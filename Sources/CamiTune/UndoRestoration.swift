import Foundation

struct ReferenceCorrectionSession {
    var draft: DeviceCorrectionProfile?
}

extension AppState: HistoryRestoring {
    func setReferenceCorrectionDraft(_ value: DeviceCorrectionProfile?, for id: UUID) {
        guard let profile = try? historyProfile(id) else { return }
        let before = referenceCorrectionSessions[id]?.draft ?? (referenceCorrectionSessions[id] == nil ? profile.personalReferenceCorrection : nil)
        referenceCorrectionSessions[id] = ReferenceCorrectionSession(draft: value)
        history.record(actionName: "Edit Reference Correction", contextName: profile.name, target: .referenceCorrection(id),
            before: .referenceCorrection(before), after: .referenceCorrection(value))
        objectWillChange.send()
    }

    func globalEQHistoryState(for profile: DeviceProfile) throws -> GlobalEQHistoryState {
        let effective = try applyingSessionEQDrafts(to: profile)
        let processing = try effective.resolvedProcessing()
        return GlobalEQHistoryState(preampDB: processing.globalEqualizer.preampDB,
            bands: processing.globalEqualizer.bands, limiterEnabled: processing.limiterEnabled,
            simpleTone: processing.simpleTone, replacesDeviceCorrection: eqDraftReplacesDeviceCorrection(for: profile.id),
            deviceCorrectionProvenance: processing.globalEqualizerProvenance, deviceCorrection: processing.deviceCorrection)
    }

    func historyProfile(_ id: UUID) throws -> DeviceProfile {
        guard let profile = profiles.profiles.first(where: { $0.id == id }) else { throw HistoryRestoreError.missingProfile }
        return profile
    }

    /// Saved processing mutations preserve every current session draft.
    func mutateSavedProcessing(profileID: UUID, _ mutation: (inout ProcessingProfile) -> Void) throws {
        var profile = try historyProfile(profileID)
        var processing = try profile.resolvedProcessing()
        mutation(&processing)
        profile.processing = processing
        profiles.update(profile)
    }
    func applyHistoryProfileIfActive(_ id: UUID) async throws {
        clearPendingEditorApply(id)
        let effective = try applyingSessionEQDrafts(to: historyProfile(id))
        if isActive, activeProfileID == id {
            clearTransientError()
            await apply(profile: effective)
            if let errorMessage { throw ProfileSettingsError.runtime(errorMessage) }
        }
    }

    func restoreHistoryState(_ snapshot: HistoryState, target: HistoryTarget) async throws {
        guard !isSavingProfileSettings, !transitionInProgress else { throw HistoryRestoreError.busy }
        let previous = try currentHistoryState(matching: snapshot, target: target)
        invalidateDeferredEdits()
        do {
            try await restoreHistoryValue(snapshot, target: target)
            try persistHistoryChanges(for: snapshot)
            if let id = activeProfileID, pendingEditorApplies.contains(id) { try await applyHistoryProfileIfActive(id) }
            publishHistoryReplay()
        } catch {
            // Restore the same domain slice only. Unrelated state and later
            // runtime observations never come from a historical app snapshot.
            try? await restoreHistoryValue(previous, target: target)
            try? persistHistoryChanges(for: previous)
            publishHistoryReplay()
            throw error
        }
    }

    private func persistHistoryChanges(for snapshot: HistoryState) throws {
        switch snapshot {
        case .crossfeed, .convolution, .profileName, .profileOrganization, .deletion, .referenceTransfer:
            try profiles.persistHistoryChanges()
        case .perAppAudio, .perAppBatch: try perAppAudio.persistHistoryChanges()
        case .appAlias, .appPlacement: try perAppAudio.presentationStore.persistHistoryChanges()
        default: break
        }
    }

