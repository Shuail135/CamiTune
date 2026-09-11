import SwiftUI
import AppKit
import Combine

/// Lightweight presentation data: EQ edits must not reload the native table.
struct SidebarRow: Equatable {
    enum Kind: Equatable {
        case navigation(SidebarDestination), addOutput, heading, folder(UUID), profile(UUID)
    }
    let kind: Kind
    let title: String
    var folderID: UUID? = nil
    var indexInGroup = 0
    var enabled = true
    var expanded = false

    var selectionID: SidebarDestination? {
        switch kind {
        case .navigation(let id): return id
        case .profile(let id): return .profile(id)
        default: return nil
        }
    }

    static func build(profiles: [DeviceProfile], folders: [ProfileFolder], expanded: Set<UUID>) -> [SidebarRow] {
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
            SidebarRow(kind: .navigation(.setup), title: "Setup"),
            SidebarRow(kind: .addOutput, title: "Add Output"),
            SidebarRow(kind: .navigation(.applications), title: "Applications"),
            SidebarRow(kind: .heading, title: "Output profiles")
        ]
        func appendProfiles(_ profiles: [DeviceProfile], folder: UUID?) {
            for (index, profile) in profiles.enumerated() {
                rows.append(SidebarRow(kind: .profile(profile.id), title: profile.name,
                    folderID: folder, indexInGroup: index, enabled: profile.isEnabled))
            }
        }
        appendProfiles(ungrouped, folder: nil)
        for folder in folders {
            rows.append(SidebarRow(kind: .folder(folder.id), title: folder.name,
                expanded: expanded.contains(folder.id)))
            if expanded.contains(folder.id) { appendProfiles(groups[folder.id] ?? [], folder: folder.id) }
        }
        return rows
    }

    struct DropTarget: Equatable {
        var folderID: UUID?
        var index: Int?
        var onRow: Bool
    }

    static func dropTarget(rows: [SidebarRow], row: Int, onRow: Bool) -> DropTarget? {
        // Empty space after the list always means the top-level profile group.
        if row == rows.count || row == -1 { return DropTarget(onRow: false) }
        guard rows.indices.contains(row) else { return nil }
        switch rows[row].kind {
        case .heading: return DropTarget(onRow: true)
        case .folder(let id):
            return onRow ? DropTarget(folderID: id, onRow: true) : DropTarget(onRow: false)
        case .profile:
            return DropTarget(folderID: rows[row].folderID, index: rows[row].indexInGroup, onRow: false)
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
                rows: SidebarRow.build(profiles: profileStore.profiles, folders: profileStore.folders, expanded: expandedFolders),
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
                onDrop: { ids, target in
                    profileStore.dropProfiles(ids: ids, into: target.folderID, at: target.index)
                    if let folder = target.folderID { expandedFolders.insert(folder) }
                }
            )
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
        .sheet(item: $folderDeletion) { request in
            FolderDeletionSheet(request: request, onCancel: { folderDeletion = nil }) {
                let deleted = await state.deleteProfileFolder(
                    id: request.id, confirmedProfileIDs: Set(request.profiles.map(\.id)))
                if deleted {
                    expandedFolders.remove(request.id)
                    if request.profiles.contains(where: { .profile($0.id) == selection }) {
                        selection = profileStore.selectedProfileID.map(SidebarDestination.profile) ?? .setup
                    }
                }
                folderDeletion = nil
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
            selection = .setup
            Task {
                if state.activeProfileID == id { await state.deactivate(manual: true) }
                profileStore.deleteProfile(id: id)
            }
        case .moveToFolder(let ids, let folder): profileStore.assignProfiles(ids: ids, toFolder: folder)
        }
    }
}

private struct FolderDeletionRequest: Identifiable {
    let id: UUID
    let name: String
    let profiles: [DeviceProfile]
}

/// A window-attached macOS sheet with native controls and no app icon.
@MainActor
private struct FolderDeletionSheet: View {
    let request: FolderDeletionRequest
    let onCancel: () -> Void
    let onDelete: () async -> Void
    @State private var isDeleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete “\(request.name)”?")
                .font(.headline)
            Text(request.profiles.isEmpty
                 ? "This folder will be deleted. This cannot be undone."
                 : "This folder and all \(request.profiles.count) profiles inside it will be deleted. This cannot be undone.")
                .fixedSize(horizontal: false, vertical: true)
            if !request.profiles.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(request.profiles) { profile in
                            Text(profile.name).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: min(140, CGFloat(request.profiles.count) * 23))
            }
            HStack {
                if isDeleting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    isDeleting = true
                    Task { await onDelete() }
                }
            }
            .disabled(isDeleting)
        }
        .padding(24)
        .frame(width: 390)
        .interactiveDismissDisabled(isDeleting)
    }
}

private struct SidebarInlineEditRequest {
    let id = UUID()
    let target: SidebarRow.Kind
}

