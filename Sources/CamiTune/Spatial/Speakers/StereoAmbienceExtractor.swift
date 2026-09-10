import Foundation

struct StereoAmbienceExtractor {
    private var low = SpatialLowPass()
    private var envelope: Float = 0
    private var release: Float = 0
    mutating func prepare(sampleRate: Double) {
        low.prepare(rate: sampleRate, cutoff: 300)
        release = Float(1 - exp(-1 / (sampleRate * 0.02)))
        envelope = 0
    }
    mutating func reset() { low.reset(); envelope = 0 }
    mutating func process(left: Float, right: Float) -> Float {
        let side = 0.5 * (left - right)
        let high = side - low.process(side)
        let peak = max(abs(left), abs(right))
        let onset = peak > max(0.001, envelope * 2)
        envelope += release * (peak - envelope)
        // Centre rejection is inherent in Side. Strong attacks stay direct.
        return high * (onset ? 0.35 : 1)
    }
}
