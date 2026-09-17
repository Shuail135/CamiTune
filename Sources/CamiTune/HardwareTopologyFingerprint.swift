import Foundation

/// Hardware-reported topology only: rates, timestamps, names, and user speaker
/// edits do not invalidate a physical mapping. Channel order is significant.
struct HardwareTopologyFingerprint: Codable, Hashable, Sendable {
    let deviceUID: String
    let channelCount: Int
    let reportedRoles: [ChannelRole]?
    let reportedPositions: [SpatialPosition?]?

    init(deviceUID: String, channelCount: Int) {
        self.deviceUID = deviceUID; self.channelCount = channelCount
        reportedRoles = nil; reportedPositions = nil
    }

    init(topology: SpeakerTopology) throws {
        try topology.validate()
        deviceUID = topology.deviceUID
        channelCount = topology.declaredChannelCount
        reportedRoles = topology.hardwareRoles
        reportedPositions = topology.hardwarePositions
    }
}
