import Foundation
import CoreAudio
import Darwin

/// Immutable transfer function copied from the physical endpoint before its
/// playback stream is opened. Runtime media-key handling uses only this local
/// table; it never queries or writes the active hardware device.
struct SystemVolumeTransferCurve: Sendable {
    let decibels: [Float32]

    /// Some physical endpoints expose a scalar-conversion property that does
    /// not include the HAL transfer exponent used by their effective volume
    /// control. Calibrate the in-memory curve against the endpoint's current
    /// scalar and actual dB value while it is still authoritative.
    static func calibratedDecibels(
        nativeSamples: [Float32],
        scalar: Float32,
        effectiveDecibels: Float32?,
        minimumDecibels: Float32?,
        maximumDecibels: Float32?
    ) -> [Float32] {
        guard nativeSamples.count >= 2,
              scalar > 0.001, scalar < 0.999,
              let effectiveDecibels, effectiveDecibels.isFinite,
              let minimumDecibels, minimumDecibels.isFinite,
              let maximumDecibels, maximumDecibels.isFinite,
              maximumDecibels > minimumDecibels else {
            return nativeSamples
        }

        let nativeCurve = SystemVolumeTransferCurve(decibels: nativeSamples)
        if abs(nativeCurve.decibels(for: scalar) - effectiveDecibels) < 0.25 {
            return nativeSamples
        }

        let normalized = (effectiveDecibels - minimumDecibels)
            / (maximumDecibels - minimumDecibels)
        guard normalized > 0, normalized < 1 else { return nativeSamples }
        let measuredExponent = logf(normalized) / logf(scalar)
        guard measuredExponent.isFinite,
              measuredExponent >= 0.2,
              measuredExponent <= 12.5 else { return nativeSamples }

        // Core Audio's standard transfer functions use this finite exponent
        // family. Snapping removes hardware-step quantization error from the
        // single effective-dB calibration point.
        let standardExponents: [Float32] = [
            1.0 / 3.0, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
        ]
        let exponent = standardExponents.min {
            abs($0 - measuredExponent) < abs($1 - measuredExponent)
        } ?? measuredExponent
        let reconstructed = minimumDecibels
            + ((maximumDecibels - minimumDecibels) * powf(scalar, exponent))
        guard abs(reconstructed - effectiveDecibels) < 0.5 else {
            return nativeSamples
        }

        let denominator = Float32(nativeSamples.count - 1)
        return nativeSamples.indices.map { index in
            let value = Float32(index) / denominator
            return minimumDecibels
                + ((maximumDecibels - minimumDecibels) * powf(value, exponent))
        }
    }

    /// The gain the physical endpoint applies when it owns the system route.
    func physicalLinearGain(for scalar: Float32) -> Float {
        let db = decibels(for: scalar)
        guard scalar > 0, db.isFinite else { return 0 }
        return min(1, max(0, powf(10, db / 20)))
    }

    func decibels(for scalar: Float32) -> Float32 {
        let value = Self.clampScalar(scalar)
        guard decibels.count >= 2 else {
            guard value > 0 else { return -150 }
            return max(-150, min(0, 20 * log10f(value)))
        }
        if value <= 0 { return decibels[0] }
        if value >= 1 { return decibels[decibels.count - 1] }

        let position = Double(value) * Double(decibels.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(decibels.count - 1, lower + 1)
        let fraction = Float32(position - Double(lower))
        let a = decibels[lower]
        let b = decibels[upper]
        let interpolated = a + ((b - a) * fraction)
        return interpolated.isFinite ? max(-150, min(0, interpolated)) : 0
    }

    static func clampScalar(_ scalar: Float32) -> Float32 {
        max(0, min(1, scalar.isFinite ? scalar : 1))
    }
}

/// Thread-safe session state. PCM callbacks use only in-memory targets; HAL
/// work belongs to the serial control queue. UI notifications retain one latest
/// snapshot, so a held key cannot build a backlog of MainActor tasks.
final class SystemVolumeControlSession: @unchecked Sendable {
    struct Snapshot: Sendable {
        let scalar: Float32
        let muted: Bool
    }

