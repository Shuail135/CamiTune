import SwiftUI
import AppKit
import Combine

/// Lightweight presentation data: EQ edits must not reload the native table.
struct SidebarRow: Equatable {
    enum Kind: Hashable {
        case navigation(SidebarDestination), addOutput, heading, folder(UUID), profile(UUID)
    }
    let kind: Kind
    let title: String
    var folderID: UUID? = nil
    var indexInGroup = 0
    var rootIndex: Int? = nil
    var enabled = true
    var expanded = false

    var selectionID: SidebarDestination? {
        switch kind {
        case .navigation(let id): return id
        case .profile(let id): return .profile(id)
        default: return nil
        }
    }

    static func build(profiles: [DeviceProfile], folders: [ProfileFolder], expanded: Set<UUID>, rootOrder: [ProfileRootItem] = []) -> [SidebarRow] {
        var membership: [UUID: UUID] = [:]
        for folder in folders {
            for id in folder.profileIDs where membership[id] == nil { membership[id] = folder.id }
        }
        var groups: [UUID: [DeviceProfile]] = [:]
        var ungrouped: [DeviceProfile] = []
        for profile in profiles {
            if let folder = membership[profile.id] { groups[folder, default: []].append(profile) }
            else { ungrouped.append(profile) }
        }
        var rows = [
            SidebarRow(kind: .navigation(.applications), title: "App Audio"),
            SidebarRow(kind: .heading, title: "Output Profiles"),
        ]
        if profiles.isEmpty {
            rows.append(SidebarRow(kind: .addOutput, title: "Add Output"))
        }
        func appendProfiles(_ profiles: [DeviceProfile], folder: UUID?) {
            for (index, profile) in profiles.enumerated() {
                rows.append(SidebarRow(kind: .profile(profile.id), title: profile.name,
                    folderID: folder, indexInGroup: index, enabled: profile.isEnabled))
            }
        }
        for (index, item) in ProfileRootItem.normalized(rootOrder, profiles: profiles, folders: folders).enumerated() {
            switch item {
            case .profile(let id):
                guard let profile = ungrouped.first(where: { $0.id == id }) else { continue }
                rows.append(SidebarRow(kind: .profile(id), title: profile.name,
                    rootIndex: index, enabled: profile.isEnabled))
            case .folder(let id):
                guard let folder = folders.first(where: { $0.id == id }) else { continue }
                rows.append(SidebarRow(kind: .folder(id), title: folder.name,
                    rootIndex: index, expanded: expanded.contains(id)))
                if expanded.contains(id) { appendProfiles(groups[id] ?? [], folder: id) }
            }
        }
        return rows
    }

    struct DropTarget: Equatable {
        var folderID: UUID?
        var index: Int?
        var onRow: Bool
        var rootIndex: Int? = nil
    }

    static func dropTarget(rows: [SidebarRow], row: Int, onRow: Bool, draggingFolders: Bool = false) -> DropTarget? {
        // Empty space after the list always means the top-level profile group.
        if row == rows.count || row == -1 { return DropTarget(onRow: false) }
        guard rows.indices.contains(row) else { return nil }
        switch rows[row].kind {
        case .heading: return nil
        case .folder(let id):
            if onRow && draggingFolders { return nil }
            return onRow ? DropTarget(folderID: id, onRow: true) : DropTarget(onRow: false, rootIndex: rows[row].rootIndex)
        case .profile:
            if draggingFolders && rows[row].folderID != nil { return nil }
            return DropTarget(folderID: rows[row].folderID, index: rows[row].folderID == nil ? nil : rows[row].indexInGroup,
                onRow: false, rootIndex: rows[row].rootIndex)
        default: return nil
        }
    }
}

/// The table highlights selection immediately. Delay expensive detail construction
/// until tracking finishes, and coalesce navigation while the user moves a range.
@MainActor
final class SidebarSelectionScheduler<Destination> {
    private var timer: Timer?
    private var revision = 0

    func cancel() {
        revision += 1
        timer?.invalidate()
        timer = nil
    }

    func schedule(_ destination: Destination?, navigate: @escaping @MainActor (Destination) -> Void) {
        cancel()
        guard let destination else { return }
        let scheduledRevision = revision
        let timer = Timer(timeInterval: 0.075, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.revision == scheduledRevision else { return }
                self.timer = nil
                navigate(destination)
            }
        }
        self.timer = timer
        // Unlike the common modes, default mode does not run during mouse dragging.
        RunLoop.main.add(timer, forMode: .default)
    }

    deinit { timer?.invalidate() }
}

