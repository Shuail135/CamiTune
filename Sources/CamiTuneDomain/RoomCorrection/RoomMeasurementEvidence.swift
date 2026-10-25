import Foundation

/// Acquisition facts, not claims about microphone accuracy or speaker distance.
/// Optional on observations so older magnitude-only sessions remain readable.
package struct RoomCaptureEvidence: Codable, Hashable, Sendable {
    package var recordingSampleRate: Double
    package var playbackSampleRate: Double
    package var analysisSampleRate: Double
    package var isLossy: Bool
    package var clippingFraction: Double
    /// Sensitivity subtracted from magnitude bins only. The raw diagnostic IR
    /// and relative phase have not been inverted or microphone-phase calibrated.
    package var calibrationApplied: MicrophoneCalibrationCurve?
    package var acquisition: RoomMeasurementSource.Kind?
    package var sweepBlockID: UUID?
    package var analysisVersion = 4
    package init(recordingSampleRate: Double, playbackSampleRate: Double, analysisSampleRate: Double,
                 isLossy: Bool, clippingFraction: Double, calibrationApplied: MicrophoneCalibrationCurve?) {
        self.recordingSampleRate = recordingSampleRate; self.playbackSampleRate = playbackSampleRate
        self.analysisSampleRate = analysisSampleRate; self.isLossy = isLossy
        self.clippingFraction = clippingFraction; self.calibrationApplied = calibrationApplied
    }
    package func validate() throws {
        guard [recordingSampleRate, playbackSampleRate, analysisSampleRate].allSatisfy({ $0.isFinite && (8000...192000).contains($0) }),
              clippingFraction.isFinite, (0...1).contains(clippingFraction), analysisVersion > 0 else {
            throw RoomCorrectionError.invalidSession
        }
        try calibrationApplied?.validateForRoomMeasurement()
    }
}

package enum RoomAnalysisPolicy: String, Codable, Sendable {
    case automaticUncalibrated, calibrated
    package static func resolve(_ source: RoomMeasurementSource) throws -> Self {
        guard let calibration = source.calibration else { return .automaticUncalibrated }
        try calibration.validateForRoomMeasurement()
        return .calibrated
    }
}

extension MicrophoneCalibrationCurve {
    /// Validate decoded/programmatically supplied curves too, not just text imports.
    package func validateForRoomMeasurement() throws {
        guard (2...10000).contains(points.count), points.allSatisfy({
            $0.frequency.isFinite && (10...40000).contains($0.frequency)
                && $0.correctionDB.isFinite && abs($0.correctionDB) <= 30
        }), zip(points, points.dropFirst()).allSatisfy({ $0.frequency < $1.frequency }) else {
            throw AcousticMeasurementError.invalidCalibrationFile
        }
    }
    package func coversRoomFrequency(_ frequency: Double) -> Bool {
        guard let first = points.first, let last = points.last else { return false }
        return (first.frequency...last.frequency).contains(frequency)
    }
}

/// Coordinates originate from the setup canvas and suggested microphone offsets.
/// They can rank nearby seats, but cannot establish acoustic delays or room modes.
package struct RoomGeometrySnapshot: Sendable {
    package enum Certainty: Sendable { case schematicEstimate }
    package let certainty: Certainty = .schematicEstimate
    package var physicalChannels: [PhysicalOutputID]
    package var listener: SpatialVector3
    package var positions: [RoomMeasurementPosition]
    package init(session: RoomMeasurementSession) {
        physicalChannels = session.context.topology.endpoints.map(\.id)
        listener = session.context.listener
        positions = session.positions.filter { !$0.skipped }
    }
    package func priority(of position: RoomMeasurementPosition) -> Double {
        if position.isMain { return 1 }
        func distance(_ point: SpatialVector3) -> Double {
            sqrt(Double(pow(point.x - listener.x, 2) + pow(point.y - listener.y, 2) + pow(point.z - listener.z, 2)))
        }
        let distances = positions.filter { !$0.isMain }.map { distance($0.coordinate) }.sorted()
        let typical = distances.isEmpty ? 1 : max(0.0001, distances[distances.count / 2])
        return max(0.5, 1 / (1 + 0.25 * distance(position.coordinate) / typical))
    }
}

