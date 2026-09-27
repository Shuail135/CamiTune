import CamiTuneDomain
import Foundation

struct FrequencyResponseCSVImporter {
    func parse(_ text: String, name: String) throws -> FrequencyResponse {
        var points: [FrequencyResponse.Point] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("*") else { continue }
            let values = line
                .replacingOccurrences(of: ";", with: " ")
                .replacingOccurrences(of: ",", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .split(whereSeparator: { $0.isWhitespace })
                .compactMap { Double($0) }
            guard values.count >= 2 else { continue }
            points.append(.init(frequency: values[0], magnitudeDB: values[1]))
        }
        let response = FrequencyResponse(name: name, points: points)
        guard response.points.count >= 3 else {
            throw ImportError.insufficientPoints
        }
        guard let first = response.points.first, let last = response.points.last,
              first.frequency <= 30, last.frequency >= 10_000 else {
            throw ImportError.insufficientFrequencyRange
        }
        return response
    }

    enum ImportError: LocalizedError, Equatable {
        case insufficientPoints
        case insufficientFrequencyRange

        var errorDescription: String? {
            switch self {
            case .insufficientPoints:
                return "The CSV needs at least three rows containing frequency and level values."
            case .insufficientFrequencyRange:
                return "The response must cover at least 30 Hz through 10 kHz."
            }
        }
    }
}

struct MeasurementConsensus: Hashable, Sendable {
    var response: FrequencyResponse
    var confidence: MeasurementConfidenceCurve
    var sources: [DeviceMeasurementReference]
    var snapshots: [MeasurementSnapshot]
}

