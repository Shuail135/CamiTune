import CamiTuneAudio
import CamiTuneDomain
import AppKit
import Combine
import Darwin
import Foundation

struct PerAppAudioApplication: Identifiable, Hashable, Sendable {
    var id: String
    var bundleID: String?
    var bundleURL: URL?
    var processID: Int32
    var displayName: String
    var isActive: Bool
    var level: Double
    var settings: PerAppAudioSettings
}

struct PerAppDriverClient: Hashable, Sendable {
    var deviceObjectID: UInt32 = 0
    var clientID: UInt32
    var processID: Int32
    var bundleID: String?
    var isActive: Bool
    var generation: UInt64

    var transportKey: PerAppTransportClientKey {
        PerAppTransportClientKey(deviceObjectID: deviceObjectID, clientID: clientID)
    }

    var applicationKey: String {
        if let bundleID = PerAppClientRegistry.canonicalApplicationBundleID(bundleID) {
            return bundleID
        }
        return "pid:\(processID)"
    }
}

struct PerAppAudioPacket: Sendable {
    var deviceObjectID: UInt32
    var clientID: UInt32
    var processID: Int32
    var cycleCounter: UInt64
    var sampleTime: Double
    var interleaved: [Float]
    var channelCount: Int
    var sampleRate: Double
    var channelLayout: LPCMChannelLayout

    init(
        deviceObjectID: UInt32 = 0,
        clientID: UInt32,
        processID: Int32 = 0,
        cycleCounter: UInt64,
        sampleTime: Double,
        interleaved: [Float],
        channelCount: Int,
        sampleRate: Double,
        channelLayout: LPCMChannelLayout? = nil
    ) {
        self.deviceObjectID = deviceObjectID
        self.clientID = clientID
        self.processID = processID
        self.cycleCounter = cycleCounter
        self.sampleTime = sampleTime
        self.interleaved = interleaved
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.channelLayout = channelLayout
            ?? LPCMChannelLayout.canonical(forChannelCount: channelCount)
            ?? LPCMChannelLayout(
                coreAudioTag: 0,
                roles: [ChannelRole](repeating: .unknown, count: max(0, channelCount))
            )
    }

    var transportKey: PerAppTransportClientKey {
        PerAppTransportClientKey(deviceObjectID: deviceObjectID, clientID: clientID)
    }
}

/// Composes client identity, settings, presentation, and the pre-global-DSP pipeline.
/// PerAppSettingsStore owns settings; PerAppDSPRuntime owns stream DSP history;
/// PerAppTimelineMixer owns timeline policy and pending PCM storage.
final class PerAppAudioController: ObservableObject, @unchecked Sendable {
    @Published private(set) var applications: [PerAppAudioApplication] = []
    private var playbackContext: PerAppPlaybackContext?

    private let timelineMixer: PerAppTimelineMixer

    private struct HeadroomKey: Hashable, Sendable {
        var applicationID: String
        var sampleRate: Double
        var settingsRevision: UInt64
    }

    private typealias ApplicationIdentity = PerAppPresentationIdentity
    private typealias ObservedAudioSource = PerAppObservedAudioSource

    private static let applicationActivityFloor = pow(10.0, -72.0 / 20.0)
    private static let meterDecayTime: TimeInterval = 0.8

    // Keep UI/control state separate from real-time-ish DSP runtime state.
    // MainActor code may take `stateLock`, but it must never wait on `audioLock`.
    private let stateLock = NSLock()
    private let audioLock = NSLock()
    // Headroom cache synchronization is intentionally independent from the DSP
    // runtime lock. No 600-point response calculation may run while this lock
    // (or `audioLock`) is held.
    private let headroomLock = NSLock()
    @Published private(set) var persistenceError: String?
    private var publishedSaveSequence: UInt64 = 0 // Main-thread delivery only.
    private let settingsStore: PerAppSettingsStore
    let presentationStore: AppPresentationStore
    private let presentationObservationQueue = DispatchQueue(label: "CamiTune.AppObservations", qos: .utility)
    private let clientRegistry: PerAppClientRegistry
    private let audioMaintenanceQueue = DispatchQueue(
        label: "CamiTune.PerAppAudioMaintenance",
        qos: .userInitiated
    )
    private let headroomQueue = DispatchQueue(
        label: "CamiTune.PerAppAudioHeadroom",
        qos: .userInitiated
    )
    // Snapshot coalescing is isolated from both control state and DSP runtime.
    // The MainActor never acquires an NSLock in order to publish applications.
    let presentationPerformanceSource = PerformanceTraceSource()
    private let publicationQueue = DispatchQueue(
        label: "CamiTune.PerAppAudioPublication",
        qos: .userInteractive
    )

    // DSP state stays under audioLock; lightweight snapshots use stateLock.
    private let dspRuntime = PerAppDSPRuntime()
    private var publishedSourceDiagnostics: [PerAppTransportClientKey: SpatialInputDiagnostics] = [:]
    var spatialInputDiagnostics: [PerAppTransportClientKey: SpatialInputDiagnostics] {
        stateLock.lock(); defer { stateLock.unlock() }
        return publishedSourceDiagnostics
    }

    private var knownAudioApplicationIDs: Set<String>
    /// Runtime truth that PCM crossed the activity floor. These IDs may be
    /// temporary and are therefore never written to the history file.
    private var observedAudioIDs: Set<String> = []
    private var observedAudioSourcesByKey: [
        PerAppTransportClientKey: ObservedAudioSource
    ] = [:]
    // Presentation levels are copied out of the audio runtime after processing so
    // SwiftUI publishing never needs to acquire `audioLock`.
    private var presentationLevelsByApplication: [String: Double] = [:]
    private var levelsByApplication: [String: Double] = [:]
    private var lastAudibleDateByApplication: [String: Date] = [:]
    private var lastPacketDateByApplication: [String: Date] = [:]
    private var lastMeterUpdateByApplication: [String: Date] = [:]
    // Protected only by `headroomLock`. A cache miss is seeded with a cheap,
    // conservative scalar while the exact 600-point response is calculated on
    // `headroomQueue`.
    private var headroomScalars: [HeadroomKey: Float] = [:]
    private var pendingHeadroomKeys: Set<HeadroomKey> = []
    private var presentationRevision: UInt64 = 0
    private(set) var applicationPublicationRevision: UInt64 = 0 // MainActor delivery only.
    private var presentationPublisher: PerAppPresentationPublisher!
    var presentationStatistics: PresentationPublicationStatistics { presentationPublisher.statistics }

