import SwiftUI

@MainActor
extension PerChannelProcessingView {
    func loadSelectedChannelIfNeeded() {
        guard runtime.loadedProfileID != profile.id else { return }
        loadSelectedChannel()
    }

    func selectChannel(_ index: Int) {
        guard index != selectedChannelIndex else { return }
        bandReduction.cancel()
        runtime.liveApplyTask?.cancel()
        if runtime.continuousEditDepth > 0 {
            runtime.continuousEditDepth = 1
            continuousEditingChanged(false)
        }
        preserveSelectedDraft()
        selectedChannelIndex = index
        loadSelectedChannel()
    }

    func requestBandCount(_ count: Int) {
        guard count != runtime.bands.count else { return }
        let currentBands = runtime.bands.values
        if EQEditorSupport.shouldRefitWhenReducing(currentBands, to: count) {
            pendingBandCount = count
            showBandReductionConfirmation = true
            return
        }
        runtime.historyActionName = "Change Channel Band Count"
        runtime.bands.replace(
            with: EQEditorSupport.resizedBands(currentBands, count: count)
        )
        channelSettingsChanged()
    }

    var bandReductionConfirmationMessage: String {
        let currentCount = runtime.bands.count
        let target = pendingBandCount ?? currentCount
        return "Every current band has an active value. Reducing from \(currentCount) to \(target) bands will recalculate frequency, gain, and Q to approximate the same channel-EQ response."
    }

    func applyPendingBandReduction() {
        guard let target = pendingBandCount else { return }
        pendingBandCount = nil
        let editGeneration = state.editGeneration
        let originalBands = runtime.bands.values
        let profileID = profile.id
        let channelIndex = selectedChannelIndex
        let sampleRate = profile.sampleRate
        bandReduction.run {
            EQEditorSupport.responseFittedBands(originalBands, count: target, sampleRate: Double(sampleRate))
        } completion: { result in
            guard editGeneration == state.editGeneration, profile.id == profileID, selectedChannelIndex == channelIndex,
                  profile.sampleRate == sampleRate, runtime.bands.values == originalBands else { return }
            if case .success(let fitted) = result {
                runtime.historyActionName = "Recalculate Channel EQ"
                runtime.bands.replace(with: fitted)
                channelSettingsChanged()
            }
        }
    }

    func loadSelectedChannel() {
        if let oldID = runtime.loadedProfileID, let channel = runtime.loadedChannelIndex {
            state.history.cancelGesture(key: GestureKey(target: .profileChannel(oldID, channel), control: "channel"))
        }
        bandReduction.cancel()
        runtime.suppressChanges = true
        if !editableChannels.contains(where: { $0.index == selectedChannelIndex }) { selectedChannelIndex = editableChannels.first?.index ?? 0 }
        runtime.liveApplyTask?.cancel()
        runtime.responseCalculationTask?.cancel()
        runtime.continuousEditDepth = 0
        runtime.commitPendingAfterContinuousEdit = false

        let draft = state.channelEQDraft(
            for: profile.id,
            channelIndex: selectedChannelIndex
        )
        let limiterDraft = state.channelLimiterDraft(
            for: profile.id,
            channelIndex: selectedChannelIndex
        )
        let delayDraft = state.channelDelayDraft(
            for: profile.id,
            channelIndex: selectedChannelIndex
        )

        let gainDB: Double
        let bands: [EQBand]
        let delayMilliseconds: Double
        let limiterEnabled: Bool

        if let draft, let parsed = try? EqualizerAPOParser().parse(draft) {
            gainDB = parsed.preampDB
            bands = EQEditorSupport.organizedBands(parsed.bands)
            delayMilliseconds = delayDraft
                ?? ((try? profile.resolvedProcessing()) ?? profile.processing).settings(forChannel: selectedChannelIndex)?.delayMilliseconds
                ?? 0
            limiterEnabled = limiterDraft
                ?? ((try? profile.resolvedProcessing()) ?? profile.processing).settings(forChannel: selectedChannelIndex)?.limiterEnabled
                ?? false
        } else {
            let settings = ((try? profile.resolvedProcessing()) ?? profile.processing).settings(forChannel: selectedChannelIndex) ?? .identity
            gainDB = settings.gainDB
            bands = EQEditorSupport.organizedBands(settings.bands)
            delayMilliseconds = delayDraft ?? settings.delayMilliseconds
            limiterEnabled = limiterDraft ?? settings.limiterEnabled
        }

        let toneDraft = state.channelToneDraft(for: profile.id, channelIndex: selectedChannelIndex)
        runtime.simpleTone.value = toneDraft
            ?? ((try? profile.resolvedProcessing()) ?? profile.processing).settings(forChannel: selectedChannelIndex)?.simpleTone
            ?? SimpleToneSettings()
        runtime.gain.value = gainDB
        runtime.bands.replace(with: bands.isEmpty ? EQEditorSupport.resizedBands([], count: 8) : bands)
        runtime.delay.value = delayMilliseconds
        runtime.limiter.value = limiterEnabled
        runtime.loadedProfileID = profile.id
        runtime.loadedChannelIndex = selectedChannelIndex
        runtime.updateStatus(isSaved: draft == nil && limiterDraft == nil && delayDraft == nil && toneDraft == nil)
        updateResponses()

        runtime.historyBaseline = runtime.snapshot
        DispatchQueue.main.async { runtime.suppressChanges = false }
    }

