import Foundation

package struct SpatialVector3: Hashable, Sendable {
    package init(x: Float, y: Float, z: Float) { self.x = x; self.y = y; self.z = z }

    package var x: Float
    package var y: Float
    package var z: Float
}

/// Listener coordinates: x right, y front/screen, z up. Negative azimuth is left.
package struct SpatialPosition: Codable, Hashable, Sendable {
    package init(azimuthDegrees: Float, elevationDegrees: Float, distanceMeters: Float? = nil) {
        self.azimuthDegrees = azimuthDegrees; self.elevationDegrees = elevationDegrees; self.distanceMeters = distanceMeters
    }

    package var azimuthDegrees: Float
    package var elevationDegrees: Float
    package var distanceMeters: Float?

    package var unitVector: SpatialVector3 {
        let azimuth = azimuthDegrees * .pi / 180
        let elevation = elevationDegrees * .pi / 180
        return SpatialVector3(
            x: sin(azimuth) * cos(elevation),
            y: cos(azimuth) * cos(elevation),
            z: sin(elevation)
        )
    }

    package func validate() throws {
        guard azimuthDegrees.isFinite, (-180..<180).contains(azimuthDegrees),
              elevationDegrees.isFinite, (-90...90).contains(elevationDegrees),
              distanceMeters.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw SpeakerTopologyError.invalidPosition
        }
    }
}
