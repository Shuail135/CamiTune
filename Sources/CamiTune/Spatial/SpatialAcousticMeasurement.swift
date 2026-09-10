import Foundation

enum AcousticMeasurementPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case listeningPosition, leftEar, rightEar
    var id: String { rawValue }
    var label: String {
        switch self {
        case .listeningPosition: return "Listening position"
        case .leftEar: return "Left-ear position"
        case .rightEar: return "Right-ear position"
        }
    }
}

struct MeasurementMicrophone: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let isBuiltIn: Bool
}

struct MicrophoneCalibrationPoint: Codable, Hashable, Sendable {
    let frequency: Double
    let correctionDB: Double
}

struct MicrophoneCalibrationCurve: Codable, Hashable, Sendable {
    let name: String
    let points: [MicrophoneCalibrationPoint]

    /// Common measurement-microphone text format: frequency followed by the
    /// measured sensitivity deviation in dB. Optional phase columns are ignored.
    static func parse(_ text: String, name: String) throws -> Self {
        var points: [MicrophoneCalibrationPoint] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("*") || trimmed.hasPrefix(";") { continue }
            let fields = trimmed.split { $0.isWhitespace || $0 == "," }
            guard fields.count >= 2, let frequency = Double(fields[0]), let db = Double(fields[1]) else { continue }
            guard frequency.isFinite, db.isFinite, (10...40_000).contains(frequency), abs(db) <= 30 else {
                throw AcousticMeasurementError.invalidCalibrationFile
            }
            points.append(.init(frequency: frequency, correctionDB: db))
            guard points.count <= 10_000 else { throw AcousticMeasurementError.invalidCalibrationFile }
        }
        points.sort { $0.frequency < $1.frequency }
        guard points.count >= 5, zip(points, points.dropFirst()).allSatisfy({ $0.frequency < $1.frequency }) else {
            throw AcousticMeasurementError.invalidCalibrationFile
        }
        return Self(name: String(name.prefix(120)), points: points)
    }

    func correction(at frequency: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if frequency <= first.frequency { return first.correctionDB }
        if frequency >= last.frequency { return last.correctionDB }
        for (lower, upper) in zip(points, points.dropFirst()) where frequency <= upper.frequency {
            let fraction = log(frequency / lower.frequency) / log(upper.frequency / lower.frequency)
            return lower.correctionDB + fraction * (upper.correctionDB - lower.correctionDB)
        }
        return 0
    }
}

struct AcousticResponsePoint: Codable, Hashable, Sendable {
    let frequency: Double
    let relativeDB: Double
    let phaseRadians: Double
    let coherence: Double
}

struct AcousticSpeakerResponse: Codable, Hashable, Sendable {
    /// A 120 ms impulse-response window aligned to the direct arrival.
    let impulseResponse: [Float]
    let impulseSampleRate: Double
    let response: [AcousticResponsePoint]
    let signalToNoiseDB: Double
    let directArrivalSeconds: Double
    let levelDB: Double
    let earlyReflectionDelayMilliseconds: Double?
    let reflectedEnergyRatio: Double
    let meanCoherence: Double
}

struct AcousticPositionMeasurement: Codable, Hashable, Sendable {
    let position: AcousticMeasurementPosition
    let left: AcousticSpeakerResponse
    let right: AcousticSpeakerResponse
    /// Removes the known delay between the two emitted sweeps. Common output
    /// and capture latency cancels; this is not an absolute distance estimate.
    let rightMinusLeftArrivalMilliseconds: Double
    var rightMinusLeftLevelDB: Double { right.levelDB - left.levelDB }
}

enum AcousticMeasurementConfidence: String, Codable, Sendable {
    case limited, moderate, high
    var label: String { rawValue.capitalized }
}

struct SpatialAcousticProfile: Codable, Hashable, Sendable {
    var version = 1
    let outputDeviceUID: String
    let processing: ProcessingProfile
    let sampleRate: Int
    let measuredAt: Date
    let microphone: MeasurementMicrophone
    let microphoneCalibration: MicrophoneCalibrationCurve?
    let positions: [AcousticPositionMeasurement]
    let systemVolumeScalar: Float

