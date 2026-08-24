import SwiftUI

@MainActor
extension DeviceCorrectionEditorView {
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
                Text("Automatic headroom \(generatedAutomaticHeadroomDB, format: .number.precision(.fractionLength(2))) dB")
                    .font(.caption.monospacedDigit().weight(.medium))
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                GridRow {
                    Text("Filter")
                    Text("Type")
                    Text("Frequency")
                    Text("Gain")
                    Text("Q")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(profile.filters.indices, id: \.self) { index in
                    let band = profile.filters[index]
                    GridRow {
                        Text("\(index + 1)")
                        Text(filterLabel(band.kind))
                        Text("\(band.frequency, format: .number.precision(.fractionLength(0...1))) Hz")
                        Text("\(band.gain ?? 0, format: .number.precision(.fractionLength(1))) dB")
                        Text("\(band.q ?? 0.707, format: .number.precision(.fractionLength(2)))")
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
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
