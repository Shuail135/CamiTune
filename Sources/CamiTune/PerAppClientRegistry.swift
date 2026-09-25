import AppKit
import CamiTuneAudio
import Foundation
import Darwin

/// Owns transport-client indexes, resolved process identities, workspace discovery,
/// and bounded identity retries. In-memory methods use the facade's state lock so
/// packet attribution and settings are captured coherently. Platform lookups run
/// on dedicated queues and enter the facade only through generation-checked results.
final class PerAppClientRegistry {
    typealias ApplicationIdentity = PerAppPresentationIdentity
    private let stateLock: NSLock
    private let monitorsRunningApplications: Bool
    private static let identityRetryDelays: [TimeInterval] = [0, 0.1, 0.25, 0.5, 1, 2]
    private var onResolved: (([PerAppTransportClientKey: ApplicationIdentity], [PerAppDriverClient], Set<PerAppTransportClientKey>, UInt64, Int) -> Bool)?
    private var onWorkspace: (([String: ApplicationIdentity], [Int32: ApplicationIdentity]) -> Void)?
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
    private(set) var clientsByKey: [PerAppTransportClientKey: PerAppDriverClient] = [:]
    private(set) var uniqueClientKeyByProcessID: [Int32: PerAppTransportClientKey] = [:]
    private(set) var uniqueClientKeyByClientID: [UInt32: PerAppTransportClientKey] = [:]
    private(set) var applicationKeyByProcessID: [Int32: String] = [:]
    private(set) var identitiesByClientKey: [PerAppTransportClientKey: ApplicationIdentity] = [:]
    private(set) var workspaceIdentitiesByProcessID: [Int32: ApplicationIdentity] = [:]
    private(set) var runningApplicationsByID: [String: ApplicationIdentity] = [:]
    private var pendingRunningApplicationRefresh: DispatchWorkItem?
    private var identityRetryWorkItem: DispatchWorkItem?
    private(set) var identityRetryExhaustedClientKeys: Set<PerAppTransportClientKey> = []
    private var identityResolutionRevision: UInt64 = 0
    private var workspaceObservers: [NSObjectProtocol] = []
    private let identityQueue = DispatchQueue(
        label: "CamiTune.PerAppAudioIdentity",
        qos: .userInitiated
    )
    private let runningApplicationQueue = DispatchQueue(
        label: "CamiTune.RunningApplicationRoster",
        qos: .utility
    )

    init(stateLock: NSLock, monitorsRunningApplications: Bool) {
        self.stateLock = stateLock
        self.monitorsRunningApplications = monitorsRunningApplications
    }

    func start(onResolved: @escaping ([PerAppTransportClientKey: ApplicationIdentity], [PerAppDriverClient], Set<PerAppTransportClientKey>, UInt64, Int) -> Bool,
               onWorkspace: @escaping ([String: ApplicationIdentity], [Int32: ApplicationIdentity]) -> Void) {
        self.onResolved = onResolved
        self.onWorkspace = onWorkspace
        if monitorsRunningApplications {
            observeWorkspaceApplications()
            scheduleRunningApplicationRefresh(immediate: true)
        }
    }

    func shutdown() {
        stateLock.lock()
        identityRetryWorkItem?.cancel()
        pendingRunningApplicationRefresh?.cancel()
        stateLock.unlock()
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
        workspaceObservers.removeAll()
    }

    func afterIdentityWork(_ work: @escaping () -> Void) { identityQueue.async(execute: work) }

    struct ClientUpdate {
        let clientsByKey: [PerAppTransportClientKey: PerAppDriverClient]
        let uniqueClientKeyByProcessID: [Int32: PerAppTransportClientKey]
        let uniqueClientKeyByClientID: [UInt32: PerAppTransportClientKey]
        let applicationKeyByProcessID: [Int32: String]
        init(_ clients: [PerAppDriverClient]) {
            clientsByKey = Dictionary(
                clients.map { ($0.transportKey, $0) },
                uniquingKeysWith: { current, candidate in
                    current.generation >= candidate.generation ? current : candidate
                }
            )
            uniqueClientKeyByProcessID = PerAppClientRegistry.uniqueClientKeys(
                clients,
                key: { $0.processID },
                isUsable: { $0 > 0 }
            )
            uniqueClientKeyByClientID = PerAppClientRegistry.uniqueClientKeys(
                clients,
                key: { $0.clientID },
                isUsable: { _ in true }
            )
            applicationKeyByProcessID = Dictionary(grouping: clients.filter { $0.processID > 0 }) {
                $0.processID
            }.compactMapValues { matches -> String? in
                let applicationKeys = Set(matches.map(\.applicationKey))
                return applicationKeys.count == 1 ? applicationKeys.first : nil
            }
        }
    }

