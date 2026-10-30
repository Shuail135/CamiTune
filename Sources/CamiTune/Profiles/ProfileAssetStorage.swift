import CamiTuneDomain
import Foundation

/// Profile documents, history, editors and runtime owners retain the same files.
/// Collection is event driven and only runs after readable profile storage has
/// established its durable references. No audio callback enters this owner.
final class ProfileAssetStorage: @unchecked Sendable {
    static let shared = ProfileAssetStorage(directory: CamiTunePaths.supportDirectory)
    let directory: URL
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "CamiTune.ProfileAssets", qos: .utility)
    private struct Snapshot {
        let revision: UInt64
        let references: ProfileAssetReferences
    }
    private var retained: [UUID: ProfileAssetReferences] = [:]
    // The document outlives its repository. Nil means storage has not been read
    // successfully, so no file can be proven unreachable yet.
    private var persistedReferences: ProfileAssetReferences?
    private var revision: UInt64 = 0
    private var accesses = 0
    private var scheduled = false

    init(directory: URL) { self.directory = directory }

    func retain(_ references: ProfileAssetReferences = .init()) -> ProfileAssetLease {
        let id = UUID()
        lock.lock()
        let previous = combinedReferences()
        retained[id] = references
        referencesChanged(from: previous)
        lock.unlock()
        return ProfileAssetLease(storage: self, id: id)
    }
    fileprivate func update(_ id: UUID, references: ProfileAssetReferences) {
        lock.lock(); defer { lock.unlock() }
        guard retained[id] != references else { return }
        let previous = combinedReferences()
        retained[id] = references
        referencesChanged(from: previous)
    }
    fileprivate func release(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        let previous = combinedReferences()
        retained.removeValue(forKey: id)
        referencesChanged(from: previous)
    }
    /// Covers acquisition through publication, including a worker that finishes
    /// after cancellation. Ending access schedules removal of abandoned results.
    func beginAccess() -> ProfileAssetAccess {
        lock.lock(); accesses += 1; revision &+= 1; lock.unlock()
        return ProfileAssetAccess(storage: self)
    }
    fileprivate func endAccess() {
        lock.lock(); accesses -= 1; changed(); lock.unlock()
    }
    func setPersistedReferences(_ references: ProfileAssetReferences?) {
        lock.lock(); defer { lock.unlock() }
        guard persistedReferences != references else { return }
        persistedReferences = references
        changed()
    }
    private func changed() {
        revision &+= 1
        schedule()
    }
    private func referencesChanged(from previous: ProfileAssetReferences) {
        // Replacing a runtime intent with the same files must not scan storage
        // on every EQ edit.
        if previous != combinedReferences() { changed() }
    }
    private func combinedReferences(persistedOnly: Bool = false) -> ProfileAssetReferences {
        var references = persistedReferences ?? .init()
        if !persistedOnly {
            for value in retained.values { references.formUnion(value) }
        }
        return references
    }
    private func schedule() {
        guard persistedReferences != nil, !scheduled, accesses == 0 else { return }
        scheduled = true
        // Finish the current UI mutation and its history record before taking
        // the snapshot. Changes during filesystem work invalidate that sweep.
        DispatchQueue.main.async { [self] in
            guard let snapshot = snapshot() else {
                lock.lock(); scheduled = false; schedule(); lock.unlock()
                return
            }
            worker.async { [self] in
                do { _ = try collect(snapshot) }
                catch { NSLog("Profile asset cleanup failed: %@", error.localizedDescription) }
                lock.lock()
                scheduled = false
                if revision != snapshot.revision { schedule() }
                lock.unlock()
            }
        }
    }
    private func snapshot(persistedOnly: Bool = false) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard persistedReferences != nil, accesses == 0 else { return nil }
        return .init(revision: revision, references: combinedReferences(persistedOnly: persistedOnly))
    }
    /// Termination and local verification only. Runtime teardown and the final
    /// profile write precede termination collection; session history then expires.
    @discardableResult
    func collectSynchronously(persistedOnly: Bool = false) throws -> Int {
        try worker.sync {
            guard let snapshot = snapshot(persistedOnly: persistedOnly) else { return 0 }
            return try collect(snapshot)
        }
    }

    private let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    private func children(_ directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let values = try directory.resourceValues(forKeys: keys)
        guard values.isDirectory == true, values.isSymbolicLink != true else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
    }
    private func isRegularFile(_ file: URL) throws -> Bool {
        let values = try file.resourceValues(forKeys: keys)
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
    private func isRecording(_ file: URL) -> Bool {
        !file.pathExtension.isEmpty && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil
    }
    private func remove(_ url: URL, snapshot: Snapshot) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard revision == snapshot.revision, accesses == 0 else { return false }
        try FileManager.default.removeItem(at: url)
        return true
    }
    private func collect(_ snapshot: Snapshot) throws -> Int {
        // Never follow a redirected support root or managed subdirectory.
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        guard try directory.resourceValues(forKeys: keys).isSymbolicLink != true else { return 0 }
        var removed = 0
        var references = snapshot.references
        var canCollectImpulseResponses = true
        let rooms = directory.appendingPathComponent("RoomMeasurements")
        for folder in try children(rooms) {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            let files = try children(folder)
            let referenced = snapshot.references.roomSessions.contains(id)
            var recordings = snapshot.references.roomRecordings[id] ?? []
            if referenced {
                let manifest = folder.appendingPathComponent("session.plist")
                guard (try? isRegularFile(manifest)) == true,
                      let session = try? RoomMeasurementStore(directory: rooms).load(id) else {
                    // An unreadable live manifest may still own baseline FIRs.
                    canCollectImpulseResponses = false
                    continue
                }
                references.include(session)
                recordings.formUnion(session.recordings.map(\.fileName))
            }
            for file in files {
                guard (isRecording(file) && !recordings.contains(file.lastPathComponent))
                        || (!referenced && file.lastPathComponent == "session.plist"),
                      try isRegularFile(file) else { continue }
                guard try remove(file, snapshot: snapshot) else { return removed }
                removed += 1
            }
            let attributes = try folder.resourceValues(forKeys: keys)
            if !referenced, attributes.isDirectory == true, attributes.isSymbolicLink != true,
               try children(folder).isEmpty {
                guard try remove(folder, snapshot: snapshot) else { return removed }
            }
        }
        if canCollectImpulseResponses {
            for file in try children(directory.appendingPathComponent("ImpulseResponses")) {
                guard file.pathExtension == "wav", isRecording(file),
                      !references.impulseResponses.contains(file.lastPathComponent),
                      try isRegularFile(file) else { continue }
                guard try remove(file, snapshot: snapshot) else { return removed }
                removed += 1
            }
        }
        for file in try children(directory.appendingPathComponent("AutoEQDrafts")) {
            let name = file.lastPathComponent
            guard name.count > 37, let id = UUID(uuidString: String(name.prefix(36))),
                  name.dropFirst(36).first == "-", !snapshot.references.profileIDs.contains(id),
                  isAutoEQDraftName(String(name.dropFirst(37))), try isRegularFile(file) else { continue }
            guard try remove(file, snapshot: snapshot) else { return removed }
            removed += 1
        }
        return removed
    }
    private func isAutoEQDraftName(_ suffix: String) -> Bool {
        for endpoint in ProfileEndpointKind.allCases {
            let name = endpoint.rawValue + ".json"
            if suffix == name { return true }
            let prefix = name + ".recovery-"
            if suffix.hasPrefix(prefix), suffix.hasSuffix(".backup"),
               UUID(uuidString: String(suffix.dropFirst(prefix.count).dropLast(7))) != nil { return true }
        }
        return false
    }
}

final class ProfileAssetLease: @unchecked Sendable {
    private let storage: ProfileAssetStorage
    private let id: UUID
    fileprivate init(storage: ProfileAssetStorage, id: UUID) { self.storage = storage; self.id = id }
    func update(_ references: ProfileAssetReferences) { storage.update(id, references: references) }
    deinit { storage.release(id) }
}

final class ProfileAssetAccess: Sendable {
    private let storage: ProfileAssetStorage
    fileprivate init(storage: ProfileAssetStorage) { self.storage = storage }
    deinit { storage.endAccess() }
}