    init(
        settingsURL: URL = CamiTunePaths.perAppAudioSettingsURL,
        audioHistoryURL: URL? = nil,
        monitorsRunningApplications: Bool = true,
        timelinePolicy: TimelineReorderPolicyConfiguration = .developerEnvironment(),
        timelineClock: TimelinePolicyClock = .live,
        timelineStoragePolicy: TimelineStoragePolicy = .init(maximumPacketFrames: SystemAudioBridgeTransport.maximumPacketFrameCapacity),
        presentationStore: AppPresentationStore? = nil,
        publicationScheduling: PresentationPublicationScheduling? = nil,
        presentationRowsBuilder: @escaping @Sendable (PerAppPresentationInput) -> [PerAppAudioApplication] = { PerAppPresentationSnapshot.makeRows($0) }
    ) {
        timelineMixer = PerAppTimelineMixer(storagePolicy: timelineStoragePolicy, policyConfiguration: timelinePolicy, clock: timelineClock, policyTrace: TimelinePolicyTrace.developerEnvironment())
        settingsStore = PerAppSettingsStore(url: settingsURL)
        let presentation = presentationStore ?? AppPresentationStore(
            url: settingsURL.deletingLastPathComponent().appendingPathComponent(
                settingsURL.lastPathComponent == "PerAppAudio.json" ? "PerAppPresentation.json" : settingsURL.lastPathComponent + ".presentation"
            ),
            legacyHistoryURL: audioHistoryURL ?? settingsURL.appendingPathExtension("history")
        )
        self.presentationStore = presentation
        clientRegistry = PerAppClientRegistry(stateLock: stateLock, monitorsRunningApplications: monitorsRunningApplications)
        persistenceError = settingsStore.loadError
        knownAudioApplicationIDs = presentation.seenIDs
        presentationPublisher = PerAppPresentationPublisher(
            scheduling: publicationScheduling ?? .live(queue: publicationQueue), performance: presentationPerformanceSource,
            captureInput: { [weak self] in self?.capturePresentationInput() }, buildRows: presentationRowsBuilder,
            observeMetadata: { [weak self] in self?.observeForPresentation($0) }, deliver: { [weak self] snapshot in
                guard let self else { return }
                UIRenderPerformance.recordAppPublication()
                self.applicationPublicationRevision = snapshot.revision
                self.applications = snapshot.applications
            })
        clientRegistry.start(onResolved: { [weak self] resolved, clients, unresolved, revision, attempt in
            self?.applyResolvedIdentities(resolved, clients: clients, unresolvedActiveKeys: unresolved,
                revision: revision, attempt: attempt) ?? false
        }, onWorkspace: { [weak self] running, audio in
            guard let self else { return }
            self.stateLock.lock()
            self.clientRegistry.recordWorkspace(running: running, audio: audio)
            self.presentationRevision &+= 1
            self.stateLock.unlock()
            self.presentationPublisher.request(.immediate)
        })
        presentationPublisher.request(.immediate)
    }

    deinit {
        clientRegistry.shutdown()
        presentationPublisher.shutdown()
        _ = settingsStore.flush(settingsStore.snapshot)
        presentationObservationQueue.sync {}
        presentationStore.flushPendingSaveSynchronously()
    }

    func updateClients(_ clients: [PerAppDriverClient]) {
        let prepared = PerAppClientRegistry.ClientUpdate(clients)
        let nextClients = prepared.clientsByKey
        stateLock.lock()
        guard let revision = clientRegistry.replaceClients(prepared) else {
            stateLock.unlock()
            return
        }
        publishedSourceDiagnostics = publishedSourceDiagnostics.filter { nextClients[$0.key] != nil }
        presentationRevision &+= 1
        stateLock.unlock()

        for client in nextClients.values {
            PerAppClientRegistry.identityDebug(
                "client device=\(client.deviceObjectID) client=\(client.clientID) "
                    + "pid=\(client.processID) bundle=\(client.bundleID ?? "nil") "
                    + "active=\(client.isActive) generation=\(client.generation)"
            )
        }

        let activeClientKeys = Set(nextClients.keys)
        audioMaintenanceQueue.async { [weak self] in
            guard let self else { return }
            self.audioLock.lock()
            self.dspRuntime.retain(only: activeClientKeys)
            self.audioLock.unlock()
        }

        clientRegistry.scheduleIdentityResolution(
            clients: Array(nextClients.values),
            revision: revision,
            attempt: 0
        )
    }

