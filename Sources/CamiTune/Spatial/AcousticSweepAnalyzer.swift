import Accelerate
import Foundation

struct AcousticSweep: Sendable {
    let sampleRate: Double
    let duration: Double
    let reference: [Float]
    let clip: SpatialCalibrationClip
    var speakerSeparationSeconds: Double { duration + 1 }

    init(sampleRate: Double, duration: Double = 3) throws {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              duration.isFinite, (0.2...4).contains(duration) else { throw AcousticMeasurementError.invalidSignal }
        self.sampleRate = sampleRate
        self.duration = duration
        let low = 80.0
        let high = min(18_000, sampleRate * 0.42)
        let logarithm = log(high / low)
        let count = Int(sampleRate * duration)
        let fade = max(1, Int(sampleRate * 0.025))
        reference = (0..<count).map { index in
            let time = Double(index) / sampleRate
            let phase = 2 * Double.pi * low * duration / logarithm * (exp(time * logarithm / duration) - 1)
            let envelope = min(1, Double(min(index, count - 1 - index)) / Double(fade))
            return Float(sin(phase) * envelope * 0.03)
        }
        let leftStart = Int(sampleRate * 0.5)
        let rightStart = leftStart + Int(sampleRate * (duration + 1))
        var samples = [Float](repeating: 0, count: (rightStart + count + Int(sampleRate)) * 2)
        for index in reference.indices {
            samples[(leftStart + index) * 2] = reference[index]
            samples[(rightStart + index) * 2 + 1] = reference[index]
        }
        guard let clip = SpatialCalibrationClip(measurementSamples: samples, sampleRate: sampleRate) else {
            throw AcousticMeasurementError.invalidSignal
        }
        self.clip = clip
    }
}

struct AcousticRecording: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let discontinuity: Bool
}

/// Regularized sweep deconvolution and Welch coherence run after capture on a
/// utility task. Nothing here is called from a PCM or microphone callback.
struct AcousticSweepAnalyzer {
    func analyze(
        recording: AcousticRecording, sweep: AcousticSweep,
        position: AcousticMeasurementPosition, calibration: MicrophoneCalibrationCurve? = nil
    ) throws -> AcousticPositionMeasurement {
        guard !recording.discontinuity else { throw AcousticMeasurementError.captureFailed }
        guard recording.sampleRate.isFinite, (8_000...192_000).contains(recording.sampleRate),
              recording.samples.allSatisfy(\.isFinite), recording.samples.count <= Int(recording.sampleRate * 16) else {
            throw AcousticMeasurementError.captureFailed
        }
        guard Double(recording.samples.count) / recording.sampleRate >= 2 * sweep.duration + 1.5 else {
            throw AcousticMeasurementError.recordingTooShort
        }
        let clipped = recording.samples.filter { abs($0) >= 0.995 }.count
        guard Double(clipped) / Double(max(1, recording.samples.count)) < 0.0005 else {
            throw AcousticMeasurementError.clipped
        }
        let rate = min(48_000, recording.sampleRate, sweep.sampleRate)
        let captured = resample(recording.samples, from: recording.sampleRate, to: rate)
        let reference = resample(sweep.reference, from: sweep.sampleRate, to: rate)
        let noise = rms(captured.prefix(Int(rate * 0.15)))
        let impulse = try deconvolve(captured, reference: reference)
        try Task.checkCancellation()
        let firstRange = Int(rate * 0.15)..<min(impulse.count, Int(rate * min(2.5, sweep.speakerSeparationSeconds)))
        guard let leftPeak = strongest(in: impulse, range: firstRange) else { throw AcousticMeasurementError.unreliable }
        let predictedRight = leftPeak + Int(sweep.speakerSeparationSeconds * rate)
        let rightRange = max(0, predictedRight - Int(rate * 0.15))..<min(impulse.count, predictedRight + Int(rate * 0.15))
        guard let rightPeak = strongest(in: impulse, range: rightRange),
              leftPeak + reference.count < captured.count,
              rightPeak + reference.count < captured.count else { throw AcousticMeasurementError.recordingTooShort }
        let left = try response(captured: captured, reference: reference, impulse: impulse,
                                peak: leftPeak, noise: noise, rate: rate, calibration: calibration)
        let right = try response(captured: captured, reference: reference, impulse: impulse,
                                 peak: rightPeak, noise: noise, rate: rate, calibration: calibration)
        guard abs(right.levelDB - left.levelDB) < 18 else { throw AcousticMeasurementError.unreliable }
        return AcousticPositionMeasurement(
            position: position, left: left, right: right,
            rightMinusLeftArrivalMilliseconds: (Double(rightPeak - leftPeak) / rate - sweep.speakerSeparationSeconds) * 1_000
        )
    }

