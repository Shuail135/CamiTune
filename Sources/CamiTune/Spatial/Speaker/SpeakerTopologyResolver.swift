import CamiTuneDomain
import Foundation

struct SpeakerTopologyResolver {
    func resolve(deviceUID: String, sampleRate: Double, channelCount: Int,
                 channels: [SpeakerChannelDescription]) throws -> SpeakerTopology {
        guard (1...32).contains(channelCount) else {
            throw SpeakerTopologyError.unsupportedChannelCount(channelCount)
        }
        let endpoints = (0..<channelCount).map { index -> SpeakerEndpoint in
            let channel = index < channels.count ? channels[index] : SpeakerChannelDescription()
            return SpeakerEndpoint(id: PhysicalOutputID(deviceUID: deviceUID, channelIndex: index),
                role: channel.role, position: channel.position ?? StandardSpeakerPositions.position(for: channel.role),
                positionSource: channel.position != nil ? .coreAudioMetadata :
                    (StandardSpeakerPositions.position(for: channel.role) == nil ? .unknown : .standardLayoutDefault),
                layer: channel.role.speakerLayer,
                displayName: channel.name ?? (channel.role == .unknown ? "Channel \(index + 1)" : channel.role.displayName),
                function: channel.role == .lowFrequencyEffects ? .subwoofer : .fullRange,
                roleOrigin: channel.role == .unknown ? .user : .hardware)
        }
        var topology = SpeakerTopology(deviceUID: deviceUID, sampleRate: sampleRate,
                                       declaredChannelCount: channelCount, endpoints: endpoints)
        topology.hardwareRoles = endpoints.map(\.role)
        topology.hardwarePositions = (0..<channelCount).map { $0 < channels.count ? channels[$0].position : nil }
        topology.groups = SpeakerGroup.standardGroups(for: endpoints)
        try topology.validate()
        return topology
    }
}
