import CamiTuneDomain
import Foundation
import Combine

struct PluginMIDISource: Identifiable, Equatable, Decodable {
    let id: Int32
    let name: String
}

@MainActor
final class PluginMIDIStatus: ObservableObject {
    @Published var sources: [PluginMIDISource] = []
    @Published var connected = 0
    @Published var message = ""
    @Published var refreshing = false
    func receive(_ event: [String: Any]) {
        if let raw = event["sources"], let data = try? JSONSerialization.data(withJSONObject: raw),
           let updated = try? JSONDecoder().decode([PluginMIDISource].self, from: data), sources != updated { sources = updated }
        if let count = event["connected"] as? Int, connected != count { connected = count }
        if let text = event["message"] as? String, message != text { message = text }
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        do {
            let event = try await Task.detached(priority: .utility) {
                let process = try PluginHostProcess(arguments: ["--midi-sources"]); defer { process.stop() }
                return try process.wait(for: "scan", timeout: 5)
            }.value
            receive(event)
        } catch { message = error.localizedDescription }
    }
}

/// Only the affected parameter row observes live values. The profile editor
/// and mapping list do not subscribe to controller traffic.
@MainActor
final class PluginParameterControl: ObservableObject, Identifiable {
    let id: UInt64
    let name: String
    let minimum: Double
    let maximum: Double
    @Published var value: Double
    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? NSNumber, let name = json["name"] as? String,
              let minimum = json["min"] as? Double, let maximum = json["max"] as? Double,
              let value = json["value"] as? Double, minimum.isFinite, maximum.isFinite, value.isFinite, maximum > minimum else { return nil }
        self.id = id.uint64Value; self.name = name; self.minimum = minimum; self.maximum = maximum; self.value = value
    }
}

@MainActor
final class PluginControlsModel: ObservableObject {
    @Published var parameters: [PluginParameterControl] = []
    @Published var loading = true
    @Published var error: String?
    @Published var learningParameterID: UInt64?
    @Published var choosingInEditor = false
    @Published var mappingActive = false
    @Published var acceptsMIDI = false
    private var lookup: [UInt64: PluginParameterControl] = [:]
    func receive(_ event: [String: Any]) {
        switch event["event"] as? String {
        case "parameters":
            parameters = (event["parameters"] as? [[String: Any]] ?? []).compactMap(PluginParameterControl.init)
            lookup = Dictionary(parameters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            acceptsMIDI = event["acceptsMIDI"] as? Bool ?? false
            loading = false; error = nil
        case "parameterValues":
            for value in event["values"] as? [[String: Any]] ?? [] {
                guard let id = value["id"] as? NSNumber, let updated = value["value"] as? Double, updated.isFinite,
                      let parameter = lookup[id.uint64Value], parameter.value != updated else { continue }
                parameter.value = min(parameter.maximum, max(parameter.minimum, updated))
            }
        default: break
        }
    }
}

@MainActor
extension AppState {
    func togglePluginKeyboardInput(profileID: UUID, slotID: UUID) async throws {
        let profile = try historyProfile(profileID)
        guard profile.pluginRack.slots.contains(where: { $0.id == slotID }) else { return }
        var midi = profile.pluginRack.midi
        if !midi.keyboardInputDisabledSlotIDs.insert(slotID).inserted {
            midi.keyboardInputDisabledSlotIDs.remove(slotID)
        }
        try await commitPluginMIDI(midi, profileID: profileID, action: "Change Plug-in Keyboard Input")
    }

    func commitPluginMIDI(_ configuration: PluginMIDIConfiguration, profileID: UUID, action: String) async throws {
        guard profiles.settingsMutationsAllowed else { throw ProfileSettingsError.busy }
        try configuration.validate()
        var profile = try historyProfile(profileID)
        let before = profile.pluginRack
        guard before.midi != configuration else { return }
        profile.pluginRack.midi = configuration
        profiles.update(profile)
        pluginRackManager.updateMIDI(profileID: profileID, rack: profile.pluginRack)
        history.record(actionName: action, contextName: profile.name, target: .profile(profileID), before: .pluginMIDI(before.midi), after: .pluginMIDI(configuration))
        markPendingEditorApply(profileID)
        try await applyHistoryProfileIfActive(profileID)
    }
    func captureMIDIMapping(profileID: UUID, mapping: PluginMIDIMapping) {
        Task {
            do {
                var midi = try historyProfile(profileID).pluginRack.midi
                // One assignment for this parameter and this hardware control in
                // the slot. Other effects may intentionally share the controller.
                midi.mappings.removeAll { $0.slotID == mapping.slotID && ($0.parameterID == mapping.parameterID
                    || ($0.sourceID == mapping.sourceID && $0.channel == mapping.channel && $0.input == mapping.input && $0.controller == mapping.controller)) }
                midi.mappings.append(mapping)
                try await commitPluginMIDI(midi, profileID: profileID, action: "Learn MIDI Mapping")
            } catch { pluginRackManager.controls(for: mapping.slotID).error = error.localizedDescription }
        }
    }
}