    private func response(
        captured: [Float], reference: [Float], impulse: [Float], peak: Int,
        noise: Double, rate: Double, calibration: MicrophoneCalibrationCurve?
    ) throws -> AcousticSpeakerResponse {
        let signal = Array(captured[peak..<(peak + reference.count)])
        let signalRMS = rms(signal)
        let snr = 20 * log10(max(1e-10, signalRMS) / max(1e-8, noise))
        guard snr >= 12, signalRMS > 0.00002 else { throw AcousticMeasurementError.tooQuiet }
        let points = try frequencyResponse(reference: reference, signal: signal, rate: rate, calibration: calibration)
        let coherence = points.map(\.coherence).reduce(0, +) / Double(max(1, points.count))
        guard coherence >= 0.35 else { throw AcousticMeasurementError.unreliable }
        let end = min(impulse.count, peak + Int(rate * 0.12))
        let response = Array(impulse[peak..<end])
        let directEnd = min(response.count, max(1, Int(rate * 0.002)))
        let directEnergy = response.prefix(directEnd).reduce(0.0) { $0 + Double($1) * Double($1) }
        let reflectedEnergy = response.dropFirst(directEnd).reduce(0.0) { $0 + Double($1) * Double($1) }
        let reflectionRange = Int(rate * 0.003)..<min(response.count, Int(rate * 0.030))
        let reflection = strongest(in: response, range: reflectionRange).flatMap { index -> Double? in
            abs(response[index]) >= abs(response[0]) * 0.12 ? Double(index) / rate * 1_000 : nil
        }
        return AcousticSpeakerResponse(
            impulseResponse: response, impulseSampleRate: rate, response: points,
            signalToNoiseDB: min(120, snr), directArrivalSeconds: Double(peak) / rate,
            levelDB: 20 * log10(max(1e-10, signalRMS) / max(1e-10, rms(reference))),
            earlyReflectionDelayMilliseconds: reflection,
            reflectedEnergyRatio: min(100, reflectedEnergy / max(1e-20, directEnergy)),
            meanCoherence: coherence
        )
    }

    private func deconvolve(_ captured: [Float], reference: [Float]) throws -> [Float] {
        let fft = try AcousticFFT(minimumSize: captured.count + reference.count)
        var x = [Float](repeating: 0, count: fft.size)
        var xi = x
        var y = x
        var yi = x
        x.replaceSubrange(0..<reference.count, with: reference)
        y.replaceSubrange(0..<captured.count, with: captured)
        fft.transform(real: &x, imaginary: &xi)
        fft.transform(real: &y, imaginary: &yi)
        var peakPower: Float = 0
        for index in x.indices { peakPower = max(peakPower, x[index] * x[index] + xi[index] * xi[index]) }
        let regularization = max(1e-15, peakPower * 1e-6)
        for index in x.indices {
            let denominator = x[index] * x[index] + xi[index] * xi[index] + regularization
            let real = (y[index] * x[index] + yi[index] * xi[index]) / denominator
            yi[index] = (yi[index] * x[index] - y[index] * xi[index]) / denominator
            y[index] = real
        }
        fft.transform(real: &y, imaginary: &yi, inverse: true)
        return y
    }