struct MeasurementConsensusBuilder {
    func build(
        deviceName: String,
        measurements: [DeviceCorrectionMeasurement]
    ) throws -> MeasurementConsensus {
        let variants = Set(measurements.map {
            ($0.source.deviceIdentity ?? .inferred(from: $0.source.catalogName)).stableKey
        })
        guard variants.count <= 1 else { throw ConsensusError.mixedVariants }
        let plannedSources = Set(MeasurementSetPlanner.references(
            from: measurements.map(\.source)
        ).map(\.id))
        let compatible = measurements.filter { plannedSources.contains($0.source.id) }
        // The AutoEQ catalog can expose a response that is also attributed to
        // its original Squiglink/lab provider. Identical normalized content is
        // one measurement, not two independent votes; retain original-source
        // provenance over an AutoEQ duplicate.
        let selected = uniqueMeasurementsByContent(compatible)
        guard !selected.isEmpty else { throw ConsensusError.noMeasurements }

        let aligned = alignInsertionDepth(in: selected)
        let normalizedByEvidence = Dictionary(grouping: aligned) {
            $0.source.independentEvidenceKey
        }.sorted { $0.key < $1.key }.map { key, measurements in
            (
                key,
                measurements.sorted {
                    MeasurementSetPlanner.isOrderedBefore($0.source, $1.source)
                }.map { ($0.source, $0.response.normalized()) }
            )
        }
        let frequencies = (0..<181).map { index in
            20 * pow(1_000, Double(index) / 180)
        }
        var responsePoints: [FrequencyResponse.Point] = []
        var confidencePoints: [MeasurementConfidenceCurve.Point] = []

        for frequency in frequencies {
            // Average repeated exports inside one physical unit first.
            let unitValues: [(lab: String, value: Double, weight: Double)] = normalizedByEvidence.compactMap {
                _, group in
                let readings = group.compactMap { source, response -> (Double, Double)? in
                    response.magnitude(at: frequency).map {
                        ($0, min(1, max(0.1, source.reliability)))
                    }
                }
                guard !readings.isEmpty else { return nil }
                let totalWeight = readings.map(\.1).reduce(0, +)
                return (
                    group[0].0.laboratoryCorrelationKey,
                    readings.map { $0.0 * $0.1 }.reduce(0, +) / max(totalWeight, 1e-9),
                    readings.map(\.1).max() ?? 0.5
                )
            }
            // Units measured by the same laboratory share systematic fixture,
            // calibration, and process errors. Combine them into one lab vote;
            // repeat units add only a small diminishing confidence benefit.
            let values: [(value: Double, weight: Double, evidence: Double)] = Dictionary(
                grouping: unitValues,
                by: \.lab
            ).sorted { $0.key < $1.key }.compactMap { _, units in
                guard !units.isEmpty else { return nil }
                let totalWeight = units.map(\.weight).reduce(0, +)
                let weight = units.map(\.weight).max() ?? 0.5
                let repeatBenefit = min(1.25, 1 + 0.15 * log2(Double(units.count)))
                return (
                    units.map { $0.value * $0.weight }.reduce(0, +)
                        / max(totalWeight, 1e-9),
                    weight,
                    weight * repeatBenefit
                )
            }
            guard !values.isEmpty else { continue }
            let center = median(values.map(\.value))
            let deviation = median(values.map { abs($0.value - center) })
            let rejectionLimit = max(1.5, deviation * 3)
            let accepted = values.filter { abs($0.value - center) <= rejectionLimit }
            let totalWeight = accepted.map(\.weight).reduce(0, +)
            let consensus = accepted.map { $0.value * $0.weight }.reduce(0, +)
                / max(totalWeight, 1e-9)
            // Evidence confidence saturates gradually and never becomes perfect
            // from count alone. Three agreeing labs are useful, but are not the
            // maximum possible body of evidence.
            let effectiveEvidenceCount = accepted.map(\.evidence).reduce(0, +)
            let countConfidence = min(
                0.96,
                0.35 + 0.60 * (1 - exp(-effectiveEvidenceCount / 3))
            )
            let agreementConfidence = exp(-deviation / 2.5)
            responsePoints.append(.init(frequency: frequency, magnitudeDB: consensus))
            confidencePoints.append(.init(
                frequency: frequency,
                confidence: min(1, max(0.15, countConfidence * agreementConfidence))
            ))
        }
        guard responsePoints.count >= 24 else { throw ConsensusError.insufficientOverlap }
        return MeasurementConsensus(
            response: FrequencyResponse(name: "\(deviceName) consensus", points: responsePoints),
            confidence: MeasurementConfidenceCurve(points: confidencePoints),
            sources: selected.map(\.source),
            snapshots: Array(Set(selected.compactMap(\.snapshot))).sorted {
                snapshotSortKey($0) < snapshotSortKey($1)
            }
        )
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private func alignInsertionDepth(
        in measurements: [DeviceCorrectionMeasurement]
    ) -> [DeviceCorrectionMeasurement] {
        guard measurements.allSatisfy({
            DeviceNameNormalizer.key(for: $0.source.form ?? "").contains("in ear")
        }) else { return measurements }

        let normalized = measurements.map { measurement -> DeviceCorrectionMeasurement in
            var copy = measurement
            copy.response = measurement.response.normalized()
            return copy
        }
        let resonanceByEvidence = Dictionary(grouping: normalized) {
            $0.source.independentEvidenceKey
        }.compactMapValues { group -> Double? in
            let estimates = group.compactMap { insertionResonance(in: $0.response) }
            guard !estimates.isEmpty else { return nil }
            return exp(median(estimates.map(log)))
        }
        guard resonanceByEvidence.count >= 2 else { return normalized }
        let anchor = exp(median(resonanceByEvidence.values.map(log)))

        return normalized.map { measurement in
            guard let resonance = resonanceByEvidence[
                measurement.source.independentEvidenceKey
            ] else { return measurement }
            let shiftOctaves = min(0.18, max(-0.18, log2(anchor / resonance)))
            var aligned = measurement
            aligned.response = FrequencyResponse(
                name: measurement.response.name,
                points: measurement.response.points.map { point in
                    let position = min(1, max(
                        0,
                        log(point.frequency / 2_000) / log(6_000.0 / 2_000)
                    ))
                    let blend = position * position * (3 - 2 * position)
                    return .init(
                        frequency: point.frequency * pow(2, shiftOctaves * blend),
                        magnitudeDB: point.magnitudeDB
                    )
                }
            )
            return aligned
        }
    }

    private func insertionResonance(in response: FrequencyResponse) -> Double? {
        let frequencies = (0..<81).map {
            4_500 * pow(12_500.0 / 4_500, Double($0) / 80)
        }
        let samples = frequencies.compactMap { frequency in
            response.magnitude(at: frequency).map { (frequency, $0) }
        }
        guard samples.count >= 40 else { return nil }
        let center = median(samples.map(\.1))
        let interior = samples.dropFirst(3).dropLast(3)
        guard let feature = interior.max(by: {
            abs($0.1 - center) < abs($1.1 - center)
        }), abs(feature.1 - center) >= 1 else { return nil }
        return feature.0
    }

    private func uniqueMeasurementsByContent(
        _ measurements: [DeviceCorrectionMeasurement]
    ) -> [DeviceCorrectionMeasurement] {
        Dictionary(grouping: measurements, by: responseContentKey)
            .sorted { $0.key < $1.key }
            .compactMap { _, duplicates in
                duplicates.sorted(by: isPreferredMeasurement).first
            }
    }

    private func isPreferredMeasurement(
        _ lhs: DeviceCorrectionMeasurement,
        _ rhs: DeviceCorrectionMeasurement
    ) -> Bool {
        let leftPriority = lhs.source.origin == .autoEq ? 0 : 1
        let rightPriority = rhs.source.origin == .autoEq ? 0 : 1
        if leftPriority != rightPriority { return leftPriority > rightPriority }
        if lhs.source.reliability != rhs.source.reliability {
            return lhs.source.reliability > rhs.source.reliability
        }
        if lhs.source != rhs.source {
            return MeasurementSetPlanner.isOrderedBefore(lhs.source, rhs.source)
        }
        return (lhs.snapshot.map(snapshotSortKey) ?? "")
            < (rhs.snapshot.map(snapshotSortKey) ?? "")
    }

    private func snapshotSortKey(_ snapshot: MeasurementSnapshot) -> String {
        [
            snapshot.providerID,
            snapshot.retrievalProviderID ?? "",
            snapshot.datasetID,
            snapshot.datasetVersion ?? "",
            snapshot.measurementID,
            snapshot.contentHash,
            String(
                format: "%.6f",
                locale: Locale(identifier: "en_US_POSIX"),
                snapshot.retrievedAt.timeIntervalSinceReferenceDate
            )
        ].joined(separator: "\u{1f}")
    }

    private func responseContentKey(_ measurement: DeviceCorrectionMeasurement) -> String {
        let normalized = measurement.response.normalized()
        let canonical = normalized.points.map {
            let locale = Locale(identifier: "en_US_POSIX")
            return "\(String(format: "%.6f", locale: locale, $0.frequency)):\(String(format: "%.6f", locale: locale, $0.magnitudeDB))"
        }.joined(separator: "|")
        return StableContentHash.string(canonical)
    }

    enum ConsensusError: LocalizedError, Equatable {
        case noMeasurements
        case mixedVariants
        case insufficientOverlap

        var errorDescription: String? {
            switch self {
            case .mixedVariants:
                return "Measurements belong to different device variants."
            case .noMeasurements:
                return "No compatible measurements are available for this device configuration."
            case .insufficientOverlap:
                return "The selected measurements do not overlap across enough of the audible range."
            }
        }
    }
}

protocol CorrectionPolicy {
    func makeCurve(
        measurement: FrequencyResponse,
        target: FrequencyResponse,
        measurementConfidence: MeasurementConfidenceCurve?
    ) throws -> CorrectionCurve
}

extension CorrectionPolicy {
    func makeCurve(
        measurement: FrequencyResponse,
        target: FrequencyResponse
    ) throws -> CorrectionCurve {
        try makeCurve(
            measurement: measurement,
            target: target,
            measurementConfidence: nil
        )
    }
}

struct BaselineCorrectionPolicy: CorrectionPolicy {
    var kind: DeviceCorrectionPolicyKind
    var domain: MeasurementDomain = .unknown

