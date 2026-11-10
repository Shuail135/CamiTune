import Foundation
import CamiTuneAtomics

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

package struct PerformanceCaptureSnapshot: Sendable {
    package let events: [PerformanceEvent]
    package let telemetryDrops: UInt64
}

/// Fixed, preallocated storage. Writers reserve independent slots without waiting.
package final class AudioLatencyCapture: @unchecked Sendable {
    package let id: UInt64
    package let start: PerformanceTick
    package let deadline: PerformanceTick
    package let capacity: Int
    private let storage: UnsafeMutablePointer<PerformanceEvent?>
    private let publications: CMTPerformanceStoreRef
    // Used only by stop/snapshot callers, never by an event writer.
    private let snapshotLock = NSLock()
    private var stoppedCount: Int?
    private let packets = PerformanceAtomic()
    private let audio = PerformanceAtomic()

    package init(id: UInt64, start: PerformanceTick, deadline: PerformanceTick, capacity: Int = 16_384) {
        self.id = id; self.start = start; self.deadline = deadline; self.capacity = max(1, capacity)
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: nil, count: self.capacity)
        publications = cmt_performance_store_create(UInt64(self.capacity))!
    }
    private struct RetiredStorage: @unchecked Sendable {
        let pointer: UnsafeMutablePointer<PerformanceEvent?>
        let publications: CMTPerformanceStoreRef
        let capacity: Int
        func release() {
            pointer.deinitialize(count: capacity); pointer.deallocate()
            cmt_performance_store_destroy(publications)
        }
    }
    deinit {
        // A pending PCM sidecar can be the final owner. Free the large store off audio.
        let retired = RetiredStorage(pointer: storage, publications: publications, capacity: capacity)
        DispatchQueue.global(qos: .utility).async { retired.release() }
    }
    package var telemetryDrops: UInt64 { cmt_performance_store_drops(publications) }
    package var isStopped: Bool { cmt_performance_store_stopped(publications) != 0 }
    package func discardMeasurement() { cmt_performance_store_discard(publications) }
    package func accepts(_ tick: PerformanceTick) -> Bool { !isStopped && tick >= start && tick <= deadline }
    package func append(_ event: PerformanceEvent) {
        guard accepts(event.timestamp) else { return }
        let slot = cmt_performance_store_reserve(publications)
        guard slot >= 0 else { return }
        storage[Int(slot)] = event
        switch event { case .packet: packets.increment(); case .audio: audio.increment(); case .recovery, .queue, .presentation: break }
        cmt_performance_store_publish(publications, UInt64(slot))
    }
    package func counts() -> (packets: Int, audio: Int) {
        // Presentation polling does not read payloads or join publisher settlement.
        (Int(packets.count), Int(audio.count))
    }
    package func stop() {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        if stoppedCount == nil { stoppedCount = Int(cmt_performance_store_stop(publications)) }
    }
    /// Non-audio readers only. Live snapshots omit pending publications. After
    /// stop, settle admitted writers for at most one second and count anything
    /// still unpublished as lost, without accessing its unfinished payload.
    package func snapshot() -> PerformanceCaptureSnapshot {
        snapshotLock.lock()
        let closedCount = stoppedCount
        snapshotLock.unlock()
        let settled = closedCount == nil || cmt_performance_store_wait(publications, 1_000_000_000) != 0
        let count = closedCount ?? Int(cmt_performance_store_reserved(publications))
        var events: [PerformanceEvent] = []
        events.reserveCapacity(count)
        for slot in 0..<count where cmt_performance_store_published(publications, UInt64(slot)) != 0 {
            events.append(storage[slot]!)
        }
        // A timed-out full-store rejection or explicit discard may still be
        // updating its counter even if every payload is ready. Keep that
        // uncertainty visible as at least one incomplete measurement.
        let pending = closedCount == nil ? 0 : max(count - events.count, settled ? 0 : 1)
        return .init(events: events, telemetryDrops: telemetryDrops + UInt64(pending))
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
