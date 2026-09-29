import CamiTuneDomain
import Foundation
import Combine

@MainActor
final class AutoEQDraftStore: ObservableObject {
    @Published private(set) var errorMessage: String?
    private let url: URL
    private let queue = DispatchQueue(label: "CamiTune.AutoEQDraft", qos: .utility)
    private var latest: AutoEQEditorDraft?
    private var canSave = false
    private var saveSequence = 0

    init(url: URL) { self.url = url }

    static func url(profileID: UUID, endpoint: ProfileEndpointKind, directory: URL = CamiTunePaths.supportDirectory) -> URL {
        directory.appendingPathComponent("AutoEQDrafts", isDirectory: true)
            .appendingPathComponent("\(profileID.uuidString)-\(endpoint.rawValue).json")
    }

    func load() -> AutoEQEditorDraft? {
        do {
            let draft: AutoEQEditorDraft? = try queue.sync {
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                let decoder = JSONDecoder()
                decoder.nonConformingFloatDecodingStrategy = .convertFromString(
                    positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
                var decoded = try decoder.decode(AutoEQEditorDraft.self, from: Data(contentsOf: url))
                guard (1...2).contains(decoded.schemaVersion) else {
                    throw CocoaError(.coderReadCorrupt)
                }
                decoded.schemaVersion = 2
                return decoded
            }
            latest = draft
            canSave = true
            errorMessage = nil
            return draft
        } catch {
            canSave = false // Preserve an unreadable or newer draft instead of overwriting it.
            errorMessage = "Could not restore Auto EQ work: \(error.localizedDescription)"
            return nil
        }
    }

    func save(_ draft: AutoEQEditorDraft) {
        guard canSave, latest != draft else { return }
        latest = draft
        saveSequence += 1
        let sequence = saveSequence
        let url = url
        queue.async { [weak self] in
            let message: String?
            do {
                let encoder = JSONEncoder()
                encoder.nonConformingFloatEncodingStrategy = .convertToString(
                    positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
                let data = try encoder.encode(draft)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
