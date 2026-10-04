import CamiTuneDomain
import Foundation

package struct RoomAnalysisPoint: Sendable {
    package var frequency: Double
    package var mainDB: Double
    package var centralDB: Double
    package var spreadDB: Double
    package var reliability: Double
    package var referenceDB: Double
}
package struct RoomCorrectionDesign: Sendable {
    package var result: RoomCorrectionResult
    package var impulses: [Int: [Float]]
}
package struct RoomCorrectionDesigner {
    package init() {}
    package func aggregate(session: RoomMeasurementSession, channel: Int) -> [RoomAnalysisPoint] {
        let positions = session.positions.filter { !$0.skipped }
        guard let main = positions.first(where: \.isMain)?.observations.first(where: { $0.channel == channel })
                ?? positions.flatMap(\.observations).first(where: { $0.channel == channel }) else { return [] }
        var observations = positions.compactMap { $0.observations.first(where: { $0.channel == channel }) }
        if session.source.kind == .recorder {
            // Compare response shape across positions without interpreting phone
            // AGC as a room-level change. Keep the original measured data intact.
            for index in observations.indices {
                let offsets = observations[index].bins.compactMap { bin -> Double? in
                    guard (300...3000).contains(bin.frequency), bin.reliability > 0.4,
                          let reference = main.bins.first(where: { abs(log2($0.frequency / bin.frequency)) < 0.01 }),
                          reference.reliability > 0.4 else { return nil }
                    return bin.magnitudeDB - reference.magnitudeDB
                }.sorted()
                guard offsets.count >= 12 else { continue }
                let offset = offsets[offsets.count / 2]
                for i in observations[index].bins.indices { observations[index].bins[i].magnitudeDB -= offset }
            }
        }
        var points = main.bins.map { bin -> RoomAnalysisPoint in
            let values = observations.compactMap { observation in observation.bins.first { abs(log2($0.frequency / bin.frequency)) < 0.01 } }
            let sorted = values.map(\.magnitudeDB).sorted()
            let median = sorted[sorted.count / 2]
            let deviations = sorted.map { abs($0 - median) }.sorted()
            let spread = deviations[deviations.count / 2] * 1.4826
            // Main seat remains primary; neighbours are evidence, not five equal votes.
            let central = 0.65 * bin.magnitudeDB + 0.35 * median
            let meanTrust: Double = values.reduce(0.0) { $0 + $1.reliability } / Double(max(1, values.count))
            let spatialTrust: Double = max(0.0, 1.0 - spread / 8.0)
            let evidenceTrust: Double = observations.count == 1 ? 0.75 : 1.0
            let reliability: Double = min(bin.reliability, meanTrust) * spatialTrust * evidenceTrust
            return .init(frequency: bin.frequency, mainDB: bin.magnitudeDB, centralDB: central,
                         spreadDB: spread, reliability: reliability, referenceDB: 0)
        }
        for i in points.indices {
            let neighbours = points.filter { abs(log2($0.frequency / points[i].frequency)) < 1.25 && $0.reliability > 0.2 }
            let sorted = neighbours.map(\.centralDB).sorted()
            points[i].referenceDB = sorted.isEmpty ? points[i].centralDB : sorted[sorted.count / 2]
        }
        return points
    }
    package func design(session: RoomMeasurementSession, settings: RoomCorrectionSettings) throws -> RoomCorrectionDesign {
        try session.validate()
        let rate = session.context.topology.sampleRate
        try settings.validate(sampleRate: rate)
        guard session.measurementFormatVersion == 1, session.measurementSignalVersion == 1,
              session.usablePositionCount > 0 else { throw RoomCorrectionError.invalidSession }
        let main = session.positions.first(where: { $0.isMain && !$0.skipped })
        let channels = Set(session.positions.filter { !$0.skipped }.flatMap(\.observations).map(\.channel)).sorted()
        let timingEligible = !channels.isEmpty && channels.allSatisfy { channel in
            guard let observation = main?.observations.first(where: { $0.channel == channel }) else { return false }
            return observation.timingEligible && observation.repeatDifferenceDB.map { $0 < 2 } == true
        }
        let method: RoomCorrectionMethod
        switch settings.method {
        case .auto:
            // Magnitude evidence alone does not justify extra latency or FIR ringing.
            method = .iir
        case .fir, .hybrid:
            guard timingEligible else { throw RoomCorrectionError.timingUnavailable }; method = settings.method
        case .iir: method = .iir
        }
        let low = settings.lowHz ?? 25, high = min(settings.highHz ?? 800, rate * 0.42)
        var result = RoomCorrectionResult(sessionID: session.id, context: session.context, method: method, settings: settings,
            lowHz: low, highHz: high, positionCount: session.usablePositionCount)
        var impulses: [Int: [Float]] = [:]
        for channel in channels {
            try Task.checkCancellation()
            let points = aggregate(session: session, channel: channel)
            let observations = session.positions.filter { !$0.skipped }.compactMap {
                $0.observations.first { $0.channel == channel }
            }
            let recorder = session.source.kind == .recorder
            guard let mainObservation = main?.observations.first(where: { $0.channel == channel }),
                  (recorder ? mainObservation.repeatShapeDifferenceDB ?? mainObservation.repeatDifferenceDB
                            : mainObservation.repeatDifferenceDB).map({ $0 < 2 }) == true,
                  observations.filter(\.hasUsableMagnitude).count >= (recorder ? 3 : 1) else { continue }
            let evidence = observations.map { safetyEvidence(observation: $0, points: points) }
            let bands = fit(points: points, evidence: evidence, recorder: recorder,
                            settings: settings, rate: rate, low: low, high: high)
            guard !bands.isEmpty else { continue }
            switch method {
            case .iir, .auto: result.channelBands[channel] = bands
            case .fir:
                impulses[channel] = try RoomFIRDesigner().design(bands: bands, sampleRate: rate, settings: settings)
            case .hybrid:
                // Disjoint filter sets: each feature belongs to exactly one stage.
                let split = min(250, sqrt(low * high))
                result.channelBands[channel] = bands.filter { $0.frequency <= split }
                impulses[channel] = try RoomFIRDesigner().design(bands: bands.filter { $0.frequency > split }, sampleRate: rate, settings: settings)
            }
        }
        // Use a shared stage only if the fitted physical channel filters agree exactly.
        // Otherwise preserve independent physical channel identities.
        return .init(result: result, impulses: impulses)
    }
    // Validate each position against its own broad trend. Absolute phone gain
    // cancels here; an averaged response must not hide a conflicting position.
    private struct Evidence {
        var deviation: Double
        var reliable: Bool
    }
    private func safetyEvidence(observation: RoomChannelObservation, points: [RoomAnalysisPoint]) -> [Evidence] {
        points.map { point in
            guard let bin = observation.bins.first(where: { abs(log2($0.frequency / point.frequency)) < 0.01 }) else {
                return .init(deviation: 0, reliable: false)
            }
            let neighbours = observation.bins.filter {
                abs(log2($0.frequency / point.frequency)) < 1.25 && $0.reliability > 0.4
            }
            let sorted = neighbours.map(\.magnitudeDB).sorted()
            let supported = bin.reliability > 0.4 && sorted.count >= 12
                && neighbours.contains { $0.frequency < point.frequency / sqrt(2) }
                && neighbours.contains { $0.frequency > point.frequency * sqrt(2) }
            return .init(deviation: bin.magnitudeDB - (sorted.isEmpty ? bin.magnitudeDB : sorted[sorted.count / 2]),
                         reliable: supported)
        }
    }
    private func fit(points: [RoomAnalysisPoint], evidence: [[Evidence]], recorder: Bool,
                     settings: RoomCorrectionSettings, rate: Double, low: Double, high: Double) -> [EQBand] {
        let maximumCut = recorder ? min(3, settings.maximumCutDB ?? 3) : settings.maximumCutDB ?? 6
        let maximumBoost = recorder ? 0 : settings.maximumBoostDB ?? 0
        var bands: [EQBand] = []
        var rejected = Set<Int>()
        let response = EQResponseCalculator()
        var combined = [Double](repeating: 0, count: points.count)
        // Check the complete cascade, including overlapping skirts and areas
        // outside the requested range, before accepting each candidate.
        func acceptable(_ gains: [Double]) -> Bool {
            for i in points.indices {
                let gain = gains[i]
                guard gain >= -maximumCut - 0.001, gain <= maximumBoost + 0.001 else { return false }
                if !(low...high).contains(points[i].frequency) || points[i].reliability <= 0.4 {
                    if abs(gain) > 0.35 { return false }
                }
                if abs(gain) > 0.35 && evidence.filter({ $0[i].reliable }).count < (recorder ? 3 : 1) { return false }
            }
            var improvement = 0.0
            for position in evidence {
                var before = 0.0, after = 0.0
                for i in points.indices {
                    let gain = gains[i], bin = position[i]
                    guard bin.reliable else {
                        if abs(gain) > 0.35 { return false }
                        continue
                    }
                    let original = abs(bin.deviation), corrected = abs(bin.deviation + gain)
                    // A small allowance accommodates IIR skirts, never a new
                    // material dip or a deeper existing null at another seat.
                    if corrected > original + 0.35 { return false }
                    let previous = bin.deviation + combined[i]
                    before += previous * previous
                    after += corrected * corrected
                }
                guard after <= before + 0.000001 else { return false }
                improvement += before - after
            }
            return improvement > 0.5
        }
        for _ in points.indices {
            if bands.count >= (settings.filterCount ?? 8) { break }
            var best: (Int, Double, Double)?
            for i in points.indices {
                let p = points[i]
                guard !rejected.contains(i), (low...high).contains(p.frequency), p.reliability > 0.4 else { continue }
                let residual = p.centralDB - p.referenceDB + combined[i]
                // Deep nulls, mobile features, and HF combing never receive boost.
                let canBoost = maximumBoost > 0 && residual > -5 && residual < -1.5 && p.spreadDB < 1.5 && p.reliability > 0.85 && p.frequency < 500
                guard residual > 1.5 || canBoost else { continue }
                let score = abs(residual) * p.reliability / (1 + p.spreadDB) * (residual > 0 ? 1 : 0.25)
                if score > (best?.2 ?? 0) { best = (i, residual, score) }
            }
            guard let (i, residual, _) = best else { break }
            let p = points[i]
            var left = i, right = i
            func deviation(_ index: Int) -> Double { points[index].centralDB - points[index].referenceDB }
            while left > 0 && deviation(left - 1) * residual > 0 && abs(deviation(left - 1)) > abs(residual) * 0.45 { left -= 1 }
            while right + 1 < points.count && deviation(right + 1) * residual > 0 && abs(deviation(right + 1)) > abs(residual) * 0.45 { right += 1 }
            let octaves = log2(points[right].frequency / points[left].frequency)
            guard octaves > (p.frequency > 1000 ? 0.25 : 0.08), octaves < 1 else { rejected.insert(i); continue }
            let q = min(settings.maximumQ ?? 4, max(0.35, p.frequency / max(1, points[right].frequency - points[left].frequency)))
            let gain = max(-maximumCut, min(maximumBoost, -residual * p.reliability * 0.8))
            guard abs(gain) > 0.4 else { rejected.insert(i); continue }
            var accepted = false
            for scale in [1.0, 0.75, 0.5, 0.25] {
                guard abs(gain * scale) > 0.4 else { continue }
                let band = EQBand(kind: .peaking, frequency: p.frequency, gain: gain * scale, q: q)
                let proposal = points.indices.map {
                    combined[$0] + response.gainDB(at: points[$0].frequency,
                        parsed: .init(preampDB: 0, bands: [band]), sampleRate: rate)
                }
                guard acceptable(proposal) else { continue }
                bands.append(band); combined = proposal; accepted = true; break
            }
            if !accepted { rejected.insert(i) }
        }
        return bands
    }
}