    private let state = NSLock()
    let mode: SystemVolumeMode
    private let transferCurve: SystemVolumeTransferCurve
    private let onVolume: @MainActor @Sendable (Double) -> Void
    private let onMasterGain: @Sendable (Float, Bool) -> Void
    private var onPhysicalVolumeTarget: @Sendable (Float32, Bool) -> Void
    private var latestScalar: Float32
    private var latestMute: Bool
    private var physicalReady: Bool
    private var handoff = false
    private var active = true
    private var uiPending = false

    init(
        scalar: Float32,
        muted: Bool,
        mode: SystemVolumeMode = .softwareOnly,
        transferCurve: SystemVolumeTransferCurve,
        onVolume: @escaping @MainActor @Sendable (Double) -> Void,
        onMasterGain: @escaping @Sendable (Float, Bool) -> Void,
        onPhysicalVolumeTarget: @escaping @Sendable (Float32, Bool) -> Void = { _, _ in }
    ) {
        latestScalar = SystemVolumeTransferCurve.clampScalar(scalar)
        latestMute = muted
        self.mode = mode
        physicalReady = mode == .softwareOnly
        self.transferCurve = transferCurve
        self.onVolume = onVolume
        self.onMasterGain = onMasterGain
        self.onPhysicalVolumeTarget = onPhysicalVolumeTarget
    }

    func attach(_ mirror: PhysicalVolumeMirror) {
        state.lock()
        onPhysicalVolumeTarget = { [mirror] scalar, muted in
            mirror.submit(scalar: scalar, muted: muted)
        }
        state.unlock()
    }

    /// Hardware mode uses the virtual HAL listener as its single input source.
    /// The shared lane may lag a physical-to-virtual write or contain the volume
    /// half of a volume/mute update; replaying it would undo a hardware button.
    func applyDriverSnapshot(scalar: Float32, muted: Bool) {
        guard mode == .softwareOnly else { return }
        apply(scalar: scalar, muted: muted)
    }

    func apply(scalar: Float32, muted: Bool) {
        state.lock()
        defer { state.unlock() }
        guard active else { return }
        let scalar = SystemVolumeTransferCurve.clampScalar(scalar)
        guard scalar != latestScalar || muted != latestMute else { return }
        if mode == .hardwareMirrored, latestMute && !muted { physicalReady = false }
        latestScalar = scalar
        latestMute = muted
        publishLocked(mirror: true)
    }

    func applyFromPhysical(_ target: PhysicalVolumeTarget) {
        state.lock()
        defer { state.unlock() }
        guard active else { return }
        latestScalar = target.scalar
        latestMute = target.muted
        physicalReady = true
        publishLocked(mirror: false)
    }

    func physicalTargetApplied(_ target: PhysicalVolumeTarget, succeeded: Bool) {
        state.lock()
        defer { state.unlock() }
        guard active else { return }
        if !succeeded {
            physicalReady = false
        } else if target.matches(PhysicalVolumeTarget(scalar: latestScalar, muted: latestMute)) {
            physicalReady = true
        }
        publishMasterLocked()
    }

    func publishCurrent() {
        state.lock()
        defer { state.unlock() }
        guard active else { return }
        publishLocked(mirror: true)
    }

    func beginOutputHandoff() {
        state.lock()
        handoff = true
        publishMasterLocked()
        state.unlock()
    }

    func resumeAfterOutputHandoff() {
        state.lock()
        defer { state.unlock() }
        guard active else { return }
        handoff = false
        publishMasterLocked()
    }

    func invalidate() {
        state.lock()
        active = false
        handoff = true
        publishMasterLocked()
        onPhysicalVolumeTarget = { _, _ in }
        state.unlock()
    }

