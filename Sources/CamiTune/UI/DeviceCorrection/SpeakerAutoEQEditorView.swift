import CamiTuneDomain
import AppKit
import SwiftUI

struct SpeakerAutoEQEditorSnapshot: Equatable {
    var draft: DeviceCorrectionProfile?
    var hasManualEdits: Bool
    var mode: SpeakerListeningMode
    var settings: SpeakerCorrectionSettings
}

@MainActor
final class SpeakerAutoEQEditorModel: ObservableObject {
    @Published var catalog: [SpeakerCatalogEntry] = []
    @Published var search = ""
    @Published var searchResults: [SpeakerCatalogEntry] = []
    @Published var speakerID = ""
    @Published var versions: [SpeakerMeasurementVersion] = []
    @Published var versionID = "" {
        didSet { if versionID != oldValue && !restoringHistory { invalidate() } }
    }
    @Published var mode: SpeakerListeningMode = .nearField {
        didSet { if mode != oldValue { optionsChanged() } }
    }
    @Published var settings = SpeakerCorrectionSettings() {
        didSet { if settings != oldValue { optionsChanged() } }
    }
    @Published var draft: DeviceCorrectionProfile?
    @Published var hasManualEdits = false
    @Published var headroomDB = 0.0
    @Published var error: String?
    @Published var warning: String?
    @Published var isLoadingCatalog = false
    @Published var isLoading = false
    @Published var isGenerating = false
    private var generation: UInt64 = 0
    private var operation: Task<Void, Never>?
    private var sourceOperation: Task<Void, Never>?
    private let provider: any SpeakerMeasurementProvider
    private let engine: SpeakerCorrectionEngine
    let history = AutoEQEditorHistory<SpeakerAutoEQEditorSnapshot>()
    private var restoringHistory = false
    private var snapshot: SpeakerAutoEQEditorSnapshot {
        .init(draft: draft, hasManualEdits: hasManualEdits, mode: mode, settings: settings)
    }
    init(provider: any SpeakerMeasurementProvider = SpinoramaSpeakerProvider.shared, engine: SpeakerCorrectionEngine = .init()) {
        self.provider = provider; self.engine = engine
        history.current = snapshot
        history.restore = { [weak self] snapshot in
            guard let self else { return }
            self.cancel()
            self.restoringHistory = true
            self.mode = snapshot.mode; self.settings = snapshot.settings
            self.draft = snapshot.draft; self.hasManualEdits = snapshot.hasManualEdits
            self.error = nil
            self.restoringHistory = false
        }
    }
    func cancel() {
        generation &+= 1; operation?.cancel(); operation = nil; isGenerating = false
    }
    func invalidate() {
        cancel(); draft = nil; hasManualEdits = false; error = nil
        history.reset(); history.current = snapshot
    }
    private func optionsChanged() {
        guard !restoringHistory else { return }
        cancel(); draft = nil; hasManualEdits = false; error = nil
        history.record(snapshot)
    }
    func replaceFilters(_ filters: [EQBand], in correction: DeviceCorrectionProfile) {
        guard filters != correction.filters else { return }
        cancel()
        var edited = correction
        edited.filters = filters
        draft = edited
        hasManualEdits = true
        error = nil
        history.record(snapshot)
    }
    func editBand(_ band: EQBand, in correction: DeviceCorrectionProfile) {
        guard let index = correction.filters.firstIndex(where: { $0.id == band.id }) else { return }
        var filters = correction.filters
        filters[index] = band
        replaceFilters(filters, in: correction)
    }
    func validationError(for correction: DeviceCorrectionProfile, sampleRate: Double) -> String? {
        guard let source = correction.speakerProvenance else { return "Choose a speaker measurement and generate Auto EQ first." }
        guard source.sampleRate == sampleRate else { return "Recalculate Auto EQ for the current sample rate." }
        do {
            try SpeakerCorrectionValidator().validate(correction.filters, settings: source.settings, sampleRate: sampleRate, allowDisabledBands: true)
            return nil
        } catch { return error.localizedDescription }
    }
    func close() { cancel(); sourceOperation?.cancel(); sourceOperation = nil }
    func restoreWork(_ saved: SpeakerAutoEQEditorDraft?, existing: DeviceCorrectionProfile?, sampleRate: Double) {
        restoringHistory = true
        defer {
            restoringHistory = false
            history.reset(); history.current = snapshot
        }
        if let saved = saved?.restored(for: sampleRate) {
            speakerID = saved.speakerID; search = saved.searchText; versionID = saved.versionID
            versions = saved.versions; mode = saved.mode; settings = saved.settings
            draft = saved.generated; hasManualEdits = saved.hasManualEdits
            headroomDB = saved.automaticHeadroomDB
        } else if let source = existing?.speakerProvenance {
            speakerID = source.speakerName; search = source.speakerName; versionID = source.measurementVersion
            mode = source.listeningMode; settings = source.settings
        } else { settings.maxFrequency = min(settings.maxFrequency, sampleRate * 0.49) }
    }
    func savedWork(sampleRate: Double, presentation: AutoEQPresentationPreferences) -> SpeakerAutoEQEditorDraft {
        .init(sampleRate: sampleRate, searchText: search, speakerID: speakerID, versionID: versionID,
              versions: versions, mode: mode, settings: settings, generated: draft,
              hasManualEdits: hasManualEdits, automaticHeadroomDB: headroomDB, presentation: presentation)
    }
    func loadSources() async {
        await loadCatalog()
        guard !Task.isCancelled else { return }
        if !speakerID.isEmpty { selectSpeaker(preservingVersion: true, preservingDraft: true) }
    }
    func loadCatalog(refresh: Bool = false) async {
        guard !isLoadingCatalog else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            let catalog = try await provider.catalog(refresh: refresh)
            try Task.checkCancellation()
            self.catalog = catalog; warning = await provider.currentWarning()
        }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func searchCatalog() async {
        let query = search
        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        let entries = catalog
        let results = await Task.detached(priority: .utility) {
            Array(entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.prefix(40))
        }.value
        guard !Task.isCancelled, search == query else { return }
        searchResults = results
    }
    func selectSpeaker(preservingVersion: Bool = false, preservingDraft: Bool = false) {
        if !preservingDraft { invalidate(); versions = [] }
        sourceOperation?.cancel(); isLoading = true
        let speaker = SpeakerCatalogEntry(name: speakerID), previousVersion = preservingVersion ? versionID : ""
        sourceOperation = Task {
            do {
                let metadata = try await provider.metadata(for: speaker, refresh: false)
                let versions = try await provider.versions(for: speaker, refresh: false)
                guard !Task.isCancelled, speakerID == speaker.name else { return }
                self.versions = versions
                versionID = versions.contains(where: { $0.id == previousVersion }) ? previousVersion
                    : SpeakerMeasurementVersion.recommended(in: versions, metadata: metadata)?.id ?? versions.first?.id ?? ""
                warning = await provider.currentWarning()
                if !versions.contains(where: \.supportsCEA2034) { error = "This speaker has no compatible CEA2034 measurement for automatic correction." }
                isLoading = false
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; isLoading = false } }
        }
    }
    var selectedVersion: SpeakerMeasurementVersion? { versions.first { $0.id == versionID } }
    func generate(profile: DeviceProfile, state: AppState, refresh: Bool = false) {
        cancel(); error = nil
        guard let version = selectedVersion else { error = "Choose a speaker measurement first."; return }
        let token = generation, editGeneration = state.editGeneration
        let speaker = SpeakerCatalogEntry(name: speakerID), mode = mode, settings = settings
        isGenerating = true
        operation = Task {
            do {
                let measurement = try await provider.cea2034(speaker: speaker, version: version, refresh: refresh)
                let correction = try await engine.generate(measurement: measurement, mode: mode,
                    settings: settings, sampleRate: Double(profile.sampleRate))
                let headroom = await state.automaticHeadroom(for: profile, correction: correction)
                guard !Task.isCancelled, generation == token, state.editGeneration == editGeneration else { return }
                draft = correction; headroomDB = headroom
                hasManualEdits = false
                history.record(snapshot)
                warning = measurement.provenance.isStale ? "Could not refresh Spinorama. Using the last cached measurement." : await provider.currentWarning()
                isGenerating = false
            } catch { if !Task.isCancelled, generation == token { self.error = error.localizedDescription; isGenerating = false } }
        }
    }
}

