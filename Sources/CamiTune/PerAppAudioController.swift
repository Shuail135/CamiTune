import AppKit
import Combine
import Darwin
import Foundation

struct PerAppAudioSettings: Codable, Hashable, Sendable {
    var volume: Double = 1
    var isMuted = false
    var eqBypassed = true
    var equalizerBands: [EQBand] = []
    var playbackModeOverride: PlaybackMode?
    var simpleTone = SimpleToneSettings()
    /// Flat gain bands and disabled filters do not light the per-app EQ indicator.
    var isEqualizerActive: Bool {
        !eqBypassed && (!simpleTone.isNeutral
            || EQEditorSupport.hasMeaningfulProcessing(ParsedEQ(bands: equalizerBands)))
    }
    var hasEqualizerProcessing: Bool { !equalizerBands.isEmpty || !simpleTone.isNeutral }
    func processingBands(sampleRate: Double) -> [EQBand] {
        equalizerBands + (simpleTone.isNeutral ? [] : ((try? SimpleToneFilterFactory.filters(for: simpleTone, sampleRate: sampleRate)) ?? []))
    }
    enum CodingKeys: String, CodingKey { case volume, isMuted, eqBypassed, equalizerBands, playbackModeOverride, simpleTone }
}

extension PerAppAudioSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        eqBypassed = try c.decodeIfPresent(Bool.self, forKey: .eqBypassed) ?? true
        equalizerBands = try c.decodeIfPresent([EQBand].self, forKey: .equalizerBands) ?? []
        playbackModeOverride = try c.decodeIfPresent(PlaybackMode.self, forKey: .playbackModeOverride)
        simpleTone = try c.decodeIfPresent(SimpleToneSettings.self, forKey: .simpleTone) ?? SimpleToneSettings()
        try simpleTone.validate()
    }
}

/// Versioned routing settings; presentation identity/order remain in their own document.
struct PerAppAudioDocument: Codable {
    static let currentVersion = 1
    var schemaVersion = currentVersion
    var settings: [String: PerAppAudioSettings]

    static func decode(_ data: Data) throws -> [String: PerAppAudioSettings] {
        struct Header: Decodable { var schemaVersion: Int? }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        if let version = header.schemaVersion {
            guard version == currentVersion else {
                throw DecodingError.dataCorrupted(.init(codingPath: [],
                    debugDescription: "Unsupported per-app settings version."))
            }
            return try decoder.decode(Self.self, from: data).settings
        }
        return try decoder.decode([String: PerAppAudioSettings].self, from: data)
    }
}

struct PerAppPlaybackContext: Hashable, Sendable {
    var profileMode: PlaybackMode
    var visibleModes: [PlaybackMode]
    var readiness: [PlaybackMode: PlaybackModeReadiness]
    var availableModes: Set<PlaybackMode>

    init(profile: DeviceProfile) {
        visibleModes = profile.availablePlaybackModes
        readiness = Dictionary(uniqueKeysWithValues: visibleModes.map { ($0, profile.playbackReadiness($0)) })
        profileMode = profile.playbackMode
        availableModes = Set(profile.availablePlaybackModes.filter { profile.playbackReadiness($0).isReady })
    }

    func effectiveMode(for override: PlaybackMode?) -> PlaybackMode {
        guard let override, availableModes.contains(override) else { return availableModes.contains(profileMode) ? profileMode : .direct }
        return override
    }
}

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
        if let bundleID = PerAppAudioController.canonicalApplicationBundleID(bundleID) {
            return bundleID
        }
        return "pid:\(processID)"
    }
}

struct PerAppTransportClientKey: Hashable, Sendable {
    var deviceObjectID: UInt32
    var clientID: UInt32
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
    var sourceBufferedFrames: Int
    var sourceCapacityFrames: Int

    init(
        deviceObjectID: UInt32 = 0,
        clientID: UInt32,
        processID: Int32 = 0,
        cycleCounter: UInt64,
        sampleTime: Double,
        interleaved: [Float],
        channelCount: Int,
        sampleRate: Double,
        channelLayout: LPCMChannelLayout? = nil,
        sourceBufferedFrames: Int,
        sourceCapacityFrames: Int
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
        self.sourceBufferedFrames = sourceBufferedFrames
        self.sourceCapacityFrames = sourceCapacityFrames
    }

    var transportKey: PerAppTransportClientKey {
        PerAppTransportClientKey(deviceObjectID: deviceObjectID, clientID: clientID)
    }
}

enum PerAppMixFlushResult: Sendable {
    case idle
    case retryAfter(TimeInterval)
    case flushed(PCMFrame)
}

/// Owns client identity, persisted per-application controls, per-client EQ
/// state, and the pre-global-DSP application mixer.
final class PerAppAudioController: ObservableObject, @unchecked Sendable {
    @Published private(set) var applications: [PerAppAudioApplication] = []
    private var playbackContext: PerAppPlaybackContext?

    private var performanceEpoch: UInt64 = 0

    private struct PendingMix {
        var performanceTrace: MixPerformanceTrace? = nil
        var deviceObjectID: UInt32
        var startSampleTime: Int64
        var channelCount: Int
        var sampleRate: Double
        var channelLayout: LPCMChannelLayout
        var sourceBufferedFrames: Int
        var sourceCapacityFrames: Int
        var clientKeys: Set<PerAppTransportClientKey>
        var samples: [Float]
        var samplesByMode: [PlaybackMode: [Float]]
        var largestPacketFrames: Int
        var lastPacketDate: Date

        var frameCount: Int {
            channelCount > 0 ? samples.count / channelCount : 0
        }

        var endSampleTime: Int64 {
            startSampleTime + Int64(frameCount)
        }
    }

    private struct HeadroomKey: Hashable, Sendable {
        var applicationID: String
        var sampleRate: Double
        var settingsRevision: UInt64
    }

    private typealias ApplicationIdentity = PerAppPresentationIdentity
    private typealias ObservedAudioSource = PerAppObservedAudioSource

    private struct ResolvedApplicationOwner {
        var bundleID: String?
        var bundleURL: URL?
        var displayName: String
        var processID: Int32
        var activationPolicy: NSApplication.ActivationPolicy?

        var stableID: String {
            if let bundleID, !bundleID.isEmpty { return bundleID }
            if let bundleURL { return "app:\(bundleURL.standardizedFileURL.path)" }
            return "pid:\(processID)"
        }
    }

    private static let applicationActivityFloor = pow(10.0, -72.0 / 20.0)
    private static let meterDecayTime: TimeInterval = 0.8
    // Hold two observed packet lengths on the device sample timeline before
    // committing audio. MixOutput callbacks from different applications can
    // complete out of order and can use different IO buffer sizes. The device
    // sample timestamp is the common clock; mIOCycleCounter is not.
    private static let pendingMixHoldbackPackets = 2
    private static let timelineRestartRewindMultiplier = 4
    private static let timelineDiscontinuityMultiplier = 8
    private static let identityRetryDelays: [TimeInterval] = [0, 0.1, 0.25, 0.5, 1, 2]

    private static func identityDebug(_ message: @autoclosure () -> String) {
#if DEBUG
        print("[PerAppIdentity] \(message())")
#endif
    }