    func makeCurve(
        measurement: FrequencyResponse,
        target: FrequencyResponse,
        measurementConfidence: MeasurementConfidenceCurve?
    ) throws -> CorrectionCurve {
        let measurement = measurement.normalized()
        let target = target.normalized()
        let grid = Self.logFrequencies(count: 181)
        let available = grid.compactMap { frequency -> (Double, Double)? in
            guard let measured = measurement.magnitude(at: frequency),
                  let desired = target.magnitude(at: frequency) else { return nil }
            return (frequency, desired - measured)
        }
        guard available.count >= 24 else { throw PolicyError.insufficientOverlap }

        let frequencies = available.map(\.0)
        let safe = SafeCorrectionProcessing.process(available.map(\.1), frequencies: frequencies, interferenceRanges: MeasurementDomainPolicy.metadata[domain]?.interferenceRanges ?? [])
        let points = available.indices.map { index in
            let frequency = frequencies[index]
            let evidence = measurementConfidence?.confidence(at: frequency)
                ?? MeasurementConfidenceCurve.unknownValue
            let reliability = recommendedConfidence(frequency: frequency, values: safe, index: index)
            let confidence = kind == .recommended ? evidence * reliability : 1
            let gain = kind == .recommended ? safe[index] * sqrt(max(0, confidence)) : safe[index]
            return CorrectionCurve.Point(frequency: frequency, gainDB: gain, confidence: confidence)
        }
        return CorrectionCurve(points: points)
    }

