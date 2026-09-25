import Foundation

/// Hardware-reported topology only: rates, timestamps, names, and user speaker
/// edits do not invalidate a physical mapping. Channel order is significant.
package struct HardwareTopologyFingerprint: Codable, Hashable, Sendable {
    package let deviceUID: String
    package let channelCount: Int
    package let reportedRoles: [ChannelRole]?
    package let reportedPositions: [SpatialPosition?]?

    package init(deviceUID: String, channelCount: Int) {
        self.deviceUID = deviceUID; self.channelCount = channelCount
        reportedRoles = nil; reportedPositions = nil
    }

    package init(topology: SpeakerTopology) throws {
        try topology.validate()
        deviceUID = topology.deviceUID
        channelCount = topology.declaredChannelCount
        reportedRoles = topology.hardwareRoles
        reportedPositions = topology.hardwarePositions
    }
}
