import CamiTuneDomain
import Foundation

enum EQEditorSupport {

    static func resizedBands(_ bands: [EQBand], count requestedCount: Int) -> [EQBand] {
        let target = min(20, max(0, requestedCount))
        // Zero is an explicit reset, not a resize. The normal resize behavior
        // preserves customized filters, which otherwise makes it impossible for
        // the picker to reach zero after any band has been touched.
        guard target > 0 else { return [] }
        let ordered = organizedBands(bands)
        let oldCount = ordered.count
        var customized = ordered.enumerated().compactMap { index, band in
            isDefaultBand(band, index: index, count: oldCount) ? nil : band
        }

        // The picker count is authoritative. If more customized filters exist
        // than can fit, retain a frequency-spaced subset instead of refusing to
        // shrink the editor back down.
        if customized.count > target {
            customized = frequencySpacedSubset(customized, count: target)
        }
        var candidateFrequencies = distributedFrequencies(count: target)

        // Preserve custom filters and remove their nearest default slots before
        // recreating the remaining evenly distributed bands.
        for custom in customized where !candidateFrequencies.isEmpty {
            let nearest = candidateFrequencies.indices.min {
                abs(log(candidateFrequencies[$0] / max(custom.frequency, 1)))
                    < abs(log(candidateFrequencies[$1] / max(custom.frequency, 1)))
            }
            if let nearest { candidateFrequencies.remove(at: nearest) }
        }

        var rebuilt = customized
        rebuilt.append(contentsOf: candidateFrequencies.map {
            EQBand(kind: .peaking, frequency: $0, gain: 0, q: 1)
        })
        rebuilt = organizedBands(rebuilt)
        if let first = rebuilt.indices.first, isUntouchedValues(rebuilt[first]) {
            rebuilt[first].kind = .lowShelf
        }
        if let last = rebuilt.indices.last,
           last != rebuilt.indices.first,
           isUntouchedValues(rebuilt[last]) {
            rebuilt[last].kind = .highShelf
        }
        return rebuilt
    }

    static func organizedBands(_ bands: [EQBand]) -> [EQBand] {
        bands.sorted { lhs, rhs in
            let lhsFrequency = lhs.frequency.isFinite
                ? lhs.frequency
                : Double.greatestFiniteMagnitude
            let rhsFrequency = rhs.frequency.isFinite
                ? rhs.frequency
                : Double.greatestFiniteMagnitude
            if lhsFrequency != rhsFrequency { return lhsFrequency < rhsFrequency }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func shouldRefitWhenReducing(_ bands: [EQBand], to requestedCount: Int) -> Bool {
        let target = min(20, max(0, requestedCount))
        return target < bands.count
            && !bands.isEmpty
            && bands.allSatisfy(hasActiveValue)
    }

    /// Recreates a smaller PEQ whose magnitude response follows the existing
    /// filter curve. The normal user preamp is intentionally outside this fit.
    static func responseFittedBands(
        _ bands: [EQBand],
        count requestedCount: Int,
        sampleRate requestedSampleRate: Double
    ) -> [EQBand] {
        let target = min(20, max(0, requestedCount))
        guard target > 0, !bands.isEmpty else { return [] }
        let sampleRate = requestedSampleRate.isFinite && requestedSampleRate > 0
            ? requestedSampleRate
            : 48_000
        let response = EQResponseCalculator().calculate(
            parsed: ParsedEQ(preampDB: 0, bands: bands, warnings: []),
            sampleRate: sampleRate,
            count: 181
        )
        let curve = CorrectionCurve(points: response.map {
            .init(frequency: $0.frequency, gainDB: $0.gainDB, confidence: 1)
        })
        let optimized = NativePEQOptimizer().optimize(
            curve: curve,
            filterCount: target,
            sampleRate: sampleRate
        )
        // The optimizer may finish early when another filter would not improve
        // the response. Retain the requested editor count with neutral bands.
        return resizedBands(optimized, count: target)
    }

    static func setKind(_ kind: EQBand.Kind, for band: inout EQBand) {
        band.kind = kind
        band.q = band.q ?? 0.707
        band.bandwidth = nil
        band.gain = usesGain(kind) ? (band.gain ?? 0) : nil
    }

    private static func distributedFrequencies(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let minimum = 31.0
        let maximum = 16_000.0
        return (0..<count).map { index in
            let position = count == 1 ? 0.5 : Double(index) / Double(count - 1)
            return minimum * pow(maximum / minimum, position)
        }
    }

    private static func frequencySpacedSubset(_ bands: [EQBand], count: Int) -> [EQBand] {
        guard count > 0 else { return [] }
        let ordered = organizedBands(bands)
        guard count < ordered.count else { return ordered }
        if count == 1 { return [ordered[ordered.count / 2]] }
        return (0..<count).map { index in
            let position = Double(index) * Double(ordered.count - 1) / Double(count - 1)
            return ordered[Int(position.rounded())]
        }
    }

    private static func hasActiveValue(_ band: EQBand) -> Bool {
        guard band.enabled else { return false }
        switch band.kind {
        case .peaking, .lowShelf, .highShelf:
            return abs(band.gain ?? 0) > 0.000_001
        case .lowPass, .highPass, .notch, .allPass:
            return true
        }
    }

    private static func isDefaultBand(_ band: EQBand, index: Int, count: Int) -> Bool {
        guard count > 0 else { return false }
        let expected = distributedFrequencies(count: count)[index]
        let expectedKind: EQBand.Kind = count > 1 && index == 0
            ? .lowShelf
            : (count > 1 && index == count - 1 ? .highShelf : .peaking)
        return abs(log(max(band.frequency, 1) / expected)) < 0.015
            && abs((band.gain ?? 0)) < 0.0001
            && abs((band.q ?? 1) - 1) < 0.0001
            && band.enabled
            && band.kind == expectedKind
    }

    private static func isUntouchedValues(_ band: EQBand) -> Bool {
        abs((band.gain ?? 0)) < 0.0001 && abs((band.q ?? 1) - 1) < 0.0001
    }

    private static func usesGain(_ kind: EQBand.Kind) -> Bool {
        kind == .peaking || kind == .lowShelf || kind == .highShelf
    }
}
