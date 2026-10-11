import Foundation

package enum RoomRecorderPositionCount: Int, CaseIterable, Sendable { case five = 5, nine = 9 }

package enum RoomMeasurementGeometry {
    package static func radius(for seat: SpatialSeatingCalibration?) -> Float {
        min(0.65, max(0.12, ((seat?.leftDistanceMeters ?? 1) + (seat?.rightDistanceMeters ?? 1)) * 0.10))
    }
    package static func recorderPositions(center: SpatialVector3, radius: Float,
                                          count: RoomRecorderPositionCount) -> [SpatialVector3] {
        // Use reproducible, tape-measure-friendly offsets in metres. Preserve
        // the exact main seat; never snap or move the user's listening position.
        let distance = radius.isFinite ? min(0.65, max(0.1, radius)) : 0.2
        let spacing = min(0.6, (distance * 10).rounded() / 10)
        let offsets: [(Float, Float)] = [(0, 0), (-1, 0), (1, 0), (0, 1), (0, -1)]
            + (count == .nine ? [(-1, 1), (1, 1), (-1, -1), (1, -1)] : [])
        return offsets.map { SpatialVector3(x: center.x + $0.0 * spacing,
            y: center.y + $0.1 * spacing, z: center.z) }
    }
    package static func suggestion(center: SpatialVector3, radius: Float, existing: [SpatialVector3]) -> SpatialVector3 {
        // Calibrated captures sample a volume around the listener, including
        // different heights. These are suggestions, never inferred room geometry.
        let radius = radius.isFinite ? min(0.65, max(0.3, radius)) : 0.4
        let candidates = [-1, 0, 1].flatMap { height in
            (0..<16).map { i in
                let angle = Float(i) * .pi / 8
                return SpatialVector3(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle),
                    z: center.z + Float(height) * min(0.3, radius * 0.7))
            }
        }
        return candidates.max { a, b in
            func distance(_ p: SpatialVector3) -> Float {
                existing.map { pow(p.x - $0.x, 2) + pow(p.y - $0.y, 2) + pow(p.z - $0.z, 2) }.min() ?? 0
            }
            return distance(a) < distance(b)
        } ?? center
    }
}

