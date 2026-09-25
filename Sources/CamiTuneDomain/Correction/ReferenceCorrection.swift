import Foundation

package enum ReferenceCorrection {
    package static func importText(_ text: String, name: String) throws -> DeviceCorrectionProfile {
        let parsed = try EqualizerAPOParser().parse(text, preampPolicy: .ignore)
        guard !parsed.bands.isEmpty else {
            throw ProfileSettingsError.runtime("No compatible filters were found. APO Preamp is ignored; use User Preamp instead.")
        }
        var correction = DeviceCorrectionProfile(deviceName: name, policy: .recommended,
            measurement: .flat(), target: .flat(), curve: CorrectionCurve(points: []),
            filters: parsed.bands, preampDB: 0)
        correction.importedAPOText = true
        return correction
    }

    package static func validFilters(_ filters: [EQBand], sampleRate: Double) -> Bool {
        filters.allSatisfy { band in
            band.frequency.isFinite && band.frequency > 0 && band.frequency < sampleRate / 2
                && (band.gain.map { $0.isFinite && (-60...60).contains($0) } ?? true)
                && (band.q.map { $0.isFinite && $0 > 0 } ?? true)
                && (band.bandwidth.map { $0.isFinite && $0 > 0 } ?? true)
        }
    }

    package static func transfer(_ correction: DeviceCorrectionProfile, to processing: ProcessingProfile,
                         userPreampDB: Double) -> ProcessingProfile {
        var result = processing
        result.setDeviceCorrection(nil)
        result.setGlobalEqualizer(preampDB: userPreampDB, bands: correction.filters)
        result.globalEqualizerProvenance = correction.importedAPOText ? nil : correction
        return result
    }
}

extension ReferenceCorrection {
    package static func headroomDB(_ correction: DeviceCorrectionProfile?, sampleRate: Double) -> Double {
        guard let correction, correction.isEnabled else { return 0 }
        return PerAppAudioSettings(eqBypassed: false, equalizerBands: correction.filters)
            .automaticHeadroomDB(sampleRate: sampleRate)
    }
}