    func snapshot() -> Snapshot {
        state.lock()
        defer { state.unlock() }
        return Snapshot(scalar: latestScalar, muted: latestMute)
    }

    private func publishMasterLocked() {
        onMasterGain(
            mode == .hardwareMirrored ? 1 : transferCurve.physicalLinearGain(for: latestScalar),
            latestMute || handoff || !physicalReady
        )
    }

    private func publishLocked(mirror: Bool) {
        // Keep target publication ordered with state changes from other threads.
        // Neither callback may call back into this session or perform HAL IO.
        publishMasterLocked()
        if mirror, mode == .hardwareMirrored {
            onPhysicalVolumeTarget(latestScalar, latestMute)
        }
        guard !uiPending else { return }
        uiPending = true
        Task { @MainActor [weak self] in
            guard let self, let scalar = self.takeUIValue() else { return }
            self.onVolume(Double(scalar))
        }
    }

    private func takeUIValue() -> Float32? {
        state.lock()
        defer { state.unlock() }
        uiPending = false
        return active ? latestScalar : nil
    }
}

/// The virtual endpoint owns system-volume state. Writable physical outputs
/// enforce its attenuation; fixed outputs retain the measured software curve.
/// A shared serial queue orders both directions of HAL synchronization.
@MainActor
final class SystemVolumeBridge {
    private weak var coreAudio: CoreAudioManager?
    private var physicalUID: String?
    private var routingID: AudioDeviceID?
    private var controlSession: SystemVolumeControlSession?
    private(set) var mode: SystemVolumeMode?
    private var physicalVolumeMirror: PhysicalVolumeMirror?
    private let controlQueue = DispatchQueue(label: "CamiTune volume control", qos: .userInitiated)
    private var listeners: [ControlListener] = []
    private var sessionGeneration: UInt64 = 0

