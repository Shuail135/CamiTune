import CamiTuneDomain
import Foundation

struct SpeakerCorrectionEngine: Sendable {
    var bridge = SpeakerAutoEQBridge()
    func generate(measurement: SpeakerCEA2034Measurement, mode: SpeakerListeningMode,
                  settings: SpeakerCorrectionSettings, sampleRate: Double) async throws -> DeviceCorrectionProfile {
        let response = try await bridge.generate(measurement: measurement, mode: mode, settings: settings, sampleRate: sampleRate)
        let bands = try response.filters.map { filter -> EQBand in
            guard filter.type == "PK" else { throw SpeakerCorrectionError.invalid("Unsupported speaker correction filter type.") }
            return EQBand(kind: .peaking, frequency: filter.frequency, gain: filter.gainDB, q: filter.q)
        }
        try SpeakerCorrectionValidator().validate(bands, settings: settings, sampleRate: sampleRate)
        guard let original = mode == .nearField ? measurement.listeningWindow : measurement.estimatedInRoom else {
            throw SpeakerCorrectionError.invalid("The selected speaker measurement is missing the preview curve.")
        }
        let normalized = original.normalized()
        let target = mode == .nearField ? FrequencyResponse.flat()
            : FrequencyResponse(name: "Speaker-score objective (no fixed target)", points: [])
        let gains = EQResponseCalculator().gainsDB(at: normalized.points.map(\.frequency), parsed: .init(preampDB: 0, bands: bands), sampleRate: sampleRate)
        var correction = DeviceCorrectionProfile(deviceName: measurement.provenance.speakerName, policy: .recommended,
            measurement: normalized, target: target, curve: .init(points: zip(normalized.points, gains).map {
                .init(frequency: $0.frequency, gainDB: mode == .nearField ? -$0.magnitudeDB : $1,
                      confidence: MeasurementConfidenceCurve.unknownValue)
            }), filters: bands, preampDB: 0)
        correction.speakerProvenance = .init(speakerName: measurement.provenance.speakerName,
            measurementVersion: measurement.provenance.version, sourceDisplayName: measurement.provenance.sourceDisplayName,
            sourceContentHash: measurement.rawPayloadHash, retrievedAt: measurement.provenance.retrievedAt,
            listeningMode: mode, engineName: response.engine.name, engineVersion: response.engine.version,
            sampleRate: sampleRate, settings: settings)
        return correction
    }
}