    var confidence: AcousticMeasurementConfidence {
        let responses = positions.flatMap { [$0.left, $0.right] }
        guard !responses.isEmpty else { return .limited }
        let snr = responses.map(\.signalToNoiseDB).min() ?? 0
        let coherence = responses.map(\.meanCoherence).min() ?? 0
        if microphone.isBuiltIn || snr < 22 || coherence < 0.65 { return .limited }
        return microphoneCalibration != nil && snr >= 30 && coherence >= 0.85 ? .high : .moderate
    }

    var hasEarMeasurements: Bool {
        positions.contains { $0.position == .leftEar } && positions.contains { $0.position == .rightEar }
    }

    /// A bounded starting point, not an inverse room filter. Unknown microphone
    /// tonality must never cause automatic frequency-response boost/correction.
    var suggestedTuning: SpatialListenerTuning {
        guard let center = positions.first(where: { $0.position == .listeningPosition }) else { return .neutral }
        var tuning = SpatialListenerTuning()
        let confidenceScale: Float = confidence == .limited ? 0.35 : 1
        if !microphone.isBuiltIn {
            tuning.centerBalance = Float(-center.rightMinusLeftLevelDB / 35) * confidenceScale
        }
        let reflections = max(center.left.reflectedEnergyRatio, center.right.reflectedEnergyRatio)
        if reflections > 0.3 {
            tuning.depth = -0.10 * confidenceScale
            tuning.crosstalk = -0.08 * confidenceScale
            tuning.centerAnchor = 0.05 * confidenceScale
        } else if confidence != .limited {
            tuning.externalization = 0.04
        }
        if abs(center.rightMinusLeftArrivalMilliseconds) > 1 {
            tuning.crosstalk -= 0.06 * confidenceScale
            tuning.width -= 0.04 * confidenceScale
        }
        if hasEarMeasurements,
           let leftEar = positions.first(where: { $0.position == .leftEar }),
           let rightEar = positions.first(where: { $0.position == .rightEar }) {
            // Only modestly strengthen cancellation when both cross-ear paths
            // arrive later than their same-side paths and measurements agree.
            let leftDelay = leftEar.rightMinusLeftArrivalMilliseconds
            let rightDelay = -rightEar.rightMinusLeftArrivalMilliseconds
            if (0.08...0.6).contains(leftDelay), (0.08...0.6).contains(rightDelay),
               abs(leftDelay - rightDelay) < 0.2, confidence != .limited {
                tuning.crosstalk += 0.04
            } else {
                tuning.crosstalk -= 0.04
            }
        }
        return tuning.validated
    }

    func applies(to profile: DeviceProfile) -> Bool {
        version == 1 && outputDeviceUID == profile.outputDeviceUID
            && processing == profile.processing && sampleRate == profile.sampleRate
    }
}

enum AcousticMeasurementError: LocalizedError {
    case invalidCalibrationFile, noMicrophone, permissionDenied, captureFailed, recordingTooShort
    case clipped, tooQuiet, unreliable, routeChanged, invalidSignal

    var errorDescription: String? {
        switch self {
        case .invalidCalibrationFile: return "Use a microphone calibration text file with at least five frequency/dB rows, in ascending frequency order."
        case .noMicrophone: return "The selected microphone is unavailable. Reconnect it or select another input."
        case .permissionDenied: return "Allow CamiTune to use the microphone in System Settings → Privacy & Security → Microphone, then retry."
        case .captureFailed: return "Microphone capture failed or lost audio. Check the input connection and retry."
        case .recordingTooShort: return "The microphone did not capture both complete sweeps. Please retry."
        case .clipped: return "The microphone recording clipped. Lower the speaker volume or microphone gain and retry."
        case .tooQuiet: return "The sweeps were too quiet compared with the room noise. Reduce background noise or check microphone placement, then retry."
        case .unreliable: return "The speaker responses could not be separated reliably. Keep the microphone still, use a quiet room, and retry."
        case .routeChanged: return "The output, input, EQ, or volume changed during measurement. Please start a new measurement."
        case .invalidSignal: return "This sample rate or measurement signal is unsupported."
        }
    }
}
