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
    @Published private(set) var isActive = false
    @Published private(set) var activeVolumeMode: SystemVolumeMode?
    @Published private(set) var activeSession: AudioRuntimeSession?
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

    var activeProfileID: UUID? { activeSession?.profileID }

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
    private var previousDefaultUID: String?
    private var monitorTimer: Timer?
    private var routingMonitorInFlight = false
    private var startupConfigurationTask: Task<Void, Never>?
    private var suppressedAutoUID: String?
    private var automaticActivationRetry: AutomaticActivationRetryState?
    @Published private(set) var transitionInProgress = false
    private struct PendingDeactivation {
        var manual: Bool
        var restoreOutput: Bool
        var invalidateLiveApplies: Bool

        mutating func merge(
            manual: Bool,
            restoreOutput: Bool,
            invalidateLiveApplies: Bool
        ) {
            self.manual = self.manual || manual
            self.restoreOutput = self.restoreOutput || restoreOutput
            self.invalidateLiveApplies = self.invalidateLiveApplies || invalidateLiveApplies
        }
    }
    private var pendingDeactivation: PendingDeactivation?
    /// Lets compound stop/restart operations observe an explicit user stop that
    /// arrived while their intermediate teardown was suspended.
    private var manualDeactivationRevision: UInt64 = 0
    private var activatingProfileID: UUID?
    private var activeSampleRate: Int?
    private var activeRoutingUID: String?
    /// The physical device actually owned by the running engine. Persisted
    /// profile fields may change while an async teardown is in flight, so they
    /// cannot safely serve as the runtime routing snapshot.
    private var activePhysicalOutputUID: String?
    private var latestApplyRequest: UInt64 = 0
    private struct PendingLiveApply {
        var request: UInt64
        var profile: DeviceProfile
    }
    private var pendingLiveApply: PendingLiveApply?
    private var liveApplyWorker: Task<Void, Never>?
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

    init(profiles: ProfileStore, perAppAudio: PerAppAudioController, startServices: Bool = false) {
        let audio = CoreAudioManager()
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
                if uid == self.activeRoutingUID {
                    self.volumeBridge.resumeAfterExternalRouteReturn()
                } else {
                    self.volumeBridge.silenceForExternalRouteChange()
                    if let context = self.spatialCalibrationContext {
                        self.endSpatialCalibration(id: context.id)
                    }
                }
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
            if await self.coreAudio
                .systemAudioBridgePresentationIsSupportedWithoutBlockingUI() {
                try? await self.coreAudio.setSystemAudioBridgePresentationWithoutBlockingUI(
                    name: "System Audio Bridge",
                    visible: false
                )
            }
            guard !Task.isCancelled else { return }
            // With no initial HAL snapshot, preserve the driver's current
            // endpoints rather than publishing from an unknown default output.
            if self.coreAudio.hasCompletedInitialRefresh,
               !self.transitionInProgress,
               !self.isActive {

                let hasExistingProfileRoutingDevices =
                    self.coreAudio.outputDevices.contains {
                        ProfileRoutingDescriptor.isProfileRoutingUID($0.id)
                    }

                if !hasExistingProfileRoutingDevices {
                    // Fresh coreaudiod/driver instance: no profile endpoints exist yet,
                    // so publish the normal initial set.
                    _ = try? await self.coreAudio
                        .synchronizeProfileRoutingDevicesWithoutBlockingUI(
                            profiles: self.profiles.profiles,
                            activeProfileID: nil
                        )
                }

                await self.monitorRouting()
            }
        }
    }

    func validate(profile: DeviceProfile, detectedHardware: SpeakerTopology? = nil) async -> ProcessingGraph? {
        do {
            let (graph, parsed) = try await Task.detached(priority: .userInitiated) {
                (
                    try detectedHardware.map { try AudioRuntimePlanCompiler().compile(profile: profile, detectedHardware: $0).processingGraph }
                        ?? ActiveAudioRoute(profile: profile).buildGraph(profile: profile),
                    try profile.resolvedProcessing().globalEqualizer
                )
            }.value
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
    private var activeReferenceTopology: SpeakerTopology?
    private var activeAudioRoute: ActiveAudioRoute?

    private func buildGraphWithoutBlockingUI(
        profile: DeviceProfile
    ) async throws -> ProcessingGraph {
        try await Task.detached(priority: .userInitiated) {
            try ActiveAudioRoute(profile: profile).buildGraph(profile: profile)
        }.value
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
        guard sessionEQDrafts[profileID] != text else { return }
        sessionEQDrafts[profileID] = text
        publishEQDraftChange(for: profileID)
    }

    func markEQDraftAsReplacingDeviceCorrection(for profileID: UUID) {
        sessionEQDraftsReplaceDeviceCorrection.insert(profileID)
    }

    func eqDraftReplacesDeviceCorrection(for profileID: UUID) -> Bool {
        sessionEQDraftsReplaceDeviceCorrection.contains(profileID)
    }

    func toneDraft(for profileID: UUID) -> SimpleToneSettings? { sessionToneDrafts[profileID] }
    func setToneDraft(_ tone: SimpleToneSettings, for profileID: UUID) {
        guard sessionToneDrafts[profileID] != tone else { return }
        sessionToneDrafts[profileID] = tone
        publishEQDraftChange(for: profileID)
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

    private func publishEQDraftChange(for profileID: UUID) {
        eqDraftRevision &+= 1
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

    func processingSampleRateProblemWithoutBlockingUI(
        rate: Int,
        outputUID: String
    ) async -> AppError? {
        guard let bridge = await coreAudio.resolveSystemAudioBridgeWithoutBlockingUI() else {
            return AppError.missingRoutingDriver
        }
        guard await coreAudio.supportsSampleRateWithoutBlockingUI(
            uid: bridge.id,
            rate: Double(rate)
        ) else {
            return AppError.unsupportedSampleRate(rate, bridge.name)
        }
        guard let output = await coreAudio.resolveDeviceWithoutBlockingUI(uid: outputUID) else {
            return .outputMissing(profiles.profiles.first { $0.outputDeviceUID == outputUID }?.outputDeviceName ?? "Physical Output")
        }
        guard await coreAudio.supportsSampleRateWithoutBlockingUI(
            uid: output.id,
            rate: Double(rate)
        ) else {
            return AppError.unsupportedSampleRate(rate, output.name)
        }
        return nil
    }

    func reportProcessingSampleRateProblem(_ error: AppError) {
        presentError(error)
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
            try await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(profiles: profiles.profiles, activeProfileID: activeProfileID)
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
            try await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(profiles: profiles.profiles, activeProfileID: activeProfileID)
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
            try await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(
                profiles: profiles.profiles, activeProfileID: activeProfileID
            )
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
                    try await coreAudio.setDefaultOutputAndWait(uid: profile.outputDeviceUID)
                } catch {
                    errorMessage = "The profile was disabled, but macOS could not switch back to \(profile.outputDeviceName): \(error.localizedDescription)"
                    return
                }
            }
            do {
                try await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(
                    profiles: profiles.profiles,
                    activeProfileID: activeProfileID
                )
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
        automaticActivationRetry = nil
        if suppressedAutoUID == device.id { suppressedAutoUID = nil }
        Task { [weak self] in
            await self?.monitorRouting()
        }
        return profile.id
    }

    func addProfile(from draft: AddOutputDraft) async throws -> UUID {
        guard !isSavingProfileSettings, !transitionInProgress else { throw ProfileSettingsError.busy }
        let candidate = try draft.candidate()
        guard let device = await coreAudio.resolveDeviceWithoutBlockingUI(uid: candidate.outputDeviceUID),
              !device.isRoutingDevice else { throw AppError.outputMissing(candidate.outputDeviceName) }
        guard await coreAudio.supportsSampleRateWithoutBlockingUI(uid: device.id, rate: Double(candidate.sampleRate)) else {
            throw AppError.unsupportedSampleRate(candidate.sampleRate, candidate.outputDeviceName)
        }
        if draft.needsSpeakers || candidate.endpointKind == .audioInterface {
            let found = try await Task.detached(priority: .userInitiated) { try SpeakerTopologyProbe().probe(device) }.value
            if let topology = candidate.speakerTopology { try topology.validateHardware(found) }
            if let assignment = try candidate.validatedInterfaceConfiguration(), assignment.hardwareChannelCount != found.declaredChannelCount {
                throw SpeakerTopologyError.hardwareLayoutChanged
            }
        }
        _ = try await buildGraphWithoutBlockingUI(profile: candidate)
        guard !isSavingProfileSettings, !transitionInProgress,
              await coreAudio.resolveDeviceWithoutBlockingUI(uid: candidate.outputDeviceUID) != nil else {
            throw ProfileSettingsError.runtime("The audio device changed. Check its connection and try again.")
        }
        let id = try profiles.insertConfiguredProfile(candidate)
        automaticActivationRetry = nil
        if suppressedAutoUID == candidate.outputDeviceUID { suppressedAutoUID = nil }
        Task { @MainActor [weak self] in await self?.monitorRouting() }
        return id
    }

    func saveProfileSettings(_ draft: ProfileSettingsDraft) async throws {
        guard !isSavingProfileSettings, !transitionInProgress, liveApplyWorker == nil,
              spatialCalibrationContext == nil else { throw ProfileSettingsError.busy }
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
        let revision = manualDeactivationRevision
        let wasActive = isActive && activeProfileID == original.id
        let originalPreviousDefaultUID = previousDefaultUID
        let oldRuntime = try applyingSessionEQDrafts(to: original)
        let newRuntime = try applyingSessionEQDrafts(to: candidate, replacingGlobalEqualizer: draft.replacesUserEqualizer)
        let changesRendering = original.endpointKind != candidate.endpointKind
            || original.sampleRate != candidate.sampleRate || original.outputDevice != candidate.outputDevice
            || original.playbackMode != candidate.playbackMode
            || original.speakerTopology != candidate.speakerTopology
            || original.spatialSettings != candidate.spatialSettings
            || original.processing != candidate.processing
            || original.multichannel != candidate.multichannel
            || original.personalReferenceCorrections != candidate.personalReferenceCorrections
        let changesSourceFormat = ProfileRoutingDescriptor.sourceLayout(for: original) != ProfileRoutingDescriptor.sourceLayout(for: candidate)
            || original.sampleRate != candidate.sampleRate
        let requiresRestart = changesSourceFormat || original.usesSourceProcessingBus != candidate.usesSourceProcessingBus || original.endpointKind != candidate.endpointKind
            || original.outputDevice != candidate.outputDevice || original.sampleRate != candidate.sampleRate
            || original.speakerTopology != candidate.speakerTopology
            || original.effectiveSpatialSettings.seating != candidate.effectiveSpatialSettings.seating
            || original.audioInterface != candidate.audioInterface
        var appliedInPlace = false
        func applyModeState(_ value: DeviceProfile) {
            pcmRouter.setPlaybackMode(value.playbackMode, correction: value.personalReferenceCorrection)
            pcmRouter.setSpatialRenderingMode(value.effectiveSpatialRenderingMode)
            pcmRouter.setSpatialSettings(value.effectiveSpatialSettings, output: value.effectiveSpatialSettings.resolvedOutput(deviceName: value.outputDeviceName))
            perAppAudio.setPlaybackContext(PerAppPlaybackContext(profile: value))
        }
        var touchedRuntime = false
        var touchedRouting = false
        func checkCurrent() throws {
            guard revision == manualDeactivationRevision else { throw ProfileSettingsError.cancelled }
            guard draftRevision == eqDraftRevision else { throw ProfileSettingsError.busy }
            try profiles.validateSettingsSnapshot(original, activation: originalActivation)
        }
        try await ProfileSettingsTransaction.run {
            try checkCurrent()
            guard ProfileNamePolicy.isAvailable(candidate.name, in: profiles.profiles, excluding: original.id) else {
                throw ProfileSettingsError.runtime("A profile with that name already exists.")
            }
            if changesRendering {
                guard let device = await coreAudio.resolveDeviceWithoutBlockingUI(uid: candidate.outputDeviceUID) else {
                    throw AppError.outputMissing(candidate.outputDeviceName)
                }
                guard !device.isRoutingDevice else { throw AppError.invalidTarget }
                guard await coreAudio.supportsSampleRateWithoutBlockingUI(uid: device.id, rate: Double(candidate.sampleRate)) else {
                    throw AppError.unsupportedSampleRate(candidate.sampleRate, device.name)
                }
                let topology = try candidate.validatedPhysicalSpeakerTopology()
                let assignment = try candidate.validatedInterfaceConfiguration()
                if topology != nil || assignment != nil {
                    let discovered = try await Task.detached(priority: .userInitiated) {
                        try SpeakerTopologyProbe().probe(device)
                    }.value
                    try candidate.speakerTopology?.validateHardware(discovered)
                    try candidate.validateMultichannelHardware(discovered)
                    if let assignment, discovered.declaredChannelCount != assignment.hardwareChannelCount {
                        throw SpeakerTopologyError.hardwareLayoutChanged
                    }
                }
                _ = try await buildGraphWithoutBlockingUI(profile: newRuntime)
                if wasActive {
                    if let problem = await processingSampleRateProblemWithoutBlockingUI(rate: candidate.sampleRate,
                        outputUID: candidate.outputDeviceUID) { throw problem }
                    await dependencies.refreshWithoutBlockingUI()
                    guard case .installed = dependencies.camillaDSPStatus else { throw AppError.missingCamillaDSP }
                    guard case .installed = dependencies.audioDriverStatus else { throw AppError.outdatedRoutingDriver }
                }
            }
            try checkCurrent()
        } apply: {
            if wasActive && changesRendering && !requiresRestart {
                appliedInPlace = true
                try await dspController.applyGraph(try await buildGraphWithoutBlockingUI(profile: newRuntime))
                try checkCurrent()
                applyModeState(newRuntime)
            }
            if wasActive && changesRendering && requiresRestart {
                touchedRuntime = true
                await deactivate(manual: false)
                try checkCurrent()
                await activate(profile: newRuntime, reportErrors: false, settingsTransaction: true)
                guard isActive, activeProfileID == original.id else {
                    throw ProfileSettingsError.runtime(errorMessage ?? "The new audio configuration could not start.")
                }
            }
            try checkCurrent()
            if changesSourceFormat || original.name != candidate.name || original.outputDevice != candidate.outputDevice {
                touchedRouting = true
                try await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(
                    profiles: profiles.profiles.map { $0.id == candidate.id ? candidate : $0 },
                    activeProfileID: activeProfileID)
            }
            try checkCurrent()
        } commit: {
            try checkCurrent()
            try profiles.commitSettings(candidate, expected: original,
                originalActivation: originalActivation, activation: activation)
        } rollback: {
            if appliedInPlace && revision == manualDeactivationRevision && isActive && activeProfileID == original.id {
                try await dspController.applyGraph(try await buildGraphWithoutBlockingUI(profile: oldRuntime))
                applyModeState(oldRuntime)
            }
            if touchedRuntime {
                await deactivate(manual: false)
                // Never undo an explicit Stop or restart a deleted/changed profile.
                if revision == manualDeactivationRevision,
                   let current = profiles.profiles.first(where: { $0.id == original.id }), current.isEnabled,
                   ProfileStore.settingsSnapshot(current) == ProfileStore.settingsSnapshot(original) {
                    await activate(profile: oldRuntime, reportErrors: false, settingsTransaction: true)
                    guard isActive, activeProfileID == original.id else {
                        throw ProfileSettingsError.runtime(errorMessage ?? "The previous audio configuration could not restart.")
                    }
                    previousDefaultUID = originalPreviousDefaultUID
                }
            }
            if touchedRouting {
                try await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(
                    profiles: profiles.profiles, activeProfileID: activeProfileID)
            }
        }
        if draft.replacesUserEqualizer {
            clearEQDraft(for: candidate.id)
            equalizerReplacementChanges.send(candidate.id)
        }
        if activation != originalActivation || candidate.outputDevice != original.outputDevice {
            automaticActivationRetry = nil
            if suppressedAutoUID == candidate.outputDeviceUID { suppressedAutoUID = nil }
            Task { @MainActor [weak self] in await self?.monitorRouting() }
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
            previousDefaultUID = activePhysicalOutputUID ?? profile.outputDeviceUID
        }
        await deactivate(manual: true)
    }

    func setAutomaticProfile(
        for physicalDevice: PhysicalOutputIdentity,
        profileID: UUID?
    ) async {
        automaticActivationRetry = nil
        if suppressedAutoUID == physicalDevice.uid { suppressedAutoUID = nil }
        profiles.setAutomaticProfile(physicalDevice: physicalDevice, profileID: profileID)
        if let profileID {
            profiles.setAutoActivateWhenProfileDeviceSelected(profileID: profileID, enabled: false)
        }
        if profileID != nil { await monitorRouting() }
    }

    func setAutoActivateWhenProfileDeviceSelected(id: UUID, enabled: Bool) async {
        automaticActivationRetry = nil
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
            try? await coreAudio.setDefaultOutputAndWait(uid: profile.outputDeviceUID)
        }
        if enabled { await monitorRouting() }
        else {
            _ = try? await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(
                profiles: profiles.profiles,
                activeProfileID: activeProfileID
            )
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
        settingsTransaction: Bool = false
    ) async {
        guard !isSavingProfileSettings || settingsTransaction else { return }
        guard !transitionInProgress else { return }
        transitionInProgress = true
        activatingProfileID = profile.id
        defer {
            activatingProfileID = nil
            finishAudioTransition()
        }
        if let startupConfigurationTask {
            startupConfigurationTask.cancel()
            await startupConfigurationTask.value
            self.startupConfigurationTask = nil
        }
        let activationOriginUID = coreAudio.defaultOutputUID
        func routingProfiles() -> [DeviceProfile] {
            guard settingsTransaction else { return profiles.profiles }
            return profiles.profiles.map { $0.id == profile.id ? profile : $0 }
        }

        do {
            guard profile.isEnabled else { throw AppError.profileDisabled(profile.name) }
            await dependencies.refreshWithoutBlockingUI()
            guard FileManager.default.isExecutableFile(atPath: dependencies.camillaDSPBinary.path) else {
                throw AppError.missingCamillaDSP
            }
            guard let initialBridge = await coreAudio
                .resolveSystemAudioBridgeWithoutBlockingUI() else {
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
            let assignment = try profile.validatedInterfaceConfiguration()
            let referenceTopology = try profile.validatedPhysicalSpeakerTopology()
            let audioRoute = try ActiveAudioRoute(profile: profile)
            var detectedHardware: SpeakerTopology?
            if referenceTopology != nil || assignment != nil {
                let discovered = try await Task.detached(priority: .userInitiated) {
                    try SpeakerTopologyProbe().probe(output)
                }.value
                if let assignment, discovered.declaredChannelCount != assignment.hardwareChannelCount {
                    throw SpeakerTopologyError.hardwareLayoutChanged
                }
                try referenceTopology?.validateHardware(discovered)
                try profile.validateMultichannelHardware(discovered)
                detectedHardware = discovered
            }
            guard let graph = await validate(profile: profile, detectedHardware: detectedHardware) else { return }
            let sampleRate = Double(profile.sampleRate)
            guard await coreAudio.supportsSampleRateWithoutBlockingUI(
                uid: initialBridge.id,
                rate: sampleRate
            ) else {
                throw AppError.unsupportedSampleRate(profile.sampleRate, initialBridge.name)
            }
            guard await coreAudio.supportsSampleRateWithoutBlockingUI(
                uid: output.id,
                rate: sampleRate
            ) else {
                throw AppError.unsupportedSampleRate(profile.sampleRate, output.name)
            }

            if isActive {
                // There is one system route and one private CamillaDSP engine.
                // Switching profiles must explicitly release the old pipeline
                // before the replacement can own either resource.
                let alreadyOwnsRequestedRuntime = activeProfileID == profile.id
                    && activePhysicalOutputUID == profile.outputDeviceUID
                    && activeSampleRate == profile.sampleRate
                    && activeReferenceTopology == referenceTopology
                    && activeAudioRoute == audioRoute
                guard !alreadyOwnsRequestedRuntime else { return }
                await stopProcessingPipeline()
                isActive = false
                activeSession = nil
                activeSampleRate = nil
            activeReferenceTopology = nil
            activeAudioRoute = nil
                activePhysicalOutputUID = nil
            }

            _ = try await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(
                profiles: routingProfiles(),
                activeProfileID: nil,
                additionallyVisible: [profile.id]
            )
            guard let routing = await coreAudio.waitForProfileRoutingDevice(profileID: profile.id) else {
                throw AppError.profileRoutingDeviceMissing(profile.name)
            }
            guard let bridge = await coreAudio
                .freshlyResolvedSystemAudioBridgeWithoutBlockingUI() else {
                throw AppError.missingRoutingDriver
            }

            // Native profile endpoints share this bridge's PCM stream. Keep
            // the generic transport hidden so Sound Settings exposes only the
            // stable, volume-capable profile device.
            try await coreAudio.setSystemAudioBridgePresentationWithoutBlockingUI(
                name: AudioDeviceInfo.systemAudioBridgeName,
                visible: false
            )

            if coreAudio.defaultOutputUID != routing.id,
               coreAudio.defaultOutputUID != bridge.id,
               coreAudio.defaultOutputUID.flatMap(ProfileRoutingDescriptor.profileID(from:)) == nil {
                previousDefaultUID = coreAudio.defaultOutputUID
            }
            activeRoutingUID = routing.id

            try await coreAudio.setSampleRate(uid: output.id, rate: sampleRate)
            try await coreAudio.setSampleRate(uid: bridge.id, rate: sampleRate)

            try await dsp.start(binary: dependencies.camillaDSPBinary)
            dspController.resetRuntime()
            let camillaOutputs = try await dsp.rpc.availablePlaybackDevices(backend: "CoreAudio")
            guard camillaOutputs.contains(where: { $0.identifier == profile.outputDeviceUID }) else {
                throw AppError.camillaDSPCoreAudioUIDUnsupported
            }
            try await dspController.applyGraph(graph)

            let runtimeSession = AudioRuntimeSession(profileID: profile.id)
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

            // Seed the virtual master before constructing the PCM writer. The
            // writer snapshots this value in its initializer, which guarantees
            // that the first processed frame matches the physical endpoint's
            // original level instead of briefly starting at unity.
            let volumeSession = try await volumeBridge.start(
                routingDevice: routing,
                physicalUID: output.id,
                coreAudio: coreAudio,
                onVolume: { [weak self] volume in
                    self?.profiles.setOutputVolumeScalar(
                        profileID: profile.id,
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
                    self?.errorMessage = "The output volume could not be synchronized. Playback is muted until a volume change succeeds. Check the output connection."
                }
            )
            activeVolumeMode = volumeBridge.mode
            await pcmRouter.start(
                camillaSink: try dsp.audioInputHandle(),
                activeRoute: audioRoute,
                spatialRenderingMode: profile.effectiveSpatialRenderingMode,
                spatialListenerTuning: profile.spatialListenerTuning,
                spatialContentMode: profile.spatialContentMode,
                spatialSettings: profile.effectiveSpatialSettings,
                spatialOutput: profile.effectiveSpatialSettings.resolvedOutput(deviceName: output.name),
                referenceTopology: referenceTopology,
                playbackMode: profile.playbackMode, referenceCorrection: profile.personalReferenceCorrection,
                meterConsumer: meters.pcmConsumer(for: runtimeSession),
                analyzerConsumer: { [weak spectrum] frame in
                    spectrum?.ingest(
                        interleaved: frame.interleaved,
                        channelCount: frame.channelCount,
                        sampleRate: frame.sampleRate,
                        session: runtimeSession
                    )
                }
            )
            activeReferenceTopology = referenceTopology
            activeAudioRoute = audioRoute
            pcmRouter.setVirtualSurroundLayout(profile.virtualSurroundLayout)
            perAppAudio.setPlaybackContext(PerAppPlaybackContext(profile: profile))
            var transportConnected = false
            var transportError: Error?
            for attempt in 0..<3 {
                guard let currentBridge = await coreAudio
                    .freshlyResolvedSystemAudioBridgeWithoutBlockingUI() else {
                    transportError = AppError.missingRoutingDriver
                    break
                }
                do {
                    try await driverTransport.start(
                        deviceObjectID: currentBridge.objectID,
                        controlDeviceObjectID: routing.objectID,
                        expectedSampleRate: sampleRate,
                        pcmRouter: pcmRouter,
                        perAppAudio: perAppAudio,
                        masterControlConsumer: { scalar, muted in
                            volumeSession.applyDriverSnapshot(scalar: scalar, muted: muted)
                        }
                    )
                    transportConnected = true
                    break
                } catch {
                    transportError = error
                    if attempt < 2 {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
            if !transportConnected {
                throw transportError ?? AppError.missingRoutingDriver
            }

            try await volumeBridge.prepareForActiveProcessing()
            if coreAudio.defaultOutputUID != routing.id {
                try await coreAudio.setDefaultOutputAndWait(uid: routing.id)
            }

            activeSession = runtimeSession
            activeSampleRate = profile.sampleRate
            activePhysicalOutputUID = profile.outputDeviceUID
            isActive = true
            await spectrum.start(session: runtimeSession, sourceName: "System Audio Bridge")
            _ = try? await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(
                profiles: routingProfiles(),
                activeProfileID: profile.id
            )
            suppressedAutoUID = nil
            automaticActivationRetry = nil
            clearTransientError()
            notifications.activated()
        } catch {
            if reportErrors || shouldAlwaysReport(error) {
                presentError(error)
            }
            if automatic, activationOriginUID == profile.outputDeviceUID {
                // Transient driver/WebSocket startup races should recover while
                // the physical output remains selected. Backoff prevents a
                // permanent setup failure from churning the route every second.
                automaticActivationRetry = .recordingFailure(
                    for: profile.outputDeviceUID,
                    previous: automaticActivationRetry
                )
            }
            await stopProcessingPipeline()
            if let routingUID = activeRoutingUID,
               coreAudio.defaultOutputUID == routingUID {
                let restore = previousDefaultUID.flatMap {
                    coreAudio.cachedDevice(uid: $0) != nil ? $0 : nil
                } ?? profile.outputDeviceUID
                try? await coreAudio.setDefaultOutputAndWait(uid: restore)
            }
            isActive = false
            activeSession = nil
            activeSampleRate = nil
            activeReferenceTopology = nil
            activeAudioRoute = nil
            activePhysicalOutputUID = nil
            activeRoutingUID = nil
            try? await coreAudio.setSystemAudioBridgePresentationWithoutBlockingUI(
                name: "System Audio Bridge",
                visible: false
            )
            _ = try? await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(
                profiles: routingProfiles(),
                activeProfileID: nil
            )
        }
    }

    func beginSpatialCalibration(profileID: UUID, virtualSurround: Bool = false, spatialAudio: Bool = false) -> SpatialCalibrationContext? {
        guard isActive, !transitionInProgress, liveApplyWorker == nil, spatialCalibrationContext == nil,
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
        pcmRouter.setSpatialListenerTuning(profile.spatialListenerTuning)
        endSpatialCalibration(id: context.id)
        return true
    }

    func clearSpatialCalibration(profileID: UUID) {
        guard spatialCalibrationContext == nil,
              var profile = profiles.profiles.first(where: { $0.id == profileID }) else { return }
        profile.spatialListenerProfile = nil
        profiles.update(profile)
        if activeProfileID == profileID { pcmRouter.setSpatialListenerTuning(profile.spatialListenerTuning) }
    }

    func holdSpatialMeasurement(context: SpatialCalibrationContext, enabled: Bool) {
        guard spatialCalibrationContext == context else { return }
        pcmRouter.holdSpatialMeasurement(id: context.id, enabled: enabled)
    }

    var acousticVolumeSnapshot: SystemVolumeControlSession.Snapshot? { volumeBridge.measurementSnapshot }

    func acousticMeasurementIsCurrent(context: SpatialCalibrationContext, processing: ProcessingProfile) -> Bool {
        spatialCalibrationContext == context && isActive && !transitionInProgress && liveApplyWorker == nil
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
        pcmRouter.setSpatialListenerTuning(profile.spatialListenerTuning)
        endSpatialCalibration(id: context.id)
        return true
    }

    func endSpatialCalibration(id: UUID) {
        guard spatialCalibrationContext?.id == id else { return }
        pcmRouter.endSpatialCalibration(id: id)
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
        guard !isSavingProfileSettings else {
            pendingSettingsLiveApply = true
            return
        }
        latestApplyRequest &+= 1
        pendingLiveApply = PendingLiveApply(
            request: latestApplyRequest,
            profile: profile
        )
        if liveApplyWorker == nil {
            liveApplyWorker = Task { @MainActor [weak self] in
                await self?.drainLiveApplies()
            }
        }
        await liveApplyWorker?.value
    }

    /// Serializes WebSocket exchanges and coalesces edits that arrive while an
    /// earlier patch is awaiting its reply. A caller canceling its UI debounce
    /// task cannot abandon a sent request or desynchronize the graph snapshot.
    private func drainLiveApplies() async {
        while let pending = pendingLiveApply {
            pendingLiveApply = nil
            await performLiveApply(pending)
        }
        liveApplyWorker = nil
    }

    private func performLiveApply(_ pending: PendingLiveApply) async {
        UIRenderPerformance.beginEQApply()
        defer { UIRenderPerformance.endEQApply() }
        let profile = pending.profile
        let request = pending.request
        guard isActive, activeProfileID == profile.id else { return }
        if activeSampleRate != profile.sampleRate || activeReferenceTopology != (try? profile.validatedPhysicalSpeakerTopology())
            || activeAudioRoute != (try? ActiveAudioRoute(profile: profile)) {
            if let problem = await processingSampleRateProblemWithoutBlockingUI(
                rate: profile.sampleRate,
                outputUID: profile.outputDeviceUID
            ) {
                presentError(problem)
                return
            }
            let manualDeactivationRevision = self.manualDeactivationRevision
            await deactivate(manual: false, invalidateLiveApplies: false)
            guard manualDeactivationRevision == self.manualDeactivationRevision else { return }
            await activate(profile: profile)
            return
        }
        do {
            guard await coreAudio.resolveDeviceWithoutBlockingUI(
                uid: profile.outputDeviceUID
            ) != nil else {
                throw AppError.outputMissing(profile.outputDeviceName)
            }
            let graph = try await buildGraphWithoutBlockingUI(profile: profile)
            try await dspController.applyGraph(graph)
            guard request == latestApplyRequest else { return }
            let currentProfile = profiles.profiles.first { $0.id == profile.id } ?? profile
            pcmRouter.setPlaybackMode(currentProfile.playbackMode, correction: currentProfile.personalReferenceCorrection)
            pcmRouter.setSpatialRenderingMode(currentProfile.effectiveSpatialRenderingMode)
            pcmRouter.setSpatialSettings(currentProfile.effectiveSpatialSettings, output: currentProfile.effectiveSpatialSettings.resolvedOutput(deviceName: currentProfile.outputDeviceName))
            pcmRouter.setSpatialListenerTuning(currentProfile.spatialListenerTuning)
            pcmRouter.setSpatialContentMode(currentProfile.spatialContentMode)
            pcmRouter.setVirtualSurroundLayout(currentProfile.virtualSurroundLayout)
            perAppAudio.setPlaybackContext(PerAppPlaybackContext(profile: currentProfile))
            clearTransientError()
        } catch {
            guard request == latestApplyRequest else { return }
            presentError(error)
        }
    }

    func deactivate(
        manual: Bool = true,
        restoreOutput: Bool = true,
        invalidateLiveApplies: Bool = true
    ) async {
        if manual { manualDeactivationRevision &+= 1 }

        guard !transitionInProgress else {
            enqueueDeactivation(
                manual: manual,
                restoreOutput: restoreOutput,
                invalidateLiveApplies: invalidateLiveApplies
            )
            return
        }

        if invalidateLiveApplies {
            latestApplyRequest &+= 1
            pendingLiveApply = nil
        }

        transitionInProgress = true
        defer { finishAudioTransition() }

        let targetUID = activePhysicalOutputUID ?? activeProfileID.flatMap { id in
            profiles.profiles.first(where: { $0.id == id })?.outputDeviceUID
        }

        var outputRestoreError: Error?

        await volumeBridge.beginOutputHandoff()
        await stopProcessingPipeline()

        if restoreOutput {
            let restore = previousDefaultUID.flatMap {
                coreAudio.cachedDevice(uid: $0) != nil ? $0 : nil
            } ?? targetUID

            if let restore {
                do {
                    try await coreAudio.setDefaultOutputAndWait(uid: restore)
                } catch {
                    outputRestoreError = error
                }
            }
        }

        try? await Task.sleep(for: .milliseconds(150))

        try? await coreAudio.setSystemAudioBridgePresentationWithoutBlockingUI(
            name: "System Audio Bridge",
            visible: false
        )

        var routingCleanupError: Error?

        for attempt in 0..<10 {
            do {
                try await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(
                    profiles: profiles.profiles,
                    activeProfileID: nil
                )

                routingCleanupError = nil
                break
            } catch {
                routingCleanupError = error

                guard attempt < 9 else {
                    break
                }

                try? await Task.sleep(for: .milliseconds(75))
            }
        }

        isActive = false
        activeSession = nil
        activeSampleRate = nil
        activeReferenceTopology = nil
        activeAudioRoute = nil
        activePhysicalOutputUID = nil
        activeRoutingUID = nil
        previousDefaultUID = nil

        if manual {
            suppressedAutoUID = targetUID
            automaticActivationRetry = nil
        }

        if let outputRestoreError {
            errorMessage =
                "EQ stopped, but macOS could not switch back to the physical output: \(outputRestoreError.localizedDescription)"
        } else if let routingCleanupError {
            errorMessage =
                "EQ stopped, but its macOS audio device could not be updated: \(routingCleanupError.localizedDescription)"
        }

        notifications.deactivated()
    }

    private func enqueueDeactivation(
        manual: Bool,
        restoreOutput: Bool,
        invalidateLiveApplies: Bool
    ) {
        if pendingDeactivation != nil {
            pendingDeactivation?.merge(
                manual: manual,
                restoreOutput: restoreOutput,
                invalidateLiveApplies: invalidateLiveApplies
            )
        } else {
            pendingDeactivation = PendingDeactivation(
                manual: manual,
                restoreOutput: restoreOutput,
                invalidateLiveApplies: invalidateLiveApplies
            )
        }
    }

    private func finishAudioTransition() {
        transitionInProgress = false
        guard let pendingDeactivation else { return }
        self.pendingDeactivation = nil
        Task { @MainActor [weak self] in
            await self?.deactivate(
                manual: pendingDeactivation.manual,
                restoreOutput: pendingDeactivation.restoreOutput,
                invalidateLiveApplies: pendingDeactivation.invalidateLiveApplies
            )
        }
    }

    private func stopProcessingPipeline() async {
        perAppAudio.setPlaybackContext(nil)
        if let context = spatialCalibrationContext { endSpatialCalibration(id: context.id) }
        meters.stop()
        await driverTransport.stopWithoutBlockingUI()
        await perAppAudio.resetRuntimeWithoutBlockingUI()
        // Stop the PCM writer before closing CamillaDSP's original stdin
        // FileHandle. The writer owns a duplicated descriptor, so this ordering
        // cleanly retires delivery before the process pipe is torn down.
        await pcmRouter.stopWithoutBlockingUI()
        await dsp.closeAudioInputWithoutBlockingUI()
        await spectrum.stopWithoutBlockingUI()
        await dsp.stop()
        dspController.resetRuntime()
        // Drain the final target and retire both listeners before another
        // session can bind this physical output. Its volume is already mirrored.
        await volumeBridge.stopWithoutBlockingUI()
        activeVolumeMode = nil
    }

    private func monitorRouting() async {
        guard !isSavingProfileSettings, !transitionInProgress, !routingMonitorInFlight else { return }
        routingMonitorInFlight = true
        defer { routingMonitorInFlight = false }
        if isActive {
            if let runtimeError = driverTransport.runtimeError {
                errorMessage = runtimeError
                await deactivate(manual: false)
                return
            }
            guard let activeProfileID,
                  let activeProfile = profiles.profiles.first(where: { $0.id == activeProfileID }) else {
                await deactivate(manual: false, restoreOutput: false)
                return
            }
            if let activePhysicalOutputUID,
               activeProfile.outputDeviceUID != activePhysicalOutputUID {
                do {
                    let updated = try applyingSessionEQDrafts(to: activeProfile)
                    let manualDeactivationRevision = self.manualDeactivationRevision
                    await deactivate(manual: false)
                    guard manualDeactivationRevision == self.manualDeactivationRevision else { return }
                    await activate(profile: updated)
                } catch {
                    presentError(error)
                    await deactivate(manual: false)
                }
                return
            }
            if let activeSampleRate,
               let outputUID = activePhysicalOutputUID,
               let actualRate = await coreAudio.nominalSampleRateWithoutBlockingUI(
                   uid: outputUID
               ),
               abs(actualRate - Double(activeSampleRate)) >= 0.5 {
                errorMessage = AppError.runtimeSampleRateMismatch(
                    expected: activeSampleRate,
                    actual: actualRate,
                    device: activeProfile.outputDeviceName
                ).localizedDescription
                await deactivate(manual: false)
                return
            }
            if !activeProfile.isEnabled {
                await deactivate(manual: false)
                return
            }
            if let outputUID = activePhysicalOutputUID,
               coreAudio.hasCompletedInitialRefresh,
               coreAudio.cachedDevice(uid: outputUID) == nil {
                await deactivate(manual: false, restoreOutput: false)
                return
            }
            guard let activeRoutingUID else {
                await deactivate(manual: false, restoreOutput: false)
                return
            }

            // If the user picks another macOS output while EQ is active, respect it.
            if coreAudio.defaultOutputUID != activeRoutingUID {
                await deactivate(manual: false, restoreOutput: false)
                return
            }

            return
        }

        guard let current = coreAudio.defaultOutputUID else { return }
        if let suppressedAutoUID {
            if current == suppressedAutoUID { return }
            self.suppressedAutoUID = nil
        }
        if let automaticActivationRetry {
            if automaticActivationRetry.outputUID != current {
                self.automaticActivationRetry = nil
            } else if automaticActivationRetry.defersActivation(for: current) {
                return
            }
        }

        // CoreAudio can temporarily keep a removed device's UID as the default
        // after it is unplugged. Never auto-activate from that stale UID: doing
        // so retries a missing route every monitor tick.
        if let currentDevice = coreAudio.cachedDevice(uid: current),
           !currentDevice.isRoutingDevice,
           let profile = profiles.automaticProfile(forPhysicalDeviceUID: current) {
            await activate(profile: profile, reportErrors: false, automatic: true)
            return
        }

        if let selectedProfileID = ProfileRoutingDescriptor.profileID(from: current),
           let selectedProfile = profiles.profiles.first(where: {
                   $0.id == selectedProfileID
                   && $0.isEnabled
                   && $0.autoActivateWhenProfileDeviceSelected
                   && coreAudio.cachedDevice(uid: $0.outputDeviceUID) != nil
           }) {
            await activate(profile: selectedProfile, reportErrors: false, automatic: true)
        }
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        shutdownSynchronously()
        updateChecker.installPreparedUpdateAfterExit()
    }

    private func shutdownSynchronously() {
        if let context = spatialCalibrationContext { endSpatialCalibration(id: context.id) }
        monitorTimer?.invalidate()
        monitorTimer = nil

        profiles.flushPendingSaveSynchronously()

        meters.stop()
        driverTransport.stop()
        perAppAudio.setPlaybackContext(nil)
        perAppAudio.resetRuntime()
        perAppAudio.flushPendingSaveSynchronously()
        pcmRouter.stop()
        dsp.closeAudioInput()
        spectrum.stop()

        // Release playback and drain the same hardware writer used at runtime.
        dsp.forceStopAndWait()
        volumeBridge.stop()
        activeVolumeMode = nil

        if let routingUID = activeRoutingUID,
           coreAudio.defaultOutputUID == routingUID {

            let targetUID = activeProfileID.flatMap { id in
                profiles.profiles.first(where: { $0.id == id })?.outputDeviceUID
            }

            let restore = previousDefaultUID ?? targetUID

            if let restore {
                try? coreAudio.setDefaultOutput(uid: restore)
            }
        }

        try? coreAudio.setSystemAudioBridgePresentation(
            name: "System Audio Bridge",
            visible: false
        )

        // Dont call destroyAllProfileRoutingDevices() here.

        isActive = false
        activeSession = nil
        activeSampleRate = nil
        activeReferenceTopology = nil
        activeAudioRoute = nil
        activePhysicalOutputUID = nil
        activeRoutingUID = nil
        previousDefaultUID = nil
    }

    private func shouldAlwaysReport(_ error: Error) -> Bool {
        if let appError = error as? AppError {
            switch appError {
            case .profileRoutingDeviceMissing, .unsupportedSampleRate,
                    .camillaDSPCoreAudioUIDUnsupported:
                return true
            default:
                break
            }
        }
        if let audioError = error as? CoreAudioManager.AudioError {
            switch audioError {
            case .sampleRateNotSettable, .sampleRateDidNotApply,
                    .defaultOutputDidNotApply:
                return true
            default:
                break
            }
        }
        return false
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
