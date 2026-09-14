import Foundation

enum SimpleEQRange: String, CaseIterable, Identifiable, Sendable {
    case bass
    case mids
    case treble

    var id: Self { self }

    var title: String {
        switch self {
        case .bass: return "Bass"
        case .mids: return "Mids"
        case .treble: return "Treble"
        }
    }

    var frequencyDescription: String {
        switch self {
        case .bass: return "Broad low shelf"
        case .mids: return "Broad midrange"
        case .treble: return "Broad high shelf"
        }
    }
}

/// Legacy graphic-EQ projection retained for compatibility tests; not used by live tone controls.
/// Smooth basis curves avoid hard frequency boundaries. A least-squares fit
/// recovers the knob values from manual/imported graphic-EQ edits, while knob
/// movement adds its broad curve without flattening existing detail.
enum SimpleEQControl {
    static let gainRange = -12.0...12.0
    static let step = 0.5

    private struct Sample {
        var bandIndex: Int
        var gain: Double
        var basis: [Double]
    }

    private struct Model {
        var samples: [Sample]
        var activeRangeIndexes: [Int]
        var coefficients: [Double]
    }

    static func value(for range: SimpleEQRange, in bands: [EQBand]) -> Double? {
        guard let model = model(for: bands),
              let rangeIndex = SimpleEQRange.allCases.firstIndex(of: range),
              let coefficientIndex = model.activeRangeIndexes.firstIndex(of: rangeIndex) else {
            return nil
        }
        return clamp(model.coefficients[coefficientIndex])
    }

    static func setting(
        _ requestedValue: Double,
        for range: SimpleEQRange,
        in bands: [EQBand]
    ) -> [EQBand] {
        guard let model = model(for: bands),
              let rangeIndex = SimpleEQRange.allCases.firstIndex(of: range),
              let coefficientIndex = model.activeRangeIndexes.firstIndex(of: rangeIndex) else {
            return bands
        }
        let target = quantized(clamp(requestedValue))
        let difference = target - model.coefficients[coefficientIndex]
        var updated = bands

        for sample in model.samples {
            let influence = sample.basis[rangeIndex]
            updated[sample.bandIndex].gain = clamp(sample.gain + difference * influence)
        }
        return updated
    }

    private static func model(for bands: [EQBand]) -> Model? {
        let samples = bands.enumerated().compactMap { index, band -> Sample? in
            guard band.enabled, usesGain(band.kind) else { return nil }
            return Sample(
                bandIndex: index,
                gain: band.gain ?? 0,
                basis: basis(at: band.frequency)
            )
        }
        guard !samples.isEmpty else { return nil }

        // Only expose a control when at least one graphic band is primarily
        // represented by that curve. Sparse custom layouts therefore remain
        // predictable instead of fabricating controls with no useful anchor.
        let activeRangeIndexes = Array(Set(samples.compactMap { sample -> Int? in
            guard let strongest = sample.basis.enumerated().max(by: {
                $0.element < $1.element
            }), strongest.element > 0.05 else { return nil }
            return strongest.offset
        })).sorted()
        guard !activeRangeIndexes.isEmpty else { return nil }

        var normal = Array(
            repeating: Array(repeating: 0.0, count: activeRangeIndexes.count),
            count: activeRangeIndexes.count
        )
        var rightHandSide = Array(repeating: 0.0, count: activeRangeIndexes.count)
        for sample in samples {
            let row = activeRangeIndexes.map { sample.basis[$0] }
            for column in row.indices {
                rightHandSide[column] += row[column] * sample.gain
                for otherColumn in row.indices {
                    normal[column][otherColumn] += row[column] * row[otherColumn]
                }
            }
        }
        // A tiny regularizer makes unusual sparse layouts numerically stable
        // without materially changing fitted values.
        for index in normal.indices { normal[index][index] += 1e-9 }
        guard let coefficients = solve(normal, rightHandSide) else { return nil }
        return Model(
            samples: samples,
            activeRangeIndexes: activeRangeIndexes,
            coefficients: coefficients
        )
    }

