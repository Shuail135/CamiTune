import Foundation

struct VirtualSpeakerPosition: Codable, Hashable, Sendable {
    var x: Float
    /// Negative is in front of the listener; positive is behind.
    var y: Float
    var validated: Self {
        Self(x: x.isFinite ? max(-1, min(1, x)) : 0,
             y: y.isFinite ? max(-1, min(1, y)) : -0.8)
    }
}

struct VirtualSurroundLayout: Codable, Hashable, Sendable {
    static let roles: [ChannelRole] = [.left, .center, .right, .leftSurround, .rightSurround,
                                      .leftRearSurround, .rightRearSurround, .lowFrequencyEffects]
    var positions: [ChannelRole: VirtualSpeakerPosition] = [:]
    var upmixStereo = false
    static let standard = Self()

    func position(for role: ChannelRole) -> VirtualSpeakerPosition {
        if let position = positions[role] { return position.validated }
        let degrees: Double
        switch role {
        case .left: degrees = -30
        case .right: degrees = 30
        case .center: degrees = 0
        case .leftSurround: degrees = -100
        case .rightSurround: degrees = 100
        case .leftRearSurround: degrees = -145
        case .rightRearSurround: degrees = 145
        case .lowFrequencyEffects: return .init(x: 0.70, y: -0.45)
        default: return .init(x: 0, y: 0)
        }
        let radians = degrees * .pi / 180
        return .init(x: Float(sin(radians)) * 0.8, y: -Float(cos(radians)) * 0.8)
    }

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
