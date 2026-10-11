import CamiTuneDomain
import Foundation

/// Analyzes identified blocks, independent of file storage, profiles and UI.
package enum RoomRecordingAnalyzer {
    package static let currentAnalysisVersion = 4
    package static func analyze(_ recording: (samples: [Float], rate: Double, format: String, isLossy: Bool),
                        blocks: [RoomMeasurementBlock], session: RoomMeasurementSession) throws -> RoomMeasurementSession {
        try session.validate()
        var session = session
        if session.source.kind == .recorder { session.source.calibration = nil }
        if session.source.kind == .microphone, let curve = session.source.calibration {
            try curve.validateForRoomMeasurement()
        }
        var observations: [UUID: [Int: [(block: RoomMeasurementBlock, response: RoomChannelObservation)]]] = [:]
        var matched: [(block: RoomMeasurementBlock, response: RoomChannelObservation)] = []
        let prepared = try RoomMeasurementAnalyzer.Recording(samples: recording.samples, sampleRate: recording.rate, isLossy: recording.isLossy)
        var issues: [RoomMeasurementIssue] = []
        var clockAnchors: [UUID: (host: Double, recorded: Double, ratio: Double)] = [:]
        var firstFailure: Error?
        for block in blocks {
            try Task.checkCancellation()
            do {
                let hint: Double?
                if let clock = block.playbackClockID, let host = block.playbackStartTime, host.isFinite,
                   let anchor = clockAnchors[clock] {
                    hint = anchor.recorded + (host - anchor.host) * anchor.ratio
                } else { hint = nil }
                let response: RoomChannelObservation
                switch session.source.kind {
                case .recorder:
                    response = try RoomSimpleRecordingAnalysis().analyze(prepared, block: block,
                        playbackRate: session.context.topology.sampleRate, expectedMarkerTime: hint)
                case .microphone:
                    if session.source.calibration != nil {
                        response = try RoomCalibratedMicrophoneAnalysis().analyze(prepared, block: block,
                            playbackRate: session.context.topology.sampleRate, calibration: session.source.calibration)
                    } else {
                        // Reanalysis compatibility for older direct captures without a file.
                        // The correction policy remains uncalibrated.
                        response = try RoomSimpleRecordingAnalysis().analyze(prepared, block: block,
                            playbackRate: session.context.topology.sampleRate, expectedMarkerTime: hint)
                    }
                }
                if let clock = block.playbackClockID, let host = block.playbackStartTime, host.isFinite,
                   let marker = response.recordingMarkerTime {
                    clockAnchors[clock] = (host, marker, response.clockRatio)
                }
                matched.append((block, response))
            } catch is CancellationError { throw CancellationError() }
            catch {
                if firstFailure == nil { firstFailure = error }
                let missing: Bool
                switch error {
                case RoomCorrectionError.missingBlocks, RoomCorrectionError.microphoneSweepMissing: missing = true
                default: missing = false
                }
                issues.append(.init(positionID: block.positionID, channel: block.channel, missingSweep: missing))
                continue
            }
        }
        // Different speaker/position codes cannot own overlapping sweeps.
        // Resolve a weak cross-match in favour of the stronger paired markers.
        for (index, match) in matched.enumerated() {
            let conflict = matched.enumerated().contains { otherIndex, other in
                guard index != otherIndex, let a = match.response.recordingMarkerTime,
                      let b = other.response.recordingMarkerTime, abs(a - b) < 5.05 else { return false }
                let quality = match.response.markerConfidence ?? 0, otherQuality = other.response.markerConfidence ?? 0
                return otherQuality > quality || (otherQuality == quality && otherIndex < index)
            }
            if conflict { issues.append(.init(positionID: match.block.positionID, channel: match.block.channel, missingSweep: true)); continue }
            observations[match.block.positionID, default: [:]][match.block.channel, default: []].append(match)
        }
        guard !observations.isEmpty else { throw firstFailure ?? RoomCorrectionError.missingBlocks }
        for i in session.positions.indices {
            guard let channels = observations[session.positions[i].id] else { continue }
            for (channel, takes) in channels.sorted(by: { $0.key < $1.key }) {
                var observation = takes.last!.response
                if let primary = takes.last(where: { !$0.block.isRepeat }),
                   let repeated = takes.last(where: { $0.block.isRepeat }) {
                    observation = compareRepeats(primary.response, repeated.response, uncalibrated: session.source.calibration == nil)
                } else if blocks.count == 1, blocks.first?.isRepeat == true,
                          let previous = session.positions[i].observations.first(where: { $0.channel == channel }),
                          let id = previous.captureEvidence?.sweepBlockID,
                          session.blocks.contains(where: { $0.id == id && !$0.isRepeat && $0.channel == channel && $0.positionID == session.positions[i].id }) {
                    observation = compareRepeats(previous, observation, uncalibrated: session.source.calibration == nil)
                } else if session.positions[i].isMain {
                    observation.timingEligible = false; observation.relativeTimingEligible = false
                }
                session.positions[i].observations.removeAll { $0.channel == channel }
                session.positions[i].observations.append(observation)
            }
        }
        session.analysisIssues = (session.analysisIssues ?? []).filter { issue in
            !blocks.contains { $0.positionID == issue.positionID && $0.channel == issue.channel }
        } + issues
        session.measurementAnalysisVersion = currentAnalysisVersion; session.roomAnalysisVersion = currentAnalysisVersion
        return session
    }
    /// A phone's AGC may change overall gain between the normal and quieter
    /// sweeps. Preserve repeatable shape, but never turn that into trusted level
    /// or alignment data. Frequency-dependent changes still reduce confidence.
    static func compareRepeats(_ first: RoomChannelObservation, _ next: RoomChannelObservation, uncalibrated: Bool) -> RoomChannelObservation {
        guard first.bins.count == next.bins.count,
              zip(first.bins, next.bins).allSatisfy({ abs(log2($0.frequency / $1.frequency)) < 0.001 }) else {
            var result = first; result.timingEligible = false; result.relativeTimingEligible = false; return result
        }
        let differences = zip(first.bins, next.bins).map { $1.magnitudeDB - $0.magnitudeDB }
        let usable = first.bins.indices.filter {
            first.bins[$0].snrDB > 18 && next.bins[$0].snrDB > 18 && (100...8000).contains(first.bins[$0].frequency)
        }
        let offsets = usable.map { differences[$0] }.sorted()
        let gain = offsets.isEmpty ? 0 : offsets[offsets.count / 2]
        let residuals = usable.map { abs(differences[$0] - gain) }.sorted()
        let shape = residuals.isEmpty ? 100 : residuals[residuals.count / 2]
        let difference = differences.map(abs).reduce(0, +) / Double(max(1, differences.count))
        var result = uncalibrated ? first : next
        result.repeatDifferenceDB = difference; result.repeatGainDifferenceDB = gain; result.repeatShapeDifferenceDB = shape
        let clockAgrees = abs(first.clockRatio - next.clockRatio) < 0.0002
        result.timingEligible = first.timingEligible && next.timingEligible && difference < 2 && clockAgrees
        for i in result.bins.indices {
            let residual = uncalibrated && usable.count >= 12 ? abs(differences[i] - gain) : abs(differences[i])
            let gainTrust = uncalibrated && abs(gain) > 1 ? 0.85 : 1.0
            let shapeTrust = uncalibrated && shape > 3 ? 0.4 : 1.0
            result.bins[i].reliability = min(first.bins[i].reliability, next.bins[i].reliability)
                * max(0, 1 - residual / 6) * gainTrust * shapeTrust
            if uncalibrated && usable.count >= 12 {
                // A changed flank need not erase an independently repeatable peak.
                // Use the HIGHER response as the reference: disagreement can only
                // reduce the proposed cut. Both takes must clear the noise floor.
                func noiseMargin(_ bin: RoomFrequencyBin) -> Double {
                    20 * log10(1 + 2 * pow(10, -max(0, bin.snrDB) / 20))
                }
                result.bins[i].repeatReferenceDB = max(first.bins[i].magnitudeDB + noiseMargin(first.bins[i]),
                    next.bins[i].magnitudeDB - gain + noiseMargin(next.bins[i]))
                result.bins[i].repeatReferenceReliability = min(first.bins[i].reliability, next.bins[i].reliability)
            }
            let delta = first.bins[i].phase - next.bins[i].phase
            let phaseError = abs(atan2(sin(delta), cos(delta)))
            let delayError = abs((first.bins[i].groupDelayMS ?? 0) - (next.bins[i].groupDelayMS ?? 0))
            let delayLimit = max(0.15, 300 / first.bins[i].frequency)
            let agrees = clockAgrees && first.hasUsableImpulse && next.hasUsableImpulse
                && phaseError < .pi / 6 && usable.count >= 12
            result.bins[i].timingReliability = agrees ? min(0.75, result.bins[i].reliability) : 0
            if !agrees || delayError >= delayLimit { result.bins[i].groupDelayMS = nil }
        }
        result.relativeTimingEligible = result.bins.filter { ($0.timingReliability ?? 0) > 0.4 }.count >= 12
        result.timingEligible = result.timingEligible && result.relativeTimingEligible == true
            && result.bins.filter { ($0.timingReliability ?? 0) > 0.4 && $0.groupDelayMS != nil }.count >= 24
        return result
    }
}
