import AppKit
import SwiftUI

/// Keeps controls and drafts mounted while presentation work follows the
/// scroll viewport. Visibility changes are event driven, without a display timer.
struct VisibleRegion<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var isVisible = false

    var body: some View {
        content(isVisible)
            .background(VisibleRegionProbe(changed: { isVisible = $0 }))
    }
}

private struct VisibleRegionProbe: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> VisibleRegionView { VisibleRegionView() }
    func updateNSView(_ view: VisibleRegionView, context: Context) {
        view.changed = changed
        view.scheduleUpdate()
    }
    static func dismantleNSView(_ view: VisibleRegionView, coordinator: ()) {
        view.changed = nil
        view.stopObserving()
    }
}

final class VisibleRegionView: NSView {
    var changed: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var updateScheduled = false
    private var lastVisibility: Bool?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observeAncestors() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observeAncestors() }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); scheduleUpdate() }
    override func setFrameOrigin(_ point: NSPoint) { super.setFrameOrigin(point); scheduleUpdate() }
    override func viewDidHide() { super.viewDidHide(); scheduleUpdate() }
    override func viewDidUnhide() { super.viewDidUnhide(); scheduleUpdate() }

    private func observeAncestors() {
        stopObserving()
        guard let window else { scheduleUpdate(); return }
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ object: AnyObject) {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                self?.scheduleUpdate()
            })
        }
        observe(NSWindow.didChangeOcclusionStateNotification, window)
        var ancestor = superview
        while let view = ancestor {
            view.postsFrameChangedNotifications = true
            observe(NSView.frameDidChangeNotification, view)
            if view is NSClipView {
                view.postsBoundsChangedNotifications = true
                observe(NSView.boundsDidChangeNotification, view)
            }
            ancestor = view.superview
        }
        scheduleUpdate()
    }

    func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    func scheduleUpdate() {
        // Most resize/scroll notifications leave this region visible (or still
        // offscreen). Do not enqueue another main-loop pass for those events.
        guard changed != nil, !updateScheduled, lastVisibility != presentationIsVisible else { return }
        updateScheduled = true
        // SwiftUI owns this probe's frame. Publish after its layout transaction.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            let visible = self.presentationIsVisible
            if self.lastVisibility != visible {
                self.lastVisibility = visible
                self.changed?(visible)
            }
        }
    }

    private var presentationIsVisible: Bool {
        window?.occlusionState.contains(.visible) == true
            && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
