import CamiTuneDomain
import Foundation

package struct MovieAnalysisIntent: Equatable, Sendable {
    package let detector: MovieDetector
    package let scope: MovieApplicationScope
    package init?(configuration: RenderConfiguration) {
        guard configuration.playbackMode == .spatialRender, let personal = configuration.personalSpatial,
              personal.experience == .spatialListening, personal.movie.analyzesContent else { return nil }
        detector = personal.movie.detector; scope = personal.movie.scope
    }
}

package struct MovieAnalysisResult: Sendable {
    package let generation: UInt64
    package let startFrame: UInt64
    package let endFrame: UInt64
    package let scores: MovieContentScores
    package init(generation: UInt64, startFrame: UInt64, endFrame: UInt64, scores: MovieContentScores) {
        self.generation = generation; self.startFrame = startFrame; self.endFrame = endFrame; self.scores = scores
    }
}

package enum MovieAnalysisPhase: UInt64, Sendable {
    case off, preparing, running, suspended, quiet, retired
    case overflow, unsupportedFormat, stale, modelFailure
    package var failureMessage: String? {
        switch self {
        case .overflow: return "Analysis could not keep up. Playback and manual enhancement continue. Turn Movie off and on to retry."
        case .unsupportedFormat: return "Analysis does not match the current input format. Playback and manual enhancement continue."
        case .stale: return "Analysis fell behind the playing audio. Playback and manual enhancement continue. Turn Movie off and on to retry."
        case .modelFailure: return "The local sound detector is unavailable. Playback and manual enhancement continue. Turn Movie off and on to retry."
        default: return nil
        }
    }
}

/// Generation and phase publish together. A failed generation stays failed
/// through producer END; only a new user intent or route can retry it.
package struct MovieAnalysisRequest: Sendable {
    package let generation: UInt64
    package let phase: MovieAnalysisPhase
    package let intent: MovieAnalysisIntent?
}

