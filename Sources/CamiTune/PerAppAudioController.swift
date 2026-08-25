import AppKit
import Combine
import Darwin
import Foundation

struct PerAppAudioSettings: Codable, Hashable, Sendable {
    var volume: Double = 1
    var isMuted = false
    var eqBypassed = false
    var equalizerBands: [EQBand] = []
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

    private struct PendingMix {
        var cycleCounter: UInt64
        var sampleTime: Double
        var channelCount: Int
        var sampleRate: Double
        var channelLayout: LPCMChannelLayout
        var sourceBufferedFrames: Int
        var sourceCapacityFrames: Int
        var clientKeys: Set<PerAppTransportClientKey>
        var samples: [Float]
        var lastPacketDate: Date
    }

    private struct HeadroomKey: Hashable, Sendable {
        var applicationID: String
        var sampleRate: Double
        var settingsRevision: UInt64
    }

    private struct ApplicationIdentity: Hashable {
        var id: String
        var bundleID: String?
        var bundleURL: URL?
        var processID: Int32
        var displayName: String
        var isDockApplication: Bool
        var isAccessoryApplication: Bool
    }

    private static let applicationActivityFloor = pow(10.0, -72.0 / 20.0)
    private static let meterDecayTime: TimeInterval = 0.8
    private static let publishInterval: TimeInterval = 0.1
    // Keep two HAL cycles in flight so a client whose MixOutput callback
    // completes slightly late cannot split one timeline cycle into two audible
    // blocks. This costs roughly two device buffers of pre-DSP latency while
    // making client add/remove activity harmless to the mixer.
    private static let maximumPendingMixCycles = 2

    // Keep UI/control state separate from real-time-ish DSP runtime state.
    // MainActor code may take `stateLock`, but it must never wait on `audioLock`.
    private let stateLock = NSLock()
    private let audioLock = NSLock()
    // Headroom cache synchronization is intentionally independent from the DSP
    // runtime lock. No 600-point response calculation may run while this lock
    // (or `audioLock`) is held.
    private let headroomLock = NSLock()
    private let settingsURL: URL
    private let audioHistoryURL: URL
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
    private let publicationQueue = DispatchQueue(
        label: "CamiTune.PerAppAudioPublication",
        qos: .userInteractive
    )
    private var clientsByKey: [PerAppTransportClientKey: PerAppDriverClient] = [:]
    private var identitiesByClientKey: [PerAppTransportClientKey: ApplicationIdentity] = [:]
    private var runningApplicationsByID: [String: ApplicationIdentity] = [:]
    private var settingsByApplication: [String: PerAppAudioSettings]
    private var settingsRevisionByApplication: [String: UInt64] = [:]
    private var knownAudioApplicationIDs: Set<String>
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
    // Multiple clients can complete MixOutput out of order. Keep a tiny,
    // ordered reorder window instead of assuming every block for one HAL cycle
    // arrives contiguously.
    private var pendingMixes: [PendingMix] = []
    // Some macOS system sounds run in a second IO context whose cycle counter
    // is unrelated to the already-playing program stream. Once detected, keep
    // that client out of the cycle-keyed mixer for the lifetime of its driver
    // registration; otherwise its faster counter eventually catches up and
    // corrupts the program timeline near the end of the sound.
    private var independentlyClockedClientGenerations: [
        PerAppTransportClientKey: UInt64
    ] = [:]
    private var lastEmittedCycleCounter: UInt64?
    private var lastEmittedSampleTime: Double?
    private var pendingPersistence: DispatchWorkItem?
    private var pendingHistoryPersistence: DispatchWorkItem?
    private var pendingRunningApplicationRefresh: DispatchWorkItem?
    // Accessed only on `publicationQueue`. Keeping these off `stateLock` means
    // the MainActor publication callback can never wait for controller state.
    private var pendingApplicationSnapshot: [PerAppAudioApplication]?
    private var mainPublishScheduled = false
    private var lastPublishDate = Date.distantPast
    private var identityResolutionRevision: UInt64 = 0
    private var meterPresentationSources: Set<String> = []
    private var suspendedMeterPresentationSources: Set<String> = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init(
        settingsURL: URL = CamiTunePaths.perAppAudioSettingsURL,
        audioHistoryURL: URL? = nil,
        monitorsRunningApplications: Bool = true
    ) {
        self.settingsURL = settingsURL
        self.audioHistoryURL = audioHistoryURL
            ?? settingsURL.appendingPathExtension("history")
        self.monitorsRunningApplications = monitorsRunningApplications
        settingsByApplication = Self.loadSettings(from: settingsURL)
        knownAudioApplicationIDs = Self.loadAudioHistory(
            from: self.audioHistoryURL
        )
        if monitorsRunningApplications {
            observeWorkspaceApplications()
            scheduleRunningApplicationRefresh(immediate: true)
        }
        publishApplications(force: true)
    }