@MainActor
struct SidebarView: View {
    let state: AppState
    @ObservedObject var profileStore: ProfileStore
    @Binding var selection: SidebarDestination
    let onAddOutput: @MainActor () async -> Void

    @State private var expandedFolders: Set<UUID> = []
    @State private var inlineEditRequest: SidebarInlineEditRequest?
    @State private var folderDeletion: FolderDeletionRequest?

    var body: some View {
        VStack(spacing: 0) {
            NativeProfileSidebar(
                rows: SidebarRow.build(profiles: profileStore.profiles, folders: profileStore.folders, expanded: expandedFolders, rootOrder: profileStore.effectiveRootOrder),
                selection: selection, state: state, editRequest: inlineEditRequest,
                onRename: { target, name in
                    switch target {
                    case .folder(let id): profileStore.renameFolder(id: id, name: name)
                    case .profile(let id): Task { await state.renameProfile(id: id, to: name) }
                    default: break
                    }
                },
                onSelection: { _, destination in
                    if let destination, selection != destination { selection = destination }
                },
                onAction: handleAction,
                onDrop: { items, target in
                    if let folder = target.folderID {
                        let ids = Set(items.compactMap { item -> UUID? in
                            if case .profile(let id) = item { return id }; return nil
                        })
                        profileStore.dropProfiles(ids: ids, into: folder, at: target.index)
                        expandedFolders.insert(folder)
                    } else {
                        profileStore.dropRootItems(items, at: target.rootIndex)
                    }
                }
            )
            DeletionUndoNotice(history: state.history)
            Divider()
            Button {
                selection = .settings
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "gearshape")
                        .frame(width: 18)
                    Text("Settings")
                    Spacer()
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .background {
                    if selection == .settings {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.18))
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .accessibilityLabel("Settings")
        }
        .navigationTitle("CamiTune")
        .navigationSplitViewColumnWidth(
            min: minimumSidebarWidth,
            ideal: minimumSidebarWidth + 15,
            max: 260
        )
        .background {
            FolderDeletionAlert(request: folderDeletion) { confirmed in
                guard let request = folderDeletion else { return }
                folderDeletion = nil
                guard confirmed else { return }
                Task {
                    let deleted = await state.deleteProfileFolder(
                        id: request.id, confirmedProfileIDs: Set(request.profiles.map(\.id)))
                    if deleted {
                        expandedFolders.remove(request.id)
                        if request.profiles.contains(where: { .profile($0.id) == selection }) {
                            selection = profileStore.selectedProfileID.map(SidebarDestination.profile) ?? .empty
                        }
                    }
                }
            }
        }
    }

    private func handleAction(_ action: SidebarAction) {
        switch action {
        case .addOutput: Task { await onAddOutput() }
        case .toggleFolder(let id):
            if !expandedFolders.insert(id).inserted { expandedFolders.remove(id) }
        case .newFolder(let ids):
            let id = profileStore.groupProfiles(ids: ids, name: "New Folder")
            expandedFolders.insert(id)
            inlineEditRequest = SidebarInlineEditRequest(target: .folder(id))
        case .renameFolder(let id):
            inlineEditRequest = SidebarInlineEditRequest(target: .folder(id))
        case .removeFolder(let id):
            if let folder = profileStore.folders.first(where: { $0.id == id }) {
                folderDeletion = FolderDeletionRequest(id: id, name: folder.name,
                    profiles: profileStore.profiles(in: id))
            }
        case .renameProfile(let id):
            inlineEditRequest = SidebarInlineEditRequest(target: .profile(id))
        case .toggleProfile(let id):
            if let profile = profileStore.profiles.first(where: { $0.id == id }) {
                Task { await state.setProfileEnabled(id: id, enabled: !profile.isEnabled) }
            }
        case .deleteProfile(let id):
            Task {
                await state.deleteProfileWithHistory(id: id)
                if selection == .profile(id) {
                    selection = profileStore.selectedProfileID.map(SidebarDestination.profile) ?? .empty
                }
            }
        case .moveItem(let item, let offset): profileStore.moveSidebarItem(item, by: offset)
        case .moveToFolder(let ids, let folder): profileStore.assignProfiles(ids: ids, toFolder: folder)
        }
    }
}

