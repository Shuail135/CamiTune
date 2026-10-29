import CamiTuneAudio
import CamiTuneDomain
import Foundation
import AppKit
import Combine

struct AutomaticActivationRetryState: Equatable, Sendable {
    let outputUID: String
    let failureCount: Int
    let retryAfter: Date

    static func recordingFailure(
        for outputUID: String,
        previous: AutomaticActivationRetryState?,
        now: Date = Date()
    ) -> AutomaticActivationRetryState {
        let failureCount: Int
        if let previous, previous.outputUID == outputUID {
            failureCount = previous.failureCount + 1
        } else {
            failureCount = 1
        }
        let delay = min(30.0, pow(2.0, Double(min(failureCount - 1, 5))))
        return AutomaticActivationRetryState(
            outputUID: outputUID,
            failureCount: failureCount,
            retryAfter: now.addingTimeInterval(delay)
        )
    }

    func defersActivation(for outputUID: String, now: Date = Date()) -> Bool {
        self.outputUID == outputUID && now < retryAfter
    }
}

@MainActor
final class AppState: NSObject, ObservableObject {
    let history = UndoCoordinator()
    lazy var undoCommands = UndoCommandRouter(history: history)
    @Published private(set) var historyReplayRevision: UInt64 = 0
    private(set) var editGeneration: UInt64 = 0
    private(set) var pendingEditorApplies: Set<UUID> = []
    func invalidateDeferredEdits() {
        editGeneration &+= 1
        cancelMultichannelAutosaves()
    }
    func publishHistoryReplay() { historyReplayRevision &+= 1 }
    func markPendingEditorApply(_ id: UUID) { pendingEditorApplies.insert(id) }
    func clearPendingEditorApply(_ id: UUID) { pendingEditorApplies.remove(id) }
    var referenceCorrectionSessions: [UUID: ReferenceCorrectionSession] = [:]
    var speakerEditSessions: [UUID: SpeakerSystemHistoryState] = [:]
    private var historyErrorObservation: AnyCancellable?
    @Published private(set) var spatialCalibrationContext: SpatialCalibrationContext?
    let setupPresentation = SetupPresentationState()
    let profileConfirmations = ProfileConfirmationState()
    @Published private(set) var isSavingProfileSettings = false
    private var pendingSettingsLiveApply = false
    @Published private(set) var errorRecovery: AppErrorRecovery?
    @Published var errorMessage: String? {
        didSet { errorRecovery = nil }
    }

    func presentError(_ error: Error, prefix: String = "") {
        errorMessage = prefix + error.localizedDescription
        errorRecovery = (error as? AppError)?.recovery
    }
    @Published var validationMessage: String = ""
    @Published var warnings: [String] = []
    /// Draft edits are intentionally kept out of `objectWillChange`. A slider
    /// can produce dozens of draft writes per second; publishing those through
    /// AppState used to invalidate the entire navigation tree, menu-bar UI,
    /// profile editor, and every visible control for each pointer event.
    private(set) var eqDraftRevision: UInt64 = 0
    let equalizerReplacementChanges = PassthroughSubject<UUID, Never>()
    let eqDraftChanges = PassthroughSubject<UUID, Never>()

    lazy var automaticBuffers = AutomaticAudioBufferController(cache: profiles.automaticAudioBufferCache,
        persist: { [weak self] in self?.profiles.automaticAudioBufferCache = $0 })
    private var automaticBufferTask: Task<Void, Never>?
    private var runtimeObservation: AnyCancellable?
    lazy var runtimeCoordinator: AudioRuntimeCoordinator = {
        let owner = AudioRuntimeCoordinator(services: runtimeServices, perAppAudio: perAppAudio, captureDelivery: captureDelivery,
            performanceRecorder: performanceRecorder, callbacks: .init(
                profiles: { [weak self] in self?.profiles.profiles ?? [] },
                automaticProfile: { [weak self] in self?.profiles.automaticProfile(forPhysicalDeviceUID: $0) },
                applyingDrafts: { [weak self] profile in try self?.applyingSessionEQDrafts(to: profile) ?? profile },
                settingsBusy: { [weak self] in (self?.isSavingProfileSettings ?? false)
                    || (self?.profiles.hasDurableCommit ?? false) || (self?.dependencies.setupInProgress ?? false) },
                retireOverlays: { [weak self] in
                    if let context = self?.spatialCalibrationContext { self?.endSpatialCalibration(id: context.id) }
                },
                cancelStartup: { [weak self] in
                    guard let self, let task = self.startupConfigurationTask else { return }
                    task.cancel(); await task.value; self.startupConfigurationTask = nil
                },
                reportError: { [weak self] in self?.presentError($0) },
                reportMessage: { [weak self] in self?.errorMessage = $0 },
                currentError: { [weak self] in self?.errorMessage },
                clearError: { [weak self] in self?.clearTransientError() }))
        runtimeObservation = owner.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        return owner
    }()
    var runtimeCoordinatorSummary: String { runtimeCoordinator.coordinatorSummary }
    var runtimeSnapshot: AudioRuntimeStateSnapshot { runtimeCoordinator.stateSnapshot }
    var runtimeSnapshots: AnyPublisher<AudioRuntimeStateSnapshot, Never> { runtimeCoordinator.$stateSnapshot.eraseToAnyPublisher() }
    var isActive: Bool { runtimeCoordinator.isActive }
    var activeSession: AudioRuntimeSession? { runtimeCoordinator.activeSession }
    var activeVolumeMode: SystemVolumeMode? { runtimeCoordinator.activeVolumeMode }
    var transitionInProgress: Bool { runtimeCoordinator.transitionInProgress }
    var liveApplyRequestRevision: UInt64 { runtimeCoordinator.liveApplyRequestRevision }
    var acknowledgedPlanRevision: RuntimeIntentRevision? { runtimeCoordinator.acknowledgedPlanRevision }
    var runtimePlanSummary: String { runtimeCoordinator.runtimePlanSummary }
    var candidatePlanRevision: RuntimeIntentRevision? { runtimeCoordinator.candidatePlanRevision }
    var runtimePlanDiffSummary: String { runtimeCoordinator.runtimePlanDiffSummary }
    var actualGraphUpdateSummary: String { runtimeCoordinator.actualGraphUpdateSummary }
    var lastRuntimePlanDelta: RuntimePlanDelta? { runtimeCoordinator.lastRuntimePlanDelta }
    private var activatingProfileID: UUID? { runtimeCoordinator.activatingProfileID }
    private var activeSampleRate: Int? { runtimeCoordinator.activeSampleRate }
    private var activeRoutingUID: String? { runtimeCoordinator.activeRoutingUID }
    private var activePhysicalOutputUID: String? { runtimeCoordinator.activePhysicalOutputUID }
    private var activeAudioRoute: ActiveAudioRoute? { runtimeCoordinator.activeAudioRoute }

    var activeProfileID: UUID? { activeSession?.profileID }

    private var suppliedRuntimeServices: AudioRuntimeServices?
    lazy var runtimeServices: AudioRuntimeServices = suppliedRuntimeServices ?? makeLiveRuntimeServices()
    lazy var diagnostics = DiagnosticsController()
    lazy var performanceRecorder = RuntimePerformanceRecorder(source: pcmRouter.performanceSource, presentationSource: perAppAudio.presentationPerformanceSource)
    private var draftPerformance: [UUID: PerformanceOperation] = [:]

