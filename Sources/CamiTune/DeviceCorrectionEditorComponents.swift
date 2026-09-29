import CamiTuneDomain
import SwiftUI

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
                TextField("Search target earphones", text: $deviceMatchSearchText)
                    .textFieldStyle(.roundedBorder)

                if !DeviceNameNormalizer.key(for: deviceMatchSearchText).isEmpty,
                   selectedDeviceMatchCatalogID == nil,
                   !matchSearchResults.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(matchSearchResults) { entry in
                                Button {
                                    selectDeviceMatch(entry)
                                } label: {
                                    Text(entry.displayName)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                    .background(
                        Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                }

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
        title: String,
        response: FrequencyResponse?,
        emptyText: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
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
                ScrollView(.horizontal) { correctionFilterTable }
                    .fixedSize(horizontal: false, vertical: true)
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
            }

        }
    }

    private var correctionFilterTable: some View {
        CorrectionFilterTable(filters: Binding(get: { generated?.filters ?? [] }, set: { filters in
            replaceFilters(filters)
        }), selectedBandID: $selectedBandID)
    }

    func boundsRow(_ title: String, lower: Binding<Double>, upper: Binding<Double>, digits: Int = 2) -> some View {
        let fields = HStack {
            TextField("Minimum", value: lower, format: .number.precision(.fractionLength(0...digits))).frame(width: 95)
            Text("–").foregroundStyle(.secondary)
            TextField("Maximum", value: upper, format: .number.precision(.fractionLength(0...digits))).frame(width: 95)
            Spacer()
        }
        return ViewThatFits(in: .horizontal) {
            HStack {
                Text(title).frame(width: 120, alignment: .leading)
                fields
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                fields
            }
        }
        .textFieldStyle(.roundedBorder)
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
