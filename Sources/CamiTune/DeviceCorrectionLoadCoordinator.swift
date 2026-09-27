import Combine

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

import CamiTuneDomain
import Foundation

struct CorrectionEditorSnapshot: Equatable {
    var generated: DeviceCorrectionProfile?
    var target: DeviceCorrectionTargetSelection
    var policy: DeviceCorrectionPolicyKind
    var settings: AutoEQSettings
    var targetChosen: Bool
}

@MainActor
final class CorrectionEditorHistory: ObservableObject {
    let manager = UndoManager()
    @Published var revision = 0
    var current: CorrectionEditorSnapshot?
    var restore: ((CorrectionEditorSnapshot) -> Void)?
    private var lastEdit = Date.distantPast

    func reset() {
        manager.removeAllActions()
        current = nil
        lastEdit = .distantPast
        revision &+= 1
    }

    func record(_ snapshot: CorrectionEditorSnapshot) {
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

    private func apply(_ snapshot: CorrectionEditorSnapshot) {
        if let inverse = current {
            manager.registerUndo(withTarget: self) { $0.apply(inverse) }
        }
        current = snapshot
        lastEdit = .distantPast
        restore?(snapshot)
        revision &+= 1
    }
}
