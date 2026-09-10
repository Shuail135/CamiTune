import Foundation

enum SpatialSafety {
    static func unit(_ value: Float) -> Float { value.isFinite ? min(1, max(0, value)) : 0 }
    static func sample(_ value: Float) -> Float {
        // Protect filter state from both non-finite and corrupt finite PCM.
        value.isFinite ? min(16, max(-16, value)) : 0
    }
}

struct SpatialScalarSmoother {
    private(set) var current: Float = 0
    private var coefficient: Float = 1
    mutating func prepare(sampleRate: Double, seconds: Double = 0.05) {
        coefficient = Float(1 - exp(-1 / (sampleRate * seconds)))
    }
    mutating func reset(to value: Float = 0) { current = value }
    mutating func next(_ target: Float) -> Float {
        current += coefficient * (target - current)
        return current
    }
}

struct SpatialLowPass {
    private var state: Float = 0
    private var coefficient: Float = 1
    mutating func prepare(rate: Double, cutoff: Double) {
        coefficient = Float(1 - exp(-2 * Double.pi * min(cutoff, rate * 0.45) / rate))
        reset()
    }
    mutating func reset() { state = 0 }
    mutating func process(_ input: Float) -> Float {
        state += coefficient * (input - state)
        if !state.isFinite { state = 0 }
        return state
    }
}

/// Linked instantaneous attack and slow release prevents per-block normalization
/// pumping. This is temporary local protection, before graph headroom integration.
struct SpatialPeakSafety {
    private(set) var gain: Float = 1
    private var release: Float = 0
    mutating func prepare(rate: Double) {
        release = Float(1 - exp(-1 / (rate * 0.2)))
        gain = 1
    }
    mutating func reset() { gain = 1 }
    mutating func process(_ left: Float, _ right: Float) -> (Float, Float) {
        let l = SpatialSafety.sample(left), r = SpatialSafety.sample(right)
        let peak = max(abs(l), abs(r))
        let target: Float = peak > 1 ? 1 / peak : 1
        gain = target < gain ? target : gain + release * (target - gain)
        return (l * gain, r * gain)
    }
}