    private func applyResolvedIdentities(
        _ resolved: [PerAppTransportClientKey: ApplicationIdentity],
        clients: [PerAppDriverClient],
        unresolvedActiveKeys: Set<PerAppTransportClientKey>,
        revision: UInt64,
        attempt: Int
    ) -> Bool {
        stateLock.lock()
        guard let hasAnotherRetry = clientRegistry.acceptResolution(resolved,
            unresolvedActiveKeys: unresolvedActiveKeys, revision: revision, attempt: attempt) else {
            stateLock.unlock()
            return false
        }

        var settingsChanged = false
        var presentationObservations: [AppPresentationObservation] = []
        var runtimeMigrations: [(from: String, to: String)] = []
        // Simultaneous identity retries use transport order, never dictionary
        // iteration, when several audio-proven temporary owners become stable.
        for client in clients.sorted(by: {
            $0.deviceObjectID == $1.deviceObjectID ? $0.clientID < $1.clientID : $0.deviceObjectID < $1.deviceObjectID
        }) {
            guard let identity = resolved[client.transportKey] else { continue }
            if var source = observedAudioSourcesByKey[client.transportKey],
               source.processID <= 0 || source.processID == client.processID {
                source.processID = identity.processID
                source.applicationID = identity.id
                source.identity = identity
                observedAudioSourcesByKey[client.transportKey] = source
            }
            let temporaryIDs = Set([
                client.applicationKey,
                "pid:\(client.processID)",
                "client:\(client.deviceObjectID):\(client.clientID)"
            ]).filter { $0 != identity.id }

            for temporaryID in temporaryIDs {
                if settingsStore.migrate(from: temporaryID, to: identity.id) {
                    settingsChanged = true
                }
                if let temporaryLevel = presentationLevelsByApplication.removeValue(
                    forKey: temporaryID
                ) {
                    presentationLevelsByApplication[identity.id] = max(
                        presentationLevelsByApplication[identity.id] ?? 0,
                        temporaryLevel
                    )
                }
                if observedAudioIDs.remove(temporaryID) != nil {
                    observedAudioIDs.insert(identity.id)
                }
                if knownAudioApplicationIDs.remove(temporaryID) != nil {
                    if PerAppApplicationIdentityPolicy.isPersistentApplicationID(identity.id) {
                        knownAudioApplicationIDs.insert(identity.id)
                    }
                }
                runtimeMigrations.append((temporaryID, identity.id))
            }
            if observedAudioIDs.contains(identity.id) || knownAudioApplicationIDs.contains(identity.id) {
                if PerAppApplicationIdentityPolicy.isPersistentApplicationID(identity.id) { knownAudioApplicationIDs.insert(identity.id) }
                presentationObservations.append(AppPresentationObservation(applicationID: identity.id,
                    systemDisplayName: identity.displayName, bundleID: identity.bundleID))
            }
        }
        let savedSettings = settingsStore.snapshot
        presentationRevision &+= 1
        stateLock.unlock()

        if settingsChanged { schedulePersistence(savedSettings) }
        observeForPresentation(presentationObservations)
        if !runtimeMigrations.isEmpty {
            audioMaintenanceQueue.async { [weak self] in
                guard let self else { return }
                self.audioLock.lock()
                for migration in runtimeMigrations {
                    if let temporaryLevel = self.levelsByApplication.removeValue(
                        forKey: migration.from
                    ) {
                        self.levelsByApplication[migration.to] = max(
                            self.levelsByApplication[migration.to] ?? 0,
                            temporaryLevel
                        )
                    }
                    Self.moveLatestDate(
                        from: migration.from,
                        to: migration.to,
                        in: &self.lastAudibleDateByApplication
                    )
                    Self.moveLatestDate(
                        from: migration.from,
                        to: migration.to,
                        in: &self.lastPacketDateByApplication
                    )
                    Self.moveLatestDate(
                        from: migration.from,
                        to: migration.to,
                        in: &self.lastMeterUpdateByApplication
                    )
                }
                self.audioLock.unlock()

                self.headroomLock.lock()
                for migration in runtimeMigrations {
                    self.headroomScalars = self.headroomScalars.filter {
                        $0.key.applicationID != migration.from
                    }
                    self.pendingHeadroomKeys = Set(self.pendingHeadroomKeys.filter {
                        $0.applicationID != migration.from
                    })
                }
                self.headroomLock.unlock()
            }
        }
        presentationPublisher.request(.immediate)
        return hasAnotherRetry
    }

    func settings(for applicationID: String) -> PerAppAudioSettings {
        stateLock.lock()
        defer { stateLock.unlock() }
        return settingsStore.settings(for: applicationID)
    }

    func hasProducedAudio(for applicationID: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return observedAudioIDs.contains(applicationID)
            || knownAudioApplicationIDs.contains(applicationID)
    }

    func setPlaybackContext(_ context: PerAppPlaybackContext?) {
        stateLock.lock()
        playbackContext = context
        stateLock.unlock()
    }

    @MainActor weak var history: UndoCoordinator?
    @MainActor private var pendingHistory: [String: PerAppAudioSettings] = [:]

    private func recordAudioEdit(_ id: String, name: String, finished: Bool, edit: () -> Void) {
        guard Thread.isMainThread else { edit(); return }
        withMainThreadHistory {
            guard history?.isReplaying != true else { return }
            let before = pendingHistory[id] ?? settings(for: id)
            let key = GestureKey(target: .application(id), control: "audio")
            if !finished, pendingHistory[id] == nil {
                history?.beginGesture(key: key, actionName: name,
                    contextName: presentationStore.currentDocument.displayName(for: id), target: .application(id), before: .perAppAudio(before))
            }
            edit()
            guard finished else { pendingHistory[id] = before; return }
            if pendingHistory.removeValue(forKey: id) != nil {
                history?.endGesture(key: key, after: .perAppAudio(settings(for: id)))
            } else {
                history?.record(actionName: name, contextName: presentationStore.currentDocument.displayName(for: id),
                    target: .application(id), before: .perAppAudio(before), after: .perAppAudio(settings(for: id)),
                    coalescingKey: name == "Adjust Volume" ? GestureKey(target: .application(id), control: "volume") : nil)
            }
        }
    }
    @MainActor
    func finishAudioInteraction(for id: String) {
        guard pendingHistory[id] != nil else { return }
        recordAudioEdit(id, name: "Edit App Audio", finished: true) {
            replaceSettings(settings(for: id), for: id)
        }
    }
    func replaceSettings(_ settings: PerAppAudioSettings, for applicationID: String) {
        var validated = settings
        validated.volume = settings.volume.isFinite ? min(max(settings.volume, 0), 1) : 1
        updateSettings(for: applicationID, resetFilterState: true, resetHeadroom: true) { $0 = validated }
    }

