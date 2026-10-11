import CamiTuneDomain
import Foundation

/// Robust whole-cascade optimization. A small skirt regression at one bin is
/// permitted; main-seat harm, deep-null boosts and material seat regressions are not.
struct RoomCorrectionOptimizer {
    struct Output {
        var bands: [EQBand]
        var diagnostic: RoomCorrectionDiagnostic
    }
    func fit(evidence: RoomChannelEvidence, policy: RoomAnalysisPolicy, settings: RoomCorrectionSettings,
             rate: Double, low: Double, high: Double, channel: Int) throws -> Output {
        let points = evidence.points, seats = evidence.seats
        let calibrated = policy == .calibrated
        // Knowing microphone sensitivity does not make one seat representative
        // of the listening area or distinguish a spatial cancellation.
        let minimumPositions = 3
        func output(_ bands: [EQBand], candidates: Int, reason: String) -> Output {
            .init(bands: bands, diagnostic: .init(usablePositions: evidence.independentPositions,
                effectivePositions: evidence.effectivePositions, candidates: candidates, accepted: bands.count, reason: reason))
        }
        guard let main = evidence.main, evidence.independentPositions >= minimumPositions,
              calibrated || evidence.effectivePositions >= 2.5 else {
            return output([], candidates: 0, reason: "Insufficient independent listening positions or missing main-seat evidence")
        }
        let cut = min(calibrated ? 8 : 4, settings.maximumCutDB ?? (calibrated ? 6 : 4))
        let boost = calibrated ? min(1, settings.maximumBoostDB ?? 0) : 0
        let maximumQ = min(4, settings.maximumQ ?? 4)
        let calculator = EQResponseCalculator()
        func huber(_ x: Double) -> Double { abs(x) <= 3 ? x * x : 6 * abs(x) - 9 }
        func loss(_ seat: RoomSeatEvidence, _ gains: [Double]) -> Double {
            var sum = 0.0, weight = 0.0
            for i in points.indices where (low...high).contains(points[i].frequency) && seat.quality[i] > 0.4 {
                sum += seat.quality[i] * huber(seat.excess[i] + gains[i]); weight += seat.quality[i]
            }
            return sum / max(1, weight)
        }
        let zero = [Double](repeating: 0, count: points.count)
        let originalLoss = seats.map { loss($0, zero) }
        func objective(_ gains: [Double]) -> Double {
            seats.indices.reduce(0) { $0 + seats[$1].weight * loss(seats[$1], gains) }
                + 0.04 * gains.reduce(0) { $0 + $1 * $1 } / Double(max(1, gains.count))
        }
        func rejection(_ gains: [Double]) -> String? {
            for i in points.indices {
                let gain = gains[i]
                if gain < -cut - 0.001 || gain > boost + 0.001 { return "Correction exceeds the gain limits" }
                if !(low...high).contains(points[i].frequency) && abs(gain) > 0.35 { return "Filter extends beyond the correction range" }
                if main.quality[i] <= 0.4 && abs(gain) > 0.35 { return "Filter affects frequencies that did not measure repeatably at the main position" }
                if main.excess[i] < -5 && (gain > 0.05 || gain < -0.75) { return "Filter would alter a deep dip at the main position" }
                let reliable = seats.filter { $0.quality[i] > 0.4 }
                if abs(gain) > 0.75 && Set(reliable.map(\.coordinate)).count < minimumPositions { return "Filter has too little support across listening positions" }
                // A calibrated microphone still cannot authorize filling cancellations.
                if gain > 0.1 && reliable.contains(where: { $0.excess[i] < -5 }) { return "Boost would fill a measured dip" }
                if gain < -1 && reliable.contains(where: { $0.excess[i] < -8 }) { return "Cut would deepen a measured dip" }
            }
            for s in seats.indices {
                let seat = seats[s]
                if seat.isMain {
                    if loss(seat, gains) >= originalLoss[s] - 0.005 { return "Filter does not improve the main position" }
                } else {
                    // Bound regression over the affected band, not diluted by the entire spectrum.
                    var regression = 0.0, weight = 0.0
                    for i in points.indices where abs(gains[i]) > 0.35 && seat.quality[i] > 0.4 {
                        regression += seat.quality[i] * (huber(seat.excess[i] + gains[i]) - huber(seat.excess[i]))
                        weight += seat.quality[i]
                    }
                    if regression / max(1, weight) > 0.8 { return "Filter would worsen another listening position" }
                }
            }
            return nil
        }
        struct Candidate { var index: Int; var q: Double; var excess: Double; var score: Double }
        var candidates: [Candidate] = []
        guard points.count >= 3 else { return output([], candidates: 0, reason: "No usable magnitude band") }
        let excess = points.map { $0.centralDB - $0.referenceDB }
        for i in 1..<points.count - 1 {
            let point = points[i], value = excess[i]
            guard (low...high).contains(point.frequency), point.reliability > 0.4,
                  (value > 1.5 && value >= excess[i - 1] && value > excess[i + 1])
                    || (boost > 0 && (-5 ... -1.5).contains(value) && value <= excess[i - 1] && value < excess[i + 1]) else { continue }
            // A deep null can pull down one baseline flank and create a false
            // positive shoulder. Require an actual turning point in the measured
            // response nearby, not merely a maximum in the detrended residual.
            let hasMeasuredPeak = (max(1, i - 2)...min(points.count - 2, i + 2)).contains { k in
                let center = points[k].centralDB
                if value > 0 { return center > points[k - 1].centralDB + 0.001 && center >= points[k + 1].centralDB }
                return center < points[k - 1].centralDB - 0.001 && center <= points[k + 1].centralDB
            }
            guard hasMeasuredPeak else { continue }
            let eligible = seats.filter { $0.quality[i] > 0.4 }
            let supporters = eligible.filter { $0.excess[i] * value > 0 && abs($0.excess[i]) > 1 }
            let availableWeight = eligible.reduce(0) { $0 + $1.weight }
            guard Set(supporters.map(\.coordinate)).count >= minimumPositions,
                  supporters.reduce(0, { $0 + $1.weight }) / max(1e-12, availableWeight) >= 0.7,
                  main.excess[i] * value > 0, abs(main.excess[i]) > 1 else { continue }
            var left = i, right = i
            while left > 0 && excess[left - 1] * value > 0 && abs(excess[left - 1]) > abs(value) * 0.5 { left -= 1 }
            while right + 1 < points.count && excess[right + 1] * value > 0 && abs(excess[right + 1]) > abs(value) * 0.5 { right += 1 }
            // Locate the half-height crossings between log-spaced samples.
            // Counting only the interior samples understates a peak's width by
            // up to two bins and can discard a resolved, repeatable bass mode.
            func crossing(_ a: Int, _ b: Int) -> Double {
                let sign = value > 0 ? 1.0 : -1.0
                let ya = excess[a] * sign, yb = excess[b] * sign
                let t = abs(yb - ya) < 1e-12 ? 0 : max(0, min(1, (abs(value) * 0.5 - ya) / (yb - ya)))
                return exp(log(points[a].frequency) + t * log(points[b].frequency / points[a].frequency))
            }
            let leftHz = left > 0 ? crossing(left - 1, left) : points[left].frequency
            let rightHz = right + 1 < points.count ? crossing(right, right + 1) : points[right].frequency
            let octaves = log2(rightHz / leftHz)
            guard octaves >= 0.125, octaves <= 1 else { continue }
            let q = min(maximumQ, max(0.5, point.frequency / max(1, rightHz - leftHz)))
            candidates.append(.init(index: i, q: q, excess: value, score: abs(value) * point.reliability / (1 + point.spreadDB)))
        }
        candidates.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        let candidateCount = candidates.count
        candidates = Array(candidates.prefix(24))
        var rejections: [String: Int] = [:]
        var bands: [EQBand] = [], combined = zero, used = Set<Int>()
        for iteration in 0..<min(calibrated ? 8 : 5, settings.filterCount ?? (calibrated ? 8 : 5)) {
            try Task.checkCancellation()
            let previousLoss = objective(combined)
            var best: (band: EQBand, gains: [Double], score: Double, index: Int)?
            for candidate in candidates where !used.contains(candidate.index) {
                let i = candidate.index, remaining = candidate.excess + combined[i]
                let budget = remaining > 0 ? cut : boost
                let initialGain = max(-cut, min(boost, -remaining * points[i].reliability * 0.8))
                for q in Set([candidate.q, min(maximumQ, candidate.q * 0.75), min(maximumQ, candidate.q * 1.25)]).sorted() {
                    // Search down to the minimum meaningful gain. Stopping at
                    // 25% misses safe small cuts when the initial target is large.
                    var scales: [Double] = [], scale = 1.0
                    while abs(initialGain * scale) >= 0.45 {
                        scales.append(contentsOf: [scale, scale * 0.75]); scale *= 0.5
                    }
                    if abs(initialGain) >= 0.45 { scales.append(0.45 / abs(initialGain)) }
                    for scale in scales {
                        let gain = initialGain * scale
                        guard abs(gain) >= 0.45,
                              bands.filter({ (($0.gain ?? 0) < 0) == (gain < 0) }).reduce(abs(gain), { $0 + abs($1.gain ?? 0) }) <= budget + 0.001 else { continue }
                        // Stable coefficient identities make repeated analysis byte-comparable.
                        let id = UUID(uuidString: String(format: "CA117B74-%04X-4000-%04X-%012X", channel, iteration, i))!
                        let band = EQBand(id: id, kind: .peaking, frequency: points[i].frequency, gain: gain, q: q)
                        let gains = points.indices.map { combined[$0] + calculator.gainDB(at: points[$0].frequency,
                            parsed: .init(preampDB: 0, bands: [band]), sampleRate: rate) }
                        if let reason = rejection(gains) { rejections[reason, default: 0] += 1; continue }
                        let score = previousLoss - objective(gains) - 0.015 - 0.002 * q
                        if score > max(0.01, best?.score ?? 0.01) { best = (band, gains, score, i) }
                    }
                }
            }
            guard let best else { break }
            bands.append(best.band); combined = best.gains; used.insert(best.index)
        }
        let reason = rejections.keys.sorted {
            rejections[$0] == rejections[$1] ? $0 < $1 : rejections[$0]! > rejections[$1]!
        }.first ?? "No repeatable bass peak has enough reliable surrounding detail and support across positions"
        return output(bands, candidates: candidateCount, reason: bands.isEmpty
            ? reason
            : "Limited correction supported by measured listening positions")
    }
}
