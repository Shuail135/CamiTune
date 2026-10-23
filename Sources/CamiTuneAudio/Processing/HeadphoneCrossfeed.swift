import CamiTuneDomain
import Foundation

/// Writer-owned stereo crossfeed. Natural uses a complementary first-order
/// network: C = g H, D = 1 - g H, where g = ratio / (1 + ratio).
/// D + C = 1 preserves mono, while D - C is a low shelf with no steady-state
/// boost. The bilinear low-pass reaches zero at Nyquist. Its phase supplies
/// the interaural timing; no block buffering or extra delay is needed.
///
/// Classic retains the old low-pass/delay blend, normalized by 1 + ratio.
/// Both paths stay warm. Parameter and bypass ramps finish in 20 ms and are
/// independent of packet boundaries. No allocation occurs in the sample loop.
package final class HeadphoneCrossfeed {
    package init() {}

    private var rate: Double = 0
    private var previousLeft = 0.0, previousRight = 0.0
    private var lowLeft = 0.0, lowRight = 0.0
    private var delayLeft: [Double] = [], delayRight: [Double] = []
    private var cursor = 0
    private var amount = Ramp(), pole = Ramp(), delay = Ramp(), classic = Ramp()

    package func reset() {
        rate = 0
        previousLeft = 0; previousRight = 0; lowLeft = 0; lowRight = 0
        cursor = 0
        amount = Ramp(); pole = Ramp(); delay = Ramp(); classic = Ramp()
    }

    package func process(_ samples: inout [Float], sampleRate: Double, settings: CrossfeedProcessor?) {
        guard !samples.isEmpty, samples.count.isMultiple(of: 2),
              sampleRate.isFinite, (8_000...384_000).contains(sampleRate) else { return }
        guard settings != nil || amount.current != 0 else {
            reset()
            return
        }
        let valid = settings.flatMap { (try? $0.validate(sampleRate: sampleRate)) != nil ? $0 : nil }
        if rate != sampleRate {
            reset()
            rate = sampleRate
            // Two spare samples cover zero delay and fractional interpolation.
            let capacity = Int(ceil(rate * 0.005)) + 2
            delayLeft = .init(repeating: 0, count: capacity)
            delayRight = .init(repeating: 0, count: capacity)
            let initial = valid ?? .standard
            pole = Ramp(value: Self.pole(frequency: initial.cutoffFrequency, rate: rate))
            delay = Ramp(value: initial.delayMilliseconds * rate / 1000)
            classic = Ramp(value: initial.model == .classic ? 1 : 0)
        }
        let rampFrames = max(1, Int(rate * 0.02))
        if let valid {
            let ratio = valid.crossfeedCoefficient
            amount.set(ratio / (1 + ratio), frames: rampFrames)
            pole.set(Self.pole(frequency: valid.cutoffFrequency, rate: rate), frames: rampFrames)
            delay.set(valid.delayMilliseconds * rate / 1000, frames: rampFrames)
            classic.set(valid.model == .classic ? 1 : 0, frames: rampFrames)
        } else {
            amount.set(0, frames: rampFrames)
        }

        for index in stride(from: 0, to: samples.count, by: 2) {
            let left = Double(SpatialSafety.sample(samples[index]))
            let right = Double(SpatialSafety.sample(samples[index + 1]))
            let a = pole.next(), b = (1 - a) * 0.5
            lowLeft = b * (left + previousLeft) + a * lowLeft
            lowRight = b * (right + previousRight) + a * lowRight
            previousLeft = left; previousRight = right
            if abs(lowLeft) < 1e-30 { lowLeft = 0 }
            if abs(lowRight) < 1e-30 { lowRight = 0 }
            delayLeft[cursor] = lowLeft; delayRight[cursor] = lowRight
            let frames = delay.next()
            let whole = Int(frames), fraction = frames - Double(whole)
            let recent = (cursor - whole + delayLeft.count) % delayLeft.count
            let older = (recent - 1 + delayLeft.count) % delayLeft.count
            let delayedLeft = delayLeft[recent] + fraction * (delayLeft[older] - delayLeft[recent])
            let delayedRight = delayRight[recent] + fraction * (delayRight[older] - delayRight[recent])
            cursor = (cursor + 1) % delayLeft.count
            let g = amount.next(), model = classic.next()
            let difference = lowRight - lowLeft
            samples[index] = Float(left + g * ((1 - model) * difference + model * (delayedRight - left)))
            samples[index + 1] = Float(right + g * (-(1 - model) * difference + model * (delayedLeft - right)))
        }
    }

    private static func pole(frequency: Double, rate: Double) -> Double {
        let k = tan(.pi * frequency / rate)
        return (1 - k) / (1 + k)
    }

    private struct Ramp {
        var current: Double
        private var target: Double
        private var step = 0.0
        private var remaining = 0

        init(value: Double = 0) { current = value; target = value }

        mutating func set(_ value: Double, frames: Int) {
            guard value != target else { return }
            target = value
            remaining = frames
            step = (target - current) / Double(frames)
        }

        mutating func next() -> Double {
            if remaining > 0 {
                remaining -= 1
                current = remaining == 0 ? target : current + step
            }
            return current
        }
    }
}
