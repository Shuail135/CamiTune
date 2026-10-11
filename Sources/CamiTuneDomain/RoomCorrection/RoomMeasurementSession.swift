import Foundation

package struct RoomMeasurementSource: Codable, Hashable, Sendable {
    package enum Kind: String, Codable, Sendable { case microphone, recorder }
    package var kind: Kind = .microphone
    package var deviceName = "Unknown / not listed"
    package var deviceID: String?
    package var calibration: MicrophoneCalibrationCurve?
    package init() {}
}
package struct RoomFrequencyBin: Codable, Hashable, Sendable {
    package var frequency: Double
    package var magnitudeDB: Double
    package var phase: Double
    package var reliability: Double
    package var snrDB: Double
    /// Upper envelope of gain-aligned, repeated uncalibrated measurements.
    /// Only a conservative reference for cuts; it does not authorize correcting
    /// this bin when the repeated measurements disagree.
    package var repeatReferenceDB: Double?
    package var repeatReferenceReliability: Double?
    /// Confidence in peak-relative phase/delay, independently of magnitude.
    package var timingReliability: Double?
    package var groupDelayMS: Double?
    package init(frequency: Double, magnitudeDB: Double, phase: Double = 0, reliability: Double = 1, snrDB: Double = 60) {
        self.frequency = frequency; self.magnitudeDB = magnitudeDB; self.phase = phase
        self.reliability = reliability; self.snrDB = snrDB
    }
}
package struct RoomChannelObservation: Codable, Hashable, Sendable {
    package var captureEvidence: RoomCaptureEvidence?
    package var channel: Int
    package var bins: [RoomFrequencyBin]
    /// Raw transfer IR relative to the recorded marker, before magnitude-only
    /// microphone calibration. Not an absolute acoustic distance measurement.
    package var impulse: [Float]
    package var impulseSampleRate: Double
    package var arrivalSeconds: Double
    package var levelDB: Double
    package var timingEligible: Bool
    package var clockRatio: Double
    package var repeatDifferenceDB: Double?
    package var repeatGainDifferenceDB: Double?
    package var repeatShapeDifferenceDB: Double?
    package var markerConfidence: Double?
    /// Diagnostic timing is relative to this response's peak, not speaker distance.
    package var impulseTimeZeroSeconds: Double?
    package var relativeImpulseEligible: Bool?
    package var relativeTimingEligible: Bool?
    package var recordingMarkerTime: Double?
    package init(channel: Int, bins: [RoomFrequencyBin], impulse: [Float] = [], impulseSampleRate: Double = 48000,
                 arrivalSeconds: Double = 0, levelDB: Double = 0, timingEligible: Bool = false,
                 clockRatio: Double = 1, repeatDifferenceDB: Double? = nil) {
        self.channel = channel; self.bins = bins; self.impulse = impulse; self.impulseSampleRate = impulseSampleRate
        self.arrivalSeconds = arrivalSeconds; self.levelDB = levelDB; self.timingEligible = timingEligible
        self.clockRatio = clockRatio; self.repeatDifferenceDB = repeatDifferenceDB
    }
}
extension RoomChannelObservation {
    package var hasUsableMagnitude: Bool { bins.filter { $0.reliability > 0.4 }.count >= 12 }
    package var hasUsableImpulse: Bool { relativeImpulseEligible ?? timingEligible }
    package var hasUsableRelativeTiming: Bool { relativeTimingEligible ?? timingEligible }
}
package struct RoomMeasurementIssue: Codable, Sendable {
    package var positionID: UUID
    package var channel: Int
    package var missingSweep: Bool
    package init(positionID: UUID, channel: Int, missingSweep: Bool) {
        self.positionID = positionID; self.channel = channel; self.missingSweep = missingSweep
    }
}
package struct RoomMeasurementPosition: Codable, Hashable, Sendable, Identifiable {
    package var id = UUID()
    package var coordinate: SpatialVector3
    package var isMain = false
    package var observations: [RoomChannelObservation] = []
    package var skipped = false
    package init(coordinate: SpatialVector3, isMain: Bool = false) { self.coordinate = coordinate; self.isMain = isMain }
}
/// A block is one bounded physical-channel clip. Tokens distinguish retries and repeated sweeps.
package struct RoomMeasurementBlock: Codable, Hashable, Sendable, Identifiable {
    package var id = UUID()
    package var token: UInt32
    package var positionID: UUID
    package var channel: Int
    package var isRepeat: Bool
    /// Actual digital test gain, independent of an approximate phone SPL reading.
    /// Absent in older recordings, which used the original 0 dB signal.
    package var playbackGainDB: Double? = nil
    /// Monotonic first-frame production time; a search hint, not an acoustic
    /// timestamp. A new clock ID prevents comparisons across app restarts.
    package var playbackStartTime: Double?
    package var playbackClockID: UUID?
    package init(token: UInt32, positionID: UUID, channel: Int, isRepeat: Bool = false) {
        self.token = token; self.positionID = positionID; self.channel = channel; self.isRepeat = isRepeat
    }
}
package struct RoomRecordingReference: Codable, Hashable, Sendable {
    package var fileName: String
    /// Display metadata only; file access continues to use the retained filename.
    package var originalFileName: String? = nil
    package var sourceFormat: String
    package var isLossy: Bool
    package var blockIDs: [UUID]
    package init(fileName: String, sourceFormat: String, isLossy: Bool, blockIDs: [UUID]) {
        self.fileName = fileName; self.sourceFormat = sourceFormat; self.isLossy = isLossy; self.blockIDs = blockIDs
    }
}
package struct RoomMeasurementSession: Codable, Sendable, Identifiable {
    package var id = UUID()
    package var createdAt = Date()
    package var name = "Room measurement"
    package var context: RoomMeasurementContext
    package var source: RoomMeasurementSource
    package var positions: [RoomMeasurementPosition]
    package var blocks: [RoomMeasurementBlock] = []
    package var recordings: [RoomRecordingReference] = []
    package var measurementFormatVersion = 1
    package var measurementSignalVersion = 1
    package var measurementAnalysisVersion = 1
    package var roomAnalysisVersion = 1
    package var analysisIssues: [RoomMeasurementIssue]?
    package init(context: RoomMeasurementContext, source: RoomMeasurementSource, positions: [RoomMeasurementPosition]) {
        self.context = context; self.source = source; self.positions = positions
    }
    package var usablePositionCount: Int {
        positions.filter { !$0.skipped && $0.observations.contains { $0.hasUsableMagnitude } }.count
    }
}
extension RoomMeasurementSession {
    /// A direct capture is ready only when every physical speaker has usable
    /// magnitude data. The main position also needs its quieter validation take.
    package func measuredMicrophoneChannels(at position: RoomMeasurementPosition) -> Set<Int> {
        Set(position.observations.compactMap { observation in
            guard observation.hasUsableMagnitude else { return nil }
            if position.isMain {
                guard observation.repeatDifferenceDB != nil,
                      blocks.contains(where: { $0.positionID == position.id && $0.channel == observation.channel && !$0.isRepeat }),
                      blocks.contains(where: { $0.positionID == position.id && $0.channel == observation.channel && $0.isRepeat }) else { return nil }
            }
            return observation.channel
        })
    }
    package func microphonePositionIsComplete(_ position: RoomMeasurementPosition) -> Bool {
        !position.skipped && Set(context.topology.endpoints.map { $0.id.channelIndex })
            .isSubset(of: measuredMicrophoneChannels(at: position))
    }
    package var completeMicrophonePositionCount: Int { positions.filter(microphonePositionIsComplete).count }
    package var microphoneMeasurementsComplete: Bool {
        let active = positions.filter { !$0.skipped }
        return active.count >= 3 && active.contains(where: \.isMain)
            && active.allSatisfy(microphonePositionIsComplete)
    }
    /// Retrying a channel retires its old normal/repeat pair and file references
    /// together. Other speakers and positions remain available if this take fails.
    package mutating func retireMicrophoneTakes(positionID: UUID, channels: Set<Int>) {
        let retired = Set(blocks.filter { $0.positionID == positionID && channels.contains($0.channel) }.map(\.id))
        blocks.removeAll { retired.contains($0.id) }
        for i in positions.indices where positions[i].id == positionID {
            positions[i].observations.removeAll { channels.contains($0.channel) }
            positions[i].skipped = false
        }
        for i in recordings.indices { recordings[i].blockIDs.removeAll { retired.contains($0) } }
        recordings.removeAll { $0.blockIDs.isEmpty }
        analysisIssues?.removeAll { $0.positionID == positionID && channels.contains($0.channel) }
    }
    package func validate() throws {
        try context.topology.validate()
        try source.calibration?.validateForRoomMeasurement()
        for observation in positions.flatMap(\.observations) { try observation.captureEvidence?.validate() }
        guard measurementFormatVersion == 1, measurementSignalVersion == 1,
              positions.count <= 1000, Set(positions.map(\.id)).count == positions.count,
              positions.filter(\.isMain).count == 1,
              blocks.count <= 10000, Set(blocks.map(\.id)).count == blocks.count,
              blocks.allSatisfy({ block in (block.playbackGainDB ?? 0).isFinite && (-120...12).contains(block.playbackGainDB ?? 0) && positions.contains(where: { $0.id == block.positionID }) && context.topology.endpoints.contains(where: { $0.id.channelIndex == block.channel }) }),
              positions.allSatisfy({ position in
                  [position.coordinate.x, position.coordinate.y, position.coordinate.z].allSatisfy(\.isFinite)
                    && Set(position.observations.map(\.channel)).count == position.observations.count
                    && position.observations.allSatisfy { observation in
                        context.topology.endpoints.contains { $0.id.channelIndex == observation.channel }
                            && [observation.impulseSampleRate, observation.arrivalSeconds, observation.levelDB,
                                observation.clockRatio].allSatisfy(\.isFinite)
                            && (8000...192000).contains(observation.impulseSampleRate)
                            && (0.995...1.005).contains(observation.clockRatio)
                            && observation.repeatDifferenceDB.map(\.isFinite) != false
                            && observation.bins.count <= 4096 && observation.impulse.count <= 192000
                            && observation.impulse.allSatisfy(\.isFinite)
                            && [observation.impulseTimeZeroSeconds, observation.markerConfidence,
                                observation.repeatGainDifferenceDB, observation.repeatShapeDifferenceDB,
                                observation.recordingMarkerTime].compactMap { $0 }.allSatisfy(\.isFinite)
                            && observation.bins.allSatisfy { bin in
                                [bin.frequency, bin.magnitudeDB, bin.phase, bin.reliability, bin.snrDB].allSatisfy(\.isFinite)
                                    && bin.frequency > 0 && (0...1).contains(bin.reliability)
                                    && bin.groupDelayMS.map(\.isFinite) != false
                                    && bin.repeatReferenceDB.map(\.isFinite) != false
                                    && bin.repeatReferenceReliability.map({ $0.isFinite && (0...1).contains($0) }) != false
                                    && bin.timingReliability.map({ $0.isFinite && (0...1).contains($0) }) != false
                            }
                            && zip(observation.bins, observation.bins.dropFirst()).allSatisfy { $0.frequency < $1.frequency }
                    }
              }) else { throw RoomCorrectionError.invalidSession }
    }
}