private struct FolderDeletionRequest: Identifiable {
    let id: UUID
    let name: String
    let profiles: [DeviceProfile]
}

/// AppKit owns alert layout, keyboard handling and the window attachment.
@MainActor
private struct FolderDeletionAlert: NSViewRepresentable {
    let request: FolderDeletionRequest?
    let onResponse: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard let request, context.coordinator.presentedID != request.id else { return }
        context.coordinator.presentedID = request.id
        DispatchQueue.main.async {
            guard let window = view.window else {
                context.coordinator.presentedID = nil
                onResponse(false)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Delete “\(request.name)”?"
            alert.informativeText = request.profiles.isEmpty
                ? "This folder will be deleted. Use Edit → Undo to restore it."
                : "This folder and all \(request.profiles.count) profiles inside it will be deleted. Use Edit → Undo to restore it."
            let cancel = alert.addButton(withTitle: "Cancel")
            cancel.keyEquivalent = "\r"
            let delete = alert.addButton(withTitle: "Delete")
            delete.hasDestructiveAction = true
            delete.keyEquivalent = ""
            if !request.profiles.isEmpty {
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300,
                    height: min(140, request.profiles.count * 22)))
                scroll.hasVerticalScroller = true
                scroll.drawsBackground = false
                let list = NSTextField(wrappingLabelWithString: request.profiles.map(\.name).joined(separator: "\n"))
                let listHeight = list.cell?.cellSize(forBounds:
                    NSRect(x: 0, y: 0, width: 280, height: CGFloat.greatestFiniteMagnitude)).height ?? 22
                list.frame = NSRect(x: 0, y: 0, width: 280, height: max(22, listHeight))
                scroll.documentView = list
                alert.accessoryView = scroll
            }
            alert.beginSheetModal(for: window) { response in
                context.coordinator.presentedID = nil
                onResponse(response == .alertSecondButtonReturn)
            }
        }
    }
    final class Coordinator { var presentedID: UUID? }
}

private struct SidebarInlineEditRequest {
    let id = UUID()
    let target: SidebarRow.Kind
}

private enum SidebarAction {
    case addOutput, toggleFolder(UUID), newFolder(Set<UUID>), renameFolder(UUID), removeFolder(UUID)
    case renameProfile(UUID), toggleProfile(UUID), deleteProfile(UUID), moveToFolder(Set<UUID>, UUID?)
    case moveItem(ProfileRootItem, Int)
}

