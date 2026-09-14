import Combine
import Foundation

struct AppPresentationObservation: Equatable, Sendable {
    var applicationID: String
    var systemDisplayName: String?
    var bundleID: String?
}

enum AppAudioSection: String, CaseIterable, Identifiable {
    case shown, hidden

    var id: Self { self }
    var title: String { self == .shown ? "Shown in Menu Bar" : "Hidden" }
}

struct AppPresentationRecord: Codable, Equatable, Sendable {
    var hasBeenSeen = false
    var isHiddenInMenuBar = false
    var userAlias: String?
    var lastKnownSystemDisplayName: String?
    var lastKnownBundleID: String?
    var equalizerPresentation: EqualizerPresentation = .bands

    init() {}

    private enum CodingKeys: String, CodingKey {
        case hasBeenSeen, isHiddenInMenuBar, userAlias, lastKnownSystemDisplayName, lastKnownBundleID, equalizerPresentation
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hasBeenSeen = (try? values.decode(Bool.self, forKey: .hasBeenSeen)) ?? false
        isHiddenInMenuBar = (try? values.decode(Bool.self, forKey: .isHiddenInMenuBar)) ?? false
        userAlias = try? values.decode(String.self, forKey: .userAlias)
        lastKnownSystemDisplayName = try? values.decode(String.self, forKey: .lastKnownSystemDisplayName)
        lastKnownBundleID = try? values.decode(String.self, forKey: .lastKnownBundleID)
        equalizerPresentation = (try? values.decode(EqualizerPresentation.self, forKey: .equalizerPresentation)) ?? .bands
    }
}

struct AppPresentationDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var schemaVersion = currentVersion
    var orderedApplicationIDs: [String] = []
    var records: [String: AppPresentationRecord] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey { case schemaVersion, orderedApplicationIDs, records }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        orderedApplicationIDs = (try? values.decode([String].self, forKey: .orderedApplicationIDs)) ?? []
        records = (try? values.decode([String: AppPresentationRecord].self, forKey: .records)) ?? [:]
    }

    mutating func sanitize() {
        records = records.filter { PerAppAudioController.isPersistentApplicationID($0.key) }
        for id in records.keys {
            let alias = Self.normalizedAlias(records[id]?.userAlias)
            records[id]?.userAlias = alias
        }
        var included: Set<String> = []
        orderedApplicationIDs = orderedApplicationIDs.filter {
            records[$0]?.hasBeenSeen == true && included.insert($0).inserted
        }
        // Malformed/missing order has a deterministic recovery policy.
        orderedApplicationIDs += records.keys.filter {
            records[$0]?.hasBeenSeen == true && !included.contains($0)
        }.sorted()
    }

    static func normalizedAlias(_ alias: String?) -> String? {
        guard let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(96))
    }

    func displayName(for id: String, systemName: String? = nil) -> String {
        records[id]?.userAlias
            ?? AppPresentationDocument.normalizedAlias(systemName)
            ?? records[id]?.lastKnownSystemDisplayName
            ?? id
    }

    func section(for id: String) -> AppAudioSection {
        records[id]?.isHiddenInMenuBar == true ? .hidden : .shown
    }

    func orderedApplications(_ applications: [PerAppAudioApplication], in section: AppAudioSection? = nil) -> [PerAppAudioApplication] {
        let applications = applications.filter { section == nil || self.section(for: $0.id) == section }
        let indices = Dictionary(uniqueKeysWithValues: orderedApplicationIDs.enumerated().map { ($1, $0) })
        // Unknown and ephemeral rows retain the controller's deterministic order.
        return applications.enumerated().sorted {
            let lhs = indices[$0.element.id] ?? -1
            let rhs = indices[$1.element.id] ?? -1
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }
}

