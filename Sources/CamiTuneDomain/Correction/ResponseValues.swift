import Foundation

package struct FrequencyResponse: Codable, Hashable, Sendable {
    package struct Point: Codable, Hashable, Sendable, Identifiable {
        package init(frequency: Double, magnitudeDB: Double) {
            self.frequency = frequency
            self.magnitudeDB = magnitudeDB
        }

        package var frequency: Double
        package var magnitudeDB: Double
        package var id: Double { frequency }
    }

    package var name: String
    package var points: [Point]

    package init(name: String, points: [Point]) {
        self.name = name
        self.points = Self.canonicalized(points)
    }

    package func magnitude(at frequency: Double) -> Double? {
        guard frequency.isFinite, frequency > 0,
              let first = points.first, let last = points.last,
              frequency >= first.frequency, frequency <= last.frequency else { return nil }
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].frequency < frequency { lower = middle + 1 }
            else { upper = middle }
        }
        if lower == 0 { return points[0].magnitudeDB }
        if lower == points.count { return points[lower - 1].magnitudeDB }
        let before = points[lower - 1]
        let after = points[lower]
        let width = log(after.frequency / before.frequency)
        guard width > 0 else { return before.magnitudeDB }
        let position = log(frequency / before.frequency) / width
        return before.magnitudeDB + (after.magnitudeDB - before.magnitudeDB) * position
    }

    /// Shape-preserving cubic interpolation for presentation only. DSP policy,
    /// consensus, and optimizer calculations continue to use `magnitude(at:)`.
    package func displayMagnitude(at frequency: Double) -> Double? {
        guard points.count >= 4,
              frequency.isFinite,
              let first = points.first,
              let last = points.last,
              frequency >= first.frequency,
              frequency <= last.frequency else {
            return magnitude(at: frequency)
        }
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].frequency < frequency { lower = middle + 1 }
            else { upper = middle }
        }
        if lower == 0 || lower == points.count { return magnitude(at: frequency) }
        let leftIndex = lower - 1
        let rightIndex = lower
        let left = points[leftIndex]
        let right = points[rightIndex]
        let x1 = log(left.frequency)
        let x2 = log(right.frequency)
        let width = x2 - x1
        guard width > 0 else { return left.magnitudeDB }

        let centerSlope = (right.magnitudeDB - left.magnitudeDB) / width
        let leftSlope = leftIndex > 0
            ? (left.magnitudeDB - points[leftIndex - 1].magnitudeDB)
                / (x1 - log(points[leftIndex - 1].frequency))
            : centerSlope
        let rightSlope = rightIndex + 1 < points.count
            ? (points[rightIndex + 1].magnitudeDB - right.magnitudeDB)
                / (log(points[rightIndex + 1].frequency) - x2)
            : centerSlope
        let m1 = Self.monotoneTangent(leftSlope, centerSlope)
        let m2 = Self.monotoneTangent(centerSlope, rightSlope)
        let t = (log(frequency) - x1) / width
        let t2 = t * t
        let t3 = t2 * t
        let value = (2 * t3 - 3 * t2 + 1) * left.magnitudeDB
            + (t3 - 2 * t2 + t) * width * m1
            + (-2 * t3 + 3 * t2) * right.magnitudeDB
            + (t3 - t2) * width * m2
        return min(max(left.magnitudeDB, right.magnitudeDB),
                   max(min(left.magnitudeDB, right.magnitudeDB), value))
    }

    package func normalized(referenceRange: ClosedRange<Double> = 300...3_000) -> FrequencyResponse {
        guard let first = points.first, let last = points.last else { return self }
        let lower = max(referenceRange.lowerBound, first.frequency)
        let upper = min(referenceRange.upperBound, last.frequency)
        let reference: [Double]
        if lower < upper {
            reference = (0..<48).compactMap { index in
                let position = Double(index) / 47
                return magnitude(at: lower * pow(upper / lower, position))
            }
        } else {
            reference = points.map(\.magnitudeDB)
        }
        guard !reference.isEmpty else { return self }
        let offset = reference.reduce(0, +) / Double(reference.count)
        return FrequencyResponse(
            name: name,
            points: points.map { .init(frequency: $0.frequency, magnitudeDB: $0.magnitudeDB - offset) }
        )
    }

    package static func flat(name: String = "Flat target") -> FrequencyResponse {
        FrequencyResponse(name: name, points: [
            .init(frequency: 20, magnitudeDB: 0),
            .init(frequency: 20_000, magnitudeDB: 0)
        ])
    }

    private static func canonicalized(_ raw: [Point]) -> [Point] {
        let valid = raw.filter {
            $0.frequency.isFinite && $0.frequency > 0 && $0.magnitudeDB.isFinite
        }.sorted { $0.frequency < $1.frequency }
        var result: [Point] = []
        var index = 0
        while index < valid.count {
            let frequency = valid[index].frequency
            var total = 0.0
            var count = 0
            while index < valid.count, valid[index].frequency == frequency {
                total += valid[index].magnitudeDB
                count += 1
                index += 1
            }
            result.append(.init(frequency: frequency, magnitudeDB: total / Double(count)))
        }
        return result
    }

    private static func monotoneTangent(_ left: Double, _ right: Double) -> Double {
        guard left.isFinite, right.isFinite, left * right > 0 else { return 0 }
        return 2 * left * right / (left + right)
    }
}

