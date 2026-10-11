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
    case calibrationRequired, calibrationChanged, incompleteMicrophoneMeasurement, inputClipped, microphoneSweepMissing
    package var errorDescription: String? {
        switch self {
        case .calibrationRequired: return "Choose the microphone and its calibration file before measuring."
        case .calibrationChanged: return "The microphone calibration changed. Reanalyze the saved recording before creating correction."
        case .incompleteMicrophoneMeasurement: return "Measure every speaker at the main position and at least two other positions. Complete or skip the remaining positions before calculating correction."
        case .inputClipped: return "The microphone input clipped. Lower the test volume or microphone input gain, then measure this position again."
        case .microphoneSweepMissing: return "The microphone did not capture a complete sweep. Check the selected input and test level, then measure this position again."
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
    package static let currentOptimizerVersion = 5
    package static let currentFIRGeneratorVersion = 3
    package var analysisPolicy: RoomAnalysisPolicy?
    package var channelDiagnostics: [Int: RoomCorrectionDiagnostic]?
    /// Import has transferred the filters to editable channel EQ/FIR slots.
    /// Absent on legacy results and on calculated previews.
    package var isChannelProcessingImport: Bool?
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

package struct RoomCorrectionDiagnostic: Codable, Hashable, Sendable {
    package var usablePositions: Int
    package var effectivePositions: Double
    package var candidates: Int
    package var accepted: Int
    package var reason: String
    package init(usablePositions: Int, effectivePositions: Double, candidates: Int, accepted: Int, reason: String) {
        self.usablePositions = usablePositions; self.effectivePositions = effectivePositions
        self.candidates = candidates; self.accepted = accepted; self.reason = reason
    }
}
