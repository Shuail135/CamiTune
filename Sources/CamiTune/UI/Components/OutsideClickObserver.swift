import AppKit
import SwiftUI

/// Blank backgrounds do not take keyboard focus on macOS. Observe outside
/// clicks without consuming them, so the clicked control still works normally.
struct OutsideClickObserver: NSViewRepresentable {
    var onOutsideClick: () -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) {
        view.stopObserving()
    }

    final class ObserverView: NSView {
        var onOutsideClick: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window else { return event }
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

        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
