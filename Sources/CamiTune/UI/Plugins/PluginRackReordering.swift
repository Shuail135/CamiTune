import AppKit
import Combine
import SwiftUI

/// Uses App Audio's Command-drag gesture, committing one edit only on drop.
@MainActor
final class PluginRackReorderCoordinator: ObservableObject {
    struct Target: Equatable { let id: UUID; let after: Bool }
    @Published private(set) var sourceID: UUID?
    @Published private(set) var target: Target?
    var draggingChanged: ((Bool) -> Void)?
    private var ids: [UUID] = []
    private var enabled = false
    private var commit: ((UUID, UUID, Bool) -> Void)?

    func configure(ids: [UUID], enabled: Bool, commit: @escaping (UUID, UUID, Bool) -> Void) {
        self.ids = ids; self.enabled = enabled && ids.count > 1; self.commit = commit
        if !self.enabled || sourceID.map({ !ids.contains($0) }) == true { cancel() }
    }
    func canBegin(_ id: UUID, modifiers: NSEvent.ModifierFlags) -> Bool {
        enabled && modifiers.contains(.command) && ids.contains(id)
    }
    @discardableResult
    func begin(_ id: UUID, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard sourceID == nil, canBegin(id, modifiers: modifiers) else { return false }
        sourceID = id
        draggingChanged?(true)
        return true
    }
    func accepts(_ id: UUID) -> Bool {
        enabled && sourceID != nil && sourceID != id && ids.contains(id)
    }
    func updateTarget(_ target: Target?) {
        guard sourceID != nil else { return }
        let next = target.flatMap { accepts($0.id) ? $0 : nil }
        if self.target != next { self.target = next }
    }
    @discardableResult
    func performDrop() -> Bool {
        guard let sourceID, let target, accepts(target.id),
              let sourceIndex = ids.firstIndex(of: sourceID), let commit else { cancel(); return false }
        var order = ids
        order.remove(at: sourceIndex)
        guard let targetIndex = order.firstIndex(of: target.id) else { cancel(); return false }
        order.insert(sourceID, at: targetIndex + (target.after ? 1 : 0))
        cancel()
        guard order != ids else { return false }
        commit(sourceID, target.id, target.after)
        return true
    }
    func cancel() {
        let wasDragging = sourceID != nil
        sourceID = nil; target = nil
        if wasDragging { draggingChanged?(false) }
    }
    func reset() { cancel(); commit = nil; draggingChanged = nil }
}

/// One native surface handles both ends of the drag, like App Audio. It covers
/// the whole row, passing ordinary clicks through to the existing SwiftUI controls.
/// Keep it in the same layout tree so responsive rows and hit regions stay aligned.
struct PluginRackDragSource: NSViewRepresentable {
    static let pasteboardType = NSPasteboard.PasteboardType("com.camitune.plugin-rack-order")
    let id: UUID
    let name: String
    let coordinator: PluginRackReorderCoordinator

    func makeNSView(context: Context) -> SourceView { SourceView() }
    func updateNSView(_ view: SourceView, context: Context) {
        view.slotID = id; view.name = name; view.coordinator = coordinator
        view.setAccessibilityElement(false)
    }

    final class SourceView: NSView, NSDraggingSource {
        var slotID = UUID()
        var name = ""
        var coordinator: PluginRackReorderCoordinator?
        private var downEvent: NSEvent?
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([PluginRackDragSource.pasteboardType])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func capturesMouse(modifiers: NSEvent.ModifierFlags) -> Bool {
            coordinator?.sourceID != nil || coordinator?.canBegin(slotID, modifiers: modifiers) == true
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard capturesMouse(modifiers: NSApp?.currentEvent?.modifierFlags ?? NSEvent.modifierFlags) else { return nil }
            return super.hitTest(point)
        }
        override func mouseDown(with event: NSEvent) {
            downEvent = capturesMouse(modifiers: event.modifierFlags) ? event : nil
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start = downEvent, let coordinator,
                  hypot(event.locationInWindow.x - start.locationInWindow.x,
                        event.locationInWindow.y - start.locationInWindow.y) >= 4 else { return }
            downEvent = nil
            guard coordinator.begin(slotID, modifiers: start.modifierFlags) else { return }
            let item = NSPasteboardItem()
            item.setString(slotID.uuidString, forType: PluginRackDragSource.pasteboardType)
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            let size = NSSize(width: min(360, max(120, bounds.width)), height: 24)
            let preview = NSImage(size: size)
            preview.lockFocus()
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            (name as NSString).draw(in: NSRect(x: 4, y: 3, width: size.width - 8, height: 18), withAttributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
            preview.unlockFocus()
            let location = convert(event.locationInWindow, from: nil)
            draggingItem.setDraggingFrame(NSRect(x: location.x - 12, y: location.y - 12,
                width: size.width, height: size.height), contents: preview)
            let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }
        override func mouseUp(with event: NSEvent) { downEvent = nil }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            coordinator?.cancel()
        }

        private func accepts(_ sender: NSDraggingInfo) -> Bool {
            guard let coordinator, coordinator.accepts(slotID),
                  let source = sender.draggingSource as? SourceView, source.coordinator === coordinator,
                  source.slotID == coordinator.sourceID, sender.draggingSourceOperationMask.contains(.move),
                  let items = sender.draggingPasteboard.pasteboardItems, items.count == 1 else { return false }
            return items[0].string(forType: PluginRackDragSource.pasteboardType) == source.slotID.uuidString
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
        private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard accepts(sender), let coordinator else { return [] }
            let location = convert(sender.draggingLocation, from: nil)
            coordinator.updateTarget(.init(id: slotID, after: location.y >= bounds.midY))
            if let event = NSApp?.currentEvent { enclosingScrollView?.autoscroll(with: event) }
            return .move
        }
        override func draggingExited(_ sender: NSDraggingInfo?) {
            if coordinator?.target?.id == slotID { coordinator?.updateTarget(nil) }
        }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard accepts(sender) else { return false }
            _ = update(sender)
            return coordinator?.performDrop() ?? false
        }
    }
}
