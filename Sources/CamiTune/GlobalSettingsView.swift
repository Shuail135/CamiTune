import SwiftUI
import AppKit
import Foundation

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var commands: MainWindowCommandCoordinator
    let state: AppState
    @ObservedObject private var store: ProfileStore
    @ObservedObject private var loginItem: LoginItemManager
    @ObservedObject private var updateChecker: AppUpdateChecker
    private var category: String { commands.settingsCategory }
    @State private var type: ProfileEndpointKind = .speakers
    @State private var showingApply = false
    @State private var selectedProfiles: Set<UUID> = []
    @AppStorage("hideCloseKeepsRunningHint") private var hideCloseKeepsRunningHint = false
    private let categories = ["General", "Section Layout", "Drivers & Components", "Confirmations"]

    init(state: AppState) {
        self.state = state
        _store = ObservedObject(wrappedValue: state.profiles)
        _loginItem = ObservedObject(wrappedValue: state.loginItem)
        _updateChecker = ObservedObject(wrappedValue: state.updateChecker)
    }
    var body: some View {
        HStack(spacing: 0) {
            List(categories, id: \.self, selection: $commands.settingsCategory) { Text($0).tag($0) }
                .listStyle(.sidebar).frame(width: 185)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text(category).font(.title.bold())
                switch category {
                case "General":
                    Toggle("Start CamiTune at login", isOn: Binding(
                        get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                        .disabled(loginItem.isUpdating)
                    Text(loginItem.statusMessage).font(.callout).foregroundStyle(.secondary)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Automatically check for updates", isOn: $updateChecker.automaticallyChecksForUpdates)
                            Text("Check for new CamiTune versions when the app starts and when update reminders are due.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case "Section Layout":
                    Picker("Device Type", selection: $type) {
                        ForEach(ProfileEndpointKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Text("New profiles and profiles using global defaults will use this layout.")
                        .foregroundStyle(.secondary)
                    SectionLayoutEditor(type: type, layout: Binding(
                        get: { store.defaultLayout(for: type) },
                        set: { store.setDefaultLayout($0, for: type) }))
                    Button("Apply to Existing Profiles…") {
                        selectedProfiles = []
                        showingApply = true
                    }
                case "Drivers & Components":
                    SetupView(state: state, embedded: true)
                case "Confirmations":
                    Text("Choose which pop-ups to show. Turn an option back on here after selecting “Do not show this again.”")
                        .foregroundStyle(.secondary)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Show profile enabled explanation", isOn: $store.showProfileEnabledExplanation)
                            Text("Show an explanation when you manually enable a profile.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Show window closing reminder", isOn: Binding(
                                get: { !hideCloseKeepsRunningHint },
                                set: { hideCloseKeepsRunningHint = !$0 }))
                            Text("Remind you that CamiTune keeps running when you close its window.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                default: EmptyView()
                }
                Spacer(minLength: 0)
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showingApply) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Apply Layout to Existing Profiles").font(.title2.bold())
                Text("Selected profiles will use the global \(type.displayName) layout. Their local layout overrides will be replaced.")
                List(store.profiles.filter { $0.endpointKind == type }) { profile in
                    Toggle(profile.name, isOn: Binding(
                        get: { selectedProfiles.contains(profile.id) },
                        set: { if $0 { selectedProfiles.insert(profile.id) } else { selectedProfiles.remove(profile.id) } }))
                }
                HStack {
                    Spacer()
                    Button("Cancel") { showingApply = false }.keyboardShortcut(.cancelAction)
                    Button("Apply") {
                        store.applyDefaultLayout(for: type, to: selectedProfiles)
                        showingApply = false
                    }.keyboardShortcut(.defaultAction).disabled(selectedProfiles.isEmpty)
                }
            }.padding(24).frame(width: 480, height: 390)
        }
    }
}

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

@MainActor
struct ProfileSettingsView: View {
    let state: AppState
    @ObservedObject private var store: ProfileStore
    @ObservedObject private var audio: CoreAudioManager
    @State private var draft: ProfileSettingsDraft
    @State private var category = "General"
    @State private var saving = false
    @State private var failure: String?
    @State private var recovery: AppErrorRecovery?
    @State private var showingRepair = false
    @State private var confirmClose = false
    @Environment(\.dismiss) private var dismiss

    init(state: AppState, profile: DeviceProfile) {
        self.state = state
        _store = ObservedObject(wrappedValue: state.profiles)
        _audio = ObservedObject(wrappedValue: state.coreAudio)
        _draft = State(initialValue: ProfileSettingsDraft(profile: profile, activation: state.profiles.activationMode(for: profile)))
    }
    private func save() {
        saving = true; failure = nil; recovery = nil
        Task {
            do { try await state.saveProfileSettings(draft); dismiss() }
            catch { failure = error.localizedDescription; recovery = (error as? AppState.AppError)?.recovery }
            saving = false
        }
    }
    private var categories: [String] {
        ["General", "Section Layout"]
            + ((draft.selectedType == .speakers || (draft.selectedType == .audioInterface && draft.audioInterface?.connectedEndpoint == .speakers)) ? ["Speaker & Listening Position"] : [])
    }
    private var hasChanges: Bool {
        (try? draft.candidate()) != draft.original || draft.activation != draft.originalActivation
    }
    private var generalSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Profile name", text: $draft.name)
                Picker("Device Type", selection: $draft.selectedType) {
                    ForEach(ProfileEndpointKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Output Device", selection: Binding(
                    get: { draft.outputDevice.uid },
                    set: { uid in
                        if let device = audio.physicalOutputDevices.first(where: { $0.id == uid }) {
                            draft.outputDevice = PhysicalOutputIdentity(uid: uid, name: device.name)
                        }
                    })) {
                    if !audio.physicalOutputDevices.contains(where: { $0.id == draft.outputDevice.uid }) {
                        Text("\(draft.outputDevice.name) (Disconnected)").tag(draft.outputDevice.uid)
                    }
                    ForEach(audio.physicalOutputDevices) { Text($0.name).tag($0.id) }
                }
                Text("Changing device type keeps your EQ and saved device configuration. A new device type starts in Direct unless it has a remembered supported mode.")
                    .font(.callout).foregroundStyle(.secondary)
                if draft.selectedType == .audioInterface {
                    InterfaceAssignmentEditor(state: state, output: draft.outputDevice,
                        sampleRate: draft.sampleRate, assignment: $draft.audioInterface,
                        topology: $draft.speakerTopology)

                }
                Picker("Processing Sample Rate", selection: $draft.sampleRate) {
                    ForEach(Array(Set([44100, 48000, 88200, 96000, 176400, 192000, draft.sampleRate])).sorted(), id: \.self) {
                        Text("\(Double($0) / 1000, specifier: "%g") kHz").tag($0)
                    }
                }
                Text("48 kHz is the recommended default. Higher rates increase CPU and bandwidth use but do not improve lower rate source audio.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(categories, id: \.self, selection: $category) { Text($0).tag($0) }
                    .listStyle(.sidebar).frame(width: 200)
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Profile Settings").font(.title.bold())
                    Text(category).font(.headline)
                    switch category {
                    case "General":
                        generalSettings
                    case "Section Layout":
                        SectionLayoutEditor(type: draft.selectedType, layout: Binding(
                            get: { draft.sectionLayout ?? store.defaultLayout(for: draft.selectedType) },
                            set: { draft.sectionLayout = $0 }))
                        Button("Reset to Global Defaults") { draft.sectionLayout = nil }
                            .disabled(draft.sectionLayout == nil)
                    case "Speaker & Listening Position":
                        ScrollView {
                            SpeakerSystemView(state: state, profile: Binding(
                                get: { (try? draft.candidate()) ?? draft.original },
                                set: { value in
                                    draft.speakerTopology = value.speakerTopology
                                    draft.spatialSettings = value.spatialSettings
                                }), draftOnly: true, embedded: true, compact: true)
                        }
                    default: EmptyView()
                    }
                    Spacer(minLength: 0)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                if recovery == .openSetup {
                    Button("Open Setup…") { showingRepair = true }
                }
                HStack {
                    if saving { ProgressView().controlSize(.small); Text("Saving…") }
                    Spacer()
                    Button("Cancel") { if hasChanges { confirmClose = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                    Button("Save") { save()                    }.keyboardShortcut(.defaultAction).disabled(!hasChanges || (try? draft.candidate()) == nil)
                }
            }.padding(16)
        }
        .frame(width: 780, height: 620)
        .disabled(saving)
        .interactiveDismissDisabled(hasChanges || saving)
        .alert("Save changes to this profile?", isPresented: $confirmClose) {
            Button("Save Changes") { save() }
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Your changes have not been saved.") }
        .sheet(isPresented: $showingRepair) { SetupPanel(state: state) }
        .onChange(of: draft.selectedType) { _ in
            if !categories.contains(category) { category = "General" }
        }
        .task { await audio.refreshWithoutBlockingUI() }
    }
}


@MainActor
struct InterfaceAssignmentEditor: View {
    let state: AppState
    let output: PhysicalOutputIdentity
    let sampleRate: Int
    @Binding var assignment: AudioInterfaceConfiguration?
    @Binding var topology: SpeakerTopology?
    @State private var discovering = false
    @State private var error: String?
    private var matches: Bool { assignment?.deviceUID == output.uid }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !matches { Text("Discover this interface to configure its channels.").foregroundStyle(.secondary) }
            if let value = assignment, matches {
                Picker("Connected Device", selection: Binding(get: { value.connectedEndpoint }, set: { assignment?.connectedEndpoint = $0 })) {
                    ForEach(ProfileEndpointKind.allCases.filter { $0 != .audioInterface }, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("Hardware Channels").font(.headline)
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(0..<value.hardwareChannelCount, id: \.self) { index in
                            Toggle("Channel \(index + 1)", isOn: Binding(
                                get: { assignment?.outputChannels.contains(index) == true },
                                set: { selected in
                                    guard var next = assignment else { return }
                                    next.outputChannels.removeAll { $0 == index }
                                    if selected { next.outputChannels.append(index) }
                                    next.outputChannels.sort()
                                    assignment = next
                                }))
                        }
                    }
                }.frame(maxHeight: 180)
                if let problem = validationProblem { Text(problem).font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Discover Channels") { discover() }.disabled(discovering)
                if discovering { ProgressView().controlSize(.small) }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
    }
    private var validationProblem: String? {
        do { try assignment?.validate(deviceUID: output.uid); return nil }
        catch { return error.localizedDescription }
    }
    private func discover() {
        discovering = true; error = nil
        let requested = output
        Task {
            defer { discovering = false }
            do {
                guard let device = await state.coreAudio.resolveDeviceWithoutBlockingUI(uid: requested.uid) else { throw SpeakerTopologyError.invalidDeviceUID }
                var found = try await Task.detached(priority: .userInitiated) { try SpeakerTopologyProbe().probe(device) }.value
                guard output.uid == requested.uid else { return }
                found.sampleRate = Double(sampleRate)
                if assignment?.deviceUID != requested.uid || assignment?.hardwareChannelCount != found.declaredChannelCount {
                    assignment = AudioInterfaceConfiguration(deviceUID: requested.uid, hardwareChannelCount: found.declaredChannelCount,
                        outputChannels: [], connectedEndpoint: .custom)
                }
                if topology?.deviceUID != requested.uid { topology = found }
            } catch { self.error = error.localizedDescription }
        }
    }
}
