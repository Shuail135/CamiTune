import AppKit
import CamiTuneDomain
import SwiftUI

@MainActor
struct PluginPickerView: View {
    @ObservedObject var catalog: PluginCatalog
    let onAdd: (AudioPluginDescriptor) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var format = "All"
    @State private var selectedID: String?
    @State private var showFailures = false
    @State private var showFolders = false
    @State private var foldersBeforeEditing: [URL]?
    @State private var selectionMessage: String?
    @State private var addingTask: Task<Void, Never>?

    private func key(_ plugin: AudioPluginDescriptor) -> String { "\(plugin.format.rawValue):\(plugin.id)" }
    private var filtered: [AudioPluginDescriptor] {
        catalog.plugins.filter {
            (format == "All" || $0.format.rawValue == format)
                && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.manufacturer.localizedCaseInsensitiveContains(search)
                    || URL(fileURLWithPath: $0.location).lastPathComponent.localizedCaseInsensitiveContains(search))
        }
    }
    private var selected: AudioPluginDescriptor? { filtered.first { key($0) == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header.fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                pluginList.frame(minHeight: 80, idealHeight: 280, maxHeight: .infinity)
                if let message = selectionMessage ?? catalog.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if !catalog.failures.isEmpty { scanFailures.fixedSize(horizontal: false, vertical: true) }
            }.frame(maxHeight: .infinity)
            footer.fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(minWidth: 600, idealWidth: 700, minHeight: 560, idealHeight: 620)
        .task {
            await catalog.load()
            if catalog.plugins.isEmpty && !catalog.isBusy { catalog.scan() }
        }
        .onChange(of: showFolders) { _ in scanAfterFolderChanges() }
        .onChange(of: catalog.customDirectories) { _ in scanAfterFolderChanges() }
        .onDisappear { addingTask?.cancel(); catalog.cancelScan() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Plug-in").font(.title2.bold()).uiInteractionAnchor("plugin-picker-title")
            Text("Choose an installed effect or instrument. AU and VST3 versions are listed separately.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                Picker("Format", selection: $format) {
                    Text("All").tag("All"); Text("AU").tag("AU"); Text("VST3").tag("VST3")
                }.pickerStyle(.menu).frame(width: 135).uiInteractionAnchor("plugin-picker-format")
                Button("Scan Folders…") {
                    foldersBeforeEditing = catalog.customDirectories
                    showFolders = true
                }
                    .popover(isPresented: $showFolders, arrowEdge: .bottom) { PluginScanFoldersView(catalog: catalog) }
                    .uiInteractionAnchor("plugin-picker-folders")
            }
        }
    }

    private func scanAfterFolderChanges() {
        // The file panel can dismiss the popover before its selection arrives.
        // Check both events, consuming the edit session only when folders changed.
        guard !showFolders, let original = foldersBeforeEditing,
              catalog.customDirectories != original else { return }
        foldersBeforeEditing = nil
        selectionMessage = nil
        catalog.scan()
    }

    private var pluginList: some View {
        List(selection: $selectedID) {
            ForEach(filtered.map { (id: key($0), plugin: $0) }, id: \.id) { row in
                let plugin = row.plugin
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plugin.name).font(.headline)
                        Text(plugin.manufacturer).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(plugin.format.rawValue).font(.caption.weight(.medium))
                        if plugin.isInstrument { Text("Instrument").font(.caption) }
                    }.foregroundStyle(.secondary)
                }.padding(.vertical, 4).contentShape(Rectangle()).tag(row.id)
                    .onTapGesture { selectedID = row.id }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { add(plugin) })
                    .uiInteractionAnchor("plugin-picker-row-\(key(plugin))")
            }
        }
        .disabled(catalog.resolvingName != nil)
        .overlay {
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension").font(.title)
                    Text(catalog.isScanning ? "Finding plug-ins…" : search.isEmpty ? "No plug-ins found" : "No matching plug-ins")
                    if !catalog.isScanning && search.isEmpty {
                        Text("Install a macOS AU or VST3 plug-in, then scan again.").font(.caption)
                    }
                }.foregroundStyle(.secondary).allowsHitTesting(false)
            }
        }
    }

    private var scanFailures: some View {
        DisclosureGroup(isExpanded: $showFailures) {
            // Only the details scroll. The title, filters and action row keep
            // their space when this section expands in a short sheet.
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(catalog.failures.keys.sorted(), id: \.self) { path in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption.bold())
                            Text(catalog.failures[path] ?? "").font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Select a plug-in and choose Add to try it again.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Clear List") { Task { await catalog.clearFailures() } }.disabled(catalog.isBusy)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 100).uiInteractionAnchor("plugin-picker-failure-details")
        } label: {
            Text("\(catalog.failures.count) plug-in bundle(s) could not be scanned")
                .uiInteractionAnchor("plugin-picker-failures")
        }.disclosureGroupStyle(SectionDisclosureStyle())
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Divider()
            HStack(spacing: 10) {
                if catalog.isScanning { Button("Stop Scan") { catalog.cancelScan() } }
                else { Button("Scan Installed Plug-ins") { selectionMessage = nil; catalog.scan() }.disabled(catalog.isBusy) }
                if catalog.isBusy {
                    ProgressView().controlSize(.small).frame(width: 16)
                        .accessibilityLabel(catalog.resolvingName == nil ? "Scanning plug-ins" : "Loading plug-in")
                        .uiInteractionAnchor("plugin-picker-progress")
                    Text(catalog.resolvingName.map { "Loading \($0)…" } ?? catalog.progress)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else { Spacer(minLength: 0) }
                Button("Cancel") { addingTask?.cancel(); catalog.cancelScan(); dismiss() }.keyboardShortcut(.cancelAction)
                    .uiInteractionAnchor("plugin-picker-cancel")
                Button("Add") { if let selected { add(selected) } }
                    .keyboardShortcut(.defaultAction).disabled(selected == nil || catalog.resolvingName != nil || addingTask != nil)
                    .uiInteractionAnchor("plugin-picker-add")
            }.uiInteractionAnchor("plugin-picker-actions")
        }
    }

    private func add(_ plugin: AudioPluginDescriptor) {
        guard addingTask == nil, catalog.resolvingName == nil else { return }
        selectionMessage = nil
        addingTask = Task {
            defer { addingTask = nil }
            do {
                let choices = try await catalog.resolveForAddition(plugin)
                try Task.checkCancellation()
                if choices.count == 1, let effect = choices.first { onAdd(effect) }
                else {
                    format = "VST3"
                    search = URL(fileURLWithPath: plugin.location).deletingPathExtension().lastPathComponent
                    selectedID = nil
                    selectionMessage = "This bundle contains several plug-ins. Select the one to add."
                }
            } catch is CancellationError {} catch {
                if !Task.isCancelled { selectionMessage = error.localizedDescription; showFailures = true }
            }
        }
    }
}