    /// The three curves form a smooth partition across logarithmic frequency.
    /// Bass fades into mids from 120–500 Hz; mids fade into treble from 2–8 kHz.
    private static func basis(at requestedFrequency: Double) -> [Double] {
        let frequency = max(1, requestedFrequency.isFinite ? requestedFrequency : 1)
        let bass = 1 - logSmootherStep(frequency, from: 120, to: 500)
        let treble = logSmootherStep(frequency, from: 2_000, to: 8_000)
        let mids = max(0, 1 - bass - treble)
        return [bass, mids, treble]
    }

    private static func logSmootherStep(
        _ frequency: Double,
        from lowerFrequency: Double,
        to upperFrequency: Double
    ) -> Double {
        let position = log(frequency / lowerFrequency) / log(upperFrequency / lowerFrequency)
        let x = min(1, max(0, position))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

    private static func solve(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        guard !matrix.isEmpty, matrix.count == vector.count else { return nil }
        var matrix = matrix
        var vector = vector

        for pivot in matrix.indices {
            guard let bestRow = (pivot..<matrix.count).max(by: {
                abs(matrix[$0][pivot]) < abs(matrix[$1][pivot])
            }), abs(matrix[bestRow][pivot]) > 1e-12 else { return nil }
            if bestRow != pivot {
                matrix.swapAt(bestRow, pivot)
                vector.swapAt(bestRow, pivot)
            }

            let divisor = matrix[pivot][pivot]
            for column in matrix[pivot].indices {
                matrix[pivot][column] /= divisor
            }
            vector[pivot] /= divisor

            for row in matrix.indices where row != pivot {
                let factor = matrix[row][pivot]
                guard factor != 0 else { continue }
                for column in matrix[row].indices {
                    matrix[row][column] -= factor * matrix[pivot][column]
                }
                vector[row] -= factor * vector[pivot]
            }
        }
        return vector
    }

    private static func usesGain(_ kind: EQBand.Kind) -> Bool {
        kind == .peaking || kind == .lowShelf || kind == .highShelf
    }

    private static func clamp(_ value: Double) -> Double {
        min(gainRange.upperBound, max(gainRange.lowerBound, value))
    }

    private static func quantized(_ value: Double) -> Double {
        (value / step).rounded() * step
    }
}


/// Independent tone controls. Older profiles decode to neutral without projecting User EQ.
struct SimpleToneSettings: Codable, Hashable, Sendable {
    static let gainRange = -12.0...12.0
    static let step = 0.5
    var bassDB: Double = 0
    var midsDB: Double = 0
    var trebleDB: Double = 0
    var isNeutral: Bool { bassDB == 0 && midsDB == 0 && trebleDB == 0 }

    subscript(_ range: SimpleEQRange) -> Double {
        get { switch range { case .bass: return bassDB; case .mids: return midsDB; case .treble: return trebleDB } }
        set {
            let value = newValue.isFinite ? min(12, max(-12, (newValue / Self.step).rounded() * Self.step)) : 0
            switch range { case .bass: bassDB = value; case .mids: midsDB = value; case .treble: trebleDB = value }
        }
    }

    func validate() throws {
        guard [bassDB, midsDB, trebleDB].allSatisfy({ $0.isFinite && Self.gainRange.contains($0) }) else {
            throw ProfileSettingsError.runtime("Tone gains must be between −12 and +12 dB.")
        }
    }
}

enum SimpleToneFilterFactory {
    static let stageID = UUID(uuidString: "43414D49-5455-4E45-544F-4E4500000000")!
    /// Fixed broad shelves and a broad midrange bell, shared by both audio paths.
    static func filters(for settings: SimpleToneSettings, sampleRate: Double) throws -> [EQBand] {
        try settings.validate()
        guard sampleRate.isFinite, sampleRate > 0 else { throw ProcessingGraphError.invalidSampleRate }
        let kinds: [EQBand.Kind] = [.lowShelf, .peaking, .highShelf]
        let frequencies = [200.0, 1000.0, 4000.0]
        return SimpleEQRange.allCases.enumerated().map { index, range in
            EQBand(id: UUID(uuidString: "43414D49-5455-4E45-544F-4E450000000\(index + 1)")!,
                kind: kinds[index], frequency: min(frequencies[index], sampleRate * 0.4),
                gain: settings[range], q: index == 1 ? 0.5 : 0.7071067811865476)
        }
    }
}