/// One delivery writer and one analysis worker. PCM has a fixed 250 ms bound,
/// independent of delivery recovery. The writer never locks or waits to copy it.
/// Every queued frame carries its generation, so a control change racing the
/// final publication cannot expose old samples as a new analysis context.
package final class MovieAnalysisExchange: @unchecked Sendable {
    package let layout: LPCMChannelLayout
    package let rate: Double
    package let capacity: Int
    package let batchFrames: Int
    private let samples: UnsafeMutablePointer<Float>
    private let generations: UnsafeMutablePointer<UInt64>
    private let frames: UnsafeMutablePointer<UInt64>
    private let read = PerformanceAtomic(), write = PerformanceAtomic()
    private let state = PerformanceAtomic()
    private let liveFrame = PerformanceAtomic()
    private let metadata = NSLock()
    private var intent: MovieAnalysisIntent?
    private var result: MovieAnalysisResult?
    private let wake: @Sendable () -> Void
    // Writer-owned clock/cache. This clock counts completed playback intervals,
    // including intervals without Movie input, and never follows inference time.
    private var nextFrame: UInt64 = 0
    private var cachedResult: MovieAnalysisResult?
    private var admittedGeneration: UInt64 = 0
    private var firstFrame: UInt64 = 0
    private enum ChannelMapping { case identity, reordered([Int?]) }
    private var cachedMapping: (layout: LPCMChannelLayout, mapping: ChannelMapping)?

    package init(rate: Double, layout: LPCMChannelLayout, wake: @escaping @Sendable () -> Void) throws {
        try layout.validate()
        guard rate.isFinite, rate >= 44_100, rate <= 192_000,
              PersonalSpatialSettings.supportedSampleRates.contains(Int(rate)), rate == Double(Int(rate)) else {
            throw AudioRouteFormatError.sampleRate(expected: 48_000)
        }
        self.rate = rate; self.layout = layout; self.wake = wake
        capacity = Int(ceil(rate * 0.25)); batchFrames = Int(ceil(rate * 0.1))
        samples = .allocate(capacity: capacity * layout.channelCount)
        generations = .allocate(capacity: capacity); frames = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity * layout.channelCount)
        generations.initialize(repeating: 0, count: capacity); frames.initialize(repeating: 0, count: capacity)
    }
    deinit { samples.deallocate(); generations.deallocate(); frames.deallocate() }

    private func phase(_ token: UInt64) -> MovieAnalysisPhase { MovieAnalysisPhase(rawValue: token & 15)! }
    private func token(_ generation: UInt64, _ phase: MovieAnalysisPhase) -> UInt64 { generation << 4 | phase.rawValue }

    /// Control-side configuration; the metadata lock never encloses model work.
    package func configure(_ next: MovieAnalysisIntent?) {
        metadata.lock()
        guard phase(state.acquired) != .retired, intent != next else { metadata.unlock(); return }
        intent = next
        result = nil
        while true {
            let old = state.acquired
            if phase(old) == .retired { break }
            if state.compareExchange(expected: old, desired: token((old >> 4) + 1, next == nil ? .off : .preparing)) { break }
        }
        metadata.unlock()
        wake()
    }
    package func suspend() {
        while true {
            let old = state.acquired
            guard [.preparing, .running, .quiet].contains(phase(old)) else { return }
            if state.compareExchange(expected: old, desired: token((old >> 4) + 1, .suspended)) { wake(); return }
        }
    }
    package func retire() {
        while true {
            let old = state.acquired
            guard phase(old) != .retired else { return }
            if state.compareExchange(expected: old, desired: token((old >> 4) + 1, .retired)) { wake(); return }
        }
    }
    package var isRetired: Bool { phase(state.acquired) == .retired }
    package var generation: UInt64 { state.acquired >> 4 }
    package var queuedFrames: Int {
        let consumed = read.acquired
        return Int(write.acquired - consumed)
    }
    package var allocatedBytes: Int { capacity * (layout.channelCount * MemoryLayout<Float>.size + 2 * MemoryLayout<UInt64>.size) }

    package func request() -> MovieAnalysisRequest {
        metadata.lock(); defer { metadata.unlock() }
        let value = state.acquired, current = phase(value)
        return .init(generation: value >> 4, phase: current, intent: current == .running || current == .preparing ? intent : nil)
    }
    package func presentationStatus() -> MovieAnalysisStatus {
        metadata.lock(); defer { metadata.unlock() }
        let value = state.acquired, current = phase(value)
        if let message = current.failureMessage { return .unavailable(message) }
        switch current {
        case .off, .retired: return .off
        case .suspended, .quiet: return .content(.init())
        case .running:
            if let result, result.generation == value >> 4 { return .content(result.scores) }
            return .preparing
        default: return .preparing
        }
    }

    /// Called exactly once per completed interval, before either scene bank.
    /// Nil input means no eligible Movie cohort, not an invented audio source.
    package func offer(_ frame: PCMFrame, movieSamples: [Float]?) -> MovieContentScores? {
        guard frame.frameCount > 0 else { return nil }
        let start = nextFrame
        nextFrame &+= UInt64(frame.frameCount); liveFrame.publish(nextFrame)
        guard !isRetired else { return nil }
        guard let input = movieSamples else { suspend(); return nil }
        let current = state.acquired
        if [.suspended, .quiet].contains(phase(current)), hasAnalysisSignal(frame, input: input) {
            if state.compareExchange(expected: current, desired: token((current >> 4) + 1, .preparing)) { wake() }
            return nil
        }
        guard phase(current) == .running else { return nil }
        let generation = current >> 4
        if admittedGeneration != generation {
            admittedGeneration = generation; firstFrame = start; cachedResult = nil
        }
        guard frame.sampleRate == rate, frame.channelCount == frame.channelLayout.channelCount,
              input.count == frame.frameCount * frame.channelCount,
              let mapping = mapping(for: frame.channelLayout) else { fail(.unsupportedFormat, generation: generation); return nil }
        let end = write.acquired, consumed = read.acquired
        guard frame.frameCount <= capacity, end - consumed <= UInt64(capacity - frame.frameCount) else {
            fail(.overflow, generation: generation); return nil
        }
        let slot = Int(end % UInt64(capacity))
        let firstCount = min(frame.frameCount, capacity - slot)
        input.withUnsafeBufferPointer { source in
            switch mapping {
            case .identity:
                samples.advanced(by: slot * layout.channelCount).update(from: source.baseAddress!, count: firstCount * layout.channelCount)
                if firstCount < frame.frameCount {
                    samples.update(from: source.baseAddress!.advanced(by: firstCount * layout.channelCount), count: (frame.frameCount - firstCount) * layout.channelCount)
                }
            case .reordered(let indices):
                var destination = slot
                for index in 0..<frame.frameCount {
                    for channel in indices.indices {
                        samples[destination * layout.channelCount + channel] = indices[channel].map { source[index * frame.channelCount + $0] } ?? 0
                    }
                    destination += 1
                    if destination == capacity { destination = 0 }
                }
            }
        }
        generations.advanced(by: slot).update(repeating: generation, count: firstCount)
        if firstCount < frame.frameCount { generations.update(repeating: generation, count: frame.frameCount - firstCount) }
        var destination = slot
        for index in 0..<frame.frameCount {
            frames[destination] = start + UInt64(index)
            destination += 1
            if destination == capacity { destination = 0 }
        }
        write.publish(end + UInt64(frame.frameCount))
        if end + UInt64(frame.frameCount) - consumed >= UInt64(batchFrames) { wake() }
        if metadata.try() { cachedResult = result; metadata.unlock() }
        guard state.acquired == current else { return nil }
        guard let cachedResult, cachedResult.generation == generation, cachedResult.endFrame <= nextFrame else {
            if nextFrame - firstFrame > UInt64(rate * 2) { fail(.stale, generation: generation) }
            return nil
        }
        if nextFrame - cachedResult.endFrame > UInt64(rate * 1.5) { fail(.stale, generation: generation); return nil }
        return cachedResult.scores
    }

    private func hasAnalysisSignal(_ frame: PCMFrame, input: [Float]) -> Bool {
        guard frame.channelCount > 0, frame.channelLayout.channelCount == frame.channelCount else { return false }
        for (index, sample) in input.enumerated() where frame.channelLayout.roles[index % frame.channelCount] != .lowFrequencyEffects {
            if sample.isFinite && abs(sample) > 0.0001 { return true }
        }
        return false
    }

    private func mapping(for input: LPCMChannelLayout) -> ChannelMapping? {
        if cachedMapping?.layout == input { return cachedMapping?.mapping }
        guard (try? input.validate()) != nil else { return nil }
        let mapping: ChannelMapping
        if input.signalSignature == layout.signalSignature {
            mapping = .identity
        } else {
            guard Set(input.roles).count == input.channelCount, Set(layout.roles).count == layout.channelCount,
                  !input.roles.contains(.unknown) else { return nil }
            for index in input.roles.indices {
                guard let destination = layout.roles.firstIndex(of: input.roles[index]),
                      input.positions?[index] == layout.positions?[destination] else { return nil }
            }
            mapping = .reordered(layout.roles.map { input.roles.firstIndex(of: $0) })
        }
        cachedMapping = (input, mapping)
        return mapping
    }

    /// Worker-only. Retain this exchange until any blocking platform call and
    /// its callbacks return; retiring a route never frees a live worker's input.
    package func begin(generation: UInt64) -> Bool {
        read.publish(write.acquired)
        return state.compareExchange(expected: token(generation, .preparing), desired: token(generation, .running))
    }
    package func readBatch(into output: UnsafeMutableBufferPointer<Float>, generation: UInt64) -> (start: UInt64, count: Int)? {
        precondition(output.count >= batchFrames * layout.channelCount)
        let start = read.acquired, end = write.acquired
        var cursor = start
        while cursor < end && generations[Int(cursor % UInt64(capacity))] != generation { cursor += 1 }
        guard end - cursor >= UInt64(batchFrames), state.acquired == token(generation, .running) else { read.publish(cursor); return nil }
        let first = frames[Int(cursor % UInt64(capacity))]
        let firstSlot = Int(cursor % UInt64(capacity))
        var slot = firstSlot
        var count = 0
        while count < batchFrames && cursor < end {
            guard generations[slot] == generation, frames[slot] == first + UInt64(count) else { break }
            count += 1; cursor += 1
            slot += 1
            if slot == capacity { slot = 0 }
        }
        let firstCount = min(count, capacity - firstSlot)
        output.baseAddress!.update(from: samples.advanced(by: firstSlot * layout.channelCount), count: firstCount * layout.channelCount)
        if firstCount < count {
            output.baseAddress!.advanced(by: firstCount * layout.channelCount).update(from: samples, count: (count - firstCount) * layout.channelCount)
        }
        read.publish(cursor)
        return count > 0 ? (first, count) : nil
    }
    package func publish(_ value: MovieAnalysisResult) {
        guard value.startFrame < value.endFrame, value.endFrame <= liveFrame.acquired else { return }
        let age = liveFrame.acquired - value.endFrame
        guard age <= UInt64(rate * 1.5) else { fail(.stale, generation: value.generation); return }
        metadata.lock(); defer { metadata.unlock() }
        guard state.acquired == token(value.generation, .running) else { return }
        if let result, result.generation == value.generation, result.endFrame > value.endFrame { return }
        result = value
    }
    package func markQuiet(generation: UInt64) {
        _ = state.compareExchange(expected: token(generation, .running), desired: token(generation, .quiet))
    }
    package func fail(_ failure: MovieAnalysisPhase, generation: UInt64) {
        precondition(failure.failureMessage != nil)
        let current = state.acquired
        guard current >> 4 == generation, [.preparing, .running].contains(phase(current)) else { return }
        if state.compareExchange(expected: current, desired: token(generation, failure)) { wake() }
    }
}
