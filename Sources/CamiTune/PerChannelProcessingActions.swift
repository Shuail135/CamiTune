import SwiftUI

@MainActor
extension PerChannelProcessingView {
    func loadSelectedChannelIfNeeded() {
        guard runtime.loadedProfileID != profile.id else { return }
        loadSelectedChannel()
    }

    func selectChannel(_ index: Int) {
        guard index != selectedChannelIndex || selectedGroup != nil else { return }
        changeSelection { selectedChannelIndex = index; selectionScope = .speakers }
    }

    func selectGroup(_ id: SpeakerGroupID) {
        guard selectedGroup?.id != id else { return }
        changeSelection { selectedGroupID = id; selectionScope = .groups }
    }

    func changeSelection(_ update: () -> Void) {
        bandReduction.cancel()
        runtime.liveApplyTask?.cancel()
        if runtime.continuousEditDepth > 0 {
            runtime.continuousEditDepth = 1
            continuousEditingChanged(false)
        }
        preserveSelectedDraft()
        update()
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
        guard let targetCount = pendingBandCount else { return }
        pendingBandCount = nil
        let editGeneration = state.editGeneration
        let originalBands = runtime.bands.values
        let profileID = profile.id
        let channelIndex = selectedChannelIndex
        let target = selectedTarget
        let sampleRate = profile.sampleRate
        bandReduction.run {
            EQEditorSupport.responseFittedBands(originalBands, count: targetCount, sampleRate: Double(sampleRate))
        } completion: { result in
            guard editGeneration == state.editGeneration, profile.id == profileID, selectedChannelIndex == channelIndex, selectedTarget == target,
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
            let target = runtime.loadedGroupID.map { HistoryTarget.profileGroup(oldID, $0) }
                ?? .profileChannel(oldID, channel)
            state.history.cancelGesture(key: GestureKey(target: target, control: "channel"))
        }
        bandReduction.cancel()
        runtime.suppressChanges = true
        if !editableChannels.contains(where: { $0.index == selectedChannelIndex }) { selectedChannelIndex = editableChannels.first?.index ?? 0 }
        runtime.liveApplyTask?.cancel()
        runtime.responseCalculationTask?.cancel()
        runtime.continuousEditDepth = 0
        runtime.commitPendingAfterContinuousEdit = false

        let processing = (try? profile.resolvedProcessing()) ?? profile.processing
        let settings: ChannelProcessingSettings
        let hasDraft: Bool
        if let group = selectedGroup {
            let draft = state.groupProcessingDraft(for: profile.id, groupID: group.id)
            settings = draft?.processingSettings ?? processing.settings(forGroup: group.id) ?? .identity
            hasDraft = draft != nil
        } else {
            var value = processing.settings(forChannel: selectedChannelIndex) ?? .identity
            let text = state.channelEQDraft(for: profile.id, channelIndex: selectedChannelIndex)
            let limiter = state.channelLimiterDraft(for: profile.id, channelIndex: selectedChannelIndex)
            let delay = state.channelDelayDraft(for: profile.id, channelIndex: selectedChannelIndex)
            let tone = state.channelToneDraft(for: profile.id, channelIndex: selectedChannelIndex)
            if let text, let parsed = try? EqualizerAPOParser().parse(text) {
                value.gainDB = parsed.preampDB; value.bands = parsed.bands
            }
            value.limiterEnabled = limiter ?? value.limiterEnabled
            value.delayMilliseconds = delay ?? value.delayMilliseconds
            value.simpleTone = tone ?? value.simpleTone
            settings = value
            hasDraft = text != nil || limiter != nil || delay != nil || tone != nil
        }
        runtime.simpleTone.value = settings.simpleTone
        runtime.gain.value = settings.gainDB
        let bands = EQEditorSupport.organizedBands(settings.bands)
        runtime.bands.replace(with: bands.isEmpty ? EQEditorSupport.resizedBands([], count: 8) : bands)
        runtime.delay.value = settings.delayMilliseconds
        runtime.limiter.value = settings.limiterEnabled
        runtime.loadedProfileID = profile.id
        runtime.loadedChannelIndex = selectedChannelIndex
        runtime.loadedGroupID = selectedGroup?.id
        runtime.updateStatus(isSaved: !hasDraft)
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
                state.history.beginGesture(key: channelGestureKey, actionName: selectedGroup == nil ? "Adjust Channel" : "Adjust Group", contextName: profile.name,
                    target: selectedTarget, before: .channel(runtime.snapshot))
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
        let target = selectedTarget
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
                  selectedChannelIndex == channelIndex, selectedTarget == target else { return }

            // APO formatting is pure CPU work; keep it off MainActor.
            let serialized = await Task.detached(priority: .utility) {
                EqualizerAPOSerializer().serialize(parsed)
            }.value
            guard !Task.isCancelled,
                  editGeneration == state.editGeneration,
                  runtime.continuousEditDepth == 0,
                  profile.id == profileID,
                  selectedChannelIndex == channelIndex, selectedTarget == target else { return }

            if let group = selectedGroup {
                state.setGroupProcessingDraft(snapshot, for: profileID, groupID: group.id)
            } else {
                state.setChannelProcessingDraft(eqText: serialized, limiterEnabled: snapshot.limiterEnabled,
                    delayMilliseconds: snapshot.delayMilliseconds, simpleTone: snapshot.simpleTone,
                    for: profileID, channelIndex: channelIndex)
            }

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
            if let group = selectedGroup {
                try updated.setGroupProcessing(id: group.id, settings: snapshot.processingSettings)
            } else {
                try updated.setChannelProcessing(index: selectedChannel.index, role: selectedChannel.role,
                    gainDB: snapshot.gainDB, bands: snapshot.bands, delayMilliseconds: snapshot.delayMilliseconds,
                    limiterEnabled: snapshot.limiterEnabled, simpleTone: snapshot.simpleTone)
            }
        } catch {
            state.errorMessage = error.localizedDescription
            return
        }

        profile = updated
        if let group = selectedGroup {
            state.clearGroupProcessingDraft(for: profile.id, groupID: group.id)
        } else { state.clearChannelEQDraft(for: profile.id, channelIndex: selectedChannel.index) }
        runtime.updateStatus(isSaved: true)
        updateResponses(using: snapshot)
        if profileIsActive { applySessionDraftsLive() }
    }

    func resetSelectedChannel() {
        runtime.historyActionName = selectedGroup == nil ? "Reset Channel" : "Reset Group"
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
        if let group = selectedGroup {
            state.setGroupProcessingDraft(snapshot, for: profile.id, groupID: group.id)
            return
        }
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
        GestureKey(target: selectedTarget, control: "channel")
    }
    func recordChannelEdit() {
        if let before = runtime.historyBaseline {
            let target = selectedTarget
            let control = runtime.historyActionName == nil ? runtime.snapshot.numericControl(changedFrom: before) : nil
            state.history.record(actionName: runtime.historyActionName ?? (selectedGroup == nil ? "Edit Channel" : "Edit Group"), contextName: profile.name,
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
        let target = selectedTarget
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
                  selectedChannelIndex == channelIndex, selectedTarget == target else { return }
            runtime.responses.filterResponse = responses.0
            runtime.responses.totalResponse = responses.1
        }
    }
}
