import AppKit
import SwiftUI

/// Blank backgrounds do not take keyboard focus on macOS. Observe outside
/// clicks without consuming them, so the clicked control still works normally.
struct OutsideClickObserver: NSViewRepresentable {
    var textFieldFocused: Bool? = nil
    var onOutsideClick: () -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onOutsideClick = onOutsideClick
        view.observesTextFocus = textFieldFocused != nil
        if textFieldFocused == false { view.checkTextFocusAfterEvent() }
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) {
        view.stopObserving()
    }

    final class ObserverView: NSView {
        var onOutsideClick: (() -> Void)?
        var observesTextFocus = false
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self, let window = self.window else { return event }
                if event.type == .keyDown {
                    if self.observesTextFocus { self.checkTextFocusAfterEvent() }
                    return event
                }
                let point = self.convert(event.locationInWindow, from: nil)
                if event.window !== window || !self.bounds.contains(point) {
                    // Finish after mouseDown so renaming another app or clicking
                    // a slider does not lose the original event or steal focus.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.monitor != nil else { return }
                        self.onOutsideClick?()
                    }
                }
                return event
            }
        }

        func checkTextFocusAfterEvent() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.monitor != nil, let window = self.window else { return }
                let field = (window.firstResponder as? NSTextField)
                    ?? ((window.firstResponder as? NSTextView)?.delegate as? NSTextField)
                guard let field, field.window === window else { return }
                let center = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: self)
                // A result click may clear the editor without focusing another
                // field. Preserve those buttons until their mouse-up action.
                if !self.bounds.contains(center) { self.onOutsideClick?() }
            }
        }

        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
