import Foundation

package struct PerformanceCaptureBinding: Sendable {
    package init(capture: AudioLatencyCapture, sessionID: UUID? = nil) {
        self.capture = capture
        self.sessionID = sessionID
    }

    package let capture: AudioLatencyCapture
    package let sessionID: UUID?
}

/// One atomic branch while disabled. Detailed capture never waits for a lock.
package final class PerformanceTraceSource: @unchecked Sendable {
    package init() {}
    private let enabled = PerformanceAtomic()
    private let contention = PerformanceAtomic()
    private let lock = NSLock()
    private var capture: AudioLatencyCapture?
    private var sessionID: UUID?
    package var contentionDrops: UInt64 { contention.count }

    package func setSession(_ id: UUID?) {
        lock.lock(); sessionID = id; lock.unlock()
    }
    package func setCapture(_ value: AudioLatencyCapture?) {
        lock.lock(); capture = value; enabled.set(value == nil ? 0 : 1); lock.unlock()
    }
    package func snapshot() -> PerformanceCaptureBinding? {
        guard enabled.count != 0 else { return nil }
        guard lock.try() else { contention.increment(); return nil }
        defer { lock.unlock() }
        return capture.map { .init(capture: $0, sessionID: sessionID) }
    }
}

/// Fixed, preallocated storage. A contended/full recorder discards telemetry only.
package final class AudioLatencyCapture: @unchecked Sendable {
    package let id: UInt64
    package let start: PerformanceTick
    package let deadline: PerformanceTick
    package let capacity: Int
    private let storage: UnsafeMutablePointer<PerformanceEvent?>
    private let lock = NSLock()
    private let stopped = PerformanceAtomic()
    private let dropped = PerformanceAtomic()
    private var count = 0
    private let packets = PerformanceAtomic()
    private let audio = PerformanceAtomic()

    package init(id: UInt64, start: PerformanceTick, deadline: PerformanceTick, capacity: Int = 16_384) {
        self.id = id; self.start = start; self.deadline = deadline; self.capacity = max(1, capacity)
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: nil, count: self.capacity)
    }
    private struct RetiredStorage: @unchecked Sendable {
        let pointer: UnsafeMutablePointer<PerformanceEvent?>
        let capacity: Int
        func release() { pointer.deinitialize(count: capacity); pointer.deallocate() }
    }
    deinit {
        // A pending PCM sidecar can be the final owner. Free the large store off audio.
        let retired = RetiredStorage(pointer: storage, capacity: capacity)
        DispatchQueue.global(qos: .utility).async { retired.release() }
    }
    package var telemetryDrops: UInt64 { dropped.count }
    package var isStopped: Bool { stopped.count != 0 }
    package func discardMeasurement() { dropped.increment() }
    package func accepts(_ tick: PerformanceTick) -> Bool { stopped.count == 0 && tick >= start && tick <= deadline }
    package func append(_ event: PerformanceEvent) {
        guard accepts(event.timestamp) else { return }
        guard lock.try() else { dropped.increment(); return }
        defer { lock.unlock() }
        guard stopped.count == 0 else { return }
        guard count < capacity else { dropped.increment(); return }
        storage[count] = event; count += 1
        switch event { case .packet: packets.increment(); case .audio: audio.increment(); case .recovery, .queue, .presentation: break }
    }
    package func counts() -> (packets: Int, audio: Int) {
        // Presentation polling must not contend with the nonblocking append.
        (Int(packets.count), Int(audio.count))
    }
    package func stop() { stopped.set(1) }
    /// Only the non-audio aggregation worker copies/sorts recorded events.
    package func events() -> [PerformanceEvent] {
        lock.lock(); defer { lock.unlock() }
        return (0..<count).compactMap { storage[$0] }
    }
}

/// Bounded trace-only metadata; changes here never affect mixer eligibility or PCM.
package struct MixPerformanceTrace: Sendable {
    package init(capture: AudioLatencyCapture, identity: AudioTraceIdentity, contributions: [TraceContribution] = [], untracedUntil: Int64, lastPolicyTick: PerformanceTick) {
        self.capture = capture
        self.identity = identity
        self.contributions = contributions
        self.untracedUntil = untracedUntil
        self.lastPolicyTick = lastPolicyTick
    }

    package var capture: AudioLatencyCapture
    package var identity: AudioTraceIdentity
    package var contributions: [TraceContribution] = []
    package var untracedUntil: Int64
    package var lastPolicyTick: PerformanceTick

    package mutating func add(_ packet: PacketPerformanceContext?, processed: PerformanceTick?, start: Int64, end: Int64, existingEnd: Int64) {
        guard let packet, let processed else {
            untracedUntil = max(untracedUntil, end); return
        }
        if identity.captureID != packet.identity.captureID || identity.runtimeSessionID != packet.identity.runtimeSessionID
            || identity.transportGeneration != packet.identity.transportGeneration || identity.streamEpoch != packet.identity.streamEpoch {
            capture = packet.capture; identity = packet.identity
            contributions.removeAll(keepingCapacity: true); untracedUntil = existingEnd
        }
        lastPolicyTick = packet.policyTick ?? packet.received
        guard contributions.count < 256 else {
            capture.discardMeasurement(); untracedUntil = max(existingEnd, end)
            contributions.removeAll(keepingCapacity: true); return
        }
        contributions.append(.init(startSampleTime: start, endSampleTime: end, received: packet.received, processingCompleted: processed))
    }

    package mutating func emit(start: Int64, count: Int, eligible: PerformanceTick, deadline: PerformanceTick?, flushStarted: PerformanceTick? = nil) -> AudioIntervalTraceContext? {
        let end = start + Int64(count)
        var first: PerformanceTick?; var last: PerformanceTick?; var processed: PerformanceTick?; var firstProcessed: PerformanceTick?; var contributors = 0
        for contribution in contributions where contribution.startSampleTime < end && contribution.endSampleTime > start {
            first = min(first ?? contribution.received, contribution.received)
            last = max(last ?? contribution.received, contribution.received)
            processed = max(processed ?? contribution.processingCompleted, contribution.processingCompleted)
            firstProcessed = min(firstProcessed ?? contribution.processingCompleted, contribution.processingCompleted)
            contributors += 1
        }
        contributions.removeAll { $0.endSampleTime <= end }
        for index in contributions.indices { contributions[index].startSampleTime = max(end, contributions[index].startSampleTime) }
        guard start >= untracedUntil, let first, let last, let processed, let firstProcessed, capture.accepts(first) else { return nil }
        var identity = self.identity; identity.startSampleTime = start; identity.frameCount = count
        return .init(capture: capture, identity: identity, firstPacketReceived: first, lastPacketReceived: last,
            firstPacketProcessed: firstProcessed, lastPacketProcessed: processed, becameEligible: max(eligible, processed), emitted: eligible,
            contributingPackets: contributors, idleDeadline: deadline, idleFlushStarted: flushStarted)
    }
}
