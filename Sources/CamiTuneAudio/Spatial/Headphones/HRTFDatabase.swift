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
    func roomResponse(for role: ChannelRole, sampleRate: Double) throws -> HRIRPair
}

extension HRTFDatabase {
    package func roomResponse(for role: ChannelRole, sampleRate: Double) throws -> HRIRPair {
        throw PersonalSpatialError.measuredRoomUnavailable
    }
}
