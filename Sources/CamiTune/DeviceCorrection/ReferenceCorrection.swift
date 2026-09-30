import CamiTuneDomain
import Foundation

/// Shared policy for catalog entry filtering, imports and explicit EQ transfer.
extension ReferenceCorrection {
    /// Call from a background operation; keep access alive through reading and parsing.
    static func importFile(_ url: URL) throws -> DeviceCorrectionProfile {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let text = try String(contentsOf: url, encoding: .utf8)
        try Task.checkCancellation()
        return try importText(text, name: url.lastPathComponent)
    }

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

}

@MainActor
extension AppState {
    func saveReferenceCorrection(profile original: DeviceProfile, correction: DeviceCorrectionProfile?) async throws {
        var draft = ProfileSettingsDraft(profile: original, activation: profiles.activationMode(for: original))
        var updated = original
        updated.setPersonalReferenceCorrection(correction)
        draft.personalReferenceCorrections = updated.personalReferenceCorrections
        // A legacy explicit EQ replacement draft must be resolved before replacing
        // the correction; otherwise session merging could silently remove it.
        guard !eqDraftReplacesDeviceCorrection(for: original.id) else {
            throw ProfileSettingsError.runtime("Save or discard your pending Equalizer replacement before changing correction.")
        }
        try await saveProfileSettings(draft)
    }

    func importReferenceToEqualizer(profile original: DeviceProfile, expectedDraft: String?) async throws {
        guard eqDraft(for: original.id) == expectedDraft,
              let correction = original.personalReferenceCorrection else { throw ProfileSettingsError.staleDraft }
        let before = ReferenceTransferHistoryState(correction: original.personalReferenceCorrection,
            globalEQ: try globalEQHistoryState(for: original), sectionLayout: original.sectionLayout)
        var draft = ProfileSettingsDraft(profile: original, activation: profiles.activationMode(for: original))
        let current = try applyingSessionEQDrafts(to: original)
        var processing = ReferenceCorrection.transfer(correction, to: try original.resolvedProcessing(),
            userPreampDB: current.processing.globalEqualizer.preampDB)
        if let limiter = limiterDraft(for: original.id) { processing.setLimiterEnabled(limiter) }
        processing.simpleTone = current.processing.simpleTone
        draft.processing = processing
        var corrections = original.personalReferenceCorrections
        corrections.removeValue(forKey: original.effectiveEndpointKind.rawValue)
        draft.personalReferenceCorrections = corrections
        draft.replacesUserEqualizer = true
        var layout = profiles.effectiveLayout(for: original)
        layout.hidden.remove(.equalizer)
        if layout.equalizer == .simpleTone { layout.equalizer = .both }
        draft.sectionLayout = layout
        try await saveProfileSettings(draft)
        let latest = try historyProfile(original.id)
        let after = ReferenceTransferHistoryState(correction: latest.personalReferenceCorrection,
            globalEQ: try globalEQHistoryState(for: latest), sectionLayout: latest.sectionLayout)
        referenceCorrectionSessions[original.id] = ReferenceCorrectionSession(draft: latest.personalReferenceCorrection)
        history.record(actionName: "Import Reference to Equalizer", contextName: original.name, target: .profile(original.id),
            before: .referenceTransfer(before), after: .referenceTransfer(after))

    }
}
