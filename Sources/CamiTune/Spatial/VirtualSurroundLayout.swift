import CamiTuneDomain

extension VirtualSurroundLayout {
    static func label(_ role: ChannelRole) -> String {
        switch role {
        case .left: return "FL"
        case .right: return "FR"
        case .center: return "C"
        case .leftSurround: return "SL"
        case .rightSurround: return "SR"
        case .leftRearSurround: return "RL"
        case .rightRearSurround: return "RR"
        case .lowFrequencyEffects: return "LFE"
        default: return role.shortName
        }
    }
}