    deinit {
        pendingPersistence?.cancel()
        pendingHistoryPersistence?.cancel()
        pendingRunningApplicationRefresh?.cancel()
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            notificationCenter.removeObserver(observer)
        }
        let settings = settingsByApplication
        let audioHistory = knownAudioApplicationIDs
        let url = settingsURL
        let historyURL = audioHistoryURL
        persistenceQueue.sync {
            Self.persist(settings, to: url)
            Self.persistAudioHistory(audioHistory, to: historyURL)
        }
    }

    func updateClients(_ clients: [PerAppDriverClient]) {
        let nextClients = Dictionary(
            clients.map { ($0.transportKey, $0) },
            uniquingKeysWith: { current, candidate in
                current.generation >= candidate.generation ? current : candidate
            }
        )
        stateLock.lock()
        let clientsChanged = clientsByKey != nextClients
        guard clientsChanged else {
            stateLock.unlock()
            return
        }
        clientsByKey = nextClients
        identityResolutionRevision &+= 1
        let revision = identityResolutionRevision
        stateLock.unlock()

        let activeClientKeys = Set(nextClients.keys)
        audioMaintenanceQueue.async { [weak self] in
            guard let self else { return }
            self.audioLock.lock()
            self.filterBanks = self.filterBanks.filter { activeClientKeys.contains($0.key) }
            self.gainsByClientKey = self.gainsByClientKey.filter {
                activeClientKeys.contains($0.key)
            }
            self.independentlyClockedClientGenerations =
                self.independentlyClockedClientGenerations.filter {
                    nextClients[$0.key]?.generation == $0.value
                }
            self.audioLock.unlock()
        }

        // Looking up NSRunningApplication, nested bundles, and application
        // metadata can trigger Launch Services disk work. Never do that on the
        // transport reader that is responsible for keeping audio flowing.
        identityQueue.async {
            let resolvedIdentities = Dictionary(
                uniqueKeysWithValues: clients.compactMap { client in
                    Self.resolveApplicationIdentity(for: client).map {
                        (client.transportKey, $0)
                    }
                }
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                guard self.identityResolutionRevision == revision else {
                    self.stateLock.unlock()
                    return
                }
                self.identitiesByClientKey = resolvedIdentities
                var settingsChanged = false
                var audioHistoryChanged = false
                var runtimeMigrations: [(from: String, to: String)] = []
                for client in clients {
                    guard let identity = resolvedIdentities[client.transportKey] else { continue }
                    let temporaryID = client.applicationKey
                    guard identity.id != temporaryID else { continue }
                    if self.settingsByApplication[identity.id] == nil,
                       let legacy = self.settingsByApplication[temporaryID] {
                        self.settingsByApplication[identity.id] = legacy
                        self.settingsRevisionByApplication[identity.id] =
                            self.settingsRevisionByApplication[temporaryID] ?? 0
                        settingsChanged = true
                    }
                    if let temporaryLevel = self.presentationLevelsByApplication.removeValue(
                        forKey: temporaryID
                    ) {
                        self.presentationLevelsByApplication[identity.id] = max(
                            self.presentationLevelsByApplication[identity.id] ?? 0,
                            temporaryLevel
                        )
                    }
                    runtimeMigrations.append((temporaryID, identity.id))
                    if self.knownAudioApplicationIDs.remove(temporaryID) != nil {
                        self.knownAudioApplicationIDs.insert(identity.id)
                        audioHistoryChanged = true
                    }
                }
                let savedSettings = self.settingsByApplication
                let savedAudioHistory = self.knownAudioApplicationIDs
                self.stateLock.unlock()
                if settingsChanged {
                    self.schedulePersistence(savedSettings)
                }
                if audioHistoryChanged {
                    self.scheduleAudioHistoryPersistence(savedAudioHistory)
                }
                if !runtimeMigrations.isEmpty {
                    self.audioMaintenanceQueue.async { [weak self] in
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
                    }
                }
                self.publishApplications(force: true)
            }
        }
    }

    func settings(for applicationID: String) -> PerAppAudioSettings {
        stateLock.lock()
        defer { stateLock.unlock() }
        return settingsByApplication[applicationID] ?? PerAppAudioSettings()
    }

    func hasProducedAudio(for applicationID: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return knownAudioApplicationIDs.contains(applicationID)
    }

    func setVolume(
        _ volume: Double,
        for applicationID: String,
        interactionFinished: Bool = true
    ) {
        updateSettings(
            for: applicationID,
            persistChanges: interactionFinished,
            forcePublication: interactionFinished
        ) {
            $0.volume = min(max(volume, 0), 1)
        }
    }

    func setMeterPresentationActive(_ active: Bool, source: String) {
        stateLock.lock()
        if active {
            meterPresentationSources.insert(source)
        } else {
            meterPresentationSources.remove(source)
        }
        let shouldPublish = active && !suspendedMeterPresentationSources.contains(source)
        stateLock.unlock()
        if shouldPublish {
            scheduleRunningApplicationRefresh(immediate: true)
            publishApplications(force: true)
        }
    }

    func setMeterPresentationSuspended(_ suspended: Bool, source: String) {
        stateLock.lock()
        if suspended {
            suspendedMeterPresentationSources.insert(source)
        } else {
            suspendedMeterPresentationSources.remove(source)
        }
        let shouldPublish = !suspended && meterPresentationSources.contains(source)
        stateLock.unlock()
        if shouldPublish {
            scheduleRunningApplicationRefresh(immediate: true)
            publishApplications(force: true)
        }
    }

    func setMuted(_ muted: Bool, for applicationID: String) {
        updateSettings(for: applicationID) { $0.isMuted = muted }
    }

    func setEQBypassed(_ bypassed: Bool, for applicationID: String) {
        updateSettings(
            for: applicationID,
            resetFilterState: true,
            resetHeadroom: true
        ) { $0.eqBypassed = bypassed }
    }

    func setEqualizerBands(
        _ bands: [EQBand],
        for applicationID: String,
        interactionFinished: Bool = true
    ) {
        updateSettings(
            for: applicationID,
            resetFilterState: true,
            resetHeadroom: true,
            persistChanges: interactionFinished,
            forcePublication: interactionFinished,
            performDeferredCleanup: interactionFinished
        ) { $0.equalizerBands = bands }
    }

    func ingest(_ packet: PerAppAudioPacket) -> PCMFrame? {
        var processed = packet.interleaved
        return ingest(packet, processed: &processed)
    }

    /// Copies the transport's reusable C read buffer directly into the one
    /// mutable array used for DSP/mixing. This avoids first allocating a
    /// packet Array and then triggering a second copy-on-write allocation when
    /// per-app processing mutates it.
    func ingestTransportPacket(
        _ metadata: PerAppAudioPacket,
        samples: UnsafeBufferPointer<Float>,
        sampleCount: Int
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
        return ingest(metadata, processed: &processed)
    }

    private func ingest(
        _ packet: PerAppAudioPacket,
        processed: inout [Float]
    ) -> PCMFrame? {
        guard packet.channelCount > 0,
              packet.sampleRate > 0,
              processed.count % packet.channelCount == 0 else { return nil }

        // Snapshot UI/control state quickly. The expensive DSP section below is
        // protected by `audioLock`, which MainActor code never acquires.
        stateLock.lock()
        let client = clientsByKey[packet.transportKey]
        let identity = identitiesByClientKey[packet.transportKey]
        let applicationID = identity?.id
            ?? client?.applicationKey
            ?? "client:\(packet.deviceObjectID):\(packet.clientID)"
        let settings = settingsByApplication[applicationID] ?? PerAppAudioSettings()
        let settingsRevision = settingsRevisionByApplication[applicationID] ?? 0
        let clientGeneration = client?.generation ?? 0
        let canPersistAudioHistory = identity?.bundleID?.isEmpty == false
            || client?.bundleID?.isEmpty == false
        stateLock.unlock()

        let rawPeak = processed.reduce(0.0) { max($0, Double(abs($1))) }
        let now = Date()
        // Resolve headroom before entering the DSP critical section. Cache
        // misses never calculate the full EQ response on the ingest thread:
        // they use an immediate conservative value and refine it asynchronously.
        let eqHeadroom: Float
        if settings.isMuted || settings.eqBypassed || settings.equalizerBands.isEmpty {
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

        if independentlyClockedClientGenerations[packet.transportKey] != nil {
            audioLock.unlock()
            return nil
        }

        // The driver transport permits overlapping real-time writers. A late
        // packet for a cycle that was already emitted must be discarded rather
        // than rendered as a second copy of old timeline audio. Core Audio can
        // also stop/restart IO and reset both clocks. A newly-started Core
        // Audio context (notably loginwindow's volume-feedback sound) has its
        // own low cycle counter while sharing the device's current sample
        // timeline. Requiring both clocks to rewind prevents that transient
        // context from repeatedly clearing queued program audio and DSP state.
        if let lastCycle = lastEmittedCycleCounter,
           !Self.cycleIsNewer(packet.cycleCounter, than: lastCycle) {
            let backwardCycles = lastCycle &- packet.cycleCounter
            let frameCount = max(1, processed.count / max(1, packet.channelCount))
            let sampleRewind = lastEmittedSampleTime.map { lastSampleTime in
                packet.sampleTime + Double(frameCount * 4) < lastSampleTime
            } ?? false
            let restartedTimeline = backwardCycles > 8 && sampleRewind

            if restartedTimeline {
                pendingMixes.removeAll(keepingCapacity: true)
                independentlyClockedClientGenerations.removeAll(
                    keepingCapacity: true
                )
                lastEmittedCycleCounter = nil
                lastEmittedSampleTime = nil
                // Stateful DSP from the previous IO epoch must not leak across
                // a discontinuous device restart. Settings remain untouched.
                filterBanks.removeAll(keepingCapacity: true)
                gainsByClientKey.removeAll(keepingCapacity: true)
            } else {
                if backwardCycles > 8 && !sampleRewind {
                    independentlyClockedClientGenerations[
                        packet.transportKey
                    ] = clientGeneration
                }
                let presentationLevel = levelsByApplication[applicationID] ?? 0
                audioLock.unlock()
                stateLock.lock()
                presentationLevelsByApplication[applicationID] = presentationLevel
                stateLock.unlock()
                publishApplications()
                return nil
            }
        }

        lastPacketDateByApplication[applicationID] = now
        if rawPeak >= Self.applicationActivityFloor {
            lastAudibleDateByApplication[applicationID] = now
        }
        if !settings.isMuted && !settings.eqBypassed && !settings.equalizerBands.isEmpty {
            var bank = filterBanks[packet.transportKey] ?? PerAppFilterBank()
            bank.process(
                &processed,
                channelCount: packet.channelCount,
                sampleRate: packet.sampleRate,
                bands: settings.equalizerBands,
                settingsRevision: settingsRevision
            )
            filterBanks[packet.transportKey] = bank
        }
        let targetGain: Float = settings.isMuted
            ? 0
            : Float(settings.volume) * eqHeadroom
        applyGainRamp(
            to: &processed,
            channelCount: packet.channelCount,
            clientKey: packet.transportKey,
            targetGain: targetGain
        )
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

        if let mixIndex = pendingMixes.firstIndex(where: {
            $0.cycleCounter == packet.cycleCounter
        }) {
            // A single HAL cycle must have one stream format. If a malformed
            // or reconfiguration packet disagrees, drop that packet instead of
            // creating a duplicate block at the same timeline position.
            let mix = pendingMixes[mixIndex]
            if mix.channelCount == packet.channelCount,
               mix.sampleRate == packet.sampleRate,
               mix.channelLayout == packet.channelLayout,
               mix.samples.count == processed.count {
                for index in processed.indices {
                    pendingMixes[mixIndex].samples[index] += processed[index]
                }
                pendingMixes[mixIndex].sourceBufferedFrames = max(
                    pendingMixes[mixIndex].sourceBufferedFrames,
                    packet.sourceBufferedFrames
                )
                pendingMixes[mixIndex].sourceCapacityFrames = min(
                    pendingMixes[mixIndex].sourceCapacityFrames,
                    packet.sourceCapacityFrames
                )
                pendingMixes[mixIndex].clientKeys.insert(packet.transportKey)
                pendingMixes[mixIndex].sampleTime = min(
                    pendingMixes[mixIndex].sampleTime,
                    packet.sampleTime
                )
                pendingMixes[mixIndex].lastPacketDate = now
            }
        } else {
            let newMix = PendingMix(
                cycleCounter: packet.cycleCounter,
                sampleTime: packet.sampleTime,
                channelCount: packet.channelCount,
                sampleRate: packet.sampleRate,
                channelLayout: packet.channelLayout,
                sourceBufferedFrames: packet.sourceBufferedFrames,
                sourceCapacityFrames: packet.sourceCapacityFrames,
                clientKeys: [packet.transportKey],
                samples: processed,
                lastPacketDate: now
            )
            let insertionIndex = pendingMixes.firstIndex {
                Self.cycleIsNewer($0.cycleCounter, than: packet.cycleCounter)
            } ?? pendingMixes.endIndex
            pendingMixes.insert(newMix, at: insertionIndex)
        }

        // Never emit a cycle merely because the next cycle arrived. Retain a
        // two-cycle reorder window so `N, N+1, late N` still produces exactly
        // one mixed block for N. Once a third distinct cycle arrives, the
        // oldest cycle is safe to commit.
        let completed: PCMFrame?
        if pendingMixes.count > Self.maximumPendingMixCycles {
            completed = emitOldestPendingMixLocked()
        } else {
            completed = nil
        }
        let presentationLevel = levelsByApplication[applicationID] ?? 0
        audioLock.unlock()

        var audioHistoryToPersist: Set<String>?
        stateLock.lock()
        presentationLevelsByApplication[applicationID] = presentationLevel
        if rawPeak >= Self.applicationActivityFloor,
           canPersistAudioHistory,
           knownAudioApplicationIDs.insert(applicationID).inserted {
            audioHistoryToPersist = knownAudioApplicationIDs
        }
        stateLock.unlock()
        if let audioHistoryToPersist {
            scheduleAudioHistoryPersistence(audioHistoryToPersist)
        }
        publishApplications()
        return completed
    }

    func flushExpiredMix() -> PerAppMixFlushResult {
        audioLock.lock()
        let now = Date()
        guard let pendingMix = pendingMixes.first else {
            decayLevelsLocked(now: now)
            let presentationLevels = levelsByApplication
            audioLock.unlock()
            stateLock.lock()
            presentationLevelsByApplication = presentationLevels
            stateLock.unlock()
            publishApplications()
            return .idle
        }
        let frameDuration = Double(pendingMix.samples.count / pendingMix.channelCount)
            / pendingMix.sampleRate
        // Give an overlapping client callback more than one nominal buffer to
        // finish before declaring the cycle complete. Continuous streams are
        // normally committed by the bounded two-cycle window above, so this
        // timeout primarily handles idle/stopping clients.
        let requiredDelay = max(0.004, frameDuration * 1.5)
        let elapsed = now.timeIntervalSince(pendingMix.lastPacketDate)
        guard elapsed >= requiredDelay else {
            audioLock.unlock()
            return .retryAfter(max(0.0005, requiredDelay - elapsed))
        }
        guard let completed = emitOldestPendingMixLocked() else {
            audioLock.unlock()
            return .idle
        }
        decayLevelsLocked(now: now)
        let presentationLevels = levelsByApplication
        audioLock.unlock()
        stateLock.lock()
        presentationLevelsByApplication = presentationLevels
        stateLock.unlock()
        publishApplications()
        return .flushed(completed)
    }

    func resetRuntimeWithoutBlockingUI() async {
        await Task.detached(priority: .userInitiated) { [self] in
            resetRuntime()
        }.value
    }

    func resetRuntime() {
        audioLock.lock()
        pendingMixes.removeAll(keepingCapacity: true)
        independentlyClockedClientGenerations.removeAll(keepingCapacity: true)
        lastEmittedCycleCounter = nil
        lastEmittedSampleTime = nil
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
        stateLock.unlock()
        publishApplications(force: true)
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
        publishApplications(force: forcePublication)
    }

    private static func cycleIsNewer(_ candidate: UInt64, than reference: UInt64) -> Bool {
        let distance = candidate &- reference
        return distance != 0 && distance < (UInt64(1) << 63)
    }

    private func emitOldestPendingMixLocked() -> PCMFrame? {
        guard !pendingMixes.isEmpty else { return nil }
        let mix = pendingMixes.removeFirst()
        lastEmittedCycleCounter = mix.cycleCounter
        lastEmittedSampleTime = mix.sampleTime
        return frame(from: mix)
    }

    private func frame(from mix: PendingMix) -> PCMFrame {
        let activeClientCount = max(1, mix.clientKeys.count)
        return PCMFrame(
            interleaved: mix.samples,
            channelCount: mix.channelCount,
            sampleRate: mix.sampleRate,
            channelLayout: mix.channelLayout,
            sourceBufferedFrames: mix.sourceBufferedFrames / activeClientCount,
            sourceCapacityFrames: mix.sourceCapacityFrames
        )
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

    private func publishApplications(force: Bool = false) {
        stateLock.lock()
        let now = Date()
        let hasVisiblePresentation = meterPresentationSources.contains {
            !suspendedMeterPresentationSources.contains($0)
        }
        if !force && !hasVisiblePresentation {
            stateLock.unlock()
            return
        }
        if !force && now.timeIntervalSince(lastPublishDate) < Self.publishInterval {
            stateLock.unlock()
            return
        }
        lastPublishDate = now
        let clients = Array(clientsByKey.values)
        let identities = identitiesByClientKey
        let runningApplications = runningApplicationsByID
        let settings = settingsByApplication
        let levels = presentationLevelsByApplication
        let knownAudioApplications = knownAudioApplicationIDs
        stateLock.unlock()

        var visibleIdentities = runningApplications.filter { _, identity in
            let hasProducedAudio = knownAudioApplications.contains(identity.id)
            return Self.shouldPresentApplication(
                isDockApplication: identity.isDockApplication,
                isAccessoryApplication: identity.isAccessoryApplication,
                hasProducedAudio: hasProducedAudio
            )
                && (!Self.isKnownNonAudioSystemApplication(bundleID: identity.bundleID)
                    || hasProducedAudio)
        }
        for client in clients where client.isActive {
            guard let identity = identities[client.transportKey] else { continue }
            let hasProducedAudio = knownAudioApplications.contains(identity.id)
            guard identity.isDockApplication || hasProducedAudio else { continue }
            guard !Self.isKnownNonAudioSystemApplication(bundleID: identity.bundleID)
                    || hasProducedAudio else { continue }
            if visibleIdentities[identity.id] == nil {
                visibleIdentities[identity.id] = identity
            }
        }

        let snapshot = visibleIdentities.map { applicationID, identity in
            return PerAppAudioApplication(
                id: applicationID,
                bundleID: identity.bundleID,
                bundleURL: identity.bundleURL,
                processID: identity.processID,
                displayName: identity.displayName,
                isActive: true,
                level: levels[applicationID] ?? 0,
                settings: settings[applicationID] ?? PerAppAudioSettings()
            )
        }
        .sorted {
            if $0.isActive != $1.isActive { return $0.isActive && !$1.isActive }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        enqueueApplicationSnapshot(snapshot)
    }

    private func enqueueApplicationSnapshot(_ snapshot: [PerAppAudioApplication]) {
        publicationQueue.async { [weak self] in
            guard let self else { return }
            // Always retain only the newest snapshot while a MainActor delivery
            // is pending. This preserves the old coalescing behavior without
            // making the UI reacquire `stateLock`.
            self.pendingApplicationSnapshot = snapshot
            self.scheduleMainPublicationIfNeeded()
        }
    }

    private func scheduleMainPublicationIfNeeded() {
        dispatchPrecondition(condition: .onQueue(publicationQueue))
        guard !mainPublishScheduled, let snapshot = pendingApplicationSnapshot else {
            return
        }

        pendingApplicationSnapshot = nil
        mainPublishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Intentionally lock-free on MainActor. `snapshot` is immutable and
            // all coalescing bookkeeping stays on `publicationQueue`.
            self.applications = snapshot

            self.publicationQueue.async { [weak self] in
                guard let self else { return }
                self.mainPublishScheduled = false
                self.scheduleMainPublicationIfNeeded()
            }
        }
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
            let resolved = Dictionary(
                NSWorkspace.shared.runningApplications.compactMap {
                    Self.resolveRunningApplicationIdentity($0).map { ($0.id, $0) }
                },
                uniquingKeysWith: { current, candidate in
                    if current.isDockApplication != candidate.isDockApplication {
                        return current.isDockApplication ? current : candidate
                    }
                    return current.processID <= candidate.processID ? current : candidate
                }
            )
            self.stateLock.lock()
            self.runningApplicationsByID = resolved
            self.pendingRunningApplicationRefresh = nil
            self.stateLock.unlock()
            self.publishApplications(force: true)
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
        guard client.processID > 0,
              client.processID != Int32(ProcessInfo.processInfo.processIdentifier) else {
            return nil
        }
        guard !isSystemAudioService(bundleID: client.bundleID) else { return nil }

        let processExists = Darwin.kill(client.processID, 0) == 0 || errno == EPERM
        let running = processExists
            ? NSRunningApplication(processIdentifier: client.processID)
            : nil
        guard running?.isTerminated != true else { return nil }

        let reportedBundleID = running?.bundleIdentifier ?? client.bundleID
        let canonicalBundleID = canonicalApplicationBundleID(reportedBundleID)
        let outerBundleURL = outermostApplicationURL(from: running?.bundleURL)
            ?? ((canonicalBundleID != reportedBundleID) ? canonicalBundleID.flatMap {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            } : nil)

        let applicationBundle = outerBundleURL.flatMap(Bundle.init(url:))
        let bundleID = applicationBundle?.bundleIdentifier
            ?? canonicalBundleID
            ?? reportedBundleID
        let ownURL = Bundle.main.bundleURL.standardizedFileURL
        let ownBundleID = Bundle.main.bundleIdentifier
        if outerBundleURL?.standardizedFileURL == ownURL
            || (bundleID != nil && bundleID == ownBundleID) {
            return nil
        }
        guard outerBundleURL != nil || bundleID?.isEmpty == false else { return nil }

        let displayName = (applicationBundle?.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String)
            ?? (applicationBundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? running?.localizedName
            ?? bundleID?.split(separator: ".").last.map(String.init)
            ?? "Application"
        guard !isSystemAudioService(
            bundleID: bundleID,
            displayName: displayName
        ) else { return nil }
        let id = bundleID
            ?? outerBundleURL.map { "app:\($0.standardizedFileURL.path)" }
            ?? "pid:\(client.processID)"
        return ApplicationIdentity(
            id: id,
            bundleID: bundleID,
            bundleURL: outerBundleURL,
            processID: client.processID,
            displayName: displayName,
            isDockApplication: running?.activationPolicy == .regular,
            isAccessoryApplication: running?.activationPolicy == .accessory
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
    /// while `publishApplications` still lets direct audio history override
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

    private static func resolveRunningApplicationIdentity(
        _ running: NSRunningApplication
    ) -> ApplicationIdentity? {
        guard running.processIdentifier > 0,
              running.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              running.isTerminated == false,
              running.activationPolicy == .regular
                || running.activationPolicy == .accessory else {
            return nil
        }

        let reportedBundleID = running.bundleIdentifier
        guard !isSystemAudioService(
            bundleID: reportedBundleID,
            displayName: running.localizedName
        ) else { return nil }
        let canonicalBundleID = canonicalApplicationBundleID(reportedBundleID)
        let outerBundleURL = outermostApplicationURL(from: running.bundleURL)
        let applicationBundle = outerBundleURL.flatMap(Bundle.init(url:))
        let bundleID = applicationBundle?.bundleIdentifier
            ?? canonicalBundleID
            ?? reportedBundleID
        let displayName = (applicationBundle?.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String)
            ?? (applicationBundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? running.localizedName
            ?? bundleID?.split(separator: ".").last.map(String.init)
            ?? "Application"
        guard !isSystemAudioService(
            bundleID: bundleID,
            displayName: displayName
        ) else { return nil }
        let id = bundleID
            ?? outerBundleURL.map { "app:\($0.standardizedFileURL.path)" }
            ?? "pid:\(running.processIdentifier)"
        return ApplicationIdentity(
            id: id,
            bundleID: bundleID,
            bundleURL: outerBundleURL,
            processID: running.processIdentifier,
            displayName: displayName,
            isDockApplication: running.activationPolicy == .regular,
            isAccessoryApplication: running.activationPolicy == .accessory
        )
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
        return components[..<helperIndex].joined(separator: ".")
    }

    private static func outermostApplicationURL(from bundleURL: URL?) -> URL? {
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

    private static func loadSettings(from url: URL) -> [String: PerAppAudioSettings] {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(
                [String: PerAppAudioSettings].self,
                from: data
              ) else { return [:] }
        return settings
    }

    private static func loadAudioHistory(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let identifiers = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(identifiers)
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
        for band in settings.equalizerBands where band.enabled {
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
        guard !settings.equalizerBands.isEmpty else { return 1 }
        let response = EQResponseCalculator().calculate(
            parsed: ParsedEQ(bands: settings.equalizerBands),
            sampleRate: sampleRate,
            count: 600
        )
        let boost = max(0, response.map(\.gainDB).max() ?? 0)
        return Float(pow(10, -boost / 20))
    }

    private func schedulePersistence(_ settings: [String: PerAppAudioSettings]) {
        pendingPersistence?.cancel()
        let url = settingsURL
        let work = DispatchWorkItem {
            Self.persist(settings, to: url)
        }
        pendingPersistence = work
        persistenceQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func scheduleAudioHistoryPersistence(_ identifiers: Set<String>) {
        let url = audioHistoryURL
        let work = DispatchWorkItem {
            Self.persistAudioHistory(identifiers, to: url)
        }
        stateLock.lock()
        pendingHistoryPersistence?.cancel()
        pendingHistoryPersistence = work
        stateLock.unlock()
        persistenceQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private static func persist(
        _ settings: [String: PerAppAudioSettings],
        to settingsURL: URL
    ) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: settingsURL, options: .atomic)
    }

    private static func persistAudioHistory(
        _ identifiers: Set<String>,
        to historyURL: URL
    ) {
        guard let data = try? JSONEncoder().encode(identifiers.sorted()) else { return }
        try? FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: historyURL, options: .atomic)
    }
}

private struct PerAppFilterBank {
    private struct Signature: Hashable {
        var channelCount: Int
        var sampleRate: Double
        var bands: [EQBand]
        var settingsRevision: UInt64
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
        settingsRevision: UInt64
    ) {
        let activeBands = bands.filter {
            $0.enabled && $0.frequency > 0 && $0.frequency < sampleRate / 2
        }
        let nextSignature = Signature(
            channelCount: channelCount,
            sampleRate: sampleRate,
            bands: activeBands,
            settingsRevision: settingsRevision
        )
        if signature != nextSignature {
            signature = nextSignature
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
