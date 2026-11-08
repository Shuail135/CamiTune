import AppKit
import SwiftUI

struct AppAlertAction {
    enum Role { case cancel, destructive }
    let title: String
    var role: Role?
    let action: () -> Void
    var isDefault = false
    init(_ title: String, role: Role? = nil, action: @escaping () -> Void) {
        self.title = title; self.role = role; self.action = action
    }
    func defaultAction() -> Self { var copy = self; copy.isDefault = true; return copy }
}

@resultBuilder
struct AppAlertActions {
    static func buildExpression(_ action: AppAlertAction) -> [AppAlertAction] { [action] }
    static func buildBlock(_ groups: [AppAlertAction]...) -> [AppAlertAction] { groups.flatMap { $0 } }
    static func buildOptional(_ actions: [AppAlertAction]?) -> [AppAlertAction] { actions ?? [] }
    static func buildEither(first: [AppAlertAction]) -> [AppAlertAction] { first }
    static func buildEither(second: [AppAlertAction]) -> [AppAlertAction] { second }
}

extension View {
    func appAlert(_ title: String, isPresented: Binding<Bool>,
                  @AppAlertActions actions: () -> [AppAlertAction], message: () -> String = { "" }) -> some View {
        background(AppAlertPresentation(title: title, message: message(), isPresented: isPresented, actions: actions()))
    }
    func appAlert<Value>(_ title: String, isPresented: Binding<Bool>, presenting value: Value?,
                         @AppAlertActions actions: (Value) -> [AppAlertAction], message: (Value) -> String) -> some View {
        background(AppAlertPresentation(title: title, message: value.map(message) ?? "", isPresented: isPresented,
                                        actions: value.map(actions) ?? []))
    }
}

/// A sheet snapshots the requested action list. Dismissal retires that snapshot
/// before a callback can present another sheet or change the edited profile.
private struct AppAlertPresentation: NSViewRepresentable {
    let title: String
    let message: String
    @Binding var isPresented: Bool
    let actions: [AppAlertAction]

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.attached = { [weak coordinator = context.coordinator] window in coordinator?.updateWindow(window) }
        return view
    }
    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.request = self
        context.coordinator.updateWindow(view.window)
    }
    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) { coordinator.retire() }

    final class AnchorView: NSView {
        var attached: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attached?(window) }
    }
    final class Coordinator {
        var request: AppAlertPresentation?
        private var alert: NSAlert?
        private var waitingForSheet: NSObjectProtocol?

        func updateWindow(_ window: NSWindow?) {
            guard let request, request.isPresented else { retire(); return }
            guard alert == nil, let window else { return }
            if window.attachedSheet != nil {
                if waitingForSheet == nil {
                    waitingForSheet = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification,
                        object: window, queue: .main) { [weak self, weak window] _ in self?.updateWindow(window) }
                }
                return
            }
            if let waitingForSheet { NotificationCenter.default.removeObserver(waitingForSheet); self.waitingForSheet = nil }
            let actions = request.actions.filter { $0.role != .cancel } + request.actions.filter { $0.role == .cancel }
            guard !actions.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = request.title
            alert.informativeText = request.message
            let defaultIndex = actions.firstIndex { $0.isDefault } ?? 0
            for (index, action) in actions.enumerated() {
                let button = alert.addButton(withTitle: action.title)
                button.hasDestructiveAction = action.role == .destructive
                button.keyEquivalent = action.role == .cancel ? "\u{1b}" : (index == defaultIndex ? "\r" : "")
            }
            self.alert = alert
            alert.beginSheetModal(for: window) { [weak self, weak alert] response in
                guard let self, let alert, self.alert === alert else { return }
                self.alert = nil
                request.isPresented = false
                let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                if actions.indices.contains(index) { actions[index].action() }
            }
        }
        func retire() {
            if let waitingForSheet { NotificationCenter.default.removeObserver(waitingForSheet); self.waitingForSheet = nil }
            if let alert {
                self.alert = nil
                alert.window.sheetParent?.endSheet(alert.window, returnCode: .abort)
                alert.window.orderOut(nil)
            }
        }
        deinit { retire() }
    }
}
