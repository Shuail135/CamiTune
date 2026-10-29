import CamiTuneDomain
import Foundation

/// Offline adjustments to generic HRIRs. Spectral detail and interaural timing
/// have separate controls; neither is a measurement of the listener's anatomy.
package enum PersonalHRTFAdjustment {
    package static func apply(_ pair: HRIRPair, tuning: PersonalHRTFTuning, rate: Double) throws -> HRIRPair {
        try tuning.validate()
        guard tuning != PersonalHRTFTuning() else { return pair }
        guard rate.isFinite, rate >= 8_000, !pair.left.isEmpty, !pair.right.isEmpty,
              pair.left.allSatisfy(\.isFinite), pair.right.allSatisfy(\.isFinite) else {
            throw BinauralConvolutionError.invalidImpulseResponse
        }
        var result = pair
        if tuning.strength != 1 || tuning.earSize != 1 {
            result.left = try shape(pair.left, tuning: tuning, rate: rate)
            result.right = try shape(pair.right, tuning: tuning, rate: rate)
        }
        if tuning.headSize != 1 {
            let left = onset(pair.left, rate: rate) + pair.leftDelaySeconds
            let right = onset(pair.right, rate: rate) + pair.rightDelaySeconds
            let change = (right - left) * Double(tuning.headSize - 1)
            // Delay one ear instead of advancing/truncating a measured response.
            // The added common component is acoustic timing, not a new buffer.
            result.leftDelaySeconds += max(0, -change)
            result.rightDelaySeconds += max(0, change)
        }
        return result
    }

    /// Low/mid-frequency onset avoids treating a pinna notch as a head delay.
    /// The threshold is relative to each response, so ILD does not become ITD.
    package static func onset(_ samples: [Float], rate: Double) -> Double {
        let upper = Float(1 - exp(-2 * .pi * 3000 / rate))
        let lower = Float(1 - exp(-2 * .pi * 300 / rate))
        var high: Float = 0, low: Float = 0
        let envelope = samples.map { sample -> Float in
            high += upper * (sample - high)
            low += lower * (high - low)
            return abs(high - low)
        }
        let threshold = (envelope.max() ?? 0) * 0.03162278
        guard threshold > 0, let index = envelope.firstIndex(where: { $0 >= threshold }) else { return 0 }
        guard index > 0 else { return 0 }
        let fraction = (threshold - envelope[index - 1]) / (envelope[index] - envelope[index - 1])
        return (Double(index - 1) + Double(fraction)) / rate
    }

    private static func shape(_ samples: [Float], tuning: PersonalHRTFTuning, rate: Double) throws -> [Float] {
        let filterFrames = Int(ceil(rate * 0.006))
        let fft = try AcousticFFT(minimumSize: max(samples.count + filterFrames, Int(ceil(rate / 24))))
        let count = fft.size, half = count / 2
        var real = samples + [Float](repeating: 0, count: count - samples.count)
        var imaginary = [Float](repeating: 0, count: count)
        fft.transform(real: &real, imaginary: &imaginary)
        let originalReal = real, originalImaginary = imaginary
        let magnitudes = (0...half).map { 0.5 * log(max(1e-12, real[$0] * real[$0] + imaginary[$0] * imaginary[$0])) }
        var sums = [Float](repeating: 0, count: half + 2)
        for i in magnitudes.indices { sums[i + 1] = sums[i] + magnitudes[i] }
        // The octave-smoothed envelope retains broad head-shadow coloration.
        // Above 2–4 kHz, shift the measured spectrum and scale its detail
        // relative to this reference; bass and lower midrange remain unchanged.
        let envelope = magnitudes.indices.map { i -> Float in
            let lower = max(0, Int(Double(i) / sqrt(2)))
            let upper = min(half, max(lower, Int(Double(i) * sqrt(2))))
            return (sums[upper + 1] - sums[lower]) / Float(upper - lower + 1)
        }
        real = .init(repeating: 0, count: count)
        imaginary = real
        for i in 1...half {
            let frequency = Double(i) * rate / Double(count)
            let position = min(Float(half), Float(i) * tuning.earSize)
            let lower = Int(position), upper = min(half, lower + 1)
            let shifted = magnitudes[lower] + (magnitudes[upper] - magnitudes[lower]) * (position - Float(lower))
            let blend = Float(max(0, min(1, (frequency - 2000) / 2000)))
            let weight = blend * blend * (3 - 2 * blend)
            let target = envelope[i] + tuning.strength * (shifted - envelope[i])
            let correction = weight * (target - magnitudes[i])
            real[i] = max(-log(2), min(log(2), correction))
            if i < half { real[count - i] = real[i] }
        }
        // A bounded minimum-phase correction preserves the original measured
        // waveform/phase beneath it. Both ears keep the same unit-DC reference.
        fft.transform(real: &real, imaginary: &imaginary, inverse: true)
        for i in 1..<half { real[i] *= 2 }
        for i in (half + 1)..<count { real[i] = 0 }
        imaginary = .init(repeating: 0, count: count)
        fft.transform(real: &real, imaginary: &imaginary)
        for i in real.indices {
            let magnitude = exp(real[i]), phase = imaginary[i]
            real[i] = magnitude * cos(phase)
            imaginary[i] = magnitude * sin(phase)
        }
        fft.transform(real: &real, imaginary: &imaginary, inverse: true)
        for i in filterFrames..<count { real[i] = 0 }
        for i in 0..<filterFrames {
            let tail = max(0, (Double(i) / Double(filterFrames - 1) - 0.75) / 0.25)
            real[i] *= Float(0.5 + 0.5 * cos(.pi * tail))
        }
        let dc = real.reduce(0, +)
        guard dc.isFinite, dc > 0 else { throw BinauralConvolutionError.invalidImpulseResponse }
        for i in 0..<filterFrames { real[i] /= dc }
        imaginary = .init(repeating: 0, count: count)
        fft.transform(real: &real, imaginary: &imaginary)
        for i in real.indices {
            let r = real[i], j = imaginary[i]
            real[i] = originalReal[i] * r - originalImaginary[i] * j
            imaginary[i] = originalReal[i] * j + originalImaginary[i] * r
        }
        fft.transform(real: &real, imaginary: &imaginary, inverse: true)
        let result = Array(real.prefix(samples.count + filterFrames - 1))
        guard result.allSatisfy(\.isFinite) else { throw BinauralConvolutionError.invalidImpulseResponse }
        return result
    }
}
