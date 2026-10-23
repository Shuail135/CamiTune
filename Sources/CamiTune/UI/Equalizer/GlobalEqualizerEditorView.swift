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
    @State var preampDB = 0.0
    @State var limiterEnabled = false
    @State var graphicBands: [EQBand] = []
    @State var pendingBandCount: Int?
    @State var showBandReductionConfirmation = false
    @State var pendingReset: EqualizerReset.Request?
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
                    HStack(spacing: 6) {
                        Button("Import .txt") { showTextImporter = true }
                        DeviceCorrectionHelpIcon(title: "Equalizer import",
                            message: "Imports ON/OFF PK/PEQ, LS/LSC, HS/HSC, LP/LPQ, HP/HPQ, NO, and AP filters using Q, BW Oct, or 6/12 dB shelf slopes. APO Preamp is ignored; use User Preamp instead. Other valid APO commands are skipped.")
                    }
                    SectionResetButton(presentation.resetTitle) { requestEqualizerReset() }
                        .disabled(!canResetEqualizer)
                }
                PreampGainControl(
                    gainDB: $preampDB,
                    limiterEnabled: $limiterEnabled,
                    meters: state.meters,
                    profileID: profile.id,
                    onEditingChanged: continuousEditingChanged
                )
                JoinedSegmentedControl(
                    options: EqualizerPresentation.allCases,
                    selection: Binding(get: { presentation }, set: onPresentationChanged),
                    title: { $0.title }
                )
                .accessibilityLabel("Equalizer controls")
                .frame(width: 260)
                AutomaticGlobalHeadroomView(state: state, profile: profile)

                if presentation != .simpleTone {
                    HStack(spacing: 8) {
                        Text("Bands")
                        Picker("Bands", selection: Binding(
                            get: { graphicBands.count },
                            set: { setBandCount($0) }
                        )) {
                            if graphicBands.isEmpty { Text("—").tag(0) }
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
                    EqualizerBandScrollView(bandCount: graphicBands.count) { columnWidth in
                        GlobalEqualizerBandStrip(
                            bands: $graphicBands,
                            spectrum: state.spectrum,
                            profileID: profile.id,
                            graphModel: graphModel,
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
                    Label("Choose a band count above.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 90)
                }
            }
            .padding(6)
        }
        .onChange(of: state.historyReplayRevision) { _ in loadGraphicEQ() }
        .onAppear { loadGraphicEQIfNeeded() }
        .onDisappear {
            pendingReset = nil
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
        .onReceive(state.equalizerReplacementChanges.filter { $0 == profile.id }) { _ in
            loadGraphicEQ()
        }
        .disabled(state.isSavingProfileSettings || bandReduction.isRunning)
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
        .alert("Reset Equalizer?", isPresented: Binding(
            get: { pendingReset != nil },
            set: { if !$0 { pendingReset = nil } }
        ), presenting: pendingReset) { request in
            Button(request.presentation == .simpleTone ? "Reset Simple Only" : "Reset Bands Only", role: .destructive) {
                resetEqualizer(request, presentation: request.presentation)
            }
            Button("Reset Both", role: .destructive) {
                resetEqualizer(request, presentation: .both)
            }
            Button("Cancel", role: .cancel) { pendingReset = nil }
        } message: { request in
            Text("Simple and Bands both have changes. Reset only \(request.presentation.title), or both? User Preamp will reset to 0 dB either way.")
        }
    }

}

/// Both equalizers display the headroom of the complete processing graph,
/// including global, group, and channel drafts, regardless of the selected channel.
@MainActor
struct AutomaticGlobalHeadroomView: View {
    let state: AppState
    let profile: DeviceProfile
    @State private var headroomDB = 0.0
    @State private var draftRevision = 0

    private struct Request: Hashable {
        let profile: DeviceProfile
        let draftRevision: Int
    }

    var body: some View {
        Text("Automatic Global Headroom: \(headroomDB, format: .number.precision(.fractionLength(2))) dB")
            .font(.caption.monospacedDigit().weight(.medium))
            .onReceive(state.eqDraftChanges.filter { $0 == profile.id }) { _ in
                draftRevision &+= 1
            }
            .task(id: Request(profile: profile, draftRevision: draftRevision)) {
                do {
                    try await Task.sleep(for: .milliseconds(120))
                    let candidate = try state.applyingSessionEQDrafts(to: profile)
                    let headroom = await Task.detached(priority: .utility) {
                        do {
                            let assets = try PreparedRuntimeAssets.prepare(profile: candidate,
                                directory: CamiTunePaths.impulseResponsesDirectory)
                            return try ProcessingGraphBuilder(channelCount: candidate.processingChannelCount,
                                preparedAssets: assets).build(profile: candidate).automaticHeadroomDB
                        } catch { return 0.0 }
                    }.value
                    guard !Task.isCancelled else { return }
                    headroomDB = headroom
                } catch {
                    guard !Task.isCancelled else { return }
                    headroomDB = 0
                }
            }
    }
}
