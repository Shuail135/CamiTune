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
    var isSubwooferLike: Bool = false
    var groupID: String?
}
