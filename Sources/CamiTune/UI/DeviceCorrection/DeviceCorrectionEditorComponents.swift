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
                        Button("Refresh") { refreshDeviceMatch() }
                            .disabled(isLoadingDeviceMatch)
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

    @ViewBuilder
    func responseRow(
        title: String? = nil,
        response: FrequencyResponse?,
        emptyText: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
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
            Spacer()
            Button(buttonTitle, action: action)
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
                }.disabled((generated?.filters.count ?? 0) >= 20).help("Add band")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(placeholder, text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onExitCommand { isFocused = false }
            if isFocused, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !results.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results) { entry in
                            Button {
                                onSelect(entry)
                                isFocused = false
                            } label: {
                                Text(title(entry))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 170)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .background(OutsideClickObserver { isFocused = false })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in isFocused = false }
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
struct AutoEQUndoButton<Snapshot: Equatable>: View {
    @ObservedObject var history: AutoEQEditorHistory<Snapshot>
    var isRedo = false
    var body: some View {
        Button {
            if isRedo { history.manager.redo() } else { history.manager.undo() }
        } label: {
            Image(systemName: isRedo ? "arrow.uturn.forward" : "arrow.uturn.backward")
        }
        .disabled(isRedo ? !history.manager.canRedo : !history.manager.canUndo)
        .help(isRedo ? "Redo Auto EQ edit" : "Undo Auto EQ edit")
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
        .help("Save Equalizer APO filters as a .txt file in a location you choose.")
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
