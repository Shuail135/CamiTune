import CamiTuneDomain
import Foundation

/// Bilinear directional interpolation, aligning waveform peaks only while
/// interpolating and restoring each ear's interpolated delay afterward. Unlike
/// independent zero-time alignment, this preserves measured interaural timing.
package struct DirectionalHRTFGrid {
    private let pairs: [HRIRPair]
    private let peaks: [(Int, Int)]
    package init(pairs: [HRIRPair]) throws {
        guard pairs.count == 13 * 36, let first = pairs.first, !first.left.isEmpty,
              pairs.allSatisfy({ $0.left.count == first.left.count && $0.right.count == first.left.count &&
                  $0.left.allSatisfy(\.isFinite) && $0.right.allSatisfy(\.isFinite) }) else {
            throw BinauralConvolutionError.invalidImpulseResponse
        }
        self.pairs = pairs
        peaks = pairs.map { pair in
            (pair.left.indices.max { abs(pair.left[$0]) < abs(pair.left[$1]) }!,
             pair.right.indices.max { abs(pair.right[$0]) < abs(pair.right[$1]) }!)
        }
    }
    package func hrir(azimuth: Float, elevation: Float) throws -> HRIRPair {
        guard azimuth.isFinite, elevation.isFinite, (-90...90).contains(elevation) else {
            throw BinauralConvolutionError.invalidConfiguration
        }
        let x = Double((azimuth + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 10
        let y = Double(elevation + 90) / 15
        let x0 = Int(floor(x)), y0 = min(12, Int(floor(y))), y1 = min(12, y0 + 1)
        let fx = Float(x - floor(x)), fy = Float(y - floor(y))
        let indices = [y0 * 36 + x0, y0 * 36 + (x0 + 1) % 36,
                       y1 * 36 + x0, y1 * 36 + (x0 + 1) % 36]
        let weights = [(1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy]
        if let exact = weights.firstIndex(where: { $0 == 1 }) { return pairs[indices[exact]] }
        func interpolate(left: Bool) -> [Float] {
            let delay = zip(indices, weights).reduce(Float(0)) { $0 + Float(left ? peaks[$1.0].0 : peaks[$1.0].1) * $1.1 }
            let earliestPeak = indices.map { left ? peaks[$0].0 : peaks[$0].1 }.min()!
            let extensionFrames = max(0, Int(ceil(delay - Float(earliestPeak)))) + 2
            var output = [Float](repeating: 0, count: pairs[0].left.count + extensionFrames)
            for (index, weight) in zip(indices, weights) where weight > 0 {
                let ir = left ? pairs[index].left : pairs[index].right
                let peak = left ? peaks[index].0 : peaks[index].1
                for n in output.indices {
                    let position = Float(n) + Float(peak) - delay
                    let lower = Int(floor(position)), fraction = position - floor(position)
                    let a: Float = ir.indices.contains(lower) ? ir[lower] : 0
                    let b: Float = ir.indices.contains(lower + 1) ? ir[lower + 1] : 0
                    output[n] += weight * (a + fraction * (b - a))
                }
            }
            return output
        }
        return .init(left: interpolate(left: true), right: interpolate(left: false))
    }
}
