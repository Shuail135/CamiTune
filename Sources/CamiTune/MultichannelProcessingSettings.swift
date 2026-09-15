import CoreAudio
import Foundation

/// Saved user intent. Intermediate bass/crossover buses are compiler-owned.
struct MultichannelProcessingSettings: Codable, Hashable, Sendable {
    var schemaVersion = 1
    var bass = BassManagementSettings()
    var routing = AdvancedRoutingSettings()
    var crossover = ActiveCrossoverSettings()
    var isEnabled: Bool { bass.enabled || routing.enabled || crossover.enabled }
}

enum CrossoverSlope: Int, Codable, Hashable, Sendable, CaseIterable {
    case lr24 = 24, lr48 = 48
    var title: String { "Linkwitz–Riley \(rawValue) dB/oct" }
    var sectionQs: [Double] {
        switch self {
        case .lr24: return [sqrt(0.5), sqrt(0.5)]
        case .lr48: return [0.541196100146197, 1.306562964876377, 0.541196100146197, 1.306562964876377]
        }
    }
}

struct BassManagedGroupSettings: Codable, Hashable, Sendable, Identifiable {
    var groupID: SpeakerGroupID
    var crossoverHz: Double = 80
    var slope: CrossoverSlope = .lr24
    var id: SpeakerGroupID { groupID }
}

struct SubwooferSettings: Codable, Hashable, Sendable {
    var gainDB: Double = 0
    var delayMilliseconds: Double = 0
    var inverted = false
}

struct BassManagementSettings: Codable, Hashable, Sendable {
    var enabled = false
    var groups: [BassManagedGroupSettings] = []
    /// Explicit unity trim by default; no implicit cinema +10 dB convention.
    var lfeGainDB: Double = 0
    var subwooferEndpointIDs: [PhysicalOutputID] = []
    var subwooferSettings: [PhysicalOutputID: SubwooferSettings] = [:]
}

enum RoutingSourceLayout: String, Codable, Hashable, Sendable, CaseIterable {
    case stereo, fivePointOne, sevenPointOne, fivePointOnePointFour, sevenPointOnePointFour, discrete
    var title: String {
        switch self {
        case .stereo: return "Stereo"
        case .fivePointOne: return "5.1"
        case .sevenPointOne: return "7.1"
        case .fivePointOnePointFour: return "5.1.4"
        case .sevenPointOnePointFour: return "7.1.4"
        case .discrete: return "Discrete channels"
        }
    }
    func layout(channelCount: Int) -> LPCMChannelLayout {
        switch self {
        case .stereo: return .stereo
        case .fivePointOne: return .fivePointOne
        case .sevenPointOne: return .sevenPointOne
        case .fivePointOnePointFour: return .fivePointOnePointFour
        case .sevenPointOnePointFour: return .sevenPointOnePointFour
        case .discrete:
            let count = min(32, max(1, channelCount))
            return LPCMChannelLayout(coreAudioTag: UInt32(kAudioChannelLayoutTag_DiscreteInOrder) | UInt32(count),
                roles: Array(repeating: .unknown, count: count))
        }
    }
}

struct SpeakerRoute: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var sourceChannel: Int
    var destination: PhysicalOutputID
    var gainDB: Double = 0
    var muted = false
    var inverted = false
}

struct AdvancedRoutingSettings: Codable, Hashable, Sendable {
    var enabled = false
    var sourceLayout: RoutingSourceLayout = .stereo
    var discreteChannelCount = 2
    var routes: [SpeakerRoute] = []
}

struct EndpointCrossover: Codable, Hashable, Sendable, Identifiable {
    var endpointID: PhysicalOutputID
    var highPassHz: Double?
    var lowPassHz: Double?
    var slope: CrossoverSlope = .lr24
    var id: PhysicalOutputID { endpointID }
}

struct EndpointProtection: Codable, Hashable, Sendable {
    var requiredHighPassHz: Double?
    var requiredHighPassSlope: CrossoverSlope = .lr24
    var limiterRequired = true
    var maximumGainDB: Double? = 0
}

struct ActiveCrossoverSettings: Codable, Hashable, Sendable {
    var enabled = false
    var endpoints: [EndpointCrossover] = []
    var protection: [PhysicalOutputID: EndpointProtection] = [:]
    /// Explicit acknowledgement of the physical map, never inferred on decode.
    var reviewedHardware: HardwareTopologyFingerprint?
}

struct MultichannelHistoryState: Equatable, Sendable {
    var settings: MultichannelProcessingSettings
    var topology: SpeakerTopology?
}

enum ActiveSpeakerPreset: Int, CaseIterable, Identifiable {
    case twoWay = 2, threeWay = 3
    var id: Int { rawValue }
    var title: String { "\(rawValue)-way stereo" }

    /// Starting values remain a draft until the hardware map is acknowledged.
    /// Physical calibration is retained by output ID.
    func applying(to profile: DeviceProfile) throws -> DeviceProfile {
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
    var usesSourceProcessingBus: Bool { hasPhysicalSpeakerRoute && multichannel.isEnabled }
    var configuredSpeakerEndpoints: [SpeakerEndpoint] {
        let ids = Set(configuredProcessingChannels.map(\.physicalOutputID))
        return (speakerTopology?.endpoints ?? []).filter { ids.contains($0.id) }.sorted { $0.id.channelIndex < $1.id.channelIndex }
    }
    var defaultBassManagement: BassManagementSettings {
        BassManagementSettings(groups: configuredSpeakerGroups.filter { $0.kind != .subwoofers && $0.kind != .custom }
            .map { BassManagedGroupSettings(groupID: $0.id) },
            subwooferEndpointIDs: configuredSpeakerEndpoints.filter { $0.function == .subwoofer }.map(\.id))
    }
    /// Presets and custom routes both resolve to these same physical routes.
    func defaultSpeakerRoutes(source: AudioFormatDescriptor) -> [SpeakerRoute] {
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
