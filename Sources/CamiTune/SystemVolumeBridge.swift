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

/// Thread-safe endpoint for the driver's latest-value volume lane.
///
/// SystemAudioBridgeTransport invokes this directly from its PCM consumer
/// before routing the next audio block. The only synchronous work is an
/// in-memory curve lookup and a tiny target update in PCMRouter; HAL calls,
/// MainActor work, disk IO, and CamillaDSP RPC never enter this path.
final class SystemVolumeControlSession: @unchecked Sendable {
    struct Snapshot: Sendable {
        let scalar: Float32
        let muted: Bool
    }

    private let state = NSLock()
    private let transferCurve: SystemVolumeTransferCurve
    private let onVolume: @MainActor @Sendable (Double) -> Void
    private let onMasterGain: @Sendable (Float, Bool) -> Void
    private var latestScalar: Float32
    private var latestMute: Bool

    init(
        scalar: Float32,
        muted: Bool,
        transferCurve: SystemVolumeTransferCurve,
        onVolume: @escaping @MainActor @Sendable (Double) -> Void,
        onMasterGain: @escaping @Sendable (Float, Bool) -> Void
    ) {
        latestScalar = SystemVolumeTransferCurve.clampScalar(scalar)
        latestMute = muted
        self.transferCurve = transferCurve
        self.onVolume = onVolume
        self.onMasterGain = onMasterGain
    }

    /// Applies one complete driver snapshot. Repeated snapshots are ignored so
    /// a busy PCM stream does no extra work between actual media-key changes.
    func apply(scalar: Float32, muted: Bool) {
        let clamped = SystemVolumeTransferCurve.clampScalar(scalar)
        state.lock()
        let changed = latestScalar != clamped || latestMute != muted
        latestScalar = clamped
        latestMute = muted
        state.unlock()
        guard changed else { return }

        publish(scalar: clamped, muted: muted)
    }

    func publishCurrent() {
        let value = snapshot()
        publish(scalar: value.scalar, muted: value.muted)
    }

    func snapshot() -> Snapshot {
        state.lock()
        let value = Snapshot(scalar: latestScalar, muted: latestMute)
        state.unlock()
        return value
    }

    private func publish(scalar: Float32, muted: Bool) {
        // Update the writer target first. UI/profile persistence is deliberately
        // asynchronous and cannot delay the next audio block.
        onMasterGain(
            transferCurve.physicalLinearGain(for: scalar),
            muted
        )
        Task { @MainActor [onVolume] in
            onVolume(Double(scalar))
        }
    }
}

/// Owns the macOS-facing system master while CamiTune is active.
///
/// The selected profile endpoint retains normal macOS volume and mute controls,
/// while the private driver transport deliberately receives full-level PCM.
/// Media-key state uses the lock-free shared-memory lane when the plug-in owns
/// the control and a virtual-endpoint listener when Core Audio owns it server
/// side. PCMRouter smoothly applies the physical endpoint's measured transfer
/// curve exactly once. No live volume change is forwarded to the active
/// physical endpoint.
///
/// The physical endpoint is normalized once, only after routing has moved away
/// from it. After CamillaDSP releases the endpoint, the latest scalar and mute
/// are copied back once so direct playback resumes at the same setting.
@MainActor
final class SystemVolumeBridge {
    private weak var coreAudio: CoreAudioManager?
    private var routingUID: String?
    private var physicalUID: String?
    private var routingID: AudioDeviceID?
    private var physicalID: AudioDeviceID?
    private var routingSupportsVolume = false
    private var controlSession: SystemVolumeControlSession?
    private let routingControlQueue = DispatchQueue(
        label: "CamiTune virtual volume control",
        qos: .userInteractive
    )
    private var routingControlListener: AudioObjectPropertyListenerBlock?

    private var sessionGeneration: UInt64 = 0
    private var physicalWasNormalized = false

