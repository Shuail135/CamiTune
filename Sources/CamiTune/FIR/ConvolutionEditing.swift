import CamiTuneDomain
import Foundation

@MainActor
extension AppState {
    func convolutionHistoryState(for target: HistoryTarget) throws -> ConvolutionHistoryState {
        let stage: (isEnabled: Bool, processor: ConvolutionProcessor)?
        switch target {
        case .profile(let id): stage = try historyProfile(id).resolvedProcessing().convolution
        case .profileChannel(let id, let index):
            let profile = try historyProfile(id)
            guard profile.configuredProcessingChannels.contains(where: { $0.index == index }) else {
                throw HistoryRestoreError.invalidStateForTarget
            }
            stage = try profile.resolvedProcessing().convolution(forChannel: index)
        case .profileGroup(let id, let group):
            let profile = try historyProfile(id)
            guard profile.configuredSpeakerGroups.contains(where: { $0.id == group }) else {
                throw HistoryRestoreError.invalidStateForTarget
            }
            stage = try profile.resolvedProcessing().convolution(forGroup: group)
        default: throw HistoryRestoreError.invalidStateForTarget
        }
        return .init(processor: stage?.processor, isEnabled: stage?.isEnabled ?? false)
    }

    @discardableResult
    func storeConvolution(_ value: ConvolutionHistoryState, target: HistoryTarget) throws -> UUID {
        // Validate the target again after asynchronous file imports or history replay.
        _ = try convolutionHistoryState(for: target)
        switch target {
        case .profile(let id):
            try mutateSavedProcessing(profileID: id) { $0.setConvolution(value.processor, enabled: value.isEnabled) }
            return id
        case .profileChannel(let id, let index):
            let profile = try historyProfile(id)
            let channel = profile.configuredProcessingChannels.first { $0.index == index }!
            try mutateSavedProcessing(profileID: id) {
                if !$0.channels.contains(where: { $0.index == index }) {
                    $0.channels.append(ChannelProcessing(index: index, role: channel.role))
                    $0.channels.sort { $0.index < $1.index }
                }
                $0.setConvolution(value.processor, enabled: value.isEnabled, forChannel: index)
            }
            return id
        case .profileGroup(let id, let group):
            try mutateSavedProcessing(profileID: id) { $0.setConvolution(value.processor, enabled: value.isEnabled, forGroup: group) }
            return id
        default: throw HistoryRestoreError.invalidStateForTarget
        }
    }

    func commitConvolution(_ value: ConvolutionHistoryState, target: HistoryTarget, name: String) throws {
        let before = try convolutionHistoryState(for: target)
        let id = try storeConvolution(value, target: target)
        history.record(actionName: "Edit \(name) FIR", contextName: try historyProfile(id).name, target: target,
            before: .convolution(before), after: .convolution(value))
        scheduleConvolutionApply(id)
    }

    func assignConvolution(_ asset: ImpulseResponseAsset, assignments: [ImpulseResponseAssignment], profileID: UUID) throws {
        let profile = try historyProfile(profileID)
        let channels = profile.configuredProcessingChannels
        let planner = ImpulseResponseAssignmentPlanner()
        try planner.validate(assignments, asset: asset, channels: channels, sampleRate: profile.sampleRate)
        let before = try Dictionary(uniqueKeysWithValues: assignments.map {
            ($0.outputChannel, try convolutionHistoryState(for: .profileChannel(profileID, $0.outputChannel)))
        })
        try mutateSavedProcessing(profileID: profileID) {
            try planner.apply(assignments, asset: asset, channels: channels, sampleRate: profile.sampleRate, to: &$0)
        }
        let after = try Dictionary(uniqueKeysWithValues: assignments.map {
            ($0.outputChannel, try convolutionHistoryState(for: .profileChannel(profileID, $0.outputChannel)))
        })
        history.record(actionName: "Assign Speaker FIRs", contextName: profile.name, target: .profile(profileID),
            before: .convolutionBatch(before), after: .convolutionBatch(after))
        scheduleConvolutionApply(profileID)
    }

    private func scheduleConvolutionApply(_ id: UUID) {
        markPendingEditorApply(id)
        let generation = editGeneration
        Task {
            guard generation == editGeneration else { return }
            do { try await applyHistoryProfileIfActive(id) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