    private func recommendedConfidence(
        frequency: Double,
        values: [Double],
        index: Int
    ) -> Double {
        let frequencyConfidence: Double
        switch frequency {
        case ..<30: frequencyConfidence = max(0, (frequency - 20) / 10)
        case 30...8_000: frequencyConfidence = 1
        case 8_000...16_000: frequencyConfidence = 1 - 0.75 * ((frequency - 8_000) / 8_000)
        default: frequencyConfidence = max(0, 0.25 * (20_000 - frequency) / 4_000)
        }
        guard index > 0, index + 1 < values.count else { return frequencyConfidence * 0.5 }
        let curvature = abs(values[index - 1] - 2 * values[index] + values[index + 1])
        let stability = 1 / (1 + curvature * 0.8)
        return min(1, max(0, frequencyConfidence * stability))
    }

    private static func logFrequencies(count: Int) -> [Double] {
        (0..<count).map { index in
            let position = Double(index) / Double(max(1, count - 1))
            return 20 * pow(1_000, position)
        }
    }

    enum PolicyError: LocalizedError, Equatable {
        case insufficientOverlap

        var errorDescription: String? {
            "The measurement and target do not overlap across enough of the audible range."
        }
    }
}

protocol PEQOptimizer {
    func optimize(
        curve: CorrectionCurve,
        filterCount: Int,
        sampleRate: Double
    ) -> [EQBand]
}

struct NativePEQOptimizer: PEQOptimizer {
    var settings = AutoEQSettings()
    var lockedBands: [EQBand] = []
    var mode: DeviceCorrectionPolicyKind = .exactTarget
    var averagesUpperTreble = true
    var combinedBoostCeiling: Double = 6

    private func bounded(_ band: EQBand, sampleRate: Double) -> EQBand {
        var result = band
        result.frequency = min(min(20_000, sampleRate * 0.49), max(20, band.frequency))
        result.gain = min(settings.maximumGain, max(settings.minimumGain, band.gain ?? 0))
        let policyQ = mode == .recommended && result.frequency > 6_000 ? 2.0 : settings.maximumQ
        result.q = max(settings.minimumQ, min(policyQ, band.q ?? 0.707))
        return result
    }

    func optimize(
        curve: CorrectionCurve,
        filterCount requestedCount: Int,
        sampleRate: Double
    ) -> [EQBand] {
        // The requested count is a ceiling; the objective chooses the useful count.
        let count = min(20, max(0, requestedCount))
        guard settings.isValid, sampleRate.isFinite, sampleRate > 40, lockedBands.count <= count else { return lockedBands }
        let usable = curve.points.filter {
            $0.frequency >= settings.minimumFrequency && $0.frequency <= settings.maximumFrequency && $0.frequency < sampleRate * 0.49
        }
        guard !usable.isEmpty else { return [] }
        var bands: [EQBand] = lockedBands
        var bestLoss = loss(bands: bands, points: usable, sampleRate: sampleRate)

        for _ in 0..<max(0, count - lockedBands.count) {
            guard !Task.isCancelled else { return bands }
            if fitIsSufficient(bands: bands, points: usable, sampleRate: sampleRate) { break }
            let residual = residuals(bands: bands, points: usable, sampleRate: sampleRate)
            let ranked = candidates(residual: residual, points: usable)
                .map { bounded($0, sampleRate: sampleRate) }
                .map { ($0, loss(bands: bands + [$0], points: usable, sampleRate: sampleRate)) }
                .sorted { $0.1 < $1.1 }
            // A useful seed can initially overlap another filter. Judge it after
            // joint refinement instead of rejecting its unrefined response.
            var bestProposal: [EQBand]?
            var proposedLoss = bestLoss
            for (candidate, _) in ranked.prefix(3) {
                let proposed = refine(bands: bands + [candidate], points: usable, sampleRate: sampleRate)
                let score = loss(bands: proposed, points: usable, sampleRate: sampleRate)
                if score < proposedLoss { bestProposal = proposed; proposedLoss = score }
            }
            guard let proposed = bestProposal, bestLoss - proposedLoss > 0.0005 else { break }
            bands = proposed
            bestLoss = proposedLoss
        }
        bands = refine(bands: bands, points: usable, sampleRate: sampleRate)
        bestLoss = loss(bands: bands, points: usable, sampleRate: sampleRate)
        // Backward elimination re-fits the remaining free filters before deciding.
        for index in bands.indices.reversed() where !bands[index].isLocked {
            var proposed = bands
            proposed.remove(at: index)
            proposed = refine(bands: proposed, points: usable, sampleRate: sampleRate)
            let score = loss(bands: proposed, points: usable, sampleRate: sampleRate)
            if score <= bestLoss + 0.0005 { bands = proposed; bestLoss = score }
        }
        // Final dense-grid check catches combined overshoot between fit samples.
        // Locked response is immutable, including intentional boosts over the ceiling.
        let ceiling = max(combinedBoostCeiling, combinedPeak(lockedBands, sampleRate: sampleRate))
        for _ in 0..<120 {
            guard combinedPeak(bands, sampleRate: sampleRate) > ceiling + 0.01 else { break }
            var changed = false
            for index in bands.indices where !bands[index].isLocked && (bands[index].gain ?? 0) > 0 {
                bands[index].gain = (bands[index].gain ?? 0) * 0.95
                changed = true
            }
            if !changed { break }
        }
        return bands.sorted { $0.frequency < $1.frequency }
    }

