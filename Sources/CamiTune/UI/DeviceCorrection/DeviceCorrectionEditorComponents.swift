import CamiTuneDomain
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension DeviceCorrectionEditorView {
    var advancedCorrectionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            boundsRow("Frequency (Hz)", lower: $autoEQSettings.minimumFrequency, upper: $autoEQSettings.maximumFrequency, digits: 0)
            boundsRow("Gain (dB)", lower: $autoEQSettings.minimumGain, upper: $autoEQSettings.maximumGain, digits: 1)
            boundsRow("Q", lower: $autoEQSettings.minimumQ, upper: $autoEQSettings.maximumQ)
            if targetChosen && targetSelection.preset != .deviceMatch && targetSelection.preset != .custom {
                modifierRow("Treble (dB)", value: modifierBinding(\.trebleGainDB))
                modifierRow("Tilt (dB/oct)", value: modifierBinding(\.tiltDBPerOctave))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modifierRow(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 120, alignment: .leading)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...2))).frame(width: 95)
            Spacer()
        }
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    var deviceMatchControls: some View {
        let matchSearchResults = deviceMatchSearchResults

        VStack(alignment: .leading, spacing: 8) {
            if measurement == nil {
                Text("Choose the source device first. CamiTune will only offer target devices with compatible structured measurement rigs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                AutoEQSearchField(placeholder: "Search target earphones", query: $deviceMatchSearchText,
                    results: selectedDeviceMatchCatalogID == nil ? matchSearchResults : [],
                    title: { $0.displayName }, onSelect: selectDeviceMatch)

                if isLoadingDeviceMatch {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Combining target-device measurements…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let metadata = targetSelection.deviceMatchTarget,
                          let consensus = deviceMatchConsensus {
                    let evidenceCount = Set(consensus.sources.map {
                        $0.laboratoryCorrelationKey
                    }).count
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(metadata.deviceName)
                                .font(.headline)
                            Text("\(consensus.response.points.count) points · \(evidenceCount) independent lab group\(evidenceCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { refreshDeviceMatch() } label: {
                            Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isLoadingDeviceMatch)
                        .accessibilityLabel("Refresh target device measurements")
                    }
                } else if !DeviceNameNormalizer.key(for: deviceMatchSearchText).isEmpty,
                          matchSearchResults.isEmpty {
                    Text("No compatible target measurements were found for this source fixture and configuration type.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var targetImportControls: some View {
        HStack(spacing: 6) {
            Button("Import…") { showingTargetImporter = true }
                .fixedSize()
                .disabled(measurement == nil)
                .accessibilityLabel("Import target")
            DeviceCorrectionHelpIcon(title: "Available targets", message: targetHelpMessage)
        }
    }

    @ViewBuilder
    func responseRow(
        title: String? = nil,
        response: FrequencyResponse?,
        emptyText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title).font(.headline)
            }
            if let response {
                Text("\(response.name) · \(response.points.count) points")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    func generatedEqualizerValues(_ profile: DeviceCorrectionProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Equalizer values")
                    .font(.headline)
                Spacer()
                Button { replaceFilters((generated?.filters ?? []) + [EQBand(kind: .peaking, frequency: 1_000, gain: 0, q: 0.707)]) } label: {
                    Image(systemName: "plus")
                }.disabled((generated?.filters.count ?? 0) >= 20).accessibilityLabel("Add band")
            }
            Text("Automatic headroom \(generatedAutomaticHeadroomDB, format: .number.precision(.fractionLength(2))) dB")
                .font(.caption.monospacedDigit().weight(.medium))

            if embedded {
                OverflowAwareHorizontalScrollView { correctionFilterTable }
            } else {
                correctionFilterTable
            }

            DisclosureGroup("Details", isExpanded: $presentation.detailsExpanded) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Target")
                        Text(profile.targetSelection.preset == .neutral
                            ? DeviceCorrectionTargetCatalog().displayName(for: .neutral, sources: profile.sources)
                            : profile.target.name)
                    }
                    GridRow { Text("Domain"); Text(profile.sources.first?.resolvedRigIdentity.stableKey ?? "Unknown") }
                    GridRow { Text("Sources"); Text(profile.sources.map(\.sourceName).joined(separator: ", ")) }
                    GridRow { Text("Engine / registry"); Text("\(profile.correctionEngineVersion) / \(profile.targetRegistryVersion)") }
                    GridRow { Text("Frequency"); Text("\(Int(profile.autoEQSettings.minimumFrequency))–\(Int(profile.autoEQSettings.maximumFrequency)) Hz") }
                    GridRow { Text("Gain"); Text("\(profile.autoEQSettings.minimumGain.formatted())–\(profile.autoEQSettings.maximumGain.formatted()) dB") }
                    GridRow { Text("Q"); Text("\(profile.autoEQSettings.minimumQ.formatted())–\(profile.autoEQSettings.maximumQ.formatted())") }
                    if profile.policy == .recommended {
                        GridRow { Text("Treble Q"); Text("≤ \(max(profile.autoEQSettings.minimumQ, min(2, profile.autoEQSettings.maximumQ)).formatted()) above 6 kHz") }
                    }
                    GridRow { Text("Combined boost ceiling"); Text("6 dB; locked filters preserved") }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
    }

    private var correctionFilterTable: some View {
        CorrectionFilterTable(filters: Binding(get: { generated?.filters ?? [] }, set: { filters in
            replaceFilters(filters)
        }), selectedBandID: $selectedBandID)
    }

    func boundsRow(_ title: String, lower: Binding<Double>, upper: Binding<Double>, digits: Int = 2) -> some View {
        AutoEQBoundsRow(title: title, lower: lower, upper: upper, digits: digits)
    }

    func editBand(_ band: EQBand) {
        guard var filters = generated?.filters, let index = filters.firstIndex(where: { $0.id == band.id }) else { return }
        filters[index] = band
        replaceFilters(filters)
    }

    func replaceFilters(_ filters: [EQBand]) {
        generated?.filters = filters
    }

    func filterLabel(_ kind: EQBand.Kind) -> String {
        switch kind {
        case .peaking: return "PK"
        case .lowShelf: return "LS"
        case .highShelf: return "HS"
        case .lowPass: return "LP"
        case .highPass: return "HP"
        case .notch: return "NO"
        case .allPass: return "AP"
        }
    }

}

/// Shared Auto EQ controls keep personal and speaker workflows visually aligned.
@MainActor
struct AutoEQSearchField<Entry: Identifiable>: View {
    let placeholder: String
    @Binding var query: String
    let results: [Entry]
    let title: (Entry) -> String
    let onSelect: @MainActor (Entry) -> Void
    @FocusState private var isFocused: Bool
    @State private var showsResults = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(placeholder, text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onExitCommand { dismissResults() }
            // A result click can clear text focus on mouse-down. Keep the rows
            // alive until the button's mouse-up action selects and dismisses them.
            if showsResults, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !results.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results) { entry in
                            Button {
                                onSelect(entry)
                                dismissResults()
                            } label: {
                                Text(title(entry))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                            }.buttonStyle(.plain)
                                .uiInteractionAnchor("autoeq-search-result-\(entry.id)")
                        }
                    }
                }.frame(maxHeight: 170)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .onChange(of: isFocused) { focused in
            if focused { showsResults = true }
        }
        .background(OutsideClickObserver(textFieldFocused: isFocused) { dismissResults() })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in dismissResults() }
    }

    private func dismissResults() {
        showsResults = false
        isFocused = false
    }
}

