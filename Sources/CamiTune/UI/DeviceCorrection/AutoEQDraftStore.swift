import CamiTuneDomain
import Foundation
import Combine

protocol PersistedAutoEQWork: Codable, Equatable, Sendable {
    func migrated() throws -> Self
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
    private let url: URL
    private let queue = DispatchQueue(label: "CamiTune.AutoEQDraft", qos: .utility)
    private var latest: Draft?
    private var canSave = false
    private var saveSequence = 0
    // Accessed only on the serial file queue, including across queued saves.
    private final class RecoveryState: @unchecked Sendable {
        var needsBackup = false
        var backupURL: URL?
    }
    private let recovery = RecoveryState()
    var recoveryBackupURL: URL? { queue.sync { recovery.backupURL } }

    init(url: URL) { self.url = url }

    static func url(profileID: UUID, endpoint: ProfileEndpointKind, directory: URL = CamiTunePaths.supportDirectory) -> URL {
        directory.appendingPathComponent("AutoEQDrafts", isDirectory: true)
            .appendingPathComponent("\(profileID.uuidString)-\(endpoint.rawValue).json")
    }

    func load() -> Draft? {
        finishLoading(queue.sync { Self.read(url: url, recovery: recovery) })
    }

    /// JSON and measurement arrays can be large. Opening an editor must not
    /// block AppKit event handling while restoring them from disk.
    func loadWithoutBlockingUI() async -> Draft? {
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

    func save(_ draft: Draft) {
        guard canSave, latest != draft else { return }
        latest = draft
        saveSequence += 1
        let sequence = saveSequence
        let url = url
        let recovery = recovery
        queue.async { [weak self] in
            let message: String?
            do {
                let encoder = JSONEncoder()
                encoder.nonConformingFloatEncodingStrategy = .convertToString(
                    positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
                let data = try encoder.encode(draft)
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
            Task { @MainActor [weak self] in
                guard let self, self.saveSequence == sequence else { return }
                if self.errorMessage != message { self.errorMessage = message }
                if message != nil { self.latest = nil } // Allow a later save to retry.
            }
        }
    }

    func flush() { queue.sync {} }
}

typealias AutoEQDraftStore = AutoEQWorkStore<AutoEQEditorDraft>
typealias SpeakerAutoEQDraftStore = AutoEQWorkStore<SpeakerAutoEQEditorDraft>