/// Presentation owns no DSP state and never calls back into controller locks.
/// Mutations serialize under a short lock; UI publication is on main and JSON
/// encoding/atomic writes run exclusively on the utility queue.
final class AppPresentationStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var snapshot: AppPresentationDocument
    @Published private(set) var persistenceError: String?
    private let lock = NSLock()
    private var document: AppPresentationDocument
    private let url: URL
    private let canWrite: Bool
    private let persistenceQueue = DispatchQueue(label: "CamiTune.AppPresentation", qos: .utility)
    private var pendingWrite: DispatchWorkItem?

    init(url: URL = CamiTunePaths.perAppPresentationURL, legacyHistoryURL: URL? = nil) {
        self.url = url
        var loaded = AppPresentationDocument()
        var writable = true
        var errorMessage: String?
        var migrated = false
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                struct Version: Decodable { var schemaVersion: Int }
                let version = try JSONDecoder().decode(Version.self, from: data).schemaVersion
                guard version == AppPresentationDocument.currentVersion else {
                    throw CocoaError(.coderReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "Unsupported app presentation schema \(version)."])
                }
                loaded = try JSONDecoder().decode(AppPresentationDocument.self, from: data)
                loaded.sanitize()
            } catch {
                writable = false
                errorMessage = "App display preferences could not be loaded. Existing storage is protected: \(error.localizedDescription)"
            }
        } else if let legacyHistoryURL,
                  let data = try? Data(contentsOf: legacyHistoryURL),
                  let ids = try? JSONDecoder().decode([String].self, from: data) {
            // Legacy history contains no manual order. Stable-ID order is the
            // one-time migration default; leave the original file as backup.
            for id in ids where PerAppAudioController.isPersistentApplicationID(id) {
                var record = AppPresentationRecord()
                record.hasBeenSeen = true
                loaded.records[id] = record
            }
            loaded.sanitize()
            migrated = true
        }
        document = loaded
        snapshot = loaded
        canWrite = writable
        persistenceError = errorMessage
        if migrated { scheduleWrite(loaded) }
    }

    var currentDocument: AppPresentationDocument {
        lock.lock(); defer { lock.unlock() }
        return document
    }

    @MainActor weak var history: UndoCoordinator?
    func placementHistoryState() -> AppPlacementHistoryState {
        let current = currentDocument
        return AppPlacementHistoryState(orderedApplicationIDs: current.orderedApplicationIDs,
            hiddenByApplicationID: current.records.mapValues(\.isHiddenInMenuBar))
    }
    func restorePlacementHistoryState(_ state: AppPlacementHistoryState) {
        mutate { document in
            let existing = Set(document.orderedApplicationIDs)
            document.orderedApplicationIDs = state.orderedApplicationIDs.filter { existing.contains($0) }
                + document.orderedApplicationIDs.filter { !state.orderedApplicationIDs.contains($0) }
            for (id, hidden) in state.hiddenByApplicationID where document.records[id] != nil {
                document.records[id]?.isHiddenInMenuBar = hidden
            }
        }
    }
    private func recordPlacement(_ before: AppPlacementHistoryState) {
        guard Thread.isMainThread else { return }
        withMainThreadHistory {
            history?.record(actionName: "Arrange Applications", target: .applicationPresentationDocument,
                before: .appPlacement(before), after: .appPlacement(placementHistoryState()))
        }
    }

    var seenIDs: Set<String> { Set(currentDocument.orderedApplicationIDs) }

    func observeAudioProvenApplication(_ observation: AppPresentationObservation) {
        let id = observation.applicationID
        guard PerAppAudioController.isPersistentApplicationID(id) else { return }
        mutate { document in
            var record = document.records[id] ?? AppPresentationRecord()
            if !record.hasBeenSeen {
                record.hasBeenSeen = true
                document.orderedApplicationIDs.insert(id, at: 0)
            }
            if let name = observation.systemDisplayName, !name.isEmpty { record.lastKnownSystemDisplayName = name }
            if let bundleID = observation.bundleID { record.lastKnownBundleID = bundleID }
            document.records[id] = record
        }
    }

    func displayName(for app: PerAppAudioApplication) -> String {
        snapshot.displayName(for: app.id, systemName: app.displayName)
    }

    func orderedApplications(_ applications: [PerAppAudioApplication], in section: AppAudioSection? = nil) -> [PerAppAudioApplication] {
        snapshot.orderedApplications(applications, in: section)
    }

    /// Visibility and order publish together, without touching application audio settings.
    @discardableResult
    func moveApplication(_ id: String, to section: AppAudioSection, relativeTo target: String? = nil, after: Bool = true) -> Bool {
        let before = placementHistoryState()
        defer { recordPlacement(before) }
        return mutate { document in
            guard document.records[id]?.hasBeenSeen == true else { return }
            if let target {
                guard target != id, document.orderedApplicationIDs.contains(target),
                      document.section(for: target) == section else { return }
            }
            document.orderedApplicationIDs.removeAll { $0 == id }
            document.records[id]?.isHiddenInMenuBar = section == .hidden
            let index: Int
            if let target, let targetIndex = document.orderedApplicationIDs.firstIndex(of: target) {
                index = targetIndex + (after ? 1 : 0)
            } else if after {
                index = document.orderedApplicationIDs.lastIndex { document.section(for: $0) == section }
                    .map { $0 + 1 } ?? document.orderedApplicationIDs.endIndex
            } else {
                index = document.orderedApplicationIDs.firstIndex { document.section(for: $0) == section }
                    ?? document.orderedApplicationIDs.endIndex
            }
            document.orderedApplicationIDs.insert(id, at: index)
        }
    }

    func setAlias(_ alias: String?, for id: String) {
        let before = currentDocument.records[id]?.userAlias
        let context = currentDocument.displayName(for: id)
        defer {
            if Thread.isMainThread {
                withMainThreadHistory {
                    history?.record(actionName: "Rename Application", contextName: context, target: .applicationPresentation(id),
                        before: .appAlias(before), after: .appAlias(currentDocument.records[id]?.userAlias))
                }
            }
        }

        mutate { document in
            guard document.records[id]?.hasBeenSeen == true else { return }
            document.records[id]?.userAlias = AppPresentationDocument.normalizedAlias(alias)
        }
    }

    func setEqualizerPresentation(_ presentation: EqualizerPresentation, for id: String) {
        mutate { document in
            guard document.records[id]?.hasBeenSeen == true else { return }
            document.records[id]?.equalizerPresentation = presentation
        }
    }

    func moveUp(_ id: String) { moveAdjacent(id, offset: -1) }
    func moveDown(_ id: String) { moveAdjacent(id, offset: 1) }

    private func moveAdjacent(_ id: String, offset: Int) {
        let before = placementHistoryState()
        defer { recordPlacement(before) }
        mutate { document in
            let peers = document.orderedApplicationIDs.filter { document.section(for: $0) == document.section(for: id) }
            guard let peerIndex = peers.firstIndex(of: id), peers.indices.contains(peerIndex + offset),
                  let index = document.orderedApplicationIDs.firstIndex(of: id),
                  let neighborIndex = document.orderedApplicationIDs.firstIndex(of: peers[peerIndex + offset]) else { return }
            document.orderedApplicationIDs.swapAt(index, neighborIndex)
        }
    }

    @discardableResult
    func moveApplication(_ id: String, relativeTo target: String, after: Bool) -> Bool {
        let before = placementHistoryState()
        defer { recordPlacement(before) }
        return mutate { document in
            guard id != target, document.orderedApplicationIDs.contains(id),
                  document.orderedApplicationIDs.contains(target) else { return }
            document.orderedApplicationIDs.removeAll { $0 == id }
            guard let index = document.orderedApplicationIDs.firstIndex(of: target) else { return }
            document.orderedApplicationIDs.insert(id, at: index + (after ? 1 : 0))
        }
    }

    func resetOrder(systemNames: [String: String] = [:]) {
        let before = placementHistoryState()
        defer { recordPlacement(before) }
        mutate { document in
            let names = document
            document.orderedApplicationIDs.sort {
                let comparison = names.displayName(for: $0, systemName: systemNames[$0])
                    .localizedStandardCompare(names.displayName(for: $1, systemName: systemNames[$1]))
                return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
            }
        }
    }

    @discardableResult
    private func mutate(_ mutation: (inout AppPresentationDocument) -> Void) -> Bool {
        lock.lock()
        let old = document
        mutation(&document)
        guard document != old else { lock.unlock(); return false }
        UIRenderPerformance.recordAppPresentationMutation()
        scheduleWrite(document)
        lock.unlock()
        if Thread.isMainThread { publishLatest() }
        else { DispatchQueue.main.async { [weak self] in self?.publishLatest() } }
        return true
    }

    private func publishLatest() {
        let latest = currentDocument
        if snapshot != latest { snapshot = latest }
    }

    // Called while locked (or during init) to preserve write ordering.
    private func scheduleWrite(_ snapshot: AppPresentationDocument) {
        guard canWrite else { return }
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write(snapshot) }
        pendingWrite = work
        persistenceQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func write(_ snapshot: AppPresentationDocument) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            DispatchQueue.main.async { [weak self] in self?.persistenceError = nil }
        } catch {
            let message = "App display preferences could not be saved: \(error.localizedDescription)"
            DispatchQueue.main.async { [weak self] in self?.persistenceError = message }
        }
    }

    func persistHistoryChanges() throws {
        lock.lock()
        pendingWrite?.cancel()
        let current = document
        lock.unlock()
        guard canWrite else { throw ProfileSettingsError.runtime(persistenceError ?? "App display storage is protected.") }
        try persistenceQueue.sync {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(current)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    func flushPendingSaveSynchronously() {
        lock.lock()
        pendingWrite?.cancel()
        let latest = document
        lock.unlock()
        guard canWrite else { return }
        persistenceQueue.sync { write(latest) }
    }
}
