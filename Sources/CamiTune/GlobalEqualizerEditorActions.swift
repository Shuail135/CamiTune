import AppKit
import SwiftUI

@MainActor
extension GlobalEqualizerEditorView {
    func loadGraphicEQIfNeeded() {
        guard runtime.loadedProfileID != profile.id else { return }
        loadGraphicEQ()
    }

    func loadGraphicEQ() {
        let draft = state.eqDraft(for: profile.id)
        let limiterDraft = state.limiterDraft(for: profile.id)
        let parsed: ParsedEQ
        let persistedLimiterEnabled: Bool
        var migratedDeviceCorrection = false
        do {
            let processing = try profile.resolvedProcessing()
            persistedLimiterEnabled = processing.limiterEnabled
            if let draft {
                parsed = try EqualizerAPOParser().parse(draft)
            } else if processing.deviceCorrection != nil {
                parsed = processing.globalEqualizerIncludingDeviceCorrection
                migratedDeviceCorrection = true
                state.setDeviceCorrectionProvenanceDraft(
                    processing.deviceCorrection,
                    for: profile.id
                )
                state.markEQDraftAsReplacingDeviceCorrection(for: profile.id)
                state.setEQDraft(
                    EqualizerAPOSerializer().serialize(parsed),
                    for: profile.id
                )
            } else {
                parsed = processing.globalEqualizer
            }
        } catch {
            state.errorMessage = error.localizedDescription
            return
        }
        runtime.suppressChanges = true
        runtime.liveApplyTask?.cancel()
        let organizedBands = EQEditorSupport.organizedBands(parsed.bands)
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
        eqIsSaved = draft == nil && limiterDraft == nil && !migratedDeviceCorrection
        DispatchQueue.main.async { runtime.suppressChanges = false }
    }

    func graphicEQChanged() {
        guard !runtime.suppressChanges else { return }

        eqIsSaved = false
        runtime.liveApplyTask?.cancel()
        if runtime.continuousEditDepth > 0 {
            runtime.commitPendingAfterContinuousEdit = true
            return
        }
        scheduleDeferredGraphicEQCommit(milliseconds: 250)
    }

    func continuousEditingChanged(_ isEditing: Bool) {
        if isEditing {
            runtime.continuousEditDepth += 1
            runtime.liveApplyTask?.cancel()
            return
        }

        runtime.continuousEditDepth = max(0, runtime.continuousEditDepth - 1)
        guard runtime.continuousEditDepth == 0,
              runtime.commitPendingAfterContinuousEdit else { return }
        runtime.commitPendingAfterContinuousEdit = false
        scheduleDeferredGraphicEQCommit(milliseconds: 60)
    }

