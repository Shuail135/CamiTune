import CamiTuneDomain
import Foundation

@MainActor
extension AppState {
    func persistEqualizerEdits(for profileID: UUID) throws {
        guard profiles.settingsMutationsAllowed else { throw ProfileSettingsError.busy }
        let current = try historyProfile(profileID)
        try profiles.validateSettingsSnapshot(current, activation: profiles.activationMode(for: current))
        let updated = try applyingSessionEQDrafts(to: current)
        if updated != current { profiles.update(updated) }
        if eqDraftReplacesDeviceCorrection(for: profileID) { clearEQDraft(for: profileID) }
    }

    func loadAutoEQCorrectionDraft(_ correction: DeviceCorrectionProfile, for profile: DeviceProfile) throws {
        if let source = correction.speakerProvenance {
            guard source.sampleRate == Double(profile.sampleRate) else {
                throw SpeakerCorrectionError.invalid("Recalculate Auto EQ for the current sample rate.")
            }
            try SpeakerCorrectionValidator().validateManualFilters(correction.filters, sampleRate: Double(profile.sampleRate))
        }
        var before = try globalEQHistoryState(for: profile)
        var after = before
        after.preampDB = 0
        after.bands = EQEditorSupport.organizedBands(correction.filters)
        after.deviceCorrectionProvenance = correction
        after.deviceCorrection = nil
        after.replacesDeviceCorrection = true
        before.ownsLegacyCorrectionTransfer = true
        after.ownsLegacyCorrectionTransfer = true
        setGlobalEQHistoryDraft(after, for: profile.id)
        do { try persistEqualizerEdits(for: profile.id) }
        catch {
            setGlobalEQHistoryDraft(before, for: profile.id)
            throw error
        }
        history.record(actionName: "Load Auto EQ into Equalizer", contextName: profile.name,
            target: .profile(profile.id), before: .globalEQ(before), after: .globalEQ(after))
        markPendingEditorApply(profile.id)
    }

    func commitDeviceCorrection(_ correction: DeviceCorrectionProfile?, profileID: UUID) throws {
        guard profiles.settingsMutationsAllowed else { throw ProfileSettingsError.busy }
        let profile = try historyProfile(profileID)
        let before = profile.processing.deviceCorrection
        try mutateSavedProcessing(profileID: profileID) { $0.setDeviceCorrection(correction) }
        history.record(actionName: "Apply Device Correction", contextName: profile.name,
            target: .profile(profileID), before: .deviceCorrection(before), after: .deviceCorrection(correction))
        markPendingEditorApply(profileID)
    }
}
