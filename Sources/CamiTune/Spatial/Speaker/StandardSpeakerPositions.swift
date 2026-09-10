import Foundation

extension ChannelRole {
    var speakerLayer: SpeakerLayer {
        switch self {
        case .lowFrequencyEffects: return .subwoofer
        case .topFrontLeft, .topFrontRight, .topMiddleLeft, .topMiddleRight,
             .topRearLeft, .topRearRight, .topCenter: return .height
        case .unknown: return .custom
        default: return .floor
        }
    }
}

enum StandardSpeakerPositions {
    static func position(for role: ChannelRole) -> SpatialPosition? {
        let azimuth: Float
        let elevation: Float = role.speakerLayer == .height ? 40 : 0
        switch role {
        case .left: azimuth = -30
        case .right: azimuth = 30
        case .center: azimuth = 0
        case .leftSurround: azimuth = -105
        case .rightSurround: azimuth = 105
        case .leftRearSurround: azimuth = -145
        case .rightRearSurround: azimuth = 145
        case .topFrontLeft: azimuth = -35
        case .topFrontRight: azimuth = 35
        case .topMiddleLeft: azimuth = -90
        case .topMiddleRight: azimuth = 90
        case .topRearLeft: azimuth = -135
        case .topRearRight: azimuth = 135
        case .topCenter: return SpatialPosition(azimuthDegrees: 0, elevationDegrees: 90)
        case .frontLeftCenter: azimuth = -15
        case .frontRightCenter: azimuth = 15
        case .wideLeft: azimuth = -60
        case .wideRight: azimuth = 60
        case .lowFrequencyEffects, .unknown: return nil
        }
        return SpatialPosition(azimuthDegrees: azimuth, elevationDegrees: elevation)
    }
}
