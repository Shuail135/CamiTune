import Foundation

struct SpatialVector3: Hashable, Sendable {
    var x: Float
    var y: Float
    var z: Float
}

/// Listener coordinates: x right, y front/screen, z up. Negative azimuth is left.
struct SpatialPosition: Codable, Hashable, Sendable {
    var azimuthDegrees: Float
    var elevationDegrees: Float
    var distanceMeters: Float?

    var unitVector: SpatialVector3 {
        let azimuth = azimuthDegrees * .pi / 180
        let elevation = elevationDegrees * .pi / 180
        return SpatialVector3(
            x: sin(azimuth) * cos(elevation),
            y: cos(azimuth) * cos(elevation),
            z: sin(elevation)
        )
    }

    func validate() throws {
        guard azimuthDegrees.isFinite, (-180..<180).contains(azimuthDegrees),
              elevationDegrees.isFinite, (-90...90).contains(elevationDegrees),
              distanceMeters.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw SpeakerTopologyError.invalidPosition
        }
    }
}
