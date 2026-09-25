import Foundation

package struct SpeakerVerificationRecord: Codable, Hashable, Sendable {
    package struct Assignment: Codable, Hashable, Sendable {
        package init(id: PhysicalOutputID, role: ChannelRole, function: SpeakerFunction) {
            self.id = id
            self.role = role
            self.function = function
        }

        package var id: PhysicalOutputID
        package var role: ChannelRole
        package var function: SpeakerFunction
    }
    package var completedAt = Date()
    package var simulated: Bool
    package var hardware: HardwareTopologyFingerprint
    package var assignments: [Assignment]

    package init(topology: SpeakerTopology, simulated: Bool) throws {
        self.simulated = simulated
        hardware = try .init(topology: topology)
        assignments = Self.assignments(topology)
    }
    package func matches(_ topology: SpeakerTopology) -> Bool {
        hardware == (try? .init(topology: topology)) && assignments == Self.assignments(topology)
    }
    private static func assignments(_ topology: SpeakerTopology) -> [Assignment] {
        topology.endpoints.filter { $0.connectionState != .disabledByUser }.sorted { $0.id.channelIndex < $1.id.channelIndex }
            .map { Assignment(id: $0.id, role: $0.role, function: $0.function) }
    }
}
