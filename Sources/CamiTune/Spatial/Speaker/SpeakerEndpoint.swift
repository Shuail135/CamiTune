import Foundation

enum SpeakerLayer: String, Codable, Sendable {
    case floor, height, subwoofer, custom
}

enum SpeakerPositionSource: String, Codable, Sendable {
    case coreAudioMetadata, standardLayoutDefault, userPlacement, acousticEstimate, unknown
}

enum SpeakerConnectionState: String, Codable, Sendable {
    case unknown, acousticallyDetected, confirmedByUser, silent, disabledByUser
}

struct SpeakerEndpoint: Codable, Hashable, Sendable, Identifiable {
    var id: PhysicalOutputID
    var role: ChannelRole = .unknown
    var position: SpatialPosition?
    var positionSource: SpeakerPositionSource = .unknown
    var layer: SpeakerLayer = .custom
    var displayName: String
    var connectionState: SpeakerConnectionState = .unknown
    var usableLowFrequencyHz: Float?
    var usableHighFrequencyHz: Float?
    var function: SpeakerFunction = .fullRange
    var roleOrigin: SpeakerAssignmentOrigin = .user
    /// Read only as part of legacy topology migration. Membership now lives in groups.
    var groupID: String?

    /// Compatibility for the existing renderer and identification-signal code.
    var isSubwooferLike: Bool {
        get { function == .subwoofer }
        set { function = newValue ? .subwoofer : .fullRange }
    }

    init(id: PhysicalOutputID, role: ChannelRole = .unknown, position: SpatialPosition? = nil,
         positionSource: SpeakerPositionSource = .unknown, layer: SpeakerLayer = .custom,
         displayName: String, connectionState: SpeakerConnectionState = .unknown,
         usableLowFrequencyHz: Float? = nil, usableHighFrequencyHz: Float? = nil,
         isSubwooferLike: Bool = false, groupID: String? = nil,
         function: SpeakerFunction? = nil, roleOrigin: SpeakerAssignmentOrigin = .user) {
        self.id = id; self.role = role; self.position = position
        self.positionSource = positionSource; self.layer = layer; self.displayName = displayName
        self.connectionState = connectionState
        self.usableLowFrequencyHz = usableLowFrequencyHz; self.usableHighFrequencyHz = usableHighFrequencyHz
        self.function = function ?? (isSubwooferLike ? .subwoofer : .fullRange)
        self.groupID = groupID; self.roleOrigin = roleOrigin
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, position, positionSource, layer, displayName, connectionState
        case usableLowFrequencyHz, usableHighFrequencyHz, function, isSubwooferLike, groupID, roleOrigin
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(PhysicalOutputID.self, forKey: .id)
        role = try values.decodeIfPresent(ChannelRole.self, forKey: .role) ?? .unknown
        position = try values.decodeIfPresent(SpatialPosition.self, forKey: .position)
        positionSource = try values.decodeIfPresent(SpeakerPositionSource.self, forKey: .positionSource) ?? .unknown
        layer = try values.decodeIfPresent(SpeakerLayer.self, forKey: .layer) ?? .custom
        displayName = try values.decode(String.self, forKey: .displayName)
        connectionState = try values.decodeIfPresent(SpeakerConnectionState.self, forKey: .connectionState) ?? .unknown
        usableLowFrequencyHz = try values.decodeIfPresent(Float.self, forKey: .usableLowFrequencyHz)
        usableHighFrequencyHz = try values.decodeIfPresent(Float.self, forKey: .usableHighFrequencyHz)
        function = try values.decodeIfPresent(SpeakerFunction.self, forKey: .function)
            ?? (((values.decodeIfPresent(Bool.self, forKey: .isSubwooferLike) ?? false) || layer == .subwoofer) ? .subwoofer : .fullRange)
        groupID = try values.decodeIfPresent(String.self, forKey: .groupID)
        roleOrigin = try values.decodeIfPresent(SpeakerAssignmentOrigin.self, forKey: .roleOrigin) ?? .user
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(role, forKey: .role)
        try values.encodeIfPresent(position, forKey: .position)
        try values.encode(positionSource, forKey: .positionSource)
        try values.encode(layer, forKey: .layer)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(connectionState, forKey: .connectionState)
        try values.encodeIfPresent(usableLowFrequencyHz, forKey: .usableLowFrequencyHz)
        try values.encodeIfPresent(usableHighFrequencyHz, forKey: .usableHighFrequencyHz)
        try values.encode(function, forKey: .function)
        try values.encode(roleOrigin, forKey: .roleOrigin)
        try values.encodeIfPresent(groupID, forKey: .groupID)
    }
}