    let coreAudio: CoreAudioSnapshotStore
    let coreAudioService: CoreAudioService
    let profiles: ProfileStore
    let dependencies: DependencyManager
    let loginItem = LoginItemManager()
    private var directOutput: DirectCoreAudioOutput?
    private var directOutputClockTask: Task<Void, Never>?
    private var directOutputError: String?
    var outputEngineIsRunning: Bool {
        if let output = directOutput { return output.snapshot().error == nil }
        return processingBackend.isRunning
    }
    let meters = AudioRuntimeMonitor()
    let spectrum = SpectrumAnalyzer()
    let pcmRouter = PCMRouter()
    lazy var pluginCatalog = PluginCatalog()
    var pluginEditorHistory: [UUID: PluginRack] = [:]
    lazy var pluginReorderApplies = PluginRackReorderApply { [weak self] id, isCurrent in
        guard let self else { return true }
        while (self.isSavingProfileSettings || self.transitionInProgress || self.profiles.hasDurableCommit), isCurrent() {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard isCurrent() else { return false }
        guard self.profiles.profiles.contains(where: { $0.id == id }) else { return true }
        // Snapshot once after arranging, preserving any edits made in an open
        // plug-in window. Check again before starting an audio transaction.
        await self.pluginRackManager.flushEditors(profileID: id, close: false)
        guard isCurrent() else { return false }
        do { try await self.applyHistoryProfileIfActive(id) }
        catch { self.errorMessage = error.localizedDescription }
        return true
    }
    lazy var pluginRackManager: PluginRackManager = {
        let manager = PluginRackManager(sidechains: perAppAudio.pluginSidechains)
        manager.stateChanged = { [weak self] in self?.capturePluginState(profileID: $0, slotID: $1, data: $2) }
        manager.editorClosed = { [weak self] in self?.finishPluginEditor(profileID: $0, slotID: $1) }
        manager.linkedEditorChanged = { [weak self] id in
            self?.markPendingEditorApply(id)
            self?.pluginReorderApplies.schedule(id)
        }
        manager.midiLearned = { [weak self] in self?.captureMIDIMapping(profileID: $0, mapping: $1) }
        return manager
    }()
    let perAppAudio: PerAppAudioController
    private let suppliedCaptureBackend: (any AudioCaptureBackend)?
    lazy var captureBackend: any AudioCaptureBackend = suppliedRuntimeServices?.captureBackend ?? suppliedCaptureBackend ?? makeLiveCaptureBackend()
    lazy var captureDelivery = AudioCaptureDelivery(router: pcmRouter, applications: perAppAudio)
    let updateChecker = AppUpdateChecker()

    private let notifications = NotificationManager()
    private let processingBackend: any AudioProcessingBackend
    private var monitorTimer: Timer?
    private var startupConfigurationTask: Task<Void, Never>?
    private var hasShutdown = false
    var processingDrafts: [UUID: ProfileProcessingDraft] = [:]
    private var requestedRuntimeVisualProfileID: UUID?
    private var requestedMovieAnalysisProfileID: UUID?
    private var requestedMeterVisuals = true
    private var requestedSpectrumVisuals = true
    private(set) var mainWindowPresentationActive = false
    private var profilePersistenceErrorObservation: AnyCancellable?
    private var coreAudioRoutingObservation: AnyCancellable?
    private var immediateDefaultOutputObservation: AnyCancellable?

    override convenience init() {
        self.init(profiles: ProfileStore(), perAppAudio: PerAppAudioController(), startServices: true)
    }

    init(profiles: ProfileStore, perAppAudio: PerAppAudioController, startServices: Bool = false, runtimeServices: AudioRuntimeServices? = nil, captureBackend: (any AudioCaptureBackend)? = nil, processingBackend: (any AudioProcessingBackend)? = nil) {
        precondition(runtimeServices == nil || !startServices)
        self.suppliedRuntimeServices = runtimeServices
        let audio = CoreAudioService(observesHardware: runtimeServices == nil)
        let dependencies = DependencyManager(coreAudio: audio)
        self.coreAudioService = audio
        self.coreAudio = audio.snapshots
        self.suppliedCaptureBackend = captureBackend
        self.processingBackend = runtimeServices?.processingBackend ?? processingBackend ?? CamillaDSPController(manager: CamillaDSPManager(), binary: dependencies.camillaDSPBinary)
        self.profiles = profiles
        self.perAppAudio = perAppAudio
        self.dependencies = dependencies
        super.init()
        history.restorer = self
        perAppAudio.history = history
        perAppAudio.presentationStore.history = history
        profiles.history = history
        profiles.performanceRecorder = performanceRecorder
        historyErrorObservation = history.$lastError.compactMap { $0 }.sink { [weak self] in self?.errorMessage = $0 }

        profilePersistenceErrorObservation = profiles.$persistenceError
            .compactMap { $0 }
            .sink { [weak self] message in
                self?.errorMessage = message
            }
        guard startServices else { return }
        UIRenderPerformance.startMonitoring()

        immediateDefaultOutputObservation = audio.snapshots.$snapshot.map(\.defaultOutputUID)
            .removeDuplicates()
            .sink { [weak self] uid in
                Task { @MainActor [weak self] in
                    guard let self, self.isActive else { return }
                    self.runtimeCoordinator.handleDefaultOutputChange(uid)
                }
            }

        coreAudioRoutingObservation = Publishers.CombineLatest(
            audio.snapshots.$snapshot.map(\.defaultOutputUID),
            audio.snapshots.$snapshot.map(\.outputs)
        )
        .dropFirst()
        .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
        .sink { [weak self] _ in
            Task { @MainActor in await self?.monitorRouting() }
        }

        // External sample-rate changes do not have a Combine surface here, so
        // retain a low-frequency health check. Route and device changes are
        // handled immediately by the notifications above.
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.monitorRouting()
            }
        }

        monitorTimer?.tolerance = 0.3