    func replaceSettingsBatch(_ replacements: [String: PerAppAudioSettings]) {
        stateLock.lock()
        for (id, var value) in replacements {
            value.volume = value.volume.isFinite ? min(max(value.volume, 0), 1) : 1
            settingsStore.update(for: id, invalidatesProcessing: true) { $0 = value }
        }
        let current = settingsStore.snapshot
        presentationRevision &+= 1
        stateLock.unlock()
        schedulePersistence(current)
        presentationPublisher.request(.immediate)
    }

    func setPlaybackModeOverride(_ mode: PlaybackMode?, for applicationID: String) {
        recordAudioEdit(applicationID, name: "Change Playback Mode", finished: true) {
            updateSettings(for: applicationID) { $0.playbackModeOverride = mode }
        }
    }
    
    func setPlaybackModeForAllApplications(_ mode: PlaybackMode) {
        let applicationIDs = applications.map(\.id)
        let before = Dictionary(uniqueKeysWithValues: applicationIDs.map { ($0, settings(for: $0)) })
        let after = before.mapValues { value in
            var updated = value; updated.playbackModeOverride = mode; return updated
        }
        replaceSettingsBatch(after)
        if Thread.isMainThread {
            withMainThreadHistory {
                history?.record(actionName: "Change All App Playback Modes", target: .applicationPresentationDocument,
                    before: .perAppBatch(before), after: .perAppBatch(after))
            }
        }
    }

    func effectivePlaybackMode(for override: PlaybackMode?, fallbackProfile: DeviceProfile) -> PlaybackMode {
        stateLock.lock()
        let context = playbackContext
        stateLock.unlock()
        return (context ?? PerAppPlaybackContext(profile: fallbackProfile)).effectiveMode(for: override)
    }

    func setVolume(
        _ volume: Double,
        for applicationID: String,
        interactionFinished: Bool = true
    ) {
        recordAudioEdit(applicationID, name: "Adjust Volume", finished: interactionFinished) {
            updateSettings(
                for: applicationID,
                persistChanges: interactionFinished,
                forcePublication: interactionFinished
            ) {
                $0.volume = min(max(volume, 0), 1)
            }
        }
    }

    func setMeterPresentationActive(_ active: Bool, source: String) {
        stateLock.lock(); presentationRevision &+= 1; stateLock.unlock()
        if presentationPublisher.setActive(active, source: source) {
            clientRegistry.scheduleRunningApplicationRefresh(immediate: true)
            presentationPublisher.request(.immediate)
        }
    }

    func setMeterPresentationSuspended(_ suspended: Bool, source: String) {
        stateLock.lock(); presentationRevision &+= 1; stateLock.unlock()
        if presentationPublisher.setSuspended(suspended, source: source) {
            clientRegistry.scheduleRunningApplicationRefresh(immediate: true)
            presentationPublisher.request(.immediate)
        }
    }

    func setMuted(_ muted: Bool, for applicationID: String) {
        recordAudioEdit(applicationID, name: "Toggle Mute", finished: true) {
            updateSettings(for: applicationID) { $0.isMuted = muted }
        }
    }

    func setEQBypassed(_ bypassed: Bool, for applicationID: String) {
        recordAudioEdit(applicationID, name: "Toggle Equalizer", finished: true) {
            updateSettings(
                for: applicationID,
                resetFilterState: true,
                resetHeadroom: true
            ) { $0.eqBypassed = bypassed }
        }
    }

    func setSimpleTone(_ tone: SimpleToneSettings, for applicationID: String, interactionFinished: Bool = true) {
        recordAudioEdit(applicationID, name: "Adjust Tone", finished: interactionFinished) {
            guard (try? tone.validate()) != nil else { return }
            updateSettings(for: applicationID, resetFilterState: true, resetHeadroom: true, persistChanges: interactionFinished, forcePublication: interactionFinished, performDeferredCleanup: interactionFinished) { $0.simpleTone = tone }
        }
    }

    func setEqualizerBands(
        _ bands: [EQBand],
        for applicationID: String,
        interactionFinished: Bool = true
    ) {
        recordAudioEdit(applicationID, name: "Edit App Equalizer", finished: interactionFinished) {
            updateSettings(
                for: applicationID,
                resetFilterState: true,
                resetHeadroom: true,
                persistChanges: interactionFinished,
                forcePublication: interactionFinished,
                performDeferredCleanup: interactionFinished
            ) { $0.equalizerBands = bands }
        }
    }

    func editEqualizer(for applicationID: String, interactionFinished: Bool = true,
                       _ edit: (inout PerAppAudioSettings) -> Void) {
        recordAudioEdit(applicationID, name: "Edit App Equalizer", finished: interactionFinished) {
            updateSettings(for: applicationID, resetFilterState: true, resetHeadroom: true,
                persistChanges: interactionFinished, forcePublication: interactionFinished,
                performDeferredCleanup: interactionFinished) {
                $0.eqBypassed = false
                edit(&$0)
            }
        }
    }

    func ingest(_ packet: PerAppAudioPacket, now: Date? = nil, performance: PacketPerformanceContext? = nil) -> PCMFrame? {
        var processed = packet.interleaved
        var wake: TimeInterval?
        return ingest(packet, processed: &processed, now: now, performance: performance, nextWake: &wake)
    }

    /// Copies the transport's reusable C read buffer directly into the one
    /// mutable array used for DSP/mixing. This avoids first allocating a
    /// packet Array and then triggering a second copy-on-write allocation when
    /// per-app processing mutates it.
    func ingestTransportPacket(
        _ metadata: PerAppAudioPacket,
        samples: UnsafeBufferPointer<Float>,
        sampleCount: Int,
        performance: PacketPerformanceContext? = nil
    ) -> PCMFrame? {
        ingestTransportPacketWithTimelineWake(metadata, samples: samples, sampleCount: sampleCount, performance: performance).frame
    }