    func scheduleDeferredGraphicEQCommit(milliseconds: Int) {
        runtime.liveApplyTask?.cancel()

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
                  runtime.continuousEditDepth == 0,
                  profile.id == profileID else { return }

            let serialized = await Task.detached(priority: .utility) {
                EqualizerAPOSerializer().serialize(parsed)
            }.value
            guard !Task.isCancelled,
                  runtime.continuousEditDepth == 0,
                  profile.id == profileID else { return }

            parsedForGraph = parsed
            state.setEQDraft(serialized, for: profileID)
            state.setLimiterDraft(limiter, for: profileID)
            updateGraphResponses()

            guard profileIsActive else { return }
            let updatedProfile = profileWithCurrentEQ()
            guard !Task.isCancelled,
                  runtime.continuousEditDepth == 0,
                  profile.id == profileID else { return }
            await state.apply(profile: updatedProfile)
        }
    }

    func saveGraphicEQ() {
        runtime.liveApplyTask?.cancel()
        profile.setGlobalEqualizer(preampDB: preampDB, bands: graphicBands)
        profile.processing.setLimiterEnabled(limiterEnabled)
        if state.eqDraftReplacesDeviceCorrection(for: profile.id) {
            profile.processing.setDeviceCorrection(nil)
        }
        state.applyDeviceCorrectionProvenanceDraft(
            to: &profile.processing,
            for: profile.id
        )
        state.clearEQDraft(for: profile.id)
        eqIsSaved = true
        if profileIsActive {
            let updated = (try? state.applyingSessionEQDrafts(to: profile)) ?? profile
            Task { await state.apply(profile: updated) }
        }
    }

    func profileWithCurrentEQ() -> DeviceProfile {
        var updated = profile
        updated.setGlobalEqualizer(preampDB: preampDB, bands: graphicBands)
        updated.processing.setLimiterEnabled(limiterEnabled)
        return (try? state.applyingSessionEQDrafts(to: updated)) ?? updated
    }

    func preserveUnsavedEQDraft() {
        guard !eqIsSaved else { return }
        state.setEQDraft(serializeGraphicEQ(), for: profile.id)
        state.setLimiterDraft(limiterEnabled, for: profile.id)
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
        let parsed = try EqualizerAPOParser().parse(text, preampPolicy: .ignore)
        state.clearTransientError()
        guard parsed.importedDirectiveCount > 0 else { return }
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
        DispatchQueue.main.async {
            preampDB = preservedUserPreampDB
            runtime.suppressChanges = false
            graphicEQChanged()
        }
    }

    func setBandCount(_ count: Int) {
        guard count != graphicBands.count else { return }
        if EQEditorSupport.shouldRefitWhenReducing(graphicBands, to: count) {
            pendingBandCount = count
            showBandReductionConfirmation = true
            return
        }
        graphicBands = EQEditorSupport.resizedBands(graphicBands, count: count)
    }

    var bandReductionConfirmationMessage: String {
        let target = pendingBandCount ?? graphicBands.count
        return "Every current band has an active value. Reducing from \(graphicBands.count) to \(target) bands will recalculate frequency, gain, and Q to approximate the same overall EQ response."
    }

    func applyPendingBandReduction() {
        guard let target = pendingBandCount else { return }
        pendingBandCount = nil
        graphicBands = EQEditorSupport.responseFittedBands(
            graphicBands,
            count: target,
            sampleRate: Double(profile.sampleRate)
        )
    }

    func updateGraphResponses() {
        let calculator = EQResponseCalculator()
        var combined = parsedForGraph
        if !state.eqDraftReplacesDeviceCorrection(for: profile.id),
           let correction = profile.processing.deviceCorrection,
           correction.isEnabled {
            combined.bands.insert(contentsOf: correction.filters, at: 0)
        }
        let filterOnly = ParsedEQ(preampDB: 0, bands: graphicBands, warnings: [])
        let sampleRate = Double(profile.sampleRate)
        let profileID = profile.id
        graphModel.calculate(parsed: combined, sampleRate: sampleRate)
        runtime.filterResponseTask?.cancel()
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
        runtime.suppressChanges = true
        runtime.liveApplyTask?.cancel()
        let organizedBands = EQEditorSupport.organizedBands(correction.filters)
        preampDB = 0
        graphicBands = organizedBands
        parsedForGraph = ParsedEQ(preampDB: 0, bands: organizedBands, warnings: [])
        state.markEQDraftAsReplacingDeviceCorrection(for: profile.id)
        state.setDeviceCorrectionProvenanceDraft(correction, for: profile.id)
        state.setEQDraft(serializeGraphicEQ(), for: profile.id)
        eqIsSaved = false
        showDeviceCorrectionEditor = false
        updateGraphResponses()
        DispatchQueue.main.async {
            runtime.suppressChanges = false
            graphicEQChanged()
        }
    }

    func updateAutomaticSystemHeadroom() {
        let candidate: DeviceProfile
        do {
            var current = profile
            current.setGlobalEqualizer(preampDB: preampDB, bands: graphicBands)
            current = try state.applyingSessionEQDrafts(to: current)
            current.setGlobalEqualizer(preampDB: preampDB, bands: graphicBands)
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
                (try? ProcessingGraphBuilder().build(profile: candidate)
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
            return try ProcessingGraphBuilder().build(profile: candidate).automaticHeadroomDB
        } catch {
            return 0
        }
    }

    var currentDeviceCorrectionProvenance: DeviceCorrectionProfile? {
        state.deviceCorrectionProvenance(
            for: profile.id,
            persisted: profile.processing.globalEqualizerProvenance
                ?? profile.processing.deviceCorrection
        )
    }

    func serializeGraphicEQ() -> String {
        EqualizerAPOSerializer().serialize(
            ParsedEQ(preampDB: preampDB, bands: graphicBands, warnings: [])
        )
    }
}
