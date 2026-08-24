import Foundation
import CoreAudio

@MainActor
final class SystemVolumeBridge {
    private weak var coreAudio: CoreAudioManager?
    private var routingUID: String?
    private var physicalUID: String?
    private var routingID: AudioDeviceID?
    private var physicalID: AudioDeviceID?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    private var physicalVolumeListener: AudioObjectPropertyListenerBlock?
    private var physicalMuteListener: AudioObjectPropertyListenerBlock?
    private var isApplyingRoutingVolume = false
    private var routingSupportsVolume = false
    private var onVolume: (@MainActor (Double) -> Void)?

    func start(
        routingDevice: AudioDeviceInfo,
        physicalUID: String,
        coreAudio: CoreAudioManager,
        onVolume: @escaping @MainActor (Double) -> Void
    ) async {
        // Listener removal can enter Core Audio. Keep route replacement
        // serialized without making MainActor perform that HAL teardown.
        await stopWithoutBlockingUI()
        self.coreAudio = coreAudio
        self.routingUID = routingDevice.id
        self.physicalUID = physicalUID
        self.routingID = routingDevice.objectID
        self.physicalID = await coreAudio.resolveDeviceWithoutBlockingUI(uid: physicalUID)?.objectID
        self.onVolume = onVolume

        let initialVolume = await coreAudio.volumeWithoutBlockingUI(uid: physicalUID) ?? 1
        routingSupportsVolume = await coreAudio.volumeWithoutBlockingUI(uid: routingDevice.id) != nil
        if routingSupportsVolume {
            try? await coreAudio.setVolumeWithoutBlockingUI(
                uid: routingDevice.id,
                scalar: initialVolume
            )
            let initiallyMuted = await coreAudio.isMutedWithoutBlockingUI(uid: physicalUID) ?? false
            await coreAudio.setMutedWithoutBlockingUI(
                uid: routingDevice.id,
                muted: initiallyMuted
            )
        }
        onVolume(Double(initialVolume))
        await synchronize()

        let volumeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in await self?.synchronize() }
        }
        let muteBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in await self?.synchronizeMute() }
        }
        let physicalVolumeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in await self?.synchronizeFromPhysical() }
        }
        let physicalMuteBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in await self?.synchronizeMuteFromPhysical() }
        }
        self.volumeListener = volumeBlock
        self.muteListener = muteBlock
        self.physicalVolumeListener = physicalVolumeBlock
        self.physicalMuteListener = physicalMuteBlock

        let routingID = routingDevice.objectID
        let physicalDeviceID = self.physicalID
        await Task.detached(priority: .utility) {
            Self.addListeners(
                routingID: routingID,
                physicalID: physicalDeviceID,
                volumeListener: volumeBlock,
                muteListener: muteBlock,
                physicalVolumeListener: physicalVolumeBlock,
                physicalMuteListener: physicalMuteBlock
            )
        }.value
    }

    func stopWithoutBlockingUI() async {
        let routingID = self.routingID
        let physicalID = self.physicalID
        let volumeListener = self.volumeListener
        let muteListener = self.muteListener
        let physicalVolumeListener = self.physicalVolumeListener
        let physicalMuteListener = self.physicalMuteListener
        clearState()

        await Task.detached(priority: .utility) {
            Self.removeListeners(
                routingID: routingID,
                physicalID: physicalID,
                volumeListener: volumeListener,
                muteListener: muteListener,
                physicalVolumeListener: physicalVolumeListener,
                physicalMuteListener: physicalMuteListener
            )
        }.value
    }

    func stop() {
        let routingID = self.routingID
        let physicalID = self.physicalID
        let volumeListener = self.volumeListener
        let muteListener = self.muteListener
        let physicalVolumeListener = self.physicalVolumeListener
        let physicalMuteListener = self.physicalMuteListener
        clearState()
        Self.removeListeners(
            routingID: routingID,
            physicalID: physicalID,
            volumeListener: volumeListener,
            muteListener: muteListener,
            physicalVolumeListener: physicalVolumeListener,
            physicalMuteListener: physicalMuteListener
        )
    }

    func setVolume(_ scalar: Float32, physicalUID requestedUID: String) async -> Bool {
        guard requestedUID == physicalUID,
              let coreAudio,
              let routingUID else { return false }
        if routingSupportsVolume {
            try? await coreAudio.setVolumeWithoutBlockingUI(uid: routingUID, scalar: scalar)
            await synchronize()
        } else {
            onVolume?(Double(scalar))
            await applyPhysicalVolume(scalar, uid: requestedUID)
        }
        return true
    }

    private func synchronize() async {
        guard let coreAudio, let routingUID, let physicalUID else { return }
        let target = routingSupportsVolume
            ? await coreAudio.volumeWithoutBlockingUI(uid: routingUID)
            : await coreAudio.volumeWithoutBlockingUI(uid: physicalUID)
        guard self.routingUID == routingUID,
              self.physicalUID == physicalUID,
              let target else { return }
        onVolume?(Double(target))
        await applyPhysicalVolume(target, uid: physicalUID)
    }

    private func synchronizeMute() async {
        guard routingSupportsVolume,
              let coreAudio, let routingUID, let physicalUID,
              let muted = await coreAudio.isMutedWithoutBlockingUI(uid: routingUID) else { return }
        guard self.routingUID == routingUID, self.physicalUID == physicalUID else { return }
        await coreAudio.setMutedWithoutBlockingUI(uid: physicalUID, muted: muted)
    }

    private func synchronizeFromPhysical() async {
        guard !isApplyingRoutingVolume,
              let coreAudio, let routingUID, let physicalUID,
              let volume = await coreAudio.volumeWithoutBlockingUI(uid: physicalUID) else { return }
        guard self.routingUID == routingUID, self.physicalUID == physicalUID else { return }
        if routingSupportsVolume {
            try? await coreAudio.setVolumeWithoutBlockingUI(uid: routingUID, scalar: volume)
        }
        guard self.routingUID == routingUID, self.physicalUID == physicalUID else { return }
        onVolume?(Double(volume))
    }

    private func synchronizeMuteFromPhysical() async {
        guard routingSupportsVolume,
              let coreAudio, let routingUID, let physicalUID,
              let muted = await coreAudio.isMutedWithoutBlockingUI(uid: physicalUID) else { return }
        guard self.routingUID == routingUID, self.physicalUID == physicalUID else { return }
        await coreAudio.setMutedWithoutBlockingUI(uid: routingUID, muted: muted)
    }

    private func applyPhysicalVolume(_ target: Float32, uid: String) async {
        guard let coreAudio, uid == physicalUID else { return }
        isApplyingRoutingVolume = true
        defer { isApplyingRoutingVolume = false }
        try? await coreAudio.setVolumeWithoutBlockingUI(uid: uid, scalar: target)
    }

    private func clearState() {
        volumeListener = nil
        muteListener = nil
        physicalVolumeListener = nil
        physicalMuteListener = nil
        routingID = nil
        physicalID = nil
        routingUID = nil
        physicalUID = nil
        isApplyingRoutingVolume = false
        routingSupportsVolume = false
        onVolume = nil
        coreAudio = nil
    }

    nonisolated private static func addListeners(
        routingID: AudioDeviceID,
        physicalID: AudioDeviceID?,
        volumeListener: @escaping AudioObjectPropertyListenerBlock,
        muteListener: @escaping AudioObjectPropertyListenerBlock,
        physicalVolumeListener: @escaping AudioObjectPropertyListenerBlock,
        physicalMuteListener: @escaping AudioObjectPropertyListenerBlock
    ) {
        var volumeAddress = Self.volumeAddress
        var muteAddress = Self.muteAddress
        _ = AudioObjectAddPropertyListenerBlock(
            routingID,
            &volumeAddress,
            .main,
            volumeListener
        )
        _ = AudioObjectAddPropertyListenerBlock(
            routingID,
            &muteAddress,
            .main,
            muteListener
        )
        if let physicalID {
            _ = AudioObjectAddPropertyListenerBlock(
                physicalID,
                &volumeAddress,
                .main,
                physicalVolumeListener
            )
            _ = AudioObjectAddPropertyListenerBlock(
                physicalID,
                &muteAddress,
                .main,
                physicalMuteListener
            )
        }
    }

    nonisolated private static func removeListeners(
        routingID: AudioDeviceID?,
        physicalID: AudioDeviceID?,
        volumeListener: AudioObjectPropertyListenerBlock?,
        muteListener: AudioObjectPropertyListenerBlock?,
        physicalVolumeListener: AudioObjectPropertyListenerBlock?,
        physicalMuteListener: AudioObjectPropertyListenerBlock?
    ) {
        if let id = routingID, let block = volumeListener {
            var address = volumeAddress
            _ = AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        if let id = routingID, let block = muteListener {
            var address = muteAddress
            _ = AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        if let id = physicalID, let block = physicalVolumeListener {
            var address = volumeAddress
            _ = AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        if let id = physicalID, let block = physicalMuteListener {
            var address = muteAddress
            _ = AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
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