@MainActor
private struct PluginScanFoldersView: View {
    @ObservedObject var catalog: PluginCatalog
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan Folders").font(.headline)
            Text("Standard plug-in locations are included automatically. Add custom VST3 folders below; subfolders are included. Audio Units are discovered through macOS.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(catalog.customDirectories, id: \.path) { url in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).font(.body)
                            Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Button {
                            editing = true
                            Task { await catalog.removeDirectory(url); editing = false }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("Remove \(url.lastPathComponent) from scan folders")
                        .disabled(catalog.isBusy || editing)
                    }.padding(.vertical, 3)
                }
            }.overlay {
                if catalog.customDirectories.isEmpty { Text("No custom folders added").font(.caption).foregroundStyle(.secondary).allowsHitTesting(false) }
            }
            HStack {
                Button("Add Folders…") { chooseFolders() }.disabled(catalog.isBusy || editing)
                Spacer()
                Text("Scans automatically after you close this panel.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).frame(width: 440, height: 310).uiInteractionAnchor("plugin-scan-folders")
    }
    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.title = "Add Plug-in Scan Folders"; panel.prompt = "Add Folders"
        panel.message = "Choose one or more folders containing VST3 plug-ins. Subfolders are scanned too."
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = true; panel.canCreateDirectories = false
        editing = true
        panel.begin { response in
            Task {
                if response == .OK { await catalog.addDirectories(panel.urls) }
                editing = false
            }
        }
    }
}
