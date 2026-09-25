import CamiTuneDomain
import Foundation

/// Owns per-application settings, processing revisions, and their durable document.
/// The facade's state lock serializes in-memory access. File work is ordered on
/// a separate queue; it never acquires the facade's state or audio locks.
final class PerAppSettingsStore {
    struct Snapshot: Sendable {
        let revision: UInt64
        let settings: [String: PerAppAudioSettings]
    }
    struct SaveResult: Sendable {
        let sequence: UInt64
        let revision: UInt64
        let error: String?
    }
    private let url: URL
    private var values: [String: PerAppAudioSettings]
    private var documentRevision: UInt64 = 0
    private var revisions: [String: UInt64] = [:]
    let loadError: String?
    private let persistenceQueue = DispatchQueue(label: "CamiTune.PerAppAudioSettings", qos: .utility)
    // Accessed exclusively by persistenceQueue, including cancellation/barriers.
    private var pendingSave: DispatchWorkItem?
    private var latestSave: Snapshot
    private var saveSequence: UInt64 = 0

    init(url: URL) {
        self.url = url
        let loaded = Self.loadSettings(from: url)
        values = loaded.settings
        latestSave = .init(revision: 0, settings: loaded.settings)
        loadError = loaded.error
    }

    var snapshot: Snapshot { .init(revision: documentRevision, settings: values) }
    func settings(for id: String) -> PerAppAudioSettings { values[id] ?? PerAppAudioSettings() }
    func revision(for id: String) -> UInt64 { revisions[id] ?? 0 }

    func update(for id: String, invalidatesProcessing: Bool,
                change: (inout PerAppAudioSettings) -> Void) {
        var value = settings(for: id)
        change(&value)
        values[id] = value
        documentRevision &+= 1
        if invalidatesProcessing { revisions[id, default: 0] &+= 1 }
    }

    /// Existing stable settings win; both identities' processing revisions survive.
    func migrate(from temporaryID: String, to stableID: String) -> Bool {
        guard let temporary = values.removeValue(forKey: temporaryID) else { return false }
        if values[stableID] == nil { values[stableID] = temporary }
        let revision = revisions.removeValue(forKey: temporaryID) ?? 0
        revisions[stableID] = max(revisions[stableID] ?? 0, revision)
        documentRevision &+= 1
        return true
    }

    func scheduleSave(_ snapshot: Snapshot, completion: @escaping (SaveResult) -> Void) {
        persistenceQueue.async { [self] in
            guard accept(snapshot) else { return }
            pendingSave?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                completion(self.persistLatest())
            }
            pendingSave = work
            persistenceQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    /// Drains older writes and persists the newest accepted document. A caller
    /// delayed after capturing its snapshot cannot overwrite a newer revision.
    func flush(_ snapshot: Snapshot) -> SaveResult {
        persistenceQueue.sync {
            _ = accept(snapshot)
            pendingSave?.cancel()
            pendingSave = nil
            return persistLatest()
        }
    }

    private func accept(_ snapshot: Snapshot) -> Bool {
        guard snapshot.revision >= latestSave.revision else { return false }
        latestSave = snapshot
        return true
    }

    private func persistLatest() -> SaveResult {
        // Every call follows accept on the same ordered worker.
        let snapshot = latestSave
        saveSequence &+= 1
        return .init(sequence: saveSequence, revision: snapshot.revision,
            error: Self.persist(snapshot.settings, to: url))
    }

    private static func loadSettings(from url: URL) -> (settings: [String: PerAppAudioSettings], error: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([:], nil) }
        do {
            let settings = try PerAppAudioDocument.decode(Data(contentsOf: url))
            return (settings.filter { PerAppApplicationIdentityPolicy.isPersistentApplicationID($0.key) }, nil)
        } catch {
            return ([:], "Per-application settings could not be read. The original file is preserved; changes cannot be saved until it is restored or opened by a compatible version.")
        }
    }

    private static func persist(_ settings: [String: PerAppAudioSettings], to settingsURL: URL) -> String? {
        let persistentSettings = settings.filter { PerAppApplicationIdentityPolicy.isPersistentApplicationID($0.key) }
        do {
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                // Never replace newer or unreadable data, including a file changed
                // by another version while this process was running.
                let previous = try PerAppAudioDocument.decode(Data(contentsOf: settingsURL))
                if previous.filter({ PerAppApplicationIdentityPolicy.isPersistentApplicationID($0.key) }) == persistentSettings { return nil }
            } else if persistentSettings.isEmpty { return nil }
            let data = try JSONEncoder().encode(PerAppAudioDocument(settings: persistentSettings))
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: settingsURL, options: .atomic)
            return nil
        } catch {
            return "Per-application settings were not saved. Check storage access and file compatibility. The previous file is preserved."
        }
    }
}
