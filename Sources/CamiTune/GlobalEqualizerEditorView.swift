import CamiTuneDomain
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct GlobalEqualizerEditorView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    let graphModel: ProfileEditorGraphModel
    var presentation: EqualizerPresentation = .both
    var needsResponseGraph = true
    var onPresentationChanged: (EqualizerPresentation) -> Void = { _ in }

    @State var parsedForGraph = ParsedEQ()
    @State var filterResponsePoints: [EQResponsePoint] = []
    @State var preampDB = 0.0
    @State var limiterEnabled = false
    @State var automaticSystemHeadroomDB = 0.0
    @State var graphicBands: [EQBand] = []
    @State var pendingBandCount: Int?
    @State var showBandReductionConfirmation = false
    @State var showTextImporter = false
    @State var simpleTone = SimpleToneSettings()
    @StateObject var runtime = GlobalEQEditorRuntime()
    @StateObject var bandReduction = UIBackgroundOperation<[EQBand]>()

    var profileIsActive: Bool {
        state.isActive && state.activeProfileID == profile.id
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Equalizer").font(.title3.bold())
                    if bandReduction.isRunning { ProgressView("Fitting bands…").controlSize(.small) }
                    Spacer()
                    Button("Import .txt") { showTextImporter = true }
                    Button("Reset") { resetEqualizer() }
                        .buttonStyle(.bordered)
                        .disabled(!canResetEqualizer)
                        .help(presentation.resetTitle)
                }
                JoinedSegmentedControl(
                    options: EqualizerPresentation.allCases,
                    selection: Binding(get: { presentation }, set: onPresentationChanged),
                    title: { $0.title }
                )
                .accessibilityLabel("Equalizer controls")
                .frame(width: 260)
                if let legacy = profile.processing.deviceCorrection, !state.eqDraftReplacesDeviceCorrection(for: profile.id) {
                    HStack {
                        Text("Legacy global correction: \(legacy.deviceName)").font(.caption).foregroundStyle(.secondary)
                        Button("Edit as User EQ") { editLegacyCorrection() }
                    }
                }
                Text("Imports ON/OFF PK/PEQ, LS/LSC, HS/HSC, LP/LPQ, HP/HPQ, NO, and AP filters using Q, BW Oct, or 6/12 dB shelf slopes. APO Preamp is ignored; use User Preamp instead. Other valid APO commands are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PreampGainControl(
                    gainDB: $preampDB,
                    limiterEnabled: $limiterEnabled,
                    meters: state.meters,
                    profileID: profile.id,
                    onEditingChanged: continuousEditingChanged
                )
                Text("Automatic system headroom: \(automaticSystemHeadroomDB, format: .number.precision(.fractionLength(2))) dB")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if presentation != .simpleTone {
                    HStack(spacing: 8) {
                        Text("Bands")
                        Picker("Bands", selection: Binding(
                            get: { graphicBands.count },
                            set: { setBandCount($0) }
                        )) {
                            ForEach(1...20, id: \.self) { count in
                                Text("\(count)").tag(count)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 64)
                    }
                }

                if !graphicBands.isEmpty || presentation != .bands {
                    if presentation != .simpleTone {
                    let columnWidth = 96.0
                    let contentWidth = GraphicEqualizerBands.requiredContentWidth(
                        bandCount: graphicBands.count,
                        columnWidth: columnWidth
                    )
                    OverflowAwareHorizontalScrollView(
                        contentWidth: contentWidth,
                        height: 402
                    ) {
                        GraphicEqualizerBands(
                            bands: $graphicBands,
                            spectrum: state.spectrum,
                            profileID: profile.id,
                            responsePoints: filterResponsePoints,
                            setKind: EQEditorSupport.setKind,
                            columnWidth: columnWidth,
                            onGainEditingChanged: continuousEditingChanged
                        )
                    }

                    }
                    if presentation == .both { Divider() }
                    if presentation != .bands {
                    SimpleEQControlsView(
                        settings: $simpleTone,
                        onEditingChanged: continuousEditingChanged
                    )
                    }
                } else {
                    Text("Choose a band count above.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 90)
                }
            }
            .padding(6)
        }
        .onChange(of: state.historyReplayRevision) { _ in loadGraphicEQ() }
        .onAppear { loadGraphicEQIfNeeded() }
        .onDisappear {
            bandReduction.cancel()
            if runtime.continuousEditDepth > 0 {
                runtime.continuousEditDepth = 1
                continuousEditingChanged(false)
            }
        }
        .onChange(of: needsResponseGraph) { _ in updateGraphResponses() }
        .onChange(of: presentation) { _ in updateGraphResponses() }
        .onChange(of: profile.id) { _ in
            loadGraphicEQIfNeeded()
        }
        .onChange(of: preampDB) { _ in editorValuesChanged() }
        .onChange(of: limiterEnabled) { _ in editorValuesChanged() }
        .onChange(of: graphicBands) { _ in editorValuesChanged() }
        .onChange(of: simpleTone) { _ in editorValuesChanged() }
        .onChange(of: profile.sampleRate) { _ in bandReduction.cancel(); updateGraphResponses() }
        .onChange(of: profile.processing) { _ in updateAutomaticSystemHeadroom() }
        .onReceive(state.equalizerReplacementChanges.filter { $0 == profile.id }) { _ in
            if let latest = state.profiles.profiles.first(where: { $0.id == profile.id }) { profile = latest }
            loadGraphicEQ()
        }
        .disabled(state.isSavingProfileSettings || bandReduction.isRunning)
        .onReceive(state.eqDraftChanges.filter { $0 == profile.id }) { _ in
            updateAutomaticSystemHeadroom()
        }
        .fileImporter(
            isPresented: $showTextImporter,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                Task { @MainActor in
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let text = try await Task.detached(priority: .userInitiated) {
                            try String(contentsOf: url, encoding: .utf8)
                        }.value
                        try importAPOText(text)
                    } catch {
                        state.errorMessage = "Could not import Equalizer APO text: \(error.localizedDescription)"
                    }
                }
            } catch {
                state.errorMessage = "Could not import Equalizer APO text: \(error.localizedDescription)"
            }
        }
        .alert("Recalculate Equalizer Bands?", isPresented: $showBandReductionConfirmation) {
            Button("Cancel", role: .cancel) { pendingBandCount = nil }
            Button("Recalculate", role: .destructive) { applyPendingBandReduction() }
        } message: {
            Text(bandReductionConfirmationMessage)
        }
    }

}

