import SwiftUI
import AppKit
import Combine

struct AppOrderView: View {
    @ObservedObject var store: AppPresentationStore
    @ObservedObject var controller: PerAppAudioController
    @Environment(\.dismiss) private var dismiss

    private var currentNames: [String: String] {
        Dictionary(uniqueKeysWithValues: controller.applications.map { ($0.id, $0.displayName) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("App Order").font(.title2.bold())
            if store.snapshot.orderedApplicationIDs.isEmpty {
                Text("Play audio in an application to add it here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Drag the reorder symbol to arrange apps or move them between Shown and Hidden.")
                    .font(.caption).foregroundStyle(.secondary)
                AppOrderList(store: store, systemNames: currentNames)
            }
            if let error = store.persistenceError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Reset Order") { store.resetOrder(systemNames: currentNames) }
                    .disabled(store.snapshot.orderedApplicationIDs.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
    }
}

@MainActor
private struct AppOrderList: NSViewRepresentable {
    let store: AppPresentationStore
    let systemNames: [String: String]

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = AppOrderTableView()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? AppOrderTableView)?.configure(store: store, systemNames: systemNames)
    }
}

/// Uses the same native row drag, gap feedback, and mouse-down handle check as Section Layout.
@MainActor
final class AppOrderTableView: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
    enum Row: Equatable {
        case heading(AppAudioSection)
        case application(String, AppAudioSection)

        var section: AppAudioSection {
            switch self {
            case .heading(let section), .application(_, let section): return section
            }
        }
        var applicationID: String? {
            if case .application(let id, _) = self { return id }
            return nil
        }
    }

    private static let dragType = NSPasteboard.PasteboardType("com.camitune.app-order-settings")
    private var store: AppPresentationStore?
    private var storeSubscription: AnyCancellable?
    private var snapshot = AppPresentationDocument()
    private var systemNames: [String: String] = [:]
    private(set) var rows: [Row] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application")))
        headerView = nil
        style = .inset
        rowHeight = 44
        intercellSpacing = .zero
        columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        autoresizingMask = [.width]
        allowsMultipleSelection = false
        allowsEmptySelection = true
        // Floating group rows follow AppKit's drag-gap tracking and can appear
        // to move with an app. Keep headings in their normal section positions.
        floatsGroupRows = false
        draggingDestinationFeedbackStyle = .gap
        delegate = self
        dataSource = self
        registerForDraggedTypes([Self.dragType])
        setDraggingSourceOperationMask(.move, forLocal: true)
        setDraggingSourceOperationMask([], forLocal: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeRows(_ document: AppPresentationDocument) -> [Row] {
        AppAudioSection.allCases.flatMap { section in
            [.heading(section)] + document.orderedApplicationIDs
                .filter { document.section(for: $0) == section }
                .map { Row.application($0, section) }
        }
    }

    func configure(store: AppPresentationStore, systemNames: [String: String]) {
        let storeChanged = self.store !== store
        if storeChanged {
            self.store = store
            // Keep the native list synchronized with drags in App Audio and
            // the menu bar, even when SwiftUI's wrapper inputs are unchanged.
            storeSubscription = store.$snapshot.dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak store] _ in
                    guard let self, let store, self.store === store else { return }
                    // Read the latest snapshot after publication, avoiding stale
                    // queued updates or reloading in the middle of a native drop.
                    self.configure(store: store, systemNames: self.systemNames)
                }
        }
        guard storeChanged || snapshot != store.snapshot || self.systemNames != systemNames else { return }
        snapshot = store.snapshot
        self.systemNames = systemNames
        rows = makeRows(snapshot)
        reloadData()
    }

    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        guard rowIndexes.count == 1, let index = rowIndexes.first,
              rows.indices.contains(index), rows[index].applicationID != nil,
              row(at: mouseDownPoint) == index,
              let cell = view(atColumn: 0, row: index, makeIfNecessary: true) as? AppOrderCellView
        else { return false }
        cell.layoutSubtreeIfNeeded()
        return cell.handle.bounds.contains(cell.handle.convert(mouseDownPoint, from: self))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].applicationID == nil }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].applicationID != nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].applicationID == nil ? 28 : 44 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = rows[row].applicationID else {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: rows[row].section.title)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8)
            ])
            return cell
        }
        let identifier = NSUserInterfaceItemIdentifier("app-order-cell")
        let cell = (makeView(withIdentifier: identifier, owner: nil) as? AppOrderCellView) ?? AppOrderCellView()
        cell.identifier = identifier
        let name = snapshot.displayName(for: id, systemName: systemNames[id])
        cell.configure(name: name, bundleID: snapshot.records[id]?.lastKnownBundleID ?? id,
                       shown: snapshot.section(for: id) == .shown) { [weak self] in
            guard let self, let store = self.store else { return }
            let destination: AppAudioSection = store.snapshot.section(for: id) == .shown ? .hidden : .shown
            store.moveApplication(id, to: destination)
            self.configure(store: store, systemNames: self.systemNames)
        }
        cell.setAccessibilityCustomActions([-1, 1].map { offset in
            NSAccessibilityCustomAction(name: offset < 0 ? "Move Up" : "Move Down", handler: { [weak self] in
                guard let self, let store = self.store else { return false }
                if offset < 0 { store.moveUp(id) } else { store.moveDown(id) }
                self.configure(store: store, systemNames: self.systemNames)
                return true
            })
        })
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row), let id = rows[row].applicationID else { return nil }
        let item = NSPasteboardItem()
        item.setString(id, forType: Self.dragType)
        return item
    }

    private func draggedApplication(_ info: NSDraggingInfo) -> String? {
        guard (info.draggingSource as? NSTableView) === self,
              let id = info.draggingPasteboard.string(forType: Self.dragType),
              store?.seenIDs.contains(id) == true else { return nil }
        return id
    }

    func insertionRow(proposed row: Int, operation: NSTableView.DropOperation) -> Int {
        if operation == .on, rows.indices.contains(row), rows[row].applicationID == nil {
            return row + 1
        }
        return max(1, min(row, rows.count))
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard draggedApplication(info) != nil else { return [] }
        setDropRow(insertionRow(proposed: row, operation: operation), dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        guard let id = draggedApplication(info) else { return false }
        return reorder(id, to: row)
    }

    @discardableResult
    func reorder(_ id: String, to insertion: Int) -> Bool {
        guard let store, let source = rows.firstIndex(where: { $0.applicationID == id }),
              store.seenIDs.contains(id), (1...rows.count).contains(insertion),
              let heading = rows[..<insertion].last(where: { $0.applicationID == nil }) else { return false }
        let target = rows.indices.contains(insertion) && rows[insertion].section == heading.section
            ? rows[insertion].applicationID : nil
        if target == id { return true }
        store.moveApplication(id, to: heading.section, relativeTo: target, after: target == nil)
        snapshot = store.snapshot
        rows = makeRows(snapshot)
        if let destination = rows.firstIndex(where: { $0.applicationID == id }) {
            if source != destination { moveRow(at: source, to: destination) }
            reloadData(forRowIndexes: IndexSet(integer: destination), columnIndexes: IndexSet(integer: 0))
        }
        return true
    }
}

