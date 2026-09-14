import Foundation

/// Shared policy for catalog entry filtering, imports and explicit EQ transfer.
enum ReferenceCorrection {
    static func catalog(_ entries: [DeviceCatalogEntry], endpoint: ProfileEndpointKind) -> [DeviceCatalogEntry] {
        entries.compactMap { entry in
            let references = entry.measurements.filter { reference in
                let form = DeviceNameNormalizer.key(for: reference.form ?? "")
                switch endpoint {
                case .iem: return ["in ear", "inear", "iem", "earbud", "earbuds"].contains(form)
                case .headphones: return ["over ear", "overear", "on ear", "onear", "headphone", "headphones"].contains(form)
                default: return false
                }
            }
            guard !references.isEmpty else { return nil }
            return DeviceCatalogEntry(displayName: entry.displayName, measurements: references, identity: entry.identity)
        }
    }

    static func importText(_ text: String, name: String) throws -> DeviceCorrectionProfile {
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

    static func validFilters(_ filters: [EQBand], sampleRate: Double) -> Bool {
        filters.allSatisfy { band in
            band.frequency.isFinite && band.frequency > 0 && band.frequency < sampleRate / 2
                && (band.gain.map { $0.isFinite && (-60...60).contains($0) } ?? true)
                && (band.q.map { $0.isFinite && $0 > 0 } ?? true)
                && (band.bandwidth.map { $0.isFinite && $0 > 0 } ?? true)
        }
    }

    static func transfer(_ correction: DeviceCorrectionProfile, to processing: ProcessingProfile,
                         userPreampDB: Double) -> ProcessingProfile {
        var result = processing
        result.setDeviceCorrection(nil)
        result.setGlobalEqualizer(preampDB: userPreampDB, bands: correction.filters)
        result.globalEqualizerProvenance = correction.importedAPOText ? nil : correction
        return result
    }
}

@MainActor
extension AppState {
    func saveReferenceCorrection(profile original: DeviceProfile, correction: DeviceCorrectionProfile?) async throws {
        var draft = ProfileSettingsDraft(profile: original, activation: profiles.activationMode(for: original))
        var processing = try original.resolvedProcessing()
        processing.setDeviceCorrection(correction)
        draft.processing = processing
        // A legacy explicit EQ replacement draft must be resolved before replacing
        // the correction; otherwise session merging could silently remove it.
        guard !eqDraftReplacesDeviceCorrection(for: original.id) else {
            throw ProfileSettingsError.runtime("Save or discard your pending Equalizer replacement before changing correction.")
        }
        try await saveProfileSettings(draft)
    }

    func importReferenceToEqualizer(profile original: DeviceProfile, expectedDraft: String?) async throws {
        guard eqDraft(for: original.id) == expectedDraft,
              let correction = original.processing.deviceCorrection else { throw ProfileSettingsError.staleDraft }
        var draft = ProfileSettingsDraft(profile: original, activation: profiles.activationMode(for: original))
        let current = try applyingSessionEQDrafts(to: original)
        var processing = ReferenceCorrection.transfer(correction, to: try original.resolvedProcessing(),
            userPreampDB: current.processing.globalEqualizer.preampDB)
        if let limiter = limiterDraft(for: original.id) { processing.setLimiterEnabled(limiter) }
        draft.processing = processing
        draft.replacesUserEqualizer = true
        var layout = profiles.effectiveLayout(for: original)
        layout.hidden.remove(.equalizer)
        draft.sectionLayout = layout
        try await saveProfileSettings(draft)
    }
}
