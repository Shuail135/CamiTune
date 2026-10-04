import Foundation

package enum DeviceCorrectionPage: String, Hashable, Sendable, Identifiable {
    case automaticEQ, roomCorrection, convolution, crossfeed
    package var id: Self { self }
}

package enum SpeakerListeningMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case nearField, farField
    package var id: Self { self }
    package var title: String { self == .nearField ? "Near-field / Desktop" : "Far-field / Room listening" }
    package var loss: String { self == .nearField ? "speaker-flat" : "speaker-score" }
}

package struct SpeakerCorrectionSettings: Codable, Hashable, Sendable {
    package var filterCount = 7
    package var minFrequency = 60.0
    package var maxFrequency = 16_000.0
    package var minimumGainDB = -12.0
    package var maximumGainDB = 3.0
    package var minimumQ = 1.0
    package var maximumQ = 3.0
    package init() {}
    package func validate(sampleRate: Double) throws {
        guard [sampleRate, minFrequency, maxFrequency, minimumGainDB, maximumGainDB, minimumQ, maximumQ].allSatisfy(\.isFinite),
              (32_000...192_000).contains(sampleRate), (1...12).contains(filterCount),
              minFrequency >= 40, maxFrequency <= 20_000, minFrequency < maxFrequency, maxFrequency < sampleRate / 2,
              minimumGainDB >= -24, minimumGainDB < 0, (0...6).contains(maximumGainDB),
              minimumQ >= 0.5, maximumQ <= 6, minimumQ <= maximumQ else {
            throw SpeakerCorrectionError.invalid("Choose valid speaker correction bounds below Nyquist.")
        }
    }
}

package struct SpeakerCorrectionProvenance: Codable, Hashable, Sendable {
    package var providerID: String = "spinorama"
    package var speakerName: String
    package var measurementVersion: String
    package var measurementType: String = "CEA2034"
    package var sourceDisplayName: String
    package var sourceContentHash: String
    package var retrievedAt: Date
    package var listeningMode: SpeakerListeningMode
    package var engineName: String
    package var engineVersion: String
    package var sampleRate: Double
    package var settings: SpeakerCorrectionSettings
    package init(speakerName: String, measurementVersion: String, sourceDisplayName: String, sourceContentHash: String,
                 retrievedAt: Date, listeningMode: SpeakerListeningMode, engineName: String, engineVersion: String,
                 sampleRate: Double, settings: SpeakerCorrectionSettings) {
        self.speakerName = speakerName; self.measurementVersion = measurementVersion
        self.sourceDisplayName = sourceDisplayName; self.sourceContentHash = sourceContentHash; self.retrievedAt = retrievedAt
        self.listeningMode = listeningMode; self.engineName = engineName; self.engineVersion = engineVersion
        self.sampleRate = sampleRate; self.settings = settings
    }
}

package enum SpeakerCorrectionError: LocalizedError {
    case invalid(String)
    package var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
}

package struct SpeakerCorrectionValidator {
    package init() {}
    package func validate(_ bands: [EQBand], settings: SpeakerCorrectionSettings, sampleRate: Double, allowDisabledBands: Bool = false) throws {
        try settings.validate(sampleRate: sampleRate)
        guard !bands.isEmpty, bands.count <= settings.filterCount else { throw SpeakerCorrectionError.invalid("Use between 1 and \(settings.filterCount) speaker correction filters.") }
        for band in bands {
            guard (band.enabled || allowDisabledBands), band.kind == .peaking, band.frequency.isFinite,
                  let gain = band.gain, gain.isFinite, let q = band.q, q.isFinite,
                  band.frequency > 0, band.frequency < sampleRate / 2,
                  (settings.minFrequency...settings.maxFrequency).contains(band.frequency),
                  (settings.minimumGainDB...settings.maximumGainDB).contains(gain),
                  (settings.minimumQ...settings.maximumQ).contains(q) else {
                throw SpeakerCorrectionError.invalid("Use peaking filters with finite frequency, gain, and Q within the configured speaker correction bounds.")
            }
        }
        let points = EQResponseCalculator().calculate(parsed: .init(preampDB: 0, bands: bands), sampleRate: sampleRate, count: 4096)
        guard points.allSatisfy({ $0.gainDB.isFinite && $0.gainDB <= 6.000001 }) else {
            throw SpeakerCorrectionError.invalid("Overlapping correction filters exceed the +6 dB combined boost limit. Reduce filter gain or maximum boost, or recalculate.")
        }
    }
}
