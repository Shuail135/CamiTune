import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct GlobalEqualizerEditorView: View {
    let state: AppState
    @Binding var profile: DeviceProfile
    let graphModel: ProfileEditorGraphModel

    @State var parsedForGraph = ParsedEQ()
    @State var filterResponsePoints: [EQResponsePoint] = []
    @State var preampDB = 0.0
    @State var limiterEnabled = false
    @State var automaticSystemHeadroomDB = 0.0
    @State var graphicBands: [EQBand] = []
    @State var pendingBandCount: Int?
    @State var showBandReductionConfirmation = false
    @State var showTextImporter = false
    @State var showDeviceCorrectionEditor = false
    @State var eqIsSaved = true
    @StateObject var runtime = GlobalEQEditorRuntime()

    var profileIsActive: Bool {
        state.isActive && state.activeProfileID == profile.id
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Equalizer").font(.title3.bold())
                    Text(eqIsSaved ? "Saved" : "Not saved")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(eqIsSaved ? Color.green : Color.secondary)
                    Spacer()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            Button("Device Correction…") {
                                showDeviceCorrectionEditor = true
                            }
                            Button("Import .txt") { showTextImporter = true }
                            Button("Paste APO Text") { importFromClipboard() }
                        }
                        Menu("Actions") {
                            Button("Device Correction…") {
                                showDeviceCorrectionEditor = true
                            }
                            Button("Import .txt") { showTextImporter = true }
                            Button("Paste APO Text") { importFromClipboard() }
                        }
                    }
                    Button { saveGraphicEQ() } label: {
                        Text("Save")
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 5)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                Text("Imports ON/OFF PK/PEQ, LS/LSC, HS/HSC, LP/LPQ, HP/HPQ, NO, and AP filters using Q, BW Oct, or 6/12 dB shelf slopes. APO Preamp is ignored; use User Preamp instead. Other valid APO commands are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                if !graphicBands.isEmpty {
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

                    Divider()
                    SimpleEQControlsView(
                        bands: $graphicBands,
                        onEditingChanged: continuousEditingChanged
                    )
                } else {
                    Text("Choose a band count above.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 90)
                }
            }
            .padding(6)
        }
        .onAppear { loadGraphicEQIfNeeded() }
        .onChange(of: profile.id) { _ in
            runtime.loadedProfileID = nil
            loadGraphicEQIfNeeded()
        }
        .onChange(of: preampDB) { _ in graphicEQChanged() }
        .onChange(of: limiterEnabled) { _ in graphicEQChanged() }
        .onChange(of: graphicBands) { _ in graphicEQChanged() }
        .onChange(of: profile.sampleRate) { _ in updateGraphResponses() }
        .onChange(of: profile.processing) { _ in updateAutomaticSystemHeadroom() }
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
        .sheet(isPresented: $showDeviceCorrectionEditor) {
            DeviceCorrectionEditorView(
                existing: currentDeviceCorrectionProvenance,
                sampleRate: Double(profile.sampleRate),
                automaticHeadroom: automaticHeadroomForCorrection,
                shouldConfirmReplacement: {
                    EQEditorSupport.hasMeaningfulProcessing(ParsedEQ(
                        preampDB: preampDB,
                        bands: graphicBands,
                        warnings: []
                    ))
                },
                onCancel: { showDeviceCorrectionEditor = false },
                onLoad: loadDeviceCorrectionEQ
            )
        }
    }

}
