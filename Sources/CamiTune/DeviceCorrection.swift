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
        case insufficientOverlap

        var errorDescription: String? {
            switch self {
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

    func makeCurve(
        measurement: FrequencyResponse,
        target: FrequencyResponse,
        measurementConfidence: MeasurementConfidenceCurve?
    ) throws -> CorrectionCurve {
        let measurement = measurement.normalized()
        let target = target.normalized()
        let frequencies = Self.logFrequencies(count: 181)
        let available = frequencies.compactMap { frequency -> (Double, Double)? in
            guard let measured = measurement.magnitude(at: frequency),
                  let desired = target.magnitude(at: frequency) else { return nil }
            return (frequency, desired - measured)
        }
        guard available.count >= 24 else { throw PolicyError.insufficientOverlap }

        let raw = available.map(\.1)
        let smoothed = smooth(raw, radius: kind == .recommended ? 4 : 2)
        let points = available.indices.map { index in
            let frequency = available[index].0
            var confidence = kind == .recommended
                ? recommendedConfidence(frequency: frequency, values: smoothed, index: index)
                : 1
            confidence *= measurementConfidence?.confidence(at: frequency)
                ?? MeasurementConfidenceCurve.unknownValue
            // Confidence controls optimizer priority only. Scaling amplitude here
            // as well would apply the same uncertainty twice.
            let desiredGain = smoothed[index]
            let limits = kind == .recommended
                ? recommendedGainLimits(at: frequency)
                : (lower: -12.0, upper: 12.0)
            return CorrectionCurve.Point(
                frequency: frequency,
                gainDB: min(limits.upper, max(limits.lower, desiredGain)),
                confidence: confidence
            )
        }
        return CorrectionCurve(points: points)
    }

    private func smooth(_ values: [Double], radius: Int) -> [Double] {
        values.indices.map { index in
            var weightedTotal = 0.0
            var totalWeight = 0.0
            for neighbor in max(0, index - radius)...min(values.count - 1, index + radius) {
                let distance = Double(neighbor - index) / Double(max(1, radius))
                let weight = exp(-2 * distance * distance)
                weightedTotal += values[neighbor] * weight
                totalWeight += weight
            }
            return weightedTotal / max(totalWeight, 1e-9)
        }
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

    /// Safety bounds are frequency-dependent policy constraints, independent
    /// of measurement confidence. Confidence remains optimizer priority only.
    private func recommendedGainLimits(at frequency: Double) -> (lower: Double, upper: Double) {
        let anchors: [(frequency: Double, cut: Double, boost: Double)] = [
            (20, 1.0, 0.5),
            (30, 4.0, 2.0),
            (60, 8.0, 4.0),
            (100, 9.0, 5.0),
            (1_000, 9.0, 5.0),
            (3_000, 8.0, 4.0),
            (6_000, 6.0, 3.0),
            (8_000, 4.5, 2.0),
            (12_000, 2.5, 1.0),
            (16_000, 1.2, 0.5),
            (20_000, 0.5, 0.25)
        ]
        guard frequency > anchors[0].frequency else {
            return (-anchors[0].cut, anchors[0].boost)
        }
        guard frequency < anchors[anchors.count - 1].frequency else {
            let last = anchors[anchors.count - 1]
            return (-last.cut, last.boost)
        }
        let upperIndex = anchors.firstIndex { $0.frequency >= frequency } ?? anchors.count - 1
        let lower = anchors[upperIndex - 1]
        let upper = anchors[upperIndex]
        let position = log(frequency / lower.frequency) / log(upper.frequency / lower.frequency)
        let cut = lower.cut + (upper.cut - lower.cut) * position
        let boost = lower.boost + (upper.boost - lower.boost) * position
        return (-cut, boost)
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
    func optimize(
        curve: CorrectionCurve,
        filterCount requestedCount: Int,
        sampleRate: Double
    ) -> [EQBand] {
        // Device Correction currently exposes at most 16 filters, while the
        // normal EQ editor can also use this fitter to reduce layouts up to 20.
        let count = min(20, max(1, requestedCount))
        let usable = curve.points.filter {
            $0.frequency >= 20 && $0.frequency < min(20_000, sampleRate * 0.49)
        }
        guard !usable.isEmpty else { return [] }
        var bands: [EQBand] = []
        var bestLoss = loss(bands: bands, points: usable, sampleRate: sampleRate)

        for _ in 0..<count {
            guard !Task.isCancelled else { return [] }
            let residual = residuals(bands: bands, points: usable, sampleRate: sampleRate)
            let candidates = candidates(residual: residual, points: usable)
            guard let choice = candidates.map({ candidate in
                (candidate, loss: loss(
                    bands: bands + [candidate],
                    points: usable,
                    sampleRate: sampleRate
                ))
            }).min(by: { $0.loss < $1.loss }), choice.loss < bestLoss * 0.995 else { break }
            bands.append(choice.0)
            bestLoss = choice.loss
        }
        bands = refine(bands: bands, points: usable, sampleRate: sampleRate)
        return bands.sorted { $0.frequency < $1.frequency }
    }

    private func candidates(
        residual: [Double],
        points: [CorrectionCurve.Point]
    ) -> [EQBand] {
        let ranked = residual.indices.sorted {
            abs(residual[$0]) * max(0.02, points[$0].confidence)
                > abs(residual[$1]) * max(0.02, points[$1].confidence)
        }
        var result = ranked.prefix(14).compactMap { index -> EQBand? in
            guard abs(residual[index]) >= 0.25 else { return nil }
            return EQBand(
                kind: .peaking,
                frequency: points[index].frequency,
                gain: min(10, max(-12, residual[index])),
                q: estimatedQ(residual: residual, points: points, peakIndex: index)
            )
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
                    gain: min(10, max(-12, gain)),
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
        var bestLoss = loss(bands: bands, points: points, sampleRate: sampleRate)
        let passes: [(gain: Double, octave: Double, qScale: Double)] = [
            (1.5, 0.35, 1.45), (0.6, 0.14, 1.18), (0.2, 0.05, 1.07)
        ]
        let maximumFrequency = min(20_000, sampleRate * 0.49)

        for pass in passes {
            for _ in 0..<2 {
                for index in bands.indices {
                    guard !Task.isCancelled else { return [] }
                    var variants: [EQBand] = []
                    for delta in [-pass.gain, pass.gain] {
                        var candidate = bands[index]
                        candidate.gain = min(10, max(-12, (candidate.gain ?? 0) + delta))
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
                        candidate.q = min(8, max(0.25, (candidate.q ?? 0.707) * scale))
                        variants.append(candidate)
                    }
                    for candidate in variants {
                        var proposed = bands
                        proposed[index] = candidate
                        let proposedLoss = loss(
                            bands: proposed,
                            points: points,
                            sampleRate: sampleRate
                        )
                        if proposedLoss < bestLoss {
                            bands = proposed
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
        let parsed = ParsedEQ(preampDB: 0, bands: bands, warnings: [])
        let calculator = EQResponseCalculator()
        return points.map {
            $0.gainDB - calculator.gainDB(
                at: $0.frequency,
                parsed: parsed,
                sampleRate: sampleRate
            )
        }
    }

    private func loss(
        bands: [EQBand],
        points: [CorrectionCurve.Point],
        sampleRate: Double
    ) -> Double {
        let residual = residuals(bands: bands, points: points, sampleRate: sampleRate)
        let weights = points.map { max(0.02, min(1, $0.confidence)) }
        let weightedSquares = zip(residual, weights).map { residualValue, weight in
            residualValue * residualValue * weight
        }
        return weightedSquares.reduce(0, +)
            / max(weights.reduce(0, +), 1e-9)
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
        filterCount: Int,
        sampleRate: Double,
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
            preservingID: id
        )
    }

    func generate(
        deviceName: String,
        measurements: [DeviceCorrectionMeasurement],
        target: FrequencyResponse = .flat(),
        targetSelection: DeviceCorrectionTargetSelection = .flat,
        policy: DeviceCorrectionPolicyKind,
        filterCount: Int,
        sampleRate: Double,
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
        filterCount: Int,
        sampleRate: Double,
        preservingID id: UUID? = nil,
        preservingSources: [DeviceMeasurementReference]? = nil,
        targetConfidence: MeasurementConfidenceCurve? = nil
    ) throws -> DeviceCorrectionProfile {
        let optimizerConfidence = targetConfidence.map {
            consensus.confidence.combinedForDifference(with: $0)
        } ?? consensus.confidence
        let curve = try BaselineCorrectionPolicy(kind: policy).makeCurve(
            measurement: consensus.response,
            target: target,
            measurementConfidence: optimizerConfidence
        )
        let filters = NativePEQOptimizer().optimize(
            curve: curve,
            filterCount: filterCount,
            sampleRate: sampleRate
        )
        return DeviceCorrectionProfile(
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
    }
}
