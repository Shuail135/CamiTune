import CamiTuneAudio
import CamiTuneDomain
// Frozen pre-Stage-11 reference. Diagnostic differential tests only.
import Foundation

extension PCMQueuePolicy {
    static func legacy(sampleRate: Double, chunkSize: Int) -> Self {
        .init(sampleRate: sampleRate,
              operatingTargetFrames: min(Int(sampleRate * 0.04), chunkSize * 2),
              recoveryTargetFrames: 0, hardLimitFrames: Int(sampleRate * 0.1),
              recoveryStrategy: .clearAll, rateTargetMode: .legacyBlockTarget)
    }
}

extension PCMDeliveryConfiguration {
    static func legacy(sampleRate: Double, chunkSize: Int) -> Self {
        .init(queue: .legacy(sampleRate: sampleRate, chunkSize: chunkSize), camillaQueueLimit: 4)
    }
}

struct ReferenceRateController {
    static let maximumAdjustmentPPM = 500.0

    private(set) var adjustmentPPM = 0.0
    private var integralPPM = 0.0
    private var filteredBufferedFrames: Double?

    mutating func update(
        bufferedFrames: Int,
        sourceCapacityFrames: Int,
        sampleRate: Double,
        elapsedFrames: Int
    ) -> Double {
        guard sampleRate > 0, elapsedFrames > 0 else { return adjustmentPPM }
        let desiredTarget = sampleRate * 0.04
        let targetFrames = sourceCapacityFrames > 0
            ? min(desiredTarget, Double(sourceCapacityFrames) * 0.25)
            : desiredTarget
        guard targetFrames > 0 else { return adjustmentPPM }

        let deltaTime = Double(elapsedFrames) / sampleRate
        let observed = Double(max(0, bufferedFrames))
        var filtered = filteredBufferedFrames ?? targetFrames
        let smoothing = 1 - exp(-deltaTime / 0.5)
        filtered += (observed - filtered) * smoothing
        filteredBufferedFrames = filtered

        var normalizedError = (filtered - targetFrames) / targetFrames
        if abs(normalizedError) < 0.02 { normalizedError = 0 }
        integralPPM += normalizedError * 40 * deltaTime
        integralPPM = min(400, max(-400, integralPPM))

        let requestedPPM = min(
            Self.maximumAdjustmentPPM,
            max(-Self.maximumAdjustmentPPM, normalizedError * 180 + integralPPM)
        )
        let maximumStep = max(0.25, 240 * deltaTime)
        adjustmentPPM += min(maximumStep, max(-maximumStep, requestedPPM - adjustmentPPM))
        return adjustmentPPM
    }

    mutating func reset() {
        adjustmentPPM = 0
        integralPPM = 0
        filteredBufferedFrames = nil
    }
}

struct ReferencePCMResampler {
    private var bufferedSamples: [Float] = []
    private var sourcePosition = 0.0
    private var channelCount = 0
    private var sampleRate = 0.0