    @discardableResult
    func start(
        routingDevice: AudioDeviceInfo,
        physicalUID: String,
        coreAudio: CoreAudioManager,
        onVolume: @escaping @MainActor @Sendable (Double) -> Void,
        onMasterGain: @escaping @Sendable (Float, Bool) -> Void,
        onMirrorFailure: @escaping @MainActor @Sendable () -> Void = {}
    ) async throws -> SystemVolumeControlSession {
        await stopWithoutBlockingUI()
        sessionGeneration &+= 1
        let generation = sessionGeneration
        guard let physical = await coreAudio.resolveDeviceWithoutBlockingUI(uid: physicalUID) else {
            throw CoreAudioManager.AudioError.deviceNotFound(physicalUID)
        }
        let capabilities = await coreAudio.outputVolumeCapabilitiesWithoutBlockingUI(
            deviceID: physical.objectID
        )
        let selectedMode: SystemVolumeMode = capabilities.supportsHardwareMirroring
            ? .hardwareMirrored : .softwareOnly
        // Hardware mirroring does not need hundreds of transfer-curve HAL reads.
        let snapshot: PhysicalVolumeTransferSnapshot
        if selectedMode == .hardwareMirrored {
            let scalar = await coreAudio.volumeWithoutBlockingUI(deviceID: physical.objectID)
            guard let scalar, scalar.isFinite else { throw CoreAudioManager.AudioError.volumeNotSettable }
            snapshot = PhysicalVolumeTransferSnapshot(scalar: scalar, decibels: [])
        } else {
            snapshot = await coreAudio.volumeTransferSnapshotWithoutBlockingUI(deviceID: physical.objectID)
        }
        let initialMute = await coreAudio.isMutedWithoutBlockingUI(deviceID: physical.objectID) ?? false
        guard generation == sessionGeneration else { throw CancellationError() }

        let initialScalar = snapshot.scalar ?? 1
        // Seed before installing listeners or starting PCM. Never normalize the
        // physical endpoint, including on failure or fixed-volume outputs.
        try await coreAudio.setVolumeWithoutBlockingUI(deviceID: routingDevice.objectID, scalar: initialScalar)
        await coreAudio.setMutedWithoutBlockingUI(deviceID: routingDevice.objectID, muted: initialMute)
        guard generation == sessionGeneration else { throw CancellationError() }

        let session = SystemVolumeControlSession(
            scalar: initialScalar, muted: initialMute, mode: selectedMode,
            transferCurve: SystemVolumeTransferCurve(decibels: snapshot.decibels),
            onVolume: onVolume, onMasterGain: onMasterGain
        )
        self.coreAudio = coreAudio
        self.physicalUID = physicalUID
        routingID = routingDevice.objectID
        controlSession = session
        mode = selectedMode
        let routingID = routingDevice.objectID
        let physicalID = physical.objectID
        let queue = controlQueue
        let mirror: PhysicalVolumeMirror?
        if selectedMode == .hardwareMirrored {
            mirror = PhysicalVolumeMirror(
                queue: queue, capabilities: capabilities,
                operations: .init(
                    read: { CoreAudioManager.volumeTarget(deviceID: physicalID) },
                    setVolume: { try CoreAudioManager.setVolume(deviceID: physicalID, scalar: $0) },
                    setMute: { try CoreAudioManager.setMuteChecked(deviceID: physicalID, muted: $0) }
                ),
                onApplied: { [weak session] target, succeeded in
                    session?.physicalTargetApplied(target, succeeded: succeeded)
                    if !succeeded {
                        Task { @MainActor [weak self] in
                            guard self?.sessionGeneration == generation else { return }
                            onMirrorFailure()
                        }
                    }
                },
                onPhysicalChange: { [weak session] target in
                    // Same queue as the virtual listener: it cannot observe a
                    // half-updated scalar/mute pair or echo this back to hardware.
                    do {
                        try CoreAudioManager.setVolume(deviceID: routingID, scalar: target.scalar)
                        try CoreAudioManager.setMuteChecked(deviceID: routingID, muted: target.muted)
                        session?.applyFromPhysical(target)
                    } catch {
                        session?.physicalTargetApplied(target, succeeded: false)
                        Task { @MainActor [weak self] in
                            guard self?.sessionGeneration == generation else { return }
                            onMirrorFailure()
                        }
                    }
                }
            )
        } else {
            mirror = nil
        }
        physicalVolumeMirror = mirror
        if let mirror { session.attach(mirror) }
        let installed = await withCheckedContinuation { continuation in
            queue.async {
                var installed = Self.installListeners(deviceID: routingID, queue: queue) { [weak session] in
                    guard let value = CoreAudioManager.volumeTarget(deviceID: routingID) else { return }
                    session?.apply(scalar: value.scalar, muted: value.muted)
                }
                if let mirror {
                    installed += Self.installListeners(deviceID: physicalID, queue: queue) { [weak mirror] in
                        mirror?.physicalControlChanged()
                    }
                }
                continuation.resume(returning: installed)
            }
        }
        listeners = installed
        let routingVolumeInstalled = installed.contains(where: {
            $0.deviceID == routingID && $0.address.mSelector == kAudioDevicePropertyVolumeScalar
        })
        let physicalVolumeInstalled = mirror == nil || installed.contains(where: {
            $0.deviceID == physicalID && $0.address.mSelector == kAudioDevicePropertyVolumeScalar
        })
        guard routingVolumeInstalled && physicalVolumeInstalled else {
            await stopWithoutBlockingUI()
            throw CoreAudioManager.AudioError.volumeNotSettable
        }
        session.publishCurrent()
        return session
    }

    func prepareForActiveProcessing() async throws {
        controlSession?.publishCurrent()
        await physicalVolumeMirror?.flush()
        if physicalVolumeMirror?.statistics.health == .unavailable {
            throw CoreAudioManager.AudioError.volumeNotSettable
        }
    }

