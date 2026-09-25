import Foundation

/// Stable all-pass section. Storage is allocated only when the sample rate changes.
package struct SpatialAllPass {
    package init() {}

    private var delay: [Float] = []
    private var cursor = 0
    private let feedback: Float = 0.35
    package mutating func prepare(rate: Double, milliseconds: Double) {
        delay = .init(repeating: 0, count: max(1, Int(rate * milliseconds / 1000)))
        cursor = 0
    }
    package mutating func reset() {
        for index in delay.indices { delay[index] = 0 }
        cursor = 0
    }
    package mutating func process(_ input: Float) -> Float {
        guard !delay.isEmpty else { return input }
        let output = delay[cursor] - feedback * input
        delay[cursor] = SpatialSafety.sample(input + feedback * output)
        cursor += 1
        if cursor == delay.count { cursor = 0 }
        return output.isFinite ? output : 0
    }
}

package struct StereoDecorrelator {
    package init() {}

    private var left = SpatialAllPass()
    private var right = SpatialAllPass()
    package mutating func prepare(sampleRate: Double, depth: Double = 1) {
        left.prepare(rate: sampleRate, milliseconds: 1.7 * depth)
        right.prepare(rate: sampleRate, milliseconds: 2.9 * depth)
    }
    package mutating func reset() { left.reset(); right.reset() }
    package mutating func process(_ input: Float) -> (Float, Float) {
        (left.process(input), right.process(input))
    }
}
