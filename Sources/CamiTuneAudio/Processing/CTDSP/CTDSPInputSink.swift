import CamiTuneDomain
import CTDSPCore
import Foundation

/// One prepared graph belongs to one delivery writer. Control may cancel the
/// downstream transport, but never mutates or reads the numerical histories.
/// A retiring writer retains this object until its final write has returned.
package final class CTDSPInputSink: PCMOutputSink, @unchecked Sendable {
    package typealias AssetLoader = @Sendable (ProcessingGraph, @escaping @Sendable () throws -> Void) throws -> [String: NativeFIRAsset]
    private let control: CTDSPGraphControl
    private let loadAssets: AssetLoader
    private let sampleRate: Int
    private let inputChannels: Int
    private let outputChannels: Int
    private let maximumFrames: Int
    private let outputDeviceUID: String
    private let output: any PCMOutputSink
    private let cancelled = PerformanceAtomic()
    private let processingLoad = PerformanceAtomic()
    private let lastProcessing = PerformanceAtomic()
    private var input: [Float]
    private var candidateInput: [Float]
    private var processed: [Float]
    private var replacement: [Float]
    private var outputLimits: [Double]
    // Sole-writer state. Progress counts downstream-accepted frames, including
    // certified completion zeros alongside a peer's actual tail interval.
    private struct Transition {
        let kind: CTDSPGraphControl.Transition
        var frames: Int
    }
    private var transition: Transition?
    private var fadeFrames: Int { sampleRate / 20 }

    // The standard path retains its existing idle-instrument batching policy.
    // The configured filter quantum is enforced inside write, independently.
    package var pacesContinuousRendering: Bool { output.pacesContinuousRendering }
    package var isCancelled: Bool { cancelled.acquired != 0 }
    package var loadPercent: Double {
        let last = PerformanceTick(rawValue: lastProcessing.acquired)
        guard last.rawValue > 0, PerformanceClock.milliseconds(last, PerformanceClock.now()) < 500 else { return 0 }
        return Double(bitPattern: processingLoad.count)
    }

    private static func prepare(_ graph: ProcessingGraph, loadAssets: AssetLoader,
                                checkCancellation: @escaping @Sendable () throws -> Void) throws -> PreparedNativeGraph {
        guard (8000...384000).contains(graph.sampleRate), !graph.playback.exclusive else {
            throw AdmissionError("This ctDSP development slice requires standard output at a supported sample rate.")
        }
        try checkCancellation()
        let assets = try loadAssets(graph, checkCancellation)
        try checkCancellation()
        // The shared preparation owner validates every declared processor,
        // channel bus and resource limit before allocating numerical storage.
        let prepared = try PreparedNativeGraph(graph: graph, maximumFrames: graph.chunkSize, assets: assets)
        try checkCancellation()
        // Finite graphs drain their complete declared span, including FIR FFT
        // overlap. Only recursive graphs need a future-output certificate.
        if try prepared.streamInfo().tail_kind == CTDSP_TAIL_RECURSIVE.rawValue {
            guard try prepared.tailPeakBound().isFinite else {
                throw AdmissionError("This graph's recursive filter settling, including any FIR history, cannot yet be bounded by the ctDSP development slice.")
            }
        }
        return prepared
    }

    package init(graph: ProcessingGraph, loadAssets: @escaping AssetLoader = { _, _ in [:] },
                 checkCancellation: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() },
                 acquireOutput: () throws -> any PCMOutputSink) throws {
        let prepared = try Self.prepare(graph, loadAssets: loadAssets, checkCancellation: checkCancellation)
        self.loadAssets = loadAssets
        sampleRate = prepared.sampleRate; inputChannels = prepared.inputChannels
        outputChannels = prepared.outputChannels; maximumFrames = prepared.maximumFrames
        outputDeviceUID = graph.playback.deviceUID
        input = [Float](repeating: 0, count: graph.chunkSize * graph.inputFormat.channelCount)
        candidateInput = [Float](repeating: 0, count: input.count)
        processed = [Float](repeating: 0, count: graph.chunkSize * graph.outputFormat.channelCount)
        replacement = [Float](repeating: 0, count: graph.chunkSize * graph.outputFormat.channelCount)
        outputLimits = [Double](repeating: .infinity, count: prepared.outputChannels)
        control = try CTDSPGraphControl(prepared: prepared)
        // Resolve numerical/storage/settling failures before acquiring hardware.
        output = try acquireOutput()
    }

    package func setControlWakeup(_ wakeup: (@Sendable () -> Void)?) { control.setWakeup(wakeup) }

    package func processPendingControl() throws -> PCMOutputTailState {
        guard !isCancelled else { throw CancellationError() }
        try beginTransition(rendering: false)
        try finishTransitionIfReady()
        try finishRetirementIfReady()
        return try tailState()
    }

    /// Preparation selects a revision without waiting for source PCM. The writer
    /// retains old state through the transition and any protected output tail.
    package func installGraph(_ graph: ProcessingGraph) async throws {
        guard graph.sampleRate == sampleRate, graph.chunkSize == maximumFrames,
              graph.inputFormat.channelCount == inputChannels, graph.outputFormat.channelCount == outputChannels,
              graph.playback.deviceUID == outputDeviceUID else {
            throw AdmissionError("A native output format change requires runtime replacement.")
        }
        let loader = loadAssets
        try await control.install { try Self.prepare(graph, loadAssets: loader, checkCancellation: $0) }
    }

    package func waitForInstrumentCapacity(frames: Int) throws {
        guard !isCancelled else { throw CancellationError() }
        try output.waitForInstrumentCapacity(frames: frames)
    }

    package func write(_ bytes: Data) throws {
        let stride = inputChannels * MemoryLayout<Float>.stride
        guard bytes.count.isMultiple(of: stride) else { throw AdmissionError("Incomplete ctDSP input frame.") }
        guard !isCancelled else { throw CancellationError() }
        try bytes.withUnsafeBytes { source in
            var offset = 0
            while offset < source.count {
                guard !isCancelled else { throw CancellationError() }
                try beginTransition(rendering: true)
                try finishRetirementIfReady()
                try check(control.handoff.withProcessingHandle { ctdsp_handoff_resume_input($0) })
                let frames = min(renderCapacity, (source.count - offset) / stride)
                let byteCount = frames * stride
                try input.withUnsafeMutableBufferPointer { samples in
                    // Data may be unaligned. Copy into prepared Float32 storage.
                    UnsafeMutableRawBufferPointer(samples).copyMemory(from: UnsafeRawBufferPointer(rebasing: source[offset..<(offset + byteCount)]))
                    try candidateInput.withUnsafeMutableBufferPointer { upcoming in
                        if let transition, transition.kind == .replacing {
                            for frame in 0..<frames {
                                let weight = Double(transition.frames + frame + 1) / Double(fadeFrames)
                                for channel in 0..<inputChannels {
                                    let index = frame * inputChannels + channel
                                    let value = Double(samples[index])
                                    upcoming[index] = Float(value * weight)
                                    samples[index] = Float(value * (1 - weight))
                                }
                            }
                        }
                        try renderAndDeliver { active, candidate in
                            try check(control.handoff.withProcessingHandle {
                                ctdsp_handoff_process_active($0, samples.baseAddress, frames * inputChannels,
                                    active.baseAddress, active.count, UInt32(frames))
                            })
                            if let transition {
                                let source = transition.kind == .replacing ? upcoming.baseAddress : samples.baseAddress
                                try check(control.handoff.withProcessingHandle {
                                    ctdsp_handoff_process_candidate($0, source, frames * inputChannels,
                                        candidate.baseAddress, candidate.count, UInt32(frames))
                                })
                            } else if hasRetiring {
                                let written = try drain(candidate, frames: frames, lane: .retiring)
                                for index in (written * outputChannels)..<(frames * outputChannels) { candidate[index] = 0 }
                            }
                            return frames
                        }
                    }
                }
                offset += byteCount
            }
        }
    }

    package func finishProducer(discard: Bool) throws -> PCMOutputTailState {
        guard !isCancelled else { throw CancellationError() }
        if discard {
            try check(control.handoff.withProcessingHandle { ctdsp_handoff_reset_input($0) })
            control.collectAfterResolution()
            if transition != nil {
                try resolveTransition(control.handoff.withProcessingHandle { ctdsp_handoff_install_prepared($0) })
            }
            try beginTransition(rendering: false)
            return .complete
        }
        try check(control.handoff.withProcessingHandle { ctdsp_handoff_end_active_input($0) })
        if transition != nil {
            try check(control.handoff.withProcessingHandle { ctdsp_handoff_end_candidate_input($0) })
        }
        // A pending continuation inherits this actual END and its current tail.
        try beginTransition(rendering: false)
        try finishTransitionIfReady()
        try finishRetirementIfReady()
        return try tailState()
    }

    package func drainProducerTail(maximumFrames: Int) throws -> PCMOutputTailState {
        guard !isCancelled else { throw CancellationError() }
        guard maximumFrames > 0 else { throw AdmissionError("Invalid native tail request.") }
        try beginTransition(rendering: false)
        try finishTransitionIfReady()
        try finishRetirementIfReady()
        guard try tailState() == .pending else { return .complete }
        let frames = min(maximumFrames, renderCapacity)
        try renderAndDeliver { active, candidate in
            let oldCount: Int, newCount: Int
            if hasRetiring {
                oldCount = try drain(active, frames: frames, lane: .active)
                let count = try outputComplete(candidate: false) ? frames : oldCount
                newCount = try drain(candidate, frames: count, lane: .retiring)
            } else if transition != nil, try outputComplete(candidate: false) {
                newCount = try drain(candidate, frames: frames, lane: .candidate)
                oldCount = try drain(active, frames: newCount, lane: .active)
            } else {
                oldCount = try drain(active, frames: frames, lane: .active)
                if transition != nil {
                    let count = try outputComplete(candidate: true) ? oldCount : frames
                    newCount = try drain(candidate, frames: count, lane: .candidate)
                } else { newCount = 0 }
            }
            let written = max(oldCount, newCount)
            if transition != nil || hasRetiring {
                // Each shortened lane is complete, proved by drain's owner.
                // Extend only across the other lane's actual rendered interval.
                for index in (oldCount * outputChannels)..<(written * outputChannels) { active[index] = 0 }
                for index in (newCount * outputChannels)..<(written * outputChannels) { candidate[index] = 0 }
            }
            return written
        }
        return try tailState()
    }

    private var renderCapacity: Int {
        min(maximumFrames, transition.map { fadeFrames - $0.frames } ?? maximumFrames)
    }

    private func beginTransition(rendering: Bool) throws {
        guard transition == nil, let kind = try control.beginTransition(rendering: rendering) else { return }
        transition = Transition(kind: kind, frames: 0)
        if kind == .replacing {
            try outputLimits.withUnsafeMutableBufferPointer { limits in
                try check(control.handoff.withProcessingHandle {
                    ctdsp_handoff_output_peak_limits($0, true, limits.baseAddress, limits.count)
                })
            }
        }
    }

    private enum Lane { case active, candidate, retiring }

    private var hasRetiring: Bool {
        var revision = CTDSPRevision()
        return control.handoff.withProcessingHandle { ctdsp_handoff_retiring_revision($0, &revision) }
    }

    private func streamInfo(_ lane: Lane) throws -> CTDSPStreamInfo {
        var info = CTDSPStreamInfo()
        try check(control.handoff.withProcessingHandle { handle in
            switch lane {
            case .active: return ctdsp_handoff_active_stream_info(handle, &info)
            case .candidate: return ctdsp_handoff_candidate_stream_info(handle, &info)
            case .retiring: return ctdsp_handoff_retiring_stream_info(handle, &info)
            }
        })
        return info
    }

    private func drain(_ destination: UnsafeMutableBufferPointer<Float>, frames: Int, lane: Lane) throws -> Int {
        guard frames > 0 else { return 0 }
        // Even certified-zero recursive histories advance across a peer's real
        // tail interval. Only the finite DRAINED state supplies implied zeros.
        let info = try streamInfo(lane)
        if info.phase == CTDSP_STREAM_DRAINED.rawValue { return 0 }
        var written: UInt32 = 0
        try check(control.handoff.withProcessingHandle { handle in
            switch lane {
            case .active: return ctdsp_handoff_drain_active(handle, destination.baseAddress, destination.count, UInt32(frames), &written)
            case .candidate: return ctdsp_handoff_drain_candidate(handle, destination.baseAddress, destination.count, UInt32(frames), &written)
            case .retiring: return ctdsp_handoff_drain_retiring(handle, destination.baseAddress, destination.count, UInt32(frames), &written)
            }
        })
        if written < frames, try streamInfo(lane).phase != CTDSP_STREAM_DRAINED.rawValue {
            throw NativeGraphError.native(CTDSP_INVALID_STATE)
        }
        return Int(written)
    }

    private func renderAndDeliver(_ render: (UnsafeMutableBufferPointer<Float>, UnsafeMutableBufferPointer<Float>) throws -> Int) throws {
        let summed = transition?.kind == .replacing || hasRetiring
        try processed.withUnsafeMutableBufferPointer { destination in
            try replacement.withUnsafeMutableBufferPointer { candidate in
                let started = PerformanceClock.now()
                let frames = try render(destination, candidate)
                if summed {
                    for frame in 0..<frames {
                        for channel in 0..<outputChannels {
                            let index = frame * outputChannels + channel
                            let combined = Double(destination[index]) + Double(candidate[index])
                            let limit = outputLimits[channel]
                            let protected = Float(min(limit, max(-limit, combined)))
                            guard protected.isFinite else { throw NativeGraphError.native(CTDSP_NUMERICAL_FAILURE) }
                            destination[index] = protected
                        }
                    }
                } else if let progress = transition?.frames {
                    for frame in 0..<frames {
                        let step = progress + frame + 1
                        for channel in 0..<outputChannels {
                            let index = frame * outputChannels + channel
                            if step == fadeFrames { destination[index] = candidate[index] }
                            else {
                                let weight = Double(step) / Double(fadeFrames)
                                let previous = Double(destination[index]), upcoming = Double(candidate[index])
                                destination[index] = Float(previous + weight * (upcoming - previous))
                            }
                        }
                    }
                }
                if frames > 0 {
                    let finished = PerformanceClock.now()
                    let percent = PerformanceClock.milliseconds(started, finished) * Double(sampleRate) / Double(frames * 10)
                    processingLoad.set(percent.bitPattern)
                    lastProcessing.publish(finished.rawValue)
                    guard !isCancelled else { throw CancellationError() }
                    try output.write(UnsafeBufferPointer(rebasing: destination[..<(frames * outputChannels)]))
                    guard !isCancelled else { throw CancellationError() }
                    if transition != nil { transition!.frames += frames }
                }
            }
        }
        // Delivery acceptance precedes activation/retirement of either graph.
        try finishTransitionIfReady()
        try finishRetirementIfReady()
    }

    private func outputComplete(candidate: Bool) throws -> Bool {
        var result = false
        try check(control.handoff.withProcessingHandle { ctdsp_handoff_output_complete($0, candidate, &result) })
        return result
    }

    private func finishTransitionIfReady() throws {
        guard let transition else { return }
        let retirement: CTDSPRetirementPolicy
        if transition.kind == .replacing {
            if try streamInfo(.active).phase != CTDSP_STREAM_ACCEPTING.rawValue {
                // END may arrive before a replacement receives any PCM. Its
                // empty output is complete; the previous graph still owns tail.
                try check(control.handoff.withProcessingHandle { ctdsp_handoff_end_candidate_input($0) })
            } else {
                guard transition.frames == fadeFrames else { return }
                try check(control.handoff.withProcessingHandle { ctdsp_handoff_end_active_input($0) })
            }
            retirement = CTDSP_PRESERVE_PREVIOUS_TAIL
        } else { retirement = CTDSP_RETIRE_PREVIOUS }
        let completed = try outputComplete(candidate: true)
        if transition.kind == .continued, transition.frames < fadeFrames {
            guard completed, try outputComplete(candidate: false) else { return }
        }
        try resolveTransition(control.handoff.withProcessingHandle {
            completed ? ctdsp_handoff_install_completed($0, retirement) : ctdsp_handoff_complete($0, retirement)
        })
    }

    private func resolveTransition(_ result: CTDSPCompletion) throws {
        guard result == CTDSP_TRANSITION_RESOLVED else {
            if isCancelled { throw CancellationError() }
            throw NativeGraphError.native(CTDSP_INVALID_STATE)
        }
        transition = nil
        control.collectAfterResolution()
    }

    private func finishRetirementIfReady() throws {
        guard hasRetiring else { return }
        var completed = false
        try check(control.handoff.withProcessingHandle { ctdsp_handoff_complete_retiring($0, &completed) })
        if completed { control.collectAfterResolution() }
    }

    private func tailState() throws -> PCMOutputTailState {
        var stream = CTDSPStreamInfo()
        try check(control.handoff.withProcessingHandle { ctdsp_handoff_active_stream_info($0, &stream) })
        if stream.phase == CTDSP_STREAM_ACCEPTING.rawValue { return .complete }
        if try !outputComplete(candidate: false) { return .pending }
        if hasRetiring { return .pending }
        if transition != nil, try !outputComplete(candidate: true) { return .pending }
        return .complete
    }

    package func cancel() {
        cancelled.publish(1)
        output.cancel()
        control.close()
    }

    /// Full runtime retirement cancels delivery, independently of producer END.
    package func finish() {
        cancelled.publish(1)
        output.finish()
        control.close()
        control.finishProcessing()
    }

    private func check(_ status: CTDSPStatus) throws {
        guard status == CTDSP_OK else { throw NativeGraphError.native(status) }
    }

    private struct AdmissionError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
