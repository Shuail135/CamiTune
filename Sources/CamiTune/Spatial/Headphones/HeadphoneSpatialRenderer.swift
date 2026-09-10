import Foundation

/// Conservative direct/crossfeed branch and fallback for unavailable HRTF rates.
/// This does not claim discrete virtual front/side/rear localization.
final class HeadphoneSpatialRenderer: SpatialAudioRenderer {
    private var leftLow = SpatialLowPass()
    private var rightLow = SpatialLowPass()
    private var leftDelay: [Float] = []
    private var rightDelay: [Float] = []
    private var cursor = 0
    func prepare(sampleRate: Double) {
        leftLow.prepare(rate: sampleRate, cutoff: 1200)
        rightLow.prepare(rate: sampleRate, cutoff: 1200)
        leftDelay = .init(repeating: 0, count: max(1, Int(sampleRate * 0.00025)))
        rightDelay = .init(repeating: 0, count: leftDelay.count)
        cursor = 0
    }
    func reset() {
        leftLow.reset(); rightLow.reset()
        for i in leftDelay.indices { leftDelay[i] = 0; rightDelay[i] = 0 }
        cursor = 0
    }
    func process(left: Float, right: Float, amount: Float, cinema: Float) -> (Float, Float) {
        guard !leftDelay.isEmpty else { return (left, right) }
        let l = leftDelay[cursor], r = rightDelay[cursor]
        leftDelay[cursor] = leftLow.process(left)
        rightDelay[cursor] = rightLow.process(right)
        cursor = (cursor + 1) % leftDelay.count
        let crossfeed = amount * amount * (0.10 + cinema * 0.05)
        // Difference crossfeed leaves centred vocals and mono bass unchanged.
        return (left + crossfeed * (r - l), right + crossfeed * (l - r))
    }
}
