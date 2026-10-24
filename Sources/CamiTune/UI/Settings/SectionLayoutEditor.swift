import CamiTuneDomain
import SwiftUI
import AppKit

@MainActor
struct SectionLayoutEditor: View {
    let type: ProfileEndpointKind
    @Binding var layout: ProfileSectionLayout
    var isExclusiveOutput = false
    var requiresConfirmation: (ProfileSection) -> Bool = { _ in false }
    @State private var confirmingHide = false
    @State private var pendingLayout: ProfileSectionLayout?
    @State private var pendingSection: ProfileSection?

    private var confirmedLayout: Binding<ProfileSectionLayout> {
        Binding(get: { layout }, set: { proposed in
            if let section = proposed.hidden.subtracting(layout.hidden).first(where: requiresConfirmation) {
                pendingLayout = proposed
                pendingSection = section
                confirmingHide = true
            } else { layout = proposed }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isExclusiveOutput {
                Label("Exclusive mode hides native audio controls. Device Setup always remains visible. App Audio, Plug-ins, and Meters & Status can be shown or hidden without stopping audio. Switch back to Through CamillaDSP to restore your section layout.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach([ProfileSection.meters, .appAudio, .plugins]) { section in
                    Toggle("Show \(section.title)", isOn: Binding(
                        get: { !layout.hidden.contains(section) },
                        set: { shown in
                            var updated = layout
                            if shown { updated.hidden.remove(section) }
                            else { updated.hidden.insert(section) }
                            layout = updated
                        }))
                }
            } else {
                Picker("Default Equalizer", selection: $layout.equalizer) {
                    ForEach(EqualizerPresentation.allCases) { Text($0.title).tag($0) }
                }
                Label("Drag the reorder symbol to arrange sections. Unchecked sections stop processing and keep their saved settings.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                SectionLayoutList(type: type, layout: confirmedLayout)
                    .frame(minHeight: 280)
            }
        }
        .alert("Disable \(pendingSection?.title ?? "section")?", isPresented: $confirmingHide) {
            Button("Disable", role: .destructive) {
                if let pendingLayout { layout = pendingLayout }
                pendingSection = nil
                pendingLayout = nil
            }
            Button("Cancel", role: .cancel) { pendingSection = nil; pendingLayout = nil }
        } message: {
            Text(pendingSection == .mode
                ? "Are you sure you want to uncheck Mode? Playback will use Direct only and the mode controls will be hidden. Your saved mode settings will be kept."
                : "Are you sure you want to uncheck this section? Its enabled processing will stop when the layout is applied. Your saved settings will be kept.")
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

    // Match App Order's explicit row-height delegate. Native gap tracking needs
    // this geometry to move every intervening row before the mouse is released.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight }

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
        if section == .subwooferControl {
            let mode: SectionVisibility = sectionLayout.explicitlyShown.contains(.subwooferControl) ? .shown : .automatic
            cell.configureAutomaticVisibility(mode) { [weak self] mode in
                guard let self else { return }
                if mode == .shown { self.sectionLayout.explicitlyShown.insert(.subwooferControl) }
                else { self.sectionLayout.explicitlyShown.remove(.subwooferControl) }
                self.onChange(self.sectionLayout)
            }
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
    private static let automaticVisibilityModes: [SectionVisibility] = [.automatic, .shown]
    private let automaticVisibility = NSPopUpButton()
    private lazy var automaticVisibilityConstraints = [
        automaticVisibility.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
        automaticVisibility.trailingAnchor.constraint(lessThanOrEqualTo: visibility.leadingAnchor, constant: -10)
    ]
    private var onAutomaticVisibilityChange: (SectionVisibility) -> Void = { _ in }
    private var onVisibilityChange: (Bool) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        handle.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Reorder section")
        handle.contentTintColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        visibility.target = self
        visibility.action = #selector(toggleVisibility)
        automaticVisibility.addItems(withTitles: Self.automaticVisibilityModes.map(\.title))
        automaticVisibility.controlSize = .small
        automaticVisibility.target = self
        automaticVisibility.action = #selector(changeAutomaticVisibility)
        for view in [handle, label, visibility, automaticVisibility] {
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
        automaticVisibility.isHidden = true
        NSLayoutConstraint.deactivate(automaticVisibilityConstraints)
        let locked = section == .deviceSetup
        label.stringValue = section.title
        handle.image = NSImage(systemSymbolName: locked ? "lock.fill" : "line.3.horizontal",
                               accessibilityDescription: locked ? "Locked section" : "Reorder section")
        handle.setAccessibilityLabel(locked ? "\(section.title), locked, always visible and first" : "Reorder \(section.title)")
        visibility.isHidden = locked
        visibility.isEnabled = !locked
        visibility.state = (locked || shown) ? .on : .off
        visibility.setAccessibilityLabel("Show \(section.title)")
        onVisibilityChange = onChange
    }

    @objc private func toggleVisibility() {
        automaticVisibility.isEnabled = visibility.state == .on
        onVisibilityChange(visibility.state == .on)
    }

    func configureAutomaticVisibility(_ mode: SectionVisibility, onChange: @escaping (SectionVisibility) -> Void) {
        automaticVisibility.isHidden = false
        automaticVisibility.isEnabled = visibility.state == .on
        NSLayoutConstraint.activate(automaticVisibilityConstraints)
        automaticVisibility.selectItem(at: Self.automaticVisibilityModes.firstIndex(of: mode) ?? 0)
        automaticVisibility.setAccessibilityLabel("Subwoofer Control visibility")
        automaticVisibility.setAccessibilityHelp("Automatic shows this section when speakers and a subwoofer are configured.")
        onAutomaticVisibilityChange = onChange
    }

    @objc private func changeAutomaticVisibility() {
        let index = automaticVisibility.indexOfSelectedItem
        guard Self.automaticVisibilityModes.indices.contains(index) else { return }
        onAutomaticVisibilityChange(Self.automaticVisibilityModes[index])
    }

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
