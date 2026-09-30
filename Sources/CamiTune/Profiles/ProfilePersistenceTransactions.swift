import CamiTuneDomain
import Foundation

/// A durable transaction records a domain mutation, never an old library snapshot
/// to republish after awaiting disk. Volume and unrelated organization survive.
enum ProfileDocumentMutation: Sendable {
    case settings(DeviceProfile, ProfileActivationMode)
    case creation(DeviceProfile)
    case routingPolicy(UUID)
    case history

    var kind: ProfilePersistenceKind {
        switch self {
        case .settings: return .settingsTransaction
        case .creation: return .profileCreation
        case .routingPolicy: return .routingPolicy
        case .history: return .history
        }
    }
    func applying(to source: ProfileDocument) throws -> ProfileDocument {
        var result = source
        switch self {
        case .settings(var candidate, let activation):
            guard let index = result.profiles.firstIndex(where: { $0.id == candidate.id }),
                  ProfileNamePolicy.isAvailable(candidate.name, in: result.profiles, excluding: candidate.id) else {
                throw ProfileSettingsError.staleDraft
            }
            candidate.outputVolumeScalar = result.profiles[index].outputVolumeScalar
            candidate.autoActivateWhenProfileDeviceSelected = activation == .profileAudioDevice
            result.profiles[index] = candidate
            result.physicalDeviceDefaults.removeAll { $0.profileID == candidate.id }
            if activation == .physicalOutput {
                result.physicalDeviceDefaults.removeAll { $0.physicalDevice.uid == candidate.outputDeviceUID }
                result.physicalDeviceDefaults.append(.init(physicalDevice: candidate.outputDevice, profileID: candidate.id))
            }
        case .creation(var candidate):
            guard !candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !candidate.outputDeviceUID.isEmpty, !result.profiles.contains(where: { $0.id == candidate.id }),
                  ProfileNamePolicy.isAvailable(candidate.name, in: result.profiles) else {
                throw ProfileSettingsError.runtime("Enter a unique profile name before adding the profile.")
            }
            let first = !result.profiles.contains { $0.outputDeviceUID == candidate.outputDeviceUID }
            candidate.autoActivateWhenProfileDeviceSelected = !first
            result.profiles.append(candidate); result.rootOrder.append(.profile(candidate.id))
            if first {
                result.physicalDeviceDefaults.removeAll { $0.physicalDevice.uid == candidate.outputDeviceUID }
                result.physicalDeviceDefaults.append(.init(physicalDevice: candidate.outputDevice, profileID: candidate.id))
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

struct ProfileDurableCommit {
    let mutation: ProfileDocumentMutation
    let ticket: ProfilePersistenceTicket
}
