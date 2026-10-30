import CamiTuneDomain
import Foundation
import Combine

protocol PersistedAutoEQWork: Codable, Equatable, Sendable {
    var sampleRate: Double { get }
    func migrated() throws -> Self
    var historyState: HistoryState { get }
    func preservingPresentation(from current: Self?) -> Self
    func restored(for sampleRate: Double) -> Self
}

extension AutoEQEditorDraft: PersistedAutoEQWork {
    func migrated() throws -> Self {
        guard (1...2).contains(schemaVersion) else { throw CocoaError(.coderReadCorrupt) }
        var value = self
        value.schemaVersion = 2
        return value
    }
}

@MainActor
final class AutoEQWorkStore<Draft: PersistedAutoEQWork>: ObservableObject {
    @Published private(set) var errorMessage: String?
    @Published private(set) var replayRevision: UInt64 = 0
    weak var history: UndoCoordinator?
    var historyTarget: HistoryTarget?
    var contextName: String?
    private let url: URL
    private let queue = DispatchQueue(label: "CamiTune.AutoEQDraft", qos: .utility)
    private(set) var latest: Draft?
    private var canSave = false
    private var saveSequence = 0
    // Accessed only on the serial file queue, including across queued saves.
    private final class RecoveryState: @unchecked Sendable {
        var needsBackup = false
        var backupURL: URL?
        var writeError: String?
    }
    private let recovery = RecoveryState()
    var recoveryBackupURL: URL? { queue.sync { recovery.backupURL } }

    init(url: URL) { self.url = url }

    static func url(profileID: UUID, endpoint: ProfileEndpointKind, directory: URL = CamiTunePaths.supportDirectory) -> URL {
        directory.appendingPathComponent("AutoEQDrafts", isDirectory: true)
            .appendingPathComponent("\(profileID.uuidString)-\(endpoint.rawValue).json")
    }

    func load() -> Draft? {
        if canSave { return latest }
        return finishLoading(queue.sync { Self.read(url: url, recovery: recovery) })
    }

    /// JSON and measurement arrays can be large. Opening an editor must not
    /// block AppKit event handling while restoring them from disk.
    func loadWithoutBlockingUI() async -> Draft? {
        if canSave { return latest }
        let url = url
        let recovery = recovery
        let result = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.read(url: url, recovery: recovery))
            }
        }
        return finishLoading(result)
    }

    private nonisolated static func read(url: URL, recovery: RecoveryState) -> Result<Draft?, Error> {
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                recovery.needsBackup = false
                return .success(nil)
            }
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(
                positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            let draft = try decoder.decode(Draft.self, from: Data(contentsOf: url)).migrated()
            recovery.needsBackup = false
            return .success(draft)
        } catch {
            // Preserve unreadable work before replacing it with a new draft.
            recovery.needsBackup = true
            return .failure(error)
        }
    }

    private func finishLoading(_ result: Result<Draft?, Error>) -> Draft? {
        guard !canSave else { return latest }
        canSave = true
        switch result {
        case .success(let draft):
            latest = draft
            errorMessage = nil
            return draft
        case .failure(let error):
            latest = nil
            errorMessage = "Could not restore Auto EQ work: \(error.localizedDescription)"
            return nil
        }
    }

    func save(_ proposed: Draft, expectedRevision: UInt64? = nil) {
        guard history?.isReplaying != true,
              expectedRevision == nil || expectedRevision == replayRevision else { return }
        var draft = proposed
        // Rate changes invalidate the displayed calculation without destroying
        // saved work. Undoing the profile rate can then recover that result.
        if let previous = latest, previous.sampleRate != proposed.sampleRate,
           previous.restored(for: proposed.sampleRate).historyState == proposed.historyState {
            draft = previous.preservingPresentation(from: proposed)
        }
        persist(draft)
    }

    private func persist(_ draft: Draft) {
        guard canSave, latest != draft || errorMessage != nil else { return }
        let previous = latest
        latest = draft
        if let previous, let historyTarget {
            history?.record(actionName: "Edit Auto EQ", contextName: contextName, target: historyTarget,
                before: previous.historyState, after: draft.historyState)
        }
        saveSequence += 1
        let sequence = saveSequence
        let url = url
        let recovery = recovery
        let savedDraft = draft
        let access = ProfileAssetStorage.shared.beginAccess()
        queue.async { [weak self, access] in
            defer { withExtendedLifetime(access) {} }
            let message: String?
            do {
                let encoder = JSONEncoder()
                encoder.nonConformingFloatEncodingStrategy = .convertToString(
                    positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
                let data = try encoder.encode(savedDraft)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if recovery.needsBackup {
                    if FileManager.default.fileExists(atPath: url.path) {
                        let backupURL = url.appendingPathExtension("recovery-\(UUID().uuidString).backup")
                        try FileManager.default.copyItem(at: url, to: backupURL)
                        recovery.backupURL = backupURL
                    }
                    recovery.needsBackup = false
                }
                try data.write(to: url, options: .atomic)
                message = nil
            } catch {
                message = "Could not save Auto EQ work: \(error.localizedDescription)"
            }
            recovery.writeError = message
            Task { @MainActor [weak self] in
                guard let self, self.saveSequence == sequence else { return }
                if self.errorMessage != message { self.errorMessage = message }
            }
        }
    }

    func flush() { queue.sync {} }

    func restoreHistory(_ draft: Draft) async throws {
        persist(draft.preservingPresentation(from: latest))
        // Retire callbacks from the old editor before the filesystem await.
        replayRevision &+= 1
        let recovery = recovery
        let failure: String? = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: recovery.writeError) }
        }
        if let failure { throw ProfileSettingsError.runtime(failure) }
    }
}

typealias AutoEQDraftStore = AutoEQWorkStore<AutoEQEditorDraft>
typealias SpeakerAutoEQDraftStore = AutoEQWorkStore<SpeakerAutoEQEditorDraft>

@MainActor
extension AppState {
    func autoEQDraftStore(profile: DeviceProfile) -> AutoEQDraftStore {
        let target = HistoryTarget.autoEQ(profile.id, profile.effectiveEndpointKind)
        if let store = autoEQDraftStores[target] { return store }
        let store = AutoEQDraftStore(url: AutoEQDraftStore.url(profileID: profile.id,
            endpoint: profile.effectiveEndpointKind, directory: profiles.assetStorage.directory))
        store.history = history; store.historyTarget = target; store.contextName = profile.name
        autoEQDraftStores[target] = store
        return store
    }

    func speakerAutoEQDraftStore(profile: DeviceProfile, directory: URL? = nil) -> SpeakerAutoEQDraftStore {
        if let store = speakerAutoEQDraftStores[profile.id] { return store }
        let store = SpeakerAutoEQDraftStore(url: SpeakerAutoEQDraftStore.url(profileID: profile.id, endpoint: .speakers,
            directory: directory ?? profiles.assetStorage.directory))
        store.history = history; store.historyTarget = .speakerAutoEQ(profile.id); store.contextName = profile.name
        speakerAutoEQDraftStores[profile.id] = store
        return store
    }
}