/// One AppKit table owns range selection and all dragging, across every group.
@MainActor
private struct NativeProfileSidebar: NSViewRepresentable {
    let rows: [SidebarRow]
    let selection: SidebarDestination
    let state: AppState
    let editRequest: SidebarInlineEditRequest?
    let onRename: @MainActor (SidebarRow.Kind, String) -> Void
    let onSelection: @MainActor (Set<UUID>, SidebarDestination?) -> Void
    let onAction: @MainActor (SidebarAction) -> Void
    let onDrop: @MainActor (Set<ProfileRootItem>, SidebarRow.DropTarget) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let table = SidebarTable()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        table.backgroundColor = .clear
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.clicked)
        table.registerForDraggedTypes([Coordinator.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.sidebarCoordinator = context.coordinator
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.observeRuntime(state)
        context.coordinator.update(self)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(self) }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        static let dragType = NSPasteboard.PasteboardType("local.camitune.profile-identities")
        var parent: NativeProfileSidebar
        weak var table: SidebarTable?
        var displayedRows: [SidebarRow] = []
        var lastSelection: SidebarDestination?
        var suppressSelection = false
        var runtimeSubscription: AnyCancellable?
        var activeProfileID: UUID?
        var menuActions: [SidebarAction] = []
        var draggedItems: Set<ProfileRootItem> = []
        var validatedDrop: SidebarRow.DropTarget?
        let selectionScheduler = SidebarSelectionScheduler<SidebarDestination>()
        var handledEditRequest: UUID?
        var editingTarget: SidebarRow.Kind?
        var editSessionID: UUID?
        var originalName = ""
        weak var editingField: NSTextField?
        var outsideClickMonitor: Any?


        init(_ parent: NativeProfileSidebar) { self.parent = parent }

        func observeRuntime(_ state: AppState) {
            runtimeSubscription = state.runtimeSnapshots.map { $0.session?.profileID }.removeDuplicates()
                .sink { [weak self] id in
                    guard let self else { return }
                    let previous = self.activeProfileID
                    self.activeProfileID = id
                    let changed = IndexSet(self.displayedRows.indices.filter {
                        if case .profile(let rowID) = self.displayedRows[$0].kind {
                            return self.editingTarget != self.displayedRows[$0].kind && (rowID == previous || rowID == id)
                        }
                        return false
                    })
                    if !changed.isEmpty { self.table?.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
                }
        }

        func selectedIDs() -> Set<UUID> {
            guard let table else { return [] }
            return Set(table.selectedRowIndexes.compactMap { index in
                guard displayedRows.indices.contains(index), case .profile(let id) = displayedRows[index].kind else { return nil }
                return id
            })
        }

        func update(_ parent: NativeProfileSidebar) {
            self.parent = parent
            guard let table else { return }
            let externalSelectionChanged = lastSelection != parent.selection
            if displayedRows != parent.rows {
                finishEditing(save: true)
                let selected = Set(table.selectedRowIndexes.compactMap { displayedRows.indices.contains($0) ? displayedRows[$0].kind : nil })
                validatedDrop = nil
                displayedRows = parent.rows
                suppressSelection = true
                table.reloadData()
                table.selectRowIndexes(IndexSet(displayedRows.indices.filter { selected.contains(displayedRows[$0].kind) }), byExtendingSelection: false)
                suppressSelection = false
            }
            if externalSelectionChanged {
                selectionScheduler.cancel()
                lastSelection = parent.selection
                if let row = displayedRows.firstIndex(where: { $0.selectionID == parent.selection }), !table.isRowSelected(row) {
                    suppressSelection = true
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    table.scrollRowToVisible(row)
                    suppressSelection = false
                } else if !displayedRows.contains(where: { $0.selectionID == parent.selection }) {
                    suppressSelection = true
                    table.deselectAll(nil)
                    suppressSelection = false
                }
            }
            if let request = parent.editRequest, handledEditRequest != request.id {
                handledEditRequest = request.id
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.parent.editRequest?.id == request.id else { return }
                    self.beginEditing(request.target)
                }
            }
        }

        func beginEditing(_ target: SidebarRow.Kind) {
            finishEditing(save: true)
            selectionScheduler.cancel()
            guard let table, let row = displayedRows.firstIndex(where: { $0.kind == target }) else { return }
            table.scrollRowToVisible(row)
            table.layoutSubtreeIfNeeded()
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell,
                  let field = cell.textField else { return }
            let sessionID = UUID()
            editSessionID = sessionID
            editingTarget = target
            originalName = displayedRows[row].title
            editingField = field
            field.isEditable = true
            field.isSelectable = true
            field.isBezeled = true
            field.drawsBackground = true
            field.delegate = self
            field.selectText(nil)
            // Native focus loss handles controls; this also commits clicks on
            // non-focusable background, without changing focus during mouseDown.
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak field] event in
                guard let self, let field else { return event }
                let point = field.convert(event.locationInWindow, from: nil)
                if event.window !== field.window || !field.bounds.contains(point) {
                    DispatchQueue.main.async { [weak self] in
                        guard self?.editSessionID == sessionID else { return }
                        self?.finishEditing(save: true)
                    }
                }
                return event
            }
        }

        func finishEditing(save: Bool) {
            guard let target = editingTarget else { return }
            let field = editingField
            let text = (field?.currentEditor()?.string ?? field?.stringValue ?? originalName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let oldName = originalName
            editingTarget = nil
            editSessionID = nil
            editingField = nil
            if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
            outsideClickMonitor = nil
            field?.delegate = nil
            field?.abortEditing()
            field?.isEditable = false
            field?.isSelectable = false
            field?.isBezeled = false
            field?.drawsBackground = false
            field?.stringValue = oldName
            if let cell = field?.superview as? SidebarCell,
               let row = displayedRows.first(where: { $0.kind == target }) {
                cell.configure(
                    row,
                    activeID: activeProfileID,
                    onAddOutput: { [weak self] in
                        guard let self else { return }
                        self.selectionScheduler.cancel()
                        self.parent.onAction(.addOutput)
                    }
                )
            }
            if save, !text.isEmpty, text != oldName {
                // A profile rename also updates its system audio-device label;
                // use the existing AppState action, never a presentation-only edit.
                let onRename = parent.onRename
                DispatchQueue.main.async { onRename(target, text) }
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) { finishEditing(save: true) }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finishEditing(save: true)
                table?.window?.makeFirstResponder(table)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finishEditing(save: false)
                table?.window?.makeFirstResponder(table)
                return true
            }
            return false
        }

        deinit {
            if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { displayedRows.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            if case .folder = displayedRows[row].kind { return true }
            return displayedRows[row].selectionID != nil
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelection, let table else { return }
            let ids = selectedIDs()
            // Range selection must not recreate the detail editor for every row crossed.
            let destination = table.selectedRowIndexes.count == 1 ? displayedRows[table.selectedRow].selectionID : nil
            selectionScheduler.schedule(destination) { [weak self] destination in
                guard let self else { return }
                self.lastSelection = destination
                self.parent.onSelection(ids, destination)
            }
        }
        @objc func clicked() {
            guard let table, displayedRows.indices.contains(table.clickedRow)
            else { return }
            switch displayedRows[table.clickedRow].kind {
            case .folder(let id):
                selectionScheduler.cancel()
                parent.onAction(.toggleFolder(id))
            case .heading, .addOutput:
                selectionScheduler.cancel()
                parent.onAction(.addOutput)
            default:
                break
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("sidebar-cell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarCell) ?? SidebarCell()
            cell.identifier = identifier
            cell.configure(
                displayedRows[row],
                activeID: activeProfileID,
                onAddOutput: { [weak self] in
                    guard let self else { return }
                    self.selectionScheduler.cancel()
                    self.parent.onAction(.addOutput)
                }
            )
            if let item = rootItem(at: row) {
                var actions = [-1, 1].map { offset in
                    NSAccessibilityCustomAction(name: offset < 0 ? "Move Up" : "Move Down", handler: { [weak self] in
                        self?.parent.state.profiles.moveSidebarItem(item, by: offset) ?? false
                    })
                }
                if case .folder(let id) = item {
                    actions.append(NSAccessibilityCustomAction(name: displayedRows[row].expanded ? "Collapse Folder" : "Expand Folder", handler: { [weak self] in
                        guard let self else { return false }
                        self.parent.onAction(.toggleFolder(id)); return true
                    }))
                }
                cell.setAccessibilityCustomActions(actions)
            } else { cell.setAccessibilityCustomActions([]) }
            return cell
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard editingTarget == nil, let identity = rootItem(at: row),
                  let data = try? JSONEncoder().encode(identity) else { return nil }
            let item = NSPasteboardItem()
            item.setData(data, forType: Self.dragType)
            return item
        }
        func rootItem(at row: Int) -> ProfileRootItem? {
            guard displayedRows.indices.contains(row) else { return nil }
            switch displayedRows[row].kind {
            case .profile(let id): return .profile(id)
            case .folder(let id): return .folder(id)
            default: return nil
            }
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            selectionScheduler.cancel()
            draggedItems = Set(rowIndexes.compactMap { rootItem(at: $0) })
            // Selecting a folder and its children moves the intact folder.
            for row in displayedRows {
                if let folder = row.folderID, draggedItems.contains(.folder(folder)),
                   case .profile(let id) = row.kind { draggedItems.remove(.profile(id)) }
            }
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            draggedItems = []
            validatedDrop = nil
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            validatedDrop = nil
            guard (info.draggingSource as? NSTableView) === tableView, !draggedItems.isEmpty,
                  let target = SidebarRow.dropTarget(rows: displayedRows, row: row, onRow: operation == .on,
                    draggingFolders: draggedItems.contains(where: { if case .folder = $0 { return true }; return false })) else { return [] }
            let indicatorRow = row == -1 ? displayedRows.count : row
            tableView.setDropRow(indicatorRow, dropOperation: target.onRow ? .on : .above)
            validatedDrop = target
            return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
            // Use the semantic target retained from validation, not AppKit's
            // possibly rewritten indicator coordinates.
            guard (info.draggingSource as? NSTableView) === tableView,
                  let target = validatedDrop, !draggedItems.isEmpty else { return false }
            parent.onDrop(draggedItems, target)
            validatedDrop = nil
            return true
        }

        func groupSelection() {
            selectionScheduler.cancel()
            let ids = selectedIDs()
            if !ids.isEmpty { parent.onAction(.newFolder(ids)) }
        }

        func menu(for row: Int) -> NSMenu {
            let menu = NSMenu()
            menuActions = []
            func add(_ title: String, _ action: SidebarAction) {
                let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
                item.target = self
                item.tag = menuActions.count
                menuActions.append(action)
                menu.addItem(item)
            }
            var ids = selectedIDs()
            if displayedRows.indices.contains(row), case .profile(let id) = displayedRows[row].kind, !ids.contains(id) { ids = [id] }
            add(ids.isEmpty ? "New Folder" : "New Folder with Selection", .newFolder(ids))
            guard displayedRows.indices.contains(row) else { return menu }
            if let item = rootItem(at: row) {
                add("Move Up", .moveItem(item, -1))
                add("Move Down", .moveItem(item, 1))
            }
            switch displayedRows[row].kind {
            case .folder(let id):
                add("Rename Folder", .renameFolder(id))
                add("Delete Folder…", .removeFolder(id))
            case .profile(let id):
                menu.addItem(.separator())
                add(displayedRows[row].enabled ? "Disable Profile" : "Enable Profile", .toggleProfile(id))
                let destinations = NSMenu()
                for folderRow in displayedRows {
                    guard case .folder(let folderID) = folderRow.kind else { continue }
                    let item = NSMenuItem(title: folderRow.title, action: #selector(menuAction(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = menuActions.count
                    menuActions.append(.moveToFolder(ids, folderID))
                    destinations.addItem(item)
                }
                if !destinations.items.isEmpty {
                    let item = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
                    item.submenu = destinations
                    menu.addItem(item)
                }
                add("Move Out of Folder", .moveToFolder(ids, nil))
                add("Rename", .renameProfile(id))
                add("Delete", .deleteProfile(id))
            default: break
            }
            return menu
        }
        func moveSelected(by offset: Int) {
            guard let table, table.selectedRowIndexes.count == 1,
                  let item = rootItem(at: table.selectedRow) else { return }
            parent.onAction(.moveItem(item, offset))
        }
        @objc func menuAction(_ sender: NSMenuItem) {
            guard menuActions.indices.contains(sender.tag) else { return }
            parent.onAction(menuActions[sender.tag])
        }
    }
}

@MainActor
private final class SidebarTable: NSTableView {
    weak var sidebarCoordinator: NativeProfileSidebar.Coordinator?
    override func menu(for event: NSEvent) -> NSMenu? {
        sidebarCoordinator?.menu(for: row(at: convert(event.locationInWindow, from: nil)))
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .control],
           event.keyCode == 125 || event.keyCode == 126 {
            sidebarCoordinator?.moveSelected(by: event.keyCode == 126 ? -1 : 1)
            return
        }
        if event.keyCode == 96, event.modifierFlags.contains(.shift), selectedRow >= 0,
           let menu = sidebarCoordinator?.menu(for: selectedRow) {
            menu.popUp(positioning: nil, at: rect(ofRow: selectedRow).origin, in: self)
            return
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "g" {
            sidebarCoordinator?.groupSelection()
            return
        }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "g" {
            sidebarCoordinator?.groupSelection()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class SidebarCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let addButton = NSButton()
    private var onAddOutput: (() -> Void)?
    private var leading: NSLayoutConstraint!
    private var titleAfterIcon: NSLayoutConstraint!
    private var headingLeading: NSLayoutConstraint!
    private var titleToDot: NSLayoutConstraint!
    private var titleToAddButton: NSLayoutConstraint!

    @objc
    private func addOutputClicked() {onAddOutput?()}
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [icon, title, dot, addButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = title
        imageView = icon
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        leading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        titleAfterIcon = title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)
        headingLeading = title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        leading = icon.leadingAnchor.constraint(equalTo: leadingAnchor,constant: 2)
        titleAfterIcon = title.leadingAnchor.constraint(equalTo: icon.trailingAnchor,constant: 6)
        headingLeading = title.leadingAnchor.constraint(equalTo: leadingAnchor,constant: 2)
        titleToDot = title.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor,constant: -2)
        titleToAddButton = title.trailingAnchor.constraint(
            lessThanOrEqualTo:addButton.leadingAnchor,constant: -3
        )
        NSLayoutConstraint.activate([
            leading,
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleAfterIcon,
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleToDot,
            dot.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            addButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,constant: -2),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 16),
            addButton.heightAnchor.constraint(equalToConstant: 16)
            ])
        addButton.image = NSImage(systemSymbolName: "plus",accessibilityDescription: "Add Output")
        addButton.imagePosition = .imageOnly
        addButton.isBordered = false
        addButton.contentTintColor = .secondaryLabelColor
        addButton.toolTip = "Add Output"
        addButton.target = self
        addButton.action = #selector(addOutputClicked)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ row: SidebarRow, activeID: UUID?, onAddOutput: @escaping () -> Void) {
        self.onAddOutput = onAddOutput
        addButton.isHidden = true
        titleToAddButton.isActive = false
        titleToDot.isActive = true
        headingLeading.isActive = false
        titleAfterIcon.isActive = true
        icon.isHidden = false
        title.stringValue = row.title
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        title.textColor = .labelColor
        toolTip = row.title
        leading.constant = row.folderID == nil ? 2 : 12
        dot.isHidden = true
        icon.contentTintColor = .secondaryLabelColor
        let symbol: String
        switch row.kind {
        case .navigation(let id):
            symbol = id == .applications ? "square.stack.3d.up.fill" : "gearshape"
        case .addOutput: symbol = "plus"
        case .heading:
            symbol = "hifispeaker.2"
            title.font = .systemFont(ofSize: 12,weight: .semibold)
            title.textColor = .secondaryLabelColor
            addButton.isHidden = false
            titleToDot.isActive = false
            titleToAddButton.isActive = true
        case .folder: symbol = row.expanded ? "chevron.down" : "chevron.right"
        case .profile(let id):
            symbol = "speaker.wave.2"
            icon.contentTintColor = row.enabled ? .systemBlue : .secondaryLabelColor
            dot.isHidden = activeID != id
        }
        icon.image = symbol.isEmpty ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        switch row.kind {
        case .profile:
            setAccessibilityLabel(row.title + ", profile, " + (row.enabled ? "Enabled" : "Disabled") + (dot.isHidden ? "" : ", Active"))
        case .folder:
            setAccessibilityLabel(row.title + ", folder, " + (row.expanded ? "expanded" : "collapsed"))
        default: setAccessibilityLabel(row.title)
        }
        icon.setAccessibilityElement(false)
        dot.setAccessibilityElement(false)
    }
}