    private func currentHistoryState(matching snapshot: HistoryState, target: HistoryTarget) throws -> HistoryState {
        switch (snapshot, target) {
        case (.multichannel, .profile(let id)):
            let profile = try historyProfile(id)
            return .multichannel(.init(settings: profile.multichannel, topology: profile.speakerTopology))
        case (.globalEQ, .profile(let id)): return .globalEQ(try globalEQHistoryState(for: historyProfile(id)))
        case (.channel, .profileChannel(let id, let channel)):
            let profile = try applyingSessionEQDrafts(to: historyProfile(id))
            let value = try profile.resolvedProcessing().settings(forChannel: channel) ?? .identity
            return .channel(PerChannelEditorSnapshot(gainDB: value.gainDB, delayMilliseconds: value.delayMilliseconds,
                limiterEnabled: value.limiterEnabled, bands: value.bands, simpleTone: value.simpleTone))
        case (.crossfeed, .profile(let id)):
            let stage = try historyProfile(id).processing.crossfeed
            return .crossfeed(CrossfeedHistoryState(processor: stage?.processor ?? .standard, isEnabled: stage?.isEnabled ?? false))
        case (.channel, .profileGroup(let id, let group)):
            let profile = try applyingSessionEQDrafts(to: historyProfile(id))
            let value = try profile.resolvedProcessing().settings(forGroup: group) ?? .identity
            return .channel(PerChannelEditorSnapshot(gainDB: value.gainDB, delayMilliseconds: value.delayMilliseconds,
                limiterEnabled: value.limiterEnabled, bands: value.bands, simpleTone: value.simpleTone))
        case (.convolution, .profile(let id)):
            let stage = try historyProfile(id).processing.convolution
            return .convolution(ConvolutionHistoryState(processor: stage?.processor, isEnabled: stage?.isEnabled ?? false))
        case (.perAppAudio, .application(let id)): return .perAppAudio(perAppAudio.settings(for: id))
        case (.perAppBatch(let values), .applicationPresentationDocument):
            return .perAppBatch(Dictionary(uniqueKeysWithValues: values.keys.map { ($0, perAppAudio.settings(for: $0)) }))
        case (.appAlias, .applicationPresentation(let id)): return .appAlias(perAppAudio.presentationStore.currentDocument.records[id]?.userAlias)
        case (.appPlacement, .applicationPresentationDocument): return .appPlacement(perAppAudio.presentationStore.placementHistoryState())
        case (.profileName, .profile(let id)): return .profileName(try historyProfile(id).name)
        case (.profileOrganization, .profileOrganization): return .profileOrganization(profiles.organizationHistoryState())
        case (.referenceCorrection, .referenceCorrection(let id)):
            let profile = try historyProfile(id)
            return .referenceCorrection(referenceCorrectionSessions[id]?.draft ?? (referenceCorrectionSessions[id] == nil ? profile.personalReferenceCorrection : nil))
        case (.speakerSystem, .speakerSystem(let id)):
            let profile = try historyProfile(id)
            return .speakerSystem(speakerEditSessions[id] ?? SpeakerSystemHistoryState(topology: profile.speakerTopology, seat: profile.effectiveSpatialSettings.seating))
        case (.referenceTransfer, .profile(let id)):
            let profile = try historyProfile(id)
            return .referenceTransfer(ReferenceTransferHistoryState(correction: profile.personalReferenceCorrection,
                globalEQ: try globalEQHistoryState(for: profile), sectionLayout: profile.sectionLayout))
        case (.deletion(let value, let deleted), .profileOrganization):
            let ids = Set(value.profiles.map(\.id))
            let existing = Set(profiles.profiles.map(\.id))
            if deleted {
                guard ids.isSubset(of: existing) else { throw HistoryRestoreError.missingProfile }
                return .deletion(profiles.captureDeletionSnapshot(profileIDs: ids, folderID: value.folderID), deleted: false)
            }
            guard ids.isDisjoint(with: existing), value.folderID == nil || !profiles.folders.contains(where: { $0.id == value.folderID }) else {
                throw HistoryRestoreError.invalidOrganization
            }
            return .deletion(value, deleted: true)
        default: throw HistoryRestoreError.invalidStateForTarget
        }
    }