    mutating func process(_ frame: PCMFrame, adjustmentPPM: Double) -> PCMFrame {
        guard frame.channelCount > 0,
              frame.sampleRate > 0,
              frame.frameCount > 0 else { return frame }
        if channelCount != frame.channelCount || sampleRate != frame.sampleRate {
            reset()
            channelCount = frame.channelCount
            sampleRate = frame.sampleRate
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
        var output: [Float] = []
        output.reserveCapacity(Int(Double(frame.frameCount) / inputFramesPerOutputFrame + 4) * channelCount)

        while true {
            let center = Int(sourcePosition)
            guard center >= 1, center + 2 < availableFrames else { break }
            let fraction = Float(sourcePosition - Double(center))
            for channel in 0..<channelCount {
                let p0 = bufferedSamples[(center - 1) * channelCount + channel]
                let p1 = bufferedSamples[center * channelCount + channel]
                let p2 = bufferedSamples[(center + 1) * channelCount + channel]
                let p3 = bufferedSamples[(center + 2) * channelCount + channel]
                output.append(cubicInterpolate(p0, p1, p2, p3, fraction))
            }
            sourcePosition += inputFramesPerOutputFrame
        }

        let consumedFrames = max(0, Int(sourcePosition) - 1)
        if consumedFrames > 0 {
            bufferedSamples.removeFirst(consumedFrames * channelCount)
            sourcePosition -= Double(consumedFrames)
        }
        return PCMFrame(
            interleaved: output,
            channelCount: frame.channelCount,
            sampleRate: frame.sampleRate,
            channelLayout: frame.channelLayout)
    }

    mutating func reset() {
        bufferedSamples.removeAll(keepingCapacity: true)
        sourcePosition = 0
        channelCount = 0
        sampleRate = 0
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

struct ReferencePCMQueue {
    private struct Buffer {
        var frame: PCMFrame
    }

    private var buffers: [Buffer] = []
    private(set) var queuedFrames = 0
    private var sampleRate = 0.0
    private(set) var snapshot = PCMQueueSnapshot()
    let maximumDuration: TimeInterval

    init(maximumDuration: TimeInterval = 0.1) {
        self.maximumDuration = maximumDuration
    }

    var isEmpty: Bool { buffers.isEmpty }
    var bufferCount: Int { buffers.count }
    var lastEnqueuedTrace: PCMWriterTraceContext? { buffers.last?.frame.writerTrace }

    mutating func append(_ frame: PCMFrame, performance: PerformanceCaptureBinding? = nil) -> Int {
        let frameCount = frame.frameCount
        let sampleRate = frame.sampleRate
        guard frameCount > 0, sampleRate > 0 else { return 0 }
        var droppedFrames = 0
        let before = queuedFrames
        let previousRate = self.sampleRate
        if self.sampleRate != 0, self.sampleRate != sampleRate {
            droppedFrames += clear()
        }
        self.sampleRate = sampleRate

        let maximumFrames = max(frameCount, Int(sampleRate * maximumDuration))
        if queuedFrames + frameCount > maximumFrames {
            droppedFrames += clear()
        }
        buffers.append(Buffer(frame: frame))
        queuedFrames += frameCount
        snapshot.queuedFrames = queuedFrames
        snapshot.capacityFrames = maximumFrames
        snapshot.sampleRate = sampleRate
        snapshot.peakQueuedFrames = max(snapshot.peakQueuedFrames, queuedFrames)
        snapshot.peakDurationMilliseconds = max(snapshot.peakDurationMilliseconds, Double(queuedFrames) * 1000 / sampleRate)
        if droppedFrames > 0 {
            snapshot.lastRecoveryUptime = PerformanceClock.now().rawValue
            snapshot.lastRecoveryDroppedFrames = droppedFrames
            snapshot.lastRecoveryQueuedFrames = before
            snapshot.lastRecoveryIncomingFrames = frameCount
            snapshot.lastRecoverySampleRate = previousRate > 0 ? previousRate : sampleRate
        }
        let interval = frame.performanceTrace
        if let capture = interval?.capture ?? performance?.capture,
           let session = interval?.identity.runtimeSessionID ?? performance?.sessionID {
            let identity = interval?.identity ?? AudioTraceIdentity(captureID: capture.id, runtimeSessionID: session,
                transportGeneration: 0, streamEpoch: 0, deviceObjectID: 0, startSampleTime: 0,
                frameCount: frameCount, sampleRate: sampleRate, channelCount: frame.channelCount)
            buffers[buffers.count - 1].frame.writerTrace = PCMWriterTraceContext(capture: capture, identity: identity,
                interval: interval, entered: PerformanceClock.now(), queueBefore: before, queueAfter: queuedFrames, capacity: maximumFrames)
        }
        return droppedFrames
    }

    mutating func removeFirst() -> PCMFrame? {
        guard !buffers.isEmpty else { return nil }
        let buffer = buffers.removeFirst()
        queuedFrames -= buffer.frame.frameCount
        snapshot.latestBlockFrames = buffer.frame.frameCount
        snapshot.queuedFrames = queuedFrames
        return buffer.frame
    }

    @discardableResult
    mutating func clear() -> Int {
        let droppedFrames = queuedFrames
        buffers.removeAll(keepingCapacity: true)
        queuedFrames = 0
        snapshot.queuedFrames = 0
        return droppedFrames
    }
}

extension LowLatencyPCMQueue {
    mutating func append(_ frame: PCMFrame, performance: PerformanceCaptureBinding? = nil) -> Int {
        enqueue(frame, performance: performance).recovery?.droppedFrames ?? 0
    }

    mutating func removeFirst() -> PCMFrame? {
        removeNext()?.frame
    }
}