private var minimumSidebarWidth: CGFloat {
    let appAudioFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let outputProfilesFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    let appAudioText = NSTextField(labelWithString: "App Audio")
    appAudioText.font = appAudioFont
    appAudioText.sizeToFit()
    let outputProfilesText = NSTextField(labelWithString: "Output Profiles")
    outputProfilesText.font = outputProfilesFont
    outputProfilesText.sizeToFit()
    
    /*
     Calculation:
     icon width          = 16
     icon -> title gap   = 6
     heading add button  = 20
     title -> plus gap   = 6
     plus trailing       = 2
     icon leading        = 2
    */
    let appAudioWidth = 2 + 16 + 6 + appAudioText.fittingSize.width + 12
    let outputProfilesWidth = 2 + 16 + 6 + outputProfilesText.fittingSize.width + 6 + 20 + 2 + 5
    let tableAllowance: CGFloat = 16
    return ceil(
        max(appAudioWidth, outputProfilesWidth)
        + tableAllowance
    )
}

@MainActor
private struct DeletionUndoNotice: View {
    @ObservedObject var history: UndoCoordinator
    @State private var visibleEntry: UUID?
    var body: some View {
        Group {
            if let entry = history.undoStack.last, entry.id == visibleEntry,
               case .deletion(_, deleted: true) = entry.after {
                HStack {
                    Text("Deleted").font(.caption)
                    Spacer()
                    Button("Undo") { Task { await history.undo() } }.disabled(!history.canUndo)
                }.padding(10)
            }
        }
        .task(id: history.undoStack.last?.id) {
            visibleEntry = history.undoStack.last?.id
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            visibleEntry = nil
        }
    }
}