    /// Called directly by the small state owner that changed. No top-level
    /// @State mutation occurs here, so the whole GroupBox is not invalidated.
    func channelSettingsChanged() {
        guard !runtime.suppressChanges else { return }

        runtime.updateStatus(isSaved: false)
        runtime.liveApplyTask?.cancel()

        if runtime.continuousEditDepth > 0 {
            runtime.commitPendingAfterContinuousEdit = true
            return
        }

        recordChannelEdit()
        preserveSelectedDraft()
        scheduleDeferredChannelCommit(milliseconds: 250)
    }

    /// Sliders call this at pointer-down/up. Expensive response, APO, headroom,
    /// and DSP work is never allowed to begin while the pointer is held down.
    func continuousEditingChanged(_ isEditing: Bool) {
        if isEditing {
            if runtime.continuousEditDepth == 0 {
                state.history.beginGesture(key: channelGestureKey, actionName: "Adjust Channel", contextName: profile.name,
                    target: .profileChannel(profile.id, selectedChannelIndex), before: .channel(runtime.snapshot))
            }
            runtime.continuousEditDepth += 1
            runtime.liveApplyTask?.cancel()
            return
        }

        runtime.continuousEditDepth = max(0, runtime.continuousEditDepth - 1)
        guard runtime.continuousEditDepth == 0 else { return }
        state.history.endGesture(key: channelGestureKey, after: .channel(runtime.snapshot))
        runtime.historyBaseline = runtime.snapshot
        guard runtime.commitPendingAfterContinuousEdit else { return }
        preserveSelectedDraft()
        runtime.commitPendingAfterContinuousEdit = false
        scheduleDeferredChannelCommit(milliseconds: 60)
    }

    func scheduleDeferredChannelCommit(milliseconds: Int) {
        state.markPendingEditorApply(profile.id)
        runtime.liveApplyTask?.cancel()

        let editGeneration = state.editGeneration
        let profileID = profile.id
        let channelIndex = selectedChannelIndex
        let snapshot = runtime.snapshot
        let parsed = ParsedEQ(
            preampDB: snapshot.gainDB,
            bands: snapshot.bands,
            warnings: []
        )

        runtime.liveApplyTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(milliseconds))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  editGeneration == state.editGeneration,
                  runtime.continuousEditDepth == 0,
                  profile.id == profileID,
                  selectedChannelIndex == channelIndex else { return }

            // APO formatting is pure CPU work; keep it off MainActor.
            let serialized = await Task.detached(priority: .utility) {
                EqualizerAPOSerializer().serialize(parsed)
            }.value
            guard !Task.isCancelled,
                  editGeneration == state.editGeneration,
                  runtime.continuousEditDepth == 0,
                  profile.id == profileID,
                  selectedChannelIndex == channelIndex else { return }

            state.setChannelProcessingDraft(
                eqText: serialized,
                limiterEnabled: snapshot.limiterEnabled,
                delayMilliseconds: snapshot.delayMilliseconds,
                simpleTone: snapshot.simpleTone,
                for: profileID,
                channelIndex: channelIndex
            )

