import Foundation

package enum ChannelRole: String, Codable, Hashable, Sendable, CaseIterable {
    case left
    case right
    case center
    case lowFrequencyEffects
    case leftSurround
    case rightSurround
    case leftRearSurround
    case rightRearSurround
    case topFrontLeft
    case topFrontRight
    case topMiddleLeft
    case topMiddleRight
    case topRearLeft
    case topRearRight
    case topCenter
    case frontLeftCenter
    case frontRightCenter
    case wideLeft
    case wideRight
    case unknown
}
