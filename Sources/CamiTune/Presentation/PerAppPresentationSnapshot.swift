import Foundation

struct PerAppPresentationIdentity: Hashable, Sendable {
    var id: String
    var bundleID: String?
    var bundleURL: URL?
    var processID: Int32
    var displayName: String
    var isDockApplication: Bool
    var isAccessoryApplication: Bool
}

/// Packet-proven owners survive independent client-registry gaps.
struct PerAppObservedAudioSource: Sendable {
    var transportKey: PerAppTransportClientKey
    var processID: Int32
    var applicationID: String
    var identity: PerAppPresentationIdentity?
}

/// Value-only boundary. Capture detaches frequently mutated collections before
/// releasing stateLock, so row construction cannot push COW copies onto ingestion.
struct PerAppPresentationInput: Sendable {
    let revision: UInt64
    var clients: [PerAppDriverClient] = []
    var identities: [PerAppTransportClientKey: PerAppPresentationIdentity] = [:]
    var workspaceIdentities: [Int32: PerAppPresentationIdentity] = [:]
    var runningApplications: [String: PerAppPresentationIdentity] = [:]
    var settings: [String: PerAppAudioSettings] = [:]
    var levels: [String: Double] = [:]
    var knownAudioApplications: Set<String> = []
    var observedAudioApplications: Set<String> = []
    var observedAudioSources: [PerAppObservedAudioSource] = []
    var exhaustedClientKeys: Set<PerAppTransportClientKey> = []
}

struct PerAppPresentationSnapshot: Sendable {
    let revision: UInt64
    let applications: [PerAppAudioApplication]
    private typealias ApplicationIdentity = PerAppPresentationIdentity

    static func build(from input: PerAppPresentationInput) -> Self {
        .init(revision: input.revision, applications: makeRows(input).sorted(by: precedes))
    }
    static func precedes(_ first: PerAppAudioApplication, _ second: PerAppAudioApplication) -> Bool {
        if first.isActive != second.isActive { return first.isActive && !second.isActive }
        return first.displayName.localizedCaseInsensitiveCompare(second.displayName) == .orderedAscending
    }
    static func makeRows(_ input: PerAppPresentationInput) -> [PerAppAudioApplication] {
        let clients = input.clients; let identities = input.identities
        let workspaceIdentities = input.workspaceIdentities; let runningApplications = input.runningApplications
        let settings = input.settings; let levels = input.levels
        let knownAudioApplications = input.knownAudioApplications; let observedAudioApplications = input.observedAudioApplications
        let observedAudioSources = input.observedAudioSources; let exhaustedClientKeys = input.exhaustedClientKeys
        var visibleIdentities: [String: ApplicationIdentity] = [:]

        // Core Audio clients are authoritative. Workspace metadata only fills
        // ownership gaps; activation policy never vetoes observed audio.
        for client in clients where client.isActive {
            guard let identity = identities[client.transportKey]
                    ?? workspaceIdentities[client.processID] else { continue }
            let hasAudioEvidence = observedAudioApplications.contains(identity.id)
                || knownAudioApplications.contains(identity.id)
            guard hasAudioEvidence else { continue }
            guard !PerAppAudioController.isSystemAudioService(
                bundleID: identity.bundleID,
                displayName: identity.displayName
            ) else { continue }
            if PerAppAudioController.isEphemeralApplicationID(identity.id) {
                guard exhaustedClientKeys.contains(client.transportKey),
                      identity.displayName != "Application" else { continue }
            }
            visibleIdentities[identity.id] = Self.preferredIdentity(
                visibleIdentities[identity.id],
                identity
            )
        }

        // PCM packets and registry updates travel through independent channels.
        // Do not make a real audio source disappear (or lose its control ID)
        // merely because the registry snapshot arrived late or was transiently
        // empty. The retained owner was resolved off the packet's exact DSP key.
        for source in observedAudioSources {
            let registeredIdentity = identities[source.transportKey].flatMap { identity in
                source.processID <= 0 || identity.processID == source.processID ? identity : nil
            }
            guard let identity = registeredIdentity
                    ?? workspaceIdentities[source.processID]
                    ?? source.identity
                    ?? runningApplications[source.applicationID] else { continue }
            guard observedAudioApplications.contains(source.applicationID)
                    || observedAudioApplications.contains(identity.id)
                    || knownAudioApplications.contains(source.applicationID)
                    || knownAudioApplications.contains(identity.id) else { continue }
            guard !PerAppAudioController.isSystemAudioService(
                bundleID: identity.bundleID,
                displayName: identity.displayName
            ) else { continue }
            if PerAppAudioController.isEphemeralApplicationID(identity.id) {
                guard exhaustedClientKeys.contains(source.transportKey),
                      identity.displayName != "Application" else { continue }
            }
            visibleIdentities[identity.id] = Self.preferredIdentity(
                visibleIdentities[identity.id],
                identity
            )
        }

        // Keep an audio-proven running owner stable across short-lived helper
        // restarts without reintroducing an idle Workspace application roster.
        for (applicationID, identity) in runningApplications {
            guard observedAudioApplications.contains(applicationID)
                    || knownAudioApplications.contains(applicationID) else { continue }
            guard !PerAppAudioController.isEphemeralApplicationID(applicationID),
                  !PerAppAudioController.isSystemAudioService(
                    bundleID: identity.bundleID,
                    displayName: identity.displayName
                  ) else { continue }
            visibleIdentities[applicationID] = Self.preferredIdentity(
                visibleIdentities[applicationID],
                identity
            )
        }

        return visibleIdentities.map { applicationID, identity in
            return PerAppAudioApplication(
                id: applicationID,
                bundleID: identity.bundleID,
                bundleURL: identity.bundleURL,
                processID: identity.processID,
                displayName: identity.displayName,
                // Every published row is already backed by audio evidence.
                // Keep it available across brief client-registry gaps so its
                // meter and controls do not disappear from the UI.
                isActive: true,
                level: levels[applicationID] ?? 0,
                settings: settings[applicationID] ?? PerAppAudioSettings()
            )
        }
    }

    private static func preferredIdentity(
        _ current: ApplicationIdentity?,
        _ candidate: ApplicationIdentity
    ) -> ApplicationIdentity {
        guard let current else { return candidate }
        if current.bundleURL == nil, candidate.bundleURL != nil { return candidate }
        if !current.isDockApplication, candidate.isDockApplication { return candidate }
        if current.displayName == "Application", candidate.displayName != "Application" {
            return candidate
        }
        return current.processID <= candidate.processID ? current : candidate
    }

}
