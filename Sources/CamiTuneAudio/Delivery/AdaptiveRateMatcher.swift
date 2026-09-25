import CamiTuneDomain
import Foundation





package struct AdaptivePCMResampler {
    package init() {}

    private var bufferedSamples = PCMInterpolationHistory()
    package var retainedSampleCount: Int { bufferedSamples.count }
    package var historyCapacity: Int { bufferedSamples.capacity }
    package var historyGrowths: Int { bufferedSamples.growths }
    package var historyRebases: Int { bufferedSamples.rebases }
    private var sourcePosition = 0.0
    private var channelCount = 0
    private var sampleRate = 0.0
    private var channelLayout: LPCMChannelLayout?

    package mutating func process(_ frame: PCMFrame, adjustmentPPM: Double) -> PCMFrame {
        guard frame.channelCount > 0,
              frame.sampleRate > 0,
              frame.frameCount > 0 else { return frame }
        if channelCount != frame.channelCount || sampleRate != frame.sampleRate {
            reset()
            channelCount = frame.channelCount
            sampleRate = frame.sampleRate
            channelLayout = frame.channelLayout
        }

        if bufferedSamples.isEmpty {
            bufferedSamples.append(contentsOf: frame.interleaved.prefix(channelCount))
            sourcePosition = 1
        }
        bufferedSamples.append(contentsOf: frame.interleaved)

        let inputFramesPerOutputFrame = min(
            1.001,
            max(0.999, 1 + adjustmentPPM / 1_000_000)
        )
        let availableFrames = bufferedSamples.count / channelCount
        let outputCapacity = Int(Double(frame.frameCount) / inputFramesPerOutputFrame + 4) * channelCount
        var position = sourcePosition
        let channels = channelCount
        let output = bufferedSamples.withSamples { samples in
            Array<Float>(unsafeUninitializedCapacity: outputCapacity) { destination, initializedCount in
                var written = 0
                while true {
                    let center = Int(position)
                    guard center >= 1, center + 2 < availableFrames else { break }
                    // The same four-frame allowance used by the previous array
                    // reserve covers retained cubic history. Check the bound
                    // once per frame before initializing any output samples.
                    precondition(written <= outputCapacity - channels)
                    let fraction = Float(position - Double(center))
                    for channel in 0..<channels {
                        let p0 = samples[(center - 1) * channels + channel]
                        let p1 = samples[center * channels + channel]
                        let p2 = samples[(center + 1) * channels + channel]
                        let p3 = samples[(center + 2) * channels + channel]
                        destination.baseAddress!.advanced(by: written).initialize(to:
                            cubicInterpolate(p0, p1, p2, p3, fraction))
                        written += 1
                    }
                    position += inputFramesPerOutputFrame
                }
                initializedCount = written
            }
        }
        sourcePosition = position

        let consumedFrames = max(0, Int(sourcePosition) - 1)
        if consumedFrames > 0 {
            bufferedSamples.consume(consumedFrames * channelCount)
            sourcePosition -= Double(consumedFrames)
        }
        return PCMFrame(
            interleaved: output,
            channelCount: frame.channelCount,
            sampleRate: frame.sampleRate,
            channelLayout: frame.channelLayout)
    }

    /// A producer seal proves that no further lookahead belongs to this epoch.
    /// Extend the endpoint for interpolation only; emit positions within the
    /// accepted input, then retire history before another sound can use it.
    package mutating func finish(adjustmentPPM: Double) -> PCMFrame? {
        guard channelCount > 0, bufferedSamples.count >= channelCount else { reset(); return nil }
        let endpoint = (0..<channelCount).map { bufferedSamples[bufferedSamples.count - channelCount + $0] }
        let padding = PCMFrame(interleaved: endpoint + endpoint, channelCount: channelCount,
            sampleRate: sampleRate, channelLayout: channelLayout)
        let result = process(padding, adjustmentPPM: adjustmentPPM)
        reset()
        return result
    }

    package mutating func reset() {
        bufferedSamples.reset()
        sourcePosition = 0
        channelCount = 0
        sampleRate = 0
        channelLayout = nil
    }

    private func cubicInterpolate(
        _ p0: Float,
        _ p1: Float,
        _ p2: Float,
        _ p3: Float,
        _ amount: Float
    ) -> Float {
        p1 + 0.5 * amount * (
            p2 - p0 + amount * (
                2 * p0 - 5 * p1 + 4 * p2 - p3
                    + amount * (3 * (p1 - p2) + p3 - p0)
            )
        )
    }
}

/// Contiguous storage with a logical head. Consumption never shifts samples.
/// When tail room runs out, only the bounded cubic history is rebased; the
/// current input is copied in bulk. Capacity follows block size, not run length.
private struct PCMInterpolationHistory {
    private var samples: [Float] = []
    private var head = 0
    private(set) var count = 0
    private(set) var growths = 0
    private(set) var rebases = 0
    var capacity: Int { samples.count }
    var isEmpty: Bool { count == 0 }
    subscript(index: Int) -> Float { samples[head + index] }

    /// The view is valid only during this synchronous call; storage cannot be
    /// appended, consumed or rebased while interpolation borrows its samples.
    func withSamples<R>(_ body: (UnsafeBufferPointer<Float>) -> R) -> R {
        samples.withUnsafeBufferPointer { storage in
            body(UnsafeBufferPointer(start: storage.baseAddress!.advanced(by: head), count: count))
        }
    }

    mutating func append<S: Collection>(contentsOf incoming: S) where S.Element == Float {
        let needed = count + incoming.count
        if needed > samples.count {
            var capacity = max(16, samples.count)
            while capacity < needed * 2 { capacity *= 2 }
            var grown = [Float](repeating: 0, count: capacity)
            for index in 0..<count { grown[index] = self[index] }
            samples = grown; head = 0; growths += 1
        } else if head + needed > samples.count {
            let oldHead = head, retained = count
            samples.withUnsafeMutableBufferPointer { storage in
                // Forward copying is safe even if these small regions overlap:
                // the destination always precedes unread source samples.
                for index in 0..<retained { storage[index] = storage[oldHead + index] }
            }
            head = 0; rebases += 1
        }
        let tail = head + count
        let copied = incoming.withContiguousStorageIfAvailable { source -> Bool in
            guard !source.isEmpty else { return true }
            samples.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress!.advanced(by: tail).update(from: source.baseAddress!, count: source.count)
            }
            return true
        } ?? false
        if !copied {
            var position = tail
            for value in incoming { samples[position] = value; position += 1 }
        }
        count = needed
    }
    mutating func consume(_ amount: Int) {
        precondition(amount >= 0 && amount <= count)
        head += amount; count -= amount
    }
    mutating func reset() { head = 0; count = 0 }
}