/// Windowed real-cepstral minimum phase, linear phase, or mixed phase realization
/// of the same bounded magnitude design. Never inverts spatially averaged phase.
package struct RoomFIRDesigner {
    package init() {}
    package func design(bands: [EQBand], sampleRate: Double, settings: RoomCorrectionSettings) throws -> [Float] {
        try settings.validate(sampleRate: sampleRate)
        let limit = settings.latencyLimitMS ?? 20
        var length = settings.filterLength ?? 2048
        if settings.filterLength == nil && settings.phase != .minimum {
            while length > 256 && Double(length / 2) / sampleRate * 1000 > limit { length /= 2 }
        }
        let delay = settings.phase == .minimum ? 0 : length / 2
        guard Double(delay) / sampleRate * 1000 <= limit else { throw RoomCorrectionError.latencyLimit }
        let fft = try AcousticFFT(minimumSize: length)
        let calculator = EQResponseCalculator()
        var logMagnitude = [Float](repeating: 0, count: length), imaginary = logMagnitude
        for i in 0...length / 2 {
            let f = max(1, Double(i) * sampleRate / Double(length))
            let low = settings.lowHz ?? 25, high = min(settings.highHz ?? 800, sampleRate * 0.45)
            let edge = max(0, min(1, log2(f / low) * 4, log2(high / f) * 4))
            let taper = 0.5 - 0.5 * cos(.pi * edge)
            let db = calculator.gainDB(at: f, parsed: .init(preampDB: 0, bands: bands), sampleRate: sampleRate) * taper
            logMagnitude[i] = Float(db * log(10) / 20)
            if i > 0 && i < length / 2 { logMagnitude[length - i] = logMagnitude[i] }
        }
        let desiredLog = logMagnitude
        fft.transform(real: &logMagnitude, imaginary: &imaginary, inverse: true)
        for i in 1..<length / 2 { logMagnitude[i] *= 2 }
        for i in length / 2 + 1..<length { logMagnitude[i] = 0 }
        imaginary = [Float](repeating: 0, count: length)
        fft.transform(real: &logMagnitude, imaginary: &imaginary)
        var real = logMagnitude
        for i in 0..<length {
            let phase: Double
            switch settings.phase {
            case .minimum: phase = Double(imaginary[i])
            case .linear: phase = -2 * .pi * Double(i * delay) / Double(length)
            case .mixed: phase = Double(imaginary[i]) * 0.5 - 2 * .pi * Double(i * delay) / Double(length)
            }
            let magnitude = exp(Double(desiredLog[i]))
            real[i] = Float(magnitude * cos(phase)); imaginary[i] = Float(magnitude * sin(phase))
        }
        fft.transform(real: &real, imaginary: &imaginary, inverse: true)
        for i in real.indices {
            let distance = settings.phase == .minimum ? Double(i) / Double(length) : abs(Double(i - delay)) / Double(length / 2)
            let window = distance < 0.75 ? 1 : 0.5 + 0.5 * cos(.pi * min(1, (distance - 0.75) / 0.25))
            real[i] *= Float(window)
        }
        guard real.allSatisfy(\.isFinite) else { throw RoomCorrectionError.unreliable }
        // Reject truncation that would materially change the approved response.
        var check = real, checkI = [Float](repeating: 0, count: length)
        fft.transform(real: &check, imaginary: &checkI)
        for i in 1..<length / 2 {
            let actualDB = 10 * log10(max(1e-20, Double(check[i] * check[i] + checkI[i] * checkI[i])))
            let desiredDB = Double(desiredLog[i]) * 20 / log(10)
            guard abs(actualDB - desiredDB) < 0.1 else { throw RoomCorrectionError.latencyLimit }
        }
        return real
    }
}