    func ingestTransportPacketWithTimelineWake(
        _ metadata: PerAppAudioPacket,
        samples: UnsafeBufferPointer<Float>,
        sampleCount: Int,
        performance: PacketPerformanceContext? = nil
    ) -> PerAppAudioIngestResult {
        guard sampleCount >= 0, sampleCount <= samples.count else { return .init(frame: nil, nextTimelineWakeAfter: nil) }
        var processed = Array<Float>(unsafeUninitializedCapacity: sampleCount) {
            destination, initializedCount in
            if sampleCount > 0 {
                destination.baseAddress!.initialize(
                    from: samples.baseAddress!,
                    count: sampleCount
                )
            }
            initializedCount = sampleCount
        }
        var wake: TimeInterval?
        let frame = ingest(metadata, processed: &processed, performance: performance, nextWake: &wake)
        return .init(frame: frame, nextTimelineWakeAfter: wake)
    }

    private func ingest(
        _ packet: PerAppAudioPacket,
        processed: inout [Float],
        now suppliedNow: Date? = nil,
        performance incomingPerformance: PacketPerformanceContext? = nil,
        nextWake: inout TimeInterval?
    ) -> PCMFrame? {
        guard (1...32).contains(packet.channelCount),
              packet.channelLayout.channelCount == packet.channelCount,
              packet.sampleRate > 0,
              packet.sampleRate.isFinite,
              processed.count % packet.channelCount == 0,
              let packetStartSampleTime = Self.integerSampleTime(packet.sampleTime) else {
            return nil
        }
        let packetFrameCount = processed.count / packet.channelCount
        guard packetFrameCount > 0, !packetStartSampleTime.addingReportingOverflow(Int64(packetFrameCount)).overflow else { return nil }

        // The driver publishes the exact (device, client) identity, but its
        // client-registry notification and PCM packet are independent real-time
        // paths. During a registry refresh, use PID (then unique client ID) as a
        // bounded fallback so the slider, meter, EQ and audio packet all resolve
        // to the same application instead of silently falling back to unity.
        stateLock.lock()
        let streamIdentity = clientRegistry.resolveStream(packet)
        let dspClientKey = packet.transportKey
        let observedSourceCandidate = observedAudioSourcesByKey[dspClientKey]
        let currentProcessID = streamIdentity.processID ?? 0
        let observedSource = observedSourceCandidate.flatMap { source in
            currentProcessID <= 0 || source.processID <= 0
                || source.processID == currentProcessID ? source : nil
        }
        let identity = streamIdentity.application ?? observedSource?.identity
        let applicationID = identity?.id ?? observedSource?.applicationID ?? streamIdentity.fallbackApplicationID
        let settings = settingsStore.settings(for: applicationID)
        let playbackMode = playbackContext?.effectiveMode(for: settings.playbackModeOverride) ?? .direct
        let settingsRevision = settingsStore.revision(for: applicationID)
        stateLock.unlock()

        let rawPeak = processed.reduce(0.0) { max($0, Double(abs($1))) }
        let now = suppliedNow ?? Date()
        let policyTick = incomingPerformance.map { _ in PerformanceClock.now() }
        let eqHeadroom: Float
        if settings.isMuted || settings.eqBypassed || !settings.hasEqualizerProcessing {
            eqHeadroom = 1
        } else {
            eqHeadroom = headroomScalarForIngest(
                settings,
                applicationID: applicationID,
                sampleRate: packet.sampleRate,
                settingsRevision: settingsRevision
            )
        }

        audioLock.lock()

        let timelineInstant = timelineMixer.policyInstant()

        // mIOCycleCounter belongs to an IO thread and can restart when that
        // thread resynchronizes. The output sample timestamp is the shared
        // device clock, so only a real sample-timeline rewind starts a new
        // epoch. This clears stale DSP history without ever blacklisting a
        // client because its cycle ordinal changed.
        let descriptor = PerAppTimelinePacket(deviceObjectID: packet.deviceObjectID,
            cycleCounter: packet.cycleCounter, startSampleTime: packetStartSampleTime, frameCount: packetFrameCount,
            channelCount: packet.channelCount, sampleRate: packet.sampleRate, channelLayout: packet.channelLayout,
            playbackMode: playbackMode)
        let preparation = timelineMixer.preparePacket(descriptor)
        guard preparation.isValid else { audioLock.unlock(); return nil }
        if preparation.requiresClientDSPReset {
            dspRuntime.reset(deviceObjectID: packet.deviceObjectID)
        }
        var performance = incomingPerformance
        performance?.policyTick = policyTick
        performance?.identity.streamEpoch = preparation.streamEpoch

        let sourceDiagnostics = dspRuntime.process(
            &processed, packet: descriptor, clientKey: dspClientKey,
            processID: currentProcessID, generation: streamIdentity.generation,
            settings: settings, settingsRevision: settingsRevision,
            targetGain: settings.isMuted ? 0 : Float(settings.volume) * eqHeadroom
        )
        lastPacketDateByApplication[applicationID] = now
        if rawPeak >= Self.applicationActivityFloor {
            lastAudibleDateByApplication[applicationID] = now
        }

        let processingCompleted = performance.map { _ in PerformanceClock.now() }
        let outputPeak = processed.reduce(0.0) { max($0, Double(abs($1))) }
        let elapsed = now.timeIntervalSince(
            lastMeterUpdateByApplication[applicationID] ?? now
        )
        let decayedLevel = (levelsByApplication[applicationID] ?? 0)
            * Self.meterDecayFactor(elapsed: elapsed)
        levelsByApplication[applicationID] = max(
            Self.normalizedMeterLevel(forPeak: outputPeak),
            decayedLevel
        )
        lastMeterUpdateByApplication[applicationID] = now

        let completed = processed.withUnsafeBufferPointer {
            timelineMixer.mixProcessedPacket(preparation, samples: $0, policyNow: timelineInstant,
                performance: performance, processingCompleted: processingCompleted)
        }
        nextWake = timelineMixer.nextWakeDelay()
        let reorderEvidence = timelineMixer.lastReorderEvidence
        let timelineWork = timelineMixer.lastWork
        let presentationLevel = levelsByApplication[applicationID] ?? 0
        audioLock.unlock()
        if let performance, let processingCompleted {
            performance.capture.append(.packet(.init(identity: performance.identity, received: performance.received, processed: processingCompleted, timeline: timelineWork, reorder: reorderEvidence)))
        }

        var presentationObservation: AppPresentationObservation?
        stateLock.lock()
        if publishedSourceDiagnostics.count >= 256, let oldest = publishedSourceDiagnostics.keys.first {
            publishedSourceDiagnostics.removeValue(forKey: oldest)
        }
        publishedSourceDiagnostics[dspClientKey] = sourceDiagnostics
        presentationRevision &+= 1
        presentationLevelsByApplication[applicationID] = presentationLevel
        if rawPeak >= Self.applicationActivityFloor {
            observedAudioIDs.insert(applicationID)
            let existingSource = observedAudioSourcesByKey[dspClientKey]
            let sourceIdentity = identity
                ?? (existingSource?.applicationID == applicationID
                    ? existingSource?.identity
                    : nil)
            observedAudioSourcesByKey[dspClientKey] = ObservedAudioSource(
                transportKey: dspClientKey,
                processID: streamIdentity.processID ?? existingSource?.processID ?? 0,
                applicationID: applicationID,
                identity: sourceIdentity
            )
            if PerAppApplicationIdentityPolicy.isPersistentApplicationID(applicationID),
               knownAudioApplicationIDs.insert(applicationID).inserted {
                presentationObservation = AppPresentationObservation(applicationID: applicationID,
                    systemDisplayName: sourceIdentity?.displayName, bundleID: sourceIdentity?.bundleID)
            }
        }
        stateLock.unlock()
        if let presentationObservation { observeForPresentation([presentationObservation]) }
        let publicationStarted = performance.map { _ in PerformanceClock.now() }
        presentationPublisher.request(.meter)
        performance?.capture.recordPresentation("Packet publication request", from: publicationStarted)
        return completed
    }

