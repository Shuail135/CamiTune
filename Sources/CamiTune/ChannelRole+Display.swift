import Foundation

extension ChannelRole {
    var groupName: String {
        switch self {
        case .left, .right: return "Front"
        case .center: return "Center"
        case .lowFrequencyEffects: return "Subwoofer"
        case .leftSurround, .rightSurround: return "Surround"
        case .leftRearSurround, .rightRearSurround: return "Rear"
        case .topFrontLeft: return "Height"
        case .topFrontRight: return "Height"
        case .topMiddleLeft: return "Height"
        case .topMiddleRight: return "Height"
        case .topRearLeft: return "Height"
        case .topRearRight: return "Height"
        case .topCenter: return "Height"
        case .frontLeftCenter: return "Front"
        case .frontRightCenter: return "Front"
        case .wideLeft: return "Front"
        case .wideRight: return "Front"
        case .unknown: return "Other"
        }
    }

    var displayName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .center: return "Center"
        case .lowFrequencyEffects: return "Low-frequency effects"
        case .leftSurround: return "Left surround"
        case .rightSurround: return "Right surround"
        case .leftRearSurround: return "Left rear surround"
        case .rightRearSurround: return "Right rear surround"
        case .topFrontLeft: return "Top front left"
        case .topFrontRight: return "Top front right"
        case .topMiddleLeft: return "Top middle left"
        case .topMiddleRight: return "Top middle right"
        case .topRearLeft: return "Top rear left"
        case .topRearRight: return "Top rear right"
        case .topCenter: return "Top center"
        case .frontLeftCenter: return "Front left center"
        case .frontRightCenter: return "Front right center"
        case .wideLeft: return "Wide left"
        case .wideRight: return "Wide right"
        case .unknown: return "Unknown"
        }
    }

    var shortName: String {
        switch self {
        case .left: return "L"
        case .right: return "R"
        case .center: return "C"
        case .lowFrequencyEffects: return "LFE"
        case .leftSurround: return "Ls"
        case .rightSurround: return "Rs"
        case .leftRearSurround: return "Lrs"
        case .rightRearSurround: return "Rrs"
        case .topFrontLeft: return "Tfl"
        case .topFrontRight: return "Tfr"
        case .topMiddleLeft: return "Tml"
        case .topMiddleRight: return "Tmr"
        case .topRearLeft: return "Trl"
        case .topRearRight: return "Trr"
        case .topCenter: return "Tc"
        case .frontLeftCenter: return "Lc"
        case .frontRightCenter: return "Rc"
        case .wideLeft: return "Lw"
        case .wideRight: return "Rw"
        case .unknown: return "?"
        }
    }
}
