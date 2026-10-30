import CamiTuneDomain
import Foundation

/// A durable transaction records a domain mutation, never an old library snapshot
/// to republish after awaiting disk. Volume and unrelated organization survive.
enum ProfileDocumentMutation: Sendable {
    case settings(DeviceProfile, ProfileActivationMode, ProfileRoutingHistoryState? = nil)
    case audioBufferDefault(AudioBufferSetting, [UUID: AudioBufferSetting?])
    case creation(DeviceProfile)
    case routingPolicy(UUID)
    case history

    var kind: ProfilePersistenceKind {
        switch self {
        case .settings, .audioBufferDefault: return .settingsTransaction
        case .creation: return .profileCreation
        case .routingPolicy: return .routingPolicy
        case .history: return .history
        }
    }
    func applying(to source: ProfileDocument) throws -> ProfileDocument {
        var result = source
        switch self {
        case .settings(var candidate, let activation, let routing):
            guard let index = result.profiles.firstIndex(where: { $0.id == candidate.id }),
                  ProfileNamePolicy.isAvailable(candidate.name, in: result.profiles, excluding: candidate.id) else {
                throw ProfileSettingsError.staleDraft
            }
            candidate.resolveAudioBuffer(default: result.audioBufferDefault)
            candidate.outputVolumeScalar = result.profiles[index].outputVolumeScalar
            candidate.autoActivateWhenProfileDeviceSelected = activation == .profileAudioDevice
            if candidate.deviceTypeConfigurationKey != result.profiles[index].deviceTypeConfigurationKey {
                result.multichannelDrafts[candidate.id] = nil
            }
            result.profiles[index] = candidate
            result.physicalDeviceDefaults.removeAll { $0.profileID == candidate.id }
            if activation == .physicalOutput {
                result.physicalDeviceDefaults.removeAll { $0.physicalDevice.uid == candidate.outputDeviceUID }
                result.physicalDeviceDefaults.append(.init(physicalDevice: candidate.outputDevice, profileID: candidate.id))
            }
            if let routing { try result.restoreRouting(routing) }
        case .creation(var candidate):
            guard !candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !candidate.outputDeviceUID.isEmpty, !result.profiles.contains(where: { $0.id == candidate.id }),
                  ProfileNamePolicy.isAvailable(candidate.name, in: result.profiles) else {
                throw ProfileSettingsError.runtime("Enter a unique profile name before adding the profile.")
            }
            candidate.resolveAudioBuffer(default: result.audioBufferDefault)
            let first = !result.profiles.contains { $0.outputDeviceUID == candidate.outputDeviceUID }
            candidate.autoActivateWhenProfileDeviceSelected = !first
            result.profiles.append(candidate); result.rootOrder.append(.profile(candidate.id))
            if first {
                result.physicalDeviceDefaults.removeAll { $0.physicalDevice.uid == candidate.outputDeviceUID }
                result.physicalDeviceDefaults.append(.init(physicalDevice: candidate.outputDevice, profileID: candidate.id))
            }
        case .audioBufferDefault(let frames, let overrides):
            guard frames.isSupported else {
                throw ProfileSettingsError.runtime("Choose a supported audio buffer size.")
            }
            guard Set(overrides.keys).isSubset(of: Set(result.profiles.map(\.id))),
                  overrides.values.allSatisfy({ $0?.isSupported != false }) else {
                throw ProfileSettingsError.staleDraft
            }
            result.audioBufferDefault = frames
            for index in result.profiles.indices {
                if let value = overrides[result.profiles[index].id] { result.profiles[index].audioBufferOverride = value }
                result.profiles[index].resolveAudioBuffer(default: frames)
            }
        case .routingPolicy(let id):
            guard let index = result.profiles.firstIndex(where: { $0.id == id }) else { throw ProfileSettingsError.staleDraft }
            result.profiles[index].autoActivateWhenProfileDeviceSelected = true
            result.physicalDeviceDefaults.removeAll { $0.profileID == id }
        case .history: break
        }
        return result
    }
}

extension ProfileDocument {
    mutating func restoreRouting(_ value: ProfileRoutingHistoryState) throws {
        guard Set(value.autoActivation.keys).isSubset(of: Set(profiles.map(\.id))),
              value.defaults.allSatisfy({ entry in
                  value.outputUIDs.contains(entry.physicalDevice.uid)
                      && profiles.contains { $0.id == entry.profileID && $0.outputDeviceUID == entry.physicalDevice.uid }
              }) else { throw HistoryRestoreError.invalidOrganization }
        physicalDeviceDefaults.removeAll { value.outputUIDs.contains($0.physicalDevice.uid) }
        physicalDeviceDefaults += value.defaults
        for index in profiles.indices {
            if let enabled = value.autoActivation[profiles[index].id] {
                profiles[index].autoActivateWhenProfileDeviceSelected = enabled
            }
        }
    }
}

struct ProfileDurableCommit {
    let mutation: ProfileDocumentMutation
    let ticket: ProfilePersistenceTicket
}
