import CamiTuneDomain
import Foundation

/// Owned PCMFrame slots, called under the writer branch's existing condition.
/// Normal dequeue releases one slot; it never shifts retained frames or samples.
package struct LowLatencyPCMQueue {
    package enum Entry {
        case audio(PCMFrame)
        case producerEnd
        package var frame: PCMFrame? { if case .audio(let frame) = self { return frame }; return nil }
    }
    private var slots: [Entry?] = []
    private var head = 0
    package private(set) var bufferCount = 0
    package private(set) var queuedFrames = 0
    private var sampleRate = 0.0
    package private(set) var snapshot = PCMQueueSnapshot()
    package private(set) var policy: PCMQueuePolicy?
    package private(set) var recoveryGeneration: UInt64 = 0
    package private(set) var slotGrowthCount = 0
    package private(set) var growthMovedBuffers = 0
    package let maximumDuration: TimeInterval

    package init(maximumDuration: TimeInterval = 0.1) { self.maximumDuration = maximumDuration }
    package var isEmpty: Bool { bufferCount == 0 }
    package var allocatedSlotCount: Int { slots.count }
    package var lastEnqueuedTrace: PCMWriterTraceContext? {
        guard bufferCount > 0 else { return nil }
        return slots[(head + bufferCount - 1) % slots.count]?.frame?.writerTrace
    }

    package mutating func configure(_ policy: PCMQueuePolicy) {
        self.policy = policy
        snapshot.operatingTargetFrames = policy.operatingTargetFrames
        snapshot.rateTargetMode = policy.rateTargetMode
        snapshot.recoveryTargetFrames = policy.recoveryTargetFrames
        snapshot.hardLimitFrames = policy.hardLimitFrames
    }



    package mutating func enqueue(_ input: PCMFrame, performance: PerformanceCaptureBinding? = nil) -> PCMQueueEnqueueResult {
        let count = input.frameCount, rate = input.sampleRate
        guard count > 0, rate.isFinite, rate > 0,
              maximumDuration.isFinite, maximumDuration > 0,
              rate * maximumDuration < Double(Int.max / 2) else { return .rejected }
        let before = queuedFrames, previousRate = sampleRate
        let configured = policy.flatMap { $0.sampleRate == rate ? $0 : nil }
        let maximum = max(count, configured?.hardLimitFrames ?? Int(rate * maximumDuration))
        var reason: PCMQueueRecoveryReason?
        if previousRate > 0, previousRate != rate { reason = .sampleRateChange; discardAll() }
        else if queuedFrames > maximum - count || bufferCount >= maximum {
            reason = .overflow
            if configured?.recoveryStrategy == .trimOldestToTarget {
                let allowed = max(0, (configured?.recoveryTargetFrames ?? 0) - count)
                while queuedFrames > allowed || bufferCount >= maximum { _ = removeOldest(recordDelivery: false) }
            } else { discardAll() }
        }
        sampleRate = rate
        let retained = queuedFrames
        var frame = input
        let interval = frame.performanceTrace
        if let capture = interval?.capture ?? performance?.capture,
           let session = interval?.identity.runtimeSessionID ?? performance?.sessionID {
            let identity = interval?.identity ?? AudioTraceIdentity(captureID: capture.id, runtimeSessionID: session,
                transportGeneration: 0, streamEpoch: 0, deviceObjectID: 0, startSampleTime: 0,
                frameCount: count, sampleRate: rate, channelCount: frame.channelCount)
            frame.writerTrace = PCMWriterTraceContext(capture: capture, identity: identity, interval: interval,
                entered: PerformanceClock.now(), queueBefore: before, queueAfter: retained + count, capacity: maximum)
        }
        reserveSlot()
        slots[(head + bufferCount) % slots.count] = .audio(frame)
        bufferCount += 1; queuedFrames += count
        snapshot.queuedFrames = queuedFrames; snapshot.capacityFrames = maximum
        snapshot.hardLimitFrames = maximum; snapshot.sampleRate = rate
        snapshot.operatingTargetFrames = configured?.operatingTargetFrames ?? min(Int(rate * 0.04), count * 2)
        snapshot.rateTargetMode = configured?.rateTargetMode ?? .legacyBlockTarget
        snapshot.recoveryTargetFrames = configured?.recoveryTargetFrames ?? 0
        snapshot.peakQueuedFrames = max(snapshot.peakQueuedFrames, queuedFrames)
        snapshot.peakDurationMilliseconds = max(snapshot.peakDurationMilliseconds, Double(queuedFrames) * 1000 / rate)
        guard let reason else { return .accepted }
        let recovery = recordRecovery(reason, before: before, incoming: count, retained: retained,
            rate: previousRate > 0 ? previousRate : rate)
        return reason == .overflow ? .overflowRecovery(recovery) : .formatReset(recovery)
    }



    /// Ordered with PCM under the writer condition. Consecutive empty epochs
    /// coalesce; controls also consume bounded slots, despite containing no PCM.
    package mutating func enqueueProducerEnd() -> Bool {
        if bufferCount > 0, case .producerEnd? = slots[(head + bufferCount - 1) % slots.count] { return true }
        guard bufferCount < max(1, policy?.hardLimitFrames ?? 4800) else { return false }
        reserveSlot()
        slots[(head + bufferCount) % slots.count] = .producerEnd
        bufferCount += 1
        return true
    }

    package mutating func removeNext() -> Entry? { removeOldest(recordDelivery: true) }

    private mutating func removeOldest(recordDelivery: Bool) -> Entry? {
        guard bufferCount > 0 else { return nil }
        let entry = slots[head]!
        slots[head] = nil
        head = (head + 1) % slots.count; bufferCount -= 1
        queuedFrames -= entry.frame?.frameCount ?? 0
        if recordDelivery, let frame = entry.frame { snapshot.latestBlockFrames = frame.frameCount }
        snapshot.queuedFrames = queuedFrames
        return entry
    }

    @discardableResult
    package mutating func clear() -> Int { reset(reason: .runtimeReset).droppedFrames }

    @discardableResult
    package mutating func reset(reason: PCMQueueRecoveryReason) -> PCMQueueRecovery {
        let before = queuedFrames
        discardAll()
        return recordRecovery(reason, before: before, incoming: 0, retained: 0, rate: sampleRate)
    }

    private mutating func discardAll() {
        for index in 0..<bufferCount { slots[(head + index) % slots.count] = nil }
        head = 0; bufferCount = 0; queuedFrames = 0; snapshot.queuedFrames = 0
    }

    private mutating func reserveSlot() {
        guard bufferCount == slots.count else { return }
        var grown = [Entry?](repeating: nil, count: max(16, slots.count * 2))
        for index in 0..<bufferCount { grown[index] = slots[(head + index) % slots.count] }
        growthMovedBuffers += bufferCount; slotGrowthCount += 1
        slots = grown; head = 0
    }

    private mutating func recordRecovery(_ reason: PCMQueueRecoveryReason, before: Int, incoming: Int,
                                         retained: Int, rate: Double) -> PCMQueueRecovery {
        recoveryGeneration &+= 1
        let value = PCMQueueRecovery(reason: reason, generation: recoveryGeneration,
            queuedFramesBefore: before, incomingFrames: incoming, droppedFrames: before - retained,
            retainedFrames: retained, queuedFramesAfter: queuedFrames,
            operatingTargetFrames: snapshot.operatingTargetFrames ?? 0,
            recoveryTargetFrames: snapshot.recoveryTargetFrames ?? 0,
            hardLimitFrames: snapshot.hardLimitFrames ?? 0, sampleRate: rate, timestamp: PerformanceClock.now())
        snapshot.lastRecoveryUptime = value.timestamp.rawValue
        snapshot.lastRecoveryDroppedFrames = value.droppedFrames
        snapshot.lastRecoveryQueuedFrames = before; snapshot.lastRecoveryIncomingFrames = incoming
        snapshot.lastRecoverySampleRate = rate; snapshot.recoveryGeneration = recoveryGeneration
        snapshot.lastRecovery = value
        return value
    }
}
