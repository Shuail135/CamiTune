import CamiTuneDomain
import SwiftUI
import AppKit

@MainActor
struct PluginMIDIInputView: View {
    let state: AppState
    @Binding var profile: DeviceProfile
    @ObservedObject var status: PluginMIDIStatus
    @State private var error: String?
    private func edit(action: String = "Change MIDI Input", _ mutation: @escaping (inout PluginMIDIConfiguration) -> Void) {
        let id = profile.id
        Task {
            do {
                var configuration = try state.historyProfile(id).pluginRack.midi
                mutation(&configuration)
                try await state.commitPluginMIDI(configuration, profileID: id, action: action)
                error = nil
            }
            catch { self.error = error.localizedDescription }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("MIDI input")
                DeviceCorrectionHelpIcon(title: "MIDI input", message: "Activate midi control by clicking the keyboard symbol in the plugin row.")
                Toggle("MIDI input", isOn: Binding(get: { profile.pluginRack.midi.isEnabled }, set: { value in edit { $0.isEnabled = value } }))
                    .labelsHidden().toggleStyle(.switch).uiInteractionAnchor("plugin-midi-enabled")
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Picker("Input", selection: Binding(get: { profile.pluginRack.midi.sourceID ?? 0 }, set: { value in edit { $0.sourceID = value == 0 ? nil : value } })) {
                    Text("All inputs").tag(Int32(0))
                    ForEach(status.sources) { source in Text(source.name).tag(source.id) }
                    if let selected = profile.pluginRack.midi.sourceID, !status.sources.contains(where: { $0.id == selected }) { Text("Disconnected input").tag(selected) }
                }.frame(maxWidth: 280, alignment: .leading)
                    .uiInteractionAnchor("plugin-midi-source")
                Picker("Channel", selection: Binding(get: { profile.pluginRack.midi.channel ?? 0 }, set: { value in edit { $0.channel = value == 0 ? nil : value } })) {
                    Text("All").tag(0)
                    ForEach(1...16, id: \.self) { Text(String($0)).tag($0) }
                }.frame(width: 130)
                Button { Task { await status.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(status.refreshing)
                    .accessibilityLabel("Refresh MIDI inputs")
                Spacer(minLength: 0)
            }.disabled(!profile.pluginRack.midi.isEnabled)
            if profile.pluginRack.midi.isEnabled {
                if status.sources.isEmpty {
                    Label("Connect a MIDI device to begin.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                else if let id = profile.pluginRack.midi.sourceID, !status.sources.contains(where: { $0.id == id }) {
                    Text("Waiting for the selected MIDI input to reconnect.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = error ?? (status.message.isEmpty ? nil : status.message) {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }.task { await status.refresh() }
    }
}

/// Per-slot keyboard playing is separate from profile-wide parameter mappings.
@MainActor
struct PluginMIDIInputButton: View {
    let state: AppState
    let profile: DeviceProfile
    let slot: AudioPluginSlot
    @Binding var error: String?
    @State private var saving = false

    private var selected: Bool {
        profile.pluginRack.midi.receivesKeyboardInput(slotID: slot.id)
            && profile.pluginRack.isEnabled && slot.isEnabled
    }

    var body: some View {
        Button {
            let profileID = profile.id, slotID = slot.id
            saving = true
            Task {
                defer { saving = false }
                do {
                    try await state.togglePluginKeyboardInput(profileID: profileID, slotID: slotID)
                    error = nil
                } catch { self.error = error.localizedDescription }
            }
        } label: {
            Image(systemName: "pianokeys")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 24)
                .background(selected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.borderless)
        .disabled(saving || !profile.pluginRack.midi.isEnabled || !profile.pluginRack.isEnabled || !slot.isEnabled)
        .accessibilityLabel("Keyboard input for \(slot.plugin.name)")
        .accessibilityValue(selected ? "On" : "Off")
        .uiInteractionAnchor("plugin-midi-input-\(slot.id)")
    }
}

/// Observes learning state locally within the mappings window.
@MainActor
struct PluginMapButton: View {
    let state: AppState
    @Binding var profile: DeviceProfile
    let slot: AudioPluginSlot
    @ObservedObject var model: PluginControlsModel
    @State private var starting = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(model.mappingActive ? "Done Mapping" : "Map") {
                if model.mappingActive { state.pluginRackManager.finishMapping(slotID: slot.id) }
                else {
                    starting = true
                    Task {
                        defer { starting = false }
                        do {
                            if !profile.pluginRack.midi.isEnabled {
                                var midi = profile.pluginRack.midi; midi.isEnabled = true
                                try await state.commitPluginMIDI(midi, profileID: profile.id, action: "Enable MIDI Mapping")
                            }
                            if state.pluginEditorHistory[slot.id] == nil { state.pluginEditorHistory[slot.id] = profile.pluginRack }
                            try await state.pluginRackManager.startMapping(slot: slot, profile: profile)
                        } catch { model.error = error.localizedDescription }
                    }
                }
            }
            .foregroundStyle(model.mappingActive ? Color.accentColor : Color.primary)
            .disabled(starting)
            .accessibilityLabel(model.mappingActive ? "Finish mapping \(slot.plugin.name)" : "Map \(slot.plugin.name)")
            .uiInteractionAnchor("plugin-midi-map-\(slot.id)")
            if model.mappingActive {
                Text(model.choosingInEditor ? "Select a plug-in control…" : "Move or press a MIDI control…")
                    .font(.caption).foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 180, alignment: .trailing)
                    .uiInteractionAnchor("plugin-midi-learning")
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 220)
            }
        }
        .onChange(of: profile.pluginRack.midi.isEnabled) { enabled in
            if !enabled { state.pluginRackManager.finishMapping(slotID: slot.id) }
        }
        .onDisappear { state.pluginRackManager.finishMapping(slotID: slot.id) }
    }
}

@MainActor
struct PluginMIDIMappingsView: View {
    let state: AppState
    @Binding var profile: DeviceProfile
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selectedSlotID: UUID?
    @State private var error: String?
    private var selectedSlot: AudioPluginSlot? {
        profile.pluginRack.slots.first { $0.id == selectedSlotID } ?? profile.pluginRack.slots.first
    }
    private var mappings: [PluginMIDIMapping] {
        profile.pluginRack.midi.mappings.filter { mapping in
            let name = profile.pluginRack.slots.first { $0.id == mapping.slotID }?.plugin.name ?? ""
            return search.isEmpty || "\(name) \(mapping.parameterName) \(mapping.sourceName)".localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MIDI Mappings").font(.title2.bold())
                    Text("All Audio Unit and VST3 assignments for this output.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(profile.pluginRack.midi.mappings.count) mapped").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                Picker("Plug-in", selection: Binding(get: { selectedSlot?.id }, set: { selectedSlotID = $0 })) {
                    ForEach(profile.pluginRack.slots) { slot in
                        Text("\(slot.plugin.name) · \(slot.plugin.format.rawValue)").tag(Optional(slot.id))
                    }
                }
                if let slot = selectedSlot {
                    HStack(alignment: .top, spacing: 6) {
                        PluginMapButton(state: state, profile: $profile, slot: slot, model: state.pluginRackManager.controls(for: slot.id))
                            .id(slot.id)
                        DeviceCorrectionHelpIcon(title: "MIDI Mapping", message: "Click Map, select or move a control in the plug-in window, then move a MIDI knob or press a button or note.")
                    }
                }
            }
            Divider()
            TextField("Search plug-ins, parameters or MIDI inputs", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(mappings) { mapping in
                        PluginMIDIMappingRow(mapping: mapping,
                            plugin: profile.pluginRack.slots.first { $0.id == mapping.slotID }?.plugin,
                            update: { editMapping(mapping.id, replacement: $0) },
                            remove: { editMapping(mapping.id, replacement: nil) })
                    }
                    if mappings.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "slider.horizontal.3").font(.largeTitle)
                            Text(search.isEmpty ? "No MIDI mappings yet" : "No matching mappings").font(.headline)
                            Text(search.isEmpty ? "Choose a plug-in above to map your first control." : "Try another plug-in, parameter or input name.")
                                .font(.callout)
                        }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 50)
                    }
                }.padding(2)
            }.frame(minHeight: 200, maxHeight: .infinity)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            Divider()
            HStack {
                Button("Release Notes") {
                    for slot in profile.pluginRack.slots { state.pluginRackManager.control("midiPanic", slotID: slot.id) }
                }
                Spacer()
                Button("Done") { NSApp.keyWindow?.makeFirstResponder(nil); dismiss() }.keyboardShortcut(.defaultAction).uiInteractionAnchor("plugin-midi-done")
            }
        }.padding(24).frame(minWidth: 640, idealWidth: 740, minHeight: 560, idealHeight: 700).focusSection()
    }

    private func editMapping(_ id: UUID, replacement: PluginMIDIMapping?) {
        let profileID = profile.id
        guard let original = profile.pluginRack.midi.mappings.first(where: { $0.id == id }) else { return }
        Task {
            do {
                var midi = try state.historyProfile(profileID).pluginRack.midi
                guard let index = midi.mappings.firstIndex(where: { $0.id == id }) else { return }
                if let replacement {
                    if replacement.lower != original.lower { midi.mappings[index].lower = replacement.lower }
                    if replacement.upper != original.upper { midi.mappings[index].upper = replacement.upper }
                    if replacement.mode != original.mode { midi.mappings[index].mode = replacement.mode }
                    if replacement.curve != original.curve { midi.mappings[index].curve = replacement.curve }
                    if replacement.pickup != original.pickup { midi.mappings[index].pickup = replacement.pickup }
                } else { midi.mappings.remove(at: index) }
                try await state.commitPluginMIDI(midi, profileID: profileID,
                    action: replacement == nil ? "Remove MIDI Mapping" : "Edit MIDI Mapping")
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct PluginMIDIMappingRow: View {
    let mapping: PluginMIDIMapping
    let plugin: AudioPluginDescriptor?
    let update: (PluginMIDIMapping) -> Void
    let remove: () -> Void
    private var continuous: Bool { mapping.mode == .knob || mapping.mode == .velocity }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(mapping.parameterName).font(.headline)
                    Text("\(plugin?.name ?? "Unavailable plug-in") · \(plugin?.format.rawValue ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(mapping.sourceName) · Ch \(mapping.channel) · \(mapping.input == .note ? "Note" : "CC") \(mapping.controller)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: remove) { Image(systemName: "trash").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove mapping for \(mapping.parameterName)")
                    .uiInteractionAnchor("plugin-midi-remove-\(mapping.id)")
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Control", selection: Binding(get: { mapping.mode }, set: { mode in
                        var value = mapping; value.mode = mode; update(value)
                    })) {
                        ForEach(PluginMIDIControlMode.allCases.filter { mapping.input == .note ? $0 != .knob : $0 != .velocity }, id: \.self) {
                            Text($0.title).tag($0)
                        }
                    }.accessibilityLabel("Control mode for \(mapping.parameterName)")
                    HStack(spacing: 6) {
                        Text("Min").font(.caption)
                        PluginMIDIRangeField(title: "Min", value: mapping.lower * 100) { lower in
                            var value = mapping; value.lower = lower / 100; update(value)
                        }
                            .accessibilityLabel("Minimum percent for \(mapping.parameterName)")
                        Text("Max").font(.caption)
                        PluginMIDIRangeField(title: "Max", value: mapping.upper * 100) { upper in
                            var value = mapping; value.upper = upper / 100; update(value)
                        }
                            .accessibilityLabel("Maximum percent for \(mapping.parameterName)")
                        Text("%").font(.caption).foregroundStyle(.secondary)
                    }.textFieldStyle(.roundedBorder)
                    if continuous {
                        Picker("Curve", selection: Binding(get: { mapping.curve }, set: { curve in
                            var value = mapping; value.curve = curve; update(value)
                        })) {
                            ForEach(PluginMIDIResponseCurve.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.accessibilityLabel("Response curve for \(mapping.parameterName)")
                    }
                    if mapping.mode == .knob {
                        Toggle("Pickup", isOn: Binding(get: { mapping.pickup }, set: { pickup in
                            var value = mapping; value.pickup = pickup; update(value)
                        }))
                    } else {
                        Text(mapping.mode == .toggle ? "Each press alternates between Min and Max." : mapping.mode == .button
                            ? "Hold for Max; release for Min." : "Note velocity sets the value; release holds it.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                PluginMIDIResponseGraph(mapping: mapping).frame(width: 190)
            }
        }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .focusSection()
    }
}

/// Each endpoint owns its text draft; editing one never writes the other.
private struct PluginMIDIRangeField: View {
    let title: String
    let value: Double
    let commit: (Double) -> Void
    @State private var draft: String
    @FocusState private var focused: Bool
    private static let format = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.fractionLength(0...2))

    init(title: String, value: Double, commit: @escaping (Double) -> Void) {
        self.title = title; self.value = value; self.commit = commit
        _draft = State(initialValue: value.formatted(Self.format))
    }
    var body: some View {
        TextField(title, text: $draft)
            .monospacedDigit().focused($focused)
            .onSubmit { commitDraft() }
            .onChange(of: focused) { if !$0 { commitDraft() } }
            .onChange(of: value) { if !focused { draft = $0.formatted(Self.format) } }
            .onExitCommand { draft = value.formatted(Self.format); focused = false }
    }
    private func commitDraft() {
        guard let number = try? Double(draft, format: Self.format, lenient: false), number.isFinite else {
            draft = value.formatted(Self.format); return
        }
        let clamped = min(100, max(0, number))
        if clamped != value { commit(clamped) }
        draft = clamped.formatted(Self.format)
    }
}

