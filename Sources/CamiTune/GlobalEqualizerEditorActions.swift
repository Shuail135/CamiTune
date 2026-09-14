import AppKit
import SwiftUI

@MainActor
extension GlobalEqualizerEditorView {
    func loadGraphicEQIfNeeded() {
        guard runtime.loadedProfileID != profile.id else { return }
        loadGraphicEQ()
    }

    func loadGraphicEQ() {
        if let oldID = runtime.loadedProfileID {
            state.history.cancelGesture(key: GestureKey(target: .profile(oldID), control: "equalizer"))
        }
        bandReduction.cancel()
        let draft = state.eqDraft(for: profile.id)
        let limiterDraft = state.limiterDraft(for: profile.id)
        let parsed: ParsedEQ
        let persistedLimiterEnabled: Bool
        do {
            let processing = try profile.resolvedProcessing()
            persistedLimiterEnabled = processing.limiterEnabled
            if let draft {
                parsed = try EqualizerAPOParser().parse(draft)
            } else {
                parsed = processing.globalEqualizer
            }
        } catch {
            state.errorMessage = error.localizedDescription
            return
        }
        runtime.suppressChanges = true
        runtime.continuousEditDepth = 0
        runtime.commitPendingAfterContinuousEdit = false
        runtime.liveApplyTask?.cancel()
        let organizedBands = EQEditorSupport.organizedBands(parsed.bands)
        simpleTone = state.toneDraft(for: profile.id) ?? profile.processing.simpleTone
        preampDB = parsed.preampDB
        limiterEnabled = limiterDraft ?? persistedLimiterEnabled
        graphicBands = organizedBands
        parsedForGraph = ParsedEQ(
            preampDB: parsed.preampDB,
            bands: organizedBands,
            warnings: parsed.warnings
        )
        runtime.loadedProfileID = profile.id
        updateGraphResponses()
        eqIsSaved = draft == nil && limiterDraft == nil && state.toneDraft(for: profile.id) == nil
        runtime.historyBaseline = currentHistoryState
        DispatchQueue.main.async { runtime.suppressChanges = false }
    }

    func editorValuesChanged() {
        guard !runtime.suppressChanges else { return }
        if runtime.continuousEditDepth == 0 { recordEQEdit() }
        graphicEQChanged()
    }

    func graphicEQChanged() {
        guard !runtime.suppressChanges else { return }

        eqIsSaved = false
        runtime.liveApplyTask?.cancel()
        if runtime.continuousEditDepth > 0 {
            runtime.commitPendingAfterContinuousEdit = true
            return
        }
        publishCurrentEQDraft()
        scheduleDeferredGraphicEQCommit(milliseconds: 250)
    }

    func continuousEditingChanged(_ isEditing: Bool) {
        if isEditing {
            if runtime.continuousEditDepth == 0 {
                runtime.historyBaseline = currentHistoryState
                state.history.beginGesture(key: eqGestureKey, actionName: "Adjust Equalizer", contextName: profile.name,
                    target: .profile(profile.id), before: .globalEQ(currentHistoryState))
            }
            runtime.continuousEditDepth += 1
            runtime.liveApplyTask?.cancel()
            return
        }

        runtime.continuousEditDepth = max(0, runtime.continuousEditDepth - 1)
        guard runtime.continuousEditDepth == 0 else { return }
        state.history.endGesture(key: eqGestureKey, after: .globalEQ(currentHistoryState))
        runtime.historyBaseline = currentHistoryState
        guard runtime.commitPendingAfterContinuousEdit else { return }
        runtime.commitPendingAfterContinuousEdit = false
        publishCurrentEQDraft()
        scheduleDeferredGraphicEQCommit(milliseconds: 60)
    }

    private func publishCurrentEQDraft() {
        // Replacement confirmation must see completed edits immediately, even
        // while the audio-application debounce is still pending.
        state.setEQDraft(serializeGraphicEQ(), for: profile.id)
        state.setLimiterDraft(limiterEnabled, for: profile.id)
        state.setToneDraft(simpleTone, for: profile.id)
    }

