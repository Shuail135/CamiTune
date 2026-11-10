import CamiTuneAudio
import CamiTuneDomain
import Foundation

extension AppState {
    func eqDraft(for id: UUID) -> ParsedEQ? { processingDrafts[id]?.equalizer.parameters }
    func toneDraft(for id: UUID) -> SimpleToneSettings? { processingDrafts[id]?.equalizer.tone }
    func limiterDraft(for id: UUID) -> Bool? { processingDrafts[id]?.equalizer.limiter }

    func setEQDraft(_ parameters: ParsedEQ, for id: UUID) {
        setProcessingDraft(parameters, for: id, at: \.equalizer.parameters, measure: true)
    }

    func setToneDraft(_ tone: SimpleToneSettings, for id: UUID) {
        setProcessingDraft(tone, for: id, at: \.equalizer.tone, measure: true)
    }

    func setLimiterDraft(_ enabled: Bool, for id: UUID) {
        setProcessingDraft(enabled, for: id, at: \.equalizer.limiter)
    }

    func eqDraftReplacesDeviceCorrection(for id: UUID) -> Bool {
        processingDrafts[id]?.equalizer.replacesDeviceCorrection == true
    }

    func setDeviceCorrectionProvenanceDraft(_ correction: DeviceCorrectionProfile?, for id: UUID) {
        processingDrafts[id, default: .init()].equalizer.provenance = .replace(correction)
    }

    func deviceCorrectionProvenance(for id: UUID, persisted: DeviceCorrectionProfile?) -> DeviceCorrectionProfile? {
        let edit = processingDrafts[id]?.equalizer.provenance ?? .unchanged
        return edit.resolve(persisted)
    }

    func clearEQDraft(for id: UUID) {
        setProcessingDraft(.init(), for: id, at: \.equalizer)
    }

    func channelToneDraft(for id: UUID, channelIndex: Int) -> SimpleToneSettings? {
        processingDrafts[id]?.channels[channelIndex]?.tone
    }

    func channelEQDraft(for id: UUID, channelIndex: Int) -> ParsedEQ? {
        processingDrafts[id]?.channels[channelIndex]?.parameters
    }

    func channelLimiterDraft(for id: UUID, channelIndex: Int) -> Bool? {
        processingDrafts[id]?.channels[channelIndex]?.limiter
    }

    func channelDelayDraft(for id: UUID, channelIndex: Int) -> Double? {
        processingDrafts[id]?.channels[channelIndex]?.delay
    }

    func setChannelDelayDraft(_ milliseconds: Double, for id: UUID, channelIndex: Int) {
        var channel = processingDrafts[id]?.channels[channelIndex] ?? .init()
        channel.delay = milliseconds
        setProcessingDraft(channel, for: id, at: \.channels[channelIndex])
    }

    func setChannelProcessingDraft(equalizer: ParsedEQ, limiterEnabled: Bool, delayMilliseconds: Double,
        simpleTone: SimpleToneSettings? = nil, for id: UUID, channelIndex: Int) {
        var channel = processingDrafts[id]?.channels[channelIndex] ?? .init()
        channel.parameters = equalizer
        channel.limiter = limiterEnabled
        channel.delay = delayMilliseconds
        if let simpleTone { channel.tone = simpleTone }
        setProcessingDraft(channel, for: id, at: \.channels[channelIndex])
    }

    func clearChannelEQDraft(for id: UUID, channelIndex: Int) {
        setProcessingDraft(nil, for: id, at: \.channels[channelIndex])
    }

    func groupProcessingDraft(for id: UUID, groupID: SpeakerGroupID) -> PerChannelEditorSnapshot? {
        processingDrafts[id]?.groups[groupID].map { settings in
            .init(gainDB: settings.gainDB, delayMilliseconds: settings.delayMilliseconds,
                limiterEnabled: settings.limiterEnabled, bands: settings.bands, simpleTone: settings.simpleTone)
        }
    }

    func setGroupProcessingDraft(_ snapshot: PerChannelEditorSnapshot, for id: UUID, groupID: SpeakerGroupID) {
        setProcessingDraft(snapshot.processingSettings, for: id, at: \.groups[groupID])
    }

    func clearGroupProcessingDraft(for id: UUID, groupID: SpeakerGroupID) {
        setProcessingDraft(nil, for: id, at: \.groups[groupID])
    }

    func setGlobalEQHistoryDraft(_ snapshot: GlobalEQHistoryState, for id: UUID) {
        var draft = ProfileProcessingDraft.Equalizer()
        draft.parameters = ParsedEQ(preampDB: snapshot.preampDB, bands: snapshot.bands)
        draft.limiter = snapshot.limiterEnabled
        draft.tone = snapshot.simpleTone
        draft.replacesDeviceCorrection = snapshot.replacesDeviceCorrection
        draft.provenance = .replace(snapshot.deviceCorrectionProvenance)
        processingDrafts[id, default: .init()].equalizer = draft
        publishEQDraftChange(for: id)
    }

    func applyingSessionEQDrafts(to profile: DeviceProfile, replacingGlobalEqualizer: Bool = false) throws -> DeviceProfile {
        try (processingDrafts[profile.id] ?? .init()).applying(to: profile, replacingGlobalEqualizer: replacingGlobalEqualizer)
    }

    private func setProcessingDraft<Value: Equatable>(_ value: Value, for id: UUID,
        at path: WritableKeyPath<ProfileProcessingDraft, Value>, measure: Bool = false) {
        let started = measure && performanceRecorder.isCapturing ? PerformanceClock.now() : nil
        var updated = processingDrafts[id] ?? .init()
        guard updated[keyPath: path] != value else { return }
        updated[keyPath: path] = value
        processingDrafts[id] = updated == .init() ? nil : updated
        publishEQDraftChange(for: id, started: started)
    }
}