@MainActor
struct SpeakerAutoEQEditorView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    @StateObject private var model: SpeakerAutoEQEditorModel
    @StateObject private var draftStore: SpeakerAutoEQDraftStore
    @State private var draftLoaded = false
    @State private var equalizerState: GlobalEQHistoryState?
    @State private var presentation = AutoEQPresentationPreferences()
    @State private var selectedBandID: UUID?
    init(state: AppState, profile: Binding<DeviceProfile>, draftDirectory: URL = CamiTunePaths.supportDirectory,
         model: SpeakerAutoEQEditorModel? = nil) {
        self.state = state
        _profile = profile
        _model = StateObject(wrappedValue: model ?? SpeakerAutoEQEditorModel())
        _draftStore = StateObject(wrappedValue: SpeakerAutoEQDraftStore(url: SpeakerAutoEQDraftStore.url(
            profileID: profile.wrappedValue.id, endpoint: .speakers, directory: draftDirectory)))
    }
    private var existing: DeviceCorrectionProfile? {
        let correction = equalizerState?.deviceCorrectionProvenance ?? profile.processing.deviceCorrection
        return correction?.speakerProvenance != nil ? correction : nil
    }
    private var displayed: DeviceCorrectionProfile? { model.draft ?? existing }
    private var isLoaded: Bool { displayed.map { equalizerState?.matchesAutoEQ($0) == true } ?? false }
    private var persistentDraft: SpeakerAutoEQEditorDraft {
        model.savedWork(sampleRate: Double(profile.sampleRate), presentation: presentation)
    }

    var body: some View {
        let validationError = displayed.flatMap { model.validationError(for: $0, sampleRate: Double(profile.sampleRate)) }
        return VStack(alignment: .leading, spacing: 12) {
            DeviceCorrectionSectionHeader(title: "Auto EQ",
                hint: "Generate correction from anechoic speaker measurements. Load into Equalizer to apply it. This corrects the speaker model; it does not measure your room.")
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Device and source data") {
                    VStack(alignment: .leading, spacing: 12) {
                        AutoEQSearchField(placeholder: "Search speakers", query: $model.search,
                            results: model.searchResults, title: { $0.name }) { speaker in
                            model.speakerID = speaker.id; model.search = speaker.name
                            model.selectSpeaker()
                        }
                        if model.isLoadingCatalog {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading device catalog…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Measurement").font(.headline)
                                if let source = model.selectedVersion {
                                    Text("\(model.speakerID) · \(source.sourceDisplayName) · via Spinorama")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("Choose a search result").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Refresh Catalog") { Task { await model.loadCatalog(refresh: true) } }
                                .disabled(model.isLoadingCatalog)
                        }
                        if model.isLoading {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading measurement sources…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if model.selectedVersion?.supportsCEA2034 == false {
                            Text("This version has no CEA2034 data. Choose another source.").font(.caption).foregroundStyle(.orange)
                        }
                    }.padding(6)
                }
                GroupBox("Listening setup") {
                    VStack(alignment: .leading, spacing: 12) {
                        JoinedSegmentedControl(options: SpeakerListeningMode.allCases, selection: $model.mode, title: { $0.title })
                            .accessibilityLabel("Speaker listening setup")
                        Text(model.mode == .nearField ? "Prioritizes direct sound and listening-window behavior for desktop and near-field listening."
                             : "Uses full CEA2034 speaker data to optimize predicted room listening behavior. This does not measure your room.")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Advanced", isExpanded: $presentation.advancedExpanded) {
                            VStack(alignment: .leading, spacing: 10) {
                                Picker("Measurement source/version", selection: $model.versionID) {
                                    ForEach(model.versions) { Text("\($0.sourceDisplayName) · \($0.id)").tag($0.id) }
                                }
                                Stepper("Filters: \(model.settings.filterCount)", value: $model.settings.filterCount, in: 1...12)
                                AutoEQBoundsRow(title: "Frequency (Hz)", lower: $model.settings.minFrequency, upper: $model.settings.maxFrequency, digits: 0)
                                AutoEQBoundsRow(title: "Gain (dB)", lower: $model.settings.minimumGainDB, upper: $model.settings.maximumGainDB, digits: 1)
                                AutoEQBoundsRow(title: "Q", lower: $model.settings.minimumQ, upper: $model.settings.maximumQ)
                                Button("Refresh Measurements") { model.generate(profile: profile, state: state, refresh: true) }
                                    .disabled(cannotGenerate)
                            }.padding(.top, 8)
                        }
                    }.padding(6)
                }
                HStack {
                    Spacer()
                    if model.isGenerating { Button("Cancel") { model.cancel() } }
                    AutoEQGenerateButton(isGenerating: model.isGenerating) {
                        presentation.resultsExpanded = true
                        model.generate(profile: profile, state: state)
                    }.disabled(cannotGenerate)
                }
                if let displayed {
                    AutoEQResultCard(isExpanded: $presentation.resultsExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(displayed.speakerProvenance?.listeningMode == .nearField
                                 ? "Original and corrected Listening Window · flat reference"
                                 : "Original and corrected predicted in-room response · model-based")
                                .font(.caption).foregroundStyle(.secondary)
                            if ReferenceCorrection.validFilters(displayed.filters, sampleRate: Double(profile.sampleRate)) {
                                CorrectionResponseGraph(profile: displayed, sampleRate: Double(profile.sampleRate), onEdit: { band in
                                    model.editBand(band, in: displayed)
                                }, selectedBandID: $selectedBandID, visibleCurves: $presentation.visibleCurves, showControlPoints: $presentation.showControlPoints)
                                    .frame(height: 300)
                            } else {
                                Text("Enter a valid frequency below Nyquist, finite gain, and positive Q.").font(.caption).foregroundStyle(.orange)
                            }
                            Divider()
                            Text("Equalizer values").font(.headline)
                            Text("Automatic headroom \(model.headroomDB, specifier: "%.2f") dB")
                                .font(.caption.monospacedDigit().weight(.medium))
                            OverflowAwareHorizontalScrollView {
                                CorrectionFilterTable(filters: Binding(get: { self.displayed?.filters ?? [] }, set: { filters in
                                    guard let correction = self.displayed else { return }
                                    model.replaceFilters(filters, in: correction)
                                }), selectedBandID: $selectedBandID)
                            }
                            DisclosureGroup("Details", isExpanded: $presentation.detailsExpanded) {
                                if let source = displayed.speakerProvenance {
                                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                                        GridRow { Text("Sources"); Text("\(source.sourceDisplayName) · via Spinorama") }
                                        GridRow { Text("Measurement version"); Text(source.measurementVersion) }
                                        GridRow { Text("Listening setup"); Text(source.listeningMode.title) }
                                        GridRow { Text("Engine"); Text("\(source.engineName) \(source.engineVersion)") }
                                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
                if let validationError { Label(validationError, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                if let warning = model.warning { Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            }.padding(.bottom, 16)
            Divider()
            HStack(alignment: .top) {
                AutoEQUndoButton(history: model.history)
                AutoEQUndoButton(history: model.history, isRedo: true)
                Spacer()
                AutoEQSaveTXTButton(correction: displayed) { model.error = $0 }
                    .disabled(displayed == nil || validationError != nil)
                AutoEQLoadButton(isLoaded: isLoaded, draftLabel: model.hasManualEdits ? "Edited draft" : "Draft", action: loadIntoEqualizer)
                    .disabled(displayed == nil || model.isGenerating || model.isLoading || validationError != nil)
            }.padding(.vertical, 5)
        }
        .groupBoxStyle(DeviceCorrectionCardStyle())
        .disabled(state.isSavingProfileSettings || state.history.isReplaying)
        .task {
            reload()
            if !draftLoaded {
                let saved = await draftStore.loadWithoutBlockingUI()
                guard !Task.isCancelled else { return }
                model.restoreWork(saved, existing: existing, sampleRate: Double(profile.sampleRate))
                if let saved { presentation = saved.presentation }
                draftLoaded = true
            }
            await model.loadSources()
        }
        .task(id: displayed?.filters) {
            guard let displayed else { return }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let headroom = await state.automaticHeadroom(for: profile, correction: displayed)
            guard !Task.isCancelled else { return }
            model.headroomDB = headroom
        }
        .task(id: model.search) { await model.searchCatalog() }
        .onChange(of: model.catalog) { _ in Task { await model.searchCatalog() } }
        .onChange(of: persistentDraft) { _ in persistWork() }
        .onChange(of: profile.sampleRate) { _ in model.invalidate() }
        .onChange(of: state.editGeneration) { _ in model.cancel() }
        .onChange(of: profile.processing) { _ in reload() }
        .onChange(of: state.historyReplayRevision) { _ in reload() }
        .onReceive(state.eqDraftChanges.filter { $0 == profile.id }) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in persistWork(flush: true) }
        .onDisappear { persistWork(); model.close() }
    }
    private var cannotGenerate: Bool { model.isLoading || model.isGenerating || model.selectedVersion?.supportsCEA2034 != true }
    private func reload() { equalizerState = try? state.globalEQHistoryState(for: profile) }
    private func persistWork(flush: Bool = false) {
        guard draftLoaded else { return }
        draftStore.save(persistentDraft)
        if flush { draftStore.flush() }
    }
    private func loadIntoEqualizer() {
        guard let correction = displayed, correction.speakerProvenance?.sampleRate == Double(profile.sampleRate) else { return }
        do {
            try state.loadAutoEQCorrectionDraft(correction, for: profile)
            profile = try state.historyProfile(profile.id)
            var layout = state.profiles.effectiveLayout(for: profile)
            layout.hidden.remove(.equalizer)
            if layout.equalizer == .simpleTone { layout.equalizer = .both }
            profile.sectionLayout = layout
            state.equalizerReplacementChanges.send(profile.id)
            reload()
            presentation.resultsExpanded = false
            persistWork(flush: true)
            let id = profile.id, generation = state.editGeneration
            Task {
                guard generation == state.editGeneration else { return }
                do { try await state.applyHistoryProfileIfActive(id) } catch { state.errorMessage = error.localizedDescription }
            }
        } catch { model.error = error.localizedDescription }
    }
}

@MainActor
extension AppState {
    func automaticHeadroom(for profile: DeviceProfile, correction: DeviceCorrectionProfile) async -> Double {
        guard var candidate = try? applyingSessionEQDrafts(to: profile) else { return 0 }
        candidate.processing.setDeviceCorrection(nil)
        candidate.setGlobalEqualizer(preampDB: 0, bands: correction.filters)
        let snapshot = candidate
        return await Task.detached(priority: .utility) {
            do {
                let assets = try PreparedRuntimeAssets.prepare(profile: snapshot, directory: CamiTunePaths.impulseResponsesDirectory)
                return try ProcessingGraphBuilder(channelCount: snapshot.processingChannelCount, preparedAssets: assets).build(profile: snapshot).automaticHeadroomDB
            } catch { return 0 }
        }.value
    }
}
