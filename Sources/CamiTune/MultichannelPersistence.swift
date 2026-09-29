import CamiTuneDomain
import Foundation

extension AppState {
    func scheduleMultichannelAutosave(_ draft: MultichannelHistoryState, for profileID: UUID, previewOnly: Bool = false) {
        multichannelEditSessions[profileID] = draft
        multichannelAutosaveTasks[profileID]?.cancel()
        let revision = UUID()
        let generation = editGeneration
        multichannelAutosaveRevisions[profileID] = revision
        multichannelAutosaveErrors[profileID] = nil
        multichannelAutosaveTasks[profileID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self else { return }
            defer {
                if self.multichannelAutosaveRevisions[profileID] == revision {
                    self.multichannelAutosaveTasks[profileID] = nil
                    self.multichannelAutosaveRevisions[profileID] = nil
                }
            }
            while self.isSavingProfileSettings || self.profiles.hasDurableCommit || self.transitionInProgress
                    || self.runtimeCoordinator.hasLiveApplyWork || self.spatialCalibrationContext != nil {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard !Task.isCancelled, self.editGeneration == generation,
                  self.multichannelAutosaveRevisions[profileID] == revision,
                  self.multichannelEditSessions[profileID] == draft else { return }
            do {
                try await self.saveMultichannelSettings(draft.settings, profileID: profileID,
                    topology: draft.topology, previewOnly: previewOnly)
            } catch {
                if self.multichannelAutosaveRevisions[profileID] == revision {
                    self.multichannelAutosaveErrors[profileID] = error.localizedDescription
                }
            }
        }
    }

    func cancelMultichannelAutosaves() {
        multichannelAutosaveTasks.values.forEach { $0.cancel() }
        multichannelAutosaveTasks.removeAll()
        multichannelAutosaveRevisions.removeAll()
    }

    @discardableResult
    func saveMultichannelSettings(_ value: MultichannelProcessingSettings, profileID: UUID,
                                  topology: SpeakerTopology? = nil, previewOnly: Bool = false, recordHistory: Bool = true) async throws -> DeviceProfile {
        let original = try historyProfile(profileID)
        var candidate = original; candidate.multichannel = value
        if let topology { candidate.speakerTopology = topology }
        if previewOnly {
            let checked = candidate
            guard let hardware = checked.speakerTopology else { throw SpeakerTopologyError.hardwareLayoutChanged }
            _ = try await Task.detached(priority: .userInitiated) {
                try AudioRuntimePlanPreparer.prepare(profile: checked, detectedHardware: hardware)
            }.value
            profiles.update(candidate)
        } else {
            var settings = ProfileSettingsDraft(profile: original, activation: profiles.activationMode(for: original))
            settings.multichannel = value
            if let topology { settings.speakerTopology = topology }
            try await saveProfileSettings(settings)
            candidate = try historyProfile(profileID)
        }
        if multichannelEditSessions[profileID] == .init(settings: value, topology: topology) {
            multichannelEditSessions[profileID] = nil
        }
        if recordHistory {
            history.record(actionName: "Change Multichannel Processing", contextName: original.name,
                target: .profile(profileID), before: .multichannel(.init(settings: original.multichannel, topology: original.speakerTopology)),
                after: .multichannel(.init(settings: value, topology: candidate.speakerTopology)))
        }
        return candidate
    }
}
