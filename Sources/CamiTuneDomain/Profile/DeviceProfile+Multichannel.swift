import Foundation

/// Saved user intent. Intermediate bass/crossover buses are compiler-owned.

package struct MultichannelHistoryState: Codable, Equatable, Sendable {
    package init(settings: MultichannelProcessingSettings, topology: SpeakerTopology? = nil) {
        self.settings = settings
        self.topology = topology
    }

    package var settings: MultichannelProcessingSettings
    package var topology: SpeakerTopology?
}

package enum ActiveSpeakerPreset: Int, CaseIterable, Identifiable {
    case twoWay = 2, threeWay = 3
    package var id: Int { rawValue }
    package var title: String { "\(rawValue)-way stereo" }

    /// Starting values remain a draft until the hardware map is acknowledged.
    /// Physical calibration is retained by output ID.
    package func applying(to profile: DeviceProfile) throws -> DeviceProfile {
        guard var topology = profile.speakerTopology, topology.endpoints.count >= rawValue * 2 else {
            throw ProfileSettingsError.runtime("This active stereo setup needs \(rawValue * 2) physical outputs.")
        }
        var result = profile
        var crossover = ActiveCrossoverSettings(enabled: true)
        let slots = topology.endpoints.indices.sorted { topology.endpoints[$0].id.channelIndex < topology.endpoints[$1].id.channelIndex }
        let functions: [SpeakerFunction] = self == .twoWay ? [.woofer, .tweeter] : [.woofer, .midrange, .tweeter]
        for (offset, index) in slots.enumerated() {
            guard offset < rawValue * 2 else { topology.endpoints[index].connectionState = .disabledByUser; continue }
            let function = functions[offset % rawValue]
            let role: ChannelRole = offset < rawValue ? .left : .right
            topology.endpoints[index].role = role
            topology.endpoints[index].roleOrigin = .user
            topology.endpoints[index].function = function
            topology.endpoints[index].displayName = "\(role.displayName) \(function.displayName.lowercased())"
            topology.endpoints[index].connectionState = .confirmedByUser
            let id = topology.endpoints[index].id
            let hp: Double? = function == .tweeter ? 2000 : (function == .midrange ? 300 : nil)
            let lp: Double? = function == .woofer ? (self == .threeWay ? 300 : 2000) : (function == .midrange ? 2000 : nil)
            crossover.endpoints.append(.init(endpointID: id, highPassHz: hp, lowPassHz: lp))
            crossover.protection[id] = .init(requiredHighPassHz: hp)
        }
        topology.layoutTemplateID = .custom
        topology.refreshStandardGroups()
        result.speakerTopology = topology
        result.multichannel.crossover = crossover
        result.multichannel.bass.enabled = false
        result.multichannel.routing.enabled = false
        return result
    }
}

extension DeviceProfile {
    package var hasSpeakersAndSubwoofer: Bool {
        let endpoints = configuredSpeakerEndpoints
        return hasPhysicalSpeakerRoute && endpoints.contains { $0.function == .subwoofer }
            && endpoints.contains { $0.function != .subwoofer }
    }
    package var usesSourceProcessingBus: Bool { hasPhysicalSpeakerRoute && multichannel.isEnabled }
    package var configuredSpeakerEndpoints: [SpeakerEndpoint] {
        let ids = Set(configuredProcessingChannels.map(\.physicalOutputID))
        return (speakerTopology?.endpoints ?? []).filter { ids.contains($0.id) }.sorted { $0.id.channelIndex < $1.id.channelIndex }
    }
    package var defaultBassManagement: BassManagementSettings {
        BassManagementSettings(groups: configuredSpeakerGroups.filter { $0.kind != .subwoofers && $0.kind != .custom }
            .map { BassManagedGroupSettings(groupID: $0.id) },
            subwooferEndpointIDs: configuredSpeakerEndpoints.filter { $0.function == .subwoofer }.map(\.id))
    }
    /// Presets and custom routes both resolve to these same physical routes.
    package func defaultSpeakerRoutes(source: AudioFormatDescriptor) -> [SpeakerRoute] {
        let endpoints = configuredSpeakerEndpoints
        return source.channels.enumerated().flatMap { index, channel in
            guard let role = channel.role, role != .unknown else { return [SpeakerRoute]() }
            let targets = endpoints.filter { $0.role == role }
            let gain = multichannel.crossover.enabled ? 0 : -10 * log10(Double(max(1, targets.count)))
            return targets.map { SpeakerRoute(id: SpeakerGroupID(rawValue: "route:\(index):\($0.id.channelIndex)").stageID("default"),
                sourceChannel: index, destination: $0.id, gainDB: gain) }
        }
    }
}
