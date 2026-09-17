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
    func invalidateDeferredEdits() { editGeneration &+= 1 }
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
    @Published private(set) var isValidating = false
    /// Draft edits are intentionally kept out of `objectWillChange`. A slider
    /// can produce dozens of draft writes per second; publishing those through
    /// AppState used to invalidate the entire navigation tree, menu-bar UI,
    /// profile editor, and every visible control for each pointer event.
    private(set) var eqDraftRevision: UInt64 = 0
    let equalizerReplacementChanges = PassthroughSubject<UUID, Never>()
    let eqDraftChanges = PassthroughSubject<UUID, Never>()

    private var runtimeObservation: AnyCancellable?
    lazy var runtimeCoordinator: AudioRuntimeCoordinator = {
        let owner = AudioRuntimeCoordinator(services: runtimeServices, perAppAudio: perAppAudio,
            performanceRecorder: performanceRecorder, callbacks: .init(
                profiles: { [weak self] in self?.profiles.profiles ?? [] },
                automaticProfile: { [weak self] in self?.profiles.automaticProfile(forPhysicalDeviceUID: $0) },
                applyingDrafts: { [weak self] profile in try self?.applyingSessionEQDrafts(to: profile) ?? profile },
                settingsBusy: { [weak self] in self?.isSavingProfileSettings ?? false },
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

    let coreAudio: CoreAudioManager
    let profiles: ProfileStore
    let dependencies: DependencyManager
    let loginItem = LoginItemManager()
    let dsp: CamillaDSPManager
    let meters = AudioRuntimeMonitor()
    let spectrum = SpectrumAnalyzer()
    let pcmRouter = PCMRouter()
    let perAppAudio: PerAppAudioController
    let driverTransport = SystemAudioBridgeTransport()
    let updateChecker = AppUpdateChecker()

    private let notifications = NotificationManager()
    private let dspController: CamillaDSPController
    private let volumeBridge = SystemVolumeBridge()
    private var monitorTimer: Timer?
    private var startupConfigurationTask: Task<Void, Never>?
    private var sessionToneDrafts: [UUID: SimpleToneSettings] = [:]
    private var sessionEQDrafts: [UUID: String] = [:]
    private var sessionEQDraftsReplaceDeviceCorrection: Set<UUID> = []
    private var sessionLegacyCorrection: [UUID: ReferenceCorrectionSession] = [:]
    private var sessionDeviceCorrectionProvenance: [UUID: DeviceCorrectionProfile] = [:]
    private var sessionClearsDeviceCorrectionProvenance: Set<UUID> = []
    private var sessionLimiterDrafts: [UUID: Bool] = [:]
    private var sessionChannelToneDrafts: [UUID: [Int: SimpleToneSettings]] = [:]
    private var sessionChannelEQDrafts: [UUID: [Int: String]] = [:]
    private var sessionChannelLimiterDrafts: [UUID: [Int: Bool]] = [:]
    private var sessionChannelDelayDrafts: [UUID: [Int: Double]] = [:]
    private var sessionGroupProcessingDrafts: [UUID: [SpeakerGroupID: PerChannelEditorSnapshot]] = [:]
    private var requestedRuntimeVisualProfileID: UUID?
    private var requestedMeterVisuals = true
    private var requestedSpectrumVisuals = true
    private var mainWindowPresentationActive = false
    private var profilePersistenceErrorObservation: AnyCancellable?
    private var coreAudioRoutingObservation: AnyCancellable?
    private var immediateDefaultOutputObservation: AnyCancellable?

    override convenience init() {
        self.init(profiles: ProfileStore(), perAppAudio: PerAppAudioController(), startServices: true)
    }

    init(profiles: ProfileStore, perAppAudio: PerAppAudioController, startServices: Bool = false, runtimeServices: AudioRuntimeServices? = nil) {
        precondition(runtimeServices == nil || !startServices)
        self.suppliedRuntimeServices = runtimeServices
        let audio = CoreAudioManager(observesHardware: runtimeServices == nil)
        let dsp = CamillaDSPManager()
        self.coreAudio = audio
        self.dsp = dsp
        self.dspController = CamillaDSPController(manager: dsp)
        self.profiles = profiles
        self.perAppAudio = perAppAudio
        self.dependencies = DependencyManager(coreAudio: audio)
        super.init()
        history.restorer = self
        perAppAudio.history = history
        perAppAudio.presentationStore.history = history
        profiles.history = history
        historyErrorObservation = history.$lastError.compactMap { $0 }.sink { [weak self] in self?.errorMessage = $0 }

        profilePersistenceErrorObservation = profiles.$persistenceError
            .compactMap { $0 }
            .sink { [weak self] message in
                self?.errorMessage = message
            }
        guard startServices else { return }
        UIRenderPerformance.startMonitoring()

        immediateDefaultOutputObservation = audio.$defaultOutputUID
            .removeDuplicates()
            .sink { [weak self] uid in
                guard let self, self.isActive, !self.transitionInProgress else { return }
                self.runtimeCoordinator.handleDefaultOutputChange(uid)
            }

        coreAudioRoutingObservation = Publishers.CombineLatest(
            audio.$defaultOutputUID,
            audio.$outputDevices
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
            let existingEndpoints = self.coreAudio.outputDevices.contains {
                ProfileRoutingDescriptor.isProfileRoutingUID($0.id)
            }
            self.runtimeCoordinator.requestStartupPresentation(publishProfiles: !existingEndpoints)
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

    var multichannelEditSessions: [UUID: MultichannelHistoryState] = [:]

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
        await runtimeCoordinator.activate(plan: plan, reportErrors: reportErrors,
            performanceReason: performanceReason, parentOperation: parentOperation)
    }

    func eqDraft(for profileID: UUID) -> String? {
        sessionEQDrafts[profileID]
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
        perAppAudio.setMeterPresentationSuspended(!active, source: "main")
        guard let requestedRuntimeVisualProfileID else { return }
        spectrum.setPresentationActive(active && requestedSpectrumVisuals, profileID: requestedRuntimeVisualProfileID)
        meters.setPresentationActive(active && requestedMeterVisuals, profileID: requestedRuntimeVisualProfileID)
    }

    func prepareForDependencyRepair() async -> Bool {
        for _ in 0..<200 where transitionInProgress {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard !transitionInProgress else {
            errorMessage = "Audio routing is still changing. Wait a moment, then start the repair again."
            return false
        }
        if isActive { await deactivate(manual: true) }
        guard !isActive else {
            errorMessage = "CamiTune could not stop the active audio route before repair."
            return false
        }
        return true
    }

    func setEQDraft(_ text: String, for profileID: UUID) {
        let draftStarted = performanceRecorder.isCapturing ? PerformanceClock.now() : nil
        guard sessionEQDrafts[profileID] != text else { return }
        sessionEQDrafts[profileID] = text
        publishEQDraftChange(for: profileID, started: draftStarted)
    }

    func markEQDraftAsReplacingDeviceCorrection(for profileID: UUID) {
        sessionEQDraftsReplaceDeviceCorrection.insert(profileID)
    }

    func eqDraftReplacesDeviceCorrection(for profileID: UUID) -> Bool {
        sessionEQDraftsReplaceDeviceCorrection.contains(profileID)
    }

    func toneDraft(for profileID: UUID) -> SimpleToneSettings? { sessionToneDrafts[profileID] }
    func setToneDraft(_ tone: SimpleToneSettings, for profileID: UUID) {
        let draftStarted = performanceRecorder.isCapturing ? PerformanceClock.now() : nil
        guard sessionToneDrafts[profileID] != tone else { return }
        sessionToneDrafts[profileID] = tone
        publishEQDraftChange(for: profileID, started: draftStarted)
    }

    func limiterDraft(for profileID: UUID) -> Bool? {
        sessionLimiterDrafts[profileID]
    }

    func setLimiterDraft(_ enabled: Bool, for profileID: UUID) {
        guard sessionLimiterDrafts[profileID] != enabled else { return }
        sessionLimiterDrafts[profileID] = enabled
        publishEQDraftChange(for: profileID)
    }

    func setDeviceCorrectionProvenanceDraft(
        _ correction: DeviceCorrectionProfile?,
        for profileID: UUID
    ) {
        if let correction {
            sessionDeviceCorrectionProvenance[profileID] = correction
            sessionClearsDeviceCorrectionProvenance.remove(profileID)
        } else {
            sessionDeviceCorrectionProvenance.removeValue(forKey: profileID)
            sessionClearsDeviceCorrectionProvenance.insert(profileID)
        }
    }

    func deviceCorrectionProvenance(
        for profileID: UUID,
        persisted: DeviceCorrectionProfile?
    ) -> DeviceCorrectionProfile? {
        if let draft = sessionDeviceCorrectionProvenance[profileID] { return draft }
        if sessionClearsDeviceCorrectionProvenance.contains(profileID) { return nil }
        return persisted
    }

    func applyDeviceCorrectionProvenanceDraft(
        to processing: inout ProcessingProfile,
        for profileID: UUID
    ) {
        if let draft = sessionDeviceCorrectionProvenance[profileID] {
            processing.globalEqualizerProvenance = draft
        } else if sessionClearsDeviceCorrectionProvenance.contains(profileID) {
            processing.globalEqualizerProvenance = nil
        }
    }

    func clearEQDraft(for profileID: UUID) {
        let hadDraft = sessionToneDrafts[profileID] != nil || sessionEQDrafts[profileID] != nil
            || sessionEQDraftsReplaceDeviceCorrection.contains(profileID)
            || sessionDeviceCorrectionProvenance[profileID] != nil
            || sessionClearsDeviceCorrectionProvenance.contains(profileID)
            || sessionLimiterDrafts[profileID] != nil
        sessionLegacyCorrection.removeValue(forKey: profileID)
        sessionToneDrafts.removeValue(forKey: profileID)
        sessionEQDrafts.removeValue(forKey: profileID)
        sessionEQDraftsReplaceDeviceCorrection.remove(profileID)
        sessionDeviceCorrectionProvenance.removeValue(forKey: profileID)
        sessionClearsDeviceCorrectionProvenance.remove(profileID)
        sessionLimiterDrafts.removeValue(forKey: profileID)
        if hadDraft { publishEQDraftChange(for: profileID) }
    }

    func channelToneDraft(for profileID: UUID, channelIndex: Int) -> SimpleToneSettings? {
        sessionChannelToneDrafts[profileID]?[channelIndex]
    }

    func groupProcessingDraft(for profileID: UUID, groupID: SpeakerGroupID) -> PerChannelEditorSnapshot? {
        sessionGroupProcessingDrafts[profileID]?[groupID]
    }

    func setGroupProcessingDraft(_ snapshot: PerChannelEditorSnapshot, for profileID: UUID, groupID: SpeakerGroupID) {
        guard sessionGroupProcessingDrafts[profileID]?[groupID] != snapshot else { return }
        sessionGroupProcessingDrafts[profileID, default: [:]][groupID] = snapshot
        publishEQDraftChange(for: profileID)
    }

    func clearGroupProcessingDraft(for profileID: UUID, groupID: SpeakerGroupID) {
        guard sessionGroupProcessingDrafts[profileID]?.removeValue(forKey: groupID) != nil else { return }
        if sessionGroupProcessingDrafts[profileID]?.isEmpty == true { sessionGroupProcessingDrafts.removeValue(forKey: profileID) }
        publishEQDraftChange(for: profileID)
    }

    func channelEQDraft(for profileID: UUID, channelIndex: Int) -> String? {
        sessionChannelEQDrafts[profileID]?[channelIndex]
    }

    func setChannelEQDraft(_ text: String, for profileID: UUID, channelIndex: Int) {
        guard sessionChannelEQDrafts[profileID]?[channelIndex] != text else { return }
        sessionChannelEQDrafts[profileID, default: [:]][channelIndex] = text
        publishEQDraftChange(for: profileID)
    }

    /// Stores a complete per-channel editor snapshot and emits one draft-change
    /// notification for the logical edit. Continuous controls use this after
    /// their debounce so Global EQ/headroom work is not triggered three times.
    func setChannelProcessingDraft(
        eqText: String,
        limiterEnabled: Bool,
        delayMilliseconds: Double,
        simpleTone: SimpleToneSettings? = nil,
        for profileID: UUID,
        channelIndex: Int
    ) {
        var changed = false

        if let simpleTone, sessionChannelToneDrafts[profileID]?[channelIndex] != simpleTone {
            sessionChannelToneDrafts[profileID, default: [:]][channelIndex] = simpleTone
            changed = true
        }
        if sessionChannelEQDrafts[profileID]?[channelIndex] != eqText {
            sessionChannelEQDrafts[profileID, default: [:]][channelIndex] = eqText
            changed = true
        }
        if sessionChannelLimiterDrafts[profileID]?[channelIndex] != limiterEnabled {
            sessionChannelLimiterDrafts[profileID, default: [:]][channelIndex] = limiterEnabled
            changed = true
        }
        if sessionChannelDelayDrafts[profileID]?[channelIndex] != delayMilliseconds {
            sessionChannelDelayDrafts[profileID, default: [:]][channelIndex] = delayMilliseconds
            changed = true
        }

        if changed { publishEQDraftChange(for: profileID) }
    }

    func channelLimiterDraft(for profileID: UUID, channelIndex: Int) -> Bool? {
        sessionChannelLimiterDrafts[profileID]?[channelIndex]
    }

    func setChannelLimiterDraft(
        _ enabled: Bool,
        for profileID: UUID,
        channelIndex: Int
    ) {
        guard sessionChannelLimiterDrafts[profileID]?[channelIndex] != enabled else {
            return
        }
        sessionChannelLimiterDrafts[profileID, default: [:]][channelIndex] = enabled
        publishEQDraftChange(for: profileID)
    }

    func channelDelayDraft(for profileID: UUID, channelIndex: Int) -> Double? {
        sessionChannelDelayDrafts[profileID]?[channelIndex]
    }

    func setChannelDelayDraft(
        _ milliseconds: Double,
        for profileID: UUID,
        channelIndex: Int
    ) {
        guard sessionChannelDelayDrafts[profileID]?[channelIndex] != milliseconds else {
            return
        }
        sessionChannelDelayDrafts[profileID, default: [:]][channelIndex] = milliseconds
        publishEQDraftChange(for: profileID)
    }

    func clearChannelEQDraft(for profileID: UUID, channelIndex: Int) {
        let hadDraft = sessionChannelToneDrafts[profileID]?[channelIndex] != nil
            || sessionChannelEQDrafts[profileID]?[channelIndex] != nil
            || sessionChannelLimiterDrafts[profileID]?[channelIndex] != nil
            || sessionChannelDelayDrafts[profileID]?[channelIndex] != nil
        sessionChannelToneDrafts[profileID]?.removeValue(forKey: channelIndex)
        if sessionChannelToneDrafts[profileID]?.isEmpty == true {
            sessionChannelToneDrafts.removeValue(forKey: profileID)
        }
        sessionChannelEQDrafts[profileID]?.removeValue(forKey: channelIndex)
        if sessionChannelEQDrafts[profileID]?.isEmpty == true {
            sessionChannelEQDrafts.removeValue(forKey: profileID)
        }
        sessionChannelLimiterDrafts[profileID]?.removeValue(forKey: channelIndex)
        if sessionChannelLimiterDrafts[profileID]?.isEmpty == true {
            sessionChannelLimiterDrafts.removeValue(forKey: profileID)
        }
        sessionChannelDelayDrafts[profileID]?.removeValue(forKey: channelIndex)
        if sessionChannelDelayDrafts[profileID]?.isEmpty == true {
            sessionChannelDelayDrafts.removeValue(forKey: profileID)
        }
        if hadDraft { publishEQDraftChange(for: profileID) }
    }

    func setGlobalEQHistoryDraft(_ snapshot: GlobalEQHistoryState, for id: UUID) {
        sessionLegacyCorrection[id] = ReferenceCorrectionSession(draft: snapshot.deviceCorrection)
        sessionEQDrafts[id] = EqualizerAPOSerializer().serialize(ParsedEQ(preampDB: snapshot.preampDB, bands: snapshot.bands))
        sessionLimiterDrafts[id] = snapshot.limiterEnabled
        sessionToneDrafts[id] = snapshot.simpleTone
        if snapshot.replacesDeviceCorrection { sessionEQDraftsReplaceDeviceCorrection.insert(id) }
        else { sessionEQDraftsReplaceDeviceCorrection.remove(id) }
        setDeviceCorrectionProvenanceDraft(snapshot.deviceCorrectionProvenance, for: id)
        publishEQDraftChange(for: id)
    }

    private func publishEQDraftChange(for profileID: UUID, started: PerformanceTick? = nil) {
        eqDraftRevision &+= 1
        draftPerformance.removeValue(forKey: profileID)?.finish("coalesced")
        if let operation = performanceRecorder.begin("Live EQ apply", revision: eqDraftRevision, started: started) {
            operation.mark("draft accepted")
            draftPerformance[profileID] = operation
        }
        eqDraftChanges.send(profileID)
    }

    /// Produces the profile currently being auditioned without persisting drafts.
    /// Global and per-channel editors both use this so changing one scope cannot
    /// revert an unsaved draft in another scope.
    func applyingSessionEQDrafts(to profile: DeviceProfile, replacingGlobalEqualizer: Bool = false) throws -> DeviceProfile {
        var updated = profile
        if let legacy = sessionLegacyCorrection[profile.id] { updated.processing.setDeviceCorrection(legacy.draft) }
        if let tone = sessionToneDrafts[profile.id] { updated.processing.simpleTone = tone }
        if !replacingGlobalEqualizer, let text = sessionEQDrafts[profile.id] {
            let parsed = try EqualizerAPOParser().parse(text)
            updated.setGlobalEqualizer(preampDB: parsed.preampDB, bands: parsed.bands)
            if sessionEQDraftsReplaceDeviceCorrection.contains(profile.id) {
                updated.processing.setDeviceCorrection(nil)
            }
        }
        if let limiterEnabled = sessionLimiterDrafts[profile.id] {
            updated.processing.setLimiterEnabled(limiterEnabled)
        }
        if !replacingGlobalEqualizer { applyDeviceCorrectionProvenanceDraft(to: &updated.processing, for: profile.id) }
        for (id, snapshot) in sessionGroupProcessingDrafts[profile.id] ?? [:] {
            // Retain drafts if a setup temporarily disables/removes their group.
            if updated.configuredSpeakerGroups.contains(where: { $0.id == id }) {
                try updated.setGroupProcessing(id: id, settings: snapshot.processingSettings)
            }
        }
        let channelToneDrafts = sessionChannelToneDrafts[profile.id] ?? [:]
        let channelEQDrafts = sessionChannelEQDrafts[profile.id] ?? [:]
        let channelLimiterDrafts = sessionChannelLimiterDrafts[profile.id] ?? [:]
        let channelDelayDrafts = sessionChannelDelayDrafts[profile.id] ?? [:]
        let draftedChannelIndexes = Set(channelEQDrafts.keys)
            .union(channelLimiterDrafts.keys)
            .union(channelDelayDrafts.keys)
            .union(channelToneDrafts.keys)
        for channelIndex in draftedChannelIndexes {
            let current = try updated.resolvedProcessing().settings(forChannel: channelIndex) ?? .identity
            let parsed = try channelEQDrafts[channelIndex].map {
                try EqualizerAPOParser().parse($0)
            } ?? ParsedEQ(
                preampDB: current.gainDB,
                bands: current.bands,
                warnings: []
            )
            let role = updated.processing.channels.first(where: { $0.index == channelIndex })?.role
                ?? (channelIndex == 0 ? .left : (channelIndex == 1 ? .right : .unknown))
            try updated.setChannelProcessing(
                index: channelIndex,
                role: role,
                gainDB: parsed.preampDB,
                bands: parsed.bands,
                delayMilliseconds: channelDelayDrafts[channelIndex]
                    ?? current.delayMilliseconds,
                limiterEnabled: channelLimiterDrafts[channelIndex]
                    ?? current.limiterEnabled,
                simpleTone: channelToneDrafts[channelIndex] ?? current.simpleTone
            )
        }
        return updated
    }

    func validateSetup(profile: DeviceProfile) async {
        guard !isValidating else { return }
        isValidating = true
        validationMessage = "Validating dependencies, devices, sample rate, and CamillaDSP configuration…"
        defer { isValidating = false }
        guard let graph = await validate(profile: profile) else { return }
        do {
            await dependencies.refreshWithoutBlockingUI()
            guard FileManager.default.isExecutableFile(atPath: dependencies.camillaDSPBinary.path) else {
                throw AppError.missingCamillaDSP
            }
            guard let bridge = await coreAudio.resolveSystemAudioBridgeWithoutBlockingUI() else {
                throw AppError.missingRoutingDriver
            }
            guard await coreAudio
                .systemAudioBridgePresentationIsSupportedWithoutBlockingUI() else {
                throw AppError.outdatedRoutingDriver
            }
            guard coreAudio.installedSystemAudioBridgeChannelLayout != nil else {
                throw AppError.unsupportedRoutingLayout
            }
            guard let output = await coreAudio.resolveDeviceWithoutBlockingUI(
                uid: profile.outputDeviceUID
            ) else {
                throw AppError.outputMissing(profile.outputDeviceName)
            }
            guard !output.isRoutingDevice else { throw AppError.invalidTarget }
            let rate = Double(profile.sampleRate)
            guard await coreAudio.supportsSampleRateWithoutBlockingUI(
                uid: bridge.id,
                rate: rate
            ) else {
                throw AppError.unsupportedSampleRate(profile.sampleRate, bridge.name)
            }
            guard await coreAudio.supportsSampleRateWithoutBlockingUI(
                uid: output.id,
                rate: rate
            ) else {
                throw AppError.unsupportedSampleRate(profile.sampleRate, output.name)
            }

            let configuration = await dspController.configuration(for: graph)
            try await dependencies.validateConfiguration(configuration.yaml)

            if isActive, activeProfileID == profile.id {
                let diagnostics = try await dspController.fetchDiagnostics()
                validationMessage = "Ready: EQ syntax, dependencies, devices, \(rateDescription(profile.sampleRate)), CamillaDSP config, and live engine checked (\(diagnostics.engineState))."
            } else {
                validationMessage = "Ready: EQ syntax, dependencies, devices, \(rateDescription(profile.sampleRate)), and CamillaDSP config checked. Activate EQ to test the live audio engine."
            }
            clearTransientError()
        } catch {
            validationMessage = ""
            presentError(error, prefix: "Validation failed: ")
        }
    }

    private func rateDescription(_ rate: Int) -> String {
        rate % 1000 == 0 ? "\(rate / 1000) kHz" : String(format: "%.1f kHz", Double(rate) / 1000)
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
        guard !isSavingProfileSettings else { return }
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
        let candidate = try draft.candidate()
        _ = try await prepareRuntimePlan(profile: candidate)
        guard !isSavingProfileSettings, !transitionInProgress,
              await coreAudio.resolveDeviceWithoutBlockingUI(uid: candidate.outputDeviceUID) != nil else {
            throw ProfileSettingsError.runtime("The audio device changed. Check its connection and try again.")
        }
        let id = try profiles.insertConfiguredProfile(candidate)
        runtimeCoordinator.resetAutomaticPolicy(outputUID: candidate.outputDeviceUID)
        Task { @MainActor [weak self] in await self?.monitorRouting() }
        return id
    }

    func saveProfileSettings(_ draft: ProfileSettingsDraft) async throws {
        guard !isSavingProfileSettings, !transitionInProgress, !runtimeCoordinator.hasLiveApplyWork,
              spatialCalibrationContext == nil else { throw ProfileSettingsError.busy }
        let operation = performanceRecorder.begin("Profile Save", reason: "settingsTransaction")
        var performanceResult = "failed"
        defer { operation?.finish(performanceResult) }
        let draftRevision = eqDraftRevision
        isSavingProfileSettings = true
        defer {
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
        guard let original = profiles.profiles.first(where: { $0.id == draft.original.id }) else { throw ProfileSettingsError.staleDraft }
        let originalActivation = profiles.activationMode(for: original)
        guard draft.activation == draft.originalActivation || originalActivation == draft.originalActivation || originalActivation == draft.activation else { throw ProfileSettingsError.staleDraft }
        let activation = draft.activation == draft.originalActivation ? originalActivation : draft.activation
        var candidate = try draft.candidate(applyingTo: original)
        candidate.autoActivateWhenProfileDeviceSelected = activation == .profileAudioDevice
        let newRuntime = try applyingSessionEQDrafts(to: candidate, replacingGlobalEqualizer: draft.replacesUserEqualizer)
        func validatePersistence() throws {
            guard draftRevision == self.eqDraftRevision else { throw ProfileSettingsError.busy }
            try self.profiles.validateSettingsSnapshot(original, activation: originalActivation)
        }
        let receipt = try await runtimeCoordinator.applySettingsCandidate(original: original, newRuntime: newRuntime,
            operation: operation, validatePersistence: validatePersistence)
        do {
            try validatePersistence()
            try runtimeCoordinator.validate(receipt)
            operation?.mark("persistence begins")
            try profiles.commitSettings(candidate, expected: original,
                originalActivation: originalActivation, activation: activation)
            try runtimeCoordinator.commit(receipt)
            operation?.mark("persistence complete")
        } catch {
            let failure = error
            do { try await runtimeCoordinator.rollback(receipt) }
            catch { throw ProfileSettingsError.rollback(failure.localizedDescription, error.localizedDescription) }
            throw failure
        }
        if draft.replacesUserEqualizer {
            clearEQDraft(for: candidate.id)
            equalizerReplacementChanges.send(candidate.id)
        }
        if activation != originalActivation || candidate.outputDevice != original.outputDevice {
            runtimeCoordinator.resetAutomaticPolicy(outputUID: candidate.outputDeviceUID)
            Task { @MainActor [weak self] in await self?.monitorRouting() }
        }
        operation?.mark("final publication")
        performanceResult = "success"
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
        guard !isSavingProfileSettings else { return }
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

    /// The confirmation is tied to a profile ID; revalidate it before any write.
    func deactivateProfileFromMenu(profileID: UUID, physicalOutputConfirmed: Bool) async {
        guard !transitionInProgress, isActive, activeProfileID == profileID,
              let profile = profiles.profiles.first(where: { $0.id == profileID }) else { return }
        let mode = profiles.activationMode(for: profile)
        if mode == .physicalOutput {
            guard physicalOutputConfirmed else { return }
            // No await between policy mutation, durable save, and deactivation.
            profiles.setAutomaticProfile(physicalDevice: profile.outputDevice, profileID: nil)
            profiles.setAutoActivateWhenProfileDeviceSelected(profileID: profileID, enabled: true)
            profiles.flushPendingSaveSynchronously()
            if let error = profiles.persistenceError {
                profiles.setAutoActivateWhenProfileDeviceSelected(profileID: profileID,
                    enabled: profile.autoActivateWhenProfileDeviceSelected)
                profiles.setAutomaticProfile(physicalDevice: profile.outputDevice, profileID: profileID)
                errorMessage = error
                return
            }
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
        runtimeCoordinator.resetAutomaticPolicy(outputUID: physicalDevice.uid)
        profiles.setAutomaticProfile(physicalDevice: physicalDevice, profileID: profileID)
        if let profileID {
            profiles.setAutoActivateWhenProfileDeviceSelected(profileID: profileID, enabled: false)
        }
        if profileID != nil { await monitorRouting() }
    }

    func setAutoActivateWhenProfileDeviceSelected(id: UUID, enabled: Bool) async {
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
        await runtimeCoordinator.activate(profile: profile, reportErrors: reportErrors, automatic: automatic,
            performanceReason: performanceReason,
            parentOperation: parentOperation, preparedPlan: preparedPlan)
    }

    func beginSpatialCalibration(profileID: UUID, virtualSurround: Bool = false, spatialAudio: Bool = false) -> SpatialCalibrationContext? {
        guard isActive, !transitionInProgress, !runtimeCoordinator.hasLiveApplyWork, spatialCalibrationContext == nil,
              let session = activeSession, session.profileID == profileID,
              let rate = activeSampleRate,
              coreAudio.defaultOutputUID == activeRoutingUID,
              let profile = profiles.profiles.first(where: { $0.id == profileID }),
              (profile.effectiveSpatialRenderingMode == .spatialAudio || profile.usesReferenceSpeakers),
              profile.outputDeviceUID == activePhysicalOutputUID else { return nil }
        let context = SpatialCalibrationContext(
            id: UUID(), runtimeSessionID: session.id, profileID: profileID,
            outputDeviceUID: profile.outputDeviceUID, sampleRate: Double(rate)
        )
        // Spatial mode is a local PCM setting. Do not let a pending graph RPC
        // leave the first audition in the previously selected Standard mode.
        pcmRouter.setSpatialRenderingMode(profile.effectiveSpatialRenderingMode)
        pcmRouter.setSpatialSettings(profile.effectiveSpatialSettings, output: profile.effectiveSpatialSettings.resolvedOutput(deviceName: profile.outputDeviceName))
        if virtualSurround { pcmRouter.setVirtualSurroundLayout(profile.virtualSurroundLayout) }
        guard pcmRouter.beginSpatialCalibration(id: context.id, tuning: profile.spatialListenerTuning) else {
            return nil
        }
        spatialCalibrationContext = context
        return context
    }

    func playSpatialCalibration(
        context: SpatialCalibrationContext, clip: SpatialCalibrationClip,
        tuning: SpatialListenerTuning, completion: @escaping @Sendable () -> Void
    ) -> Bool {
        guard spatialCalibrationContext == context, activeSession?.id == context.runtimeSessionID,
              isActive, !transitionInProgress, activePhysicalOutputUID == context.outputDeviceUID,
              coreAudio.defaultOutputUID == activeRoutingUID,
              Double(activeSampleRate ?? 0) == clip.sampleRate else { return false }
        return pcmRouter.playSpatialCalibration(
            id: context.id, clip: clip, tuning: tuning, completion: completion
        )
    }

    func saveSpatialCalibration(
        context: SpatialCalibrationContext, name: String, result: SpatialPerceptualCalibration
    ) -> Bool {
        guard result.isComplete, spatialCalibrationContext == context,
              activeSession?.id == context.runtimeSessionID, !transitionInProgress,
              coreAudio.defaultOutputUID == activeRoutingUID,
              var profile = profiles.profiles.first(where: { $0.id == context.profileID }),
              profile.outputDeviceUID == context.outputDeviceUID else { return false }
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        profile.spatialListenerProfile = SpatialListenerProfile(
            name: name.isEmpty ? "My listening position" : name,
            outputDeviceUID: context.outputDeviceUID, savedAt: Date(),
            position: result.position, tuning: result.tuning.validated,
            completedComparisons: result.comparisonIndex
        )
        profiles.update(profile)
        endSpatialCalibration(id: context.id)
        Task {
            do { try await applyHistoryProfileIfActive(profile.id) }
            catch { presentError(error) }
        }
        return true
    }

    func clearSpatialCalibration(profileID: UUID) {
        guard spatialCalibrationContext == nil,
              var profile = profiles.profiles.first(where: { $0.id == profileID }) else { return }
        profile.spatialListenerProfile = nil
        profiles.update(profile)
        if activeProfileID == profileID {
            Task {
                do { try await applyHistoryProfileIfActive(profile.id) }
                catch { presentError(error) }
            }
        }
    }

    func holdSpatialMeasurement(context: SpatialCalibrationContext, enabled: Bool) {
        guard spatialCalibrationContext == context else { return }
        pcmRouter.holdSpatialMeasurement(id: context.id, enabled: enabled)
    }

    var acousticVolumeSnapshot: SystemVolumeControlSession.Snapshot? { volumeBridge.measurementSnapshot }

    func acousticMeasurementIsCurrent(context: SpatialCalibrationContext, processing: ProcessingProfile) -> Bool {
        spatialCalibrationContext == context && isActive && !transitionInProgress && !runtimeCoordinator.hasLiveApplyWork
            && activeSession?.id == context.runtimeSessionID
            && coreAudio.defaultOutputUID == activeRoutingUID
            && profiles.profiles.first(where: { $0.id == context.profileID })?.processing == processing
    }

    func saveAcousticCalibration(context: SpatialCalibrationContext, measurement: SpatialAcousticProfile) -> Bool {
        guard spatialCalibrationContext == context, isActive, !transitionInProgress,
              activeSession?.id == context.runtimeSessionID,
              coreAudio.defaultOutputUID == activeRoutingUID,
              var profile = profiles.profiles.first(where: { $0.id == context.profileID }),
              measurement.applies(to: profile),
              measurement.positions.contains(where: { $0.position == .listeningPosition }) else { return false }
        profile.spatialAcousticProfile = measurement
        profile.spatialListenerProfile = nil
        profiles.update(profile)
        endSpatialCalibration(id: context.id)
        Task {
            do { try await applyHistoryProfileIfActive(profile.id) }
            catch { presentError(error) }
        }
        return true
    }

    func endSpatialCalibration(id: UUID) {
        guard spatialCalibrationContext?.id == id else { return }
        pcmRouter.endSpatialCalibration(id: id)
        runtimeCoordinator.restoreRenderConfiguration()
        spatialCalibrationContext = nil
    }

    func selectListeningPosition(profileID: UUID, positionID: UUID?, delete: Bool = false) async {
        guard spatialCalibrationContext == nil,
              let profile = profiles.profiles.first(where: { $0.id == profileID }) else { return }
        var draft = ProfileSettingsDraft(profile: profile, activation: profiles.activationMode(for: profile))
        if delete, let positionID {
            draft.spatialSettings.listeningPositions.removeAll { $0.id == positionID }
            if draft.spatialSettings.selectedPositionID == positionID { draft.spatialSettings.selectedPositionID = nil }
            if draft.spatialSettings.primaryPositionID == positionID { draft.spatialSettings.primaryPositionID = draft.spatialSettings.listeningPositions.first?.id }
        } else {
            guard positionID == nil || draft.spatialSettings.listeningPositions.contains(where: {
                $0.id == positionID && $0.outputDeviceUID == profile.outputDeviceUID
            }) else { return }
            draft.spatialSettings.selectedPositionID = positionID
        }
        do { try await saveProfileSettings(draft) }
        catch { presentError(error) }
    }

    func saveListeningPosition(context: SpatialCalibrationContext, position: SpatialSeatingCalibration) async -> Bool {
        guard spatialCalibrationContext == context, activeSession?.id == context.runtimeSessionID,
              !transitionInProgress, activePhysicalOutputUID == context.outputDeviceUID,
              var profile = profiles.profiles.first(where: { $0.id == context.profileID }),
              profile.outputDeviceUID == position.outputDeviceUID,
              profile.outputDeviceUID == context.outputDeviceUID else { return false }
        profile.spatialSettings.seating = position
        profile.synchronizeListeningPositionCorrection()
        profiles.update(profile)
        endSpatialCalibration(id: context.id)
        await apply(profile: profile)
        return true
    }

    func saveRoomCorrection(context: SpatialCalibrationContext, measurement: SpatialAcousticProfile) async -> Bool {
        guard acousticMeasurementIsCurrent(context: context, processing: measurement.processing),
              var profile = profiles.profiles.first(where: { $0.id == context.profileID }),
              [.virtualSurround, .spatialAudio].contains(profile.effectiveSpatialRenderingMode),
              (profile.effectiveSpatialRenderingMode != .spatialAudio
                || profile.effectiveSpatialSettings.resolvedOutput(deviceName: profile.outputDeviceName) == .speakers),
              measurement.applies(to: profile),
              !SpatialRoomCorrection.isApplied(to: profile.processing) else { return false }
        let bands = SpatialRoomCorrection.bands(for: measurement)
        var seat = profile.effectiveSpatialSettings.seating
            ?? SpatialSeatingCalibration(outputDeviceUID: profile.outputDeviceUID, name: "Measured listening position")
        seat.roomCorrectionBands = bands
        seat.roomCorrectionTopology = profile.speakerTopology
        seat.measuredAt = measurement.measuredAt
        seat.microphoneName = measurement.microphone.name
        seat.measurementConfidence = measurement.confidence
        if measurement.confidence != .limited,
           let center = measurement.positions.first(where: { $0.position == .listeningPosition }) {
            seat.measuredArrivalDifferenceMS = center.rightMinusLeftArrivalMilliseconds
            seat.measuredLevelDifferenceDB = center.rightMinusLeftLevelDB
            seat.useMeasuredAlignment = true
        }
        profile.spatialSettings.seating = seat
        profile.synchronizeListeningPositionCorrection()
        profile.spatialAcousticProfile = measurement
        profiles.update(profile)
        // Save before ending the token; normal profile apply preserves all
        // preexisting EQ/limiter stages and uses the serialized graph worker.
        endSpatialCalibration(id: context.id)
        await apply(profile: profile)
        return true
    }

    func removeRoomCorrection(profileID: UUID) async {
        guard spatialCalibrationContext == nil,
              var profile = profiles.profiles.first(where: { $0.id == profileID }) else { return }
        profile.spatialSettings.seating?.roomCorrectionBands = []
        profile.processing.global.stages.removeAll { $0.id == SpatialRoomCorrection.stageID }
        profiles.update(profile)
        if activeProfileID == profileID { await apply(profile: profile) }
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
        updateChecker.installPreparedUpdateAfterExit()
    }

    func shutdownSynchronously() {
        monitorTimer?.invalidate(); monitorTimer = nil
        startupConfigurationTask?.cancel(); startupConfigurationTask = nil
        profiles.flushPendingSaveSynchronously()
        runtimeCoordinator.shutdownSynchronously()
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
    private func makeLiveRuntimeServices() -> AudioRuntimeServices {
        AudioRuntimeServices(
            currentVolumeSession: { [volumeBridge] in volumeBridge.runtimeControlSession },
            synchronous: .init(
                stopTransport: { [driverTransport] in driverTransport.stop() },
                stopPCM: { [pcmRouter] in pcmRouter.stop() },
                closeEngineInput: { [dsp] in dsp.closeAudioInput() },
                stopSpectrum: { [spectrum] in spectrum.stop() },
                stopEngine: { [dsp] in dsp.forceStopAndWait() },
                stopVolume: { [volumeBridge] in volumeBridge.stop() },
                setDefaultOutput: { [coreAudio] in try coreAudio.setDefaultOutput(uid: $0) },
                hideBridge: { [coreAudio] in try coreAudio.setSystemAudioBridgePresentation(name: "System Audio Bridge", visible: false) }),
            silenceVolume: { [volumeBridge] in volumeBridge.silenceForExternalRouteChange() },
            resumeVolume: { [volumeBridge] in volumeBridge.resumeAfterExternalRouteReturn() },
            refreshDependencies: { [unowned self] in await dependencies.refreshWithoutBlockingUI() },
            engineAvailable: { [unowned self] in FileManager.default.isExecutableFile(atPath: dependencies.camillaDSPBinary.path) },
            resolveBridge: { [unowned self] in await coreAudio.resolveSystemAudioBridgeWithoutBlockingUI() },
            freshBridge: { [unowned self] in await coreAudio.freshlyResolvedSystemAudioBridgeWithoutBlockingUI() },
            presentationSupported: { [unowned self] in await coreAudio.systemAudioBridgePresentationIsSupportedWithoutBlockingUI() },
            bridgeLayout: { [unowned self] in coreAudio.installedSystemAudioBridgeChannelLayout },
            resolveOutput: { [unowned self] in await coreAudio.resolveDeviceWithoutBlockingUI(uid: $0) },
            probeTopology: { output in try await Task.detached(priority: .userInitiated) { try SpeakerTopologyProbe().probe(output) }.value },
            outputChannelCount: { output in try await Task.detached(priority: .userInitiated) { try SpeakerTopologyProbe().outputChannelCount(output) }.value },
            supportsRate: { [unowned self] in await coreAudio.supportsSampleRateWithoutBlockingUI(uid: $0, rate: $1) },
            defaultOutput: { [unowned self] in coreAudio.defaultOutputUID },
            cachedDevice: { [unowned self] in coreAudio.cachedDevice(uid: $0) },
            hasSnapshot: { [unowned self] in coreAudio.hasCompletedInitialRefresh },
            nominalRate: { [unowned self] in await coreAudio.nominalSampleRateWithoutBlockingUI(uid: $0) },
            synchronizeRouting: { [unowned self] in _ = try await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(profiles: $0, activeProfileID: $1, additionallyVisible: $2, preparedDescriptors: $3) },
            waitForRouting: { [unowned self] in await coreAudio.waitForProfileRoutingDevice(profileID: $0) },
            hideBridge: { [unowned self] in try await coreAudio.setSystemAudioBridgePresentationWithoutBlockingUI(name: AudioDeviceInfo.systemAudioBridgeName, visible: false) },
            setRate: { [unowned self] in try await coreAudio.setSampleRate(uid: $0, rate: $1) },
            setDefaultOutput: { [unowned self] in try await coreAudio.setDefaultOutputAndWait(uid: $0) },
            startEngine: { [unowned self] in try await dsp.start(binary: dependencies.camillaDSPBinary) },
            resetEngine: { [unowned self] in dspController.resetRuntime() },
            playbackDevices: { [unowned self] in try await dsp.rpc.availablePlaybackDevices(backend: "CoreAudio").map(\.identifier) },
            graphUpdateDescription: { [unowned self] in dspController.lastGraphUpdate?.rawValue },
            applyGraph: { [unowned self] in try await dspController.applyGraph($0, performanceRecorder: performanceRecorder) },
            startObservations: { [unowned self] runtimeSession in
                meters.start(
                    controller: dspController,
                    session: runtimeSession,
                    routeDiagnosticsProvider: { [driverTransport, pcmRouter] in
                        AudioRouteDiagnostics(
                            transport: driverTransport.statistics,
                            router: pcmRouter.statistics
                        )
                    }
                )
            },
            startVolume: { [unowned self] routing, output, profileID in
                guard let ownershipID = runtimeCoordinator.currentOwnershipID else { throw CancellationError() }
                let volumeSession = try await volumeBridge.start(
                    routingDevice: routing,
                    physicalUID: output.id,
                    coreAudio: coreAudio,
                    onVolume: { [weak self] volume in
                        guard let self, self.runtimeCoordinator.owns(ownershipID) else { return }
                        self.profiles.setOutputVolumeScalar(
                            profileID: profileID,
                            scalar: volume
                        )
                    },
                    onMasterGain: { [pcmRouter] linearGain, muted in
                        pcmRouter.setSystemMaster(
                            linearGain: linearGain,
                            muted: muted
                        )
                    },
                    onMirrorFailure: { [weak self] in
                        self?.runtimeCoordinator.reportVolumeMirrorFailure(ownershipID: ownershipID)
                    }
                )
                return { scalar, muted in volumeSession.applyDriverSnapshot(scalar: scalar, muted: muted) }
            },
            volumeMode: { [unowned self] in volumeBridge.mode },
            startPCM: { [unowned self] plan, runtimeSession in
                pcmRouter.performanceSource.setSession(runtimeSession.id)
                await pcmRouter.start(camillaSink: try dsp.audioInputHandle(), activeRoute: plan.route,
                    renderConfiguration: plan.renderConfiguration, referenceTopology: plan.referenceTopology,
                    meterConsumer: meters.pcmConsumer(for: runtimeSession),
                    analyzerConsumer: { [weak spectrum] frame in
                        spectrum?.ingest(interleaved: frame.interleaved, channelCount: frame.channelCount,
                            sampleRate: frame.sampleRate, session: runtimeSession)
                    })
            },
            applyRenderConfiguration: { [unowned self] in pcmRouter.setRenderConfiguration($0) },
            startTransport: { [unowned self] currentBridge, routing, sampleRate, masterControl in
                try await driverTransport.start(
                    deviceObjectID: currentBridge.objectID,
                    controlDeviceObjectID: routing.objectID,
                    expectedSampleRate: sampleRate,
                    pcmRouter: pcmRouter,
                    perAppAudio: perAppAudio,
                    masterControlConsumer: { scalar, muted in
                        masterControl(scalar, muted)
                    }
                )
            },
            prepareVolume: { [unowned self] in try await volumeBridge.prepareForActiveProcessing() },
            startSpectrum: { [unowned self] in await spectrum.start(session: $0, sourceName: "System Audio Bridge") },
            beginHandoff: { [unowned self] in await volumeBridge.beginOutputHandoff() },
            stopObservations: { [unowned self] in meters.stop() },
            stopTransport: { [unowned self] in await driverTransport.stopWithoutBlockingUI() },
            stopPCM: { [unowned self] in
                await pcmRouter.stopWithoutBlockingUI()
                pcmRouter.performanceSource.setSession(nil)
            },
            closeEngineInput: { [unowned self] in await dsp.closeAudioInputWithoutBlockingUI() },
            stopSpectrum: { [unowned self] in await spectrum.stopWithoutBlockingUI() },
            stopEngine: { [unowned self] in await dsp.stop() },
            stopVolume: { [unowned self] in await volumeBridge.stopWithoutBlockingUI() },
            transportError: { [unowned self] in driverTransport.runtimeError },
            notifyActivation: { [unowned self] in notifications.activated() },
            notifyDeactivation: { [unowned self] in notifications.deactivated() },
            sleep: { try await Task.sleep(for: $0) },
            transitionFinished: { _ in }
        )
    }
}

extension AppState {
    func performanceEnvironment() -> PerformanceEnvironment {
        let profile = activeProfileID.flatMap { id in profiles.profiles.first { $0.id == id } }
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
            dspLoad: fresh ? telemetry.processingLoadPercent : nil, dspBufferFrames: fresh ? telemetry.dspBufferLevelFrames : nil,
            dspResamplerLoad: fresh ? telemetry.resamplerLoadPercent : nil, queue: statistics.camillaQueue,
            recoveries: statistics.camillaQueueRecoveries, droppedFrames: statistics.camillaDroppedFrames,
            transportDroppedFrames: driverTransport.statistics.droppedFrames, processCPUSeconds: RuntimePerformanceRecorder.cpuSeconds(),
            presentationStatistics: perAppAudio.presentationStatistics)
    }
}