package struct CorrectionCurve: Codable, Hashable, Sendable {
    package init(points: [Point]) {
        self.points = points
    }

    package struct Point: Codable, Hashable, Sendable, Identifiable {
        package init(frequency: Double, gainDB: Double, confidence: Double) {
            self.frequency = frequency
            self.gainDB = gainDB
            self.confidence = confidence
        }

        package var frequency: Double
        package var gainDB: Double
        package var confidence: Double
        package var id: Double { frequency }
    }

    package var points: [Point]
}

package struct MeasurementConfidenceCurve: Codable, Hashable, Sendable {
    package init(points: [Point]) {
        self.points = points
    }

    /// Empty points mean confidence was not measured (for example a legacy v1
    /// profile). Unknown evidence is intentionally neutral, not perfect.
    package static let unknownValue = 0.5
    package struct Point: Codable, Hashable, Sendable, Identifiable {
        package init(frequency: Double, confidence: Double) {
            self.frequency = frequency
            self.confidence = confidence
        }

        package var frequency: Double
        package var confidence: Double
        package var id: Double { frequency }
    }

    package var points: [Point]

    package func confidence(at frequency: Double) -> Double {
        guard !points.isEmpty else { return Self.unknownValue }
        guard let first = points.first, let last = points.last else { return Self.unknownValue }
        if frequency <= first.frequency { return first.confidence }
        if frequency >= last.frequency { return last.confidence }
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].frequency < frequency { lower = middle + 1 }
            else { upper = middle }
        }
        let before = points[max(0, lower - 1)]
        let after = points[min(points.count - 1, lower)]
        let width = log(after.frequency / before.frequency)
        guard width > 0 else { return before.confidence }
        let position = log(frequency / before.frequency) / width
        return min(1, max(0, before.confidence + (after.confidence - before.confidence) * position))
    }

    /// Confidence in a response difference depends on both measurements. The
    /// geometric mean creates one optimizer-priority curve without scaling the
    /// requested Device Match magnitude.
    package func combinedForDifference(with other: MeasurementConfidenceCurve) -> Self {
        let frequencies = (0..<181).map { index in
            20 * pow(1_000, Double(index) / 180)
        }
        return .init(points: frequencies.map { frequency in
            .init(
                frequency: frequency,
                confidence: sqrt(
                    confidence(at: frequency) * other.confidence(at: frequency)
                )
            )
        })
    }
}