    func flushExpiredMix(now suppliedNow: Date? = nil, policyNow: PerformanceTick? = nil, transportRead: TimelineTransportReadObservation? = nil) -> PerAppMixFlushResult {
        audioLock.lock()
        let now = suppliedNow ?? Date()
        let result = timelineMixer.flushExpired(policyNow: policyNow, transportRead: transportRead)
        if case .retryAfter = result { audioLock.unlock(); return result }
        decayLevelsLocked(now: now)
        let presentationLevels = levelsByApplication
        audioLock.unlock()
        stateLock.lock()
        presentationRevision &+= 1
        presentationLevelsByApplication = presentationLevels
        stateLock.unlock()
        presentationPublisher.request(.meter)
        return result
    }

    /// Called only by the transport reader after ordered producer evidence has
    /// closed this interval. Per-client DSP consumes each released slice once.
    func ingestCompletedInterval(_ interval: ProducerCompletedInterval) throws -> PCMFrame {
        audioLock.lock()
        do {
            try timelineMixer.beginCompletedInterval(interval)
            if interval.beginsEpoch {
                dspRuntime.reset(deviceObjectID: interval.device)
            }
            audioLock.unlock()
        } catch { audioLock.unlock(); throw error }
        for source in interval.contributions {
            let packet = PerAppAudioPacket(deviceObjectID: source.device, clientID: source.client,
                processID: source.process, cycleCounter: source.cycle, sampleTime: Double(source.start),
                interleaved: source.samples, channelCount: source.channels, sampleRate: source.rate,
                channelLayout: source.layout)
            var performance = source.performance
            performance?.identity.startSampleTime = source.start
            performance?.identity.frameCount = source.frames
            _ = ingest(packet, performance: performance)
        }
        audioLock.lock(); defer { audioLock.unlock() }
        return try timelineMixer.finishCompletedInterval(interval)
    }

    /// Developer harness calls this after deactivation; no PCM callback can own the trace.
    func exportTimelinePolicyTrace(to url: URL) throws {
        audioLock.lock()
        let document = timelineMixer.policyTraceDocument()
        audioLock.unlock()
        try document?.export(to: url)
    }

    /// UI diagnostics must never wait for the audio lock. String formatting is
    /// done by the caller after this cheap value snapshot has released it.
    func timelineStatisticsSnapshot() -> PerAppTimelineMixerStatistics? {
        guard audioLock.try() else { return nil }
        defer { audioLock.unlock() }
        return timelineMixer.statisticsSnapshot()
    }

    func resetRuntimeWithoutBlockingUI() async {
        await Task.detached(priority: .userInitiated) { [self] in
            resetRuntime()
        }.value
    }

    func resetRuntime() {
        stateLock.lock(); publishedSourceDiagnostics.removeAll(); stateLock.unlock()
        audioLock.lock()
        timelineMixer.reset()
        dspRuntime.reset()
        levelsByApplication.removeAll()
        lastAudibleDateByApplication.removeAll()
        lastPacketDateByApplication.removeAll()
        lastMeterUpdateByApplication.removeAll()
        audioLock.unlock()
        headroomLock.lock()
        headroomScalars.removeAll()
        pendingHeadroomKeys.removeAll()
        headroomLock.unlock()
        stateLock.lock()
        presentationLevelsByApplication.removeAll()
        presentationRevision &+= 1
        observedAudioSourcesByKey.removeAll()
        stateLock.unlock()
        presentationPublisher.request(.immediate)
    }

