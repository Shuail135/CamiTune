import CamiTuneDomain
import Foundation

/// Distances from each physical speaker to the listener, in metres. This is
/// arrival-time/level alignment, not generic crosstalk cancellation or room EQ.

package final class SpatialSeatAligner {
    package init() {}
    private var left: [Float] = []
    private var right: [Float] = []
    private var cursor = 0
    private var rate: Double = 0
    private var leftDelay = SpatialScalarSmoother(), rightDelay = SpatialScalarSmoother()
    private var leftGain = SpatialScalarSmoother(), rightGain = SpatialScalarSmoother()

    package func prepare(sampleRate: Double) {
        rate = sampleRate
        left = .init(repeating: 0, count: Int(ceil(sampleRate * 0.01)) + 2)
        right = .init(repeating: 0, count: left.count)
        leftDelay.prepare(sampleRate: rate); rightDelay.prepare(sampleRate: rate)
        leftGain.prepare(sampleRate: rate); rightGain.prepare(sampleRate: rate)
        reset()
    }
    package func reset() {
        for i in left.indices { left[i] = 0; right[i] = 0 }
        cursor = 0
        leftDelay.reset(); rightDelay.reset(); leftGain.reset(to: 1); rightGain.reset(to: 1)
    }
    package func process(_ l: Float, _ r: Float, alignment: (Double, Double, Float, Float)) -> (Float, Float) {
        guard !left.isEmpty else { return (l, r) }
        left[cursor] = l; right[cursor] = r
        let ld = leftDelay.next(Float(alignment.0 * rate))
        let rd = rightDelay.next(Float(alignment.1 * rate))
        let result = (read(left, delay: ld) * leftGain.next(alignment.2),
                      read(right, delay: rd) * rightGain.next(alignment.3))
        cursor = (cursor + 1) % left.count
        return result
    }
    private func read(_ buffer: [Float], delay: Float) -> Float {
        let whole = Int(delay), fraction = delay - Float(whole)
        let a = (cursor - whole + buffer.count) % buffer.count
        let b = (a - 1 + buffer.count) % buffer.count
        return buffer[a] + fraction * (buffer[b] - buffer[a])
    }
}