struct AutoEQBoundsRow: View {
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    let title: String
    @Binding var lower: Double
    @Binding var upper: Double
    var digits = 2
    private var fields: some View {
        HStack {
            TextField("Minimum", value: $lower, format: .number.precision(.fractionLength(0...digits))).frame(width: 95 * scale)
            Text("–").foregroundStyle(.secondary)
            TextField("Maximum", value: $upper, format: .number.precision(.fractionLength(0...digits))).frame(width: 95 * scale)
            Spacer()
        }
    }
    var body: some View {
        ResponsiveStackLayout(minimumHorizontalWidth: 360 * scale,
            horizontalSpacing: 8, verticalSpacing: 4) {
            Text(title).frame(width: 120 * scale, alignment: .leading)
            fields
        }.textFieldStyle(.roundedBorder)
    }
}

@MainActor
struct AutoEQGenerateButton: View {
    let isGenerating: Bool
    var title = "Auto EQ"
    let action: @MainActor () -> Void
    var body: some View {
        Button { action() } label: {
            Text(title)
                .opacity(isGenerating ? 0 : 1)
                .overlay {
                    if isGenerating { ProgressView().controlSize(.small) }
                }
        }.buttonStyle(.borderedProminent)
    }
}

@MainActor
struct EditorHistoryCommands<Snapshot: Equatable>: ViewModifier {
    @ObservedObject var history: EditorSnapshotHistory<Snapshot>
    var isExclusive = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.undoCommandRouter) private var router

    func body(content: Content) -> some View {
        content.background(EditorHistoryRegistration(manager: history.manager, revision: history.revision,
            isEnabled: isEnabled && !history.isEditing, isExclusive: isExclusive, router: router))
    }
}

