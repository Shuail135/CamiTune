import Foundation

package enum RoomCorrectionMethod: String, Codable, CaseIterable, Sendable { case auto, iir, fir, hybrid }
package enum RoomFIRPhase: String, Codable, CaseIterable, Sendable { case minimum, linear, mixed }
package struct RoomCorrectionSettings: Codable, Hashable, Sendable {
    package var method: RoomCorrectionMethod = .auto
    package var lowHz: Double?
    package var highHz: Double?
    package var maximumBoostDB: Double?
    package var maximumCutDB: Double?
    package var maximumQ: Double?
    package var filterCount: Int?
    package var phase: RoomFIRPhase = .minimum
    package var filterLength: Int?
    package var latencyLimitMS: Double?
    package init() {}
    package func validate(sampleRate: Double) throws {
        guard sampleRate.isFinite, (8000...192000).contains(sampleRate),
              [lowHz, highHz, maximumBoostDB, maximumCutDB, maximumQ, latencyLimitMS].compactMap({ $0 }).allSatisfy(\.isFinite),
              (10...1000).contains(lowHz ?? 25), (40...20000).contains(highHz ?? 800),
              (lowHz ?? 25) < min(highHz ?? 800, sampleRate * 0.45),
              (0...3).contains(maximumBoostDB ?? 1), (0...12).contains(maximumCutDB ?? 8),
              (0.3...10).contains(maximumQ ?? 4), (1...20).contains(filterCount ?? 8),
              (1...200).contains(latencyLimitMS ?? 20),
              filterLength.map({ (256...32768).contains($0) && $0.nonzeroBitCount == 1 }) ?? true else {
            throw RoomCorrectionError.invalidSettings
        }
    }
}
package enum RoomCorrectionError: LocalizedError {
    case invalidSettings, invalidSession, unreliable, timingUnavailable, latencyLimit, stale, missingBlocks, routeUnavailable
    package var errorDescription: String? {
        switch self {
        case .invalidSettings: return "The correction limits are invalid. Check the frequency, gain, Q and latency limits."
        case .invalidSession: return "This measurement session is incomplete or unsupported."
        case .unreliable: return "The position could not be measured reliably. Reduce background noise and repeat it."
        case .timingUnavailable: return "This recording supports magnitude analysis only. Use IIR or repeat with a reliable microphone."
        case .latencyLimit: return "The selected filter length and phase exceed the latency limit."
        case .stale: return "The output, processing or listening geometry changed. Re-measure this setup."
        case .missingBlocks: return "No complete measurement blocks were found. Import the recording made during this session."
        case .routeUnavailable: return "Activate this speaker profile and wait for audio changes to finish before measuring."
        }
    }
}
package struct RoomMeasurementSource: Codable, Hashable, Sendable {
    package enum Kind: String, Codable, Sendable { case microphone, recorder }
    package var kind: Kind = .microphone
    package var deviceName = "Unknown / not listed"
    package var deviceID: String?
    package var calibration: MicrophoneCalibrationCurve?
    package init() {}
}
package struct RoomMeasurementContext: Codable, Hashable, Sendable {
    package var topology: SpeakerTopology
    package var listener: SpatialVector3
    /// Exact downstream processing through which the sweep was measured, excluding room correction.
    package var processing: ProcessingProfile
    package var revision = 1
    package var multichannel: MultichannelProcessingSettings?
    package init(topology: SpeakerTopology, listener: SpatialVector3, processing: ProcessingProfile) {
        self.topology = topology; self.listener = listener; self.processing = processing
    }
    package func canReprocess(to current: Self) -> Bool {
        var old = self
        old.topology.sampleRate = current.topology.sampleRate
        return old == current
    }
}
extension RoomMeasurementContext {
    /// Editor identities, locked bands and bypassed stages do not change what
    /// the microphone heard. Keep all enabled audio settings and their order.
    private var acousticProcessing: ProcessingProfile {
        let identity = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        func chain(_ source: ProcessingChain) -> ProcessingChain {
            var result = source
            result.stages = source.stages.compactMap { stage in
                guard stage.isEnabled else { return nil }
                var stage = stage
                if case .equalizer(var equalizer) = stage.processor {
                    equalizer.bands = equalizer.bands.filter(\.enabled).map {
                        EQBand(id: identity, kind: $0.kind, frequency: $0.frequency,
                            gain: $0.gain, q: $0.q, bandwidth: $0.bandwidth)
                    }
                    guard !equalizer.bands.isEmpty else { return nil }
                    stage.processor = .equalizer(equalizer)
                }
                return stage
            }
            return result
        }
        var result = processing
        result.globalEqualizerProvenance = nil
        result.global = chain(result.global)
        for index in result.channels.indices { result.channels[index].chain = chain(result.channels[index].chain) }
        for index in result.groups.indices { result.groups[index].chain = chain(result.groups[index].chain) }
        return result
    }
    private var acousticTopology: SpeakerTopology {
        var value = topology
        value.createdAt = .distantPast; value.updatedAt = .distantPast
        for i in value.endpoints.indices { value.endpoints[i].displayName = "" }
        return value
    }
    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.acousticTopology == rhs.acousticTopology && lhs.listener == rhs.listener
            && lhs.acousticProcessing == rhs.acousticProcessing && lhs.revision == rhs.revision && lhs.multichannel == rhs.multichannel
    }
    package func hash(into hasher: inout Hasher) {
        hasher.combine(acousticTopology); hasher.combine(listener); hasher.combine(acousticProcessing)
        hasher.combine(revision); hasher.combine(multichannel)
    }
}
package struct RoomFrequencyBin: Codable, Hashable, Sendable {
    package var frequency: Double
    package var magnitudeDB: Double
    package var phase: Double
    package var reliability: Double
    package var snrDB: Double
    /// Confidence in peak-relative phase/delay, independently of magnitude.
    package var timingReliability: Double?
    package var groupDelayMS: Double?
    package init(frequency: Double, magnitudeDB: Double, phase: Double = 0, reliability: Double = 1, snrDB: Double = 60) {
        self.frequency = frequency; self.magnitudeDB = magnitudeDB; self.phase = phase
        self.reliability = reliability; self.snrDB = snrDB
    }
}
package struct RoomChannelObservation: Codable, Hashable, Sendable {
    package var channel: Int
    package var bins: [RoomFrequencyBin]
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
package struct RoomCorrectionResult: Codable, Hashable, Sendable {
    package var sessionID: UUID
    package var generatedAt = Date()
    package var context: RoomMeasurementContext
    package var method: RoomCorrectionMethod
    package var settings: RoomCorrectionSettings
    package var sharedBands: [EQBand] = []
    package var channelBands: [Int: [EQBand]] = [:]
    package var channelFIR: [Int: ConvolutionProcessor] = [:]
    package var lowHz: Double
    package var highHz: Double
    package var positionCount: Int
    package static let currentOptimizerVersion = 2
    package static let currentFIRGeneratorVersion = 2
    package var optimizerVersion = currentOptimizerVersion
    package var firGeneratorVersion = currentFIRGeneratorVersion
    package var hasCorrection: Bool {
        !sharedBands.isEmpty || channelBands.values.contains { !$0.isEmpty } || !channelFIR.isEmpty
    }
    package init(sessionID: UUID, context: RoomMeasurementContext, method: RoomCorrectionMethod,
                 settings: RoomCorrectionSettings, lowHz: Double, highHz: Double, positionCount: Int) {
        self.sessionID = sessionID; self.context = context; self.method = method; self.settings = settings
        self.lowHz = lowHz; self.highHz = highHz; self.positionCount = positionCount
    }
}
package enum RoomRecorderPositionCount: Int, CaseIterable, Sendable { case five = 5, nine = 9 }

package enum RoomMeasurementGeometry {
    package static func radius(for seat: SpatialSeatingCalibration?) -> Float {
        min(0.65, max(0.12, ((seat?.leftDistanceMeters ?? 1) + (seat?.rightDistanceMeters ?? 1)) * 0.10))
    }
    package static func recorderPositions(center: SpatialVector3, radius: Float,
                                          count: RoomRecorderPositionCount) -> [SpatialVector3] {
        // Use reproducible, tape-measure-friendly offsets in metres. Preserve
        // the exact main seat; never snap or move the user's listening position.
        let distance = radius.isFinite ? min(0.65, max(0.1, radius)) : 0.2
        let spacing = min(0.6, (distance * 10).rounded() / 10)
        let offsets: [(Float, Float)] = [(0, 0), (-1, 0), (1, 0), (0, 1), (0, -1)]
            + (count == .nine ? [(-1, 1), (1, 1), (-1, -1), (1, -1)] : [])
        return offsets.map { SpatialVector3(x: center.x + $0.0 * spacing,
            y: center.y + $0.1 * spacing, z: center.z) }
    }
    package static func suggestion(center: SpatialVector3, radius: Float, existing: [SpatialVector3]) -> SpatialVector3 {
        // Maximin coverage adapts after a user relocates a point; no obstruction inference.
        (0..<16).map { i in
            let angle = Float(i) * .pi / 8
            return SpatialVector3(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle), z: center.z)
        }.max { a, b in
            func distance(_ p: SpatialVector3) -> Float {
                existing.map { pow(p.x - $0.x, 2) + pow(p.y - $0.y, 2) }.min() ?? 0
            }
            return distance(a) < distance(b)
        } ?? center
    }
}

