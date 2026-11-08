import SwiftUI
import AppKit

/// Output and Spatial setup share the same sheet chrome and native controls.
struct SetupSheet<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 38)).foregroundColor(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.bold())
                    Text(subtitle).font(.callout).foregroundColor(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            content()
            Divider()
            HStack(spacing: 12) { actions() }
                .controlSize(.regular).padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 780, height: 760)
        .background(Color(.windowBackgroundColor))
    }
}

private struct SheetDismissalPolicy: ViewModifier {
    let blocked: Bool
    func body(content: Content) -> some View {
        content.background(SheetCloseGuard(blocked: blocked))
    }
}

private struct SheetCloseGuard: NSViewRepresentable {
    let blocked: Bool
    func makeNSView(context: Context) -> CloseGuardView { CloseGuardView() }
    func updateNSView(_ view: CloseGuardView, context: Context) { view.blocked = blocked }

    final class CloseGuardView: NSView {
        var blocked = false { didSet { if blocked != oldValue { updateMonitoring() } } }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateMonitoring()
        }
        private func updateMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard blocked, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.blocked, let window = self.window,
                      event.window === window, event.keyCode == 53 else { return event }
                // SwiftUI's sheet window handles Escape before the content's
                // responder chain and ignores windowShouldClose. Offer it to
                // explicit Cancel shortcuts, then stop automatic dismissal.
                _ = window.contentView?.performKeyEquivalent(with: event)
                return nil
            }
        }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
extension View {
    func sheetDismissalBlocked(_ blocked: Bool) -> some View {
        modifier(SheetDismissalPolicy(blocked: blocked))
    }
}