    private func combinedPeak(_ bands: [EQBand], sampleRate: Double) -> Double {
        let parsed = ParsedEQ(preampDB: 0, bands: bands, warnings: [])
        let frequencies = (0..<1025).map { index in
            20 * pow(min(1_000, sampleRate * 0.49 / 20), Double(index) / 1024)
        }
        return EQResponseCalculator().gainsDB(at: frequencies, parsed: parsed, sampleRate: sampleRate).max() ?? 0
    }

    private func fitIsSufficient(bands: [EQBand], points: [CorrectionCurve.Point], sampleRate: Double) -> Bool {
        let residual = residuals(bands: bands, points: points, sampleRate: sampleRate)
        var weightedSquares = 0.0
        var weightSum = 0.0
        var peak = 0.0
        for (point, error) in zip(points, residual) {
            let weight = max(0.02, min(1, point.confidence))
            weightedSquares += error * error * weight
            weightSum += weight
            peak = max(peak, abs(error) * sqrt(weight))
        }
        let rms = sqrt(weightedSquares / max(weightSum, 1e-9))
        return rms <= (mode == .recommended ? 0.20 : 0.15) && peak <= (mode == .recommended ? 0.65 : 0.5)
    }

    private func candidates(
        residual: [Double],
        points: [CorrectionCurve.Point]
    ) -> [EQBand] {
        let ranked = residual.indices.sorted {
            abs(residual[$0]) * max(0.02, points[$0].confidence)
                > abs(residual[$1]) * max(0.02, points[$1].confidence)
        }
        // Cover separate residual features, rather than spending every seed on
        // adjacent samples of the largest peak. Try both narrower and broader Q.
        var centers: [Int] = []
        for index in ranked where abs(residual[index]) >= 0.2 {
            let amplitude = abs(residual[index])
            guard (index == 0 || amplitude >= abs(residual[index - 1])),
                  (index == residual.count - 1 || amplitude >= abs(residual[index + 1])),
                  centers.allSatisfy({ abs(log2(points[index].frequency / points[$0].frequency)) >= 0.35 }) else { continue }
            centers.append(index)
            if centers.count == 12 { break }
        }
        var result = centers.flatMap { index in
            let q = estimatedQ(residual: residual, points: points, peakIndex: index)
            return [0.65, 1.0, 1.6].map { scale in
                EQBand(kind: .peaking, frequency: points[index].frequency,
                       gain: min(settings.maximumGain, max(settings.minimumGain, residual[index])),
                       q: min(settings.maximumQ, max(settings.minimumQ, q * scale)))
            }
        }

        for (kind, frequencies) in [
            (EQBand.Kind.lowShelf, [55.0, 90, 140, 220, 350]),
            (.highShelf, [2_500.0, 4_000, 6_500, 10_000, 14_000])
        ] {
            for frequency in frequencies {
                let relevant = points.indices.filter { index in
                    kind == .lowShelf
                        ? points[index].frequency <= frequency
                        : points[index].frequency >= frequency
                }
                guard !relevant.isEmpty else { continue }
                let weight = relevant.map { max(0.02, points[$0].confidence) }.reduce(0, +)
                let gain = relevant.map {
                    residual[$0] * max(0.02, points[$0].confidence)
                }.reduce(0, +) / max(weight, 1e-9)
                guard abs(gain) >= 0.25 else { continue }
                result.append(EQBand(
                    kind: kind,
                    frequency: frequency,
                    gain: min(settings.maximumGain, max(settings.minimumGain, gain)),
                    q: 0.707
                ))
            }
        }
        return result
    }

