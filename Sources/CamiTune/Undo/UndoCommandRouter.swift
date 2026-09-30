import AppKit
import Combine

@MainActor
final class UndoCommandRouter: ObservableObject {
    let history: UndoCoordinator
    private var observations: [AnyCancellable] = []
    var nativeTextUndoManager: () -> UndoManager? = {
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable else { return nil }
        return text.undoManager
    }
    init(history: UndoCoordinator) {
        self.history = history
        history.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        for name in [NSText.didBeginEditingNotification, NSText.didEndEditingNotification,
                     NSText.didChangeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification, Notification.Name.NSUndoManagerCheckpoint] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        }
    }
    var canUndo: Bool { nativeTextUndoManager()?.canUndo == true || history.canUndo }
    var canRedo: Bool { nativeTextUndoManager()?.canRedo == true || history.canRedo }
    var undoMenuTitle: String {
        if let manager = nativeTextUndoManager(), manager.canUndo { return manager.undoMenuItemTitle }
        return history.undoTitle.map { "Undo " + $0 } ?? "Undo"
    }
    var redoMenuTitle: String {
        if let manager = nativeTextUndoManager(), manager.canRedo { return manager.redoMenuItemTitle }
        return history.redoTitle.map { "Redo " + $0 } ?? "Redo"
    }
    func performUndo() {
        if let manager = nativeTextUndoManager(), manager.canUndo { manager.undo(); objectWillChange.send() }
        else { Task { await history.undo() } }
    }
    func performRedo() {
        if let manager = nativeTextUndoManager(), manager.canRedo { manager.redo(); objectWillChange.send() }
        else { Task { await history.redo() } }
    }
}
