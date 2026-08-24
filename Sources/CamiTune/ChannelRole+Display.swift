import Foundation

extension ChannelRole {
    var groupName: String {
        switch self {
        case .left, .right: return "Front"
        case .center: return "Center"
        case .lowFrequencyEffects: return "Subwoofer"
        case .leftSurround, .rightSurround: return "Surround"
        case .leftRearSurround, .rightRearSurround: return "Rear"
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
        case .unknown: return "?"
        }
    }
}
