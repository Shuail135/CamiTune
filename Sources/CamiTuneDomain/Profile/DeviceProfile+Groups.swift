import Foundation

/// Content processing shared by a group. Physical calibration stays on each output.

extension DeviceProfile {
    /// Standard groups follow assignments; custom memberships retain physical IDs.
    /// Missing legacy groups are derived without rewriting a saved profile.
    package var configuredSpeakerGroups: [SpeakerGroup] {
        guard hasPhysicalSpeakerRoute, let topology = speakerTopology else { return [] }
        let configuredIDs = Set(configuredProcessingChannels.map(\.physicalOutputID))
        let endpoints = topology.endpoints.filter { configuredIDs.contains($0.id) }
        var groups = SpeakerGroup.standardGroups(for: endpoints)
        groups += topology.groups.filter { $0.kind == .custom }.compactMap { group in
            var group = group
            group.members = group.members.filter { configuredIDs.contains($0) }.sorted { $0.channelIndex < $1.channelIndex }
            return group.members.isEmpty ? nil : group
        }
        let grouped = Set(groups.flatMap(\.members))
        let remaining = configuredProcessingChannels.map(\.physicalOutputID).filter { !grouped.contains($0) }
        if !remaining.isEmpty {
            groups.append(SpeakerGroup(id: .init(rawValue: "standard:other"), name: "Other speakers",
                kind: .custom, members: remaining))
        }
        return groups
    }

    package var usesGroupedProcessingPresentation: Bool { hasPhysicalSpeakerRoute && configuredProcessingChannels.count > 2 }

    package mutating func setGroupProcessing(id: SpeakerGroupID, settings: ChannelProcessingSettings) throws {
        guard configuredSpeakerGroups.contains(where: { $0.id == id }) else {
            throw SpeakerTopologyError.invalidGroup(id.rawValue)
        }
        var updated = try resolvedProcessing()
        updated.setGroupProcessing(id: id, settings: settings)
        replaceProcessing(updated)
    }
}
