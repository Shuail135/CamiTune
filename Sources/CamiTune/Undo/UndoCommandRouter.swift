import AppKit
import Combine
import SwiftUI

private struct UndoCommandRouterKey: EnvironmentKey {
    static let defaultValue: UndoCommandRouter? = nil
}

extension EnvironmentValues {
    var undoCommandRouter: UndoCommandRouter? {
        get { self[UndoCommandRouterKey.self] }
        set { self[UndoCommandRouterKey.self] = newValue }
    }
}

@MainActor
final class UndoCommandRouter: ObservableObject {
    let history: UndoCoordinator
    private var observations: [AnyCancellable] = []
    private let editors = NSHashTable<EditorHistoryCommandView>.weakObjects()
    private var refreshPending = false
    private var usesNativeTextHistory = true
    var keyWindow: () -> NSWindow? = { NSApp.keyWindow }
    var nativeTextUndoManager: () -> UndoManager? = {
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable else { return nil }
        return text.undoManager
    } { didSet { usesNativeTextHistory = true } }
    init(history: UndoCoordinator) {
        self.history = history
        history.objectWillChange.sink { [weak self] _ in
            self?.usesNativeTextHistory = false
            self?.objectWillChange.send()
        }.store(in: &observations)
        for name in [NSText.didBeginEditingNotification, NSText.didEndEditingNotification,
                     NSText.didChangeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification, Notification.Name.NSUndoManagerDidCloseUndoGroup,
                     Notification.Name.NSUndoManagerDidUndoChange, Notification.Name.NSUndoManagerDidRedoChange] {
            // canRedo itself posts a checkpoint. Observing checkpoints would
            // make menu validation invalidate and rebuild the same menu forever.
            // AppKit posts these on the main thread. Preserve their order
            // before a bound control publishes its application history entry.
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] notification in
                    guard let self else { return }
                    if !self.history.isReplaying, notification.name == NSText.didChangeNotification {
                        self.usesNativeTextHistory = true
                    }
                    self.objectWillChange.send()
                }.store(in: &observations)
        }
    }
    func register(_ editor: EditorHistoryCommandView) {
        editors.add(editor)
        refreshCommands()
    }

    func unregister(_ editor: EditorHistoryCommandView) {
        editors.remove(editor)
        refreshCommands()
    }

    func refreshCommands() {
        guard !refreshPending else { return }
        refreshPending = true
        // Native registration can change during a SwiftUI view update.
        DispatchQueue.main.async { [weak self] in
            self?.refreshPending = false
            self?.objectWillChange.send()
        }
    }

    private var editorContext: EditorHistoryCommandView? {
        editors.allObjects.first { $0.isInWindow(keyWindow()) }
    }

    private func allowsAppHistory(editor: UndoManager?) -> Bool {
        editor == nil && editorContext == nil
    }

    private func manager(forUndo: Bool, editor: UndoManager?) -> UndoManager? {
        // Only an open, cancelable dialog owns a separate draft transaction.
        let context = editorContext
        let local = context?.isAvailable(in: keyWindow()) == true ? context?.manager : nil
        guard !history.isReplaying else { return nil }
        let text = usesNativeTextHistory || context != nil || editor != nil ? nativeTextUndoManager() : nil
        for manager in [text, editor ?? local].compactMap({ $0 }) {
            if forUndo ? manager.canUndo : manager.canRedo { return manager }
        }
        return nil
    }
    func canUndo(editor: UndoManager? = nil) -> Bool {
        manager(forUndo: true, editor: editor) != nil || (allowsAppHistory(editor: editor) && history.canUndo)
    }
    func canRedo(editor: UndoManager? = nil) -> Bool {
        manager(forUndo: false, editor: editor) != nil || (allowsAppHistory(editor: editor) && history.canRedo)
    }
    func undoMenuTitle(editor: UndoManager? = nil) -> String {
        if let manager = manager(forUndo: true, editor: editor) { return manager.undoMenuItemTitle }
        guard allowsAppHistory(editor: editor) else { return "Undo" }
        return history.undoTitle.map { "Undo " + $0 } ?? "Undo"
    }
    func redoMenuTitle(editor: UndoManager? = nil) -> String {
        if let manager = manager(forUndo: false, editor: editor) { return manager.redoMenuItemTitle }
        guard allowsAppHistory(editor: editor) else { return "Redo" }
        return history.redoTitle.map { "Redo " + $0 } ?? "Redo"
    }
    func performUndo(editor: UndoManager? = nil) {
        guard !history.isReplaying else { return }
        if let manager = manager(forUndo: true, editor: editor) { manager.undo(); objectWillChange.send() }
        else if allowsAppHistory(editor: editor) { Task { await history.undo() } }
    }
    func performRedo(editor: UndoManager? = nil) {
        guard !history.isReplaying else { return }
        if let manager = manager(forUndo: false, editor: editor) { manager.redo(); objectWillChange.send() }
        else if allowsAppHistory(editor: editor) { Task { await history.redo() } }
    }
}
