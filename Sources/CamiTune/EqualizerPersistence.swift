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
        let before = try globalEQHistoryState(for: profile)
        let bands = EQEditorSupport.organizedBands(correction.filters)
        var after = before
        after.preampDB = 0
        after.bands = bands
        after.deviceCorrectionProvenance = correction
        setDeviceCorrectionProvenanceDraft(correction, for: profile.id)
        setEQDraft(EqualizerAPOSerializer().serialize(ParsedEQ(preampDB: 0, bands: bands)), for: profile.id)
        do { try persistEqualizerEdits(for: profile.id) }
        catch {
            setGlobalEQHistoryDraft(before, for: profile.id)
            throw error
        }
        history.record(actionName: "Load Device Correction into Equalizer", contextName: profile.name,
            target: .profile(profile.id), before: .globalEQ(before), after: .globalEQ(after))
        markPendingEditorApply(profile.id)
    }
}
