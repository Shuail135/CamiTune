import CamiTuneDomain
import Foundation
import Combine

/// Persist each move immediately; only snapshot and apply after arranging stops.
/// Waiting timers may be cancelled, but an audio transaction already in flight
/// finishes normally. Further moves are collected for one subsequent apply.
@MainActor
final class PluginRackReorderApply: ObservableObject {
    @Published private(set) var applying: Set<UUID> = []
    private var pending: [UUID: UUID] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var dragging: Set<UUID> = []
    private let delay: Duration
    private let apply: (UUID, @escaping @MainActor () -> Bool) async -> Bool

    init(delay: Duration = .seconds(1), apply: @escaping (UUID, @escaping @MainActor () -> Bool) async -> Bool) {
        self.delay = delay; self.apply = apply
    }
    func schedule(_ profileID: UUID) {
        pending[profileID] = UUID()
        arm(profileID)
    }
    func setDragging(_ value: Bool, profileID: UUID) {
        if value { dragging.insert(profileID) } else { dragging.remove(profileID) }
        arm(profileID)
    }
    func cancelPending(_ profileID: UUID? = nil) {
        if let profileID {
            pending[profileID] = nil
            timers.removeValue(forKey: profileID)?.cancel()
        } else {
            pending.removeAll()
            timers.values.forEach { $0.cancel() }
            timers.removeAll()
        }
    }
    private func arm(_ id: UUID) {
        timers.removeValue(forKey: id)?.cancel()
        guard let revision = pending[id], !dragging.contains(id), !applying.contains(id) else { return }
        let delay = delay
        timers[id] = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.pending[id] == revision, !self.dragging.contains(id) else { return }
            self.timers[id] = nil
            self.applying.insert(id)
            let consumed = await self.apply(id) { [weak self] in
                self?.pending[id] == revision && self?.dragging.contains(id) == false
            }
            if consumed, self.pending[id] == revision { self.pending[id] = nil }
            self.applying.remove(id)
            self.arm(id)
        }
    }
}

@MainActor
extension AppState {
    func commitAudioBufferSize(_ frames: AudioBufferSetting?, profileID: UUID) async throws {
        let profile = try historyProfile(profileID)
        let previous = profile.audioBufferOverride
        guard previous != frames else { return }
        var draft = ProfileSettingsDraft(profile: profile, activation: profiles.activationMode(for: profile))
        draft.audioBufferOverride = frames
        try await saveProfileSettings(draft)
        history.record(actionName: "Change Buffer Size", contextName: profile.name, target: .profile(profileID),
            before: .audioBuffer(previous), after: .audioBuffer(frames))
    }

    func commitPluginRack(_ rack: PluginRack, profileID: UUID, action: String) async throws {
        guard profiles.settingsMutationsAllowed else { throw ProfileSettingsError.busy }
        try rack.validate()
        var profile = try historyProfile(profileID)
        _ = try ActiveAudioRoute(profile: profile)
        let before = profile.pluginRack
        guard before != rack else { return }
        pluginReorderApplies.cancelPending(profileID)
        profile.pluginRack = rack
        profiles.update(profile)
        history.record(actionName: action, contextName: profile.name, target: .profile(profileID), before: .pluginRack(before), after: .pluginRack(rack))
        markPendingEditorApply(profileID)
        try await applyHistoryProfileIfActive(profileID)
    }

    func movePlugin(_ id: UUID, relativeTo target: UUID, after: Bool, profileID: UUID) throws {
        guard !history.isReplaying else { throw HistoryRestoreError.busy }
        var order = try historyProfile(profileID).pluginRack.slots.map(\.id)
        guard id != target, let sourceIndex = order.firstIndex(of: id), order.contains(target) else { return }
        order.remove(at: sourceIndex)
        guard let targetIndex = order.firstIndex(of: target) else { return }
        order.insert(id, at: targetIndex + (after ? 1 : 0))
        let profile = try historyProfile(profileID)
        let before = profile.pluginRack.slots.map(\.id)
        guard before != order else { return }
        try storePluginOrder(order, profileID: profileID)
        history.record(actionName: "Reorder Plug-ins", contextName: profile.name, target: .profile(profileID),
            before: .pluginOrder(before), after: .pluginOrder(order))
        pluginReorderApplies.schedule(profileID)
    }

    /// Order history never restores stale parameter states or MIDI mappings.
    func storePluginOrder(_ order: [UUID], profileID: UUID) throws {
        guard profiles.settingsMutationsAllowed else { throw ProfileSettingsError.busy }
        var profile = try historyProfile(profileID)
        let slots = profile.pluginRack.slots
        guard order.count == slots.count, Set(order).count == order.count,
              Set(order) == Set(slots.map(\.id)) else { throw HistoryRestoreError.invalidStateForTarget }
        let byID = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
        profile.pluginRack.slots = order.compactMap { byID[$0] }
        profiles.update(profile)
    }

    func capturePluginState(profileID: UUID, slotID: UUID, data: Data) {
        guard var profile = try? historyProfile(profileID), let index = profile.pluginRack.slots.firstIndex(where: { $0.id == slotID }),
              data.count <= PluginRack.maximumStateBytes, profile.pluginRack.slots[index].state != data else { return }
        profile.pluginRack.slots[index].state = data
        profiles.update(profile)
    }

    func openPluginEditor(slot: AudioPluginSlot, profile: DeviceProfile) async throws {
        if pluginEditorHistory[slot.id] == nil { pluginEditorHistory[slot.id] = profile.pluginRack }
        try await pluginRackManager.openEditor(slot: slot, profile: profile)
    }

    func finishPluginEditor(profileID: UUID, slotID: UUID) {
        guard let before = pluginEditorHistory.removeValue(forKey: slotID), let profile = try? historyProfile(profileID) else { return }
        // Only the edited slot participates in this history entry; concurrent
        // changes to other slots or their order are preserved.
        var previous = profile.pluginRack
        if let old = before.slots.first(where: { $0.id == slotID }), let index = previous.slots.firstIndex(where: { $0.id == slotID }) {
            previous.slots[index].state = old.state
        }
        history.record(actionName: "Edit Plug-in", contextName: profile.name, target: .profile(profileID), before: .pluginRack(previous), after: .pluginRack(profile.pluginRack))
    }
}
