import Foundation

/// Saved room geometry is independent of source positions. Size changes the
/// walls explicitly; source/listener edits must fit inside the resulting room.
package struct PersonalSpatialRoom: Codable, Hashable, Sendable {
    package var minimum = SpatialVector3(x: -4.5, y: -5.5, z: -1.2)
    package var maximum = SpatialVector3(x: 4.5, y: 5.5, z: 4.8)
    package var size: Float = 1
    package var earlyReflectionsDB: Float = 0
    package var diffusion: Float = 0.75
    package var decaySeconds: Float = 0.35
    package init() {}

    package var bounds: (minimum: SpatialVector3, maximum: SpatialVector3) {
        (.init(x: minimum.x * size, y: minimum.y * size, z: minimum.z),
         .init(x: maximum.x * size, y: maximum.y * size, z: minimum.z + (maximum.z - minimum.z) * size))
    }

    package func contains(_ point: SpatialVector3) -> Bool {
        let bounds = bounds
        let clearance: Float = 0.2499 // Float roundoff at a saved 25 cm boundary.
        return point.x >= bounds.minimum.x + clearance && point.x <= bounds.maximum.x - clearance
            && point.y >= bounds.minimum.y + clearance && point.y <= bounds.maximum.y - clearance
            && point.z >= bounds.minimum.z + clearance && point.z <= bounds.maximum.z - clearance
    }

    package func minimumSize(containing points: [SpatialVector3]) -> Float {
        var result: Float = 0.75
        for point in points {
            result = max(result, (0.25 - point.x) / -minimum.x, (point.x + 0.25) / maximum.x,
                (0.25 - point.y) / -minimum.y, (point.y + 0.25) / maximum.y,
                (point.z + 0.25 - minimum.z) / (maximum.z - minimum.z))
        }
        return ceil(result * 100 - 0.001) / 100
    }

    package func validate() throws {
        guard size.isFinite, (0.75...1.5).contains(size),
              earlyReflectionsDB.isFinite, (-12...3).contains(earlyReflectionsDB),
              diffusion.isFinite, (0...1).contains(diffusion),
              decaySeconds.isFinite, (0.15...0.8).contains(decaySeconds),
              [minimum.x, minimum.y, minimum.z, maximum.x, maximum.y, maximum.z].allSatisfy(\.isFinite),
              (-15 ... -0.5).contains(minimum.x), (-15 ... -0.5).contains(minimum.y),
              (-15 ... -0.5).contains(minimum.z), (0.5...15).contains(maximum.x),
              (0.5...15).contains(maximum.y), (0.5...15).contains(maximum.z) else {
            throw PersonalSpatialError.invalidRoom
        }
    }
}
