import Foundation

struct BassManager {
    private var first = SpatialLowPass()
    private var second = SpatialLowPass()
    mutating func prepare(sampleRate: Double) {
        first.prepare(rate: sampleRate, cutoff: 100)
        second.prepare(rate: sampleRate, cutoff: 100)
    }
    mutating func reset() { first.reset(); second.reset() }
    mutating func process(_ sample: Float) -> Float { second.process(first.process(sample)) * 0.25 }
}

/// Semantic routing remains active even in forced Music mode: content policy
/// must never discard real center or surround channels.
final class MovieDownmixer {
    private var bass = BassManager()
    private var sideLeft = StereoDecorrelator()
    private var sideRight = StereoDecorrelator()
    private var rearLeft = StereoDecorrelator()
    private var rearRight = StereoDecorrelator()
    private var lowSL = SpatialLowPass(), lowSR = SpatialLowPass()
    private var lowRL = SpatialLowPass(), lowRR = SpatialLowPass()
    func prepare(sampleRate: Double) {
        bass.prepare(sampleRate: sampleRate)
        sideLeft.prepare(sampleRate: sampleRate, depth: 2.7)
        sideRight.prepare(sampleRate: sampleRate, depth: 3.1)
        rearLeft.prepare(sampleRate: sampleRate, depth: 4.9)
        rearRight.prepare(sampleRate: sampleRate, depth: 5.7)
        lowSL.prepare(rate: sampleRate, cutoff: 150)
        lowSR.prepare(rate: sampleRate, cutoff: 150)
        lowRL.prepare(rate: sampleRate, cutoff: 150)
        lowRR.prepare(rate: sampleRate, cutoff: 150)
    }
    func reset() {
        bass.reset(); sideLeft.reset(); sideRight.reset(); rearLeft.reset(); rearRight.reset()
        lowSL.reset(); lowSR.reset(); lowRL.reset(); lowRR.reset()
    }
    func process(source: UnsafeBufferPointer<Float>, offset: Int, map: SemanticChannelMapper,
                 surroundAmount: Float, dialogue: Float) -> (Float, Float) {
        let l = map.sample(map.left, source: source, offset: offset)
        let r = map.sample(map.right, source: source, offset: offset)
        let c = map.sample(map.center, source: source, offset: offset) * 0.70710678 * (1 + 0.12 * dialogue)
        let b = bass.process(map.sample(map.lfe, source: source, offset: offset))
        let sl = map.sample(map.sideLeft, source: source, offset: offset)
        let sr = map.sample(map.sideRight, source: source, offset: offset)
        let rl = map.sample(map.rearLeft, source: source, offset: offset)
        let rr = map.sample(map.rearRight, source: source, offset: offset)
        let sll = lowSL.process(sl), srl = lowSR.process(sr)
        let rll = lowRL.process(rl), rrl = lowRR.process(rr)
        let a = sideLeft.process(sl - sll), d = sideRight.process(sr - srl)
        let e = rearLeft.process(rl - rll), f = rearRight.process(rr - rrl)
        // Only the upper surround field receives decorrelation. Fronts have no delay.
        let wet = 0.35 * surroundAmount
        let leftSurround = sl + rl + wet * (a.0 + e.0 - (sl - sll) - (rl - rll))
        let rightSurround = sr + rr + wet * (d.1 + f.1 - (sr - srl) - (rr - rrl))
        return (l + c + b + 0.70710678 * leftSurround,
                r + c + b + 0.70710678 * rightSurround)
    }
}
