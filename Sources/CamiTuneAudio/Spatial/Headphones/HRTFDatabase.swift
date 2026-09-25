import CamiTuneDomain
import Foundation

package struct HRTFDirection: Hashable, Sendable {
    package init(azimuthDegrees: Float, elevationDegrees: Float = 0, distanceMeters: Float = 1) {
        self.azimuthDegrees = azimuthDegrees
        self.elevationDegrees = elevationDegrees
        self.distanceMeters = distanceMeters
    }

    package var azimuthDegrees: Float
    package var elevationDegrees: Float = 0
    package var distanceMeters: Float = 1
}

package struct HRIRPair: Sendable {
    package init(left: [Float], right: [Float], leftDelaySeconds: Double = 0, rightDelaySeconds: Double = 0) {
        self.left = left
        self.right = right
        self.leftDelaySeconds = leftDelaySeconds
        self.rightDelaySeconds = rightDelaySeconds
    }

    package var left: [Float]
    package var right: [Float]
    package var leftDelaySeconds: Double = 0
    package var rightDelaySeconds: Double = 0
}

/// SOFA parsing, lookup and resampling belong behind this interface, off the
/// render worker. Dataset license/attribution is independent of loader licensing.
package protocol HRTFDatabase {
    var profileName: String { get }
    var supportedSampleRates: [Double] { get }
    func referenceDelayFrames(sampleRate: Double) -> Int
    func hrir(for direction: HRTFDirection, sampleRate: Double) throws -> HRIRPair
}

package struct BinauralSpeakerPosition: Hashable, Sendable {
    package init(role: ChannelRole, direction: HRTFDirection) {
        self.role = role
        self.direction = direction
    }

    package var role: ChannelRole
    package var direction: HRTFDirection
}

package struct VirtualSpeakerLayout: Sendable {
    package init(speakers: [BinauralSpeakerPosition]) {
        self.speakers = speakers
    }

    package var speakers: [BinauralSpeakerPosition]
    package static let cinema = VirtualSpeakerLayout(speakers: [
        .init(role: .left, direction: .init(azimuthDegrees: -30)),
        .init(role: .right, direction: .init(azimuthDegrees: 30)),
        .init(role: .center, direction: .init(azimuthDegrees: 0)),
        .init(role: .leftSurround, direction: .init(azimuthDegrees: -105)),
        .init(role: .rightSurround, direction: .init(azimuthDegrees: 105)),
        .init(role: .leftRearSurround, direction: .init(azimuthDegrees: -145)),
        .init(role: .rightRearSurround, direction: .init(azimuthDegrees: 145))
    ])
}
