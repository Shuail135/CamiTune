import SwiftUI
import AppKit

// Native frame anchors exist only in UI diagnostics and XCTest.
// Tests send real mouse events at these controls, without hard-coded pixels.
extension View {
    @ViewBuilder
    func uiInteractionAnchor(_ id: String) -> some View {
        #if DEBUG
        if UIInteractionAnchor.isEnabled {
            background(UIInteractionAnchor(id: id))
        } else { self }
        #else
        self
        #endif
    }
}
#if DEBUG
private struct UIInteractionAnchor: NSViewRepresentable {
    static let isEnabled = NSClassFromString("XCTestCase") != nil
    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    let id: String
    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        view.identifier = NSUserInterfaceItemIdentifier(id)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { view.identifier = NSUserInterfaceItemIdentifier(id) }
}
#endif
