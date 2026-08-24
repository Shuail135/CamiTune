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
    @Published private(set) var isActive = false
    @Published private(set) var activeSession: AudioRuntimeSession?
    @Published var errorMessage: String?
    @Published var validationMessage: String = ""
    @Published var warnings: [String] = []
    @Published private(set) var isValidating = false
    /// Draft edits are intentionally kept out of `objectWillChange`. A slider
    /// can produce dozens of draft writes per second; publishing those through
    /// AppState used to invalidate the entire navigation tree, menu-bar UI,
    /// profile editor, and every visible control for each pointer event.
    private(set) var eqDraftRevision: UInt64 = 0
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
    let perAppAudio = PerAppAudioController()
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
    private var transitionInProgress = false
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
    private var sessionEQDrafts: [UUID: String] = [:]
    private var sessionEQDraftsReplaceDeviceCorrection: Set<UUID> = []
    private var sessionDeviceCorrectionProvenance: [UUID: DeviceCorrectionProfile] = [:]
    private var sessionClearsDeviceCorrectionProvenance: Set<UUID> = []
    private var sessionLimiterDrafts: [UUID: Bool] = [:]
    private var sessionChannelEQDrafts: [UUID: [Int: String]] = [:]
    private var sessionChannelLimiterDrafts: [UUID: [Int: Bool]] = [:]
    private var sessionChannelDelayDrafts: [UUID: [Int: Double]] = [:]
    private var requestedRuntimeVisualProfileID: UUID?
    private var mainWindowPresentationActive = false
    private var profilePersistenceErrorObservation: AnyCancellable?
    private var coreAudioRoutingObservation: AnyCancellable?

    override init() {
        let audio = CoreAudioManager()
        let dsp = CamillaDSPManager()
        self.coreAudio = audio
        self.dsp = dsp
        self.dspController = CamillaDSPController(manager: dsp)
        self.profiles = ProfileStore()
        self.dependencies = DependencyManager(coreAudio: audio)
        super.init()
        profilePersistenceErrorObservation = profiles.$persistenceError
            .compactMap { $0 }
            .sink { [weak self] message in
                self?.errorMessage = message
            }
        UIRenderPerformance.startMonitoring()

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
                _ = try? await self.coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(
                    profiles: self.profiles.profiles,
                    activeProfileID: nil
                )
                await self.monitorRouting()
            }
        }
    }

    func validate(profile: DeviceProfile) async -> ProcessingGraph? {
        do {
            let (graph, parsed) = try await Task.detached(priority: .userInitiated) {
                (
                    try ProcessingGraphBuilder().build(profile: profile),
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
                errorMessage = error.localizedDescription
            }
            return nil
        }
    }

    private func buildGraphWithoutBlockingUI(
        profile: DeviceProfile
    ) async throws -> ProcessingGraph {
        try await Task.detached(priority: .userInitiated) {
            try ProcessingGraphBuilder().build(profile: profile)
        }.value
    }

    func eqDraft(for profileID: UUID) -> String? {
        sessionEQDrafts[profileID]
    }

    /// Spectrum FFT, PCM metering, and telemetry polling are presentation
    /// concerns. The DSP/audio route stays active when no profile editor is on
    /// screen, while these visual-only consumers pause.
    func setRuntimeVisuals(profileID: UUID, active: Bool) {
        let previousProfileID = requestedRuntimeVisualProfileID
        if active {
            requestedRuntimeVisualProfileID = profileID
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
        spectrum.setPresentationActive(true, profileID: requestedRuntimeVisualProfileID)
        meters.setPresentationActive(true, profileID: requestedRuntimeVisualProfileID)
    }

    /// The main NSWindow is retained after close, so SwiftUI's onDisappear is
    /// not a reliable signal for stopping presentation-only audio observers.
    /// Gate them with the real AppKit visibility and occlusion state instead.
    func setMainWindowPresentationActive(_ active: Bool) {
        guard mainWindowPresentationActive != active else { return }
        mainWindowPresentationActive = active
        perAppAudio.setMeterPresentationSuspended(!active, source: "main")
        guard let requestedRuntimeVisualProfileID else { return }
        spectrum.setPresentationActive(active, profileID: requestedRuntimeVisualProfileID)
        meters.setPresentationActive(active, profileID: requestedRuntimeVisualProfileID)
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
        let hadDraft = sessionEQDrafts[profileID] != nil
            || sessionEQDraftsReplaceDeviceCorrection.contains(profileID)
            || sessionDeviceCorrectionProvenance[profileID] != nil
            || sessionClearsDeviceCorrectionProvenance.contains(profileID)
            || sessionLimiterDrafts[profileID] != nil
        sessionEQDrafts.removeValue(forKey: profileID)
        sessionEQDraftsReplaceDeviceCorrection.remove(profileID)
        sessionDeviceCorrectionProvenance.removeValue(forKey: profileID)
        sessionClearsDeviceCorrectionProvenance.remove(profileID)
        sessionLimiterDrafts.removeValue(forKey: profileID)
        if hadDraft { publishEQDraftChange(for: profileID) }
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
        for profileID: UUID,
        channelIndex: Int
    ) {
        var changed = false

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
        let hadDraft = sessionChannelEQDrafts[profileID]?[channelIndex] != nil
            || sessionChannelLimiterDrafts[profileID]?[channelIndex] != nil
            || sessionChannelDelayDrafts[profileID]?[channelIndex] != nil
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

    private func publishEQDraftChange(for profileID: UUID) {
        eqDraftRevision &+= 1
        eqDraftChanges.send(profileID)
    }

    /// Produces the profile currently being auditioned without persisting drafts.
    /// Global and per-channel editors both use this so changing one scope cannot
    /// revert an unsaved draft in another scope.
    func applyingSessionEQDrafts(to profile: DeviceProfile) throws -> DeviceProfile {
        var updated = profile
        if let text = sessionEQDrafts[profile.id] {
            let parsed = try EqualizerAPOParser().parse(text)
            updated.setGlobalEqualizer(preampDB: parsed.preampDB, bands: parsed.bands)
            if sessionEQDraftsReplaceDeviceCorrection.contains(profile.id) {
                updated.processing.setDeviceCorrection(nil)
            }
        }
        if let limiterEnabled = sessionLimiterDrafts[profile.id] {
            updated.processing.setLimiterEnabled(limiterEnabled)
        }
        applyDeviceCorrectionProvenanceDraft(to: &updated.processing, for: profile.id)
        let channelEQDrafts = sessionChannelEQDrafts[profile.id] ?? [:]
        let channelLimiterDrafts = sessionChannelLimiterDrafts[profile.id] ?? [:]
        let channelDelayDrafts = sessionChannelDelayDrafts[profile.id] ?? [:]
        let draftedChannelIndexes = Set(channelEQDrafts.keys)
            .union(channelLimiterDrafts.keys)
            .union(channelDelayDrafts.keys)
        for channelIndex in draftedChannelIndexes {
            let current = updated.processing.settings(forChannel: channelIndex) ?? .identity
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
                    ?? current.limiterEnabled
            )
        }
        return updated
    }

    func processingSampleRateProblemWithoutBlockingUI(
        rate: Int,
        outputUID: String
    ) async -> String? {
        guard let bridge = await coreAudio.resolveSystemAudioBridgeWithoutBlockingUI() else {
            return AppError.missingRoutingDriver.localizedDescription
        }
        guard await coreAudio.supportsSampleRateWithoutBlockingUI(
            uid: bridge.id,
            rate: Double(rate)
        ) else {
            return AppError.unsupportedSampleRate(rate, bridge.name).localizedDescription
        }
        guard let output = await coreAudio.resolveDeviceWithoutBlockingUI(uid: outputUID) else {
            return "The selected physical output is disconnected."
        }
        guard await coreAudio.supportsSampleRateWithoutBlockingUI(
            uid: output.id,
            rate: Double(rate)
        ) else {
            return AppError.unsupportedSampleRate(rate, output.name).localizedDescription
        }
        return nil
    }

    func reportProcessingSampleRateProblem(_ message: String) {
        errorMessage = message
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
            errorMessage = "Validation failed: \(error.localizedDescription)"
        }
    }

    private func rateDescription(_ rate: Int) -> String {
        rate % 1000 == 0 ? "\(rate / 1000) kHz" : String(format: "%.1f kHz", Double(rate) / 1000)
    }

    func renameProfile(id: UUID, to requestedName: String) async {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = profiles.profiles.firstIndex(where: { $0.id == id }) else { return }
        guard profiles.profiles[index].name != name else { return }
        guard ProfileNamePolicy.isAvailable(name, in: profiles.profiles, excluding: id) else {
            errorMessage = "A profile named \"\(name)\" already exists. Profile names must be unique."
            return
        }

        profiles.profiles[index].name = name

        do {
            // The driver keeps the profile UID on the same native endpoint, so
            // renaming changes the selected device without replacing it.
            try await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(
                profiles: profiles.profiles,
                activeProfileID: activeProfileID
            )

            clearTransientError()
        } catch {
            errorMessage = "The profile was renamed, but its macOS audio device could not be updated: \(error.localizedDescription)"
        }
    }

    func setProfileEnabled(id: UUID, enabled: Bool) async {
        guard let profile = profiles.profiles.first(where: { $0.id == id }),
              profile.isEnabled != enabled else { return }

        profiles.setProfileEnabled(profileID: id, enabled: enabled)
        if !enabled, activeProfileID == id {
            await deactivate(manual: false)
        } else {
            // Move away from a disabled profile endpoint before removing it;
            // Core Audio cannot destroy a device while it is the default.
            if !enabled,
               coreAudio.defaultOutputUID.flatMap(ProfileRoutingDescriptor.profileID(from:)) == id,
               coreAudio.cachedDevice(uid: profile.outputDeviceUID) != nil {
                try? await coreAudio.setDefaultOutputAndWait(uid: profile.outputDeviceUID)
            }
            _ = try? await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(
                profiles: profiles.profiles,
                activeProfileID: activeProfileID
            )
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

    /// Changes an output through the runtime owner. If this profile is active,
    /// its old engine and volume bridge are released before the same profile is
    /// restarted against the new physical endpoint. Session EQ drafts remain
    /// in memory and are applied to the restarted graph.
    func setOutputDevice(profileID: UUID, device: AudioDeviceInfo) async {
        guard !device.isRoutingDevice,
              let current = profiles.profiles.first(where: { $0.id == profileID }) else {
            return
        }
        let requiresRestart = isActive
            && activeProfileID == profileID
            && current.outputDeviceUID != device.id

        profiles.setOutputDevice(profileID: profileID, device: device)
        automaticActivationRetry = nil
        suppressedAutoUID = nil

        if requiresRestart {
            await deactivate(manual: false)
            guard let persisted = profiles.profiles.first(where: { $0.id == profileID }) else {
                return
            }
            do {
                await activate(profile: try applyingSessionEQDrafts(to: persisted))
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            _ = try? await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(
                profiles: profiles.profiles,
                activeProfileID: activeProfileID
            )
            await monitorRouting()
        }
    }

    func activate(
        profile: DeviceProfile,
        reportErrors: Bool = true,
        automatic: Bool = false
    ) async {
        guard !transitionInProgress else { return }
        transitionInProgress = true
        defer { transitionInProgress = false }
        if let startupConfigurationTask {
            startupConfigurationTask.cancel()
            await startupConfigurationTask.value
            self.startupConfigurationTask = nil
        }
        let activationOriginUID = coreAudio.defaultOutputUID

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
            guard let graph = await validate(profile: profile) else { return }
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
                guard !alreadyOwnsRequestedRuntime else { return }
                await stopProcessingPipeline()
                isActive = false
                activeSession = nil
                activeSampleRate = nil
                activePhysicalOutputUID = nil
            }

            _ = try await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(
                profiles: profiles.profiles,
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
            await pcmRouter.start(
                camillaSink: try dsp.audioInputHandle(),
                spatialRenderingMode: profile.spatialRenderingMode,
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
                        expectedSampleRate: sampleRate,
                        pcmRouter: pcmRouter,
                        perAppAudio: perAppAudio
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

            // Switch only when activation did not originate from this profile
            // output. The same Core Audio object remains selected afterward.
            if coreAudio.defaultOutputUID != routing.id {
                try await coreAudio.setDefaultOutputAndWait(uid: routing.id)
            }

            await volumeBridge.start(
                routingDevice: routing,
                physicalUID: output.id,
                coreAudio: coreAudio
            ) { [weak self] volume in
                self?.profiles.setOutputVolumeScalar(
                    profileID: profile.id,
                    scalar: volume
                )
            }

            activeSession = runtimeSession
            activeSampleRate = profile.sampleRate
            activePhysicalOutputUID = profile.outputDeviceUID
            isActive = true
            await spectrum.start(session: runtimeSession, sourceName: "System Audio Bridge")
            _ = try? await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(
                profiles: profiles.profiles,
                activeProfileID: profile.id
            )
            suppressedAutoUID = nil
            automaticActivationRetry = nil
            clearTransientError()
            notifications.activated()
        } catch {
            if reportErrors || shouldAlwaysReport(error) {
                errorMessage = error.localizedDescription
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
            activePhysicalOutputUID = nil
            activeRoutingUID = nil
            try? await coreAudio.setSystemAudioBridgePresentationWithoutBlockingUI(
                name: "System Audio Bridge",
                visible: false
            )
            _ = try? await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(
                profiles: profiles.profiles,
                activeProfileID: nil
            )
        }
    }

    func apply(profile: DeviceProfile) async {
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
        let profile = pending.profile
        let request = pending.request
        guard isActive, activeProfileID == profile.id else { return }
        if activeSampleRate != profile.sampleRate {
            if let problem = await processingSampleRateProblemWithoutBlockingUI(
                rate: profile.sampleRate,
                outputUID: profile.outputDeviceUID
            ) {
                errorMessage = problem
                return
            }
            await deactivate(manual: false, invalidateLiveApplies: false)
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
            pcmRouter.setSpatialRenderingMode(profile.spatialRenderingMode)
            clearTransientError()
        } catch {
            guard request == latestApplyRequest else { return }
            errorMessage = error.localizedDescription
        }
    }

    func deactivate(
        manual: Bool = true,
        restoreOutput: Bool = true,
        invalidateLiveApplies: Bool = true
    ) async {
        guard !transitionInProgress else { return }
        if invalidateLiveApplies {
            latestApplyRequest &+= 1
            pendingLiveApply = nil
        }
        transitionInProgress = true
        defer { transitionInProgress = false }

        let targetUID = activePhysicalOutputUID ?? activeProfileID.flatMap { id in
            profiles.profiles.first(where: { $0.id == id })?.outputDeviceUID
        }

        await stopProcessingPipeline()

        if restoreOutput {
            let restore = previousDefaultUID.flatMap {
                coreAudio.cachedDevice(uid: $0) != nil ? $0 : nil
            } ?? targetUID
            if let restore { try? await coreAudio.setDefaultOutputAndWait(uid: restore) }
        }

        try? await coreAudio.setSystemAudioBridgePresentationWithoutBlockingUI(
            name: "System Audio Bridge",
            visible: false
        )

        isActive = false
        activeSession = nil
        activeSampleRate = nil
        activePhysicalOutputUID = nil
        activeRoutingUID = nil
        previousDefaultUID = nil
        if manual {
            suppressedAutoUID = targetUID
            automaticActivationRetry = nil
        }
        _ = try? await coreAudio.synchronizeProfileRoutingDevicesWithoutBlockingUI(
            profiles: profiles.profiles,
            activeProfileID: nil
        )
        notifications.deactivated()
    }

    private func stopProcessingPipeline() async {
        meters.stop()
        await volumeBridge.stopWithoutBlockingUI()
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
    }

    private func monitorRouting() async {
        guard !transitionInProgress, !routingMonitorInFlight else { return }
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
                    await deactivate(manual: false)
                    await activate(profile: updated)
                } catch {
                    errorMessage = error.localizedDescription
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
        monitorTimer?.invalidate()
        monitorTimer = nil
        profiles.flushPendingSaveSynchronously()
        meters.stop()
        volumeBridge.stop()
        driverTransport.stop()
        perAppAudio.resetRuntime()
        pcmRouter.stop()
        dsp.closeAudioInput()
        spectrum.stop()

        if let routingUID = activeRoutingUID,
           coreAudio.defaultOutputUID == routingUID {
            let targetUID = activeProfileID.flatMap { id in profiles.profiles.first(where: { $0.id == id })?.outputDeviceUID }
            let restore = previousDefaultUID ?? targetUID
            if let restore { try? coreAudio.setDefaultOutput(uid: restore) }
        }
        try? coreAudio.setSystemAudioBridgePresentation(
            name: "System Audio Bridge",
            visible: false
        )
        let cleanupFallbackUID = activeProfileID.flatMap { id in
            profiles.profiles.first(where: { $0.id == id })?.outputDeviceUID
        } ?? previousDefaultUID
        coreAudio.destroyAllProfileRoutingDevices(fallbackUID: cleanupFallbackUID)
        dsp.forceStopAndWait()
        isActive = false
        activeSession = nil
        activeSampleRate = nil
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
        var errorDescription: String? {
            switch self {
            case .missingCamillaDSP: return "CamillaDSP is not installed. Open Setup and install it first."
            case .missingRoutingDriver: return "System Audio Bridge is not installed or visible to CoreAudio. Open Setup to install the bundled driver."
            case .outdatedRoutingDriver: return "The installed audio routing driver is outdated. Open Setup and select Install / Repair Everything."
            case .unsupportedRoutingLayout: return "The installed audio routing driver does not expose a supported 2.0, 5.1, or 7.1 LPCM layout. Open Setup and select Install / Repair Everything."
            case .outputMissing(let name): return "The selected output device is not connected: \(name)"
            case .invalidTarget: return "The virtual routing device cannot be used as the physical playback target."
            case .profileDisabled(let name): return "Activate the \(name) profile before using its EQ activation conditions."
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