private enum SidebarAction {
    case addOutput, toggleFolder(UUID), newFolder(Set<UUID>), renameFolder(UUID), removeFolder(UUID)
    case renameProfile(UUID), toggleProfile(UUID), deleteProfile(UUID), moveToFolder(Set<UUID>, UUID)
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
    let onDrop: @MainActor (Set<UUID>, SidebarRow.DropTarget) -> Void

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
        var draggedIDs: Set<UUID> = []
        let selectionScheduler = SidebarSelectionScheduler<SidebarDestination>()
        var handledEditRequest: UUID?
        var editingTarget: SidebarRow.Kind?
        var editSessionID: UUID?
        var originalName = ""
        weak var editingField: NSTextField?
        var outsideClickMonitor: Any?


        init(_ parent: NativeProfileSidebar) { self.parent = parent }

        func observeRuntime(_ state: AppState) {
            runtimeSubscription = state.$activeSession.map { $0?.profileID }
                .combineLatest(state.$isActive)
                .map { $1 ? $0 : nil }.removeDuplicates()
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
                let selected = Set(table.selectedRowIndexes.compactMap { displayedRows.indices.contains($0) ? displayedRows[$0].selectionID : nil })
                displayedRows = parent.rows
                suppressSelection = true
                table.reloadData()
                table.selectRowIndexes(IndexSet(displayedRows.indices.filter { displayedRows[$0].selectionID.map { selected.contains($0) } ?? false }), byExtendingSelection: false)
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
                cell.configure(row, activeID: activeProfileID)
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
            displayedRows[row].selectionID != nil
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
            guard let table, displayedRows.indices.contains(table.clickedRow) else { return }
            switch displayedRows[table.clickedRow].kind {
            case .folder(let id):
                selectionScheduler.cancel()
                parent.onAction(.toggleFolder(id))
            case .addOutput:
                selectionScheduler.cancel()
                parent.onAction(.addOutput)
            default: break
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("sidebar-cell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarCell) ?? SidebarCell()
            cell.identifier = identifier
            cell.configure(displayedRows[row], activeID: activeProfileID)
            return cell
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard editingTarget == nil, case .profile(let id) = displayedRows[row].kind else { return nil }
            let item = NSPasteboardItem()
            item.setString(id.uuidString, forType: Self.dragType)
            return item
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            selectionScheduler.cancel()
            draggedIDs = Set(rowIndexes.compactMap {
                if case .profile(let id) = displayedRows[$0].kind { return id }; return nil
            })
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            draggedIDs = []
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard (info.draggingSource as? NSTableView) === tableView, !draggedIDs.isEmpty,
                  let target = SidebarRow.dropTarget(rows: displayedRows, row: row, onRow: operation == .on) else { return [] }
            tableView.setDropRow(row == -1 ? displayedRows.count : row, dropOperation: target.onRow ? .on : .above)
            return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
            guard (info.draggingSource as? NSTableView) === tableView,
                  let target = SidebarRow.dropTarget(rows: displayedRows, row: row, onRow: operation == .on) else { return false }
            let ids = Set((info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: Self.dragType).flatMap(UUID.init(uuidString:)) })
            guard !ids.isEmpty else { return false }
            parent.onDrop(ids, target)
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
                add("Rename", .renameProfile(id))
                add("Delete", .deleteProfile(id))
            default: break
            }
            return menu
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
    private var leading: NSLayoutConstraint!
    private var titleAfterIcon: NSLayoutConstraint!
    private var headingLeading: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [icon, title, dot] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        textField = title
        imageView = icon
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        leading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        titleAfterIcon = title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)
        headingLeading = title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        NSLayoutConstraint.activate([
            leading, icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleAfterIcon,
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(equalTo: dot.leadingAnchor, constant: -4),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ row: SidebarRow, activeID: UUID?) {
        let isHeading = row.kind == .heading
        if isHeading {
            titleAfterIcon.isActive = false
            headingLeading.isActive = true
        } else {
            headingLeading.isActive = false
            titleAfterIcon.isActive = true
        }
        icon.isHidden = isHeading
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
            symbol = id == .setup ? "wrench.and.screwdriver" : (id == .applications ? "square.stack.3d.up.fill" : "gearshape")
        case .addOutput: symbol = "plus.circle.fill"; icon.contentTintColor = .controlAccentColor
        case .heading:
            symbol = ""; title.font = .boldSystemFont(ofSize: 11); title.textColor = .secondaryLabelColor
        case .folder: symbol = row.expanded ? "chevron.down" : "chevron.right"
        case .profile(let id):
            symbol = "speaker.wave.2"
            icon.contentTintColor = row.enabled ? .systemBlue : .secondaryLabelColor
            dot.isHidden = activeID != id
        }
        icon.image = symbol.isEmpty ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        setAccessibilityLabel(row.title + (dot.isHidden ? "" : ", Active"))
    }
}
