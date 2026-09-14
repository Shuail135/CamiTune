import AppKit
import Combine

struct MenuAppDropTarget: Equatable {
    var applicationID: String? = nil
    var after: Bool
    var section: AppAudioSection? = nil
}

@MainActor
final class MenuAppReorderCoordinator: ObservableObject {
    let store: AppPresentationStore
    @Published private(set) var draggedApplicationID: String?
    @Published private(set) var dropTarget: MenuAppDropTarget?
    @Published var showingMoreApps = false
    @Published private(set) var hoveringBridge = false
    private var hoveringPopover = false
    private var hoverTask: Task<Void, Never>?

    init(store: AppPresentationStore) { self.store = store }

    static func canBegin(applicationID: String, modifiers: NSEvent.ModifierFlags, requiresModifier: Bool = true) -> Bool {
        (!requiresModifier || !modifiers.intersection([.option, .command]).isEmpty)
            && PerAppAudioController.isPersistentApplicationID(applicationID)
    }

    @discardableResult
    func beginDrag(applicationID: String, modifiers: NSEvent.ModifierFlags, requiresModifier: Bool = true) -> Bool {
        guard draggedApplicationID == nil, Self.canBegin(applicationID: applicationID, modifiers: modifiers, requiresModifier: requiresModifier),
              store.seenIDs.contains(applicationID) else { return false }
        hoverTask?.cancel()
        draggedApplicationID = applicationID
        return true
    }

    func updateTarget(_ target: MenuAppDropTarget?) {
        guard draggedApplicationID != nil else { return }
        dropTarget = target
    }

    @discardableResult
    func performDrop() -> Bool {
        guard let source = draggedApplicationID, let target = dropTarget,
              source != target.applicationID, store.seenIDs.contains(source) else { endDrag(); return false }
        if let section = target.section {
            if let id = target.applicationID,
               (!store.seenIDs.contains(id) || store.snapshot.section(for: id) != section) {
                endDrag()
                return false
            }
            store.moveApplication(source, to: section, relativeTo: target.applicationID, after: target.after)
        } else {
            guard let id = target.applicationID, store.seenIDs.contains(id) else { endDrag(); return false }
            store.moveApplication(source, relativeTo: id, after: target.after)
        }
        endDrag()
        return true
    }

    func bridgeHover(_ inside: Bool) {
        guard hoveringBridge != inside else { return }
        hoveringBridge = inside
        scheduleHover()
    }

    func popoverHover(_ inside: Bool) {
        guard hoveringPopover != inside else { return }
        hoveringPopover = inside
        scheduleHover()
    }

    func openMoreApps() {
        hoverTask?.cancel()
        showingMoreApps = true
    }

    private func scheduleHover() {
        hoverTask?.cancel()
        if hoveringPopover { return }
        if !hoveringBridge && draggedApplicationID != nil { return }
        let opening = hoveringBridge
        hoverTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(opening ? 180 : 300)) } catch { return }
            guard let self else { return }
            if opening { self.showingMoreApps = true }
            else if self.draggedApplicationID == nil {
                // A native mode pull-down temporarily owns pointer tracking.
                guard NSApp?.windows.contains(where: { $0.isVisible && $0.level == .popUpMenu }) != true else { return }
                self.showingMoreApps = false
            }
        }
    }

    func endDrag() {
        draggedApplicationID = nil
        dropTarget = nil
        scheduleHover()
    }

    func cancel() {
        hoverTask?.cancel()
        draggedApplicationID = nil
        dropTarget = nil
        hoveringBridge = false
        hoveringPopover = false
        showingMoreApps = false
    }
}
