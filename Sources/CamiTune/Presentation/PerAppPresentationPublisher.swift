import Foundation

/// One serial worker; the manual implementation controls deadlines and Main delivery in tests.
struct PresentationPublicationScheduling: @unchecked Sendable {
    typealias Job = @Sendable () -> Void
    var now: @Sendable () -> PerformanceTick
    var enqueue: (@escaping Job) -> Void
    var after: (Double, @escaping Job) -> Job
    var main: (@escaping Job) -> Void
    var assertWorker: () -> Void

    static func live(queue: DispatchQueue) -> Self {
        .init(now: { PerformanceClock.now() }, enqueue: { queue.async(execute: $0) }, after: { delay, job in
            let work = DispatchWorkItem(block: job)
            queue.asyncAfter(deadline: .now() + max(0, delay), execute: work)
            return { work.cancel() }
        }, main: { DispatchQueue.main.async(execute: $0) }, assertWorker: {
            dispatchPrecondition(condition: .onQueue(queue))
        })
    }
}

enum ApplicationPublicationRequest { case meter, immediate }

/// Audio/control state → presentation, never the reverse.
/// Lock order: audioLock is never used here. The request lock protects scalar
/// scheduling state only, and is released before input capture takes stateLock.
/// Building/sorting/diffing holds neither lock. Main delivery takes no locks.
final class PerAppPresentationPublisher: @unchecked Sendable {
    private let scheduling: PresentationPublicationScheduling
    private let captureInput: @Sendable () -> PerAppPresentationInput?
    private let buildRows: @Sendable (PerAppPresentationInput) -> [PerAppAudioApplication]
    private let observeMetadata: @Sendable ([AppPresentationObservation]) -> Void
    private let deliver: @Sendable (PerAppPresentationSnapshot) -> Void
    private let performance: PerformanceTraceSource
    private let requestLock = NSLock()
    private let closed = PerformanceAtomic()
    private var dirty = false
    private var forcePending = false
    private var drainScheduled = false
    private var waitingForDeadline = false
    private var generation: UInt64 = 0
    private var trailingCancel: PresentationPublicationScheduling.Job?
    private var statisticsValue = PresentationPublicationStatistics()
    private var activeSources: Set<String> = []
    private var suspendedSources: Set<String> = []
    private var visible = false
    // Worker-only state.
    private var lastPublished: PerformanceTick?
    private var mainScheduled = false
    private var submittedMetadata: [String: AppPresentationObservation] = [:]
    // Atomic ownership transfer lets Main take the newest immutable snapshot
    // without a mutex or synchronous hop back to the worker.
    private let pending = PresentationSnapshotMailbox()
    private var deliveredRevision: UInt64 = 0 // Main-only.

    init(scheduling: PresentationPublicationScheduling, performance: PerformanceTraceSource,
         captureInput: @escaping @Sendable () -> PerAppPresentationInput?,
         buildRows: @escaping @Sendable (PerAppPresentationInput) -> [PerAppAudioApplication] = { PerAppPresentationSnapshot.makeRows($0) },
         observeMetadata: @escaping @Sendable ([AppPresentationObservation]) -> Void,
         deliver: @escaping @Sendable (PerAppPresentationSnapshot) -> Void) {
        self.scheduling = scheduling; self.performance = performance; self.captureInput = captureInput
        self.buildRows = buildRows; self.observeMetadata = observeMetadata; self.deliver = deliver
    }
    deinit { shutdown() }

    var statistics: PresentationPublicationStatistics {
        requestLock.lock(); defer { requestLock.unlock() }; return statisticsValue
    }

    /// Only publisher policy examines visibility; callers still record identity evidence.
    func setActive(_ active: Bool, source: String) -> Bool {
        requestLock.lock(); defer { requestLock.unlock() }
        if active { activeSources.insert(source) } else { activeSources.remove(source) }
        visible = !activeSources.subtracting(suspendedSources).isEmpty
        return active && !suspendedSources.contains(source)
    }
    func setSuspended(_ suspended: Bool, source: String) -> Bool {
        requestLock.lock(); defer { requestLock.unlock() }
        if suspended { suspendedSources.insert(source) } else { suspendedSources.remove(source) }
        visible = !activeSources.subtracting(suspendedSources).isEmpty
        return !suspended && activeSources.contains(source)
    }

    func request(_ request: ApplicationPublicationRequest) {
        var token: UInt64?
        requestLock.lock()
        guard closed.count == 0 else { requestLock.unlock(); return }
        statisticsValue.requests &+= 1
        if request == .immediate { statisticsValue.immediateRequests &+= 1; forcePending = true }
        else { statisticsValue.meterRequests &+= 1 }
        dirty = true
        if !drainScheduled && (visible || forcePending) {
            drainScheduled = true; generation &+= 1; token = generation
        } else if request == .immediate && waitingForDeadline {
            // Supersede one delayed drain, not one task for each incoming request.
            waitingForDeadline = false; generation &+= 1; token = generation
        } else { statisticsValue.coalescedRequests &+= 1 }
        if token != nil { statisticsValue.maximumPendingDrains = 1 }
        requestLock.unlock()
        if let token { scheduling.enqueue { [weak self] in self?.drain(token: token, trailing: false) } }
    }

