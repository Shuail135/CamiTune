import Foundation

enum SystemVolumeMode: Sendable, Equatable {
    case hardwareMirrored
    case softwareOnly
}

struct PhysicalVolumeTarget: Sendable, Equatable {
    let scalar: Float32
    let muted: Bool

    init(scalar: Float32, muted: Bool) {
        self.scalar = SystemVolumeTransferCurve.clampScalar(scalar)
        self.muted = muted
    }

    func matches(_ other: Self) -> Bool {
        abs(scalar - other.scalar) < 0.0005 && muted == other.muted
    }
}

enum PhysicalVolumeMirrorHealth: Sendable {
    case healthy, delayed, unavailable
}

struct PhysicalVolumeMirrorStatistics: Sendable {
    var writes: UInt64 = 0
    var coalescedUpdates: UInt64 = 0
    var failures: UInt64 = 0
    var lastWriteMilliseconds: Double = 0
    var maximumWriteMilliseconds: Double = 0
    var health: PhysicalVolumeMirrorHealth = .healthy
}

/// One immutable device binding per session. All HAL operations, including
/// readback and physical-to-virtual synchronization, run on `queue`.
/// Submission only replaces a value under a short lock; slow HAL calls never
/// hold that lock, block PCM, or start a second writer after a timeout.
final class PhysicalVolumeMirror: @unchecked Sendable {
    struct Operations: Sendable {
        let read: @Sendable () -> PhysicalVolumeTarget?
        let setVolume: @Sendable (Float32) throws -> Void
        let setMute: @Sendable (Bool) throws -> Void
    }

    private let queue: DispatchQueue
    private let capabilities: OutputVolumeCapabilities
    private let operations: Operations
    private let onApplied: @Sendable (PhysicalVolumeTarget, Bool) -> Void
    private let onPhysicalChange: @Sendable (PhysicalVolumeTarget) -> Void
    private let lock = NSLock()
    private var pending: PhysicalVolumeTarget?
    private var scheduled = false
    private var accepting = true
    private var storedStatistics = PhysicalVolumeMirrorStatistics()

    // Queue-confined state. Readback recognizes hardware quantization and
    // delayed property notifications without feeding them into the virtual UI.
    private var lastApplied: PhysicalVolumeTarget?
    private var lastReadback: PhysicalVolumeTarget?
    private var stopped = false
    private var nextWriteTime = DispatchTime.now()

    init(
        queue: DispatchQueue,
        capabilities: OutputVolumeCapabilities,
        operations: Operations,
        onApplied: @escaping @Sendable (PhysicalVolumeTarget, Bool) -> Void,
        onPhysicalChange: @escaping @Sendable (PhysicalVolumeTarget) -> Void
    ) {
        self.queue = queue
        self.capabilities = capabilities
        self.operations = operations
        self.onApplied = onApplied
        self.onPhysicalChange = onPhysicalChange
    }

    var statistics: PhysicalVolumeMirrorStatistics {
        lock.lock()
        defer { lock.unlock() }
        return storedStatistics
    }

    func submit(scalar: Float32, muted: Bool) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        if pending != nil { storedStatistics.coalescedUpdates &+= 1 }
        pending = PhysicalVolumeTarget(scalar: scalar, muted: muted)
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if shouldSchedule { queue.async { [self] in drainNext() } }
    }

    private func takePending() -> PhysicalVolumeTarget? {
        lock.lock()
        defer { lock.unlock() }
        let target = pending
        pending = nil
        return target
    }

    private func drainNext() {
        guard !stopped else { return }
        if DispatchTime.now() < nextWriteTime {
            queue.asyncAfter(deadline: nextWriteTime) { [self] in drainNext() }
            return
        }
        if let target = takePending() { apply(target) }
        lock.lock()
        let hasPending = pending != nil
        if !hasPending { scheduled = false }
        lock.unlock()
        if hasPending {
            // Leading update is immediate. Held keys/sliders retain only the
            // newest value and write at most once per display frame thereafter.
            queue.asyncAfter(deadline: nextWriteTime) { [self] in drainNext() }
        }
    }

    /// Must be invoked on the shared control queue by the property listener.
    func physicalControlChanged() {
        guard !stopped else { return }
        lock.lock()
        let hasPending = pending != nil
        lock.unlock()
        guard !hasPending, let observed = operations.read() else { return }
        if let lastReadback, observed.matches(lastReadback) { return }
        lastReadback = observed
        if let lastApplied {
            let expected = PhysicalVolumeTarget(
                scalar: lastApplied.muted && !capabilities.muteWritable ? 0 : lastApplied.scalar,
                muted: capabilities.muteWritable && lastApplied.muted
            )
            // Some drivers return the old state immediately after a setter and
            // only expose its result in a later notification.
            if observed.matches(expected) { return }
        }
        var logical = observed
        if !capabilities.muteWritable, lastApplied?.muted == true, observed.scalar == 0 {
            // Zero implements mute, but must not erase the remembered volume.
            logical = lastApplied ?? observed
        }
        lastApplied = logical
        onPhysicalChange(logical)
    }

    private func apply(_ target: PhysicalVolumeTarget) {
        if let lastApplied, target.matches(lastApplied) {
            onApplied(target, true)
            return
        }
        let start = DispatchTime.now().uptimeNanoseconds
        nextWriteTime = DispatchTime(uptimeNanoseconds: start) + .milliseconds(16)
        var succeeded = false
        do {
            if target.muted {
                if capabilities.muteWritable {
                    // If mute fails, do not proceed to raise a stored volume.
                    try operations.setMute(true)
                    try operations.setVolume(target.scalar)
                } else {
                    try operations.setVolume(0)
                }
            } else {
                // A failed volume write must never be followed by unmute.
                try operations.setVolume(target.scalar)
                if capabilities.muteWritable { try operations.setMute(false) }
            }
            lastApplied = target
            lastReadback = operations.read()
            succeeded = true
        } catch {
            // Do not normalize, retry indefinitely, or remember a failed target
            // as applied. A later user change/explicit flush can recover.
            lastApplied = nil
            lastReadback = operations.read()
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        lock.lock()
        storedStatistics.writes &+= 1
        if !succeeded { storedStatistics.failures &+= 1 }
        storedStatistics.lastWriteMilliseconds = elapsed
        storedStatistics.maximumWriteMilliseconds = max(storedStatistics.maximumWriteMilliseconds, elapsed)
        storedStatistics.health = succeeded ? (elapsed > 100 ? .delayed : .healthy) : .unavailable
        lock.unlock()
        onApplied(target, succeeded)
    }

    /// Lifecycle barriers bypass the frame-rate throttle, on the same writer.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                while let target = takePending() { apply(target) }
                continuation.resume()
            }
        }
    }

    /// Called on `queue` after listeners and control producers are retired.
    func stopOnControlQueue() {
        lock.lock()
        accepting = false
        lock.unlock()
        while let target = takePending() { apply(target) }
        stopped = true
    }
}