extension RoomMeasurementSession {
    package func validate() throws {
        try context.topology.validate()
        guard measurementFormatVersion == 1, measurementSignalVersion == 1,
              positions.count <= 1000, Set(positions.map(\.id)).count == positions.count,
              positions.filter(\.isMain).count == 1,
              blocks.count <= 10000, Set(blocks.map(\.id)).count == blocks.count,
              blocks.allSatisfy({ block in (block.playbackGainDB ?? 0).isFinite && (-120...12).contains(block.playbackGainDB ?? 0) && positions.contains(where: { $0.id == block.positionID }) && context.topology.endpoints.contains(where: { $0.id.channelIndex == block.channel }) }),
              positions.allSatisfy({ position in
                  [position.coordinate.x, position.coordinate.y, position.coordinate.z].allSatisfy(\.isFinite)
                    && Set(position.observations.map(\.channel)).count == position.observations.count
                    && position.observations.allSatisfy { observation in
                        observation.bins.count <= 4096 && observation.impulse.count <= 192000
                            && observation.impulse.allSatisfy(\.isFinite)
                            && [observation.impulseTimeZeroSeconds, observation.markerConfidence,
                                observation.repeatGainDifferenceDB, observation.repeatShapeDifferenceDB,
                                observation.recordingMarkerTime].compactMap { $0 }.allSatisfy(\.isFinite)
                            && observation.bins.allSatisfy { bin in
                                [bin.frequency, bin.magnitudeDB, bin.phase, bin.reliability, bin.snrDB].allSatisfy(\.isFinite)
                                    && bin.frequency > 0 && (0...1).contains(bin.reliability)
                                    && bin.groupDelayMS.map(\.isFinite) != false
                                    && bin.timingReliability.map({ $0.isFinite && (0...1).contains($0) }) != false
                            }
                            && zip(observation.bins, observation.bins.dropFirst()).allSatisfy { $0.frequency < $1.frequency }
                    }
              }) else { throw RoomCorrectionError.invalidSession }
    }
}
