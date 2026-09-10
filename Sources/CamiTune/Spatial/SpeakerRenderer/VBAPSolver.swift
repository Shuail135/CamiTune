import Foundation

extension SpatialVector3 {
    func dot(_ b: Self) -> Float { x * b.x + y * b.y + z * b.z }
    func cross(_ b: Self) -> Self { Self(x: y * b.z - z * b.y, y: z * b.x - x * b.z, z: x * b.y - y * b.x) }
    static func - (a: Self, b: Self) -> Self { Self(x: a.x-b.x, y: a.y-b.y, z: a.z-b.z) }
}

/// Prepares nondegenerate convex-hull faces and adjacent floor pairs once.
struct VBAPSolver {
    private struct Face {
        var indices: [Int]
        var inverseRows: [SpatialVector3]
    }
    private var faces: [Face] = []
    private var pairs: [(Int, Int, Float)] = []
    private let vectors: [SpatialVector3]
    private let floor: [Int]

    init(positions: [SpatialPosition]) {
        vectors = positions.map(\.unitVector)
        floor = positions.indices.filter { abs(positions[$0].elevationDegrees) < 10 }
            .sorted { positions[$0].azimuthDegrees < positions[$1].azimuthDegrees }
        if floor.count >= 2 {
            for i in floor.indices {
                let a = floor[i], b = floor[(i + 1) % floor.count]
                let det = vectors[a].x * vectors[b].y - vectors[b].x * vectors[a].y
                let gap = (positions[b].azimuthDegrees - positions[a].azimuthDegrees + 360).truncatingRemainder(dividingBy: 360)
                if abs(det) > 0.0001, gap < 180 { pairs.append((a, b, det)) }
            }
        }
        guard vectors.count >= 3 else { return }
        for a in 0..<(vectors.count-2) {
            for b in (a+1)..<(vectors.count-1) {
                for c in (b+1)..<vectors.count {
                    let u = vectors[a], v = vectors[b], w = vectors[c]
                    let det = u.dot(v.cross(w))
                    guard abs(det) > 0.0001 else { continue }
                    let normal = (v-u).cross(w-u)
                    let distances = vectors.map { normal.dot($0-u) }
                    // Only hull faces, not overlapping interior triangles.
                    guard !distances.contains(where: { $0 > 0.0001 }) || !distances.contains(where: { $0 < -0.0001 }) else { continue }
                    func divided(_ x: SpatialVector3) -> SpatialVector3 { SpatialVector3(x: x.x/det, y: x.y/det, z: x.z/det) }
                    faces.append(Face(indices: [a,b,c], inverseRows: [divided(v.cross(w)), divided(w.cross(u)), divided(u.cross(v))]))
                }
            }
        }
    }

    func gains(for position: SpatialPosition) -> (gains: [Float], fallback: Bool) {
        let target = position.unitVector
        var gains = [Float](repeating: 0, count: vectors.count)
        guard !vectors.isEmpty else { return (gains, true) }
        if let exact = vectors.indices.first(where: { vectors[$0].dot(target) > 0.99999 }) {
            gains[exact] = 1; return (gains, false)
        }
        if abs(position.elevationDegrees) < 10 || faces.isEmpty {
            let pairTarget = faces.isEmpty
                ? SpatialPosition(azimuthDegrees: position.azimuthDegrees, elevationDegrees: 0).unitVector : target
            for (a,b,det) in pairs {
                let x = (pairTarget.x * vectors[b].y - vectors[b].x * pairTarget.y) / det
                let y = (vectors[a].x * pairTarget.y - pairTarget.x * vectors[a].y) / det
                if x >= -0.00001, y >= -0.00001, x*x+y*y > 0.000001 {
                    gains[a] = max(0,x); gains[b] = max(0,y)
                    return (normalized(gains), abs(position.elevationDegrees) >= 10)
                }
            }
        }
        for face in faces {
            let values = face.inverseRows.map { $0.dot(target) }
            if values.allSatisfy({ $0 >= -0.00001 }), values.contains(where: { $0 > 0.00001 }) {
                for i in 0..<3 { gains[face.indices[i]] = max(0,values[i]) }
                return (normalized(gains), false)
            }
        }
        let nearest = vectors.indices.max { vectors[$0].dot(target) < vectors[$1].dot(target) }!
        gains[nearest] = 1
        return (gains, true)
    }

    private func normalized(_ gains: [Float]) -> [Float] {
        let energy = sqrt(gains.reduce(0) { $0 + $1*$1 })
        return energy > 0 ? gains.map { $0 / energy } : gains
    }
}