    /// Latch the outgoing PCM fade so a late media-key event cannot unmute it.
    func silenceForExternalRouteChange() {
        controlSession?.beginOutputHandoff()
    }

    func resumeAfterExternalRouteReturn() {
        controlSession?.resumeAfterOutputHandoff()
    }

    func beginOutputHandoff() async {
        controlSession?.beginOutputHandoff()
        await captureLatestRoutingState()
        await physicalVolumeMirror?.flush()
        try? await Task.sleep(for: .milliseconds(12))
    }

    func setVolume(_ scalar: Float32, physicalUID requestedUID: String) async -> Bool {
        guard requestedUID == physicalUID, let routingID, let session = controlSession else { return false }
        let clamped = SystemVolumeTransferCurve.clampScalar(scalar)
        return await withCheckedContinuation { continuation in
            controlQueue.async {
                do {
                    try CoreAudioManager.setVolume(deviceID: routingID, scalar: clamped)
                    session.apply(scalar: clamped, muted: session.snapshot().muted)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func captureLatestRoutingState() async {
        guard let routingID, let session = controlSession else { return }
        await withCheckedContinuation { continuation in
            controlQueue.async {
                if let value = CoreAudioManager.volumeTarget(deviceID: routingID) {
                    session.apply(scalar: value.scalar, muted: value.muted)
                }
                continuation.resume()
            }
        }
    }

    func stopWithoutBlockingUI() async {
        let listeners = self.listeners
        let session = controlSession
        let mirror = physicalVolumeMirror
        let routingID = self.routingID
        let queue = controlQueue
        invalidateState()
        await withCheckedContinuation { continuation in
            queue.async {
                Self.finishSession(listeners: listeners, queue: queue, routingID: routingID, session: session, mirror: mirror)
                continuation.resume()
            }
        }
    }

    /// Application termination needs a synchronous barrier, still using the
    /// same serial writer so an old HAL operation cannot undo the final state.
    func stop() {
        let listeners = self.listeners
        let session = controlSession
        let mirror = physicalVolumeMirror
        let routingID = self.routingID
        let queue = controlQueue
        invalidateState()
        queue.sync {
            Self.finishSession(listeners: listeners, queue: queue, routingID: routingID, session: session, mirror: mirror)
        }
    }

    nonisolated private static func finishSession(
        listeners: [ControlListener], queue: DispatchQueue, routingID: AudioDeviceID?,
        session: SystemVolumeControlSession?, mirror: PhysicalVolumeMirror?
    ) {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.deviceID, &address, queue, listener.block)
        }
        if let routingID, let value = CoreAudioManager.volumeTarget(deviceID: routingID) {
            session?.apply(scalar: value.scalar, muted: value.muted)
        }
        // Submission is synchronous, so this also drains a last button press
        // that has not yet reached the driver's maintenance wake.
        session?.publishCurrent()
        session?.invalidate()
        mirror?.stopOnControlQueue()
    }

    private func invalidateState() {
        sessionGeneration &+= 1
        listeners = []
        routingID = nil
        physicalUID = nil
        mode = nil
        controlSession = nil
        physicalVolumeMirror = nil
        coreAudio = nil
    }

    private struct ControlListener: @unchecked Sendable {
        let deviceID: AudioDeviceID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    nonisolated private static func installListeners(
        deviceID: AudioDeviceID, queue: DispatchQueue,
        onChange: @escaping @Sendable () -> Void
    ) -> [ControlListener] {
        var listeners: [ControlListener] = []
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        // Master-only devices, per-channel devices, and devices without mute
        // each keep every listener that successfully installs.
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element
                )
                guard AudioObjectHasProperty(deviceID, &address) else { continue }
                if AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block) == noErr {
                    listeners.append(ControlListener(deviceID: deviceID, address: address, block: block))
                }
            }
        }
        return listeners
    }
}