private struct PluginMIDIResponseGraph: View {
    let mapping: PluginMIDIMapping
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Output %").font(.caption2).foregroundStyle(.secondary)
            Canvas { context, size in
                var grid = Path()
                for step in 0...4 {
                    let x = size.width * Double(step) / 4, y = size.height * Double(step) / 4
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.secondary.opacity(0.16)), lineWidth: 0.5)
                var response = Path()
                for step in 0...128 {
                    let input = Double(step) / 128
                    let point = CGPoint(x: input * size.width, y: (1 - mapping.output(at: input)) * size.height)
                    if step == 0 { response.move(to: point) } else { response.addLine(to: point) }
                }
                context.stroke(response, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }.frame(height: 96).padding(4)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 4))
            HStack {
                Text(mapping.mode == .button || mapping.mode == .toggle ? "Off" : "0")
                Spacer()
                Text(mapping.mode == .velocity ? "Velocity" : mapping.mode == .toggle ? "Toggle state" : mapping.mode == .button ? "Button" : "MIDI input")
                Spacer()
                Text(mapping.mode == .button || mapping.mode == .toggle ? "On" : "127")
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mapping.mode.title) response, \(mapping.curve.title), from \(Int(mapping.lower * 100)) to \(Int(mapping.upper * 100)) percent")
    }
}