@MainActor
final class AppOrderCellView: NSTableCellView {
    let handle = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let bundleLabel = NSTextField(labelWithString: "")
    let visibility = NSButton()
    private var onVisibilityChange: () -> Void = { }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        handle.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Reorder app")
        handle.contentTintColor = .secondaryLabelColor
        bundleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        bundleLabel.textColor = .secondaryLabelColor
        for label in [nameLabel, bundleLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let labels = NSStackView(views: [nameLabel, bundleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        visibility.isBordered = false
        visibility.imagePosition = .imageOnly
        visibility.target = self
        visibility.action = #selector(toggleVisibility)
        for view in [handle, labels, visibility] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            handle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            handle.widthAnchor.constraint(equalToConstant: 20),
            handle.heightAnchor.constraint(equalToConstant: 24),
            labels.leadingAnchor.constraint(equalTo: handle.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: visibility.leadingAnchor, constant: -10),
            visibility.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            visibility.widthAnchor.constraint(equalToConstant: 24),
            visibility.heightAnchor.constraint(equalToConstant: 24)
        ])
        imageView = handle
        textField = nameLabel
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, bundleID: String, shown: Bool, onChange: @escaping () -> Void) {
        nameLabel.stringValue = name
        nameLabel.toolTip = name
        bundleLabel.stringValue = bundleID
        bundleLabel.toolTip = bundleID
        handle.toolTip = "Drag to reorder \(name)"
        handle.setAccessibilityLabel("Reorder \(name)")
        visibility.image = NSImage(systemSymbolName: shown ? "eye.slash" : "eye", accessibilityDescription: nil)
        visibility.toolTip = shown ? "Hide from Menu Bar" : "Show in Menu Bar"
        visibility.setAccessibilityLabel("\(shown ? "Hide" : "Show") \(name) in menu bar")
        onVisibilityChange = onChange
    }

    @objc private func toggleVisibility() { onVisibilityChange() }

    override var draggingImageComponents: [NSDraggingImageComponent] {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return super.draggingImageComponents }
        cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = image
        component.frame = bounds
        return [component]
    }
}