    private func updateSettings(
        for applicationID: String,
        resetFilterState: Bool = false,
        resetHeadroom: Bool = false,
        persistChanges: Bool = true,
        forcePublication: Bool = true,
        performDeferredCleanup: Bool = true,
        change: (inout PerAppAudioSettings) -> Void
    ) {
        stateLock.lock()
        settingsStore.update(for: applicationID,
            invalidatesProcessing: resetFilterState || resetHeadroom, change: change)
        let settingsRevision = settingsStore.revision(for: applicationID)
        let saved = persistChanges ? settingsStore.snapshot : nil
        presentationRevision &+= 1
        stateLock.unlock()

        // Correctness no longer depends on maintenance running before the next
        // packet: `settingsRevision` is part of both the filter-bank and
        // headroom signatures. Cleanup happens away from MainActor so an EQ
        // drag cannot wait behind DSP processing.
        if resetHeadroom && performDeferredCleanup {
            audioMaintenanceQueue.async { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                let isCurrentRevision =
                    self.settingsStore.revision(for: applicationID) == settingsRevision
                self.stateLock.unlock()
                guard isCurrentRevision else { return }

                self.headroomLock.lock()
                self.headroomScalars = self.headroomScalars.filter {
                    $0.key.applicationID != applicationID
                        || $0.key.settingsRevision == settingsRevision
                }
                self.pendingHeadroomKeys = Set(self.pendingHeadroomKeys.filter {
                    $0.applicationID != applicationID
                        || $0.settingsRevision == settingsRevision
                })
                self.headroomLock.unlock()
            }
        }
        if let saved {
            schedulePersistence(saved)
        }
        presentationPublisher.request(forcePublication ? .immediate : .meter)
    }

    private static func integerSampleTime(_ sampleTime: Double) -> Int64? {
        guard sampleTime.isFinite else { return nil }
        let rounded = sampleTime.rounded()
        guard rounded >= Double(Int64.min), rounded < Double(Int64.max) else {
            return nil
        }
        return Int64(rounded)
    }

    /// Keep gain continuous at packet boundaries. Applying one scalar to an
    /// entire block makes interactive volume changes sound like zipper noise.


    private func decayLevelsLocked(now: Date) {
        for key in levelsByApplication.keys {
            let elapsed = now.timeIntervalSince(lastMeterUpdateByApplication[key] ?? now)
            levelsByApplication[key, default: 0] *= Self.meterDecayFactor(elapsed: elapsed)
            lastMeterUpdateByApplication[key] = now
            if levelsByApplication[key, default: 0] < 0.001 {
                levelsByApplication[key] = 0
            }
        }
    }