            // One response update and one live graph apply per settled edit.
            updateResponses(using: snapshot)
            guard profileIsActive else { return }
            applySessionDraftsLive()
        }
    }

    func saveSelectedChannel() {
        recordChannelEdit()
        runtime.liveApplyTask?.cancel()
        runtime.commitPendingAfterContinuousEdit = false
        let snapshot = runtime.snapshot

        var updated = profile
        do {
            try updated.setChannelProcessing(
                index: selectedChannel.index,
                role: selectedChannel.role,
                gainDB: snapshot.gainDB,
                bands: snapshot.bands,
                delayMilliseconds: snapshot.delayMilliseconds,
                limiterEnabled: snapshot.limiterEnabled,
                simpleTone: snapshot.simpleTone
            )
        } catch {
            state.errorMessage = error.localizedDescription
            return
        }

        profile = updated
        state.clearChannelEQDraft(
            for: profile.id,
            channelIndex: selectedChannel.index
        )
        runtime.updateStatus(isSaved: true)
        updateResponses(using: snapshot)
        if profileIsActive { applySessionDraftsLive() }
    }

    func resetSelectedChannel() {
        runtime.historyActionName = "Reset Channel"
        runtime.liveApplyTask?.cancel()
        runtime.simpleTone.value = SimpleToneSettings()
        runtime.gain.value = 0
        runtime.delay.value = 0
        runtime.bands.replace(with: [])
        runtime.limiter.value = false
        channelSettingsChanged()
    }

    func preserveSelectedDraft() {
        guard !runtime.status.isSaved else { return }
        let snapshot = runtime.snapshot
        state.setChannelProcessingDraft(
            eqText: EqualizerAPOSerializer().serialize(
                ParsedEQ(
                    preampDB: snapshot.gainDB,
                    bands: snapshot.bands,
                    warnings: []
                )
            ),
            limiterEnabled: snapshot.limiterEnabled,
            delayMilliseconds: snapshot.delayMilliseconds,
            simpleTone: snapshot.simpleTone,
            for: profile.id,
            channelIndex: selectedChannelIndex
        )
    }

    func applySessionDraftsLive() {
        let generation = state.editGeneration
        let id = profile.id
        state.markPendingEditorApply(id)
        Task {
            guard generation == state.editGeneration else { return }
            do { try await state.applyHistoryProfileIfActive(id) }
            catch { state.errorMessage = error.localizedDescription }
        }
    }

    var channelGestureKey: GestureKey {
        GestureKey(target: .profileChannel(profile.id, selectedChannelIndex), control: "channel")
    }
    func recordChannelEdit() {
        if let before = runtime.historyBaseline {
            let target = HistoryTarget.profileChannel(profile.id, selectedChannelIndex)
            let control = runtime.historyActionName == nil ? runtime.snapshot.numericControl(changedFrom: before) : nil
            state.history.record(actionName: runtime.historyActionName ?? "Edit Channel", contextName: profile.name,
                target: target, before: .channel(before), after: .channel(runtime.snapshot),
                coalescingKey: control.map { GestureKey(target: target, control: $0) })
        }
        runtime.historyBaseline = runtime.snapshot
        runtime.historyActionName = nil
    }

    func updateResponses() {
        updateResponses(using: runtime.snapshot)
    }

    func updateResponses(using snapshot: PerChannelEditorSnapshot) {
        let sampleRate = Double(profile.sampleRate)
        let profileID = profile.id
        let channelIndex = selectedChannelIndex
        runtime.responseCalculationTask?.cancel()
        runtime.responseCalculationTask = Task {
            // Keep all filter math off MainActor. This task is only created for a
            // settled edit, load, save, or sample-rate change—not every drag tick.
            let responses = await Task.detached(priority: .userInitiated) {
                let calculator = EQResponseCalculator()
                let toneBands = (try? SimpleToneFilterFactory.filters(
                    for: snapshot.simpleTone, sampleRate: sampleRate
                )) ?? []
                return (
                    calculator.calculate(
                        parsed: ParsedEQ(
                            preampDB: 0,
                            bands: snapshot.bands,
                            warnings: []
                        ),
                        sampleRate: sampleRate
                    ),
                    calculator.calculate(
                        parsed: ParsedEQ(
                            preampDB: snapshot.gainDB,
                            bands: snapshot.bands + toneBands,
                            warnings: []
                        ),
                        sampleRate: sampleRate
                    )
                )
            }.value
            guard !Task.isCancelled,
                  profile.id == profileID,
                  selectedChannelIndex == channelIndex else { return }
            runtime.responses.filterResponse = responses.0
            runtime.responses.totalResponse = responses.1
        }
    }
}