    // Keep UI/control state separate from real-time-ish DSP runtime state.
    // MainActor code may take `stateLock`, but it must never wait on `audioLock`.
    private let stateLock = NSLock()
    private let audioLock = NSLock()
    // Headroom cache synchronization is intentionally independent from the DSP
    // runtime lock. No 600-point response calculation may run while this lock
    // (or `audioLock`) is held.
    private let headroomLock = NSLock()
    @Published private(set) var persistenceError: String?
    private let settingsURL: URL
    let presentationStore: AppPresentationStore
    private let presentationObservationQueue = DispatchQueue(label: "CamiTune.AppObservations", qos: .utility)
    private let monitorsRunningApplications: Bool
    private let persistenceQueue = DispatchQueue(
        label: "CamiTune.PerAppAudioSettings",
        qos: .utility
    )
    private let identityQueue = DispatchQueue(
        label: "CamiTune.PerAppAudioIdentity",
        qos: .userInitiated
    )
    private let runningApplicationQueue = DispatchQueue(
        label: "CamiTune.RunningApplicationRoster",
        qos: .utility
    )
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
    private struct SourceDetector {
        var processID: Int32
        var generation: UInt64
        var detector = EffectiveLayoutDetector()
    }
    // DSP state stays under audioLock; lightweight snapshots use stateLock.
    private var sourceDetectors: [PerAppTransportClientKey: SourceDetector] = [:]
    private var publishedSourceDiagnostics: [PerAppTransportClientKey: SpatialInputDiagnostics] = [:]
    var spatialInputDiagnostics: [PerAppTransportClientKey: SpatialInputDiagnostics] {
        stateLock.lock(); defer { stateLock.unlock() }
        return publishedSourceDiagnostics
    }

    private var clientsByKey: [PerAppTransportClientKey: PerAppDriverClient] = [:]
    private var uniqueClientKeyByProcessID: [Int32: PerAppTransportClientKey] = [:]
    private var uniqueClientKeyByClientID: [UInt32: PerAppTransportClientKey] = [:]
    private var applicationKeyByProcessID: [Int32: String] = [:]
    private var identitiesByClientKey: [PerAppTransportClientKey: ApplicationIdentity] = [:]
    private var workspaceIdentitiesByProcessID: [Int32: ApplicationIdentity] = [:]
    private var runningApplicationsByID: [String: ApplicationIdentity] = [:]
    private var settingsByApplication: [String: PerAppAudioSettings]
    private var settingsRevisionByApplication: [String: UInt64] = [:]
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
    private var filterBanks: [PerAppTransportClientKey: PerAppFilterBank] = [:]
    private var gainsByClientKey: [PerAppTransportClientKey: Float] = [:]
    // Protected only by `headroomLock`. A cache miss is seeded with a cheap,
    // conservative scalar while the exact 600-point response is calculated on
    // `headroomQueue`.
    private var headroomScalars: [HeadroomKey: Float] = [:]
    private var pendingHeadroomKeys: Set<HeadroomKey> = []
    // Each driver endpoint owns an independent Core Audio sample timeline.
    // A pending buffer is an overlap-add window: application blocks are placed
    // at their output sample positions and summed before the safe prefix is
    // handed to the global DSP path.
    private var pendingMixesByDevice: [UInt32: PendingMix] = [:]
    private var lastEmittedEndSampleTimeByDevice: [UInt32: Int64] = [:]
    private var pendingPersistence: DispatchWorkItem?
    private var pendingRunningApplicationRefresh: DispatchWorkItem?
    private var identityRetryWorkItem: DispatchWorkItem?
    private var identityRetryExhaustedClientKeys: Set<PerAppTransportClientKey> = []
    private var presentationRevision: UInt64 = 0
    private(set) var applicationPublicationRevision: UInt64 = 0 // MainActor delivery only.
    private var presentationPublisher: PerAppPresentationPublisher!
    var presentationStatistics: PresentationPublicationStatistics { presentationPublisher.statistics }
    private var identityResolutionRevision: UInt64 = 0
    private var workspaceObservers: [NSObjectProtocol] = []

    init(
        settingsURL: URL = CamiTunePaths.perAppAudioSettingsURL,
        audioHistoryURL: URL? = nil,
        monitorsRunningApplications: Bool = true,
        presentationStore: AppPresentationStore? = nil,
        publicationScheduling: PresentationPublicationScheduling? = nil,
        presentationRowsBuilder: @escaping @Sendable (PerAppPresentationInput) -> [PerAppAudioApplication] = { PerAppPresentationSnapshot.makeRows($0) }
    ) {
        self.settingsURL = settingsURL
        let presentation = presentationStore ?? AppPresentationStore(
            url: settingsURL.deletingLastPathComponent().appendingPathComponent(
                settingsURL.lastPathComponent == "PerAppAudio.json" ? "PerAppPresentation.json" : settingsURL.lastPathComponent + ".presentation"
            ),
            legacyHistoryURL: audioHistoryURL ?? settingsURL.appendingPathExtension("history")
        )
        self.presentationStore = presentation
        self.monitorsRunningApplications = monitorsRunningApplications
        let loaded = Self.loadSettings(from: settingsURL)
        settingsByApplication = loaded.settings
        persistenceError = loaded.error
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
        if monitorsRunningApplications {
            observeWorkspaceApplications()
            scheduleRunningApplicationRefresh(immediate: true)
        }
        presentationPublisher.request(.immediate)
    }