    func scheduleDeferredGraphicEQCommit(milliseconds: Int) {
        state.markPendingEditorApply(profile.id)
        runtime.liveApplyTask?.cancel()

        let editGeneration = state.editGeneration
        let profileID = profile.id
        let parsed = ParsedEQ(preampDB: preampDB, bands: graphicBands, warnings: [])
        let limiter = limiterEnabled
        runtime.liveApplyTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(milliseconds))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  editGeneration == state.editGeneration,
                  runtime.continuousEditDepth == 0,
                  profile.id == profileID else { return }

            let serialized = await Task.detached(priority: .utility) {
                EqualizerAPOSerializer().serialize(parsed)
            }.value
            guard !Task.isCancelled,
                  editGeneration == state.editGeneration,
                  runtime.continuousEditDepth == 0,
                  profile.id == profileID else { return }

            parsedForGraph = parsed
            state.setEQDraft(serialized, for: profileID)
            state.setLimiterDraft(limiter, for: profileID)
            updateGraphResponses()

            guard profileIsActive else { return }
            guard !Task.isCancelled,
                  editGeneration == state.editGeneration,
                  runtime.continuousEditDepth == 0,
                  profile.id == profileID else { return }
            do { try await state.applyHistoryProfileIfActive(profileID) }
            catch { state.errorMessage = error.localizedDescription }
        }
    }

    func saveGraphicEQ() {
        recordEQEdit()
        runtime.liveApplyTask?.cancel()
        if let effective = try? state.applyingSessionEQDrafts(to: profile) {
            profile.processing.setDeviceCorrection(effective.processing.deviceCorrection)
        }
        profile.setGlobalEqualizer(preampDB: preampDB, bands: graphicBands)
        profile.processing.setLimiterEnabled(limiterEnabled)
        profile.processing.simpleTone = simpleTone
        if state.eqDraftReplacesDeviceCorrection(for: profile.id) {
            profile.processing.setDeviceCorrection(nil)
        }
        state.applyDeviceCorrectionProvenanceDraft(
            to: &profile.processing,
            for: profile.id
        )
        state.clearEQDraft(for: profile.id)
        eqIsSaved = true
        runtime.historyBaseline = currentHistoryState
        if profileIsActive {
            let generation = state.editGeneration
            let id = profile.id
            state.markPendingEditorApply(id)
            Task {
                guard generation == state.editGeneration else { return }
                do { try await state.applyHistoryProfileIfActive(id) }
                catch { state.errorMessage = error.localizedDescription }
            }
        }
    }

    func profileWithCurrentEQ() -> DeviceProfile {
        var updated = profile
        updated.setGlobalEqualizer(preampDB: preampDB, bands: graphicBands)
        updated.processing.setLimiterEnabled(limiterEnabled)
        updated.processing.simpleTone = simpleTone
        return (try? state.applyingSessionEQDrafts(to: updated)) ?? updated
    }

    func preserveUnsavedEQDraft() {
        guard !eqIsSaved else { return }
        state.setEQDraft(serializeGraphicEQ(), for: profile.id)
        state.setLimiterDraft(limiterEnabled, for: profile.id)
        state.setToneDraft(simpleTone, for: profile.id)
    }

    func editLegacyCorrection() {
        guard let correction = profile.processing.deviceCorrection else { return }
        runtime.historyActionName = "Load Legacy Correction into Equalizer"
        runtime.suppressChanges = true
        graphicBands = EQEditorSupport.organizedBands(correction.filters + graphicBands)
        state.markEQDraftAsReplacingDeviceCorrection(for: profile.id)
        eqIsSaved = false
        if presentation == .simpleTone { onPresentationChanged(.both) }
        runtime.suppressChanges = false
        editorValuesChanged()
    }

    func importFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            state.errorMessage = "The clipboard does not contain Equalizer APO text."
            return
        }
        do { try importAPOText(text) }
        catch {
            state.errorMessage = "Invalid Equalizer APO text: \(error.localizedDescription)"
        }
    }

    func importAPOText(_ text: String) throws {
        let preservedUserPreampDB = preampDB
        if presentation == .simpleTone { onPresentationChanged(.both) }
        let parsed = try EqualizerAPOParser().parse(text, preampPolicy: .ignore)
        state.clearTransientError()
        guard parsed.importedDirectiveCount > 0 else { return }
        runtime.historyActionName = "Import Equalizer APO Text"
        runtime.suppressChanges = true
        let organizedBands = EQEditorSupport.organizedBands(parsed.bands)
        preampDB = preservedUserPreampDB
        graphicBands = organizedBands
        parsedForGraph = ParsedEQ(
            preampDB: preservedUserPreampDB,
            bands: organizedBands,
            warnings: parsed.warnings
        )
        updateGraphResponses()
        eqIsSaved = false
        state.setDeviceCorrectionProvenanceDraft(nil, for: profile.id)
        let generation = state.editGeneration
        DispatchQueue.main.async {
            guard generation == state.editGeneration else { return }
            preampDB = preservedUserPreampDB
            runtime.suppressChanges = false
            editorValuesChanged()
        }
    }

    func setBandCount(_ count: Int) {
        guard count != graphicBands.count else { return }
        if EQEditorSupport.shouldRefitWhenReducing(graphicBands, to: count) {
            pendingBandCount = count
            showBandReductionConfirmation = true
            return
        }
        runtime.historyActionName = "Change EQ Band Count"
        graphicBands = EQEditorSupport.resizedBands(graphicBands, count: count)
    }

    var bandReductionConfirmationMessage: String {
        let target = pendingBandCount ?? graphicBands.count
        return "Every current band has an active value. Reducing from \(graphicBands.count) to \(target) bands will recalculate frequency, gain, and Q to approximate the same overall EQ response."
    }

    func applyPendingBandReduction() {
        guard let target = pendingBandCount else { return }
        pendingBandCount = nil
        let editGeneration = state.editGeneration
        let originalBands = graphicBands
        let profileID = profile.id
        let sampleRate = profile.sampleRate
        bandReduction.run {
            EQEditorSupport.responseFittedBands(originalBands, count: target, sampleRate: Double(sampleRate))
        } completion: { result in
            guard editGeneration == state.editGeneration, profile.id == profileID, profile.sampleRate == sampleRate,
                  graphicBands == originalBands else { return }
            if case .success(let fitted) = result { runtime.historyActionName = "Recalculate EQ Bands"; graphicBands = fitted }
        }
    }

    func updateGraphResponses() {
        guard needsResponseGraph else {
            graphModel.cancel()
            runtime.filterResponseTask?.cancel()
            updateAutomaticSystemHeadroom()
            return
        }
        let calculator = EQResponseCalculator()
        let sampleRate = Double(profile.sampleRate)
        var combined = ParsedEQ(preampDB: parsedForGraph.preampDB,
            bands: presentation == .simpleTone ? [] : parsedForGraph.bands)
        if presentation != .bands {
            combined.bands += (try? SimpleToneFilterFactory.filters(for: simpleTone, sampleRate: Double(profile.sampleRate))) ?? []
        }
        let profileID = profile.id
        graphModel.calculate(parsed: combined, sampleRate: sampleRate)
        runtime.filterResponseTask?.cancel()
        guard presentation != .simpleTone else {
            updateAutomaticSystemHeadroom()
            return
        }
        let filterOnly = ParsedEQ(bands: parsedForGraph.bands)
        runtime.filterResponseTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return
            }
            let response = await Task.detached(priority: .userInitiated) {
                calculator.calculate(parsed: filterOnly, sampleRate: sampleRate)
            }.value
            guard !Task.isCancelled, profile.id == profileID else { return }
            filterResponsePoints = response
        }
        updateAutomaticSystemHeadroom()
    }

    func loadDeviceCorrectionEQ(_ correction: DeviceCorrectionProfile) {
        runtime.historyActionName = "Load Device Correction into Equalizer"
        if presentation == .simpleTone { onPresentationChanged(.both) }
        runtime.suppressChanges = true
        runtime.liveApplyTask?.cancel()
        let organizedBands = EQEditorSupport.organizedBands(correction.filters)
        preampDB = 0
        graphicBands = organizedBands
        parsedForGraph = ParsedEQ(preampDB: 0, bands: organizedBands, warnings: [])
        state.setDeviceCorrectionProvenanceDraft(correction, for: profile.id)
        state.setEQDraft(serializeGraphicEQ(), for: profile.id)
        eqIsSaved = false
        showDeviceCorrectionEditor = false
        updateGraphResponses()
        let generation = state.editGeneration
        DispatchQueue.main.async {
            guard generation == state.editGeneration else { return }
            runtime.suppressChanges = false
            editorValuesChanged()
        }
    }

    func updateAutomaticSystemHeadroom() {
        let candidate: DeviceProfile
        do {
            var current = profile
            current.setGlobalEqualizer(preampDB: preampDB, bands: graphicBands)
            current.processing.simpleTone = simpleTone
            current = try state.applyingSessionEQDrafts(to: current)
            current.setGlobalEqualizer(preampDB: preampDB, bands: graphicBands)
            current.processing.simpleTone = simpleTone
            candidate = current
        } catch {
            automaticSystemHeadroomDB = 0
            return
        }
        let profileID = profile.id
        runtime.headroomCalculationTask?.cancel()
        runtime.headroomCalculationTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            let headroom = await Task.detached(priority: .utility) {
                (try? ProcessingGraphBuilder(channelCount: candidate.processingChannelCount).build(profile: candidate)
                    .automaticHeadroomDB) ?? 0
            }.value
            guard !Task.isCancelled, profile.id == profileID else { return }
            automaticSystemHeadroomDB = headroom
        }
    }

    func automaticHeadroomForCorrection(_ filters: [EQBand]) -> Double {
        do {
            var candidate = profile
            candidate = try state.applyingSessionEQDrafts(to: candidate)
            candidate.processing.setDeviceCorrection(nil)
            candidate.setGlobalEqualizer(preampDB: 0, bands: filters)
            return try ProcessingGraphBuilder(channelCount: candidate.processingChannelCount).build(profile: candidate).automaticHeadroomDB
        } catch {
            return 0
        }
    }

    var currentDeviceCorrectionProvenance: DeviceCorrectionProfile? {
        state.deviceCorrectionProvenance(
            for: profile.id,
            persisted: profile.processing.globalEqualizerProvenance
        )
    }

    var eqGestureKey: GestureKey { GestureKey(target: .profile(profile.id), control: "equalizer") }
    var currentHistoryState: GlobalEQHistoryState {
        GlobalEQHistoryState(preampDB: preampDB, bands: graphicBands, limiterEnabled: limiterEnabled,
            simpleTone: simpleTone, replacesDeviceCorrection: state.eqDraftReplacesDeviceCorrection(for: profile.id),
            deviceCorrectionProvenance: currentDeviceCorrectionProvenance,
            deviceCorrection: state.eqDraftReplacesDeviceCorrection(for: profile.id) ? nil
                : ((try? state.applyingSessionEQDrafts(to: profile)) ?? profile).processing.deviceCorrection)
    }
    func recordEQEdit() {
        let after = currentHistoryState
        if let before = runtime.historyBaseline {
            let control = runtime.historyActionName == nil ? after.numericControl(changedFrom: before) : nil
            state.history.record(actionName: runtime.historyActionName ?? "Edit Equalizer", contextName: profile.name, target: .profile(profile.id),
                before: .globalEQ(before), after: .globalEQ(after),
                coalescingKey: control.map { GestureKey(target: .profile(profile.id), control: $0) })
        }
        runtime.historyBaseline = after
        runtime.historyActionName = nil
    }

    func serializeGraphicEQ() -> String {
        EqualizerAPOSerializer().serialize(
            ParsedEQ(preampDB: preampDB, bands: graphicBands, warnings: [])
        )
    }
}