    private func refine(
        bands initial: [EQBand],
        points: [CorrectionCurve.Point],
        sampleRate: Double
    ) -> [EQBand] {
        var bands = initial
        let frequencies = points.map(\.frequency)
        let calculator = EQResponseCalculator()
        var bandResponses = bands.map { calculator.gainsDB(at: frequencies, parsed: .init(preampDB: 0, bands: [$0], warnings: []), sampleRate: sampleRate) }
        var response = calculator.gainsDB(at: frequencies, parsed: .init(preampDB: 0, bands: bands, warnings: []), sampleRate: sampleRate)
        var bestLoss = loss(bands: bands, points: points, sampleRate: sampleRate, response: response)
        let passes: [(gain: Double, octave: Double, qScale: Double)] = [
            (1.5, 0.35, 1.45), (0.6, 0.14, 1.18), (0.2, 0.05, 1.07), (0.06, 0.015, 1.025)
        ]
        let maximumFrequency = min(20_000, sampleRate * 0.49)

        for pass in passes {
            for _ in 0..<2 {
                for index in bands.indices where !bands[index].isLocked {
                    guard !Task.isCancelled else { return bands }
                    var variants: [EQBand] = []
                    for delta in [-pass.gain, pass.gain] {
                        var candidate = bands[index]
                        candidate.gain = min(settings.maximumGain, max(settings.minimumGain, (candidate.gain ?? 0) + delta))
                        variants.append(candidate)
                    }
                    for delta in [-pass.octave, pass.octave] {
                        var candidate = bands[index]
                        candidate.frequency = min(
                            maximumFrequency,
                            max(20, candidate.frequency * pow(2, delta))
                        )
                        variants.append(candidate)
                    }
                    for scale in [1 / pass.qScale, pass.qScale] {
                        var candidate = bands[index]
                        candidate.q = min(settings.maximumQ, max(settings.minimumQ, (candidate.q ?? 0.707) * scale))
                        variants.append(candidate)
                    }
                    for candidate in variants {
                        var proposed = bands
                        proposed[index] = bounded(candidate, sampleRate: sampleRate)
                        let values = calculator.gainsDB(at: frequencies, parsed: .init(preampDB: 0, bands: [proposed[index]], warnings: []), sampleRate: sampleRate)
                        let proposedResponse = points.indices.map { response[$0] - bandResponses[index][$0] + values[$0] }
                        let proposedLoss = loss(bands: proposed, points: points, sampleRate: sampleRate, response: proposedResponse)
                        if proposedLoss < bestLoss {
                            bands = proposed
                            response = proposedResponse
                            bandResponses[index] = values
                            bestLoss = proposedLoss
                        }
                    }
                }
            }
        }
        return bands
    }

    private func residuals(
        bands: [EQBand],
        points: [CorrectionCurve.Point],
        sampleRate: Double
    ) -> [Double] {
        let response = EQResponseCalculator().gainsDB(at: points.map(\.frequency),
            parsed: .init(preampDB: 0, bands: bands, warnings: []), sampleRate: sampleRate)
        return zip(points, response).map { $0.gainDB - $1 }
    }

    private func loss(
        bands: [EQBand],
        points: [CorrectionCurve.Point],
        sampleRate: Double,
        response: [Double]? = nil
    ) -> Double {
        let residual = response.map { zip(points, $0).map { $0.gainDB - $1 } }
            ?? residuals(bands: bands, points: points, sampleRate: sampleRate)
        let weights = points.map { max(0.02, min(1, $0.confidence)) }
        let high = points.indices.filter { points[$0].frequency > 10_000 }
        let highMean = high.isEmpty ? 0 : high.map { residual[$0] }.reduce(0, +) / Double(high.count)
        let weightedSquares = points.indices.map { index in
            let error = averagesUpperTreble && points[index].frequency > 10_000 ? highMean : residual[index]
            return error * error * weights[index]
        }
        let penalty = bands.filter { !$0.isLocked }.reduce(0.0) { sum, band in
            let sharpness = max(0, (band.q ?? 0.707) - 2)
            return sum + (mode == .recommended ? 0.006 : 0.003) + sharpness * sharpness * (mode == .recommended ? 0.001 : 0.0003)
                + pow(max(0, abs(band.gain ?? 0) - 6), 2) * 0.002
        }
        let peak = zip(points, residual).map { $0.0.gainDB - $0.1 }.max() ?? 0
        let boostPenalty = pow(max(0, peak - combinedBoostCeiling), 2) * 10
        return weightedSquares.reduce(0, +)
            / max(weights.reduce(0, +), 1e-9) + penalty + boostPenalty
    }

