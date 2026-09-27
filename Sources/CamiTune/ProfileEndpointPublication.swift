import CamiTuneDomain
import Foundation
import CoreAudio
import SystemAudioBridgeC

/// Typed snapshots include legacy endpoints so a failed upgrade can restore
/// their original presentation. This is runtime state, never profile storage.
struct ProfileEndpointState: Equatable, Sendable {
    struct Format: Equatable, Sendable {
        let channelCount: UInt32
        let layoutTag: UInt32
        let sampleRate: Double
    }
    let uid: String
    let name: String
    let format: Format?

    init(payload: [String: Any]) throws {
        guard let uid = payload["deviceUID"] as? String, !uid.isEmpty, uid.utf16.count <= 256,
              let name = payload["displayName"] as? String, !name.isEmpty, name.utf16.count <= 128 else {
            throw ProfileSettingsError.runtime("The driver returned an invalid profile endpoint.")
        }
        self.uid = uid; self.name = name
        if ["profileFormatVersion", "channelCount", "channelLayoutTag", "supportedSampleRates"].contains(where: { payload[$0] != nil }) {
            var parsed = SABRProfileFormat()
            guard sabr_profile_format_parse(payload as CFDictionary, &parsed) else {
                throw ProfileSettingsError.runtime("The profile endpoint format is unsupported.")
            }
            format = .init(channelCount: parsed.channelCount, layoutTag: parsed.channelLayoutTag, sampleRate: parsed.sampleRate)
        } else { format = nil }
    }

    var payload: [String: Any] {
        var value: [String: Any] = ["deviceUID": uid, "displayName": name]
        if let format {
            value["profileFormatVersion"] = 1; value["channelCount"] = format.channelCount
            value["channelLayoutTag"] = format.layoutTag; value["supportedSampleRates"] = [format.sampleRate]
        }
        return value
    }
}

/// Domain endpoint policy produces values; the HAL service only publishes them.
struct ProfileEndpointPublicationRequest: Sendable {
    let descriptors: [UUID: ProfileRoutingDescriptor]
    let endpoints: [ProfileEndpointState]
    init(profiles: [DeviceProfile], activeProfileID: UUID?, defaultOutputUID: String?,
         additionallyVisible: Set<UUID> = [], preparedDescriptors: [UUID: ProfileRoutingDescriptor] = [:]) throws {
        let resolved = ProfileRoutingDescriptor.descriptors(for: profiles.filter { preparedDescriptors[$0.id] == nil })
            .merging(preparedDescriptors) { _, prepared in prepared }
        descriptors = resolved
        let desired = ProfileRoutingDescriptor.visibleProfileIDs(profiles: profiles, activeProfileID: activeProfileID,
            defaultOutputUID: defaultOutputUID, additionallyVisible: additionallyVisible)
        endpoints = try desired.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            guard let descriptor = resolved[id] else { return nil }
            return try ProfileEndpointState(payload: descriptor.formatPayload())
        }
    }
}

protocol ProfileEndpointPublicationBackend {
    func checkSupport() throws
    func current() throws -> [ProfileEndpointState]
    func apply(_ endpoints: [ProfileEndpointState]) throws
    func waitForVisibility(_ uids: Set<String>, present: Bool) throws
    func defaultOutputUID() throws -> String?
    func restoreDefaultOutput(_ uid: String) throws
}

enum ProfileEndpointPublication {
    // CoreAudio's sync migration and worker publisher share one transaction lane.
    private static let lock = NSLock()

    static func publish(_ desired: [ProfileEndpointState], using backend: ProfileEndpointPublicationBackend) throws {
        lock.lock(); defer { lock.unlock() }
        // A cancelled worker may have been waiting behind shutdown cleanup.
        try Task.checkCancellation()
        guard Set(desired.map(\.uid)).count == desired.count, desired.count <= 32 else {
            throw ProfileSettingsError.runtime("Profile endpoints must have unique identities and fit the driver capacity.")
        }
        try backend.checkSupport()
        let previous = try backend.current()
        if equivalent(previous, desired) { return }
        let defaultUID = try backend.defaultOutputUID()
        do {
            try apply(from: previous, to: desired, using: backend)
            if let uid = defaultUID, desired.contains(where: { $0.uid == uid }), try backend.defaultOutputUID() != uid {
                try backend.restoreDefaultOutput(uid)
            }
        } catch {
            let failure = error
            do {
                try CoreAudioPublicationCancellation.$current.withValue(nil) {
                let current = try backend.current()
                if !equivalent(current, previous) { try apply(from: current, to: previous, using: backend) }
                if let uid = defaultUID, try backend.defaultOutputUID() != uid { try backend.restoreDefaultOutput(uid) }
                }
            } catch { throw ProfileSettingsError.rollback(failure.localizedDescription, error.localizedDescription) }
            throw failure
        }
    }

