import AudioToolbox
import Foundation

package struct MultichannelProcessingSettings: Codable, Hashable, Sendable {
    package init(
        schemaVersion: Int = 1,
        bass: BassManagementSettings = BassManagementSettings(),
        routing: AdvancedRoutingSettings = AdvancedRoutingSettings(),
        crossover: ActiveCrossoverSettings = ActiveCrossoverSettings(),
        subwooferControl: SubwooferControlSettings = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.bass = bass
        self.routing = routing
        self.crossover = crossover
        self.subwooferControl = subwooferControl
    }

    package var schemaVersion = 1
    package var bass = BassManagementSettings()
    package var routing = AdvancedRoutingSettings()
    package var crossover = ActiveCrossoverSettings()
    package var subwooferControl = SubwooferControlSettings()
    package var effectiveBass: BassManagementSettings {
        var value = bass
        if subwooferControl.mode == .mute { value.enabled = false }
        return value
    }
    package var isEnabled: Bool { effectiveBass.enabled || routing.enabled || crossover.enabled }

    private enum CodingKeys: String, CodingKey { case schemaVersion, bass, routing, crossover, subwooferControl }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        bass = try values.decodeIfPresent(BassManagementSettings.self, forKey: .bass) ?? .init()
        routing = try values.decodeIfPresent(AdvancedRoutingSettings.self, forKey: .routing) ?? .init()
        crossover = try values.decodeIfPresent(ActiveCrossoverSettings.self, forKey: .crossover) ?? .init()
        subwooferControl = try values.decodeIfPresent(SubwooferControlSettings.self, forKey: .subwooferControl) ?? .init()
    }
}

package enum SubwooferControlMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, reduce, mute
    package var id: Self { self }
    package var title: String {
        switch self {
        case .standard: return "Default"
        case .reduce: return "Reduce"
        case .mute: return "Mute"
        }
    }
}

package struct SubwooferControlSettings: Codable, Hashable, Sendable {
    package static let reductionRangeDB: ClosedRange<Double> = 0...24
    package var mode: SubwooferControlMode = .standard
    package var reductionDB: Double = 6
    package init(mode: SubwooferControlMode = .standard, reductionDB: Double = 6) {
        self.mode = mode; self.reductionDB = reductionDB
    }
}

package enum CrossoverSlope: Int, Codable, Hashable, Sendable, CaseIterable {
    case lr24 = 24, lr48 = 48
    package var title: String { "Linkwitz–Riley \(rawValue) dB/oct" }
    package var sectionQs: [Double] {
        switch self {
        case .lr24: return [sqrt(0.5), sqrt(0.5)]
        case .lr48: return [0.541196100146197, 1.306562964876377, 0.541196100146197, 1.306562964876377]
        }
    }
}

package struct BassManagedGroupSettings: Codable, Hashable, Sendable, Identifiable {
    package init(groupID: SpeakerGroupID, crossoverHz: Double = 80, slope: CrossoverSlope = .lr24) {
        self.groupID = groupID
        self.crossoverHz = crossoverHz
        self.slope = slope
    }

    package var groupID: SpeakerGroupID
    package var crossoverHz: Double = 80
    package var slope: CrossoverSlope = .lr24
    package var id: SpeakerGroupID { groupID }
}

package struct SubwooferSettings: Codable, Hashable, Sendable {
    package init(gainDB: Double = 0, delayMilliseconds: Double = 0, inverted: Bool = false) {
        self.gainDB = gainDB
        self.delayMilliseconds = delayMilliseconds
        self.inverted = inverted
    }

    package var gainDB: Double = 0
    package var delayMilliseconds: Double = 0
    package var inverted = false
}

package struct BassManagementSettings: Codable, Hashable, Sendable {
    package init(
        enabled: Bool = false,
        groups: [BassManagedGroupSettings] = [],
        lfeGainDB: Double = 0,
        subwooferEndpointIDs: [PhysicalOutputID] = [],
        subwooferSettings: [PhysicalOutputID: SubwooferSettings] = [:]
    ) {
        self.enabled = enabled
        self.groups = groups
        self.lfeGainDB = lfeGainDB
        self.subwooferEndpointIDs = subwooferEndpointIDs
        self.subwooferSettings = subwooferSettings
    }

    package var enabled = false
    package var groups: [BassManagedGroupSettings] = []
    /// Explicit unity trim by default; no implicit cinema +10 dB convention.
    package var lfeGainDB: Double = 0
    package var subwooferEndpointIDs: [PhysicalOutputID] = []
    package var subwooferSettings: [PhysicalOutputID: SubwooferSettings] = [:]
}

