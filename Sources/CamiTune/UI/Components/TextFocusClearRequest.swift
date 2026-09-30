import AppKit

/// A window reuses the same NSTextView for several fields. Compare its delegate
/// as well as the responder, so a delayed background click can't blur a new field.
@MainActor
final class TextFocusClearRequest {
    private weak var window: NSWindow?
    private weak var editor: NSTextView?
    private weak var delegate: AnyObject?

    init?(window: NSWindow) {
        guard let editor = window.firstResponder as? NSTextView,
              editor.isFieldEditor, let delegate = editor.delegate else { return nil }
        self.window = window
        self.editor = editor
        self.delegate = delegate
    }

    func perform() {
        guard let window, let editor, let delegate,
              window.firstResponder === editor,
              (editor.delegate as AnyObject?) === delegate else { return }
        window.makeFirstResponder(nil)
    }

    /// End editing while bindings still address the departing selection. Give
    /// SwiftUI's focus-change callbacks one run-loop turn to commit their drafts.
    static func commitBeforeChangingSelection(_ action: @escaping @MainActor () -> Void) {
        guard let window = NSApp.keyWindow,
              let request = TextFocusClearRequest(window: window) else {
            action()
            return
        }
        request.perform()
        DispatchQueue.main.async(execute: action)
    }
}
