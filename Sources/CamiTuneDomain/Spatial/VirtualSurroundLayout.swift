import Foundation

package struct VirtualSpeakerPosition: Codable, Hashable, Sendable {
    package init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    package var x: Float
    /// Negative is in front of the listener; positive is behind.
    package var y: Float
    package var validated: Self {
        Self(x: x.isFinite ? max(-1, min(1, x)) : 0,
             y: y.isFinite ? max(-1, min(1, y)) : -0.8)
    }
}

package struct VirtualSurroundLayout: Codable, Hashable, Sendable {
    package init(positions: [ChannelRole: VirtualSpeakerPosition] = [:], upmixStereo: Bool = false) {
        self.positions = positions
        self.upmixStereo = upmixStereo
    }

    package static let roles: [ChannelRole] = [.left, .center, .right, .leftSurround, .rightSurround,
                                      .leftRearSurround, .rightRearSurround, .lowFrequencyEffects]
    package var positions: [ChannelRole: VirtualSpeakerPosition] = [:]
    package var upmixStereo = false
    package static let standard = Self()

    package func position(for role: ChannelRole) -> VirtualSpeakerPosition {
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

}
