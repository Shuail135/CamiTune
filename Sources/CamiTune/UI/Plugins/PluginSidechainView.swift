import CamiTuneDomain
import SwiftUI

@MainActor
struct PluginSidechainView: View {
    let state: AppState
    let profile: DeviceProfile
    let slot: AudioPluginSlot
    let apply: (PluginSidechainSource?, Int?) -> Void
    @ObservedObject private var manager: PluginRackManager
    @ObservedObject private var inputs: PluginSidechainInputs
    @ObservedObject private var applications: PerAppAudioController
    @State private var source: PluginSidechainSource?
    @State private var bus: Int?
    @State private var loading = false
    @State private var error: String?
    @State private var applied = false
    @State private var inspecting = false
    @Environment(\.dismiss) private var dismiss

    init(state: AppState, profile: DeviceProfile, slot: AudioPluginSlot,
         apply: @escaping (PluginSidechainSource?, Int?) -> Void) {
        self.state = state; self.profile = profile; self.slot = slot; self.apply = apply
        _manager = ObservedObject(wrappedValue: state.pluginRackManager)
        _inputs = ObservedObject(wrappedValue: state.pluginRackManager.sidechainInputs)
        _applications = ObservedObject(wrappedValue: state.perAppAudio)
        _source = State(initialValue: slot.sidechain); _bus = State(initialValue: slot.sidechainBus)
    }
    private var capabilities: PluginRackManager.Capabilities? { manager.capabilities[slot.id] }
    private var sourceKey: String {
        guard let source else { return "off" }
        return (source.kind == .application ? "app:" : "input:") + source.id
    }
    private var availableKeys: Set<String> {
        Set(applications.applications.map { "app:" + $0.id } + inputs.devices.map { "input:" + $0.id })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("External Sidechain").font(.headline)
                DeviceCorrectionHelpIcon(title: "External Sidechain", message: "Send another app or an audio input to this plug-in’s detector input. App audio is taken before its volume and EQ; the app must play through CamiTune. Audio inputs are captured only while this rack is active. Missing sources send silence. Enable external sidechain in the plug-in’s own editor if it offers that switch.")
                if loading { ProgressView().controlSize(.small) }
                Spacer()
            }
            if capabilities?.sidechainBuses.isEmpty == true {
                Text("This plug-in does not expose a sidechain input.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Source", selection: Binding(get: { sourceKey }, set: select)) {
                Text("Off").tag("off")
                if !applications.applications.isEmpty {
                    Section("Apps") {
                        ForEach(applications.applications) { app in Text(app.displayName).tag("app:" + app.id) }
                    }
                }
                if !inputs.devices.isEmpty {
                    Section("Audio Inputs") {
                        ForEach(inputs.devices) { input in Text(input.name).tag("input:" + input.id) }
                    }
                }
                if let source, !availableKeys.contains(sourceKey) {
                    Text("\(source.name) · Unavailable").tag(sourceKey)
                }
            }
            .disabled(loading)
            .uiInteractionAnchor("plugin-sidechain-source")
            if let source, source.kind == .audioInput,
               let input = inputs.devices.first(where: { $0.id == source.id }), input.channels > 2 {
                Picker("Input Channels", selection: Binding(get: { source.channelOffset }, set: { self.source?.channelOffset = $0 })) {
                    ForEach(Array(stride(from: 0, to: input.channels, by: 2)), id: \.self) { offset in
                        Text(offset + 1 == input.channels ? "\(offset + 1)" : "\(offset + 1)–\(offset + 2)").tag(offset)
                    }
                }
            }
            if let buses = capabilities?.sidechainBuses, buses.count > 1, source != nil {
                Picker("Plug-in Input", selection: $bus) {
                    Text("Automatic").tag(Int?.none)
                    ForEach(buses) { item in Text(item.name).tag(Optional(item.id)) }
                }
            }
            if let message = error ?? source.flatMap({ inputs.errors[$0.id] }) {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if source?.kind == .audioInput, error == nil {
                    Button("Retry Input") { inputs.retry() }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .uiInteractionAnchor("plugin-sidechain-cancel")
                Button("Apply") { applied = true; apply(source, source == nil ? nil : bus) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || (source != nil && (capabilities == nil || capabilities?.sidechainBuses.isEmpty == true)))
                    .uiInteractionAnchor("plugin-sidechain-apply")
            }
        }
        .padding(16).frame(width: 340)
        .task {
            inputs.refresh()
            guard capabilities == nil else { return }
            loading = true
            defer { loading = false }
            do { inspecting = true; try await manager.openEditor(slot: slot, profile: profile, controlsOnly: true) }
            catch { self.error = error.localizedDescription }
        }
        .onDisappear {
            if inspecting && !applied { Task { _ = await manager.closeControls(slotID: slot.id) } }
        }
    }
    private func select(_ key: String) {
        if let app = applications.applications.first(where: { "app:" + $0.id == key }) {
            source = .init(kind: .application, id: app.id, name: app.displayName)
        } else if let input = inputs.devices.first(where: { "input:" + $0.id == key }) {
            source = .init(kind: .audioInput, id: input.id, name: input.name)
        } else if key == "off" { source = nil }
    }
}