    private func restoreHistoryValue(_ snapshot: HistoryState, target: HistoryTarget) async throws {
        var applyID: UUID?
        switch (snapshot, target) {
        case let (.multichannel(value), .profile(id)):
            try await saveMultichannelSettings(value.settings, profileID: id, topology: value.topology,
                previewOnly: ProcessInfo.processInfo.arguments.contains("--speaker-setup-preview"), recordHistory: false)
        case let (.globalEQ(value), .profile(id)):
            _ = try historyProfile(id)
            setGlobalEQHistoryDraft(value, for: id)
            applyID = id
        case let (.channel(value), .profileChannel(id, channel)):
            let profile = try historyProfile(id)
            guard channel >= 0, channel < profile.processingChannelCount else { throw HistoryRestoreError.invalidStateForTarget }
            setChannelProcessingDraft(eqText: EqualizerAPOSerializer().serialize(ParsedEQ(preampDB: value.gainDB, bands: value.bands)),
                limiterEnabled: value.limiterEnabled, delayMilliseconds: value.delayMilliseconds,
                simpleTone: value.simpleTone, for: id, channelIndex: channel)
            applyID = id
        case let (.crossfeed(value), .profile(id)):
            try mutateSavedProcessing(profileID: id) { $0.setCrossfeed(value.processor, enabled: value.isEnabled) }
            applyID = id
        case let (.channel(value), .profileGroup(id, group)):
            let profile = try historyProfile(id)
            guard profile.configuredSpeakerGroups.contains(where: { $0.id == group }) else {
                throw HistoryRestoreError.invalidStateForTarget
            }
            setGroupProcessingDraft(value, for: id, groupID: group)
            applyID = id
        case let (.convolution(value), .profile(id)):
            try mutateSavedProcessing(profileID: id) { $0.setConvolution(value.processor, enabled: value.isEnabled) }
            applyID = id
        case let (.perAppAudio(value), .application(id)):
            perAppAudio.replaceSettings(value, for: id)
        case let (.perAppBatch(values), .applicationPresentationDocument):
            perAppAudio.replaceSettingsBatch(values)
        case let (.appAlias(value), .applicationPresentation(id)):
            perAppAudio.presentationStore.setAlias(value, for: id)
        case let (.appPlacement(value), .applicationPresentationDocument):
            perAppAudio.presentationStore.restorePlacementHistoryState(value)
        case let (.profileName(name), .profile(id)):
            _ = try historyProfile(id)
            guard ProfileNamePolicy.isAvailable(name, in: profiles.profiles, excluding: id) else { throw HistoryRestoreError.invalidOrganization }
            try await commitProfileRename(id: id, to: name)
        case let (.deletion(value, deleted), .profileOrganization):
            if deleted {
                if let folder = value.folderID {
                    guard await deleteProfileFolder(id: folder, confirmedProfileIDs: Set(value.profiles.map(\.id))) else {
                        throw HistoryRestoreError.invalidOrganization
                    }
                } else {
                    guard let id = value.profiles.first?.id else { throw HistoryRestoreError.invalidStateForTarget }
                    _ = try historyProfile(id)
                    await deleteProfileWithHistory(id: id)
                }
            } else {
                try profiles.restoreDeletedProfiles(value)
                do {
                    try await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(profiles: profiles.profiles, activeProfileID: activeProfileID)
                } catch { errorMessage = "Profile data was restored, but its audio device label could not be synchronized: \(error.localizedDescription)" }
            }
        case let (.profileOrganization(value), .profileOrganization):
            try profiles.restoreOrganizationHistoryState(value)
        case let (.referenceCorrection(value), .referenceCorrection(id)):
            _ = try historyProfile(id)
            referenceCorrectionSessions[id] = ReferenceCorrectionSession(draft: value)
        case let (.speakerSystem(value), .speakerSystem(id)):
            _ = try historyProfile(id)
            speakerEditSessions[id] = value
        case let (.referenceTransfer(value), .profile(id)):
            var profile = try historyProfile(id)
            profile.setPersonalReferenceCorrection(value.correction)
            profile.sectionLayout = value.sectionLayout
            profiles.update(profile)
            referenceCorrectionSessions[id] = ReferenceCorrectionSession(draft: value.correction)
            setGlobalEQHistoryDraft(value.globalEQ, for: id)
            applyID = id
        default: throw HistoryRestoreError.invalidStateForTarget
        }
        if let applyID { try await applyHistoryProfileIfActive(applyID) }
    }
}