    @discardableResult
    func start(
        routingDevice: AudioDeviceInfo,
        physicalUID: String,
        coreAudio: CoreAudioManager,
        onVolume: @escaping @MainActor @Sendable (Double) -> Void,
        onMasterGain: @escaping @Sendable (Float, Bool) -> Void
    ) async -> SystemVolumeControlSession? {
        await stopWithoutBlockingUI()
        sessionGeneration &+= 1
        let generation = sessionGeneration

        self.coreAudio = coreAudio
        self.routingUID = routingDevice.id
        self.physicalUID = physicalUID
        self.routingID = routingDevice.objectID
        self.physicalID = await coreAudio.resolveDeviceWithoutBlockingUI(
            uid: physicalUID
        )?.objectID

        guard let physicalID else { return nil }

        // Before CamiTune takes over, the physical endpoint is authoritative.
        // Seed the virtual control from it so both activation and later
        // deactivation preserve the user's visible setting.
        let volumeSnapshot = await coreAudio.volumeTransferSnapshotWithoutBlockingUI(
            deviceID: physicalID
        )
        let initialVolume = volumeSnapshot.scalar ?? 1
        let initialMute = await coreAudio.isMutedWithoutBlockingUI(
            deviceID: physicalID
        ) ?? false
        let volumeCurve = volumeSnapshot.decibels
        guard generation == sessionGeneration else { return nil }

        routingSupportsVolume = await coreAudio.volumeWithoutBlockingUI(
            deviceID: routingDevice.objectID
        ) != nil
        guard generation == sessionGeneration else { return nil }

        let session = SystemVolumeControlSession(
            scalar: initialVolume,
            muted: initialMute,
            transferCurve: SystemVolumeTransferCurve(decibels: volumeCurve),
            onVolume: onVolume,
            onMasterGain: onMasterGain
        )
        controlSession = session

        if routingSupportsVolume {
            try? await coreAudio.setVolumeWithoutBlockingUI(
                deviceID: routingDevice.objectID,
                scalar: initialVolume
            )
            guard generation == sessionGeneration else { return nil }
            await coreAudio.setMutedWithoutBlockingUI(
                deviceID: routingDevice.objectID,
                muted: initialMute
            )
            guard generation == sessionGeneration else { return nil }

            // Core Audio can own a plug-in volume as a server-side control. In
            // that mode its value changes without invoking the driver's setter,
            // so the shared-memory control lane is only a fast path. Observe
            // the virtual endpoint as the authoritative fallback; this listener
            // never reads or writes the active physical device.
            let controlDeviceID = routingDevice.objectID
            let listener: AudioObjectPropertyListenerBlock = { [weak session] _, _ in
                guard let session,
                      let scalar = Self.routingVolume(deviceID: controlDeviceID) else {
                    return
                }
                let muted = Self.routingMute(deviceID: controlDeviceID)
                    ?? session.snapshot().muted
                session.apply(scalar: scalar, muted: muted)
            }
            if Self.addRoutingControlListener(
                deviceID: controlDeviceID,
                queue: routingControlQueue,
                listener: listener
            ) {
                routingControlListener = listener
            }
        }

        // PCMRouter may not have started its writer yet. Publishing now lets a
        // newly constructed branch initialize at this exact gain rather than
        // emitting its first buffer at unity and ramping down afterward.
        session.publishCurrent()
        return session
    }

    /// Called only after macOS has switched the default output to the profile.
    /// The software target is already installed in PCMRouter before this one
    /// setup write removes the hidden endpoint's hardware attenuation.
    func engageProcessingVolume() async {
        guard let coreAudio,
              let physicalID,
              let controlSession else { return }
        let generation = sessionGeneration

        controlSession.publishCurrent()
        do {
            try await coreAudio.setVolumeWithoutBlockingUI(
                deviceID: physicalID,
                scalar: 1
            )
            guard generation == sessionGeneration else { return }
            physicalWasNormalized = true
        } catch {
            // Fixed-volume endpoints (HDMI and some digital outputs) already
            // operate at unity, so the software master remains sufficient.
            physicalWasNormalized = false
        }
        await coreAudio.setMutedWithoutBlockingUI(
            deviceID: physicalID,
            muted: false
        )
    }

    /// Programmatic profile-volume changes use the same virtual control as
    /// F11/F12. Apply the value locally as well so idle playback need not wait
    /// for the transport's low-frequency maintenance wake.
    func setVolume(_ scalar: Float32, physicalUID requestedUID: String) async -> Bool {
        guard requestedUID == physicalUID,
              routingSupportsVolume,
              let coreAudio,
              let routingID,
              let controlSession else { return false }
        let clamped = SystemVolumeTransferCurve.clampScalar(scalar)
        try? await coreAudio.setVolumeWithoutBlockingUI(
            deviceID: routingID,
            scalar: clamped
        )
        let muted = controlSession.snapshot().muted
        controlSession.apply(scalar: clamped, muted: muted)
        return true
    }

