import Foundation

struct HRTFDirection: Hashable, Sendable {
    var azimuthDegrees: Float
    var elevationDegrees: Float = 0
    var distanceMeters: Float = 1
}

struct HRIRPair: Sendable {
    var left: [Float]
    var right: [Float]
    var leftDelaySeconds: Double = 0
    var rightDelaySeconds: Double = 0
}

/// SOFA parsing, lookup and resampling belong behind this interface, off the
/// render worker. Dataset license/attribution is independent of loader licensing.
protocol HRTFDatabase {
    func hrir(for direction: HRTFDirection, sampleRate: Double) throws -> HRIRPair
}

struct BinauralSpeakerPosition: Hashable, Sendable {
    var role: ChannelRole
    var direction: HRTFDirection
}

struct VirtualSpeakerLayout: Sendable {
    var speakers: [BinauralSpeakerPosition]
    static let cinema = VirtualSpeakerLayout(speakers: [
        .init(role: .left, direction: .init(azimuthDegrees: -30)),
        .init(role: .right, direction: .init(azimuthDegrees: 30)),
        .init(role: .center, direction: .init(azimuthDegrees: 0)),
        .init(role: .leftSurround, direction: .init(azimuthDegrees: -105)),
        .init(role: .rightSurround, direction: .init(azimuthDegrees: 105)),
        .init(role: .leftRearSurround, direction: .init(azimuthDegrees: -145)),
        .init(role: .rightRearSurround, direction: .init(azimuthDegrees: 145))
    ])
}