/// Admission to simple-mode correction, not approval of any filter. A phone may
/// resolve only part of the bass band. Keep that evidence without demanding a
/// calibrated microphone, full-band coverage, or a fixed recording level.
package struct RoomSimpleRecordingQuality: Equatable, Sendable {
    package enum State: Equatable, Sendable { case adequate, limited, insufficient }
    package enum Reason: Equatable, Sendable { case adequate, partial, missingMain, missingRepeat, positions, weakBass, noSharedBand }
    package struct Channel: Equatable, Sendable {
        package var channel: Int
        package var state: State
        package var reason: Reason
        package var range: ClosedRange<Double>
        package var supportedRanges: [ClosedRange<Double>]
        package var coverage: Double
        package var usablePositions: Int
        package var totalPositions: Int
        package var repeatsComplete: Bool
    }
    package var channels: [Channel]
    package var state: State {
        if channels.isEmpty || channels.allSatisfy({ $0.state == .insufficient }) { return .insufficient }
        return channels.allSatisfy({ $0.state == .adequate }) ? .adequate : .limited
    }
    package var canCalculate: Bool { state != .insufficient }

    package static func assess(_ session: RoomMeasurementSession, settings: RoomCorrectionSettings = .init()) -> Self? {
        guard session.source.kind == .recorder,
              session.positions.contains(where: { !$0.observations.isEmpty }) else { return nil }
        let positions = session.positions.filter { !$0.skipped }
        let main = positions.firstIndex(where: \.isMain)
        let low = max(45, settings.lowHz ?? 45)
        let high = min(300, settings.highHz ?? 300, session.context.topology.sampleRate * 0.42)
        guard low.isFinite, high.isFinite, low < high else { return .init(channels: []) }
        let measuredChannels = Set(session.blocks.map(\.channel))
        let endpoints = session.context.topology.endpoints.filter {
            // The playback manifest also accounts for disabled interface outputs.
            // Legacy sessions without blocks use the configured speaker states.
            measuredChannels.isEmpty
                ? ($0.connectionState == .confirmedByUser || $0.connectionState == .acousticallyDetected)
                : measuredChannels.contains($0.id.channelIndex)
        }
        let channels = endpoints.map { endpoint -> Channel in
            let channel = endpoint.id.channelIndex
            let upper = max(low, min(high, endpoint.isSubwooferLike ? 160 : 300))
            let range = low...upper
            let frequencies = (0..<241).map { 20 * pow(2, Double($0) / 24) }.filter { range.contains($0) }
            let observations = positions.map { $0.observations.first { $0.channel == channel } }
            let masks = observations.map { observation -> (usable: [Bool], strong: [Bool]) in
                guard let observation,
                      session.requiresRepeatedPositions != true || observation.repeatDifferenceDB != nil else {
                    return (frequencies.map { _ in false }, frequencies.map { _ in false })
                }
                return qualityMasks(for: observation, frequencies: frequencies)
            }
            let usablePositions = Set(positions.indices.filter {
                !ranges(mask: masks[$0].usable, frequencies: frequencies, within: range).isEmpty
            }.map { positions[$0].coordinate }).count
            let repeatsComplete = !observations.isEmpty && observations.allSatisfy { $0?.repeatDifferenceDB != nil }
            var usable = frequencies.map { _ in false }, strong = usable
            if let main {
                for i in frequencies.indices {
                    // A bright midrange or one isolated tone cannot supply bass
                    // evidence. Require a shared band at the main seat and two
                    // distinct additional positions, independently per speaker.
                    usable[i] = masks[main].usable[i] && Set(positions.indices.filter {
                        masks[$0].usable[i]
                    }.map { positions[$0].coordinate }).count >= 3
                    strong[i] = masks[main].strong[i] && Set(positions.indices.filter {
                        masks[$0].strong[i]
                    }.map { positions[$0].coordinate }).count >= 3
                }
            }
            let supported = ranges(mask: usable, frequencies: frequencies, within: range)
            let coverage = Double(usable.filter { $0 }.count) / Double(max(1, frequencies.count))
            let strongCoverage = Double(strong.filter { $0 }.count) / Double(max(1, frequencies.count))
            let state: State
            let reason: Reason
            if main == nil || observations[main!] == nil { state = .insufficient; reason = .missingMain }
            else if session.requiresRepeatedPositions == true && observations[main!]?.repeatDifferenceDB == nil {
                state = .insufficient; reason = .missingRepeat
            } else if ranges(mask: masks[main!].usable, frequencies: frequencies, within: range).isEmpty {
                state = .insufficient; reason = .weakBass
            } else if usablePositions < 3 { state = .insufficient; reason = .positions }
            else if supported.isEmpty { state = .insufficient; reason = .noSharedBand }
            else if strongCoverage >= 0.6 && usablePositions == positions.count && repeatsComplete {
                state = .adequate; reason = .adequate
            } else { state = .limited; reason = .partial }
            return .init(channel: channel, state: state, reason: reason, range: range,
                supportedRanges: supported, coverage: coverage, usablePositions: usablePositions,
                totalPositions: positions.count, repeatsComplete: repeatsComplete)
        }
        return .init(channels: channels)
    }

    private static func qualityMasks(for observation: RoomChannelObservation, frequencies: [Double]) -> (usable: [Bool], strong: [Bool]) {
        let bins = observation.bins.filter {
            $0.frequency.isFinite && $0.frequency > 0 && $0.reliability.isFinite && $0.snrDB.isFinite
        }.sorted { $0.frequency < $1.frequency }
        var usable: [Bool] = [], strong: [Bool] = [], index = 0
        for frequency in frequencies {
            while index < bins.count && bins[index].frequency < frequency { index += 1 }
            var reliability = 0.0, snr = -Double.infinity
            if index < bins.count && abs(log2(bins[index].frequency / frequency)) < 1e-6 {
                reliability = bins[index].reliability; snr = bins[index].snrDB
            } else if index > 0 && index < bins.count,
                      log2(bins[index].frequency / bins[index - 1].frequency) <= 1.0 / 8 {
                reliability = min(bins[index - 1].reliability, bins[index].reliability)
                snr = min(bins[index - 1].snrDB, bins[index].snrDB)
            }
            // Deliberately more permissive than filter approval (>0.4). Marginal
            // phone data can be analyzed without becoming permission to equalize it.
            usable.append(reliability > 0.25 && snr >= 15)
            strong.append(reliability > 0.4 && snr >= 20)
        }
        return (usable, strong)
    }

    private static func ranges(mask: [Bool], frequencies: [Double], within band: ClosedRange<Double>) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = [], start: Int?
        let halfBin = pow(2, 1.0 / 48)
        for i in 0...mask.count {
            if i < mask.count && mask[i] { if start == nil { start = i } }
            else if let first = start {
                let low = max(band.lowerBound, frequencies[first] / halfBin)
                let high = min(band.upperBound, frequencies[i - 1] * halfBin)
                // Four adjacent 1/24-octave cells are enough for admission.
                // Scattered reliable bins, hum, or a single spike are not.
                if log2(high / low) >= 1.0 / 6 - 1e-9 { result.append(low...high) }
                start = nil
            }
        }
        return result
    }
}