    /// Restore only after CamillaDSP has released the physical endpoint. The
    /// virtual listener is detached first, and there are no live physical-volume
    /// writes to drain.
    func stopWithoutBlockingUI() async {
        if let routingID, let listener = routingControlListener {
            routingControlListener = nil
            let queue = routingControlQueue
            await Task.detached(priority: .utility) {
                Self.removeRoutingControlListener(
                    deviceID: routingID,
                    queue: queue,
                    listener: listener
                )
            }.value
        }

        // The transport intentionally coalesces controls to the next audio or
        // maintenance wake. Take one final virtual-device snapshot so pressing
        // a key immediately before deactivation cannot restore an older value.
        if routingSupportsVolume,
           let coreAudio,
           let routingID,
           let controlSession,
           let scalar = await coreAudio.volumeWithoutBlockingUI(deviceID: routingID) {
            let muted = await coreAudio.isMutedWithoutBlockingUI(
                deviceID: routingID
            ) ?? controlSession.snapshot().muted
            controlSession.apply(scalar: scalar, muted: muted)
        }
        let restore = restorationSnapshot()
        invalidateState()

        guard let restore else { return }
        if restore.shouldRestoreVolume {
            try? await restore.coreAudio.setVolumeWithoutBlockingUI(
                deviceID: restore.physicalID,
                scalar: restore.scalar
            )
        }
        await restore.coreAudio.setMutedWithoutBlockingUI(
            deviceID: restore.physicalID,
            muted: restore.muted
        )
    }

    func stop() {
        if let routingID, let listener = routingControlListener {
            routingControlListener = nil
            Self.removeRoutingControlListener(
                deviceID: routingID,
                queue: routingControlQueue,
                listener: listener
            )
        }
        if routingSupportsVolume,
           let coreAudio,
           let routingUID,
           let controlSession,
           let scalar = coreAudio.volume(uid: routingUID) {
            let muted = coreAudio.isMuted(uid: routingUID)
                ?? controlSession.snapshot().muted
            controlSession.apply(scalar: scalar, muted: muted)
        }
        let restore = restorationSnapshot()
        invalidateState()

        guard let restore else { return }
        if restore.shouldRestoreVolume {
            try? restore.coreAudio.setVolume(
                uid: restore.physicalUID,
                scalar: restore.scalar
            )
        }
        restore.coreAudio.setMuted(
            uid: restore.physicalUID,
            muted: restore.muted
        )
    }

    private struct RestorationSnapshot {
        let coreAudio: CoreAudioManager
        let physicalUID: String
        let physicalID: AudioDeviceID
        let scalar: Float32
        let muted: Bool
        let shouldRestoreVolume: Bool
    }

    private func restorationSnapshot() -> RestorationSnapshot? {
        guard let coreAudio,
              let physicalUID,
              let physicalID,
              let controlSession else { return nil }
        let control = controlSession.snapshot()
        return RestorationSnapshot(
            coreAudio: coreAudio,
            physicalUID: physicalUID,
            physicalID: physicalID,
            scalar: control.scalar,
            muted: control.muted,
            shouldRestoreVolume: physicalWasNormalized
        )
    }

    private func invalidateState() {
        sessionGeneration &+= 1
        routingID = nil
        physicalID = nil
        routingUID = nil
        physicalUID = nil
        routingSupportsVolume = false
        routingControlListener = nil
        physicalWasNormalized = false
        controlSession = nil
        coreAudio = nil
    }

    nonisolated private static func routingVolume(
        deviceID: AudioDeviceID
    ) -> Float32? {
        var address = volumeAddress
        var value: Float32 = 1
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return SystemVolumeTransferCurve.clampScalar(value)
    }

    nonisolated private static func routingMute(
        deviceID: AudioDeviceID
    ) -> Bool? {
        var address = muteAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value != 0
    }

    nonisolated private static func addRoutingControlListener(
        deviceID: AudioDeviceID,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> Bool {
        var volume = volumeAddress
        guard AudioObjectAddPropertyListenerBlock(
            deviceID,
            &volume,
            queue,
            listener
        ) == noErr else { return false }

        var mute = muteAddress
        guard AudioObjectAddPropertyListenerBlock(
            deviceID,
            &mute,
            queue,
            listener
        ) == noErr else {
            _ = AudioObjectRemovePropertyListenerBlock(
                deviceID,
                &volume,
                queue,
                listener
            )
            return false
        }
        return true
    }

    nonisolated private static func removeRoutingControlListener(
        deviceID: AudioDeviceID,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) {
        var volume = volumeAddress
        var mute = muteAddress
        _ = AudioObjectRemovePropertyListenerBlock(
            deviceID,
            &volume,
            queue,
            listener
        )
        _ = AudioObjectRemovePropertyListenerBlock(
            deviceID,
            &mute,
            queue,
            listener
        )
    }

    nonisolated private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    nonisolated private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
