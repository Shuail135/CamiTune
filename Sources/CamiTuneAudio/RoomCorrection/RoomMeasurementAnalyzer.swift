import CamiTuneDomain
import Foundation
import AVFoundation
import Accelerate

/// Correlates two coded markers, estimates the recorder clock, then performs regularized deconvolution.
/// Host timestamps only narrow the search; recorded codes determine alignment and clock correction.
package struct RoomMeasurementAnalyzer {
    package init() {}
    /// Decode and anti-alias the continuous recording once, regardless of pauses
    /// or the number/order of positions. Block identity still comes from codes.
    package struct Recording: Sendable {
        let samples: [Float]
        let sampleRate: Double
        let isLossy: Bool
        let detection: [Float]
        package init(samples: [Float], sampleRate: Double, isLossy: Bool) throws {
            guard sampleRate.isFinite, (8000...192000).contains(sampleRate), !samples.isEmpty,
                  samples.count <= 57_600_000, samples.count <= Int(sampleRate * 1200),
                  samples.allSatisfy(\.isFinite) else { throw RoomCorrectionError.invalidSession }
            self.samples = samples; self.sampleRate = sampleRate; self.isLossy = isLossy
            detection = try RoomMeasurementAnalyzer.convertSampleRate(samples, from: sampleRate, to: 12000)
        }
    }
    package func analyze(samples: [Float], sampleRate: Double, isLossy: Bool, block: RoomMeasurementBlock,
                         playbackRate: Double, calibration: MicrophoneCalibrationCurve?) throws -> RoomChannelObservation {
        try analyze(recording: Recording(samples: samples, sampleRate: sampleRate, isLossy: isLossy),
                    block: block, playbackRate: playbackRate, calibration: calibration)
    }
    package func analyze(recording prepared: Recording, block: RoomMeasurementBlock,
                         playbackRate: Double, calibration: MicrophoneCalibrationCurve?,
                         expectedMarkerTime: Double? = nil) throws -> RoomChannelObservation {
        let samples = prepared.samples, sampleRate = prepared.sampleRate, isLossy = prepared.isLossy
        let detectionRate = 12000.0
        let detection = prepared.detection
        let startTemplate = RoomMeasurementSignal.marker(token: block.token, end: false, rate: detectionRate)
        let endTemplate = RoomMeasurementSignal.marker(token: block.token, end: true, rate: detectionRate)
        var located: (Double, Double, Double)?
        var searchRanges: [Range<Int>] = []
        if let expectedMarkerTime, expectedMarkerTime.isFinite {
            let lo = Int(min(Double(detection.count), max(0, expectedMarkerTime - 1) * detectionRate))
            let hi = max(lo, Int(min(Double(detection.count), max(0, expectedMarkerTime + 1.2) * detectionRate)))
            if hi - lo > startTemplate.count { searchRanges.append(lo..<hi) }
        }
        // Timestamp hints may be stale after a recorder pause, edit, or restart.
        // Fall back to the whole file; never invent a match from elapsed time.
        searchRanges.append(0..<detection.count)
        for range in searchRanges {
            let starts = try correlations(Array(detection[range]), template: startTemplate, rate: detectionRate)
                .map { (offset: $0.offset + range.lowerBound, score: $0.score) }
            // Prefer the strongest complete code pair. A later weak cross-match to
            // another token must not replace the correct take. For equal evidence,
            // reversed order keeps the latest replay.
            for start in starts.reversed() {
                if let located, start.score <= located.2 * 1.05 { continue }
                let expected = start.offset + Int(5.1 * detectionRate)
                let lo = max(0, expected - 500), hi = min(detection.count, expected + 2500)
                guard hi > lo + endTemplate.count,
                      let end = try correlations(Array(detection[lo..<hi]), template: endTemplate, rate: detectionRate)
                        .filter({ (0.995...1.005).contains(Double(lo + $0.offset - start.offset) / (5.1 * detectionRate)) })
                        .max(by: { $0.score < $1.score }) else { continue }
                let ratio = Double(lo + end.offset - start.offset) / (5.1 * detectionRate)
                // Require two different matching codes at the correct separation;
                // a weak single marker or a plausible sweep order is insufficient.
                guard (0.995...1.005).contains(ratio), start.score * end.score >= 0.09 else { continue }
                let quality = min(start.score, end.score)
                if let located, quality <= located.2 * 1.05 { continue }
                let refinedStart = refineMarker(samples, sampleRate: sampleRate, token: block.token,
                    end: false, time: Double(start.offset) / detectionRate)
                let refinedEnd = refineMarker(samples, sampleRate: sampleRate, token: block.token,
                    end: true, time: Double(lo + end.offset) / detectionRate)
                let refinedRatio = (refinedEnd - refinedStart) / 5.1
                guard (0.995...1.005).contains(refinedRatio) else { continue }
                located = (refinedStart, refinedRatio, quality)
            }
            if let located, located.2 >= 0.5 { break }
        }
        guard let (markerTime, ratio, markerQuality) = located else { throw RoomCorrectionError.missingBlocks }
        try Task.checkCancellation()
        let rate = min(48000, sampleRate, playbackRate)
        let emittedSweep = try RoomMeasurementSignal(block: block, sampleRate: playbackRate).sweep
        let sweep = try Self.convertSampleRate(emittedSweep, from: playbackRate, to: rate)
        let startTime = markerTime + 0.5 * ratio
        guard startTime >= 0, (startTime + 4.5 * ratio) * sampleRate < Double(samples.count) else { throw RoomCorrectionError.missingBlocks }
        let count = Int(4.5 * sampleRate)
        let clockCorrected = try Self.correctClock(samples, start: startTime * sampleRate, count: count, ratio: ratio)
        let recording = try Self.convertSampleRate(clockCorrected, from: sampleRate, to: rate)
        let clipFraction = Double(recording.filter { abs($0) >= 0.995 }.count) / Double(recording.count)
        guard clipFraction < 0.0005 else { throw RoomCorrectionError.unreliable }
        let noiseStart = max(0, Int((markerTime + 0.22 * ratio) * sampleRate))
        let noiseEnd = min(samples.count, noiseStart + Int(0.15 * sampleRate))
        let noise = try Self.convertSampleRate(Array(samples[noiseStart..<noiseEnd]), from: sampleRate, to: rate)
        let noiseFFT = try AcousticFFT(minimumSize: max(256, noise.count))
        var nr = [Float](repeating: 0, count: noiseFFT.size), ni = nr
        var windowEnergy = 0.0
        for i in noise.indices {
            let window = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(max(1, noise.count - 1)))
            nr[i] = noise[i] * Float(window); windowEnergy += window * window
        }
        noiseFFT.transform(real: &nr, imaginary: &ni)
        let fft = try AcousticFFT(minimumSize: recording.count + sweep.count)
        var xr = [Float](repeating: 0, count: fft.size), xi = xr, yr = xr, yi = xr
        xr.replaceSubrange(0..<sweep.count, with: sweep)
        yr.replaceSubrange(0..<recording.count, with: recording)
        fft.transform(real: &xr, imaginary: &xi); fft.transform(real: &yr, imaginary: &yi)
        var hr = xr, hi = xi
        let regularization = max(1e-14, xr.indices.map { xr[$0] * xr[$0] + xi[$0] * xi[$0] }.max()! * 1e-7)
        for i in xr.indices {
            let denominator = xr[i] * xr[i] + xi[i] * xi[i] + regularization
            hr[i] = (yr[i] * xr[i] + yi[i] * xi[i]) / denominator
            hi[i] = (yi[i] * xr[i] - yr[i] * xi[i]) / denominator
        }
        var bins: [RoomFrequencyBin] = []
        for i in 0..<241 {
            let frequency = 20 * pow(2, Double(i) / 24)
            guard frequency < min(rate * 0.43, 20000) else { break }
            let center = Int((frequency / rate * Double(fft.size)).rounded())
            let radius = max(1, Int(Double(center) * (pow(2, 1.0 / 96) - 1)))
            let indices = max(1, center - radius)...min(fft.size / 2 - 1, center + radius)
            let power = indices.reduce(0.0) { $0 + Double(hr[$1] * hr[$1] + hi[$1] * hi[$1]) } / Double(indices.count)
            let recordedPower = indices.reduce(0.0) { $0 + Double(yr[$1] * yr[$1] + yi[$1] * yi[$1]) } / Double(indices.count)
            // Phone noise is coloured. Compare against local spectral noise,
            // rather than treating all background energy as white noise.
            let nc = Int((frequency / rate * Double(noiseFFT.size)).rounded())
            let radiusN = max(2, Int(Double(nc) * 0.12))
            let noiseIndices = max(1, nc - radiusN)...min(noiseFFT.size / 2 - 1, nc + radiusN)
            let noisePower = noiseIndices.reduce(0.0) { $0 + Double(nr[$1] * nr[$1] + ni[$1] * ni[$1]) }
                / Double(noiseIndices.count) / max(1, windowEnergy) * Double(recording.count)
            let snr = min(100, 10 * log10(max(1e-20, recordedPower) / max(1e-20, noisePower)))
            let sourcePrior = calibration == nil ? 0.8 : 1.0
            let reliability = max(0, min(1, (snr - 8) / 24)) * min(1, markerQuality / 0.35) * sourcePrior
            var bin = RoomFrequencyBin(frequency: frequency, magnitudeDB: max(-100, min(100, 10 * log10(max(1e-20, power)) - (calibration?.correction(at: frequency) ?? 0))),
                phase: Double(atan2(hi[center], hr[center])), reliability: reliability, snrDB: snr)
            // Differentiate the dense FFT, before logarithmic binning. Unwrapping
            // sparse log-spaced phases aliases delays at higher frequencies.
            // Fit a local phase slope over 1/12 octave. Differencing adjacent
            // FFT samples amplifies noise and makes delay far less stable than
            // phase, even when repeated responses agree.
            let delayRadius = max(3, Int(Double(center) * (pow(2, 1.0 / 24) - 1)))
            let delayIndices = max(1, center - delayRadius)...min(fft.size / 2 - 1, center + delayRadius)
            var previous = 0.0, unwrapped = 0.0
            var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            for k in delayIndices {
                let phase = atan2(Double(hi[k]), Double(hr[k]))
                if k == delayIndices.lowerBound { previous = phase }
                let delta = atan2(sin(phase - previous), cos(phase - previous))
                unwrapped += delta; previous = phase
                let f = Double(k - center) * rate / Double(fft.size)
                let weight = Double(hr[k]) * Double(hr[k]) + Double(hi[k]) * Double(hi[k])
                sw += weight; sx += weight * f; sy += weight * unwrapped
                sxx += weight * f * f; sxy += weight * f * unwrapped
            }
            let denominator = sw * sxx - sx * sx
            if denominator > 1e-30 { bin.groupDelayMS = -(sw * sxy - sx * sy) / denominator / (2 * .pi) * 1000 }
            bins.append(bin)
        }
        guard bins.filter({ $0.reliability > 0.45 }).count >= 24 else { throw RoomCorrectionError.unreliable }
        fft.transform(real: &hr, imaginary: &hi, inverse: true)
        // Acoustic marker alignment can put the direct response just BEFORE
        // index zero. Search both sides of the circular FFT and retain pre-roll.
        let search = Int(rate * 0.025)
        let candidates = Array(0..<search) + Array((fft.size - search)..<fft.size)
        let peak = candidates.max { abs(hr[$0]) < abs(hr[$1]) } ?? 0
        let signedPeak = peak < fft.size / 2 ? peak : peak - fft.size
        let peakSeconds = Double(signedPeak) / rate
        let preRoll = Int(rate * 0.01)
        let impulse = (0..<Int(rate * 0.41)).map { hr[(peak - preRoll + $0 + fft.size) % fft.size] }
        let totalEnergy = hr.reduce(0.0) { $0 + Double($1) * Double($1) }
        let directEnergy = (-Int(rate * 0.002)..<Int(rate * 0.008)).reduce(0.0) {
            let value = Double(hr[(peak + $1 + fft.size) % fft.size]); return $0 + value * value
        }
        let concentrated = directEnergy / max(1e-20, totalEnergy)
        for i in bins.indices {
            let phase = bins[i].phase + 2 * .pi * bins[i].frequency * peakSeconds
            bins[i].phase = atan2(sin(phase), cos(phase))
            bins[i].groupDelayMS = (bins[i].groupDelayMS ?? 0) - peakSeconds * 1000
            bins[i].timingReliability = isLossy ? 0 : bins[i].reliability
        }
        let level = bins.filter { (300...2000).contains($0.frequency) }.map(\.magnitudeDB)
        var result = RoomChannelObservation(channel: block.channel, bins: bins, impulse: impulse, impulseSampleRate: rate,
            arrivalSeconds: peakSeconds, levelDB: level.reduce(0, +) / Double(max(1, level.count)),
            timingEligible: !isLossy && markerQuality > 0.45 && abs(ratio - 1) < 0.002 && concentrated > 0.25,
            clockRatio: ratio)
        result.markerConfidence = markerQuality; result.impulseTimeZeroSeconds = Double(preRoll) / rate
        result.recordingMarkerTime = markerTime
        result.relativeImpulseEligible = markerQuality >= 0.28 && concentrated > 0.2
        result.relativeTimingEligible = result.timingEligible
        return result
    }
    private func refineMarker(_ samples: [Float], sampleRate: Double, token: UInt32, end: Bool, time: Double) -> Double {
        let template = RoomMeasurementSignal.marker(token: token, end: end, rate: sampleRate)
        // The detector's sample-rate converter and acoustic filtering can shift
        // the coarse peak by more than one carrier cycle. Revisit the original
        // samples across that uncertainty before fractional interpolation.
        let center = Int((time * sampleRate).rounded()), radius = Int(sampleRate * 0.003)
        let lo = max(0, center - radius), hi = min(samples.count - template.count, center + radius)
        guard hi > lo else { return time }
        let templateEnergy = template.reduce(0.0) { $0 + Double($1) * Double($1) }
        var scores: [Double] = []
        samples.withUnsafeBufferPointer { input in
            template.withUnsafeBufferPointer { reference in
                for offset in lo...hi {
                    var dot: Float = 0, energy: Float = 0
                    vDSP_dotpr(input.baseAddress! + offset, 1, reference.baseAddress!, 1, &dot, vDSP_Length(template.count))
                    vDSP_svesq(input.baseAddress! + offset, 1, &energy, vDSP_Length(template.count))
                    scores.append(abs(Double(dot)) / sqrt(max(1e-30, Double(energy) * templateEnergy)))
                }
            }
        }
        let peak = scores.indices.max { scores[$0] < scores[$1] } ?? 0
        var fraction = 0.0
        if peak > 0, peak + 1 < scores.count {
            let denominator = scores[peak - 1] - 2 * scores[peak] + scores[peak + 1]
            if denominator < -1e-12 { fraction = max(-0.5, min(0.5, 0.5 * (scores[peak - 1] - scores[peak + 1]) / denominator)) }
        }
        return (Double(lo + peak) + fraction) / sampleRate
    }
    private func correlations(_ samples: [Float], template: [Float], rate: Double) throws -> [(offset: Int, score: Double)] {
        guard samples.count >= template.count else { return [] }
        let window = 131072, overlap = template.count
        let fft = try AcousticFFT(minimumSize: min(window, samples.count) + template.count)
        var tr = [Float](repeating: 0, count: fft.size), ti = tr
        tr.replaceSubrange(0..<template.count, with: template.reversed())
        fft.transform(real: &tr, imaginary: &ti)
        let energy = template.reduce(0.0) { $0 + Double($1) * Double($1) }
        var found: [(Int, Double)] = []
        for start in stride(from: 0, to: samples.count, by: window - overlap) {
            try Task.checkCancellation()
            let count = min(window, samples.count - start)
            guard count >= template.count else { break }
            var real = [Float](repeating: 0, count: fft.size), imaginary = real
            real.replaceSubrange(0..<count, with: samples[start..<start + count])
            fft.transform(real: &real, imaginary: &imaginary)
            for i in real.indices {
                let r = real[i] * tr[i] - imaginary[i] * ti[i]
                imaginary[i] = real[i] * ti[i] + imaginary[i] * tr[i]; real[i] = r
            }
            fft.transform(real: &real, imaginary: &imaginary, inverse: true)
            var sum = samples[start..<start + template.count].reduce(0.0) { $0 + Double($1) * Double($1) }
            var last = -template.count
            for offset in 0...count - template.count {
                if offset > 0 {
                    let added = Double(samples[start + offset + template.count - 1]), removed = Double(samples[start + offset - 1])
                    sum += added * added - removed * removed
                }
                guard sum > max(1e-10, energy * 1e-8) else { continue }
                let score = abs(Double(real[offset + template.count - 1])) / sqrt(sum * energy)
                if score > 0.25 && score <= 1.01 {
                    if offset - last < template.count / 2, !found.isEmpty {
                        if score > found[found.count - 1].1 { found[found.count - 1] = (start + offset, score) }
                    } else { found.append((start + offset, score)) }
                    last = offset
                }
            }
        }
        return found.sorted { $0.0 < $1.0 }
    }
    /// System band-limited conversion preserves the emitted sweep's frequency law.
    /// Re-synthesizing a sweep at the analysis rate would change its upper endpoint.
    package static func convertSampleRate(_ values: [Float], from: Double, to: Double) throws -> [Float] {
        guard from != to else { return values }
        guard from.isFinite, to.isFinite, (8000...192000).contains(from), (8000...192000).contains(to),
              !values.isEmpty, values.count <= 57_600_000,
              let inputFormat = AVAudioFormat(standardFormatWithSampleRate: from, channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: to, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(values.count)),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { throw RoomCorrectionError.invalidSession }
        let expected = Int(Double(values.count) * to / from)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(expected + 512)) else { throw RoomCorrectionError.invalidSession }
        input.frameLength = AVAudioFrameCount(values.count)
        values.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: values.count) }
        converter.primeMethod = .none
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true; inputStatus.pointee = .haveData; return input
        }
        guard status != .error, error == nil, Int(output.frameLength) >= expected - 2 else { throw RoomCorrectionError.invalidSession }
        var result = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: min(expected, Int(output.frameLength))))
        if result.count < expected { result.append(contentsOf: repeatElement(0, count: expected - result.count)) }
        return result
    }
    package static func sample(_ values: [Float], at index: Double) -> Float {
        guard index >= 0, index < Double(values.count - 1) else { return 0 }
        let lower = Int(index), fraction = Float(index - Double(lower))
        return values[lower] + fraction * (values[lower + 1] - values[lower])
    }
    /// Fractional clock correction must not attenuate treble like linear
    /// interpolation does. Windowed-sinc kernels preserve the measured band.
    package static func correctClock(_ values: [Float], start: Double, count: Int, ratio: Double) throws -> [Float] {
        guard start.isFinite, start >= 0, count > 0, count <= 4_000_000,
              ratio.isFinite, (0.995...1.005).contains(ratio),
              start + Double(count - 1) * ratio < Double(values.count) else { throw RoomCorrectionError.invalidSession }
        let taps = 48, phases = 1024, firstTap = -23
        let cutoff = min(1, 1 / ratio)
        var kernels: [Float] = []; kernels.reserveCapacity((phases + 1) * taps)
        for phase in 0...phases {
            let fraction = Double(phase) / Double(phases)
            var weights = (0..<taps).map { tap -> Double in
                let distance = Double(firstTap + tap) - fraction
                let sinc = abs(distance) < 1e-12 ? cutoff : sin(.pi * distance * cutoff) / (.pi * distance)
                return sinc * max(0, 0.5 + 0.5 * cos(.pi * distance / 24))
            }
            let sum = weights.reduce(0, +)
            for i in weights.indices { weights[i] /= sum }
            kernels.append(contentsOf: weights.map(Float.init))
        }
        var result = [Float](repeating: 0, count: count)
        try values.withUnsafeBufferPointer { input in
            try kernels.withUnsafeBufferPointer { table in
                try result.withUnsafeMutableBufferPointer { output in
                    for i in 0..<count {
                        if i.isMultiple(of: 8192) { try Task.checkCancellation() }
                        let at = start + Double(i) * ratio, index = Int(at)
                        let phase = min(phases, Int(((at - Double(index)) * Double(phases)).rounded()))
                        let lower = index + firstTap
                        if lower >= 0, lower + taps <= values.count {
                            vDSP_dotpr(input.baseAddress! + lower, 1, table.baseAddress! + phase * taps, 1,
                                output.baseAddress! + i, vDSP_Length(taps))
                        } else {
                            for tap in 0..<taps where lower + tap >= 0 && lower + tap < values.count {
                                output[i] += input[lower + tap] * table[phase * taps + tap]
                            }
                        }
                    }
                }
            }
        }
        return result
    }
    package static func resample(_ values: [Float], from: Double, to: Double) -> [Float] {
        guard from != to else { return values }
        return (0..<Int(Double(values.count) * to / from)).map { sample(values, at: Double($0) * from / to) }
    }
}
