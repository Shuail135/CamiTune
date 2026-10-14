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
    private weak var activeEditor: EditorHistoryCommandView?
    private var mouseMonitor: Any?
    private var refreshPending = false
    var keyWindow: () -> NSWindow? = { NSApp.keyWindow }
    var nativeTextUndoManager: () -> UndoManager? = {
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable else { return nil }
        return text.undoManager
    }
    init(history: UndoCoordinator) {
        self.history = history
        history.objectWillChange.sink { [weak self] _ in
            // Editing another section returns commands to the app's history.
            self?.activeEditor = nil
            self?.objectWillChange.send()
        }.store(in: &observations)
        for name in [NSText.didBeginEditingNotification, NSText.didEndEditingNotification,
                     NSText.didChangeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification, Notification.Name.NSUndoManagerCheckpoint] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        }
    }
    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    func register(_ editor: EditorHistoryCommandView) {
        editors.add(editor)
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = event.window, window === self.keyWindow() else { return event }
                self.activeEditor = self.editors.allObjects.first {
                    $0.isAvailable(in: window) && $0.visibleRect.contains($0.convert(event.locationInWindow, from: nil))
                }
                self.refreshCommands()
                return event
            }
        }
        refreshCommands()
    }

    func unregister(_ editor: EditorHistoryCommandView) {
        editors.remove(editor)
        if activeEditor === editor { activeEditor = nil }
        if editors.allObjects.isEmpty, let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        refreshCommands()
    }

    func editorDidChange(_ editor: EditorHistoryCommandView) {
        if editor.isAvailable(in: editor.window) { activeEditor = editor }
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
        let window = keyWindow()
        // A wizard owns its entire window, including an empty undo stack.
        if let modal = editors.allObjects.first(where: { $0.isExclusive && $0.isInWindow(window) }) { return modal }
        guard let activeEditor, activeEditor.isAvailable(in: window) else { return nil }
        return activeEditor
    }

    private func allowsAppHistory(editor: UndoManager?) -> Bool {
        editor != nil || editorContext?.isExclusive != true
    }

    private func manager(forUndo: Bool, editor: UndoManager?) -> UndoManager? {
        // Text editing keeps its native history; editor drafts precede saved app edits.
        let context = editorContext
        let local = context?.isAvailable(in: keyWindow()) == true ? context?.manager : nil
        for manager in [nativeTextUndoManager(), editor ?? local].compactMap({ $0 }) {
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
        if let manager = manager(forUndo: true, editor: editor) { manager.undo(); objectWillChange.send() }
        else if allowsAppHistory(editor: editor) { Task { await history.undo() } }
    }
    func performRedo(editor: UndoManager? = nil) {
        if let manager = manager(forUndo: false, editor: editor) { manager.redo(); objectWillChange.send() }
        else if allowsAppHistory(editor: editor) { Task { await history.redo() } }
    }
}
