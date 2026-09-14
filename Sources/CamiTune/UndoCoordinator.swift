import Combine
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
    weak var restorer: (any HistoryRestoring)?
    let capacity: Int
    var canUndo: Bool { !isReplaying && gestures.isEmpty && !undoStack.isEmpty }
    var canRedo: Bool { !isReplaying && gestures.isEmpty && !redoStack.isEmpty }
    var isRecordingEnabled: Bool { !isReplaying }
    init(capacity: Int = 150) { self.capacity = max(1, capacity) }

    func record(actionName: String, contextName: String? = nil, target: HistoryTarget,
                before: HistoryState, after: HistoryState,
                coalescingKey: HistoryCoalescingKey? = nil, now: Date = Date()) {
        guard isRecordingEnabled, before != after else { return }
        if let key = coalescingKey, var last = undoStack.last,
           redoStack.isEmpty, last.coalescingKey == key, last.target == target,
           last.actionName == actionName, last.after == before,
           now.timeIntervalSince(last.timestamp) >= 0, now.timeIntervalSince(last.timestamp) <= 0.4 {
            last.after = after
            last.timestamp = now
            undoStack.removeLast()
            if last.before != after { undoStack.append(last) }
        } else {
            undoStack.append(HistoryEntry(id: UUID(), actionName: actionName, contextName: contextName,
                target: target, before: before, after: after, coalescingKey: coalescingKey, timestamp: now))
        }
        redoStack.removeAll()
        if undoStack.count > capacity { undoStack.removeFirst(undoStack.count - capacity) }
        refresh()
    }
    func beginGesture(key: GestureKey, actionName: String, contextName: String? = nil,
                      target: HistoryTarget, before: HistoryState) {
        guard isRecordingEnabled, gestures[key] == nil else { return }
        gestures[key] = HistoryEntry(id: UUID(), actionName: actionName, contextName: contextName,
            target: target, before: before, after: before, coalescingKey: nil, timestamp: Date())
        objectWillChange.send()
    }
    func endGesture(key: GestureKey, after: HistoryState) {
        guard let gesture = gestures.removeValue(forKey: key) else { return }
        record(actionName: gesture.actionName, contextName: gesture.contextName, target: gesture.target,
               before: gesture.before, after: after)
        objectWillChange.send()
    }
    func cancelGesture(key: GestureKey) { gestures.removeValue(forKey: key); objectWillChange.send() }
    func clear() {
        guard !isReplaying else { return }
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