package enum RoutingSourceLayout: String, Codable, Hashable, Sendable, CaseIterable {
    case stereo, fivePointOne, sevenPointOne, fivePointOnePointFour, sevenPointOnePointFour, discrete
    package var title: String {
        switch self {
        case .stereo: return "Stereo"
        case .fivePointOne: return "5.1"
        case .sevenPointOne: return "7.1"
        case .fivePointOnePointFour: return "5.1.4"
        case .sevenPointOnePointFour: return "7.1.4"
        case .discrete: return "Discrete channels"
        }
    }
    package func layout(channelCount: Int) -> LPCMChannelLayout {
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

package struct SpeakerRoute: Codable, Hashable, Sendable, Identifiable {
    package init(
        id: UUID = UUID(),
        sourceChannel: Int,
        destination: PhysicalOutputID,
        gainDB: Double = 0,
        muted: Bool = false,
        inverted: Bool = false
    ) {
        self.id = id
        self.sourceChannel = sourceChannel
        self.destination = destination
        self.gainDB = gainDB
        self.muted = muted
        self.inverted = inverted
    }

    package var id: UUID = UUID()
    package var sourceChannel: Int
    package var destination: PhysicalOutputID
    package var gainDB: Double = 0
    package var muted = false
    package var inverted = false
}

package struct AdvancedRoutingSettings: Codable, Hashable, Sendable {
    package init(
        enabled: Bool = false,
        sourceLayout: RoutingSourceLayout = .stereo,
        discreteChannelCount: Int = 2,
        routes: [SpeakerRoute] = []
    ) {
        self.enabled = enabled
        self.sourceLayout = sourceLayout
        self.discreteChannelCount = discreteChannelCount
        self.routes = routes
    }

    package var enabled = false
    package var sourceLayout: RoutingSourceLayout = .stereo
    package var discreteChannelCount = 2
    package var routes: [SpeakerRoute] = []
}

package struct EndpointCrossover: Codable, Hashable, Sendable, Identifiable {
    package init(
        endpointID: PhysicalOutputID,
        highPassHz: Double? = nil,
        lowPassHz: Double? = nil,
        slope: CrossoverSlope = .lr24
    ) {
        self.endpointID = endpointID
        self.highPassHz = highPassHz
        self.lowPassHz = lowPassHz
        self.slope = slope
    }

    package var endpointID: PhysicalOutputID
    package var highPassHz: Double?
    package var lowPassHz: Double?
    package var slope: CrossoverSlope = .lr24
    package var id: PhysicalOutputID { endpointID }
}

package struct EndpointProtection: Codable, Hashable, Sendable {
    package init(
        requiredHighPassHz: Double? = nil,
        requiredHighPassSlope: CrossoverSlope = .lr24,
        limiterRequired: Bool = true,
        maximumGainDB: Double? = 0
    ) {
        self.requiredHighPassHz = requiredHighPassHz
        self.requiredHighPassSlope = requiredHighPassSlope
        self.limiterRequired = limiterRequired
        self.maximumGainDB = maximumGainDB
    }

    package var requiredHighPassHz: Double?
    package var requiredHighPassSlope: CrossoverSlope = .lr24
    package var limiterRequired = true
    package var maximumGainDB: Double? = 0
}

package struct ActiveCrossoverSettings: Codable, Hashable, Sendable {
    package init(
        enabled: Bool = false,
        endpoints: [EndpointCrossover] = [],
        protection: [PhysicalOutputID: EndpointProtection] = [:],
        reviewedHardware: HardwareTopologyFingerprint? = nil
    ) {
        self.enabled = enabled
        self.endpoints = endpoints
        self.protection = protection
        self.reviewedHardware = reviewedHardware
    }

    package var enabled = false
    package var endpoints: [EndpointCrossover] = []
    package var protection: [PhysicalOutputID: EndpointProtection] = [:]
    /// Explicit acknowledgement of the physical map, never inferred on decode.
    package var reviewedHardware: HardwareTopologyFingerprint?
}
