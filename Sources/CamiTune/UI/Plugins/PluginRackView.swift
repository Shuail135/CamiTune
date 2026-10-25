import CamiTuneDomain
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
struct PluginRackView: View {
    let state: AppState
    @Binding var profile: DeviceProfile
    @ObservedObject private var manager: PluginRackManager
    @ObservedObject private var catalog: PluginCatalog
    @ObservedObject private var reorderApplies: PluginRackReorderApply
    @State private var showingPicker = false
    @State private var showingMappings = false
    @State private var showingMIDI = false
    @State private var sidechainSlotID: UUID?
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var confirmingExclusiveOutput = false
    @StateObject private var reorder = PluginRackReorderCoordinator()
    // An actual image reserves native menu geometry; Color.clear labels collapse
    // when SwiftUI converts them to an AppKit menu button.
    private static let optionsMenuImage = NSImage(size: .init(width: 36, height: 24), flipped: false) { _ in true }

    init(state: AppState, profile: Binding<DeviceProfile>) {
        self.state = state; _profile = profile
        _manager = ObservedObject(wrappedValue: state.pluginRackManager)
        _catalog = ObservedObject(wrappedValue: state.pluginCatalog)
        _reorderApplies = ObservedObject(wrappedValue: state.pluginReorderApplies)
    }
    private var status: PluginRackManager.Status { manager.statuses[profile.id] ?? .init() }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("Plug-ins(Beta)").font(.title3.bold())
                    DeviceCorrectionHelpIcon(title: "Plug-ins", message: "Support AU and VST3 plugins.")
                        .uiInteractionAnchor("plugin-rack-help")
                    Spacer().overlay(alignment: .leading) {
                        if busy || status.loading || reorderApplies.applying.contains(profile.id) {
                            ProgressView().controlSize(.small).frame(width: 14, height: 14)
                                .accessibilityLabel("Applying plug-ins")
                                .uiInteractionAnchor("plugin-rack-progress")
                                .allowsHitTesting(false)
                        }
                    }
                    Button { showingPicker = true } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                        .buttonStyle(.borderless)
                        .disabled(busy || profile.pluginRack.slots.count >= PluginRack.maximumSlots)
                        .accessibilityLabel("Add Plug-in")
                        .accessibilityIdentifier("plugin-rack-add")
                        .uiInteractionAnchor("plugin-rack-add")
                    Toggle("Enable rack", isOn: Binding(get: { profile.pluginRack.isEnabled }, set: { value in
                        edit("\(value ? "Enable" : "Bypass") Plug-in Rack") { $0.isEnabled = value }
                    }))
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(busy)
                    .accessibilityIdentifier("plugin-rack-enabled")
                }.uiInteractionAnchor("plugin-rack-header")
                Label(profile.pluginRack.slots.isEmpty
                    ? "Press + to add AU or VST3 Plugin"
                    : "Press ⌘ and drag a plug-in to reorder.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                if status.active, status.latencyMilliseconds > 0 {
                    HStack {
                        Spacer()
                        Text(String(format: "Plug-in delay: %.1f ms", status.latencyMilliseconds))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !profile.pluginRack.slots.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(profile.pluginRack.slots.enumerated()), id: \.element.id) { index, slot in
                            VStack(spacing: 0) {
                                if index > 0 {
                                    Divider()
                                        .uiInteractionAnchor("plugin-divider-\(index)")
                                        .overlay { if insertionIndex == index { insertionMarker } }
                                        .padding(.vertical, 8)
                                }
                                rackRow(slot, index: index)
                            }
                            // Include the divider in the native destination so dropping
                            // directly on the insertion line also works.
                            .overlay { dragSource(slot) }
                        }
                    }
                    .overlay(alignment: .top) { if insertionIndex == 0 { insertionMarker } }
                    .overlay(alignment: .bottom) { if insertionIndex == profile.pluginRack.slots.count { insertionMarker } }
                    .padding(10)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Output mode", selection: Binding(get: { profile.pluginRack.outputMode }, set: { mode in
                        changeOutputMode(mode)
                    })) {
                        ForEach(PluginOutputMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                    }
                    .disabled(busy)
                    .fixedSize(horizontal: true, vertical: false)
                    if profile.pluginRack.outputMode == .exclusive {
                        ResponsiveStackLayout(minimumHorizontalWidth: 420, horizontalSpacing: 12, verticalSpacing: 6) {
                            HStack(spacing: 6) {
                                Text("Buffer Size")
                                DeviceCorrectionHelpIcon(title: "Exclusive Plug-in Buffer Size", message: " Smaller buffers reduce latency; increase the size if audio crackles.")
                            }
                            HStack {
                                Picker("Exclusive Plug-in Buffer", selection: Binding(get: { profile.pluginRack.exclusiveBufferSize }, set: { frames in
                                    edit("Change Plug-in Buffer Size") { $0.exclusiveBufferSize = frames }
                                })) {
                                    ForEach(DeviceProfile.audioBufferSizes, id: \.self) { frames in
                                        Text("\(frames) samples").tag(frames)
                                    }
                                }
                                .labelsHidden().disabled(busy)
                                .fixedSize(horizontal: true, vertical: false)
                                .accessibilityIdentifier("plugin-audio-buffer")
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                if !profile.pluginRack.slots.isEmpty {
                    DisclosureGroup("MIDI", isExpanded: $showingMIDI) {
                        PluginMIDIInputView(state: state, profile: $profile, status: manager.midiStatus(for: profile.id))
                            .padding(.top, 6)
                        Button { showingMappings = true } label: {
                            Label("MIDI Mappings (\(profile.pluginRack.midi.mappings.count))", systemImage: "slider.horizontal.3")
                        }
                        .padding(.top, 6)
                        .uiInteractionAnchor("plugin-midi-mappings")
                    }.disclosureGroupStyle(SectionDisclosureStyle())
                }
                if let message = errorMessage ?? (status.loading ? nil : status.message) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        if profile.pluginRack.isProcessing {
                            Button("Bypass Rack") { edit("Bypass Plug-in Rack") { $0.isEnabled = false } }
                                .disabled(busy)
                        }
                    }.accessibilityIdentifier("plugin-rack-error")
                }
            }.padding(6).uiInteractionAnchor("plugin-rack-content")
        }
        .focusSection()
        .task { await catalog.load() }
        .onAppear { configureReordering() }
        .onChange(of: profile.pluginRack.slots.map(\.id)) { _ in configureReordering() }
        .onChange(of: busy) { _ in configureReordering() }
        .onDisappear { reorder.reset(); reorderApplies.setDragging(false, profileID: profile.id) }
        .sheet(isPresented: $showingPicker) {
            PluginPickerView(catalog: catalog) { plugin in
                showingPicker = false
                edit("Add \(plugin.name)") {
                    $0.slots.append(AudioPluginSlot(plugin: plugin))
                }
            }
        }
        .sheet(isPresented: $showingMappings) {
            PluginMIDIMappingsView(state: state, profile: $profile)
        }
        .alert("Switch to Exclusive Mode?", isPresented: $confirmingExclusiveOutput) {
            Button("Switch to Exclusive") {
                edit("Change Plug-in Output Mode") { $0.outputMode = .exclusive }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Exclusive mode disables native audio processing, including your enabled processing sections. Their controls will be hidden and your saved settings will be kept. Switch back to Through CamillaDSP to restore them.")
        }
    }

    private func changeOutputMode(_ mode: PluginOutputMode) {
        guard !busy, mode != profile.pluginRack.outputMode else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        let nativeSections: [ProfileSection] = [.mode, .equalizer, .deviceCorrection, .perChannel, .multichannel, .subwooferControl]
        if mode == .exclusive, nativeSections.contains(where: { state.sectionNeedsDisableConfirmation($0, profile: profile) }) {
            confirmingExclusiveOutput = true
        } else {
            edit("Change Plug-in Output Mode") { $0.outputMode = mode }
        }
    }

    private func rackRow(_ slot: AudioPluginSlot, index: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
                HStack(spacing: 6) {
                    Text(slot.plugin.name).font(.headline).lineLimit(2)
                        .uiInteractionAnchor("plugin-title-\(slot.id)")
                    Button {
                        Task {
                            do { try await state.openPluginEditor(slot: slot, profile: profile) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    } label: {
                        Image(systemName: "arrow.up.forward.app").frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .disabled(busy || manager.openingEditors.contains(slot.id))
                    .accessibilityLabel("Open \(slot.plugin.name) editor")
                    .uiInteractionAnchor("plugin-editor-\(slot.id)")
                }
                Spacer(minLength: 4)
            }
            HStack(spacing: 10) {
                PluginMIDIInputButton(state: state, profile: profile, slot: slot, error: $errorMessage)
                    .disabled(busy)
                Toggle("Enable \(slot.plugin.name)", isOn: Binding(get: { slot.isEnabled }, set: { value in
                    edit("\(value ? "Enable" : "Bypass") \(slot.plugin.name)") { rack in
                        if let index = rack.slots.firstIndex(where: { $0.id == slot.id }) { rack.slots[index].isEnabled = value }
                    }
                }))
                .labelsHidden().toggleStyle(.switch)
                .disabled(busy)
                presetMenu(slot)
            }
        }
        .opacity(slot.isEnabled && profile.pluginRack.isEnabled ? 1 : 0.65)
    }

    private var insertionIndex: Int? {
        guard let target = reorder.target,
              let index = profile.pluginRack.slots.firstIndex(where: { $0.id == target.id }) else { return nil }
        return index + (target.after ? 1 : 0)
    }
    private var insertionMarker: some View {
        Rectangle().fill(Color.accentColor).frame(height: 2)
            .uiInteractionAnchor("plugin-reorder-marker").allowsHitTesting(false)
    }

    private func dragSource(_ slot: AudioPluginSlot) -> some View {
        PluginRackDragSource(id: slot.id, name: slot.plugin.name, coordinator: reorder)
            .accessibilityHidden(true)
    }

    private func presetMenu(_ slot: AudioPluginSlot) -> some View {
        Menu {
            Button("Save Preset…") { savePreset(slot) }.disabled(busy)
            Button("Load Preset…") { loadPreset(slot) }.disabled(busy)
            Button("Reset to Default") { edit("Reset \(slot.plugin.name)") { rack in
                if let index = rack.slots.firstIndex(where: { $0.id == slot.id }) { rack.slots[index].state = nil }
            }}.disabled(busy)
            Divider()
            Button("Sidechain…") { sidechainSlotID = slot.id }.disabled(busy)
            Divider()
            Button("Remove Plug-in", role: .destructive) {
                edit("Remove \(slot.plugin.name)") {
                    $0.slots.removeAll { $0.id == slot.id }
                    $0.midi.mappings.removeAll { $0.slotID == slot.id }
                    $0.midi.keyboardInputDisabledSlotIDs.remove(slot.id)
                    if $0.midi.programChangeSlotID == slot.id { $0.midi.programChangeSlotID = nil }
                }
            }.disabled(busy).accessibilityIdentifier("plugin-remove-\(slot.id)")
        } label: {
            Image(nsImage: Self.optionsMenuImage).contentShape(Rectangle())
        }
        // Keep native hit testing and focus feedback; draw the symbols separately
        // so focus cannot dim them independently of the rack switches.
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .overlay {
            HStack(spacing: 3) {
                Image(systemName: "ellipsis")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.primary)
            .allowsHitTesting(false)
        }
        .accessibilityLabel("Options for \(slot.plugin.name)")
        .uiInteractionAnchor("plugin-presets-\(slot.id)")
        .popover(isPresented: Binding(get: { sidechainSlotID == slot.id }, set: { if !$0 { sidechainSlotID = nil } }), arrowEdge: .bottom) {
            PluginSidechainView(state: state, profile: profile, slot: slot) { source, bus in
                sidechainSlotID = nil
                edit("Change \(slot.plugin.name) Sidechain") { rack in
                    if let index = rack.slots.firstIndex(where: { $0.id == slot.id }) {
                        rack.slots[index].sidechain = source; rack.slots[index].sidechainBus = bus
                    }
                }
            }
        }
    }

    private func edit(_ action: String, mutation: @escaping (inout PluginRack) -> Void) {
        guard !busy else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        let profileID = profile.id
        busy = true; errorMessage = nil
        Task {
            defer { busy = false }
            do {
                await state.pluginRackManager.flushEditors(profileID: profileID, close: true)
                var rack = try state.historyProfile(profileID).pluginRack
                mutation(&rack)
                try await state.commitPluginRack(rack, profileID: profileID, action: action)
            }
            catch { errorMessage = error.localizedDescription }
        }
    }
    private func configureReordering() {
        reorder.draggingChanged = { reorderApplies.setDragging($0, profileID: profile.id) }
        reorder.configure(ids: profile.pluginRack.slots.map(\.id), enabled: !busy) { source, target, after in
            move(source, relativeTo: target, after: after)
        }
    }
    private func move(_ id: UUID, relativeTo target: UUID, after: Bool) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        do { try state.movePlugin(id, relativeTo: target, after: after, profileID: profile.id); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    private struct Preset: Codable { let version: Int; let pluginID: String; let format: AudioPluginFormat; let state: Data? }
    private func savePreset(_ slot: AudioPluginSlot) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = slot.plugin.name + ".camipreset"
        panel.allowedContentTypes = [UTType(filenameExtension: "camipreset") ?? .data]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                await manager.flushEditors(profileID: profile.id, close: false)
                let current = profile.pluginRack.slots.first { $0.id == slot.id } ?? slot
                let preset = Preset(version: 1, pluginID: current.plugin.id, format: current.plugin.format, state: current.state)
                do {
                    try await Task.detached(priority: .utility) { try JSONEncoder().encode(preset).write(to: url, options: .atomic) }.value
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }
    private func loadPreset(_ slot: AudioPluginSlot) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "camipreset") ?? .data]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let preset = try await Task.detached(priority: .utility) {
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= PluginRack.maximumStateBytes * 2 else { throw PluginHostError(message: "This preset is too large.") }
                        return try JSONDecoder().decode(Preset.self, from: Data(contentsOf: url))
                    }.value
                    guard preset.version == 1, preset.pluginID == slot.plugin.id, preset.format == slot.plugin.format else {
                        throw PluginHostError(message: "This preset belongs to a different plug-in.")
                    }
                    edit("Load \(slot.plugin.name) Preset") { rack in
                        if let index = rack.slots.firstIndex(where: { $0.id == slot.id }) { rack.slots[index].state = preset.state }
                    }
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }
}
