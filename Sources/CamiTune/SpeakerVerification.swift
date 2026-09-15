import Foundation

struct SpeakerVerificationRecord: Codable, Hashable, Sendable {
    struct Assignment: Codable, Hashable, Sendable {
        var id: PhysicalOutputID
        var role: ChannelRole
        var function: SpeakerFunction
    }
    var completedAt = Date()
    var simulated: Bool
    var hardware: HardwareTopologyFingerprint
    var assignments: [Assignment]

    init(topology: SpeakerTopology, simulated: Bool) throws {
        self.simulated = simulated
        hardware = try .init(topology: topology)
        assignments = Self.assignments(topology)
    }
    func matches(_ topology: SpeakerTopology) -> Bool {
        hardware == (try? .init(topology: topology)) && assignments == Self.assignments(topology)
    }
    private static func assignments(_ topology: SpeakerTopology) -> [Assignment] {
        topology.endpoints.filter { $0.connectionState != .disabledByUser }.sorted { $0.id.channelIndex < $1.id.channelIndex }
            .map { Assignment(id: $0.id, role: $0.role, function: $0.function) }
    }
}

struct SpeakerVerificationSession {
    var topology: SpeakerTopology
    private(set) var confirmed: Set<PhysicalOutputID> = []
    var outputs: [SpeakerEndpoint] {
        topology.endpoints.filter { $0.connectionState != .disabledByUser }.sorted { $0.id.channelIndex < $1.id.channelIndex }
    }
    var current: SpeakerEndpoint? { outputs.first { !confirmed.contains($0.id) } }
    var isComplete: Bool { !outputs.isEmpty && current == nil }

    mutating func confirm() {
        guard let current, let index = topology.endpoints.firstIndex(where: { $0.id == current.id }) else { return }
        confirmed.insert(current.id)
        topology.endpoints[index].connectionState = .confirmedByUser
    }

    mutating func correctAssignment(heard: PhysicalOutputID) throws {
        guard let current, heard != current.id,
              let a = topology.endpoints.firstIndex(where: { $0.id == current.id }),
              let b = topology.endpoints.firstIndex(where: { $0.id == heard }),
              topology.endpoints[b].connectionState != .disabledByUser else { throw SpeakerTopologyError.invalidDeviceUID }
        guard ![topology.endpoints[a].function, topology.endpoints[b].function].contains(where: { [.woofer, .midrange, .tweeter].contains($0) }) else {
            throw ProfileSettingsError.runtime("Active driver assignments must be reviewed together with their crossovers and protection.")
        }
        // Move speaker meaning; immutable physical IDs and the profile's separate
        // physical calibration chains remain on their actual hardware outputs.
        var first = topology.endpoints[a], second = topology.endpoints[b]
        first.id = heard; second.id = current.id
        first.roleOrigin = .user; second.roleOrigin = .user
        topology.endpoints[a] = second; topology.endpoints[b] = first
        topology.layoutTemplateID = .custom
        topology.refreshStandardGroups()
        confirmed.remove(current.id); confirmed.remove(heard)
    }
}
