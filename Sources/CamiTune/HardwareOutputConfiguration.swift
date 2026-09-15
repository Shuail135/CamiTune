import Foundation

/// Hardware capacity and enabled slots, with no logical L/R or speaker meaning.
struct HardwareOutputConfiguration: Codable, Hashable, Sendable {
    var deviceUID: String
    var hardwareChannelCount: Int
    var enabledHardwareOutputs: Set<Int>

    func validate(deviceUID expectedUID: String) throws {
        guard deviceUID == expectedUID, !deviceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...SpeakerTopology.maximumOutputChannels).contains(hardwareChannelCount),
              !enabledHardwareOutputs.isEmpty,
              enabledHardwareOutputs.allSatisfy({ (0..<hardwareChannelCount).contains($0) }) else {
            throw ProfileSettingsError.runtime("Choose valid outputs on the connected audio device.")
        }
    }
}

/// The physical map can be reviewed independently of its semantic role edits.
enum HardwareTopologyReview: Equatable, Sendable {
    case unchanged
    case needsReview(previous: HardwareTopologyFingerprint, current: HardwareTopologyFingerprint)

    init(configured: SpeakerTopology, detected: SpeakerTopology) throws {
        let previous = try HardwareTopologyFingerprint(topology: configured)
        let current = try HardwareTopologyFingerprint(topology: detected)
        // A migrated profile may not have a hardware metadata snapshot yet.
        let compatible = previous.deviceUID == current.deviceUID && previous.channelCount == current.channelCount
            && (previous.reportedRoles == nil || previous.reportedRoles == current.reportedRoles)
            && (previous.reportedPositions == nil || previous.reportedPositions == current.reportedPositions)
        self = compatible ? .unchanged : .needsReview(previous: previous, current: current)
    }
}
