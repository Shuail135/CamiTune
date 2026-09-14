import AppKit
import SwiftUI

private let applicationOrderType = NSPasteboard.PasteboardType("com.camitune.application-order")

/// Only this identity-sized view is a source. Sliders/buttons remain in their
/// ordinary SwiftUI hit regions, outside its mouse handling.
struct MenuAppDragSource: NSViewRepresentable {
    let application: PerAppAudioApplication
    let displayedName: String
    let coordinator: MenuAppReorderCoordinator
    var drawsIdentity = true
    var modifierOnlyHitTesting = false
    var requiresModifier = true

    func makeNSView(context: Context) -> SourceView { SourceView() }
    func updateNSView(_ view: SourceView, context: Context) {
        view.applicationID = application.id
        view.displayedName = displayedName
        view.icon = PerAppIconCache.icon(for: application)
        view.coordinator = coordinator
        view.drawsIdentity = drawsIdentity
        view.modifierOnlyHitTesting = modifierOnlyHitTesting
        view.requiresModifier = requiresModifier
        view.toolTip = PerAppAudioController.isPersistentApplicationID(application.id)
            ? "\(displayedName) — \(requiresModifier ? "Option-drag" : "Drag") to move" : displayedName
        view.setAccessibilityElement(drawsIdentity)
        view.setAccessibilityRole(.staticText)
        view.setAccessibilityLabel(displayedName)
        view.needsDisplay = true
    }

    final class SourceView: NSView, NSDraggingSource {
        var applicationID = ""
        var displayedName = ""
        var icon = NSImage()
        var coordinator: MenuAppReorderCoordinator?
        var drawsIdentity = true
        var modifierOnlyHitTesting = false
        var requiresModifier = true
        private var downEvent: NSEvent?
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // An overlay in App Audio captures only Option or Command presses. Ordinary name
        // clicks and field editing continue to the underlying SwiftUI view.
        func capturesMouse(modifiers: NSEvent.ModifierFlags) -> Bool {
            !modifierOnlyHitTesting || MenuAppReorderCoordinator.canBegin(
                applicationID: applicationID, modifiers: modifiers)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard capturesMouse(modifiers: NSApp?.currentEvent?.modifierFlags ?? NSEvent.modifierFlags) else { return nil }
            return super.hitTest(point)
        }

        override func draw(_ dirtyRect: NSRect) {
            if drawsIdentity { drawIdentity() }
        }

        private func drawIdentity() {
            icon.draw(in: NSRect(x: 0, y: (bounds.height - 24) / 2, width: 24, height: 24),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            (displayedName as NSString).draw(in: NSRect(x: 30, y: (bounds.height - 17) / 2,
                width: max(0, bounds.width - 30), height: 17), withAttributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.labelColor, .paragraphStyle: style
                ])
        }

        override func mouseDown(with event: NSEvent) {
            downEvent = MenuAppReorderCoordinator.canBegin(applicationID: applicationID,
                modifiers: event.modifierFlags, requiresModifier: requiresModifier) ? event : nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = downEvent, let coordinator,
                  hypot(event.locationInWindow.x - start.locationInWindow.x,
                        event.locationInWindow.y - start.locationInWindow.y) >= 4 else { return }
            downEvent = nil
            guard coordinator.beginDrag(applicationID: applicationID, modifiers: start.modifierFlags, requiresModifier: requiresModifier) else { return }
            let item = NSPasteboardItem()
            item.setString(applicationID, forType: applicationOrderType)
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            let dragImage = NSImage(size: bounds.size)
            dragImage.lockFocus()
            drawIdentity()
            dragImage.unlockFocus()
            draggingItem.setDraggingFrame(bounds, contents: dragImage)
            let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        override func mouseUp(with event: NSEvent) { downEvent = nil }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            coordinator?.endDrag()
        }
    }
}

/// The registered AppKit ancestor accepts destinations across both menu
/// windows while its hosted controls keep normal mouse hit testing.
struct MenuAppDropBridge<Content: View>: NSViewRepresentable {
    var applicationID: String? = nil
    var section: AppAudioSection? = nil
    var sectionAppend = true
    var isMoreAppsBridge = false
    var isPopover = false
    let coordinator: MenuAppReorderCoordinator
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> DestinationView<Content> {
        DestinationView(rootView: content())
    }

    func updateNSView(_ view: DestinationView<Content>, context: Context) {
        view.host.rootView = content()
        view.applicationID = applicationID
        view.section = section
        view.sectionAppend = sectionAppend
        view.isMoreAppsBridge = isMoreAppsBridge
        view.isPopover = isPopover
        view.coordinator = coordinator
    }

    final class DestinationView<Hosted: View>: NSView {
        let host: NSHostingView<Hosted>
        var applicationID: String?
        var section: AppAudioSection?
        var sectionAppend = true
        var isMoreAppsBridge = false
        var isPopover = false
        var coordinator: MenuAppReorderCoordinator?
        override var isFlipped: Bool { true }

        init(rootView: Hosted) {
            host = NSHostingView(rootView: rootView)
            super.init(frame: .zero)
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            registerForDraggedTypes([applicationOrderType])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private func accepts(_ sender: NSDraggingInfo) -> Bool {
            guard let coordinator, let source = coordinator.draggedApplicationID,
                  let items = sender.draggingPasteboard.pasteboardItems, items.count == 1,
                  items[0].string(forType: applicationOrderType) == source,
                  sender.draggingSource is MenuAppDragSource.SourceView,
                  coordinator.store.seenIDs.contains(source) else { return false }
            if let applicationID {
                return coordinator.store.seenIDs.contains(applicationID)
                    && (source != applicationID || isMoreAppsBridge)
            }
            return section != nil
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }

        private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard accepts(sender), let coordinator else { return [] }
            let location = convert(sender.draggingLocation, from: nil)
            coordinator.updateTarget(MenuAppDropTarget(applicationID: applicationID,
                after: applicationID == nil ? sectionAppend : (isMoreAppsBridge || location.y >= bounds.midY),
                section: section))
            if let event = NSApp?.currentEvent { enclosingScrollView?.autoscroll(with: event) }
            if isMoreAppsBridge { coordinator.bridgeHover(true) }
            else { coordinator.popoverHover(isPopover) }
            return .move
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            coordinator?.updateTarget(nil)
            if isMoreAppsBridge { coordinator?.bridgeHover(false) }
            if isPopover { coordinator?.popoverHover(false) }
        }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard accepts(sender) else { return false }
            _ = update(sender)
            if isMoreAppsBridge { coordinator?.bridgeHover(false) }
            return coordinator?.performDrop() ?? false
        }
    }
}
