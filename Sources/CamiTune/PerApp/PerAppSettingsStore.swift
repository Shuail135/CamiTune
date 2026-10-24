import CamiTuneDomain
import Foundation

enum PerAppSettingsScope: Hashable, Sendable {
    case active, global, profile(UUID), local(UUID)
}

/// Owns per-application settings, processing revisions, and their durable document.
/// The facade's state lock serializes in-memory access. File work is ordered on
/// a separate queue; it never acquires the facade's state or audio locks.
final class PerAppSettingsStore {
    struct Snapshot: Sendable {
        let revision: UInt64
        let settings: [String: PerAppAudioSettings]
        let document: PerAppAudioDocument
    }
    struct SaveResult: Sendable {
        let sequence: UInt64
        let revision: UInt64
        let error: String?
    }
    private let url: URL
    private var document: PerAppAudioDocument
    private(set) var activeProfileID: UUID?
    private var processingRevision: UInt64 = 0
    private var scopeRevision: UInt64 = 0
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
        document = loaded.document
        latestSave = .init(revision: 0, settings: loaded.document.settings, document: loaded.document)
        loadError = loaded.error
    }

    var snapshot: Snapshot { .init(revision: documentRevision, settings: values(for: .active), document: document) }
    func resolvedScope(_ scope: PerAppSettingsScope) -> PerAppSettingsScope {
        switch scope {
        case .active: return activeProfileID.map { resolvedScope(.profile($0)) } ?? .global
        case .profile(let id): return document.localProfileIDs.contains(id) ? .local(id) : .global
        default: return scope
        }
    }
    func values(for scope: PerAppSettingsScope) -> [String: PerAppAudioSettings] {
        if case .local(let id) = resolvedScope(scope) { return document.profileSettings[id] ?? [:] }
        return document.settings
    }
    func settings(for id: String, scope: PerAppSettingsScope = .active) -> PerAppAudioSettings {
        values(for: scope)[id] ?? PerAppAudioSettings()
    }
    func revision(for id: String) -> UInt64 { max(revisions[id] ?? 0, scopeRevision) }
    func setActiveProfile(_ id: UUID?) {
        guard activeProfileID != id else { return }
        activeProfileID = id
        invalidateScope()
    }
    func usesGlobalSettings(for id: UUID) -> Bool { !document.localProfileIDs.contains(id) }
    func setUsesGlobalSettings(_ global: Bool, for id: UUID) {
        guard global != usesGlobalSettings(for: id) else { return }
        if global { document.localProfileIDs.remove(id) }
        else {
            if document.profileSettings[id] == nil { document.profileSettings[id] = document.settings }
            document.localProfileIDs.insert(id)
        }
        documentRevision &+= 1
        if activeProfileID == id { invalidateScope() }
    }
    private func invalidateScope() {
        processingRevision &+= 1
        scopeRevision = processingRevision
    }
    func update(for id: String, scope: PerAppSettingsScope = .active, invalidatesProcessing: Bool,
                change: (inout PerAppAudioSettings) -> Void) {
        var value = settings(for: id, scope: scope)
        change(&value)
        if case .local(let profileID) = resolvedScope(scope) { document.profileSettings[profileID, default: [:]][id] = value }
        else { document.settings[id] = value }
        documentRevision &+= 1
        // Inactive-profile edits must not reset the active app's DSP history.
        // Selecting that profile later invalidates every stream via scopeRevision.
        if invalidatesProcessing, resolvedScope(scope) == resolvedScope(.active) {
            processingRevision &+= 1
            revisions[id] = processingRevision
        }
    }

    /// Preserve temporary app edits in every scope when identity resolves.
    func migrate(from temporaryID: String, to stableID: String) -> Bool {
        var changed = false
        func migrateValues(_ values: inout [String: PerAppAudioSettings]) {
            guard let temporary = values.removeValue(forKey: temporaryID) else { return }
            if values[stableID] == nil { values[stableID] = temporary }
            changed = true
        }
        migrateValues(&document.settings)
        for id in Array(document.profileSettings.keys) { migrateValues(&document.profileSettings[id]!) }
        guard changed else { return false }
        processingRevision &+= 1
        revisions[stableID] = processingRevision
        revisions.removeValue(forKey: temporaryID)
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
            error: Self.persist(snapshot.document, to: url))
    }

    private static func loadSettings(from url: URL) -> (document: PerAppAudioDocument, error: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (.init(settings: [:]), nil) }
        do {
            let document = try PerAppAudioDocument.decodeDocument(Data(contentsOf: url))
            return (persistentDocument(document), nil)
        } catch {
            return (.init(settings: [:]), "Per-application settings could not be read. The original file is preserved; changes cannot be saved until it is restored or opened by a compatible version.")
        }
    }

    private static func persistentDocument(_ document: PerAppAudioDocument) -> PerAppAudioDocument {
        var result = document
        result.settings = result.settings.filter { PerAppApplicationIdentityPolicy.isPersistentApplicationID($0.key) }
        result.profileSettings = result.profileSettings.mapValues { $0.filter { PerAppApplicationIdentityPolicy.isPersistentApplicationID($0.key) } }
        return result
    }

    private static func persist(_ document: PerAppAudioDocument, to settingsURL: URL) -> String? {
        let persistent = persistentDocument(document)
        do {
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                // Never replace newer or unreadable data, including a file changed
                // by another version while this process was running.
                let previous = try PerAppAudioDocument.decodeDocument(Data(contentsOf: settingsURL))
                if persistentDocument(previous) == persistent { return nil }
            } else if persistent == PerAppAudioDocument(settings: [:]) { return nil }
            let data = try JSONEncoder().encode(persistent)
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: settingsURL, options: .atomic)
            return nil
        } catch {
            return "Per-application settings were not saved. Check storage access and file compatibility. The previous file is preserved."
        }
    }
}