    private func capturePresentationInput() -> PerAppPresentationInput {
        stateLock.lock(); defer { stateLock.unlock() }
        // Detach storage under the existing state lock, then release it before
        // identity merge, row creation, sorting, metadata diff, or Main delivery.
        func copy<K, V>(_ values: [K: V]) -> [K: V] { Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0.value) }) }
        return .init(revision: presentationRevision, clients: Array(clientRegistry.clientsByKey.values),
            identities: copy(clientRegistry.identitiesByClientKey), workspaceIdentities: copy(clientRegistry.workspaceIdentitiesByProcessID),
            runningApplications: copy(clientRegistry.runningApplicationsByID), settings: copy(settingsStore.snapshot.settings),
            levels: copy(presentationLevelsByApplication), knownAudioApplications: Set(knownAudioApplicationIDs.map { $0 }),
            observedAudioApplications: Set(observedAudioIDs.map { $0 }), observedAudioSources: Array(observedAudioSourcesByKey.values),
            exhaustedClientKeys: Set(clientRegistry.identityRetryExhaustedClientKeys.map { $0 }))
    }

    static func normalizedMeterLevel(forPeak peak: Double) -> Double {
        guard peak.isFinite, peak > 0 else { return 0 }
        let decibels = 20 * log10(peak)
        return min(1, max(0, (decibels + 72) / 72))
    }

    private static func meterDecayFactor(elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return 1 }
        return pow(0.1, elapsed / meterDecayTime)
    }

    private static func moveLatestDate(
        from sourceID: String,
        to destinationID: String,
        in dates: inout [String: Date]
    ) {
        guard let source = dates.removeValue(forKey: sourceID) else { return }
        dates[destinationID] = max(dates[destinationID] ?? .distantPast, source)
    }

    /// Apple ships a small group of document, account, and maintenance apps
    /// that do not own a media playback path. Hide those idle Dock processes,
    /// while the presentation snapshot builder still lets direct audio history override
    /// this conservative classification if macOS changes their behavior.

    /// Resolve the process that actually produced a PCM packet to its owning
    /// application. Background/helper processes (Chrome, Electron, WebKit) may
    /// have a prohibited activation policy even though their outer .app owns
    /// the user-facing volume row, so packet attribution must not use the
    /// visible-app filter.

    /// Core Audio hosts third-party AudioServerPlugIns in its own service
    /// process. That process is transport plumbing, not an application the
    /// user can control, so it must never become a per-app volume row.


    /// Browser and Electron audio normally originates in a nested helper
    /// process. Collapse its bundle identifier to the owning application even
    /// when Launch Services does not provide a bundle URL for that PID.

    private func headroomScalarForIngest(
        _ settings: PerAppAudioSettings,
        applicationID: String,
        sampleRate: Double,
        settingsRevision: UInt64
    ) -> Float {
        let key = HeadroomKey(
            applicationID: applicationID,
            sampleRate: sampleRate,
            settingsRevision: settingsRevision
        )

        // The steady-state packet path is only one short lookup. Compute the
        // fallback only after a miss, then double-check in case another packet
        // populated the cache while it was being derived.
        headroomLock.lock()
        if let cached = headroomScalars[key] {
            headroomLock.unlock()
            return cached
        }
        headroomLock.unlock()

        let fallback = Self.conservativeHeadroomScalar(settings)
        headroomLock.lock()
        if let cached = headroomScalars[key] {
            headroomLock.unlock()
            return cached
        }
        headroomScalars[key] = fallback
        let shouldCalculate = pendingHeadroomKeys.insert(key).inserted
        headroomLock.unlock()

        if shouldCalculate {
            scheduleExactHeadroomCalculation(
                for: key,
                settings: settings
            )
        }
        return fallback
    }

    private func scheduleExactHeadroomCalculation(
        for key: HeadroomKey,
        settings: PerAppAudioSettings
    ) {
        headroomQueue.async { [weak self] in
            guard let self else { return }

            // Rapid EQ drags can enqueue multiple revisions. Skip obsolete work
            // before doing the 600-point calculation.
            self.stateLock.lock()
            let isCurrentBeforeCalculation =
                self.settingsStore.revision(for: key.applicationID)
                    == key.settingsRevision
            self.stateLock.unlock()
            guard isCurrentBeforeCalculation else {
                self.finishHeadroomCalculation(for: key, scalar: nil)
                return
            }

            // Intentionally outside every lock and outside the ingest call.
            let exact = Self.headroomScalar(settings, sampleRate: key.sampleRate)

            self.stateLock.lock()
            let isStillCurrent =
                self.settingsStore.revision(for: key.applicationID)
                    == key.settingsRevision
            self.stateLock.unlock()
            self.finishHeadroomCalculation(
                for: key,
                scalar: isStillCurrent ? exact : nil
            )
        }
    }

    private func finishHeadroomCalculation(
        for key: HeadroomKey,
        scalar: Float?
    ) {
        headroomLock.lock()
        let wasPending = pendingHeadroomKeys.remove(key) != nil
        if wasPending, let scalar {
            headroomScalars[key] = scalar
        } else if scalar == nil {
            headroomScalars.removeValue(forKey: key)
        }
        headroomLock.unlock()
    }

    /// Fast first-packet protection used while exact headroom is calculated.
    /// Gain filters contribute their positive nominal gain; resonant filter
    /// types also receive a Q-derived margin. This intentionally errs toward
    /// temporary attenuation rather than allowing a boosted EQ to clip.
    private static func conservativeHeadroomScalar(
        _ settings: PerAppAudioSettings
    ) -> Float {
        var maximumBoostDB = 0.0
        for band in settings.processingBands(sampleRate: 48_000) where band.enabled {
            let gain = (band.gain ?? 0).isFinite ? (band.gain ?? 0) : 0
            let qValue = band.q ?? 0.70710678
            let q = qValue.isFinite && qValue > 0 ? qValue : 0.70710678

            switch band.kind {
            case .peaking:
                maximumBoostDB += max(0, gain)
            case .lowShelf, .highShelf:
                maximumBoostDB += max(0, gain) + resonanceMarginDB(forQ: q)
            case .lowPass, .highPass:
                maximumBoostDB += resonanceMarginDB(forQ: q)
            case .notch, .allPass:
                break
            }
        }
        guard maximumBoostDB.isFinite, maximumBoostDB > 0 else { return 1 }
        return Float(pow(10, -maximumBoostDB / 20))
    }

    private static func resonanceMarginDB(forQ q: Double) -> Double {
        let threshold = 1 / sqrt(2.0)
        guard q.isFinite, q > threshold else { return 0 }
        let denominatorSquared = 1 - 1 / (4 * q * q)
        guard denominatorSquared > 0 else { return 0 }
        let peak = q / sqrt(denominatorSquared)
        guard peak.isFinite, peak > 1 else { return 0 }
        return 20 * log10(peak)
    }

    private static func headroomScalar(
        _ settings: PerAppAudioSettings,
        sampleRate: Double
    ) -> Float {
        Float(pow(10, settings.automaticHeadroomDB(sampleRate: sampleRate) / 20))
    }

    private func schedulePersistence(_ settings: PerAppSettingsStore.Snapshot) {
        settingsStore.scheduleSave(settings) { [weak self] error in
            self?.publishPersistenceError(error)
        }
    }

    private func publishPersistenceError(_ result: PerAppSettingsStore.SaveResult) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.publishPersistenceError(result) }
            return
        }
        // A synchronous flush may publish before an older queued completion.
        guard result.sequence > publishedSaveSequence else { return }
        publishedSaveSequence = result.sequence
        if persistenceError != result.error { persistenceError = result.error }
    }

    private func observeForPresentation(_ observations: [AppPresentationObservation]) {
        guard !observations.isEmpty else { return }
        let store = presentationStore
        presentationObservationQueue.async {
            for observation in observations { store.observeAudioProvenApplication(observation) }
        }
    }

    func persistHistoryChanges() throws {
        stateLock.lock()
        let current = settingsStore.snapshot
        stateLock.unlock()
        let error = settingsStore.flush(current)
        if let error = error.error { throw ProfileSettingsError.runtime(error) }
    }

    /// Test/benchmark barrier for already-enqueued discovery/publication work.
    /// Does not force delayed identity retries or advance meter deadlines.
    func drainPresentationPreparation() async {
        await withCheckedContinuation { continuation in
            clientRegistry.afterIdentityWork { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { continuation.resume(); return }
                    self.publicationQueue.async {
                        DispatchQueue.main.async { continuation.resume() }
                    }
                }
            }
        }
    }

    func flushPendingSaveSynchronously() {
        stateLock.lock()
        let settings = settingsStore.snapshot
        stateLock.unlock()
        let error = settingsStore.flush(settings)
        publishPersistenceError(error)
        publicationQueue.sync {}
        presentationObservationQueue.sync {}
        presentationStore.flushPendingSaveSynchronously()
    }
}
