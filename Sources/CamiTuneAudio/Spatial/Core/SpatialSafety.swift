import Foundation

package enum SpatialSafety {

    package static func sample(_ value: Float) -> Float {
        // Protect filter state from both non-finite and corrupt finite PCM.
        value.isFinite ? min(16, max(-16, value)) : 0
    }
}

package struct SpatialScalarSmoother {
    package init() {}

    package private(set) var current: Float = 0
    private var coefficient: Float = 1
    package mutating func prepare(sampleRate: Double, seconds: Double = 0.05) {
        coefficient = Float(1 - exp(-1 / (sampleRate * seconds)))
    }
    package mutating func reset(to value: Float = 0) { current = value }
    package mutating func next(_ target: Float) -> Float {
        current += coefficient * (target - current)
        return current
    }
}

package struct SpatialLowPass {
    package init() {}

    private var state: Float = 0
    private var coefficient: Float = 1
    package mutating func prepare(rate: Double, cutoff: Double) {
        coefficient = Float(1 - exp(-2 * Double.pi * min(cutoff, rate * 0.45) / rate))
        reset()
    }
    package mutating func reset() { state = 0 }
    package mutating func process(_ input: Float) -> Float {
        state += coefficient * (input - state)
        if !state.isFinite { state = 0 }
        return state
    }
}

/// Linked instantaneous attack and slow release prevents per-block normalization
/// pumping. This is temporary local protection, before graph headroom integration.
package struct SpatialPeakSafety {
    package init() {}

    package private(set) var gain: Float = 1
    private var release: Float = 0
    package mutating func prepare(rate: Double) {
        release = Float(1 - exp(-1 / (rate * 0.2)))
        gain = 1
    }
    package mutating func reset() { gain = 1 }
    package mutating func process(_ left: Float, _ right: Float) -> (Float, Float) {
        let l = SpatialSafety.sample(left), r = SpatialSafety.sample(right)
        let peak = max(abs(l), abs(r))
        let target: Float = peak > 1 ? 1 / peak : 1
        gain = target < gain ? target : gain + release * (target - gain)
        return (l * gain, r * gain)
    }
}