/// Device correction owns generation; the separate Equalizer owns the applied controls.
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
            DeviceCorrectionSectionHeader(title: "Auto EQ",
                hint: "Generate correction for all channels from device measurements and a target response. Load into Equalizer to apply it. Equalizer changes are saved automatically.")
            if let correction = equalizerState?.deviceCorrectionProvenance {
                Text(correction.deviceName).font(.headline)
            }
            if let message = draftStore.errorMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            if draftLoaded {
                DeviceCorrectionEditorView(
                    existing: state.deviceCorrectionProvenance(for: profile.id,
                        persisted: profile.processing.globalEqualizerProvenance),
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
                    shouldConfirmReplacement: {
                        guard let current = try? state.globalEQHistoryState(for: profile) else { return true }
                        return ParsedEQ(preampDB: current.preampDB, bands: current.bands).hasMeaningfulProcessing
                    },
                    onCancel: {},
                    onLoad: loadCorrection
                )
                .id(profile.id)
            }
        }
        .disabled(state.isSavingProfileSettings || state.history.isReplaying)
        .onAppear {
            reload()
            if !draftLoaded {
                initialDraft = draftStore.load()
                draftLoaded = true
            }
        }
        .onChange(of: profile.id) { _ in reload() }
        .onChange(of: profile.processing) { _ in reload() }
        .onChange(of: state.historyReplayRevision) { _ in reload() }
        .onReceive(state.eqDraftChanges.filter { $0 == profile.id }) { _ in reload() }
    }

    private func reload() {
        equalizerState = try? state.globalEQHistoryState(for: profile)
    }

    private func loadCorrection(_ correction: DeviceCorrectionProfile) -> Bool {
        do {
            try state.loadAutoEQCorrectionDraft(correction, for: profile)
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
