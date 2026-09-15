import Foundation

enum SpeakerTopologyError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case hardwareLayoutChanged
    case invalidDeviceUID
    case unsupportedChannelCount(Int)
    case invalidSampleRate
    case invalidChannelIndex(Int)
    case duplicateOutput(Int)
    case foreignDevice(PhysicalOutputID)
    case invalidPosition
    case invalidBandwidth(PhysicalOutputID)
    case invalidGroup(String)

    var errorDescription: String? {
        switch self {
        case .hardwareLayoutChanged: return "The device channel layout changed. Discover and check its channels again."
        case .invalidDeviceUID, .foreignDevice: return "The speaker map belongs to another output device. Discover this device's channels again."
        case .invalidSampleRate: return "The speaker map uses a different sample rate. Rediscover it at the profile's processing rate."
        case .unsupportedChannelCount(let count): return "This output has \(count) channels. CamiTune supports 1 through 32."
        case .unsupportedVersion: return "This speaker map uses an unsupported version. Discover the channels again."
        case .invalidChannelIndex, .duplicateOutput: return "The speaker map has invalid or duplicate physical channel indices."
        case .invalidPosition: return "Speaker positions must use finite angles and a positive distance when supplied."
        case .invalidBandwidth: return "The speaker's frequency limits are invalid."
        case .invalidGroup: return "A speaker group has an invalid identity or output assignment."
        }
    }

}

/// A physical endpoint is an independently addressable output channel.
/// It is not necessarily one visible enclosure or one driver.
/// Validate after decoding or editing and before using a topology for DSP.
struct SpeakerTopology: Codable, Hashable, Sendable {
    static let maximumOutputChannels = 32
    static let currentVersion = 2

    var version: Int = currentVersion
    var deviceUID: String
    var sampleRate: Double
    var declaredChannelCount: Int
    var endpoints: [SpeakerEndpoint]
    var hardwareRoles: [ChannelRole]? = nil
    var hardwarePositions: [SpatialPosition?]? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var groups: [SpeakerGroup] = []
    var layoutTemplateID: SpeakerLayoutTemplateID? = nil

    init(version: Int = Self.currentVersion, deviceUID: String, sampleRate: Double,
         declaredChannelCount: Int, endpoints: [SpeakerEndpoint], hardwareRoles: [ChannelRole]? = nil,
         hardwarePositions: [SpatialPosition?]? = nil, createdAt: Date = Date(), updatedAt: Date = Date(),
         groups: [SpeakerGroup] = [], layoutTemplateID: SpeakerLayoutTemplateID? = nil) {
        self.version = version; self.deviceUID = deviceUID; self.sampleRate = sampleRate
        self.declaredChannelCount = declaredChannelCount; self.endpoints = endpoints
        self.hardwareRoles = hardwareRoles; self.hardwarePositions = hardwarePositions
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.groups = groups; self.layoutTemplateID = layoutTemplateID
    }

    private enum CodingKeys: String, CodingKey {
        case version, deviceUID, sampleRate, declaredChannelCount, endpoints
        case hardwareRoles, hardwarePositions, createdAt, updatedAt, groups, layoutTemplateID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let savedVersion = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...Self.currentVersion).contains(savedVersion) else {
            throw SpeakerTopologyError.unsupportedVersion(savedVersion)
        }
        version = Self.currentVersion
        deviceUID = try values.decode(String.self, forKey: .deviceUID)
        sampleRate = try values.decode(Double.self, forKey: .sampleRate)
        declaredChannelCount = try values.decode(Int.self, forKey: .declaredChannelCount)
        endpoints = try values.decode([SpeakerEndpoint].self, forKey: .endpoints)
        hardwareRoles = try values.decodeIfPresent([ChannelRole].self, forKey: .hardwareRoles)
        hardwarePositions = try values.decodeIfPresent([SpatialPosition?].self, forKey: .hardwarePositions)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        groups = try values.decodeIfPresent([SpeakerGroup].self, forKey: .groups) ?? []
        layoutTemplateID = try values.decodeIfPresent(SpeakerLayoutTemplateID.self, forKey: .layoutTemplateID)
        if savedVersion == 1 {
            let legacyIDs = Set(endpoints.compactMap(\.groupID)).sorted()
            for legacyID in legacyIDs where !legacyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let id = SpeakerGroupID(rawValue: "legacy:\(legacyID)")
                if !groups.contains(where: { $0.id == id }) {
                    groups.append(SpeakerGroup(id: id, name: legacyID, kind: .custom,
                        members: endpoints.filter { $0.groupID == legacyID }.map(\.id)))
                }
            }
            for index in endpoints.indices { endpoints[index].groupID = nil }
        }
        try validate()
    }

    var activeEndpoints: [SpeakerEndpoint] {
        endpoints.filter { $0.connectionState == .acousticallyDetected }
    }

    func validateHardware(_ current: SpeakerTopology) throws {
        guard try HardwareTopologyReview(configured: self, detected: current) == .unchanged else {
            throw SpeakerTopologyError.hardwareLayoutChanged
        }
    }

    func validate() throws {
        guard version == Self.currentVersion else {
            throw SpeakerTopologyError.unsupportedVersion(version)
        }
        guard !deviceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeakerTopologyError.invalidDeviceUID
        }
        guard (1...Self.maximumOutputChannels).contains(declaredChannelCount) else {
            throw SpeakerTopologyError.unsupportedChannelCount(declaredChannelCount)
        }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw SpeakerTopologyError.invalidSampleRate
        }
        if let hardwareRoles, hardwareRoles.count != declaredChannelCount { throw SpeakerTopologyError.hardwareLayoutChanged }
        if let hardwarePositions {
            guard hardwarePositions.count == declaredChannelCount else { throw SpeakerTopologyError.hardwareLayoutChanged }
            for position in hardwarePositions { try position?.validate() }
        }
        var indices = Set<Int>()
        for endpoint in endpoints {
            try endpoint.id.validate()
            guard endpoint.id.deviceUID == deviceUID else {
                throw SpeakerTopologyError.foreignDevice(endpoint.id)
            }
            let index = endpoint.id.channelIndex
            guard index < declaredChannelCount else {
                throw SpeakerTopologyError.invalidChannelIndex(index)
            }
            guard indices.insert(index).inserted else {
                throw SpeakerTopologyError.duplicateOutput(index)
            }
            try endpoint.position?.validate()
            let low = endpoint.usableLowFrequencyHz
            let high = endpoint.usableHighFrequencyHz
            let ordered = low.flatMap { low in high.map { low <= $0 } } ?? true
            guard [low, high].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 > 0 }), ordered else {
                throw SpeakerTopologyError.invalidBandwidth(endpoint.id)
            }
        }
        let outputIDs = Set(endpoints.map(\.id))
        var groupIDs = Set<SpeakerGroupID>()
        for group in groups {
            guard !group.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  groupIDs.insert(group.id).inserted, !group.members.isEmpty,
                  Set(group.members).count == group.members.count,
                  group.members.allSatisfy({ outputIDs.contains($0) }) else {
                throw SpeakerTopologyError.invalidGroup(group.id.rawValue)
            }
        }
    }
}
