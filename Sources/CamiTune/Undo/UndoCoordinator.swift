import Combine
import CamiTuneDomain
import Foundation

@MainActor
protocol HistoryRestoring: AnyObject {
    func restoreHistoryState(_ state: HistoryState, target: HistoryTarget) async throws
}

/// Session-only chronology. Entries contain values, never editor setter closures.
@MainActor
final class UndoCoordinator: ObservableObject {
    @Published private(set) var undoTitle: String?
    @Published private(set) var redoTitle: String?
    @Published private(set) var isReplaying = false
    @Published private(set) var lastError: String?
    private(set) var undoStack: [HistoryEntry] = []
    private(set) var redoStack: [HistoryEntry] = []
    private var gestures: [GestureKey: HistoryEntry] = [:]
    private var nextPosition: UInt64 = 0
    private var pendingEdits: Set<HistoryPosition> = []
    private var retainedAssets: ProfileAssetLease?
    weak var restorer: (any HistoryRestoring)?
    let capacity: Int
    var canUndo: Bool { !isReplaying && gestures.isEmpty && pendingEdits.isEmpty && !undoStack.isEmpty }
    var canRedo: Bool { !isReplaying && gestures.isEmpty && pendingEdits.isEmpty && !redoStack.isEmpty }
    var isRecordingEnabled: Bool { !isReplaying }
    init(capacity: Int = 150) { self.capacity = max(1, capacity) }

    private func position() -> HistoryPosition {
        nextPosition &+= 1
        return .init(ordinal: nextPosition)
    }

    /// Async edits reserve their user-action order before suspension. Replay
    /// waits for their explicit success, failure or cancellation.
    func beginPendingEdit() -> HistoryPosition? {
        guard isRecordingEnabled else { return nil }
        let value = position()
        pendingEdits.insert(value)
        objectWillChange.send()
        return value
    }

    func endPendingEdit(_ value: HistoryPosition?) {
        guard let value, pendingEdits.remove(value) != nil else { return }
        objectWillChange.send()
    }

    func retainAssets(in storage: ProfileAssetStorage) {
        retainedAssets = storage.retain(assetReferences)
    }
    private var assetReferences: ProfileAssetReferences {
        var references = ProfileAssetReferences()
        for entry in undoStack + redoStack + Array(gestures.values) {
            references.formUnion(entry.before.assetReferences)
            references.formUnion(entry.after.assetReferences)
        }
        return references
    }

    func record(actionName: String, contextName: String? = nil, target: HistoryTarget,
                before: HistoryState, after: HistoryState,
                coalescingKey: HistoryCoalescingKey? = nil, now: Date = Date(), position reservedPosition: HistoryPosition? = nil) {
        guard isRecordingEnabled, before != after else { return }
        let position = reservedPosition ?? position()
        var before = before, after = after
        if case .globalEQ(var previous) = before, case .globalEQ(var next) = after,
           previous.replacesDeviceCorrection != next.replacesDeviceCorrection {
            // An explicit old-style transfer owns both slices. Ordinary User EQ
            // events own only tonal controls, even if their snapshot saw correction.
            previous.ownsLegacyCorrectionTransfer = true; next.ownsLegacyCorrectionTransfer = true
            before = .globalEQ(previous); after = .globalEQ(next)
        }
        if let key = coalescingKey, var last = undoStack.last,
           redoStack.isEmpty, last.position < position, last.coalescingKey == key, last.target == target,
           !pendingEdits.contains(where: { last.position < $0 && $0 < position }),
           !gestures.values.contains(where: { last.position < $0.position && $0.position < position }),
           last.actionName == actionName, last.after == before,
           now.timeIntervalSince(last.timestamp) >= 0, now.timeIntervalSince(last.timestamp) <= 0.4 {
            last.after = after
            last.timestamp = now
            undoStack.removeLast()
            if last.before != after { undoStack.append(last) }
        } else {
            let entry = HistoryEntry(id: UUID(), position: position, actionName: actionName, contextName: contextName,
                target: target, before: before, after: after, coalescingKey: coalescingKey, timestamp: now)
            let index = undoStack.firstIndex { position < $0.position } ?? undoStack.endIndex
            undoStack.insert(entry, at: index)
        }
        redoStack.removeAll()
        if undoStack.count > capacity { undoStack.removeFirst(undoStack.count - capacity) }
        refresh()
    }
    func beginGesture(key: GestureKey, actionName: String, contextName: String? = nil,
                      target: HistoryTarget, before: HistoryState) {
        guard isRecordingEnabled, gestures[key] == nil else { return }
        gestures[key] = HistoryEntry(id: UUID(), position: position(), actionName: actionName, contextName: contextName,
            target: target, before: before, after: before, coalescingKey: nil, timestamp: Date())
        retainedAssets?.update(assetReferences)
        objectWillChange.send()
    }
    func endGesture(key: GestureKey, after: HistoryState) {
        guard let gesture = gestures.removeValue(forKey: key) else { return }
        record(actionName: gesture.actionName, contextName: gesture.contextName, target: gesture.target,
               before: gesture.before, after: after, position: gesture.position)
        retainedAssets?.update(assetReferences)
        objectWillChange.send()
    }
    func cancelGesture(key: GestureKey) {
        guard gestures.removeValue(forKey: key) != nil else { return }
        retainedAssets?.update(assetReferences)
        objectWillChange.send()
    }
    func clear() {
        guard !isReplaying, pendingEdits.isEmpty else { return }
        gestures.removeAll(); undoStack.removeAll(); redoStack.removeAll(); refresh()
    }
    func undo() async { await replay(undo: true) }
    func redo() async { await replay(undo: false) }
    private func replay(undo: Bool) async {
        guard undo ? canUndo : canRedo,
              let entry = undo ? undoStack.last : redoStack.last, let restorer else { return }
        isReplaying = true
        lastError = nil
        defer { isReplaying = false }
        do {
            try await restorer.restoreHistoryState(undo ? entry.before : entry.after, target: entry.target)
            if undo { undoStack.removeLast(); redoStack.append(entry) }
            else { redoStack.removeLast(); undoStack.append(entry) }
            refresh()
        } catch { lastError = error.localizedDescription }
    }
    private func refresh() {
        retainedAssets?.update(assetReferences)
        undoTitle = undoStack.last?.title
        redoTitle = redoStack.last?.title
    }
}

/// Compatibility boundary for the pre-concurrency, lock-protected controllers.
/// Their synchronous UI hooks run only on the main thread, including macOS 13.
@preconcurrency @MainActor
func withMainThreadHistory(_ body: @MainActor () -> Void) {
    precondition(Thread.isMainThread)
    body()
}
