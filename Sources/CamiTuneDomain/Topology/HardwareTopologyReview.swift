import Foundation

package enum HardwareTopologyReview: Equatable, Sendable {
    case unchanged
    case needsReview(previous: HardwareTopologyFingerprint, current: HardwareTopologyFingerprint)

    package init(configured: SpeakerTopology, detected: SpeakerTopology) throws {
        let previous = try HardwareTopologyFingerprint(topology: configured)
        let current = try HardwareTopologyFingerprint(topology: detected)
        // A migrated profile may not have a hardware metadata snapshot yet.
        let compatible = previous.deviceUID == current.deviceUID && previous.channelCount == current.channelCount
            && (previous.reportedRoles == nil || previous.reportedRoles == current.reportedRoles)
            && (previous.reportedPositions == nil || previous.reportedPositions == current.reportedPositions)
        self = compatible ? .unchanged : .needsReview(previous: previous, current: current)
    }
}
