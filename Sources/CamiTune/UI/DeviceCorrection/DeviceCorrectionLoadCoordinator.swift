import Combine
import Foundation
import CamiTuneDomain

/// Catalog decoding, filtering and search indexing are shared between editors.
/// Scrolling away cancels a view's interest, not the useful preparation work.
actor AutoEQCatalogPresentationCache {
    static let shared = AutoEQCatalogPresentationCache()
    struct Presentation: Sendable {
        let entries: [DeviceCatalogEntry]
        let index: DeviceCatalogSearch.Index
    }
    private struct Entry {
        let started: Date
        let task: Task<Presentation, Error>
    }
    private var entries: [String: Entry] = [:]

    func load(endpoint: ProfileEndpointKind) async throws -> Presentation {
        let key = endpoint.rawValue
        if let entry = entries[key], Date().timeIntervalSince(entry.started) < 300 {
            return try await entry.task.value
        }
        let task = Task.detached(priority: .utility) {
            let all = try await DeviceMeasurementCatalog.online.entries()
            let filtered = ReferenceCorrection.catalog(all, endpoint: endpoint)
            return Presentation(entries: filtered, index: DeviceCatalogSearch.Index(entries: filtered))
        }
        let started = Date()
        entries[key] = Entry(started: started, task: task)
        do {
            return try await task.value
        } catch {
            // A temporary network failure must not poison later retries.
            if entries[key]?.started == started { entries[key] = nil }
            throw error
        }
    }
}

/// Non-visual cancellation generations for async device-correction loads.
/// These deliberately are not @Published: changing a generation token should
/// not invalidate the SwiftUI editor hierarchy.
@MainActor
final class DeviceCorrectionLoadCoordinator: ObservableObject {
    private var targetPathCache: [([DeviceMeasurementReference], [CorrectionPath])] = []

    func targetPaths(for sources: [DeviceMeasurementReference]) -> [CorrectionPath] {
        if let cached = targetPathCache.first(where: { $0.0 == sources }) { return cached.1 }
        let paths = TargetCompatibilityEngine().validPaths(sources: sources)
        targetPathCache.append((sources, paths))
        if targetPathCache.count > 2 { targetPathCache.removeFirst() }
        return paths
    }

    var sourceGeneration: UInt64 = 0
    var deviceMatchGeneration: UInt64 = 0
}

struct CorrectionEditorSnapshot: Equatable {
    var generated: DeviceCorrectionProfile?
    var target: DeviceCorrectionTargetSelection
    var policy: DeviceCorrectionPolicyKind
    var settings: AutoEQSettings
    var targetChosen: Bool
}

@MainActor
final class AutoEQEditorHistory<Snapshot: Equatable>: ObservableObject {
    let manager = UndoManager()
    @Published var revision = 0
    var current: Snapshot?
    var restore: ((Snapshot) -> Void)?
    private var lastEdit = Date.distantPast

    func reset() {
        manager.removeAllActions()
        current = nil
        lastEdit = .distantPast
        revision &+= 1
    }

    func record(_ snapshot: Snapshot) {
        guard let previous = current else { current = snapshot; return }
        guard previous != snapshot else { return }
        current = snapshot
        // Pointer updates and repeated numeric edits form one transaction.
        let now = Date()
        if now.timeIntervalSince(lastEdit) > 0.4 {
            manager.registerUndo(withTarget: self) { $0.apply(previous) }
            manager.setActionName("Edit Device Correction")
        }
        lastEdit = now
        revision &+= 1
    }

    private func apply(_ snapshot: Snapshot) {
        if let inverse = current {
            manager.registerUndo(withTarget: self) { $0.apply(inverse) }
        }
        current = snapshot
        lastEdit = .distantPast
        restore?(snapshot)
        revision &+= 1
    }
}

typealias CorrectionEditorHistory = AutoEQEditorHistory<CorrectionEditorSnapshot>
