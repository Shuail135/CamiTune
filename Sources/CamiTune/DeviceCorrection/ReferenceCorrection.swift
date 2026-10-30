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

/// Reuses the measurement consensus, fixture compatibility and bounded PEQ
/// engine used by Reference. Spatial owns the resulting correction separately.
enum SpatialHeadphoneCorrection {
    static func describe(_ entry: DeviceCatalogEntry) -> SpatialPlaybackDevice {
        let forms = Set(entry.measurements.compactMap { DeviceForm(catalogValue: $0.form) })
        return .init(id: entry.id, name: entry.displayName, source: "AutoEq",
            catalogForm: forms.count == 1 ? forms.first : nil, verifiedType: verifiedType(model: entry.displayName))
    }

    /// Exact catalog names only. These independently checked enclosure facts
    /// do not authorize fuzzy matches, fixture conversions or anatomy defaults.
    private static func verifiedType(model: String) -> SpatialDeviceTypeEvidence? {
        let name: String, enclosure: HeadphoneEnclosure, url: String
        switch DeviceNameNormalizer.key(for: model) {
        case "sennheiser hd 600", "sennheiser hd600":
            name = "Sennheiser HD 600"; enclosure = .openBack
            url = "https://www.sennheiser-hearing.com/p/hd-600/1000/"
        case "sennheiser hd 620s", "sennheiser hd620s", "sennheiser hd 620 s":
            name = "Sennheiser HD 620S"; enclosure = .closedBack
            url = "https://newsroom.sennheiser.com/distraction-off-open-sound-on"
        default: return nil
        }
        return .init(type: .init(form: .overEar, enclosure: enclosure), model: name,
            sourceName: "Sennheiser", sourceURL: url, revision: "2026-10-27",
            reviewedAt: Date(timeIntervalSince1970: 1_793_059_200),
            rights: "Independently recorded product facts; no manufacturer text, images or measurement data reproduced.")
    }

    static func paths(measurements: [DeviceCorrectionMeasurement]) throws -> [CorrectionPath] {
        try TargetCompatibilityEngine().rankedPaths(measurements: measurements).filter {
            $0.target == .diffuseFieldReference || $0.target == .neutral
        }.sorted { a, b in
            if a.target != b.target { return a.target == .diffuseFieldReference }
            if a.isConverted != b.isConverted { return !a.isConverted }
            return a.confidence > b.confidence
        }
    }

    static func prepare(entry: DeviceCatalogEntry, measurements: [DeviceCorrectionMeasurement],
                        target: DeviceCorrectionTargetPreset, typeOverride: SpatialDeviceType? = nil) throws -> SpatialPlaybackDevice {
        var result = describe(entry)
        result.typeOverride = typeOverride
        guard let path = try paths(measurements: measurements).first(where: {
            $0.target == target && result.resolvedType.supportsCorrection(from: $0.sources)
        }) else {
            throw PersonalSpatialError.invalidHeadphoneCorrection
        }
        let ids = Set(path.sources.map(\.id))
        let compatible = measurements.filter { ids.contains($0.source.id) }
        let selection = DeviceCorrectionTargetSelection(preset: target)
        let resolved = try DeviceCorrectionTargetCatalog().resolve(selection: selection, sources: path.sources)
        let correction = try DeviceCorrectionEngine().generate(deviceName: entry.displayName, measurements: compatible,
            target: resolved.response, targetSelection: selection, policy: .recommended, filterCount: 12,
            sampleRate: 44_100, targetConfidence: resolved.confidence)
        result.correction = correction
        try result.validate()
        return result
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
        let position = history.beginPendingEdit()
        defer { history.endPendingEdit(position) }
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
        try await saveProfileSettings(draft, historyAction: nil)
        let latest = try historyProfile(original.id)
        let after = ReferenceTransferHistoryState(correction: latest.personalReferenceCorrection,
            globalEQ: try globalEQHistoryState(for: latest), sectionLayout: latest.sectionLayout)
        referenceCorrectionSessions[original.id] = ReferenceCorrectionSession(draft: latest.personalReferenceCorrection)
        history.record(actionName: "Import Reference to Equalizer", contextName: original.name, target: .profile(original.id),
            before: .referenceTransfer(before), after: .referenceTransfer(after), position: position)

    }
}