/// The main window uses NSHostingController, not a SwiftUI Window scene.
/// Register against its actual NSWindow so graph gestures need no text focus.
@MainActor
private struct EditorHistoryRegistration: NSViewRepresentable {
    let manager: UndoManager
    let revision: Int
    let isEnabled: Bool
    let isExclusive: Bool
    let router: UndoCommandRouter?

    func makeNSView(context: Context) -> EditorHistoryCommandView { EditorHistoryCommandView() }
    func updateNSView(_ view: EditorHistoryCommandView, context: Context) {
        view.configure(manager: manager, revision: revision, isEnabled: isEnabled, isExclusive: isExclusive, router: router)
    }
    static func dismantleNSView(_ view: EditorHistoryCommandView, coordinator: ()) {
        view.router?.unregister(view)
    }
}

@MainActor
final class EditorHistoryCommandView: NSView {
    private(set) var manager: UndoManager?
    private(set) weak var router: UndoCommandRouter?
    private var revision: Int?
    private var commandsEnabled = false
    private(set) var isExclusive = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(manager: UndoManager, revision: Int, isEnabled: Bool, isExclusive: Bool, router: UndoCommandRouter?) {
        let changed = self.revision != nil && self.revision != revision
        if self.router !== router {
            self.router?.unregister(self)
            self.router = router
            router?.register(self)
        }
        self.manager = manager
        self.revision = revision
        commandsEnabled = isEnabled
        self.isExclusive = isExclusive
        if changed { router?.editorDidChange(self) }
        router?.refreshCommands()
    }

    func isAvailable(in window: NSWindow?) -> Bool {
        commandsEnabled && isInWindow(window)
    }

    func isInWindow(_ window: NSWindow?) -> Bool {
        window != nil && self.window === window && !isHiddenOrHasHiddenAncestor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        router?.refreshCommands()
    }
}

@MainActor
struct AutoEQSaveTXTButton: View {
    let correction: DeviceCorrectionProfile?
    let onError: (String) -> Void
    @State private var isSaving = false
    var body: some View {
        Button("Save Equalizer APO…") {
            guard let correction else { return }
            let text = EqualizerAPOSerializer().serialize(.init(preampDB: 0, bands: correction.filters))
            isSaving = true
            Task { @MainActor in
                defer { isSaving = false }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.plainText]
                panel.allowsOtherFileTypes = false
                panel.canCreateDirectories = true
                let name = correction.deviceName.components(separatedBy: CharacterSet(charactersIn: "/:\n\r")).joined(separator: "-")
                panel.nameFieldStringValue = "\(name.isEmpty ? "AutoEQ" : name)-AutoEQ.txt"
                guard await panel.begin() == .OK, let url = panel.url else { return }
                do { try text.write(to: url, atomically: true, encoding: .utf8) }
                catch { onError("Could not save Equalizer APO text: \(error.localizedDescription)") }
            }
        }
        .disabled(correction == nil || isSaving)
    }
}

@MainActor
struct AutoEQLoadButton: View {
    let isLoaded: Bool
    var showsStatus = true
    var draftLabel = "Draft"
    let action: @MainActor () -> Void
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button("Load into Equalizer") { action() }.buttonStyle(.borderedProminent).tint(.blue)
            if showsStatus {
                Text(isLoaded ? "Loaded" : draftLabel).font(.caption2)
                    .foregroundStyle(isLoaded ? Color.green : Color.secondary)
                    .fixedSize().frame(height: 12)
            }
        }
    }
}

struct AutoEQResultCard<Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                content().padding(.top, 8)
            } label: { Text("Graph & Equalizer Values").font(.headline) }
            .padding(6)
        }
        .disclosureGroupStyle(SectionDisclosureStyle())
    }
}
