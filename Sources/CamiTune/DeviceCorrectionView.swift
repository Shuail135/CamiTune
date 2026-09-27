import CamiTuneDomain
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct DeviceCorrectionEditorView: View {
    let existing: DeviceCorrectionProfile?
    let sampleRate: Double
    let referenceEndpoint: ProfileEndpointKind?
    let automaticHeadroom: @MainActor ([EQBand]) async -> Double
    let shouldConfirmReplacement: @MainActor () -> Bool
    let onPreview: (@MainActor (DeviceCorrectionProfile?) async -> Void)?
    let onCancel: @MainActor () -> Void
    let onLoad: @MainActor (DeviceCorrectionProfile) -> Void

    let catalog = DeviceMeasurementCatalog.online
    @StateObject var history = CorrectionEditorHistory()
    @StateObject var loadCoordinator = DeviceCorrectionLoadCoordinator()

    @State var deviceName: String
    @State var searchText: String
    @State var policy: DeviceCorrectionPolicyKind
    @State var autoEQSettings: AutoEQSettings
    var catalogIsIEM: Bool { referenceEndpoint == .iem }
    @State var selectedBandID: UUID?
    @State var targetChosen = false
    @State var hasCompatibleDeviceMatch = false
    @State var searchIndex = DeviceCatalogSearch.Index(entries: [])
    @State var searchResults: [DeviceCatalogEntry] = []
    @State var deviceMatchSearchResults: [DeviceCatalogEntry] = []
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
    @State var accepted = false
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
        automaticHeadroom: @escaping @MainActor ([EQBand]) async -> Double,
        shouldConfirmReplacement: @escaping @MainActor () -> Bool,
        onPreview: (@MainActor (DeviceCorrectionProfile?) async -> Void)? = nil,
        onCancel: @escaping @MainActor () -> Void,
        onLoad: @escaping @MainActor (DeviceCorrectionProfile) -> Void
    ) {
        self.existing = existing
        self.sampleRate = sampleRate
        self.referenceEndpoint = referenceEndpoint
        self.automaticHeadroom = automaticHeadroom
        self.shouldConfirmReplacement = shouldConfirmReplacement
        self.onPreview = onPreview
        self.onCancel = onCancel
        self.onLoad = onLoad
        _deviceName = State(initialValue: existing?.deviceName ?? "")
        _searchText = State(initialValue: existing?.deviceName ?? "")
        _selectedCatalogID = State(initialValue: existing.map {
            $0.deviceIdentity.stableKey
        })
        _policy = State(initialValue: existing?.policy ?? .recommended)
        _autoEQSettings = State(initialValue: existing?.autoEQSettings ?? .init())
        _targetChosen = State(initialValue: existing != nil)
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
            initialValue: 0
        )
    }

    var body: some View {
        let sourceSearchResults = selectedCatalogID == nil ? searchResults : []

        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Device Correction")
                        .font(.title2.bold())

                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Device and source data") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField(catalogIsIEM ? "Search IEMs" : "Search headphones", text: $searchText)
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

                            if sourceMeasurements.first?.source.origin == .local {
                                Picker("Measurement fixture", selection: sourceRigBinding) {
                                    Text("—").tag(DeviceCorrectionRigFamily?.none)
                                    Text("IEC 711").tag(DeviceCorrectionRigFamily?.some(.iec711))
                                    Text("B&K 5128").tag(DeviceCorrectionRigFamily?.some(.bk5128))
                                }
                            }
                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                Picker("Target", selection: compatibleTargetBinding) {
                                    Text("—").tag(DeviceCorrectionTargetPreset?.none)
                                    ForEach(availableTargets, id: \.self) {
                                        Text(targetTitle($0)).tag(Optional($0))
                                    }
                                }.pickerStyle(.menu).disabled(measurement == nil)
                                if measurement != nil && availableTargets.isEmpty {
                                    Text("No compatible target is available for this measurement data.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }

                                if targetChosen && targetSelection.preset == .jm1PopAvgDFTilt {
                                    HStack(spacing: 10) {
                                        Text("Tilt")
                                            .font(.caption.weight(.medium))
                                        Slider(value: targetTiltBinding, in: -2...1, step: 0.1)
                                        Text("\(targetSelection.tiltDBPerOctave, format: .number.precision(.fractionLength(1))) dB/oct")
                                            .font(.caption.monospacedDigit())
                                            .frame(width: 92, alignment: .trailing)
                                    }
                                }

                                if targetChosen && targetSelection.preset == .deviceMatch {
                                    deviceMatchControls
                                }

                                Button("Import Target…") { showingTargetImporter = true }.disabled(measurement == nil)
                                if customTarget != nil {
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
                                }
                            }
                        }
                        .padding(6)
                    }

                    GroupBox("Correction policy") {
                        VStack(alignment: .leading, spacing: 12) {
                            JoinedSegmentedControl(
                                options: DeviceCorrectionPolicyKind.allCases,
                                selection: policyBinding,
                                title: { $0.title }
                            )
                            .accessibilityLabel("Policy")

                            if policy == .recommended && targetChosen && targetSelection.preset != .deviceMatch && targetSelection.preset != .custom {
                                HStack {
                                    Text("Bass")
                                    Slider(value: modifierBinding(\.bassGainDB), in: -12...12, step: 0.5)
                                    TextField("dB", value: modifierBinding(\.bassGainDB), format: .number.precision(.fractionLength(0...1))).frame(width: 55)
                                    Text("dB").foregroundStyle(.secondary)
                                }
                            }
                            if policy == .exactTarget {
                                advancedCorrectionControls
                            } else {
                                DisclosureGroup("Advanced") {
                                    advancedCorrectionControls.padding(.top, 8)
                                }
                            }

                        }
                        .padding(6)
                    }

                    HStack {
                        Spacer()
                        Button { generate() } label: {
                            if isGenerating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text((generated?.filters.contains { $0.isLocked } ?? false) ? "Re-optimize Unlocked Bands" : "Auto EQ")
                            }
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                isGenerating
                                    || !targetChosen || !autoEQSettings.isValid
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

                    }

                    if let generated {
                        GroupBox("Graph") {
                            VStack(alignment: .leading, spacing: 10) {
                                if ReferenceCorrection.validFilters(generated.filters, sampleRate: sampleRate) {
                                    CorrectionResponseGraph(profile: generated, sampleRate: sampleRate, onEdit: { band in editBand(band) }, selectedBandID: $selectedBandID)
                                        .frame(height: 300)
                                } else {
                                    Text("Enter a valid frequency below Nyquist, finite gain, and positive Q.").foregroundStyle(.orange)
                                }
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
                Button { history.manager.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!history.manager.canUndo).keyboardShortcut("z", modifiers: .command).help("Undo")
                Button { history.manager.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!history.manager.canRedo).keyboardShortcut("z", modifiers: [.command, .shift]).help("Redo")
                Spacer()
                Button("Cancel") { onCancel() }
                Button(referenceEndpoint == nil ? "Load into Equalizer" : "Load Correction") { requestLoadIntoEqualizer() }
                    .buttonStyle(.bordered)
                    .disabled(generated == nil || !resultIsCurrent || trimmedDeviceName.isEmpty || !ReferenceCorrection.validFilters(generated?.filters ?? [], sampleRate: sampleRate))
            }
            .padding(16)
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 620, idealHeight: 720)
        .onAppear {
            history.current = editorSnapshot
            history.restore = { snapshot in
                generated = snapshot.generated
                targetSelection = snapshot.target
                policy = snapshot.policy
                autoEQSettings = snapshot.settings
                targetChosen = snapshot.targetChosen
            }
        }
        .onChange(of: editorSnapshot) { history.record($0) }
        .task { await loadCatalog() }
        .task(id: sourceSearchRequest) { await updateSearch(sourceSearchRequest) }
        .task(id: matchSearchRequest) { await updateSearch(matchSearchRequest, deviceMatch: true) }
        .onChange(of: searchIndex.id) { _ in updateDeviceMatchAvailability() }
        .onChange(of: targetSources) { _ in updateDeviceMatchAvailability() }
        .task(id: generated) {
            guard let generated, ReferenceCorrection.validFilters(generated.filters, sampleRate: sampleRate) else { return }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !Task.isCancelled else { return }
            await onPreview?(generated)
        }
        .task(id: generated?.filters) {
            guard let filters = generated?.filters else { generatedAutomaticHeadroomDB = 0; return }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let result = await automaticHeadroom(filters)
            guard !Task.isCancelled, generated?.filters == filters else { return }
            generatedAutomaticHeadroomDB = result
        }
        .onChange(of: searchText) { newValue in
            searchResults = []
            guard newValue != deviceName else { return }
            history.reset()
            loadCoordinator.sourceGeneration &+= 1
            selectedCatalogID = nil
            targetChosen = false
            deviceName = ""
            sourceMeasurements = []
            measurement = nil
            clearDeviceMatchTarget(clearSearch: false)
            generated = nil
            isLoadingMeasurements = false
        }
        .onChange(of: deviceMatchSearchText) { newValue in
            deviceMatchSearchResults = []
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
            if !accepted { Task { await onPreview?(nil) } }
            history.restore = nil
            history.manager.removeAllActions()
            loadCoordinator.sourceGeneration &+= 1
            loadCoordinator.deviceMatchGeneration &+= 1
        }
    }

}