    /// Cross-spectral averaging estimates magnitude-squared coherence. A single
    /// FFT ratio would trivially report coherence = 1 even for poor recordings.
    private func frequencyResponse(
        reference: [Float], signal: [Float], rate: Double, calibration: MicrophoneCalibrationCurve?
    ) throws -> [AcousticResponsePoint] {
        let fft = try AcousticFFT(minimumSize: min(4096, max(256, reference.count / 4)))
        let frequencies = [125.0, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000].filter { $0 < rate * 0.42 }
        let bins = frequencies.map { min(fft.size / 2 - 1, max(1, Int(($0 * Double(fft.size) / rate).rounded()))) }
        var xx = [Double](repeating: 0, count: bins.count)
        var yy = xx, crossReal = xx, crossImaginary = xx
        let window = (0..<fft.size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fft.size - 1))) }
        for start in stride(from: 0, through: reference.count - fft.size, by: fft.size / 2) {
            try Task.checkCancellation()
            var x = (0..<fft.size).map { reference[start + $0] * window[$0] }
            var y = (0..<fft.size).map { signal[start + $0] * window[$0] }
            var xi = [Float](repeating: 0, count: fft.size), yi = xi
            fft.transform(real: &x, imaginary: &xi)
            fft.transform(real: &y, imaginary: &yi)
            for (index, bin) in bins.enumerated() {
                let xr = Double(x[bin]), imaginaryX = Double(xi[bin])
                let yr = Double(y[bin]), imaginaryY = Double(yi[bin])
                xx[index] += xr * xr + imaginaryX * imaginaryX
                yy[index] += yr * yr + imaginaryY * imaginaryY
                crossReal[index] += yr * xr + imaginaryY * imaginaryX
                crossImaginary[index] += imaginaryY * xr - yr * imaginaryX
            }
        }
        let levels = frequencies.indices.map { index in
            10 * log10(max(1e-20, yy[index]) / max(1e-20, xx[index]))
                - (calibration?.correction(at: frequencies[index]) ?? 0)
        }
        let referenceLevels = frequencies.indices.filter { (500...2_000).contains(frequencies[$0]) }.map { levels[$0] }
        let offset = referenceLevels.reduce(0, +) / Double(max(1, referenceLevels.count))
        return frequencies.indices.map { index in
            let crossPower = crossReal[index] * crossReal[index] + crossImaginary[index] * crossImaginary[index]
            return AcousticResponsePoint(
                frequency: frequencies[index], relativeDB: max(-80, min(80, levels[index] - offset)),
                phaseRadians: atan2(crossImaginary[index], crossReal[index]),
                coherence: min(1, max(0, crossPower / max(1e-20, xx[index] * yy[index])))
            )
        }
    }

    private func strongest(in samples: [Float], range: Range<Int>) -> Int? {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= samples.count else { return nil }
        return range.max { abs(samples[$0]) < abs(samples[$1]) }
    }

    private func rms<S: Collection>(_ samples: S) -> Double where S.Element == Float {
        sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count)))
    }

    private func resample(_ samples: [Float], from sourceRate: Double, to rate: Double) -> [Float] {
        guard sourceRate != rate, !samples.isEmpty else { return samples }
        return (0..<Int(Double(samples.count) * rate / sourceRate)).map { index in
            let position = Double(index) * sourceRate / rate
            let lower = min(samples.count - 1, Int(position))
            let upper = min(samples.count - 1, lower + 1)
            return samples[lower] + (samples[upper] - samples[lower]) * Float(position - Double(lower))
        }
    }
}

private final class AcousticFFT {
    let size: Int
    private let logSize: vDSP_Length
    private let setup: FFTSetup

    init(minimumSize: Int) throws {
        guard minimumSize > 0, minimumSize <= 1 << 22 else { throw AcousticMeasurementError.invalidSignal }
        logSize = vDSP_Length(ceil(log2(Double(minimumSize))))
        size = 1 << Int(logSize)
        guard let setup = vDSP_create_fftsetup(logSize, FFTRadix(kFFTRadix2)) else {
            throw AcousticMeasurementError.captureFailed
        }
        self.setup = setup
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func transform(real: inout [Float], imaginary: inout [Float], inverse: Bool = false) {
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, logSize, FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward))
            }
        }
        if inverse {
            let scale = Float(1) / Float(size)
            for index in real.indices { real[index] *= scale; imaginary[index] *= scale }
        }
    }
}
