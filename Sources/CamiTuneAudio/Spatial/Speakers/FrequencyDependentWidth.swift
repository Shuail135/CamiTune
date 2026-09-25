import Foundation

/// The mid signal never enters this filter. Bass receives no side boost; the
/// complementary bands add at most 0.5, 1.0 and 1.5 dB respectively.
package struct FrequencyDependentWidth {
    package init() {}

    private var bass = SpatialLowPass()
    private var lowMid = SpatialLowPass()
    private var mid = SpatialLowPass()
    package mutating func prepare(sampleRate: Double) {
        bass.prepare(rate: sampleRate, cutoff: 120)
        lowMid.prepare(rate: sampleRate, cutoff: 400)
        mid.prepare(rate: sampleRate, cutoff: 2000)
    }
    package mutating func reset() { bass.reset(); lowMid.reset(); mid.reset() }
    package mutating func process(_ side: Float, amount: Float) -> Float {
        let b = bass.process(side), l = lowMid.process(side), m = mid.process(side)
        return side + amount * (0.059254 * (l - b) + 0.122018 * (m - l) + 0.188502 * (side - m))
    }
}