        Task { await notifications.requestAuthorization() }
        updateChecker.start()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    deinit {
        monitorTimer?.invalidate()
        startupConfigurationTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func startAfterPresentation() {
        guard startupConfigurationTask == nil else { return }
        startupConfigurationTask = Task { @MainActor [weak self] in
            // The first suspension guarantees AppKit has a chance to order the
            // main window and install the status item before driver setup.
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            // Keep startup probes away from the main actor until HAL has
            // produced a device snapshot. The editor is usable immediately and
            // renders only from cached device state while this task waits.
            for _ in 0..<100 where !self.coreAudio.hasCompletedInitialRefresh {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
            guard self.coreAudio.hasCompletedInitialRefresh else { return }
            await self.dependencies.refreshWithoutBlockingUI()
            guard !Task.isCancelled, self.coreAudio.hasCompletedInitialRefresh,
                  !self.transitionInProgress, !self.isActive else { return }
            // Existing endpoints may be incomplete or belong to outputs that
            // have since disconnected. Always reconcile the full desired set.
            self.runtimeCoordinator.requestStartupPresentation(publishProfiles: true)
            // Finish the startup task before activation can wait for its retirement.
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runtimeCoordinator.waitUntilSettled()
                await self.monitorRouting()
            }

        }
    }

    func validate(profile: DeviceProfile) async -> ProcessingGraph? {
        do {
            let plan = try await prepareRuntimePlan(profile: profile)
            let graph = plan.processingGraph
            let parsed = try plan.intent.resolvedProcessing().globalEqualizer
            if !warnings.isEmpty { warnings = [] }
            let activeFilterCount = graph.processors.lazy.filter { processor in
                if case .biquad = processor.implementation { return true }
                return false
            }.count
            let processedChannelCount = Set(graph.pipeline.compactMap { step -> Int? in
                if case .channel(let index, _) = step.scope { return index }
                return nil
            }).count
            let channelSummary = processedChannelCount == 0
                ? "global processing only"
                : "\(processedChannelCount) channels with individual processing"
            let message = "Valid: \(graph.pipeline.count) processing stages, \(activeFilterCount) active filters, \(channelSummary), preamp \(String(format: "%.2f", parsed.preampDB)) dB"
            if validationMessage != message { validationMessage = message }
            clearTransientError()
            return graph
        } catch {
            if !validationMessage.isEmpty { validationMessage = "" }
            if !warnings.isEmpty { warnings = [] }
            if errorMessage != error.localizedDescription {
                presentError(error)
            }
            return nil
        }
    }

    var multichannelEditSessions: [UUID: MultichannelHistoryState] {
        get { profiles.multichannelDrafts }
        set { profiles.multichannelDrafts = newValue }
    }
    var multichannelAutosaveTasks: [UUID: Task<Void, Never>] = [:]
    var multichannelAutosaveRevisions: [UUID: UUID] = [:]
    @Published var multichannelAutosaveErrors: [UUID: String] = [:]

    func prepareRuntimePlan(profile: DeviceProfile, reason: String = "validation", parentOperation: PerformanceOperationID? = nil) async throws -> AudioRuntimePlan {
        try await runtimeCoordinator.prepareRuntimePlan(profile: profile, reason: reason, parentOperation: parentOperation)
    }
    @discardableResult
    func compareRuntimePlans(from old: AudioRuntimePlan, to candidate: AudioRuntimePlan, reason: String, parentOperation: PerformanceOperationID? = nil) -> RuntimePlanDelta {
        runtimeCoordinator.compareRuntimePlans(from: old, to: candidate, reason: reason, parentOperation: parentOperation)
    }
    func inspectRuntimePlanDiff() async { await runtimeCoordinator.inspectRuntimePlanDiff() }
    func activate(plan: AudioRuntimePlan, reportErrors: Bool = true,
                  performanceReason: String? = nil, parentOperation: PerformanceOperationID? = nil) async {
        guard !dependencies.setupInProgress else { return }
        await runtimeCoordinator.activate(plan: plan, reportErrors: reportErrors,
            performanceReason: performanceReason, parentOperation: parentOperation)
    }

    /// Spectrum FFT, PCM metering, and telemetry polling are presentation
    /// concerns. The DSP/audio route stays active when no profile editor is on
    /// screen, while these visual-only consumers pause.
    func setRuntimeVisuals(profileID: UUID, active: Bool, meters meterVisible: Bool = true, spectrum spectrumVisible: Bool = true) {
        UIRenderPerformance.recordVisualDemand()
        let previousProfileID = requestedRuntimeVisualProfileID
        if active {
            requestedRuntimeVisualProfileID = profileID
            requestedMeterVisuals = meterVisible
            requestedSpectrumVisuals = spectrumVisible
        } else if requestedRuntimeVisualProfileID == profileID {
            requestedRuntimeVisualProfileID = nil
        }

        if let previousProfileID,
           previousProfileID != requestedRuntimeVisualProfileID {
            spectrum.setPresentationActive(false, profileID: previousProfileID)
            meters.setPresentationActive(false, profileID: previousProfileID)
        }
        guard mainWindowPresentationActive,
              let requestedRuntimeVisualProfileID else { return }
        spectrum.setPresentationActive(requestedSpectrumVisuals, profileID: requestedRuntimeVisualProfileID)
        meters.setPresentationActive(requestedMeterVisuals, profileID: requestedRuntimeVisualProfileID)
    }

    /// The main NSWindow is retained after close, so SwiftUI's onDisappear is
    /// not a reliable signal for stopping presentation-only audio observers.
    /// Gate them with the real AppKit visibility and occlusion state instead.
    func setMainWindowPresentationActive(_ active: Bool) {
        guard mainWindowPresentationActive != active else { return }
        mainWindowPresentationActive = active
        updateMovieAnalysisPresentation()
        perAppAudio.setMeterPresentationSuspended(!active, source: "main")
        guard let requestedRuntimeVisualProfileID else { return }
        spectrum.setPresentationActive(active && requestedSpectrumVisuals, profileID: requestedRuntimeVisualProfileID)
        meters.setPresentationActive(active && requestedMeterVisuals, profileID: requestedRuntimeVisualProfileID)
    }

    func setMovieAnalysisPresentation(profileID: UUID, active: Bool) {
        if active { requestedMovieAnalysisProfileID = profileID }
        else if requestedMovieAnalysisProfileID == profileID { requestedMovieAnalysisProfileID = nil }
        updateMovieAnalysisPresentation()
    }

    private func updateMovieAnalysisPresentation() {
        pcmRouter.setMovieAnalysisPresentationEnabled(mainWindowPresentationActive && activeProfileID != nil
            && requestedMovieAnalysisProfileID == activeProfileID)
    }

    func prepareForDependencyRepair() async -> Bool {
        if let task = startupConfigurationTask {
            task.cancel()
            await task.value
            startupConfigurationTask = nil
        }
        // Stop also supersedes a provisional activation. Await its retirement
        // even when deactivate submitted intent to an already-running worker.
        await deactivate(manual: true, performanceReason: "dependencyRepair")
        await runtimeCoordinator.waitUntilSettled()
        guard !isActive, !transitionInProgress else {
            errorMessage = "CamiTune could not stop the active audio route before repair."
            return false
        }
        return true
    }

    func publishEQDraftChange(for profileID: UUID, started: PerformanceTick? = nil) {
        eqDraftRevision &+= 1
        draftPerformance.removeValue(forKey: profileID)?.finish("coalesced")
        if let operation = performanceRecorder.begin("Live EQ apply", revision: eqDraftRevision, started: started) {
            operation.mark("draft accepted")
            draftPerformance[profileID] = operation
        }
        eqDraftChanges.send(profileID)
    }

    func renameProfile(id: UUID, to requestedName: String) async {
        guard let profile = profiles.profiles.first(where: { $0.id == id }) else { return }
        do {
            try await commitProfileRename(id: id, to: requestedName)
            guard let renamed = profiles.profiles.first(where: { $0.id == id }) else { return }
            history.record(actionName: "Rename Profile", contextName: profile.name, target: .profile(id),
                before: .profileName(profile.name), after: .profileName(renamed.name))
        } catch { errorMessage = error.localizedDescription }
    }

    func commitProfileRename(id: UUID, to requestedName: String) async throws {
        guard profiles.settingsMutationsAllowed, !isSavingProfileSettings else { throw ProfileSettingsError.busy }
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = profiles.profiles.firstIndex(where: { $0.id == id }) else { throw HistoryRestoreError.missingProfile }
        guard profiles.profiles[index].name != name else { return }
        guard ProfileNamePolicy.isAvailable(name, in: profiles.profiles, excluding: id) else {
            throw ProfileSettingsError.runtime("A profile named \"\(name)\" already exists. Profile names must be unique.")
        }
        let previousName = profiles.profiles[index].name
        profiles.profiles[index].name = name
        do {
            try await runtimeCoordinator.synchronizeProfileEndpoints()
            clearTransientError()
        } catch {
            if let current = profiles.profiles.firstIndex(where: { $0.id == id }) { profiles.profiles[current].name = previousName }
            throw error
        }
    }

    func deleteProfileWithHistory(id: UUID) async {
        guard profiles.settingsMutationsAllowed, !isSavingProfileSettings else { return }
        guard let profile = profiles.profiles.first(where: { $0.id == id }) else { return }
        let snapshot = profiles.captureDeletionSnapshot(profileIDs: [id])
        await setProfileEnabled(id: id, enabled: false)
        if activeProfileID == id { await deactivate(manual: true) }
        profiles.deleteProfile(id: id)
        history.record(actionName: "Delete Profile", contextName: profile.name, target: .profileOrganization,
            before: .deletion(snapshot, deleted: false), after: .deletion(snapshot, deleted: true))
        do {
            try await runtimeCoordinator.synchronizeProfileEndpoints()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Delete only the folder membership explicitly shown in the confirmation.
    func deleteProfileFolder(id: UUID, confirmedProfileIDs: Set<UUID>) async -> Bool {
        guard profiles.settingsMutationsAllowed, !isSavingProfileSettings else { return false }
        func stillMatchesConfirmation() -> Bool {
            profiles.folders.contains { $0.id == id }
                && Set(profiles.profiles(in: id).map(\.id)) == confirmedProfileIDs
        }
        guard stillMatchesConfirmation() else {
            errorMessage = "The folder contents changed. Review the folder and confirm deletion again."
            return false
        }
        let deletionSnapshot = profiles.captureDeletionSnapshot(profileIDs: confirmedProfileIDs, folderID: id)
        // Remove eligibility before waiting on a startup or route transition.
        // The existing disable path also restores a selected profile endpoint.
        for profileID in confirmedProfileIDs {
            await setProfileEnabled(id: profileID, enabled: false)
        }
        while transitionInProgress {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if let activeProfileID, confirmedProfileIDs.contains(activeProfileID) {
            await deactivate(manual: true)
        }
        guard stillMatchesConfirmation() else {
            errorMessage = "The folder contents changed. Review the folder and confirm deletion again."
            return false
        }
        profiles.deleteFolder(id: id)
        history.record(actionName: "Delete Folder", target: .profileOrganization,
            before: .deletion(deletionSnapshot, deleted: false), after: .deletion(deletionSnapshot, deleted: true))
        do {
            try await runtimeCoordinator.synchronizeProfileEndpoints()
        } catch {
            errorMessage = "The folder was deleted, but its macOS audio devices could not be updated: \(error.localizedDescription)"
        }
        return true
    }

    func setProfileEnabled(id: UUID, enabled: Bool) async {
        guard !isSavingProfileSettings, profiles.settingsMutationsAllowed else { return }
        guard let profile = profiles.profiles.first(where: { $0.id == id }),
              profile.isEnabled != enabled else { return }

        profiles.setProfileEnabled(profileID: id, enabled: enabled)
        if enabled && profiles.showProfileEnabledExplanation { profileConfirmations.showEnabledExplanation = true }
        // activeProfileID is published only after activation completes. Track
        // the profile currently acquiring the route so disabling it during
        // startup queues a stop instead of letting a disabled profile go live.
        let runtimeProfileID = activatingProfileID ?? activeProfileID
        if !enabled, runtimeProfileID == id {
            await deactivate(manual: false)
        } else {
            // Move away from a disabled profile endpoint before removing it;
            // Core Audio cannot destroy a device while it is the default.
            if !enabled,
               coreAudio.defaultOutputUID.flatMap(ProfileRoutingDescriptor.profileID(from:)) == id,
               coreAudio.cachedDevice(uid: profile.outputDeviceUID) != nil {
                do {
                    try await runtimeCoordinator.synchronizeProfileEndpoints(restoringDisabledProfile: profile)
                } catch {
                    errorMessage = "The profile was disabled, but macOS could not switch back to \(profile.outputDeviceName): \(error.localizedDescription)"
                    return
                }
            }
            do {
                try await runtimeCoordinator.synchronizeProfileEndpoints()
            } catch {
                errorMessage = "The profile was disabled, but its macOS audio device could not be removed: \(error.localizedDescription)"
            }
        }
        if enabled { await monitorRouting() }
    }

    /// Profile creation changes routing policy, so it must pass through the
    /// runtime owner instead of only mutating persistent profile storage.
    @discardableResult
    func addProfile(for device: AudioDeviceInfo) -> UUID? {
        guard let profile = profiles.addProfile(for: device) else { return nil }
        runtimeCoordinator.resetAutomaticPolicy(outputUID: device.id)
        Task { [weak self] in
            await self?.monitorRouting()
        }
        return profile.id
    }

    func addProfile(from draft: AddOutputDraft) async throws -> UUID {
        guard !isSavingProfileSettings, !transitionInProgress else { throw ProfileSettingsError.busy }
        var candidate = try draft.candidate()
        candidate.resolveAudioBuffer(default: profiles.audioBufferDefault)
        _ = try await prepareRuntimePlan(profile: candidate)
        guard !isSavingProfileSettings, !transitionInProgress,
              await runtimeServices.resolveOutput(candidate.outputDeviceUID) != nil else {
            throw ProfileSettingsError.runtime("The audio device changed. Check its connection and try again.")
        }
        let generation = runtimeCoordinator.desiredRuntime.generation
        let id = try await profiles.insertConfiguredProfile(candidate)
        if runtimeCoordinator.desiredRuntime.generation == generation {
            runtimeCoordinator.resetAutomaticPolicy(outputUID: candidate.outputDeviceUID)
            Task { @MainActor [weak self] in await self?.monitorRouting() }
        }
        return id
    }

    private func startAutomaticBufferObservation() {
        automaticBufferTask?.cancel()
        automaticBufferTask = Task { @MainActor [weak self] in
            var observedRevision: RuntimeIntentRevision?
            var observedSession: UUID?
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                guard !self.transitionInProgress, self.spatialCalibrationContext == nil,
                      let profile = self.runtimeCoordinator.appliedProfile,
                      !profile.usesExclusivePluginOutput,
                      self.profiles.profiles.first(where: { $0.id == profile.id })?.audioBufferSetting == .automatic,
                      let session = self.activeSession?.id, let revision = self.acknowledgedPlanRevision else {
                    _ = self.pcmRouter.takeAudioBufferWork()
                    self.automaticBuffers.end(); observedRevision = nil; observedSession = nil
                    continue
                }
                if observedRevision != revision || observedSession != session {
                    self.automaticBuffers.begin(profile: profile)
                    _ = self.pcmRouter.takeAudioBufferWork()
                    observedRevision = revision; observedSession = session
                    continue
                }
                let work = await self.processingBackend.measureWork()
                guard !Task.isCancelled, self.activeSession?.id == session,
                      self.acknowledgedPlanRevision == revision, !self.transitionInProgress,
                      self.spatialCalibrationContext == nil,
                      self.profiles.profiles.first(where: { $0.id == profile.id })?.audioBufferSetting == .automatic else {
                    observedRevision = nil; continue
                }
                self.automaticBuffers.observe(work: self.pcmRouter.takeAudioBufferWork(), dspLoadPercent: work.loadPercent,
                    clockEpoch: work.clockEpoch, underrunFrames: work.underrunFrames,
                    droppedFrames: self.pcmRouter.statistics.camillaDroppedFrames)
            }
        }
    }

    private func finishSavingSettings() {
        isSavingProfileSettings = false
        if pendingSettingsLiveApply {
            pendingSettingsLiveApply = false
            Task { @MainActor [weak self] in
                guard let self, self.isActive,
                      let current = self.profiles.profiles.first(where: { $0.id == self.activeProfileID }),
                      let latest = try? self.applyingSessionEQDrafts(to: current) else { return }
                await self.apply(profile: latest)
            }
        }
    }

    func saveGlobalAudioBuffer(_ frames: AudioBufferSetting, inheritingProfileIDs: Set<UUID> = []) async throws {
        guard !isSavingProfileSettings, !profiles.hasDurableCommit, !transitionInProgress,
              !runtimeCoordinator.hasLiveApplyWork, spatialCalibrationContext == nil else {
            throw ProfileSettingsError.busy
        }
        guard frames.isSupported else {
            throw ProfileSettingsError.runtime("Choose a supported audio buffer size.")
        }
        isSavingProfileSettings = true
        defer { finishSavingSettings() }
        let oldDefault = profiles.audioBufferDefault
        let draftRevision = eqDraftRevision
        // Reconfigure the live profile only when it follows this default.
        guard let original = profiles.profiles.first(where: { $0.id == activeProfileID }),
              original.usesGlobalAudioBuffer || inheritingProfileIDs.contains(original.id) else {
            try await profiles.commitAudioBufferDefault(frames, inheritingProfileIDs: inheritingProfileIDs)
            await runtimeCoordinator.refreshAudioBuffer(from: profiles.profiles)
            return
        }
        let activation = profiles.activationMode(for: original)
        var candidate = original
        if inheritingProfileIDs.contains(candidate.id) { candidate.audioBufferOverride = nil }
        candidate.resolveAudioBuffer(default: frames)
        let newRuntime = try applyingSessionEQDrafts(to: candidate)
        func validatePersistence() throws {
            guard oldDefault == self.profiles.audioBufferDefault, draftRevision == self.eqDraftRevision else {
                throw ProfileSettingsError.busy
            }
            try self.profiles.validateSettingsSnapshot(original, activation: activation)
        }
        let receipt = try await runtimeCoordinator.applySettingsCandidate(original: original, newRuntime: newRuntime,
            operation: nil, validatePersistence: validatePersistence)
        do {
            try validatePersistence()
            try runtimeCoordinator.validate(receipt)
            try await profiles.commitAudioBufferDefault(frames, inheritingProfileIDs: inheritingProfileIDs)
            runtimeCoordinator.persistenceCommitted(receipt)
            await runtimeCoordinator.refreshAudioBuffer(from: profiles.profiles)
        } catch {
            let failure = error
            do { _ = try await runtimeCoordinator.persistenceFailed(receipt) }
            catch { throw ProfileSettingsError.rollback(failure.localizedDescription, error.localizedDescription) }
            throw failure
        }
    }

    func saveProfileSettings(_ draft: ProfileSettingsDraft) async throws {
        guard !isSavingProfileSettings, !profiles.hasDurableCommit, !transitionInProgress, !runtimeCoordinator.hasLiveApplyWork,
              spatialCalibrationContext == nil else { throw ProfileSettingsError.busy }
        let operation = performanceRecorder.begin("Profile Save", reason: "settingsTransaction")
        var performanceResult = "failed"
        defer { operation?.finish(performanceResult) }
        let draftRevision = eqDraftRevision
        isSavingProfileSettings = true
        defer { finishSavingSettings() }
        if let preview = try? draft.preview(), !preview.isSectionEnabled(.plugins) && !preview.usesExclusivePluginOutput {
            await pluginRackManager.flushEditors(profileID: draft.original.id, close: false)
        }
        guard let original = profiles.profiles.first(where: { $0.id == draft.original.id }) else { throw ProfileSettingsError.staleDraft }
        let originalActivation = profiles.activationMode(for: original)
        guard draft.activation == draft.originalActivation || originalActivation == draft.originalActivation || originalActivation == draft.activation else { throw ProfileSettingsError.staleDraft }
        let activation = draft.activation == draft.originalActivation ? originalActivation : draft.activation
        var candidate = try draft.candidate(applyingTo: original)
        let changingDeviceType = candidate.endpointKind != original.endpointKind
            || candidate.effectiveEndpointKind != original.effectiveEndpointKind
        if changingDeviceType {
            // Save pending tuning with the outgoing context, never overlay it
            // onto the incoming device's freshly selected configuration.
            candidate = try draft.candidate(applyingTo: applyingSessionEQDrafts(to: original))
        }
        candidate.resolveAudioBuffer(default: profiles.audioBufferDefault)
        candidate.autoActivateWhenProfileDeviceSelected = activation == .profileAudioDevice
        let newRuntime = changingDeviceType ? candidate : try applyingSessionEQDrafts(to: candidate, replacingGlobalEqualizer: draft.replacesUserEqualizer)
        func validatePersistence() throws {
            guard draftRevision == self.eqDraftRevision else { throw ProfileSettingsError.busy }
            try self.profiles.validateSettingsSnapshot(original, activation: originalActivation)
        }
        let receipt = try await runtimeCoordinator.applySettingsCandidate(original: original, newRuntime: newRuntime,
            operation: operation, validatePersistence: validatePersistence)
        var resolution = RuntimePersistenceResolution.superseded
        do {
            try validatePersistence()
            try runtimeCoordinator.validate(receipt)
            operation?.mark("persistence begins")
            _ = try await profiles.commitSettings(candidate, expected: original,
                originalActivation: originalActivation, activation: activation)
            operation?.mark("persistence complete")
            resolution = runtimeCoordinator.persistenceCommitted(receipt)
            operation?.mark("runtime persistence finalization")
        } catch {
            let failure = error
            do { _ = try await runtimeCoordinator.persistenceFailed(receipt) }
            catch { throw ProfileSettingsError.rollback(failure.localizedDescription, error.localizedDescription) }
            throw failure
        }
        if changingDeviceType {
            invalidateDeferredEdits()
            clearEQDraft(for: candidate.id)
            processingDrafts[candidate.id] = nil
            referenceCorrectionSessions[candidate.id] = nil
            speakerEditSessions[candidate.id] = nil
            multichannelEditSessions[candidate.id] = nil
            multichannelAutosaveErrors[candidate.id] = nil
            clearPendingEditorApply(candidate.id)
            history.discardDeviceConfiguration(for: candidate.id)
            equalizerReplacementChanges.send(candidate.id)
        } else if draft.replacesUserEqualizer && eqDraftRevision == draftRevision {
            clearEQDraft(for: candidate.id)
            equalizerReplacementChanges.send(candidate.id)
        }
        if resolution == .finalizedCurrentRuntime && (activation != originalActivation || candidate.outputDevice != original.outputDevice) {
            runtimeCoordinator.resetAutomaticPolicy(outputUID: candidate.outputDeviceUID)
        }
        if !candidate.isSectionEnabled(.plugins) && !candidate.usesExclusivePluginOutput {
            pluginRackManager.retireHiddenSection(profileID: candidate.id)
        }
        operation?.mark("final publication")
        performanceResult = "success"
    }

    func setPersonalSpatial(profileID: UUID, settings: PersonalSpatialSettings, expectedContext: String, recordHistory: Bool = true) async throws {
        guard let profile = profiles.profiles.first(where: { $0.id == profileID }), profile.isPersonalListening,
              expectedContext == profile.deviceTypeConfigurationKey else {
            throw ProfileSettingsError.runtime("The playback device changed. Reopen Spatial and try again.")
        }
        var draft = ProfileSettingsDraft(profile: profile, activation: profiles.activationMode(for: profile))
        draft.personalSpatial = settings
        try await saveProfileSettings(draft)
        if recordHistory {
            history.record(actionName: "Adjust Virtual Speakers", contextName: profile.name, target: .profile(profileID),
                before: .personalSpatial(context: profile.deviceTypeConfigurationKey, settings: profile.personalSpatial),
                after: .personalSpatial(context: profile.deviceTypeConfigurationKey, settings: settings))
        }
    }

    func setPlaybackMode(profileID: UUID, mode: PlaybackMode) async {
        guard let profile = profiles.profiles.first(where: { $0.id == profileID }),
              profile.availablePlaybackModes.contains(mode) else { return }
        guard profile.playbackReadiness(mode).isReady else { presentError(ProfileSettingsError.runtime(profile.playbackReadiness(mode).reason ?? "Configure this mode first.")); return }
        var draft = ProfileSettingsDraft(profile: profile, activation: profiles.activationMode(for: profile))
        draft.requestedMode = mode
        do { try await saveProfileSettings(draft) }
        catch { presentError(error) }
    }

    func setActivationMode(profileID: UUID, mode: ProfileActivationMode) async {
        guard !isSavingProfileSettings, profiles.settingsMutationsAllowed else { return }
        guard let profile = profiles.profiles.first(where: { $0.id == profileID }) else { return }
        switch mode {
        case .physicalOutput:
            await setAutomaticProfile(for: profile.outputDevice, profileID: profileID)
        case .profileAudioDevice:
            await setAutoActivateWhenProfileDeviceSelected(id: profileID, enabled: true)
        case .manual:
            if profiles.activationMode(for: profile) == .physicalOutput {
                await setAutomaticProfile(for: profile.outputDevice, profileID: nil)
            }
            await setAutoActivateWhenProfileDeviceSelected(id: profileID, enabled: false)
        }
    }

    func profileDeactivationRequiresConfirmation(profileID: UUID) -> Bool {
        guard !profiles.hasDurableCommit,
              let profile = profiles.profiles.first(where: { $0.id == profileID }) else { return false }
        return profiles.activationMode(for: profile) == .physicalOutput
    }

    /// Shared by profile controls in the sidebar and menus.
    func setProfileRuntimeActive(profileID: UUID, active: Bool, physicalOutputConfirmed: Bool = false) async {
        guard !transitionInProgress, spatialCalibrationContext == nil,
              let profile = profiles.profiles.first(where: { $0.id == profileID }) else { return }
        if active {
            guard profile.isEnabled, !(isActive && activeProfileID == profileID) else { return }
            await activate(profile: profile)
        } else {
            await deactivateProfileFromMenu(profileID: profileID, physicalOutputConfirmed: physicalOutputConfirmed)
        }
    }

    /// The confirmation is tied to a profile ID; revalidate it before any write.
    func deactivateProfileFromMenu(profileID: UUID, physicalOutputConfirmed: Bool) async {
        guard !transitionInProgress, isActive, activeProfileID == profileID,
              let profile = profiles.profiles.first(where: { $0.id == profileID }) else { return }
        // Stop remains available while another document commit is pending.
        // Its existing manual-stop suppression preserves the stored policy.
        if profiles.hasDurableCommit {
            await deactivate(manual: true)
            return
        }
        let mode = profiles.activationMode(for: profile)
        let generation = runtimeCoordinator.desiredRuntime.generation
        let session = activeSession?.id
        if mode == .physicalOutput {
            guard physicalOutputConfirmed else { return }
            do { _ = try await profiles.commitMenuDeactivationPolicy(profileID: profileID) }
            catch { errorMessage = error.localizedDescription; return }
            // The policy may commit after a separate Stop/switch. It has no
            // authority to stop the newer runtime that appeared during I/O.
            guard runtimeCoordinator.desiredRuntime.generation == generation,
                  activeSession?.id == session, activeProfileID == profileID else { return }
        }
        if mode != .manual {
            runtimeCoordinator.preferPhysicalOutputRestoration(profile.outputDeviceUID)
        }
        await deactivate(manual: true)
    }

    func setAutomaticProfile(
        for physicalDevice: PhysicalOutputIdentity,
        profileID: UUID?
    ) async {
        guard profiles.settingsMutationsAllowed, !isSavingProfileSettings else { return }
        runtimeCoordinator.resetAutomaticPolicy(outputUID: physicalDevice.uid)
        profiles.setAutomaticProfile(physicalDevice: physicalDevice, profileID: profileID)
        if let profileID {
            profiles.setAutoActivateWhenProfileDeviceSelected(profileID: profileID, enabled: false)
        }
        if profileID != nil { await monitorRouting() }
    }

    func setAutoActivateWhenProfileDeviceSelected(id: UUID, enabled: Bool) async {
        guard profiles.settingsMutationsAllowed, !isSavingProfileSettings else { return }
        runtimeCoordinator.resetAutomaticPolicy()
        guard let profile = profiles.profiles.first(where: { $0.id == id }) else { return }
        if enabled,
           profiles.automaticProfileID(forPhysicalDeviceUID: profile.outputDeviceUID) == id {
            profiles.setAutomaticProfile(physicalDevice: profile.outputDevice, profileID: nil)
        }
        profiles.setAutoActivateWhenProfileDeviceSelected(profileID: id, enabled: enabled)

        if !enabled,
           !isActive,
           coreAudio.defaultOutputUID.flatMap(ProfileRoutingDescriptor.profileID(from:)) == id,
           coreAudio.cachedDevice(uid: profile.outputDeviceUID) != nil {
            try? await runtimeCoordinator.synchronizeProfileEndpoints(restoringDisabledProfile: profile)
        }
        if enabled { await monitorRouting() }
        else {
            try? await runtimeCoordinator.synchronizeProfileEndpoints()
        }
    }

    /// Output changes use the same staged validation and rollback as Profile Settings.
    func setOutputDevice(profileID: UUID, device: AudioDeviceInfo) async {
        guard !device.isRoutingDevice,
              let current = profiles.profiles.first(where: { $0.id == profileID }) else { return }
        var draft = ProfileSettingsDraft(profile: current, activation: profiles.activationMode(for: current))
        draft.outputDevice = PhysicalOutputIdentity(uid: device.id, name: device.name)
        do { try await saveProfileSettings(draft) }
        catch { presentError(error) }
    }

    func activate(
        profile: DeviceProfile,
        reportErrors: Bool = true,
        automatic: Bool = false,
        performanceReason: String? = nil,
        parentOperation: PerformanceOperationID? = nil,
        preparedPlan: AudioRuntimePlan? = nil
    ) async {
        guard !dependencies.setupInProgress else { return }
        await runtimeCoordinator.activate(profile: profile, reportErrors: reportErrors, automatic: automatic,
            performanceReason: performanceReason,
            parentOperation: parentOperation, preparedPlan: preparedPlan)
    }

    func beginSpatialCalibration(profileID: UUID, roomMeasurement: Bool = false) -> SpatialCalibrationContext? {
        guard directOutput == nil else {
            errorMessage = "Use Through CamillaDSP to measure or calibrate this profile."
            return nil
        }
        guard isActive, !transitionInProgress, !runtimeCoordinator.hasLiveApplyWork, spatialCalibrationContext == nil,
              let session = activeSession, session.profileID == profileID,
              let rate = activeSampleRate,
              coreAudio.defaultOutputUID == activeRoutingUID,
              let profile = profiles.profiles.first(where: { $0.id == profileID }),
              (profile.effectiveSpatialRenderingMode == .spatialAudio || profile.usesReferenceSpeakers || (roomMeasurement && (try? profile.validatedPhysicalSpeakerTopology()) != nil)),
              profile.outputDeviceUID == activePhysicalOutputUID else { return nil }
        let context = SpatialCalibrationContext(
            id: UUID(), runtimeSessionID: session.id, profileID: profileID,
            outputDeviceUID: profile.outputDeviceUID, sampleRate: Double(rate)
        )
        // Spatial mode is a local PCM setting. Do not let a pending graph RPC
        // leave the first audition in the previously selected Standard mode.
        pcmRouter.setSpatialRenderingMode(profile.effectiveSpatialRenderingMode)
        pcmRouter.setSpatialSettings(profile.effectiveSpatialSettings, output: profile.effectiveSpatialSettings.resolvedOutput(deviceName: profile.outputDeviceName))
        guard pcmRouter.beginSpatialCalibration(id: context.id) else {
            return nil
        }
        spatialCalibrationContext = context
        return context
    }

    func playSpatialCalibration(
        context: SpatialCalibrationContext, clip: SpatialCalibrationClip, levelCheckGain: Float = 1,
        started: (@Sendable (TimeInterval) -> Void)? = nil,
        completion: @escaping @Sendable () -> Void
    ) -> Bool {
        guard spatialCalibrationContext == context, activeSession?.id == context.runtimeSessionID,
              isActive, !transitionInProgress, activePhysicalOutputUID == context.outputDeviceUID,
              coreAudio.defaultOutputUID == activeRoutingUID,
              Double(activeSampleRate ?? 0) == clip.sampleRate else { return false }
        return pcmRouter.playSpatialCalibration(
            id: context.id, clip: clip, levelCheckGain: levelCheckGain, started: started, completion: completion
        )
    }

    func setLevelCheckGain(context: SpatialCalibrationContext, gain: Float) {
        guard spatialCalibrationContext == context, activeSession?.id == context.runtimeSessionID,
              isActive, !transitionInProgress else { return }
        pcmRouter.setLevelCheckGain(id: context.id, gain: gain)
    }

    func holdSpatialMeasurement(context: SpatialCalibrationContext, enabled: Bool) {
        guard spatialCalibrationContext == context else { return }
        pcmRouter.holdSpatialMeasurement(id: context.id, enabled: enabled)
    }

    var acousticVolumeSnapshot: SystemVolumeControlSession.Snapshot? { runtimeCoordinator.volumeSnapshot }


    func endSpatialCalibration(id: UUID) {
        guard spatialCalibrationContext?.id == id else { return }
        pcmRouter.endSpatialCalibration(id: id)
        runtimeCoordinator.restoreRenderConfiguration()
        spatialCalibrationContext = nil
    }


    func sectionNeedsDisableConfirmation(_ section: ProfileSection, profile: DeviceProfile) -> Bool {
        let runtime = (try? applyingSessionEQDrafts(to: profile)) ?? profile
        if runtime.hasEnabledProcessing(in: section) { return true }
        guard activeProfileID == profile.id, profile.isSectionEnabled(section) else { return false }
        if section == .meters || section == .spectrum { return true }
        if section == .mode {
            let context = PerAppPlaybackContext(profile: profile)
            return perAppAudio.applications.contains {
                context.effectiveMode(for: $0.settings.playbackModeOverride) != .direct
            }
        }
        return false
    }

    func applySectionLayoutToActiveProfile() {
        guard let profile = profiles.profiles.first(where: { $0.id == activeProfileID }) else { return }
        Task {
            if !profile.isSectionEnabled(.plugins) && !profile.usesExclusivePluginOutput {
                await pluginRackManager.flushEditors(profileID: profile.id, close: false)
            }
            guard let current = profiles.profiles.first(where: { $0.id == profile.id }) else { return }
            await apply(profile: current)
            if !current.isSectionEnabled(.plugins) && !current.usesExclusivePluginOutput { pluginRackManager.retireHiddenSection(profileID: current.id) }
        }
    }

    func apply(profile: DeviceProfile) async {
        guard !isSavingProfileSettings else { pendingSettingsLiveApply = true; return }
        let operation = draftPerformance.removeValue(forKey: profile.id)
            ?? performanceRecorder.begin("Live EQ apply", revision: eqDraftRevision)
        await runtimeCoordinator.apply(profile: profile, performanceOperation: operation)
    }
    func deactivate(manual: Bool = true, restoreOutput: Bool = true,
                    performanceReason: String = "user", parentOperation: PerformanceOperationID? = nil,
                    performanceOperation: PerformanceOperation? = nil) async {
        await runtimeCoordinator.deactivate(manual: manual, restoreOutput: restoreOutput,
            performanceReason: performanceReason,
            parentOperation: parentOperation, performanceOperation: performanceOperation)
    }

    func monitorRouting() async { await runtimeCoordinator.monitorRouting() }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        shutdownSynchronously()
        do { try RoomMeasurementStore().removeUnreferencedRecordings() }
        catch { NSLog("Room recording cleanup will be retried at the next quit: %@", error.localizedDescription) }
    }

    func shutdownSynchronously() {
        guard !hasShutdown else { return }
        hasShutdown = true
        automaticBufferTask?.cancel(); automaticBufferTask = nil
        monitorTimer?.invalidate(); monitorTimer = nil
        startupConfigurationTask?.cancel(); startupConfigurationTask = nil
        cancelMultichannelAutosaves()
        pluginReorderApplies.cancelPending()
        pluginRackManager.flushForTermination()
        profiles.shutdownSynchronously()
        runtimeCoordinator.shutdownSynchronously()
        pluginRackManager.stopForTermination()
        perAppAudio.flushPendingSaveSynchronously()
    }

    /// Successful transient operations must not hide a profile-store failure
    /// published during the same edit.
    func clearTransientError() {
        let next = profiles.persistenceError
        if errorMessage != next { errorMessage = next }
    }

    enum AppError: LocalizedError {
        case missingCamillaDSP
        case missingRoutingDriver
        case outdatedRoutingDriver
        case unsupportedRoutingLayout
        case outputMissing(String)
        case invalidTarget
        case profileDisabled(String)
        case profileRoutingDeviceMissing(String)
        case unsupportedSampleRate(Int, String)
        case camillaDSPCoreAudioUIDUnsupported
        case runtimeSampleRateMismatch(expected: Int, actual: Double, device: String)
        var recovery: AppErrorRecovery? {
            switch self {
            case .missingCamillaDSP, .missingRoutingDriver, .outdatedRoutingDriver,
                 .unsupportedRoutingLayout, .camillaDSPCoreAudioUIDUnsupported:
                return .openSetup
            default: return nil
            }
        }
        var errorDescription: String? {
            switch self {
            case .missingCamillaDSP: return "CamillaDSP is not installed. Open Setup and install it first."
            case .missingRoutingDriver: return "System Audio Bridge is not installed or visible to CoreAudio. Open Setup to install the bundled driver."
            case .outdatedRoutingDriver: return "The installed audio routing driver is outdated. Open Setup and select Install / Repair Everything."
            case .unsupportedRoutingLayout: return "The installed audio routing driver does not expose a supported 2.0, 5.1, or 7.1 LPCM layout. Open Setup and select Install / Repair Everything."
            case .outputMissing(let name): return "The selected output device is not connected: \(name)"
            case .invalidTarget: return "The virtual routing device cannot be used as the physical playback target."
            case .profileDisabled(let name): return "Enable the \(name) profile before using its activation conditions."
            case .profileRoutingDeviceMissing(let name): return "CoreAudio did not create the \(name) profile audio device."
            case .unsupportedSampleRate(let rate, let device): return "\(device) does not report support for the selected \(Double(rate) / 1000) kHz sample rate."
            case .camillaDSPCoreAudioUIDUnsupported:
                return "The installed CamillaDSP build cannot select Core Audio devices by UID. Open Setup and select Install / Repair Everything."
            case .runtimeSampleRateMismatch(let expected, let actual, let device):
                return "\(device) changed to \(String(format: "%.1f", actual / 1_000)) kHz while this profile requires \(String(format: "%.1f", Double(expected) / 1_000)) kHz. Processing was stopped to prevent wrong-speed or corrupted audio."
            }
        }
    }
}

// Composition root: adapters share the existing managers; the coordinator owns sequencing.
extension AppState {
    var volumeHandoffSummary: String { captureBackend.controlSummary }
    var coreAudioSummary: String {
        "Snapshot revision: \(coreAudio.snapshot.revision) • Outputs: \(coreAudio.outputDevices.count)\nInitial snapshot: \(coreAudio.hasCompletedInitialRefresh)\nFull refreshes: \(coreAudioService.refreshCount) • Coalesced: \(coreAudioService.coalescedRefreshCount) • Recovery: \(coreAudioService.recoveryRefreshCount)\nLast full refresh: \(String(format: "%.2f", coreAudioService.lastRefreshMilliseconds)) ms\n" + coreAudio.diagnostics
    }
    private func makeLiveCaptureBackend() -> any AudioCaptureBackend {
        SystemAudioBridgeCaptureBackend(coreAudio: coreAudioService, performanceRecorder: performanceRecorder,
            onVolume: { [weak self] profileID, ownershipID, scalar in
                guard let self, self.runtimeCoordinator.owns(ownershipID) else { return }
                self.profiles.setOutputVolumeScalar(profileID: profileID, scalar: scalar)
            },
            onMasterGain: { [pcmRouter] gain, muted in pcmRouter.setSystemMaster(linearGain: gain, muted: muted) },
            onMirrorFailure: { [weak self] in self?.runtimeCoordinator.reportVolumeMirrorFailure(ownershipID: $0) })
    }

    private func makeLiveRuntimeServices() -> AudioRuntimeServices {
        coreAudioService.performanceRecorder = performanceRecorder
        return AudioRuntimeServices(
            startDirectOutput: { [unowned self] plan in
                guard let device = await coreAudioService.resolveDeviceWithoutBlockingUI(uid: plan.hardwareEvidence.output.uid) else {
                    throw AppError.outputMissing(plan.hardwareEvidence.output.name)
                }
                let output = try await Task.detached(priority: .userInitiated) {
                    try DirectCoreAudioOutput(deviceID: device.objectID, sampleRate: Double(plan.sourceFormat.sampleRate),
                        inputChannels: plan.dspInputFormat.channelCount, outputChannels: plan.hardwareOutputFormat.channelCount,
                        channelMap: plan.directOutputChannelMap, requestedFrames: plan.processingGraph.chunkSize)
                }.value
                directOutput = output; directOutputError = nil
            },
            directOutputNeedsRecovery: { [unowned self] in
                guard let output = directOutput, captureBackend.runtimeError == nil else { return false }
                return output.snapshot().error != nil || pcmRouter.statistics.camillaWriteFailures > 0
            },
            preparePluginRack: { [unowned self] in try await pluginRackManager.prepare($0) },
            commitPluginRack: { [unowned self] in pcmRouter.setPluginProcessor(pluginRackManager.commit($0)) },
            freshDefaultOutput: { [coreAudioService] in await coreAudioService.readDefaultOutputWithoutBlockingUI() },
            physicalOutputs: { [coreAudioService] in coreAudioService.physicalOutputDevices },
            automaticBufferSize: { [unowned self] in automaticBuffers.recommendedFrames(for: $0) },
            synchronous: .init(
                stopPCM: { [unowned self] in pcmRouter.stop(); pluginRackManager.stop() },
                closeEngineInput: { [unowned self] in processingBackend.closeInputSynchronously() },
                stopSpectrum: { [spectrum] in spectrum.stop() },
                stopEngine: { [unowned self] in
                    directOutputClockTask?.cancel(); directOutputClockTask = nil
                    directOutput?.stop(); directOutput = nil; directOutputError = nil
                    processingBackend.stopSynchronously()
                },
                setDefaultOutput: { [coreAudioService] in try coreAudioService.setDefaultOutput(uid: $0) }),
            refreshDependencies: { [unowned self] in await dependencies.refreshWithoutBlockingUI() },
            prepareAssets: { profile in
                let directory = CamiTunePaths.impulseResponsesDirectory
                return try await Task.detached(priority: .userInitiated) {
                    try PreparedRuntimeAssets.prepare(profile: profile, directory: directory)
                }.value
            },
            captureBackend: captureBackend,
            processingBackend: processingBackend,
            resolveOutput: { [unowned self] in await coreAudioService.resolveDeviceWithoutBlockingUI(uid: $0) },
            probeTopology: { [coreAudioService] output in try await coreAudioService.probeSpeakerTopology(uid: output.id) },
            outputChannelCount: { [coreAudioService] output in try await coreAudioService.outputChannelCount(uid: output.id) },
            supportsRate: { [unowned self] in await coreAudioService.supportsSampleRateWithoutBlockingUI(uid: $0, rate: $1) },
            defaultOutput: { [unowned self] in coreAudioService.defaultOutputUID },
            cachedDevice: { [unowned self] in coreAudioService.cachedDevice(uid: $0) },
            hasSnapshot: { [unowned self] in coreAudioService.hasCompletedInitialRefresh },
            nominalRate: { [unowned self] in await coreAudioService.nominalSampleRateWithoutBlockingUI(uid: $0) },
            setDefaultOutput: { [unowned self] in try await coreAudioService.setDefaultOutputAndWait(uid: $0) },
            startObservations: { [unowned self] runtimeSession in
                meters.start(
                    backend: directOutput == nil ? processingBackend : nil,
                    session: runtimeSession,
                    directOutput: directOutput,
                    routeDiagnosticsProvider: { [captureBackend, pcmRouter] in
                        AudioRouteDiagnostics(
                            transport: captureBackend.statistics,
                            router: pcmRouter.statistics
                        )
                    }
                )
            },
            startPCM: { [unowned self] plan, runtimeSession in
                startAutomaticBufferObservation()
                pcmRouter.performanceSource.setSession(runtimeSession.id)
                try await pluginRackManager.prepare(plan)
                let pluginProcessor = pluginRackManager.commit(plan)
                let sink: any PCMOutputSink
                if plan.usesExclusivePluginOutput {
                    guard let output = directOutput else { throw CancellationError() }
                    sink = output
                } else {
                    sink = try processingBackend.makeInputSink()
                }
                await pcmRouter.start(sink: sink, activeRoute: plan.route,
                    renderConfiguration: plan.renderConfiguration, deliveryConfiguration: plan.deliveryConfiguration,
                    backendChunkFrames: plan.processingGraph.chunkSize,
                    referenceTopology: plan.referenceTopology,
                    pluginProcessor: pluginProcessor,
                    meterConsumer: meters.pcmConsumer(for: runtimeSession),
                    meterAdmission: meters.pcmAdmission(for: runtimeSession),
                    analyzerConsumer: { [weak spectrum] frame in
                        spectrum?.ingest(interleaved: frame.interleaved, channelCount: frame.channelCount,
                            sampleRate: frame.sampleRate, session: runtimeSession)
                    },
                    analyzerAdmission: spectrum.pcmAdmission(for: runtimeSession),
                    analyzerBatchFrames: spectrum.analysisHopFrames)
                if let output = directOutput {
                    let consume = pcmRouter.playbackClockConsumer()
                    directOutputClockTask = Task { @MainActor [weak self] in
                        while !Task.isCancelled {
                            let snapshot = output.snapshot()
                            if let clock = snapshot.clock { consume(clock) }
                            self?.directOutputError = snapshot.error
                            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                        }
                    }
                } else if plan.deliveryConfiguration.queue.rateTargetMode == .clockTracked {
                    processingBackend.observePlaybackClock(session: runtimeSession.id, consumer: pcmRouter.playbackClockConsumer())
                }
            },
            applyRenderConfiguration: { [unowned self] in pcmRouter.setRenderConfiguration($0) },
            applyPCMDeliveryConfiguration: { [unowned self] configuration in
                pcmRouter.setDeliveryConfiguration(configuration)
                if directOutput == nil, configuration.queue.rateTargetMode == .clockTracked, let session = runtimeCoordinator.activeSession {
                    processingBackend.observePlaybackClock(session: session.id, consumer: pcmRouter.playbackClockConsumer())
                } else { processingBackend.stopClockObservations() }
            },
            startSpectrum: { [unowned self] in await spectrum.start(session: $0, sourceName: captureBackend.name) },
            stopObservations: { [unowned self] in meters.stop() },
            stopPCM: { [unowned self] in
                directOutputClockTask?.cancel(); directOutputClockTask = nil
                automaticBufferTask?.cancel(); automaticBufferTask = nil
                automaticBuffers.end()
                processingBackend.stopClockObservations()
                await pluginRackManager.flushBeforeStopping()
                await pcmRouter.stopWithoutBlockingUI()
                pluginRackManager.stop()
                pcmRouter.performanceSource.setSession(nil)
            },
            closeEngineInput: { [unowned self] in await processingBackend.closeInput() },
            stopSpectrum: { [unowned self] in await spectrum.stopWithoutBlockingUI() },
            stopEngine: { [unowned self] in
                if let output = directOutput {
                    directOutput = nil; directOutputError = nil
                    await Task.detached(priority: .userInitiated) { output.stop() }.value
                }
                await processingBackend.stop()
            },
            deliveryError: { [unowned self] in pcmRouter.statistics.deliveryError ?? directOutputError },
            notifyActivation: { [unowned self] in notifications.activated() },
            notifyDeactivation: { [unowned self] in notifications.deactivated() },
            sleep: { try await Task.sleep(for: $0) },
            transitionFinished: { _ in }
        )
    }
}

extension AppState {
    func performanceEnvironment() -> PerformanceEnvironment {
        // Measure the configuration acknowledged by both engines, which may
        // differ from a saved/draft profile while reconciliation is pending.
        let profile = runtimeCoordinator.appliedProfile
        let statistics = pcmRouter.statistics
        let telemetry = meters.status
        let fresh = telemetry.hasFreshTelemetry()
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return PerformanceEnvironment(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unavailable",
            configuration: configuration, gitCommit: Bundle.main.object(forInfoDictionaryKey: "CamiTuneGitCommit") as? String,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString, architecture: architecture,
            outputName: profile?.outputDeviceName, outputUID: activePhysicalOutputUID, sessionID: activeSession?.id,
            sampleRate: activeSampleRate, channelCount: activeAudioRoute?.sourceFormat.channelCount,
            playbackMode: profile?.playbackMode.rawValue, spatialMode: profile?.effectiveSpatialRenderingMode.rawValue,
            processingStages: profile.map { $0.processing.global.stages.count + $0.processing.channels.reduce(0) { $0 + $1.chain.stages.count } },
            chunkSize: profile?.chunkSize, activeApplications: perAppAudio.applications.filter(\.isActive).count,
            windowVisible: mainWindowPresentationActive,
            profileVisible: mainWindowPresentationActive && requestedRuntimeVisualProfileID == activeProfileID && activeProfileID != nil,
            telemetryHealth: String(describing: telemetry.telemetryAssessment().health),
            dspLoad: fresh ? telemetry.processingLoadPercent : nil, dspBufferFrames: fresh ? telemetry.outputBufferedFrames : nil,
            dspResamplerLoad: fresh ? telemetry.resamplerLoadPercent : nil, queue: statistics.camillaQueue,
            recoveries: statistics.camillaQueueRecoveries, droppedFrames: statistics.camillaDroppedFrames,
            transportDroppedFrames: captureBackend.statistics.droppedFrames, processCPUSeconds: RuntimePerformanceRecorder.cpuSeconds(),
            presentationStatistics: perAppAudio.presentationStatistics,
            timelineMixerStatistics: perAppAudio.timelineStatisticsSnapshot(),
            writerRateAdjustmentPPM: statistics.rateAdjustmentPPM,
            writerRateBufferedFrames: statistics.rateMatchBufferedFrames,
            deliveryConfiguration: runtimeCoordinator.activeDeliveryConfiguration,
            producerCompletion: captureBackend.statistics.completion, playbackClock: processingBackend.playbackClock,
            deliveryError: captureBackend.runtimeError ?? statistics.deliveryError,
            producerDrains: statistics.producerDrains)
    }
}
