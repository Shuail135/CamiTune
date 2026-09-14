import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct DeviceCorrectionEditorView: View {
    let existing: DeviceCorrectionProfile?
    let sampleRate: Double
    let referenceEndpoint: ProfileEndpointKind?
    let automaticHeadroom: @MainActor ([EQBand]) -> Double
    let shouldConfirmReplacement: @MainActor () -> Bool
    let onCancel: @MainActor () -> Void
    let onLoad: @MainActor (DeviceCorrectionProfile) -> Void

    let catalog = DeviceMeasurementCatalog.online
    @StateObject var loadCoordinator = DeviceCorrectionLoadCoordinator()

    @State var deviceName: String
    @State var searchText: String
    @State var policy: DeviceCorrectionPolicyKind
    @State var filterCount: Int
    @State var catalogEntries: [DeviceCatalogEntry] = []
    @State var selectedCatalogID: String?
    @State var sourceMeasurements: [DeviceCorrectionMeasurement] = []
    @State var measurement: FrequencyResponse?
    @State var targetSelection: DeviceCorrectionTargetSelection
    @State var customTarget: FrequencyResponse?
    @State var deviceMatchSearchText: String
    @State var selectedDeviceMatchCatalogID: String?
    @State var deviceMatchConsensus: MeasurementConsensus?
    @State var generated: DeviceCorrectionProfile?
    @State var generatedAutomaticHeadroomDB: Double
    @State var errorMessage: String?
    @State var isLoadingCatalog = false
    @State var isLoadingMeasurements = false
    @State var isLoadingDeviceMatch = false
    @State var isGenerating = false
    @State var showingMeasurementImporter = false
    @State var showingTargetImporter = false
    @State var showingReplacementConfirmation = false

    init(
        existing: DeviceCorrectionProfile?,
        sampleRate: Double,
        referenceEndpoint: ProfileEndpointKind? = nil,
        automaticHeadroom: @escaping @MainActor ([EQBand]) -> Double,
        shouldConfirmReplacement: @escaping @MainActor () -> Bool,
        onCancel: @escaping @MainActor () -> Void,
        onLoad: @escaping @MainActor (DeviceCorrectionProfile) -> Void
    ) {
        self.existing = existing
        self.sampleRate = sampleRate
        self.referenceEndpoint = referenceEndpoint
        self.automaticHeadroom = automaticHeadroom
        self.shouldConfirmReplacement = shouldConfirmReplacement
        self.onCancel = onCancel
        self.onLoad = onLoad
        _deviceName = State(initialValue: existing?.deviceName ?? "")
        _searchText = State(initialValue: existing?.deviceName ?? "")
        _selectedCatalogID = State(initialValue: existing.map {
            $0.deviceIdentity.stableKey
        })
        _policy = State(initialValue: existing?.policy ?? .recommended)
        _filterCount = State(initialValue: min(16, max(3, existing?.filters.count ?? 10)))
        _measurement = State(initialValue: existing?.measurement)
        _targetSelection = State(initialValue: existing?.targetSelection ?? .flat)
        _customTarget = State(initialValue:
            existing?.targetSelection.preset == .custom ? existing?.target : nil
        )
        let matchMetadata = existing?.targetSelection.preset == .deviceMatch
            ? existing?.targetSelection.deviceMatchTarget
            : nil
        _deviceMatchSearchText = State(initialValue: matchMetadata?.deviceName ?? "")
        _selectedDeviceMatchCatalogID = State(
            initialValue: matchMetadata?.deviceIdentity.stableKey
        )
        _deviceMatchConsensus = State(initialValue: matchMetadata.map {
            MeasurementConsensus(
                response: existing?.target ?? .flat(),
                confidence: $0.measurementConfidence,
                sources: $0.sources,
                snapshots: $0.measurementSnapshots
            )
        })
        _generated = State(initialValue: existing)
        _generatedAutomaticHeadroomDB = State(
            initialValue: existing.map { automaticHeadroom($0.filters) } ?? 0
        )
    }

    var body: some View {
        let sourceSearchResults = searchResults

        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Device Correction")
                        .font(.title2.bold())
                    Text("Select one device configuration and combine its compatible measurements.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Device and source data") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Search earphones", text: $searchText)
                                .textFieldStyle(.roundedBorder)

                            if isLoadingCatalog {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading device catalog…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else if !DeviceNameNormalizer.key(for: searchText).isEmpty,
                                      selectedCatalogID == nil,
                                      !sourceSearchResults.isEmpty {
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        ForEach(sourceSearchResults) { entry in
                                            Button {
                                                select(entry)
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

                            if isLoadingMeasurements {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Combining compatible measurements…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else if !sourceMeasurements.isEmpty {
                                let evidenceCount = Set(sourceMeasurements.map {
                                    $0.source.laboratoryCorrelationKey
                                }).count
                                Text("Ready from \(evidenceCount) compatible independent lab group\(evidenceCount == 1 ? "" : "s").")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if sourceMeasurements.isEmpty,
                               let existing,
                               existing.sources.contains(where: { $0.providerID != "local" }) {
                                Button("Refresh Measurements") {
                                    refreshMeasurements(from: existing)
                                }
                                .disabled(isLoadingMeasurements)
                                .help("Download these saved measurement references again without searching for the device.")
                            }

                            responseRow(
                                title: "Measurement",
                                response: measurement,
                                emptyText: "Choose a search result or import your own CSV",
                                buttonTitle: "Import Custom CSV…"
                            ) { showingMeasurementImporter = true }

                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                Picker("Correction target", selection: targetPresetBinding) {
                                    ForEach(DeviceCorrectionTargetPreset.allCases, id: \.self) {
                                        Text($0.title).tag($0)
                                    }
                                }
                                .pickerStyle(.menu)

                                Text(targetSelection.preset.shortDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if targetSelection.preset == .jm1PopAvgDFTilt {
                                    HStack(spacing: 10) {
                                        Text("Tilt")
                                            .font(.caption.weight(.medium))
                                        Slider(value: targetTiltBinding, in: -2...1, step: 0.1)
                                        Text("\(targetSelection.tiltDBPerOctave, format: .number.precision(.fractionLength(1))) dB/oct")
                                            .font(.caption.monospacedDigit())
                                            .frame(width: 92, alignment: .trailing)
                                    }
                                }

                                if targetSelection.preset == .deviceMatch {
                                    deviceMatchControls
                                }

                                Text(targetCompatibilityMessage)
                                    .font(.caption)
                                    .foregroundStyle(targetIsIncompatible ? .orange : .secondary)

                                if targetSelection.preset == .custom {
                                    responseRow(
                                        title: "Custom target",
                                        response: customTarget,
                                        emptyText: "No target CSV imported",
                                        buttonTitle: "Import Custom Target…"
                                    ) { showingTargetImporter = true }
                                    Picker(
                                        "Target CSV fixture",
                                        selection: customTargetRigFamilyBinding
                                    ) {
                                        Text("Choose fixture…")
                                            .tag(DeviceCorrectionRigFamily?.none)
                                        Text(DeviceCorrectionRigFamily.iec711.title)
                                            .tag(DeviceCorrectionRigFamily?.some(.iec711))
                                        Text(DeviceCorrectionRigFamily.bk5128.title)
                                            .tag(DeviceCorrectionRigFamily?.some(.bk5128))
                                    }
                                    .pickerStyle(.menu)
                                } else if let generated {
                                    Text("Resolved curve: \(generated.target.name)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(6)
                    }

                    GroupBox("Correction policy") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Policy", selection: policyBinding) {
                                ForEach(DeviceCorrectionPolicyKind.allCases, id: \.self) {
                                    Text($0.title).tag($0)
                                }
                            }
                            .pickerStyle(.segmented)

                            Text(policyExplanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Stepper(value: filterCountBinding, in: 3...16) {
                                Text("PEQ filters: \(filterCount)")
                            }
                        }
                        .padding(6)
                    }

                    HStack {
                        Button { generate() } label: {
                            if isGenerating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Generate Correction")
                            }
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                isGenerating
                                    || measurement == nil
                                    || trimmedDeviceName.isEmpty
                                    || isLoadingMeasurements
                                    || isLoadingDeviceMatch
                                    || (targetSelection.preset == .custom
                                        && (customTarget == nil
                                            || targetSelection.customTargetRigIdentity == nil))
                                    || (targetSelection.preset == .deviceMatch
                                        && deviceMatchConsensus == nil)
                                    || targetIsIncompatible
                            )
                        if generated == nil, existing != nil {
                            Text("Regenerate after changing measurement, target, policy, or filter count.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let generated {
                        GroupBox("Graph") {
                            VStack(alignment: .leading, spacing: 10) {
                                if ReferenceCorrection.validFilters(generated.filters, sampleRate: sampleRate) {
                                    CorrectionResponseGraph(profile: generated, sampleRate: sampleRate)
                                        .equatable().frame(height: 260)
                                } else {
                                    Text("Enter a valid frequency below Nyquist, finite gain, and positive Q.").foregroundStyle(.orange)
                                }
                                HStack(spacing: 16) {
                                    Label("Measurement", systemImage: "minus")
                                        .foregroundStyle(.secondary)
                                    Label("Target", systemImage: "minus")
                                        .foregroundStyle(.blue)
                                    Label("Corrected", systemImage: "minus")
                                        .foregroundStyle(.green)
                                    Label("Equalizer", systemImage: "minus")
                                        .foregroundStyle(.orange)
                                    Label("Residual error", systemImage: "minus")
                                        .foregroundStyle(.red)
                                }
                                .font(.caption)
                                Divider()
                                generatedEqualizerValues(generated)
                            }
                            .padding(6)
                        }
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button(referenceEndpoint == nil ? "Load into Equalizer" : "Load Correction") { requestLoadIntoEqualizer() }
                    .buttonStyle(.bordered)
                    .disabled(generated == nil || trimmedDeviceName.isEmpty || !ReferenceCorrection.validFilters(generated?.filters ?? [], sampleRate: sampleRate))
            }
            .padding(16)
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 620, idealHeight: 720)
        .task { await loadCatalog() }
        .onChange(of: searchText) { newValue in
            guard newValue != deviceName else { return }
            loadCoordinator.sourceGeneration &+= 1
            selectedCatalogID = nil
            deviceName = ""
            sourceMeasurements = []
            measurement = nil
            clearDeviceMatchTarget(clearSearch: false)
            generated = nil
            isLoadingMeasurements = false
        }
        .onChange(of: deviceMatchSearchText) { newValue in
            guard newValue != targetSelection.deviceMatchTarget?.deviceName,
                  !(selectedDeviceMatchCatalogID != nil && isLoadingDeviceMatch) else {
                return
            }
            loadCoordinator.deviceMatchGeneration &+= 1
            selectedDeviceMatchCatalogID = nil
            deviceMatchConsensus = nil
            targetSelection.deviceMatchTarget = nil
            generated = nil
            isLoadingDeviceMatch = false
        }
        .alert(
            "Replace existing equalizer?",
            isPresented: $showingReplacementConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Replace Equalizer", role: .destructive) {
                loadIntoEqualizer()
            }
        } message: {
            Text("Loading this correction will replace the current global EQ bands and user preamp. It will remain unsaved until you press the main Equalizer Save button.")
        }
        .fileImporter(
            isPresented: $showingMeasurementImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            importResponse(result, asTarget: false)
        }
        .fileImporter(
            isPresented: $showingTargetImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            importResponse(result, asTarget: true)
        }
        .onDisappear {
            loadCoordinator.sourceGeneration &+= 1
            loadCoordinator.deviceMatchGeneration &+= 1
        }
    }

}