    /// Caller holds stateLock; unchanged snapshots preserve retry progress.
    func replaceClients(_ next: ClientUpdate) -> UInt64? {
        guard clientsByKey != next.clientsByKey else { return nil }
        clientsByKey = next.clientsByKey
        identitiesByClientKey = identitiesByClientKey.filter { key, identity in
            clientsByKey[key]?.processID == identity.processID
        }
        uniqueClientKeyByProcessID = next.uniqueClientKeyByProcessID
        uniqueClientKeyByClientID = next.uniqueClientKeyByClientID
        applicationKeyByProcessID = next.applicationKeyByProcessID
        identityResolutionRevision &+= 1
        identityRetryWorkItem?.cancel()
        identityRetryWorkItem = nil
        identityRetryExhaustedClientKeys.removeAll()
        return identityResolutionRevision
    }

    /// Caller holds stateLock; nil rejects stale discovery without migration.
    func acceptResolution(_ resolved: [PerAppTransportClientKey: ApplicationIdentity],
                          unresolvedActiveKeys: Set<PerAppTransportClientKey>, revision: UInt64,
                          attempt: Int) -> Bool? {
        guard identityResolutionRevision == revision else { return nil }
        identitiesByClientKey = resolved
        let hasAnotherRetry = !unresolvedActiveKeys.isEmpty && attempt + 1 < Self.identityRetryDelays.count
        identityRetryExhaustedClientKeys = hasAnotherRetry ? [] : unresolvedActiveKeys
        if !hasAnotherRetry { identityRetryWorkItem = nil }
        return hasAnotherRetry
    }

    func recordWorkspace(running: [String: ApplicationIdentity], audio: [Int32: ApplicationIdentity]) {
        runningApplicationsByID = running
        workspaceIdentitiesByProcessID = audio
        pendingRunningApplicationRefresh = nil
    }

    struct ResolvedStreamIdentity {
        let processID: Int32?
        let generation: UInt64
        let application: ApplicationIdentity?
        let fallbackApplicationID: String
    }

    /// One immutable packet attribution snapshot, captured under the facade state lock.
    /// The original packet transport key still owns DSP history.
    func resolveStream(_ packet: PerAppAudioPacket) -> ResolvedStreamIdentity {
        let key = clientKey(for: packet)
        let client = key.flatMap { clientsByKey[$0] }
        let workspace = packet.processID > 0 ? workspaceIdentitiesByProcessID[packet.processID] : nil
        let application = key.flatMap { identitiesByClientKey[$0] } ?? workspace
        let applicationKey = packet.processID > 0 ? applicationKeyByProcessID[packet.processID] : nil
        return .init(processID: packet.processID > 0 ? packet.processID : client?.processID,
            generation: client?.generation ?? 0, application: application,
            fallbackApplicationID: client?.applicationKey ?? applicationKey
                ?? (packet.processID > 0 ? "pid:\(packet.processID)" : nil)
                ?? "client:\(packet.deviceObjectID):\(packet.clientID)")
    }

    private func clientKey(for packet: PerAppAudioPacket) -> PerAppTransportClientKey? {
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
    }

    func scheduleIdentityResolution(
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
                      !PerAppApplicationIdentityPolicy.isEphemeralApplicationID(identity.id) else {
                    return client.transportKey
                }
                return nil
            })

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let retry = self.onResolved?(resolved, clients, unresolvedActiveKeys, revision, attempt) ?? false
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

    func scheduleRunningApplicationRefresh(immediate: Bool = false) {
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
            self.onWorkspace?(resolved, audioIdentities)
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

    static func identityDebug(_ message: @autoclosure () -> String) {
#if DEBUG
        NSLog("[PerAppIdentity] %@", message())
#endif
    }

    private static func isIdentityResolutionCandidate(_ client: PerAppDriverClient) -> Bool {
        client.processID > 0
            && client.processID != Int32(ProcessInfo.processInfo.processIdentifier)
            && !isSystemAudioService(bundleID: client.bundleID)
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

    static func isKnownNonAudioSystemApplication(bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.lowercased() else { return false }
        return knownNonAudioSystemApplicationBundleIDs.contains(bundleID)
    }

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
}
