import CamiTuneDomain
import SwiftUI
import Combine

/// Auto EQ loads generated bands through the existing Equalizer workflow.
@MainActor
struct AutoEQCorrectionView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    @StateObject private var draftStore: AutoEQDraftStore
    @State private var initialDraft: AutoEQEditorDraft?
    @State private var draftLoaded = false
    @State private var equalizerState: GlobalEQHistoryState?

    init(state: AppState, profile: Binding<DeviceProfile>) {
        self.state = state
        _profile = profile
        _draftStore = StateObject(wrappedValue: AutoEQDraftStore(url: AutoEQDraftStore.url(
            profileID: profile.wrappedValue.id, endpoint: profile.wrappedValue.effectiveEndpointKind)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Auto EQ").font(.title3.bold())
            if draftLoaded {
                DeviceCorrectionEditorView(
                    existing: personalCorrection,
                    embedded: true,
                    initialDraft: initialDraft,
                    equalizerState: equalizerState,
                    onPersistDraft: { draft, flush in
                        draftStore.save(draft)
                        if flush { draftStore.flush() }
                    },
                    sampleRate: Double(profile.sampleRate),
                    referenceEndpoint: profile.effectiveEndpointKind,
                    automaticHeadroom: automaticHeadroomForCorrection,
                    shouldConfirmReplacement: { false },
                    onCancel: {},
                    onLoad: loadCorrection
                )
                .id(profile.id)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            }
            if let error = draftStore.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .disabled(state.isSavingProfileSettings || state.history.isReplaying)
        .task {
            reload()
            if !draftLoaded {
                let saved = await draftStore.loadWithoutBlockingUI()
                guard !Task.isCancelled else { return }
                initialDraft = saved
                draftLoaded = true
            }
        }
        .onChange(of: profile.id) { _ in reload() }
        .onChange(of: profile.processing) { _ in reload() }
        .onChange(of: state.historyReplayRevision) { _ in reload() }
        .onReceive(state.eqDraftChanges.filter { $0 == profile.id }) { _ in reload() }
    }

    private var personalCorrection: DeviceCorrectionProfile? {
        let correction = equalizerState?.deviceCorrectionProvenance ?? profile.processing.deviceCorrection
        return correction?.speakerProvenance == nil ? correction : nil
    }

    private func reload() {
        equalizerState = try? state.globalEQHistoryState(for: profile)
    }

    private func loadCorrection(_ correction: DeviceCorrectionProfile) -> Bool {
        do {
            try state.loadAutoEQCorrectionDraft(correction, for: profile)
            if let latest = state.profiles.profiles.first(where: { $0.id == profile.id }) { profile = latest }
            var layout = state.profiles.effectiveLayout(for: profile)
            layout.hidden.remove(.equalizer)
            if layout.equalizer == .simpleTone { layout.equalizer = .both }
            profile.sectionLayout = layout
            state.equalizerReplacementChanges.send(profile.id)
            reload()
            let profileID = profile.id
            let generation = state.editGeneration
            Task {
                guard generation == state.editGeneration else { return }
                do { try await state.applyHistoryProfileIfActive(profileID) }
                catch { state.errorMessage = error.localizedDescription }
            }
            return true
        } catch {
            state.errorMessage = error.localizedDescription
            return false
        }
    }

    func automaticHeadroomForCorrection(_ filters: [EQBand]) async -> Double {
        do {
            var candidate = profile
            candidate = try state.applyingSessionEQDrafts(to: candidate)
            candidate.processing.setDeviceCorrection(nil)
            candidate.setGlobalEqualizer(preampDB: 0, bands: filters)
            let snapshot = candidate
            return await Task.detached(priority: .utility) {
                do {
                    let assets = try PreparedRuntimeAssets.prepare(profile: snapshot, directory: CamiTunePaths.impulseResponsesDirectory)
                    return try ProcessingGraphBuilder(channelCount: snapshot.processingChannelCount, preparedAssets: assets)
                        .build(profile: snapshot).automaticHeadroomDB
                } catch { return 0 }
            }.value
        } catch {
            return 0
        }
    }

}
