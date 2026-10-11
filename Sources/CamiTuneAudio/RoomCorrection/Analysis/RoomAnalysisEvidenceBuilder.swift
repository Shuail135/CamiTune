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

struct RoomSeatEvidence: Sendable {
    var id: UUID
    var isMain: Bool
    var coordinate: SpatialVector3
    var weight: Double
    var magnitudes: [Double]
    var excess: [Double]
    var quality: [Double]
}

struct RoomChannelEvidence: Sendable {
    var points: [RoomAnalysisPoint]
    var seats: [RoomSeatEvidence]
    var independentPositions: Int
    var effectivePositions: Double
    var main: RoomSeatEvidence? { seats.first { $0.isMain } }
}

/// Measurement quality, spatial support and correction decisions stay separate.
/// Neither the acquisition label nor absent legacy diagnostics imply calibration.
struct RoomAnalysisEvidenceBuilder {
    func build(session: RoomMeasurementSession, channel: Int) throws -> RoomChannelEvidence {
        let geometry = RoomGeometrySnapshot(session: session)
        let positions = geometry.positions.filter {
            $0.observations.first { $0.channel == channel }?.hasUsableMagnitude == true
        }.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            return a.id.uuidString < b.id.uuidString
        }
        guard let mainPosition = positions.first(where: \.isMain),
              let main = mainPosition.observations.first(where: { $0.channel == channel }) else {
            return .init(points: [], seats: [], independentPositions: 0, effectivePositions: 0)
        }
        let frequencies = (0..<241).map { 20 * pow(2, Double($0) / 24) }
            .filter { $0 < min(20000, session.context.topology.sampleRate * 0.43) }
        func distance(_ a: SpatialVector3, _ b: SpatialVector3) -> Double {
            sqrt(Double(pow(a.x - b.x, 2) + pow(a.y - b.y, 2) + pow(a.z - b.z, 2)))
        }
        // Merge numerical jitter and points much closer than the seat spacing.
        // This is relative coverage, not an inference of acoustic distance.
        let tolerance = max(0.0001, median(positions.map { distance($0.coordinate, mainPosition.coordinate) }) * 0.02)
        var representatives: [SpatialVector3] = [], coordinateByID: [UUID: SpatialVector3] = [:]
        for position in positions {
            let coordinate = representatives.first { distance($0, position.coordinate) <= tolerance } ?? position.coordinate
            if !representatives.contains(coordinate) { representatives.append(coordinate) }
            coordinateByID[position.id] = coordinate
        }
        var seats: [RoomSeatEvidence] = []
        for position in positions {
            try Task.checkCancellation()
            let observation = position.observations.first { $0.channel == channel }!
            // Remove only broadband level differences; microphone coloration remains unknown.
            let offsets = observation.bins.compactMap { bin -> Double? in
                guard (300...3000).contains(bin.frequency), bin.reliability > 0.4,
                      let reference = interpolate(main.bins, at: bin.frequency), reference.reliability > 0.4 else { return nil }
                return bin.magnitudeDB - reference.magnitudeDB
            }
            let offset = offsets.count >= 12 ? median(offsets) : 0
            let repeatShape = observation.repeatShapeDifferenceDB ?? observation.repeatDifferenceDB
            // Version 3+ already incorporates repeat disagreement per bin.
            // Applying the broadband penalty again can erase every reliable bin.
            let repeatTrust = (observation.captureEvidence?.analysisVersion ?? 0) >= 3
                ? 1 : (repeatShape.map { max(0, min(1, (3.5 - $0) / 2)) } ?? 0.85)
            let coordinate = coordinateByID[position.id]!
            let duplicates = coordinateByID.values.filter { $0 == coordinate }.count
            var seat = RoomSeatEvidence(id: position.id, isMain: position.isMain,
                coordinate: coordinate,
                weight: geometry.priority(of: position) / Double(duplicates), magnitudes: [], excess: [], quality: [])
            for frequency in frequencies {
                guard let bin = interpolate(observation.bins, at: frequency) else {
                    seat.magnitudes.append(0); seat.excess.append(0); seat.quality.append(0); continue
                }
                let baseline = trend(observation.bins, at: frequency, repeatEnvelope: session.source.calibration == nil)
                var quality = min(bin.reliability, max(0, min(1, (bin.snrDB - 8) / 24))) * repeatTrust
                if baseline == nil { quality = 0 }
                if let calibration = session.source.calibration, !calibration.coversRoomFrequency(frequency) { quality = 0 }
                // Captures without provenance are still useful, with reduced confidence.
                if observation.captureEvidence == nil { quality *= 0.9 }
                seat.magnitudes.append(bin.magnitudeDB - offset)
                seat.excess.append(bin.magnitudeDB - (baseline ?? bin.magnitudeDB))
                seat.quality.append(quality)
            }
            seats.append(seat)
        }
        let secondaryWeight = seats.filter { !$0.isMain }.reduce(0) { $0 + $1.weight }
        for i in seats.indices {
            seats[i].weight = seats[i].isMain ? (secondaryWeight > 0 ? 0.5 : 1) : 0.5 * seats[i].weight / secondaryWeight
        }
        let primary = seats.first { $0.isMain }!
        let points = frequencies.indices.map { i -> RoomAnalysisPoint in
            let usable = seats.filter { $0.quality[i] > 0.4 }
            let magnitudes = usable.map { $0.magnitudes[i] }
            let central = magnitudes.isEmpty ? primary.magnitudes[i]
                : 0.65 * primary.magnitudes[i] + 0.35 * median(magnitudes)
            let spread = median(magnitudes.map { abs($0 - median(magnitudes)) }) * 1.4826
            let centralExcess = 0.65 * primary.excess[i] + 0.35 * median(usable.map { $0.excess[i] })
            let quality = usable.reduce(0) { $0 + $1.weight * $1.quality[i] }
            return .init(frequency: frequencies[i], mainDB: primary.magnitudes[i], centralDB: central,
                         spreadDB: spread, reliability: min(primary.quality[i], quality), referenceDB: central - centralExcess)
        }
        let groups = Dictionary(grouping: seats, by: \.coordinate)
        let groupWeights = groups.values.map { $0.reduce(0) { $0 + $1.weight } }.sorted()
        return .init(points: points, seats: seats, independentPositions: groups.count,
                     effectivePositions: 1 / max(1e-12, groupWeights.reduce(0) { $0 + $1 * $1 }))
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
    /// Two robust flanks remove linear microphone tilt without fitting away a local mode.
    private func trend(_ bins: [RoomFrequencyBin], at frequency: Double, repeatEnvelope: Bool) -> Double? {
        func reliability(_ bin: RoomFrequencyBin) -> Double {
            repeatEnvelope ? (bin.repeatReferenceReliability ?? bin.reliability) : bin.reliability
        }
        func magnitude(_ bin: RoomFrequencyBin) -> Double {
            repeatEnvelope ? max(bin.magnitudeDB, bin.repeatReferenceDB ?? bin.magnitudeDB) : bin.magnitudeDB
        }
        func supportsReference(_ bin: RoomFrequencyBin) -> Bool {
            // An upper bound from TWO takes includes a spectral-noise margin.
            // It can constrain a cut with less confidence than is required to
            // actually correct a frequency. Single takes retain the strict gate.
            let threshold = repeatEnvelope && bin.repeatReferenceDB != nil ? 0.25 : 0.4
            return reliability(bin) > threshold
        }
        let left = bins.filter { supportsReference($0) && (-1.25 ... -0.55).contains(log2($0.frequency / frequency)) }
        let right = bins.filter { supportsReference($0) && (0.55...1.25).contains(log2($0.frequency / frequency)) }
        guard left.count >= 4, right.count >= 4 else { return nil }
        let x0 = median(left.map { log2($0.frequency) }), x1 = median(right.map { log2($0.frequency) })
        let y0 = median(left.map(magnitude)), y1 = median(right.map(magnitude))
        return y0 + (y1 - y0) * (log2(frequency) - x0) / (x1 - x0)
    }
    private func interpolate(_ bins: [RoomFrequencyBin], at frequency: Double) -> RoomFrequencyBin? {
        guard let first = bins.first, let last = bins.last, frequency >= first.frequency, frequency <= last.frequency else { return nil }
        var lo = 0, hi = bins.count - 1
        while lo < hi { let mid = (lo + hi) / 2; if bins[mid].frequency < frequency { lo = mid + 1 } else { hi = mid } }
        let upper = bins[lo]
        if abs(log2(upper.frequency / frequency)) < 1e-6 { return upper }
        guard lo > 0 else { return nil }
        let lower = bins[lo - 1]
        guard log2(upper.frequency / lower.frequency) <= 1.0 / 8 else { return nil }
        let t = log(frequency / lower.frequency) / log(upper.frequency / lower.frequency)
        return .init(frequency: frequency, magnitudeDB: lower.magnitudeDB + t * (upper.magnitudeDB - lower.magnitudeDB),
                     reliability: min(lower.reliability, upper.reliability), snrDB: min(lower.snrDB, upper.snrDB))
    }
}