    private func drain(token: UInt64, trailing: Bool) {
        scheduling.assertWorker()
        let now = scheduling.now()
        requestLock.lock()
        guard closed.count == 0, token == generation else { requestLock.unlock(); return }
        statisticsValue.workerDrains &+= 1
        let cancel = trailingCancel; trailingCancel = nil
        if !forcePending && !trailing && !visible {
            dirty = false; drainScheduled = false; waitingForDeadline = false
            requestLock.unlock(); cancel?(); return
        }
        if !forcePending && !trailing, let lastPublished, now < lastPublished.advanced(seconds: 0.1) {
            waitingForDeadline = true
            let delay = Double(lastPublished.advanced(seconds: 0.1).rawValue - now.rawValue) / 1e9
            requestLock.unlock(); cancel?()
            let cancellation = scheduling.after(delay) { [weak self] in self?.drain(token: token, trailing: true) }
            requestLock.lock()
            let retain = closed.count == 0 && generation == token && waitingForDeadline
            if retain { trailingCancel = cancellation }
            requestLock.unlock()
            if !retain { cancellation() }
            return
        }
        dirty = false; forcePending = false; waitingForDeadline = false
        requestLock.unlock(); cancel?()

        let capture = performance.snapshot()?.capture
        let inputStarted = capture.map { _ in PerformanceClock.now() }
        if let input = captureInput() {
            capture?.recordPresentation("Input capture", from: inputStarted, revision: input.revision)
            let buildStarted = capture.map { _ in PerformanceClock.now() }
            let rows = buildRows(input)
            let sortStarted = capture.map { _ in PerformanceClock.now() }
            let sorted = rows.sorted(by: PerAppPresentationSnapshot.precedes)
            capture?.recordPresentation("Sorting", from: sortStarted, revision: input.revision)
            capture?.recordPresentation("Snapshot construction", from: buildStarted, revision: input.revision, onWorker: true)
            let snapshot = PerAppPresentationSnapshot(revision: input.revision, applications: sorted)
            let metadataStarted = capture.map { _ in PerformanceClock.now() }
            var observations: [AppPresentationObservation] = []
            for app in sorted where PerAppAudioController.isPersistentApplicationID(app.id) {
                let observation = AppPresentationObservation(applicationID: app.id, systemDisplayName: app.displayName, bundleID: app.bundleID)
                if submittedMetadata[app.id] != observation {
                    submittedMetadata[app.id] = observation; observations.append(observation)
                }
            }
            // This callback enqueues durable observations independently of replaceable UI rows.
            observeMetadata(observations)
            capture?.recordPresentation("Metadata diff", from: metadataStarted, revision: input.revision)
            if closed.count == 0 {
                pending.replace(.init(snapshot: snapshot, capture: capture, enqueued: PerformanceClock.now()))
                // Shutdown may have cleared the mailbox while this build finished.
                if closed.count != 0 { pending.replace(nil) }
                else { scheduleMainIfNeeded() }
            }
            lastPublished = now
            requestLock.lock()
            statisticsValue.snapshotsBuilt &+= 1
            if trailing { statisticsValue.trailingBuilds &+= 1 }
            requestLock.unlock()
        }
        requestLock.lock()
        let again = dirty && closed.count == 0
        if !again { drainScheduled = false }
        let next = generation
        requestLock.unlock()
        if again { scheduling.enqueue { [weak self] in self?.drain(token: next, trailing: false) } }
    }

    private func scheduleMainIfNeeded() {
        scheduling.assertWorker()
        guard !mainScheduled, !pending.isEmpty, closed.count == 0 else { return }
        mainScheduled = true
        scheduling.main { [weak self] in
            guard let self, closed.count == 0, let envelope = pending.take() else { return }
            // No controller, scheduler, or audio lock is acquired by this callback.
            if closed.count == 0 && envelope.snapshot.revision >= deliveredRevision {
                deliveredRevision = envelope.snapshot.revision
                envelope.capture?.recordPresentation("MainActor delivery lag", from: envelope.enqueued, revision: envelope.snapshot.revision)
                deliver(envelope.snapshot)
            }
            scheduling.enqueue { [weak self] in
                guard let self, closed.count == 0 else { return }
                requestLock.lock(); statisticsValue.mainDeliveries &+= 1; requestLock.unlock()
                mainScheduled = false
                scheduleMainIfNeeded()
            }
        }
    }

    func shutdown() {
        requestLock.lock()
        closed.set(1); dirty = false; forcePending = false; drainScheduled = false; waitingForDeadline = false
        generation &+= 1
        let cancel = trailingCancel; trailingCancel = nil
        requestLock.unlock()
        cancel?(); pending.replace(nil)
    }
}

private final class PresentationSnapshotEnvelope: @unchecked Sendable {
    let snapshot: PerAppPresentationSnapshot
    let capture: AudioLatencyCapture?
    let enqueued: PerformanceTick
    init(snapshot: PerAppPresentationSnapshot, capture: AudioLatencyCapture?, enqueued: PerformanceTick) {
        self.snapshot = snapshot; self.capture = capture; self.enqueued = enqueued
    }
}

/// Exchange transfers one retained reference. Unlike load+retain, take cannot race
/// a producer releasing the old snapshot. All supported Mac architectures are 64-bit.
private final class PresentationSnapshotMailbox: @unchecked Sendable {
    private let slot = PerformanceAtomic()
    var isEmpty: Bool { slot.count == 0 }
    func replace(_ value: PresentationSnapshotEnvelope?) {
        let pointer = value.map { UInt64(UInt(bitPattern: Unmanaged.passRetained($0).toOpaque())) } ?? 0
        if let old = object(slot.exchange(pointer)) { old.release() }
    }
    func take() -> PresentationSnapshotEnvelope? { object(slot.exchange(0))?.takeRetainedValue() }
    private func object(_ value: UInt64) -> Unmanaged<PresentationSnapshotEnvelope>? {
        guard let pointer = UnsafeRawPointer(bitPattern: UInt(value)) else { return nil }
        return Unmanaged<PresentationSnapshotEnvelope>.fromOpaque(pointer)
    }
    deinit { replace(nil) }
}