    private static func equivalent(_ lhs: [ProfileEndpointState], _ rhs: [ProfileEndpointState]) -> Bool {
        lhs.sorted { $0.uid < $1.uid } == rhs.sorted { $0.uid < $1.uid }
    }

    private static func apply(from current: [ProfileEndpointState], to desired: [ProfileEndpointState],
                              using backend: ProfileEndpointPublicationBackend) throws {
        let retained = current.filter { old in desired.contains { $0.uid == old.uid && $0.format == old.format } }
        let removed = Set(current.map(\.uid)).subtracting(retained.map(\.uid))
        if !removed.isEmpty {
            // The driver rejects removal while client IO runs. No partial change
            // occurs in that case; callers can report it and retain the old route.
            try backend.apply(retained)
            try backend.waitForVisibility(removed, present: false)
        }
        try backend.apply(desired)
        try backend.waitForVisibility(Set(desired.map(\.uid)), present: true)
        guard equivalent(try backend.current(), desired) else {
            throw ProfileSettingsError.runtime("The driver did not retain the requested profile formats.")
        }
    }
}

struct NativeProfileEndpointBackend: ProfileEndpointPublicationBackend {
    let bridgeID: AudioObjectID // compatibility initializer only; never trusted across publication
    var waitObserver: @Sendable (CoreAudioWaitResult) -> Void = { _ in }
    private var currentBridgeID: AudioObjectID { Self.resolve(AudioDeviceInfo.systemAudioBridgeUID) }

    func checkSupport() throws {
        guard sabr_client_profile_format_version(currentBridgeID) == 1,
              sabr_client_transport_is_supported(currentBridgeID), sabr_client_transport_channel_count(currentBridgeID) == 32 else {
            throw ProfileSettingsError.runtime("Profile channel formats require System Audio Bridge 0.8.0 or newer. Open Setup and select Install / Repair Everything.")
        }
    }

    func current() throws -> [ProfileEndpointState] {
        guard let array = sabr_client_copy_profile_devices(currentBridgeID), let payloads = array as? [[String: Any]] else {
            throw ProfileSettingsError.runtime("Could not read the driver's profile endpoints.")
        }
        return try payloads.map { try ProfileEndpointState(payload: $0) }
    }

    func apply(_ endpoints: [ProfileEndpointState]) throws {
        let status = sabr_client_set_profile_devices(currentBridgeID, endpoints.map(\.payload) as CFArray)
        guard status == noErr else {
            throw ProfileSettingsError.runtime("The profile audio devices could not be reconfigured (Core Audio \(status)). Stop apps using the affected profile output and retry.")
        }
    }

    func waitForVisibility(_ uids: Set<String>, present: Bool) throws {
        let result = CoreAudioConditionWaiter.waitSynchronously(backend: .live, event: .devices, timeout: .seconds(3)) {
            uids.allSatisfy { (Self.resolve($0) != kAudioObjectUnknown) == present }
        }
        waitObserver(result)
        if result.source == .cancelled { throw CancellationError() }
        guard result.source != .timedOut else {
            throw ProfileSettingsError.runtime("macOS did not finish updating the profile audio devices.")
        }
    }

    func defaultOutputUID() throws -> String? {
        var id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else {
            throw ProfileSettingsError.runtime("Could not read the current macOS output.")
        }
        if id == kAudioObjectUnknown { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString?; size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw ProfileSettingsError.runtime("Could not preserve the current macOS output.")
        }
        return uid as String?
    }

    func restoreDefaultOutput(_ uid: String) throws {
        var id = Self.resolve(uid)
        guard id != kAudioObjectUnknown else { throw ProfileSettingsError.runtime("The previous macOS output is unavailable.") }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &id)
        guard status == noErr else { throw ProfileSettingsError.runtime("The macOS output could not be restored (\(status)).") }
    }

    private static func resolve(_ uid: String) -> AudioObjectID {
        var value = uid as CFString, id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
        }
        guard status == noErr else { return kAudioObjectUnknown }
        return id
    }
}