    private func estimatedQ(
        residual: [Double],
        points: [CorrectionCurve.Point],
        peakIndex: Int
    ) -> Double {
        let peak = residual[peakIndex]
        let threshold = abs(peak) * 0.5
        var lower = peakIndex
        var upper = peakIndex
        while lower > 0,
              residual[lower - 1].sign == peak.sign,
              abs(residual[lower - 1]) >= threshold { lower -= 1 }
        while upper + 1 < residual.count,
              residual[upper + 1].sign == peak.sign,
              abs(residual[upper + 1]) >= threshold { upper += 1 }
        let bandwidth = max(0.2, log2(points[upper].frequency / points[lower].frequency))
        let q = 1 / (2 * sinh(log(2) / 2 * bandwidth))
        return min(6, max(0.3, q))
    }
}

struct DeviceCorrectionEngine {
    func generate(
        deviceName: String,
        measurement: FrequencyResponse,
        target: FrequencyResponse = .flat(),
        targetSelection: DeviceCorrectionTargetSelection = .flat,
        policy: DeviceCorrectionPolicyKind,
        filterCount: Int = 20,
        sampleRate: Double,
        settings: AutoEQSettings = .init(),
        lockedBands: [EQBand] = [],
        preservingID id: UUID? = nil
    ) throws -> DeviceCorrectionProfile {
        let local = DeviceCorrectionMeasurement.local(response: measurement)
        return try generate(
            deviceName: deviceName,
            measurements: [local],
            target: target,
            targetSelection: targetSelection,
            policy: policy,
            filterCount: filterCount,
            sampleRate: sampleRate,
            settings: settings,
            lockedBands: lockedBands,
            preservingID: id
        )
    }

    func generate(
        deviceName: String,
        measurements: [DeviceCorrectionMeasurement],
        target: FrequencyResponse = .flat(),
        targetSelection: DeviceCorrectionTargetSelection = .flat,
        policy: DeviceCorrectionPolicyKind,
        filterCount: Int = 20,
        sampleRate: Double,
        settings: AutoEQSettings = .init(),
        lockedBands: [EQBand] = [],
        preservingID id: UUID? = nil,
        preservingSources: [DeviceMeasurementReference]? = nil,
        targetConfidence: MeasurementConfidenceCurve? = nil
    ) throws -> DeviceCorrectionProfile {
        let consensus = try MeasurementConsensusBuilder().build(
            deviceName: deviceName,
            measurements: measurements
        )
        return try generate(
            deviceName: deviceName,
            consensus: consensus,
            target: target,
            targetSelection: targetSelection,
            policy: policy,
            filterCount: filterCount,
            sampleRate: sampleRate,
            settings: settings,
            lockedBands: lockedBands,
            preservingID: id,
            preservingSources: preservingSources,
            targetConfidence: targetConfidence
        )
    }

    func generate(
        deviceName: String,
        consensus: MeasurementConsensus,
        target: FrequencyResponse = .flat(),
        targetSelection: DeviceCorrectionTargetSelection = .flat,
        policy: DeviceCorrectionPolicyKind,
        filterCount: Int = 20,
        sampleRate: Double,
        settings: AutoEQSettings = .init(),
        lockedBands: [EQBand] = [],
        preservingID id: UUID? = nil,
        preservingSources: [DeviceMeasurementReference]? = nil,
        targetConfidence: MeasurementConfidenceCurve? = nil
    ) throws -> DeviceCorrectionProfile {
        guard sampleRate.isFinite, sampleRate > 40, lockedBands.count <= 20,
              ReferenceCorrection.validFilters(lockedBands, sampleRate: sampleRate), settings.isValid else {
            throw GenerationError.invalidConstraints
        }
        let optimizerConfidence = targetConfidence.map {
            consensus.confidence.combinedForDifference(with: $0)
        } ?? consensus.confidence
        let curve = try BaselineCorrectionPolicy(kind: policy, domain: consensus.sources.first.map { MeasurementDomain(source: $0) } ?? .unknown).makeCurve(
            measurement: consensus.response,
            target: target,
            measurementConfidence: optimizerConfidence
        )
        guard settings.isValid else { throw GenerationError.invalidConstraints }
        let filters = NativePEQOptimizer(settings: settings, lockedBands: lockedBands, mode: policy).optimize(
            curve: curve,
            filterCount: filterCount,
            sampleRate: sampleRate
        )
        var profile = DeviceCorrectionProfile(
            id: id ?? UUID(),
            deviceName: deviceName,
            deviceIdentity: consensus.sources.compactMap(\.deviceIdentity).first,
            policy: policy,
            measurement: consensus.response,
            measurementConfidence: consensus.confidence,
            sources: preservingSources ?? consensus.sources,
            measurementSnapshots: consensus.snapshots,
            targetSelection: targetSelection,
            target: target,
            curve: curve,
            filters: filters,
            preampDB: 0
        )
        profile.autoEQSettings = settings
        return profile
    }