    deinit {
        pendingPersistence?.cancel()
        pendingRunningApplicationRefresh?.cancel()
        identityRetryWorkItem?.cancel()
        presentationPublisher.shutdown()
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            notificationCenter.removeObserver(observer)
        }
        let settings = settingsByApplication
        let url = settingsURL
        _ = persistenceQueue.sync {
            Self.persist(settings, to: url)
        }
        presentationObservationQueue.sync {}
        presentationStore.flushPendingSaveSynchronously()
    }

    func updateClients(_ clients: [PerAppDriverClient]) {
        let nextClients = Dictionary(
            clients.map { ($0.transportKey, $0) },
            uniquingKeysWith: { current, candidate in
                current.generation >= candidate.generation ? current : candidate
            }
        )
        let uniquePIDKeys = Self.uniqueClientKeys(
            clients,
            key: { $0.processID },
            isUsable: { $0 > 0 }
        )
        let uniqueClientIDKeys = Self.uniqueClientKeys(
            clients,
            key: { $0.clientID },
            isUsable: { _ in true }
        )
        let applicationKeysByPID = Dictionary(grouping: clients.filter { $0.processID > 0 }) {
            $0.processID
        }.compactMapValues { matches -> String? in
            let applicationKeys = Set(matches.map(\.applicationKey))
            return applicationKeys.count == 1 ? applicationKeys.first : nil
        }
        stateLock.lock()
        let clientsChanged = clientsByKey != nextClients
        guard clientsChanged else {
            stateLock.unlock()
            return
        }
        publishedSourceDiagnostics = publishedSourceDiagnostics.filter { nextClients[$0.key] != nil }
        clientsByKey = nextClients
        identitiesByClientKey = identitiesByClientKey.filter { key, identity in
            nextClients[key]?.processID == identity.processID
        }
        uniqueClientKeyByProcessID = uniquePIDKeys
        uniqueClientKeyByClientID = uniqueClientIDKeys
        applicationKeyByProcessID = applicationKeysByPID
        identityResolutionRevision &+= 1
        let revision = identityResolutionRevision
        identityRetryWorkItem?.cancel()
        identityRetryWorkItem = nil
        identityRetryExhaustedClientKeys.removeAll()
        presentationRevision &+= 1
        stateLock.unlock()

        for client in nextClients.values {
            Self.identityDebug(
                "client device=\(client.deviceObjectID) client=\(client.clientID) "
                    + "pid=\(client.processID) bundle=\(client.bundleID ?? "nil") "
                    + "active=\(client.isActive) generation=\(client.generation)"
            )
        }

        let activeClientKeys = Set(nextClients.keys)
        audioMaintenanceQueue.async { [weak self] in
            guard let self else { return }
            self.audioLock.lock()
            self.sourceDetectors = self.sourceDetectors.filter { activeClientKeys.contains($0.key) }
            self.filterBanks = self.filterBanks.filter { activeClientKeys.contains($0.key) }
            self.gainsByClientKey = self.gainsByClientKey.filter {
                activeClientKeys.contains($0.key)
            }
            self.audioLock.unlock()
        }

        scheduleIdentityResolution(
            clients: Array(nextClients.values),
            revision: revision,
            attempt: 0
        )
    }

    private func scheduleIdentityResolution(
        clients: [PerAppDriverClient],
        revision: UInt64,
        attempt: Int
    ) {
        guard attempt < Self.identityRetryDelays.count else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let resolvedPairs: [(PerAppTransportClientKey, ApplicationIdentity)] =
                clients.compactMap { client -> (PerAppTransportClientKey, ApplicationIdentity)? in
                    guard let identity = Self.resolveApplicationIdentity(for: client) else {
                        Self.identityDebug(
                            "UNRESOLVED device=\(client.deviceObjectID) "
                                + "client=\(client.clientID) pid=\(client.processID) "
                                + "bundle=\(client.bundleID ?? "nil")"
                        )
                        return nil
                    }
                    Self.identityDebug(
                        "resolved pid=\(client.processID) -> id=\(identity.id) "
                            + "name=\(identity.displayName) "
                            + "url=\(identity.bundleURL?.path ?? "nil")"
                    )
                    return (client.transportKey, identity)
                }
            let resolved = Dictionary(uniqueKeysWithValues: resolvedPairs)
            let unresolvedActiveKeys = Set(clients.compactMap { client -> PerAppTransportClientKey? in
                guard client.isActive,
                      Self.isIdentityResolutionCandidate(client) else { return nil }
                guard let identity = resolved[client.transportKey],
                      !Self.isEphemeralApplicationID(identity.id) else {
                    return client.transportKey
                }
                return nil
            })

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let retry = self.applyResolvedIdentities(
                    resolved,
                    clients: clients,
                    unresolvedActiveKeys: unresolvedActiveKeys,
                    revision: revision,
                    attempt: attempt
                )
                if retry {
                    self.scheduleIdentityResolution(
                        clients: clients,
                        revision: revision,
                        attempt: attempt + 1
                    )
                }
            }
        }

        stateLock.lock()
        guard identityResolutionRevision == revision else {
            stateLock.unlock()
            return
        }
        identityRetryWorkItem?.cancel()
        identityRetryWorkItem = work
        stateLock.unlock()
        identityQueue.asyncAfter(
            deadline: .now() + Self.identityRetryDelays[attempt],
            execute: work
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
        guard identityResolutionRevision == revision else {
            stateLock.unlock()
            return false
        }
        identitiesByClientKey = resolved
        let hasAnotherRetry = !unresolvedActiveKeys.isEmpty
            && attempt + 1 < Self.identityRetryDelays.count
        identityRetryExhaustedClientKeys = hasAnotherRetry ? [] : unresolvedActiveKeys
        if !hasAnotherRetry { identityRetryWorkItem = nil }

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
                if let temporarySettings = settingsByApplication.removeValue(forKey: temporaryID) {
                    if settingsByApplication[identity.id] == nil {
                        settingsByApplication[identity.id] = temporarySettings
                    }
                    let temporaryRevision = settingsRevisionByApplication.removeValue(
                        forKey: temporaryID
                    ) ?? 0
                    settingsRevisionByApplication[identity.id] = max(
                        settingsRevisionByApplication[identity.id] ?? 0,
                        temporaryRevision
                    )
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
                    if Self.isPersistentApplicationID(identity.id) {
                        knownAudioApplicationIDs.insert(identity.id)
                    }
                }
                runtimeMigrations.append((temporaryID, identity.id))
            }
            if observedAudioIDs.contains(identity.id) || knownAudioApplicationIDs.contains(identity.id) {
                if Self.isPersistentApplicationID(identity.id) { knownAudioApplicationIDs.insert(identity.id) }
                presentationObservations.append(AppPresentationObservation(applicationID: identity.id,
                    systemDisplayName: identity.displayName, bundleID: identity.bundleID))
            }
        }
        let savedSettings = settingsByApplication
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

    private static func isIdentityResolutionCandidate(_ client: PerAppDriverClient) -> Bool {
        client.processID > 0
            && client.processID != Int32(ProcessInfo.processInfo.processIdentifier)
            && !isSystemAudioService(bundleID: client.bundleID)
    }

    func settings(for applicationID: String) -> PerAppAudioSettings {
        stateLock.lock()
        defer { stateLock.unlock() }
        return settingsByApplication[applicationID] ?? PerAppAudioSettings()
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
            settingsByApplication[id] = value
            settingsRevisionByApplication[id, default: 0] &+= 1
        }
        let current = settingsByApplication
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
            scheduleRunningApplicationRefresh(immediate: true)
            presentationPublisher.request(.immediate)
        }
    }

    func setMeterPresentationSuspended(_ suspended: Bool, source: String) {
        stateLock.lock(); presentationRevision &+= 1; stateLock.unlock()
        if presentationPublisher.setSuspended(suspended, source: source) {
            scheduleRunningApplicationRefresh(immediate: true)
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
        return ingest(packet, processed: &processed, now: now, performance: performance)
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
        guard sampleCount >= 0, sampleCount <= samples.count else { return nil }
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
        return ingest(metadata, processed: &processed, performance: performance)
    }

    private func ingest(
        _ packet: PerAppAudioPacket,
        processed: inout [Float],
        now suppliedNow: Date? = nil,
        performance incomingPerformance: PacketPerformanceContext? = nil
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
        guard packetFrameCount > 0 else { return nil }

        // The driver publishes the exact (device, client) identity, but its
        // client-registry notification and PCM packet are independent real-time
        // paths. During a registry refresh, use PID (then unique client ID) as a
        // bounded fallback so the slider, meter, EQ and audio packet all resolve
        // to the same application instead of silently falling back to unity.
        stateLock.lock()
        let resolvedClientKey: PerAppTransportClientKey? = {
            // HAL can recycle client IDs when an endpoint is republished. The
            // packet and registry are separate snapshots: a positive packet PID
            // must agree before any cached client identity can own this audio.
            func matchesProcess(_ key: PerAppTransportClientKey) -> Bool {
                guard let client = clientsByKey[key] else { return false }
                return packet.processID <= 0 || client.processID == packet.processID
            }
            if matchesProcess(packet.transportKey) { return packet.transportKey }
            if packet.processID > 0,
               let key = uniqueClientKeyByProcessID[packet.processID] {
                return key
            }
            if let key = uniqueClientKeyByClientID[packet.clientID], matchesProcess(key) { return key }
            return nil
        }()
        let client = resolvedClientKey.flatMap { clientsByKey[$0] }
        let packetIdentity = packet.processID > 0
            ? workspaceIdentitiesByProcessID[packet.processID]
            : nil
        // Identity fallbacks must not merge two actual callback streams into
        // the same gain ramp/filter history while the registry catches up.
        let dspClientKey = packet.transportKey
        let observedSourceCandidate = observedAudioSourcesByKey[dspClientKey]
        let currentProcessID = packet.processID > 0
            ? packet.processID
            : (client?.processID ?? 0)
        let observedSource = observedSourceCandidate.flatMap { source in
            currentProcessID <= 0 || source.processID <= 0
                || source.processID == currentProcessID ? source : nil
        }
        let identity = resolvedClientKey.flatMap { identitiesByClientKey[$0] }
            ?? packetIdentity
            ?? observedSource?.identity
        let packetApplicationKey = packet.processID > 0
            ? applicationKeyByProcessID[packet.processID]
            : nil
        let applicationID = identity?.id
            ?? observedSource?.applicationID
            ?? client?.applicationKey
            ?? packetApplicationKey
            ?? (packet.processID > 0 ? "pid:\(packet.processID)" : nil)
            ?? "client:\(packet.deviceObjectID):\(packet.clientID)"
        let settings = settingsByApplication[applicationID] ?? PerAppAudioSettings()
        let playbackMode = playbackContext?.effectiveMode(for: settings.playbackModeOverride) ?? .direct
        let settingsRevision = settingsRevisionByApplication[applicationID] ?? 0
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

        // mIOCycleCounter belongs to an IO thread and can restart when that
        // thread resynchronizes. The output sample timestamp is the shared
        // device clock, so only a real sample-timeline rewind starts a new
        // epoch. This clears stale DSP history without ever blacklisting a
        // client because its cycle ordinal changed.
        prepareTimelineEpochLocked(
            deviceObjectID: packet.deviceObjectID,
            packetStartSampleTime: packetStartSampleTime,
            packetFrameCount: packetFrameCount,
            sampleRate: packet.sampleRate,
            cycleCounter: packet.cycleCounter
        )

        var performance = incomingPerformance
        performance?.policyTick = policyTick
        if performance != nil, let mix = pendingMixesByDevice[packet.deviceObjectID],
           mix.channelCount != packet.channelCount || mix.channelLayout != packet.channelLayout
            || abs(mix.sampleRate - packet.sampleRate) >= 0.5
            || packetStartSampleTime - mix.endSampleTime > Int64(max(mix.largestPacketFrames, packetFrameCount) * Self.timelineDiscontinuityMultiplier) {
            performanceEpoch &+= 1
        }
        performance?.identity.streamEpoch = performanceEpoch

        if sourceDetectors[dspClientKey]?.processID != currentProcessID ||
            sourceDetectors[dspClientKey]?.generation != UInt64(client?.generation ?? 0) {
            if sourceDetectors.count >= 256, let oldest = sourceDetectors.keys.first {
                sourceDetectors.removeValue(forKey: oldest)
            }
            sourceDetectors[dspClientKey] = SourceDetector(processID: currentProcessID, generation: UInt64(client?.generation ?? 0))
        }
        sourceDetectors[dspClientKey]?.detector.ingest(PCMFrame(interleaved: processed,
            channelCount: packet.channelCount, sampleRate: packet.sampleRate, channelLayout: packet.channelLayout),
            sampleTime: packetStartSampleTime)
        let sourceDiagnostics = sourceDetectors[dspClientKey]?.detector.diagnostics
        lastPacketDateByApplication[applicationID] = now
        if rawPeak >= Self.applicationActivityFloor {
            lastAudibleDateByApplication[applicationID] = now
        }
        if !settings.isMuted && !settings.eqBypassed && settings.hasEqualizerProcessing {
            var bank = filterBanks[dspClientKey] ?? PerAppFilterBank()
            bank.process(
                &processed,
                channelCount: packet.channelCount,
                sampleRate: packet.sampleRate,
                bands: settings.equalizerBands,
                settingsRevision: settingsRevision, tone: settings.simpleTone
            )
            filterBanks[dspClientKey] = bank
        }
        let targetGain: Float = settings.isMuted
            ? 0
            : Float(settings.volume) * eqHeadroom
        applyGainRamp(
            to: &processed,
            channelCount: packet.channelCount,
            clientKey: dspClientKey,
            targetGain: targetGain
        )

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

        let completed = mixProcessedPacketLocked(
            packet,
            mode: playbackMode,
            packetStartSampleTime: packetStartSampleTime,
            samples: processed,
            clientKey: dspClientKey,
            now: now,
            performance: performance,
            processingCompleted: processingCompleted
        )
        let presentationLevel = levelsByApplication[applicationID] ?? 0
        audioLock.unlock()
        if let performance, let processingCompleted {
            performance.capture.append(.packet(.init(identity: performance.identity, received: performance.received, processed: processingCompleted)))
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
                processID: packet.processID > 0
                    ? packet.processID
                    : (client?.processID ?? existingSource?.processID ?? 0),
                applicationID: applicationID,
                identity: sourceIdentity
            )
            if Self.isPersistentApplicationID(applicationID),
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

    func flushExpiredMix(now suppliedNow: Date? = nil) -> PerAppMixFlushResult {
        audioLock.lock()
        let now = suppliedNow ?? Date()
        guard !pendingMixesByDevice.isEmpty else {
            decayLevelsLocked(now: now)
            let presentationLevels = levelsByApplication
            audioLock.unlock()
            stateLock.lock()
            presentationRevision &+= 1
            presentationLevelsByApplication = presentationLevels
            stateLock.unlock()
            presentationPublisher.request(.meter)
            return .idle
        }

        var selectedDevice: UInt32?
        var selectedDeadline = Date.distantFuture
        for (deviceObjectID, mix) in pendingMixesByDevice {
            let packetDuration = Double(max(1, mix.largestPacketFrames)) / mix.sampleRate
            let requiredDelay = max(0.004, packetDuration * 1.5)
            let deadline = mix.lastPacketDate.addingTimeInterval(requiredDelay)
            if deadline < selectedDeadline {
                selectedDeadline = deadline
                selectedDevice = deviceObjectID
            }
        }

        guard let selectedDevice else {
            audioLock.unlock()
            return .idle
        }
        guard now >= selectedDeadline else {
            audioLock.unlock()
            return .retryAfter(max(0.0005, selectedDeadline.timeIntervalSince(now)))
        }
        let execution = pendingMixesByDevice[selectedDevice]?.performanceTrace.map { _ in PerformanceClock.now() }
        let deadline: PerformanceTick? = pendingMixesByDevice[selectedDevice].flatMap { mix in
            mix.performanceTrace.map { trace in
                trace.lastPolicyTick.advanced(seconds: max(0.004, Double(max(1, mix.largestPacketFrames)) / mix.sampleRate * 1.5))
            }
        }
        guard let completed = emitAllPendingMixLocked(for: selectedDevice, eligible: deadline ?? execution, idleDeadline: deadline, idleFlushStarted: execution) else {
            audioLock.unlock()
            return .idle
        }
        decayLevelsLocked(now: now)
        let presentationLevels = levelsByApplication
        audioLock.unlock()
        stateLock.lock()
        presentationRevision &+= 1
        presentationLevelsByApplication = presentationLevels
        stateLock.unlock()
        presentationPublisher.request(.meter)
        return .flushed(completed)
    }

    func resetRuntimeWithoutBlockingUI() async {
        await Task.detached(priority: .userInitiated) { [self] in
            resetRuntime()
        }.value
    }

    func resetRuntime() {
        stateLock.lock(); publishedSourceDiagnostics.removeAll(); stateLock.unlock()
        audioLock.lock()
        pendingMixesByDevice.removeAll(keepingCapacity: true)
        performanceEpoch &+= 1
        lastEmittedEndSampleTimeByDevice.removeAll(keepingCapacity: true)
        sourceDetectors.removeAll()
        filterBanks.removeAll()
        gainsByClientKey.removeAll()
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
        var settings = settingsByApplication[applicationID] ?? PerAppAudioSettings()
        change(&settings)
        settingsByApplication[applicationID] = settings
        if resetFilterState || resetHeadroom {
            settingsRevisionByApplication[applicationID, default: 0] &+= 1
        }
        let settingsRevision = settingsRevisionByApplication[applicationID] ?? 0
        let saved = persistChanges ? settingsByApplication : nil
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
                    self.settingsRevisionByApplication[applicationID] == settingsRevision
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

    private static func uniqueClientKeys<Key: Hashable>(
        _ clients: [PerAppDriverClient],
        key: (PerAppDriverClient) -> Key,
        isUsable: (Key) -> Bool
    ) -> [Key: PerAppTransportClientKey] {
        var result: [Key: PerAppTransportClientKey] = [:]
        var ambiguous: Set<Key> = []
        for client in clients {
            let value = key(client)
            guard isUsable(value), !ambiguous.contains(value) else { continue }
            if let existing = result[value], existing != client.transportKey {
                result.removeValue(forKey: value)
                ambiguous.insert(value)
            } else if result[value] == nil {
                result[value] = client.transportKey
            }
        }
        return result
    }

    private static func integerSampleTime(_ sampleTime: Double) -> Int64? {
        guard sampleTime.isFinite else { return nil }
        let rounded = sampleTime.rounded()
        guard rounded >= Double(Int64.min), rounded <= Double(Int64.max) else {
            return nil
        }
        return Int64(rounded)
    }

    private func prepareTimelineEpochLocked(
        deviceObjectID: UInt32,
        packetStartSampleTime: Int64,
        packetFrameCount: Int,
        sampleRate: Double,
        cycleCounter: UInt64
    ) {
        guard packetFrameCount > 0 else { return }
        let packetEnd = packetStartSampleTime + Int64(packetFrameCount)
        let emittedEnd = lastEmittedEndSampleTimeByDevice[deviceObjectID]
        let pendingEnd = pendingMixesByDevice[deviceObjectID]?.endSampleTime
        guard let referenceEnd = [emittedEnd, pendingEnd].compactMap({ $0 }).max() else {
            return
        }

        let nominalRewindFrames = max(
            packetFrameCount * Self.timelineRestartRewindMultiplier,
            Int(max(1, sampleRate) * 0.1)
        )
        let rewindFrames = referenceEnd - packetEnd
        // A true IO restart normally recycles mIOCycleCounter near zero. Use
        // that only as a restart hint after the device sample timeline itself
        // has made a large backwards jump; never use it to order applications.
        if rewindFrames > Int64(nominalRewindFrames), cycleCounter <= 16 {
            resetDeviceTimelineLocked(deviceObjectID)
        }
    }

    private func resetDeviceTimelineLocked(_ deviceObjectID: UInt32) {
        performanceEpoch &+= 1
        pendingMixesByDevice.removeValue(forKey: deviceObjectID)
        lastEmittedEndSampleTimeByDevice.removeValue(forKey: deviceObjectID)
        sourceDetectors = sourceDetectors.filter { $0.key.deviceObjectID != deviceObjectID }
        filterBanks = filterBanks.filter { $0.key.deviceObjectID != deviceObjectID }
        gainsByClientKey = gainsByClientKey.filter { $0.key.deviceObjectID != deviceObjectID }
    }

    private func mixProcessedPacketLocked(
        _ packet: PerAppAudioPacket,
        mode: PlaybackMode,
        packetStartSampleTime: Int64,
        samples: [Float],
        clientKey: PerAppTransportClientKey,
        now: Date,
        performance: PacketPerformanceContext?,
        processingCompleted: PerformanceTick?
    ) -> PCMFrame? {
        let channelCount = packet.channelCount
        var packetSamples = samples
        var packetFrameCount = packetSamples.count / channelCount
        var packetStart = packetStartSampleTime
        guard packetFrameCount > 0 else { return nil }

        // If a callback finishes after part of its timeline has already been
        // committed, trim only that already-rendered prefix. A fully stale
        // callback is ignored; the client is never permanently disabled.
        if let emittedEnd = lastEmittedEndSampleTimeByDevice[packet.deviceObjectID],
           packetStart < emittedEnd {
            let staleFrames = min(
                packetFrameCount,
                Int(max(0, emittedEnd - packetStart))
            )
            if staleFrames >= packetFrameCount { return nil }
            packetSamples.removeFirst(staleFrames * channelCount)
            packetStart += Int64(staleFrames)
            packetFrameCount -= staleFrames
        }

        if var mix = pendingMixesByDevice[packet.deviceObjectID] {
            if mix.performanceTrace?.capture.isStopped == true { mix.performanceTrace = nil }
            let formatMatches = mix.channelCount == channelCount
                && abs(mix.sampleRate - packet.sampleRate) < 0.5
                && mix.channelLayout == packet.channelLayout
            if !formatMatches {
                let completed = emitAllPendingMixLocked(for: packet.deviceObjectID)
                pendingMixesByDevice[packet.deviceObjectID] = makePendingMix(
                    packet,
                    mode: mode,
                    startSampleTime: packetStart,
                    samples: packetSamples,
                    clientKey: clientKey,
                    now: now,
                    performance: performance, processingCompleted: processingCompleted
                )
                return completed
            }

            let packetEnd = packetStart + Int64(packetFrameCount)
            let maximumSpan = max(
                mix.largestPacketFrames,
                packetFrameCount
            ) * Self.timelineDiscontinuityMultiplier

            // A far-future timestamp means there was an idle/discontinuous
            // interval, not a giant buffer of zero PCM that should be allocated.
            if packetStart > mix.endSampleTime,
               packetStart - mix.endSampleTime > Int64(maximumSpan) {
                let completed = emitAllPendingMixLocked(for: packet.deviceObjectID)
                pendingMixesByDevice[packet.deviceObjectID] = makePendingMix(
                    packet,
                    mode: mode,
                    startSampleTime: packetStart,
                    samples: packetSamples,
                    clientKey: clientKey,
                    now: now,
                    performance: performance, processingCompleted: processingCompleted
                )
                return completed
            }

            // A very old packet that is entirely before the reorder window is
            // stale. Do not let it rewind the live stream or reset another app.
            if packetEnd < mix.startSampleTime,
               mix.startSampleTime - packetEnd > Int64(maximumSpan) {
                return nil
            }

            if mix.performanceTrace == nil, let performance {
                mix.performanceTrace = MixPerformanceTrace(capture: performance.capture, identity: performance.identity,
                    untracedUntil: mix.endSampleTime, lastPolicyTick: performance.policyTick ?? performance.received)
            }
            let existingMixEnd = mix.endSampleTime
            mix.performanceTrace?.add(performance, processed: processingCompleted, start: packetStart,
                end: packetEnd, existingEnd: existingMixEnd)
            if packetStart < mix.startSampleTime {
                let prependFrames = Int(mix.startSampleTime - packetStart)
                mix.samples = [Float](
                    repeating: 0,
                    count: prependFrames * channelCount
                ) + mix.samples
                mix.startSampleTime = packetStart
                for key in Array(mix.samplesByMode.keys) {
                    mix.samplesByMode[key] = [Float](repeating: 0,
                        count: prependFrames * channelCount) + mix.samplesByMode[key]!
                }
            }

            let frameOffset = Int(packetStart - mix.startSampleTime)
            let sampleOffset = frameOffset * channelCount
            let requiredSamples = sampleOffset + packetSamples.count
            if requiredSamples > mix.samples.count {
                mix.samples.append(contentsOf: repeatElement(
                    Float(0),
                    count: requiredSamples - mix.samples.count
                ))
            }
            for index in packetSamples.indices {
                mix.samples[sampleOffset + index] += packetSamples[index]
            }
            for key in Set(mix.samplesByMode.keys).union([mode]) {
                var bus = mix.samplesByMode[key] ?? []
                bus.append(contentsOf: repeatElement(Float(0), count: mix.samples.count - bus.count))
                if key == mode {
                    for index in packetSamples.indices { bus[sampleOffset + index] += packetSamples[index] }
                }
                mix.samplesByMode[key] = bus
            }
            mix.sourceBufferedFrames = max(
                mix.sourceBufferedFrames,
                packet.sourceBufferedFrames
            )
            mix.sourceCapacityFrames = min(
                mix.sourceCapacityFrames,
                packet.sourceCapacityFrames
            )
            mix.clientKeys.insert(clientKey)
            mix.largestPacketFrames = max(mix.largestPacketFrames, packetFrameCount)
            mix.lastPacketDate = now
            pendingMixesByDevice[packet.deviceObjectID] = mix
        } else {
            pendingMixesByDevice[packet.deviceObjectID] = makePendingMix(
                packet,
                mode: mode,
                startSampleTime: packetStart,
                samples: packetSamples,
                clientKey: clientKey,
                now: now,
                performance: performance, processingCompleted: processingCompleted
            )
        }

        guard let pendingMix = pendingMixesByDevice[packet.deviceObjectID] else {
            return nil
        }
        let holdbackFrames = max(
            1,
            pendingMix.largestPacketFrames * Self.pendingMixHoldbackPackets
        )
        let safeFrames = pendingMix.frameCount - holdbackFrames
        guard safeFrames > 0 else { return nil }
        return emitPendingPrefixLocked(
            for: packet.deviceObjectID,
            frameCount: safeFrames,
            eligible: pendingMix.performanceTrace.map { _ in PerformanceClock.now() }
        )
    }

    private func makePendingMix(
        _ packet: PerAppAudioPacket,
        mode: PlaybackMode,
        startSampleTime: Int64,
        samples: [Float],
        clientKey: PerAppTransportClientKey,
        now: Date,
        performance: PacketPerformanceContext?,
        processingCompleted: PerformanceTick?
    ) -> PendingMix {
        var trace = performance.map { MixPerformanceTrace(capture: $0.capture, identity: $0.identity,
            untracedUntil: startSampleTime, lastPolicyTick: $0.policyTick ?? $0.received) }
        trace?.add(performance, processed: processingCompleted, start: startSampleTime,
                   end: startSampleTime + Int64(samples.count / packet.channelCount), existingEnd: startSampleTime)
        return PendingMix(
            performanceTrace: trace,
            deviceObjectID: packet.deviceObjectID,
            startSampleTime: startSampleTime,
            channelCount: packet.channelCount,
            sampleRate: packet.sampleRate,
            channelLayout: packet.channelLayout,
            sourceBufferedFrames: packet.sourceBufferedFrames,
            sourceCapacityFrames: packet.sourceCapacityFrames,
            clientKeys: [clientKey],
            samples: samples,
            samplesByMode: [mode: samples],
            largestPacketFrames: max(1, samples.count / packet.channelCount),
            lastPacketDate: now
        )
    }

    private func emitAllPendingMixLocked(for deviceObjectID: UInt32, eligible: PerformanceTick? = nil, idleDeadline: PerformanceTick? = nil, idleFlushStarted: PerformanceTick? = nil) -> PCMFrame? {
        guard let mix = pendingMixesByDevice[deviceObjectID] else { return nil }
        return emitPendingPrefixLocked(
            for: deviceObjectID,
            frameCount: mix.frameCount,
            eligible: eligible ?? mix.performanceTrace.map { _ in PerformanceClock.now() },
            idleDeadline: idleDeadline, idleFlushStarted: idleFlushStarted
        )
    }

    private func emitPendingPrefixLocked(
        for deviceObjectID: UInt32,
        frameCount: Int,
        eligible: PerformanceTick? = nil,
        idleDeadline: PerformanceTick? = nil,
        idleFlushStarted: PerformanceTick? = nil
    ) -> PCMFrame? {
        guard var mix = pendingMixesByDevice[deviceObjectID],
              frameCount > 0,
              frameCount <= mix.frameCount else {
            return nil
        }
        if mix.performanceTrace?.capture.isStopped == true { mix.performanceTrace = nil }
        let intervalTrace = eligible.flatMap { mix.performanceTrace?.emit(start: mix.startSampleTime,
            count: frameCount, eligible: $0, deadline: idleDeadline, flushStarted: idleFlushStarted) }
        let sampleCount = frameCount * mix.channelCount
        let outputSamples = Array(mix.samples.prefix(sampleCount))
        let activeClientCount = max(1, mix.clientKeys.count)
        var output = PCMFrame(
            interleaved: outputSamples,
            channelCount: mix.channelCount,
            sampleRate: mix.sampleRate,
            channelLayout: mix.channelLayout,
            sourceBufferedFrames: mix.sourceBufferedFrames / activeClientCount,
            sourceCapacityFrames: mix.sourceCapacityFrames
        )
        output.playbackModeSamples = mix.samplesByMode.mapValues { Array($0.prefix(sampleCount)) }
        let emittedEnd = mix.startSampleTime + Int64(frameCount)
        lastEmittedEndSampleTimeByDevice[deviceObjectID] = emittedEnd

        if frameCount == mix.frameCount {
            pendingMixesByDevice.removeValue(forKey: deviceObjectID)
        } else {
            mix.samples.removeFirst(sampleCount)
            for key in Array(mix.samplesByMode.keys) {
                mix.samplesByMode[key]?.removeFirst(sampleCount)
            }
            mix.startSampleTime = emittedEnd
            pendingMixesByDevice[deviceObjectID] = mix
        }
        output.performanceTrace = intervalTrace
        if output.performanceTrace != nil { output.performanceTrace?.emitted = PerformanceClock.now() }
        return output
    }

    /// Keep gain continuous at packet boundaries. Applying one scalar to an
    /// entire block makes interactive volume changes sound like zipper noise.
    private func applyGainRamp(
        to samples: inout [Float],
        channelCount: Int,
        clientKey: PerAppTransportClientKey,
        targetGain: Float
    ) {
        guard channelCount > 0, !samples.isEmpty else {
            gainsByClientKey[clientKey] = targetGain
            return
        }
        let frameCount = samples.count / channelCount
        guard frameCount > 0 else {
            gainsByClientKey[clientKey] = targetGain
            return
        }
        let startingGain = gainsByClientKey[clientKey] ?? targetGain
        if startingGain == targetGain {
            if targetGain != 1 {
                for index in samples.indices { samples[index] *= targetGain }
            }
        } else {
            let gainStep = (targetGain - startingGain) / Float(frameCount)
            var gain = startingGain
            for frame in 0..<frameCount {
                gain += gainStep
                let base = frame * channelCount
                for channel in 0..<channelCount {
                    samples[base + channel] *= gain
                }
            }
        }
        gainsByClientKey[clientKey] = targetGain
    }

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
        return .init(revision: presentationRevision, clients: Array(clientsByKey.values),
            identities: copy(identitiesByClientKey), workspaceIdentities: copy(workspaceIdentitiesByProcessID),
            runningApplications: copy(runningApplicationsByID), settings: copy(settingsByApplication),
            levels: copy(presentationLevelsByApplication), knownAudioApplications: Set(knownAudioApplicationIDs.map { $0 }),
            observedAudioApplications: Set(observedAudioIDs.map { $0 }), observedAudioSources: Array(observedAudioSourcesByKey.values),
            exhaustedClientKeys: Set(identityRetryExhaustedClientKeys.map { $0 }))
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

    private func observeWorkspaceApplications() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ] {
            workspaceObservers.append(notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.scheduleRunningApplicationRefresh()
            })
        }
    }

    private func scheduleRunningApplicationRefresh(immediate: Bool = false) {
        guard monitorsRunningApplications else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let running = NSWorkspace.shared.runningApplications
            let resolved = Dictionary(
                running.compactMap {
                    Self.resolveRunningApplicationIdentity($0).map { ($0.id, $0) }
                },
                uniquingKeysWith: { current, candidate in
                    if current.isDockApplication != candidate.isDockApplication {
                        return current.isDockApplication ? current : candidate
                    }
                    return current.processID <= candidate.processID ? current : candidate
                }
            )
            let audioIdentities = Dictionary(
                running.compactMap { runningApplication -> (Int32, ApplicationIdentity)? in
                    guard let identity = Self.resolveAudioProcessIdentity(runningApplication) else {
                        return nil
                    }
                    return (runningApplication.processIdentifier, identity)
                },
                uniquingKeysWith: { current, _ in current }
            )
            self.stateLock.lock()
            self.presentationRevision &+= 1
            self.runningApplicationsByID = resolved
            self.workspaceIdentitiesByProcessID = audioIdentities
            self.pendingRunningApplicationRefresh = nil
            self.stateLock.unlock()
            self.presentationPublisher.request(.immediate)
        }

        stateLock.lock()
        pendingRunningApplicationRefresh?.cancel()
        pendingRunningApplicationRefresh = work
        stateLock.unlock()
        runningApplicationQueue.asyncAfter(
            deadline: .now() + (immediate ? 0 : 0.1),
            execute: work
        )
    }

    private static func moveLatestDate(
        from sourceID: String,
        to destinationID: String,
        in dates: inout [String: Date]
    ) {
        guard let source = dates.removeValue(forKey: sourceID) else { return }
        dates[destinationID] = max(dates[destinationID] ?? .distantPast, source)
    }

    private static func resolveApplicationIdentity(
        for client: PerAppDriverClient
    ) -> ApplicationIdentity? {
        guard let owner = resolveOwningApplication(
            processID: client.processID,
            reportedBundleID: client.bundleID
        ) else { return nil }
        return makeApplicationIdentity(from: owner)
    }

    private static func resolveOwningApplication(
        processID: Int32,
        reportedBundleID: String?
    ) -> ResolvedApplicationOwner? {
        guard processID > 0,
              processID != Int32(ProcessInfo.processInfo.processIdentifier),
              !isSystemAudioService(bundleID: reportedBundleID) else {
            return nil
        }

        let processExists = Darwin.kill(processID, 0) == 0 || errno == EPERM
        let running = processExists
            ? NSRunningApplication(processIdentifier: processID)
            : nil
        guard running?.isTerminated != true else { return nil }

        let processBundleURL = running?.bundleURL
        let outerBundleURL = outermostApplicationURL(from: processBundleURL)
        let rawBundleID = running?.bundleIdentifier ?? reportedBundleID
        let canonicalBundleID = canonicalApplicationBundleID(rawBundleID)
        var ownerURL = outerBundleURL
        if ownerURL == nil,
           let canonicalBundleID,
           canonicalBundleID != rawBundleID {
            ownerURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: canonicalBundleID
            )
        }

        let ownerBundle = ownerURL.flatMap(Bundle.init(url:))
        let ownerBundleID = ownerBundle?.bundleIdentifier
            ?? canonicalBundleID
            ?? rawBundleID
        let displayName = (ownerBundle?.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String)
            ?? (ownerBundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? running?.localizedName
            ?? ownerBundleID?.split(separator: ".").last.map(String.init)
            ?? "Application"

        guard !isSystemAudioService(
            bundleID: ownerBundleID,
            displayName: displayName
        ) else { return nil }

        return ResolvedApplicationOwner(
            bundleID: ownerBundleID,
            bundleURL: ownerURL,
            displayName: displayName,
            processID: processID,
            activationPolicy: running?.activationPolicy
        )
    }

    private static func makeApplicationIdentity(
        from owner: ResolvedApplicationOwner
    ) -> ApplicationIdentity? {
        let ownURL = Bundle.main.bundleURL.standardizedFileURL
        let ownBundleID = Bundle.main.bundleIdentifier
        if owner.bundleURL?.standardizedFileURL == ownURL
            || (owner.bundleID != nil && owner.bundleID == ownBundleID) {
            return nil
        }
        return ApplicationIdentity(
            id: owner.stableID,
            bundleID: owner.bundleID,
            bundleURL: owner.bundleURL,
            processID: owner.processID,
            displayName: owner.displayName,
            isDockApplication: owner.activationPolicy == .regular,
            isAccessoryApplication: owner.activationPolicy == .accessory
        )
    }

    static func shouldPresentApplication(
        isDockApplication: Bool,
        isAccessoryApplication: Bool,
        hasProducedAudio: Bool
    ) -> Bool {
        isDockApplication || (isAccessoryApplication && hasProducedAudio)
    }

    /// Apple ships a small group of document, account, and maintenance apps
    /// that do not own a media playback path. Hide those idle Dock processes,
    /// while the presentation snapshot builder still lets direct audio history override
    /// this conservative classification if macOS changes their behavior.
    static func isKnownNonAudioSystemApplication(bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.lowercased() else { return false }
        return knownNonAudioSystemApplicationBundleIDs.contains(bundleID)
    }

    private static let knownNonAudioSystemApplicationBundleIDs: Set<String> = [
        "com.apple.activitymonitor",
        "com.apple.addressbook",
        "com.apple.automator",
        "com.apple.bluetoothfileexchange",
        "com.apple.calculator",
        "com.apple.colorsyncutility",
        "com.apple.console",
        "com.apple.digitalcolormeter",
        "com.apple.directoryutility",
        "com.apple.diskutility",
        "com.apple.fontbook",
        "com.apple.ical",
        "com.apple.image_capture",
        "com.apple.keychainaccess",
        "com.apple.migrateassistant",
        "com.apple.passwords",
        "com.apple.reminders",
        "com.apple.scripteditor2",
        "com.apple.stickies",
        "com.apple.systemprofiler"
    ]

    /// Resolve the process that actually produced a PCM packet to its owning
    /// application. Background/helper processes (Chrome, Electron, WebKit) may
    /// have a prohibited activation policy even though their outer .app owns
    /// the user-facing volume row, so packet attribution must not use the
    /// visible-app filter.
    private static func resolveAudioProcessIdentity(
        _ running: NSRunningApplication
    ) -> ApplicationIdentity? {
        guard !running.isTerminated,
              let owner = resolveOwningApplication(
                processID: running.processIdentifier,
                reportedBundleID: running.bundleIdentifier
              ) else { return nil }
        return makeApplicationIdentity(from: owner)
    }

    private static func resolveRunningApplicationIdentity(
        _ running: NSRunningApplication
    ) -> ApplicationIdentity? {
        guard running.isTerminated == false,
              running.activationPolicy == .regular
                || running.activationPolicy == .accessory else {
            return nil
        }
        guard let owner = resolveOwningApplication(
            processID: running.processIdentifier,
            reportedBundleID: running.bundleIdentifier
        ) else { return nil }
        return makeApplicationIdentity(from: owner)
    }

    /// Core Audio hosts third-party AudioServerPlugIns in its own service
    /// process. That process is transport plumbing, not an application the
    /// user can control, so it must never become a per-app volume row.
    static func isSystemAudioService(
        bundleID: String?,
        displayName: String? = nil
    ) -> Bool {
        let candidates = [bundleID, displayName].compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return candidates.contains { candidate in
            let normalized = candidate
                .replacingOccurrences(of: "_", with: "-")
                .replacingOccurrences(of: " ", with: "-")
            return normalized.contains("core-audio-driver-service")
                || normalized == "coreaudiod"
                || normalized == "com.apple.audio.coreaudiod"
        }
    }

    /// Browser and Electron audio normally originates in a nested helper
    /// process. Collapse its bundle identifier to the owning application even
    /// when Launch Services does not provide a bundle URL for that PID.
    static func canonicalApplicationBundleID(_ bundleID: String?) -> String? {
        guard let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty else { return nil }
        let components = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard let helperIndex = components.firstIndex(where: {
            let component = $0.lowercased()
            return component == "helper" || component.hasPrefix("helper-")
        }), helperIndex > 0 else {
            return bundleID
        }
        let owner = components[..<helperIndex].joined(separator: ".")
        return owner.isEmpty ? bundleID : owner
    }

    static func outermostApplicationURL(from bundleURL: URL?) -> URL? {
        guard var candidate = bundleURL?.standardizedFileURL else { return nil }
        var outermost: URL?
        while candidate.path != "/" {
            if candidate.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame {
                outermost = candidate
            }
            candidate.deleteLastPathComponent()
        }
        return outermost
    }

    static func isNestedApplicationProcess(
        processBundleURL: URL?,
        ownerBundleURL: URL?
    ) -> Bool {
        guard let processBundleURL = processBundleURL?.standardizedFileURL,
              let ownerBundleURL = ownerBundleURL?.standardizedFileURL else {
            return false
        }
        return processBundleURL != ownerBundleURL
            && processBundleURL.path.hasPrefix(ownerBundleURL.path + "/")
    }

    static func isEphemeralApplicationID(_ id: String) -> Bool {
        id.hasPrefix("pid:") || id.hasPrefix("client:")
    }

    static func isPersistentApplicationID(_ id: String) -> Bool {
        !isEphemeralApplicationID(id)
    }

    private static func loadSettings(from url: URL) -> (settings: [String: PerAppAudioSettings], error: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([:], nil) }
        do {
            let settings = try PerAppAudioDocument.decode(Data(contentsOf: url))
            return (settings.filter { isPersistentApplicationID($0.key) }, nil)
        } catch {
            return ([:], "Per-application settings could not be read. The original file is preserved; changes cannot be saved until it is restored or opened by a compatible version.")
        }
    }

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
                self.settingsRevisionByApplication[key.applicationID]
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
                self.settingsRevisionByApplication[key.applicationID]
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
        Float(pow(10, automaticSystemHeadroomDB(settings, sampleRate: sampleRate) / 20))
    }

    /// Shared by the audio path and the application EQ readout. Application
    /// volume and mute do not affect the headroom reserved for EQ boosts.
    static func automaticSystemHeadroomDB(
        _ settings: PerAppAudioSettings,
        sampleRate: Double
    ) -> Double {
        guard !settings.eqBypassed, settings.hasEqualizerProcessing else { return 0 }
        let response = EQResponseCalculator().calculate(
            parsed: ParsedEQ(bands: settings.processingBands(sampleRate: sampleRate)),
            sampleRate: sampleRate,
            count: 600
        )
        let boost = max(0, response.map(\.gainDB).max() ?? 0)
        return boost > 0 ? -boost : 0
    }

    private func schedulePersistence(_ settings: [String: PerAppAudioSettings]) {
        pendingPersistence?.cancel()
        let url = settingsURL
        let work = DispatchWorkItem { [weak self] in
            let error = Self.persist(settings, to: url)
            self?.publishPersistenceError(error)
        }
        pendingPersistence = work
        persistenceQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    @discardableResult
    private static func persist(_ settings: [String: PerAppAudioSettings], to settingsURL: URL) -> String? {
        let persistentSettings = settings.filter { isPersistentApplicationID($0.key) }
        do {
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                // Never replace newer or unreadable data, including a file changed
                // by another version while this process was running.
                let previous = try PerAppAudioDocument.decode(Data(contentsOf: settingsURL))
                if previous.filter({ isPersistentApplicationID($0.key) }) == persistentSettings { return nil }
            } else if persistentSettings.isEmpty { return nil }
            let data = try JSONEncoder().encode(PerAppAudioDocument(settings: persistentSettings))
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: settingsURL, options: .atomic)
            return nil
        } catch {
            return "Per-application settings were not saved. Check storage access and file compatibility. The previous file is preserved."
        }
    }

    private func publishPersistenceError(_ error: String?) {
        if Thread.isMainThread {
            if persistenceError != error { persistenceError = error }
        } else {
            DispatchQueue.main.async { [weak self] in
                if self?.persistenceError != error { self?.persistenceError = error }
            }
        }
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
        pendingPersistence?.cancel()
        let current = settingsByApplication
        stateLock.unlock()
        let error = persistenceQueue.sync { Self.persist(current, to: settingsURL) }
        if let error { throw ProfileSettingsError.runtime(error) }
    }

    /// Test/benchmark barrier for already-enqueued discovery/publication work.
    /// Does not force delayed identity retries or advance meter deadlines.
    func drainPresentationPreparation() async {
        await withCheckedContinuation { continuation in
            identityQueue.async { [weak self] in
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
        pendingPersistence?.cancel()
        let settings = settingsByApplication
        stateLock.unlock()
        let error = persistenceQueue.sync { Self.persist(settings, to: settingsURL) }
        publishPersistenceError(error)
        publicationQueue.sync {}
        presentationObservationQueue.sync {}
        presentationStore.flushPendingSaveSynchronously()
    }

}

struct PerAppFilterBank {
    private struct Signature: Hashable {
        var channelCount: Int
        var sampleRate: Double
        var bands: [EQBand]
        var settingsRevision: UInt64
        var tone: SimpleToneSettings
    }

    private struct State {
        var x1 = 0.0
        var x2 = 0.0
        var y1 = 0.0
        var y2 = 0.0
    }

    private struct Coefficients {
        var b0: Double
        var b1: Double
        var b2: Double
        var a1: Double
        var a2: Double
    }

    private var signature: Signature?
    private var coefficients: [Coefficients] = []
    private var states: [State] = []

    mutating func process(
        _ samples: inout [Float],
        channelCount: Int,
        sampleRate: Double,
        bands: [EQBand],
        settingsRevision: UInt64,
        tone: SimpleToneSettings = SimpleToneSettings()
    ) {
        let nextSignature = Signature(
            channelCount: channelCount,
            sampleRate: sampleRate,
            bands: bands,
            settingsRevision: settingsRevision, tone: tone
        )
        if signature != nextSignature {
            signature = nextSignature
            let activeBands = (bands + (tone.isNeutral ? [] : ((try? SimpleToneFilterFactory.filters(for: tone, sampleRate: sampleRate)) ?? []))).filter {
                $0.enabled && $0.frequency > 0 && $0.frequency < sampleRate / 2
            }
            coefficients = activeBands.compactMap {
                Self.coefficients(for: $0, sampleRate: sampleRate)
            }
            states = [State](repeating: State(), count: coefficients.count * channelCount)
        }
        guard !coefficients.isEmpty else { return }
        for sampleIndex in samples.indices {
            let channel = sampleIndex % channelCount
            var value = Double(samples[sampleIndex])
            for filterIndex in coefficients.indices {
                let stateIndex = filterIndex * channelCount + channel
                var state = states[stateIndex]
                let c = coefficients[filterIndex]
                let output = c.b0 * value + c.b1 * state.x1 + c.b2 * state.x2
                    - c.a1 * state.y1 - c.a2 * state.y2
                state.x2 = state.x1
                state.x1 = value
                state.y2 = state.y1
                state.y1 = output
                states[stateIndex] = state
                value = output
            }
            samples[sampleIndex] = Float(value.isFinite ? value : 0)
        }
    }

    private static func coefficients(for band: EQBand, sampleRate: Double) -> Coefficients? {
        let q: Double
        if let value = band.q, value.isFinite, value > 0 {
            q = value
        } else if let bandwidth = band.bandwidth,
                  bandwidth.isFinite, bandwidth > 0 {
            q = 1 / (2 * sinh(log(2) / 2 * bandwidth))
        } else {
            q = 0.70710678
        }
        let w0 = 2 * Double.pi * band.frequency / sampleRate
        let cosw = cos(w0)
        let sinw = sin(w0)
        let gain = band.gain ?? 0
        guard gain.isFinite else { return nil }
        let a = pow(10, gain / 40)
        let alpha = sinw / (2 * q)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0
        var a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch band.kind {
        case .peaking:
            b0 = 1 + alpha * a; b1 = -2 * cosw; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cosw; a2 = 1 - alpha / a
        case .lowPass:
            b0 = (1 - cosw) / 2; b1 = 1 - cosw; b2 = b0
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosw) / 2; b1 = -(1 + cosw); b2 = b0
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .notch:
            b0 = 1; b1 = -2 * cosw; b2 = 1
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .allPass:
            b0 = 1 - alpha; b1 = -2 * cosw; b2 = 1 + alpha
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .lowShelf, .highShelf:
            let squareRootA = sqrt(a)
            let beta = 2 * squareRootA * alpha
            if band.kind == .lowShelf {
                b0 = a * ((a + 1) - (a - 1) * cosw + beta)
                b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
                b2 = a * ((a + 1) - (a - 1) * cosw - beta)
                a0 = (a + 1) + (a - 1) * cosw + beta
                a1 = -2 * ((a - 1) + (a + 1) * cosw)
                a2 = (a + 1) + (a - 1) * cosw - beta
            } else {
                b0 = a * ((a + 1) + (a - 1) * cosw + beta)
                b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
                b2 = a * ((a + 1) + (a - 1) * cosw - beta)
                a0 = (a + 1) - (a - 1) * cosw + beta
                a1 = 2 * ((a - 1) - (a + 1) * cosw)
                a2 = (a + 1) - (a - 1) * cosw - beta
            }
        }
        guard a0.isFinite, a0 != 0 else { return nil }
        return Coefficients(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
    }
}
