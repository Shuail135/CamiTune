import CamiTuneDomain
import SwiftUI
import AppKit

@MainActor
struct SectionLayoutEditor: View {
    let type: ProfileEndpointKind
    @Binding var layout: ProfileSectionLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Default Equalizer", selection: $layout.equalizer) {
                ForEach(EqualizerPresentation.allCases) { Text($0.title).tag($0) }
            }
            Text("Drag the reorder symbol to arrange sections. Hidden sections keep their processing settings.")
                .font(.caption).foregroundStyle(.secondary)
            SectionLayoutList(type: type, layout: $layout)
                .frame(minHeight: 280)
        }
    }
}

@MainActor
private struct SectionLayoutList: NSViewRepresentable {
    let type: ProfileEndpointKind
    @Binding var layout: ProfileSectionLayout

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = SectionLayoutTableView()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? SectionLayoutTableView else { return }
        table.configure(type: type, layout: layout) { layout = $0 }
    }
}

/// AppKit owns the native row drag and gap animation. Only its mouse-down
/// eligibility check is restricted to the handle; pointer movement never disables a drag.
@MainActor
final class SectionLayoutTableView: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
    private static let dragType = NSPasteboard.PasteboardType("com.camitune.section-layout")
    private var endpoint: ProfileEndpointKind = .speakers
    private(set) var sectionLayout = ProfileSectionLayout()
    private var onChange: (ProfileSectionLayout) -> Void = { _ in }
    private var sections: [ProfileSection] {
        sectionLayout.normalizedOrder.filter { $0.applies(to: endpoint) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        addTableColumn(column)
        headerView = nil
        style = .inset
        rowHeight = 32
        intercellSpacing = NSSize(width: 0, height: 0)
        columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        autoresizingMask = [.width]
        allowsMultipleSelection = false
        allowsEmptySelection = true
        draggingDestinationFeedbackStyle = .gap
        delegate = self
        dataSource = self
        registerForDraggedTypes([Self.dragType])
        setDraggingSourceOperationMask(.move, forLocal: true)
        setDraggingSourceOperationMask([], forLocal: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(type: ProfileEndpointKind, layout: ProfileSectionLayout,
                   onChange: @escaping (ProfileSectionLayout) -> Void) {
        self.onChange = onChange
        guard endpoint != type || sectionLayout != layout || numberOfRows != sections.count else { return }
        endpoint = type
        sectionLayout = layout
        reloadData()
    }

    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        guard rowIndexes.count == 1, let index = rowIndexes.first,
              sections.indices.contains(index), sections[index] != .deviceSetup,
              row(at: mouseDownPoint) == index,
              let cell = view(atColumn: 0, row: index, makeIfNecessary: true) as? SectionLayoutCellView
        else { return false }
        cell.layoutSubtreeIfNeeded()
        let handlePoint = cell.handle.convert(mouseDownPoint, from: self)
        return cell.handle.bounds.contains(handlePoint)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sections.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("section-layout-cell")
        let cell = (makeView(withIdentifier: identifier, owner: nil) as? SectionLayoutCellView)
            ?? SectionLayoutCellView()
        cell.identifier = identifier
        let section = sections[row]
        cell.configure(section: section, shown: !sectionLayout.hidden.contains(section)) { [weak self] shown in
            guard let self, section != .deviceSetup else { return }
            if shown { self.sectionLayout.hidden.remove(section) }
            else { self.sectionLayout.hidden.insert(section) }
            self.onChange(self.sectionLayout)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard sections.indices.contains(row), sections[row] != .deviceSetup else { return nil }
        let item = NSPasteboardItem()
        item.setString(sections[row].rawValue, forType: Self.dragType)
        return item
    }

    private func draggedSection(_ info: NSDraggingInfo) -> ProfileSection? {
        guard (info.draggingSource as? NSTableView) === self,
              let value = info.draggingPasteboard.string(forType: Self.dragType),
              let section = ProfileSection(rawValue: value), section != .deviceSetup,
              sections.contains(section) else { return nil }
        return section
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard draggedSection(info) != nil else { return [] }
        setDropRow(max(1, min(row, sections.count)), dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        guard let section = draggedSection(info) else { return false }
        return reorder(section, to: row)
    }

    @discardableResult
    func reorder(_ section: ProfileSection, to destination: Int) -> Bool {
        let applicable = sections
        guard section != .deviceSetup, let source = applicable.firstIndex(of: section),
              (0...applicable.count).contains(destination) else { return false }
        let destination = max(1, destination)
        let insertion = destination > source ? destination - 1 : destination
        guard insertion != source else { return true }
        var reordered = applicable
        reordered.remove(at: source)
        reordered.insert(section, at: insertion)
        var iterator = reordered.makeIterator()
        // Preserve remembered slots for sections unavailable for this device type.
        sectionLayout.order = sectionLayout.normalizedOrder.map { section in
            applicable.contains(section) ? (iterator.next() ?? section) : section
        }
        moveRow(at: source, to: insertion)
        onChange(sectionLayout)
        return true
    }
}

@MainActor
final class SectionLayoutCellView: NSTableCellView {
    let handle = NSImageView()
    let label = NSTextField(labelWithString: "")
    let visibility = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var onVisibilityChange: (Bool) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        handle.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Reorder section")
        handle.contentTintColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        visibility.target = self
        visibility.action = #selector(toggleVisibility)
        for view in [handle, label, visibility] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            handle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            handle.widthAnchor.constraint(equalToConstant: 20),
            handle.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: handle.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: visibility.leadingAnchor, constant: -10),
            visibility.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
        imageView = handle
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(section: ProfileSection, shown: Bool, onChange: @escaping (Bool) -> Void) {
        let locked = section == .deviceSetup
        label.stringValue = section.title
        handle.image = NSImage(systemSymbolName: locked ? "lock.fill" : "line.3.horizontal",
                               accessibilityDescription: locked ? "Locked section" : "Reorder section")
        handle.toolTip = locked ? "Always visible and first" : "Drag to reorder \(section.title)"
        handle.setAccessibilityLabel(locked ? "\(section.title), locked, always visible and first" : "Reorder \(section.title)")
        visibility.isHidden = locked
        visibility.isEnabled = !locked
        visibility.state = (locked || shown) ? .on : .off
        visibility.setAccessibilityLabel("Show \(section.title)")
        visibility.toolTip = "Show or hide \(section.title)"
        onVisibilityChange = onChange
    }

    @objc private func toggleVisibility() { onVisibilityChange(visibility.state == .on) }

    override var draggingImageComponents: [NSDraggingImageComponent] {
        // The native drag carries the complete row, including its visibility control.
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