    enum GenerationError: LocalizedError {
        case invalidConstraints
        var errorDescription: String? { "Enter valid frequency, gain, and Q ranges." }
    }
}

/// Independently implemented AutoEq-style stages. Values are correction (target − measurement).
/// Each stage is exposed internally for regression tests; no processing runs on the audio callback.
enum SafeCorrectionProcessing {
    static func smooth(_ values: [Double], frequencies: [Double], octaves: Double) -> [Double] {
        values.indices.map { index in
            var total = 0.0, weight = 0.0
            for other in values.indices {
                let distance = abs(log2(frequencies[other] / frequencies[index]))
                guard distance <= octaves else { continue }
                let w = exp(-8 * pow(distance / octaves, 2))
                total += values[other] * w
                weight += w
            }
            return total / max(weight, 1e-12)
        }
    }

    static func limit(_ values: [Double], frequencies: [Double], reverse: Bool, slope: Double = 18) -> [Double] {
        guard values.count > 1 else { return values }
        var result = values
        let order = reverse ? Array((0..<values.count - 1).reversed()) : Array(1..<values.count)
        for index in order {
            let previous = reverse ? index + 1 : index - 1
            let width = abs(log2(frequencies[index] / frequencies[previous]))
            result[index] = min(result[index], result[previous] + slope * width)
        }
        return result
    }

    static func protectionMask(_ values: [Double], frequencies: [Double]) -> [Bool] {
        guard values.count > 2 else { return values.map { _ in false } }
        var mask = values.map { _ in false }
        for index in 1..<values.count - 1 where values[index] > 0 {
            guard values[index] > values[index - 1], values[index] >= values[index + 1] else { continue }
            let neighbors = values.indices.filter { abs(log2(frequencies[$0] / frequencies[index])) <= 0.35 }
            let floor = neighbors.map { values[$0] }.min() ?? values[index]
            if values[index] - floor > 3 { for neighbor in neighbors { mask[neighbor] = true } }
        }
        return mask
    }

    static func process(_ raw: [Double], frequencies: [Double], interferenceRanges: [ClosedRange<Double>] = []) -> [Double] {
        let normal = smooth(raw, frequencies: frequencies, octaves: 1 / 12)
        let treble = smooth(raw, frequencies: frequencies, octaves: 2)
        let dual = raw.indices.map { i -> Double in
            let t = min(1, max(0, log2(frequencies[i] / 6_000) / log2(8_000.0 / 6_000)))
            let blend = t * t * (3 - 2 * t)
            return normal[i] * (1 - blend) + treble[i] * blend
        }
        var mask = protectionMask(dual, frequencies: frequencies)
        for index in mask.indices where interferenceRanges.contains(where: { $0.contains(frequencies[index]) }) {
            mask[index] = dual[index] > 0
        }
        let broad = smooth(dual, frequencies: frequencies, octaves: 0.5)
        let protected = dual.indices.map { mask[$0] ? min(dual[$0], broad[$0]) : dual[$0] }
        let left = limit(protected, frequencies: frequencies, reverse: false)
        let right = limit(protected, frequencies: frequencies, reverse: true)
        let limited = dual.indices.map { i -> Double in
            let t = min(1, max(0, log2(frequencies[i] / 6_000) / log2(10_000.0 / 6_000)))
            return min(6, max(-12, min(left[i], right[i]) * (1 - 0.5 * t)))
        }
        return smooth(limited, frequencies: frequencies, octaves: 1 / 6)
    }
}

struct MeasurementDomainPolicy {
    var interferenceRanges: [ClosedRange<Double>]
    // Concha protection is attached to the measured domain, never to a UI category.
    static let metadata: [MeasurementDomain: MeasurementDomainPolicy] = [
        .bk5128OverEar: .init(interferenceRanges: [8_000...10_000]),
        .grasOverEar: .init(interferenceRanges: [8_000...10_000]),
        .bk5128InEar: .init(interferenceRanges: []),
        .iec711InEar: .init(interferenceRanges: []),
        .unknown: .init(interferenceRanges: [])
    ]
}
