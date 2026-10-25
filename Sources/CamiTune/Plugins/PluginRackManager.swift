import CamiTuneAudio
import CamiTuneDomain
import Foundation
import Combine

@MainActor
final class PluginRackManager: ObservableObject {
    struct SidechainBus: Identifiable, Equatable {
        let id: Int
        let name: String
        let channels: Int
    }
    struct Capabilities: Equatable {
        let instrument: Bool
        let architecture: String
        let sidechainBuses: [SidechainBus]
    }
    struct Status: Equatable {
        var message: String?
        var loading = false
        var latencyMilliseconds: Double = 0
        var active = false
    }
    private final class Prepared {
        let id = UUID()
        let profileID: UUID
        let format: AudioFormatDescriptor
        var sampleRate: Double { Double(format.sampleRate) }
        var rack: PluginRack
        let requestedRack: PluginRack
        let blockFrames: Int
        var session: PluginHostSession?
        var needsReload = false
        init(profileID: UUID, format: AudioFormatDescriptor, rack: PluginRack, blockFrames: Int = PluginHostSession.maximumFrames) {
            self.profileID = profileID; self.format = format.signalSignature; self.rack = rack; self.requestedRack = rack
            self.blockFrames = blockFrames
        }
        func matches(_ plan: AudioRuntimePlan, allowRequested: Bool = false) -> Bool {
            !needsReload && profileID == plan.intent.id && format == plan.dspInputFormat.signalSignature
                && blockFrames == (plan.usesExclusivePluginOutput ? plan.processingGraph.chunkSize : PluginHostSession.maximumFrames)
                && (rack.audioConfiguration == (plan.renderConfiguration.pluginRack ?? PluginRack()).audioConfiguration
                    || (allowRequested && requestedRack.audioConfiguration == (plan.renderConfiguration.pluginRack ?? PluginRack()).audioConfiguration)) && session?.errorMessage == nil
        }
    }
    @Published private(set) var statuses: [UUID: Status] = [:]
    @Published private(set) var openingEditors: Set<UUID> = []
    @Published private(set) var capabilities: [UUID: Capabilities] = [:]
    let sidechainInputs: PluginSidechainInputs
    private let sidechains: PluginSidechainHub
    var stateChanged: ((UUID, UUID, Data) -> Void)?
    var editorClosed: ((UUID, UUID) -> Void)?
    var linkedEditorChanged: ((UUID) -> Void)?
    var midiLearned: ((UUID, PluginMIDIMapping) -> Void)?
    private var controlModels: [UUID: PluginControlsModel] = [:]
    private var midiModels: [UUID: PluginMIDIStatus] = [:]
    private var inspecting: Set<UUID> = []
    // Track the owning session as well as the slot so a retired host cannot
    // close an editor that has already moved to the replacement rack.
    private var nativeEditors: [UUID: UUID] = [:]
    private var closingNativeEditors: Set<UUID> = []
    private var editorPositions: [UUID: [String: Double]] = [:]
    private var active: Prepared?
    private var pending: Prepared?
    // Keep the old prepared rack alive through transactional rollback.
    private var previous: Prepared?
    private var editors: [UUID: Prepared] = [:]
    private var generation: UInt64 = 0

    init(sidechains: PluginSidechainHub = PluginSidechainHub()) {
        self.sidechains = sidechains
        sidechainInputs = PluginSidechainInputs(hub: sidechains)
    }

    func prepare(_ plan: AudioRuntimePlan) async throws {
        if active?.matches(plan) == true { updateMIDI(profileID: plan.intent.id, rack: (plan.renderConfiguration.pluginRack ?? PluginRack())); return }
        if previous?.matches(plan, allowRequested: true) == true { pending = previous; return }
        if pending?.matches(plan, allowRequested: true) == true, !(plan.renderConfiguration.pluginRack ?? PluginRack()).isProcessing || pending?.session != nil { return }
        generation &+= 1; let revision = generation
        let candidate = Prepared(profileID: plan.intent.id, format: plan.dspInputFormat, rack: (plan.renderConfiguration.pluginRack ?? PluginRack()),
            blockFrames: plan.usesExclusivePluginOutput ? plan.processingGraph.chunkSize : PluginHostSession.maximumFrames)
        pending = candidate
        guard candidate.rack.isProcessing else { return }
        statuses[candidate.profileID] = Status(message: "Loading plug-ins…", loading: true,
            latencyMilliseconds: statuses[candidate.profileID]?.latencyMilliseconds ?? 0, active: active?.profileID == candidate.profileID)
        do {
            let session = try await makeSession(candidate)
            session.setSidechainsEnabled(false)
            guard generation == revision, pending === candidate else { throw CancellationError() }
            candidate.session = session
            statuses[candidate.profileID] = Status(latencyMilliseconds: Double(session.latencyFrames) * 1000 / candidate.sampleRate,
                active: active?.profileID == candidate.profileID)
        } catch {
            if generation == revision {
                pending = nil
                statuses[candidate.profileID] = Status(message: error.localizedDescription, active: active?.profileID == candidate.profileID)
            }
            throw error
        }
    }

    func commit(_ plan: AudioRuntimePlan) -> (any PluginAudioProcessor)? {
        if active?.matches(plan) == true { updateMIDI(profileID: plan.intent.id, rack: (plan.renderConfiguration.pluginRack ?? PluginRack())); return active?.session }
        let candidate: Prepared?
        if pending?.matches(plan, allowRequested: true) == true { candidate = pending }
        else if previous?.matches(plan, allowRequested: true) == true { candidate = previous }
        else if !(plan.renderConfiguration.pluginRack ?? PluginRack()).isProcessing {
            candidate = Prepared(profileID: plan.intent.id, format: plan.dspInputFormat, rack: (plan.renderConfiguration.pluginRack ?? PluginRack()),
                blockFrames: plan.usesExclusivePluginOutput ? plan.processingGraph.chunkSize : PluginHostSession.maximumFrames)
        }
        else { return active?.session }
        let old = active
        let oldSlots = nativeEditors.compactMap { slotID, ownerID in ownerID == old?.id ? slotID : nil }
        let openSlots = oldSlots.filter { !closingNativeEditors.contains($0) }
        old?.session?.configureMIDI(.init(), enabled: false)
        old?.session?.setSidechainsEnabled(false)
        old?.session?.closeEditors()
        active = candidate; previous = old; pending = nil
        for id in oldSlots { nativeEditors[id] = nil; closingNativeEditors.remove(id) }
        sidechainInputs.configure(candidate?.rack.activeSlots.compactMap(\.sidechain) ?? [])
        if let old, old.profileID != candidate?.profileID { statuses[old.profileID]?.active = false }
        if let candidate {
            candidate.rack.midi = (plan.renderConfiguration.pluginRack ?? PluginRack()).midi
            candidate.session?.configureMIDI(candidate.rack.midi, enabled: true)
            candidate.session?.setSidechainsEnabled(true)
            statuses[candidate.profileID] = Status(latencyMilliseconds: Double(candidate.session?.latencyFrames ?? 0) * 1000 / candidate.sampleRate,
                active: candidate.session != nil)
            if candidate.profileID == old?.profileID, let session = candidate.session {
                for id in openSlots where candidate.rack.activeSlots.contains(where: { $0.id == id }) {
                    presentEditor(slotID: id, owner: candidate, session: session)
                }
            }
        }
        for editor in editors.values {
            configureEditorMIDI(editor, enabled: editor.profileID == candidate?.profileID)
        }
        return candidate?.session
    }

    /// Called after a successful layout transaction; rollback no longer needs
    /// the retired rack. Dropping the sessions also stops idle helper processes.
    func retireHiddenSection(profileID: UUID) {
        guard active?.profileID != profileID || active?.rack.isProcessing == false else { return }
        if previous?.profileID == profileID { previous = nil }
        if pending?.profileID == profileID { pending = nil }
        for (id, editor) in editors where editor.profileID == profileID {
            editor.session?.configureMIDI(.init(), enabled: false)
            editor.session?.setSidechainsEnabled(false)
            editor.session?.closeEditors()
            editors[id] = nil
            editorClosed?(profileID, id)
        }
    }

    func stop() {
        generation &+= 1
        if let id = active?.profileID { statuses[id] = Status() }
        active?.session?.configureMIDI(.init(), enabled: false)
        active?.session?.setSidechainsEnabled(false)
        for editor in editors.values { editor.session?.configureMIDI(.init(), enabled: false) }
        active = nil; pending = nil; previous = nil
        sidechainInputs.configure([])
    }

    func flushBeforeStopping() async {
        if let profileID = active?.profileID { await flushEditors(profileID: profileID, close: true) }
    }

    /// Termination only. All current hosts share one bounded wait, including
    /// editors for inactive profiles. Their control readers do not need the UI
    /// actor; publish the captured presets synchronously before disk is drained.
    func flushForTermination() {
        let owners = ([active] + editors.values.map(Optional.some)).compactMap { $0 }
        let deadline = Date().addingTimeInterval(1.5)
        let requests = owners.map { ($0, $0.session?.beginSnapshot(close: true) ?? []) }
        for (owner, snapshots) in requests {
            for snapshot in snapshots {
                for (id, data) in snapshot.finish(deadline) {
                    stateChanged?(owner.profileID, id, data)
                }
            }
        }
    }

    func stopForTermination() {
        stop()
        editors.removeAll()
    }

    func openEditor(slot: AudioPluginSlot, profile: DeviceProfile, controlsOnly: Bool = false) async throws {
        guard openingEditors.insert(slot.id).inserted else { return }
        defer { openingEditors.remove(slot.id) }
        func present(_ session: PluginHostSession, owner: Prepared) {
            if controlsOnly {
                inspecting.insert(slot.id)
                session.control(["command": "parameters", "slotID": slot.id.uuidString])
            } else { presentEditor(slotID: slot.id, owner: owner, session: session) }
        }
        let format = try ActiveAudioRoute(profile: profile).dspInputFormat.signalSignature
        if let active, active.profileID == profile.id, active.format == format,
           active.rack.activeSlots.contains(where: { $0.id == slot.id }), let session = active.session,
           session.errorMessage == nil {
            present(session, owner: active); return
        }
        if let editor = editors[slot.id], editor.format == format, let session = editor.session,
           session.errorMessage == nil { present(session, owner: editor); return }
        editors[slot.id]?.session?.closeEditors()
        var enabled = slot; enabled.isEnabled = true
        let editor = Prepared(profileID: profile.id, format: format, rack: PluginRack(isEnabled: true, slots: [enabled], midi: profile.pluginRack.midi))
        editors[slot.id] = editor
        do {
            editor.session = try await makeSession(editor, editorOnly: true)
            configureEditorMIDI(editor, enabled: active == nil || active?.profileID == profile.id)
            if let session = editor.session { present(session, owner: editor) }
        } catch { editors[slot.id] = nil; throw error }
    }

    private func presentEditor(slotID: UUID, owner: Prepared, session: PluginHostSession) {
        nativeEditors[slotID] = owner.id
        closingNativeEditors.remove(slotID)
        var command: [String: Any] = ["command": "editor", "slotID": slotID.uuidString]
        if let position = editorPositions[slotID] { command["position"] = position }
        session.control(command)
    }

    func controls(for slotID: UUID) -> PluginControlsModel {
        if let model = controlModels[slotID] { return model }
        let model = PluginControlsModel(); controlModels[slotID] = model; return model
    }
    func midiStatus(for profileID: UUID) -> PluginMIDIStatus {
        if let model = midiModels[profileID] { return model }
        let model = PluginMIDIStatus(); midiModels[profileID] = model; return model
    }
    func updateMIDI(profileID: UUID, rack: PluginRack) {
        let owners = ([active, pending] + editors.values.map(Optional.some)).compactMap { $0 }.filter { $0.profileID == profileID }
        for owner in owners {
            guard owner.rack.midi != rack.midi else { continue }
            owner.rack.midi = rack.midi
            if editors.values.contains(where: { $0 === owner }) {
                configureEditorMIDI(owner, enabled: active == nil || active?.profileID == profileID)
            } else {
                owner.session?.configureMIDI(rack.midi, enabled: owner === active)
            }
        }
    }
    private func configureEditorMIDI(_ editor: Prepared, enabled: Bool) {
        var configuration = editor.rack.midi
        // Preview editors can learn mappings, but only the active audio rack
        // receives program changes (including when a bypassed slot is open).
        configuration.programChangeSlotID = nil
        editor.session?.configureMIDI(configuration, enabled: enabled)
    }
    private func controlSession(_ slotID: UUID) -> PluginHostSession? {
        if let active, active.rack.activeSlots.contains(where: { $0.id == slotID }), active.session?.errorMessage == nil { return active.session }
        return editors[slotID]?.session
    }
    func control(_ command: String, slotID: UUID, values: [String: Any] = [:]) {
        var message = values; message["command"] = command; message["slotID"] = slotID.uuidString
        controlSession(slotID)?.control(message)
    }
    func startMapping(slot: AudioPluginSlot, profile: DeviceProfile) async throws {
        for id in Array(controlModels.keys) where controlModels[id]?.mappingActive == true { finishMapping(slotID: id) }
        let model = controls(for: slot.id)
        model.loading = true; model.error = nil
        do {
            try await openEditor(slot: slot, profile: profile)
            try await openEditor(slot: slot, profile: profile, controlsOnly: true)
            model.mappingActive = true
            model.choosingInEditor = true
            control("watchParameter", slotID: slot.id)
        } catch {
            model.loading = false; model.error = error.localizedDescription
            throw error
        }
    }
    func learn(slotID: UUID, parameterID: UInt64) {
        let model = controls(for: slotID); model.choosingInEditor = false; model.learningParameterID = parameterID
        control("learnMIDI", slotID: slotID, values: ["parameterID": parameterID])
    }
    func cancelLearn(slotID: UUID) {
        let model = controls(for: slotID); model.learningParameterID = nil; model.choosingInEditor = false; model.mappingActive = false
        control("cancelMIDILearn", slotID: slotID)
    }
    func finishMapping(slotID: UUID) {
        guard controlModels[slotID]?.mappingActive == true else { return }
        cancelLearn(slotID: slotID)
        control("endParameters", slotID: slotID)
        inspecting.remove(slotID)
        if nativeEditors[slotID] == nil { editors[slotID] = nil }
    }
    func closeControls(slotID: UUID) async -> Bool {
        if let owner = editors[slotID] ?? active { await flushEditors(profileID: owner.profileID, close: false) }
        cancelLearn(slotID: slotID); control("endParameters", slotID: slotID)
        inspecting.remove(slotID)
        if nativeEditors[slotID] == nil { editors[slotID] = nil; return true }
        return false
    }

    func flushEditors(profileID: UUID, close: Bool) async {
        let owners = ([active] + editors.values.map(Optional.some)).compactMap { $0 }.filter { $0.profileID == profileID }
        for owner in owners {
            guard let session = owner.session else { continue }
            for (id, data) in await session.snapshot(close: close) {
                if let index = owner.rack.slots.firstIndex(where: { $0.id == id }) { owner.rack.slots[index].state = data }
                stateChanged?(profileID, id, data)
            }
        }
    }

    private func makeSession(_ prepared: Prepared, editorOnly: Bool = false) async throws -> PluginHostSession {
        let rack = prepared.rack, rate = prepared.sampleRate, token = prepared.id, blockFrames = prepared.blockFrames
        let hub = sidechains
        let roles = prepared.format.channels.map { $0.role ?? .unknown }
        return try await Task.detached(priority: .userInitiated) { [weak self] in
            try PluginHostSession(rack: rack, sampleRate: rate, channelRoles: roles, editorOnly: editorOnly, blockFrames: blockFrames, sidechainHub: hub) { [weak self] event in
                Task { @MainActor [weak self] in self?.receive(event, token: token) }
            }
        }.value
    }

    private func receive(_ event: [String: Any], token: UUID) {
        guard let owner = ([active, pending] + editors.values.map(Optional.some)).compactMap({ $0 }).first(where: { $0.id == token }) else { return }
        switch event["event"] as? String {
        case "editorClosing":
            guard let text = event["slotID"] as? String, let id = UUID(uuidString: text),
                  nativeEditors[id] == owner.id else { return }
            closingNativeEditors.insert(id)
        case "editorPosition":
            guard let text = event["slotID"] as? String, let id = UUID(uuidString: text),
                  nativeEditors[id] == owner.id,
                  let position = event["position"] as? [String: Double],
                  let x = position["x"], let y = position["y"], x.isFinite, y.isFinite else { return }
            editorPositions[id] = ["x": x, "y": y]
        case "ready":
            for value in event["capabilities"] as? [[String: Any]] ?? [] {
                guard let text = value["slotID"] as? String, let id = UUID(uuidString: text) else { continue }
                capabilities[id] = Capabilities(instrument: value["instrument"] as? Bool ?? false,
                    architecture: event["architecture"] as? String ?? "",
                    sidechainBuses: (value["sidechainBuses"] as? [[String: Any]] ?? []).compactMap { bus in
                        guard let index = bus["index"] as? Int else { return nil }
                        return SidechainBus(id: index, name: bus["name"] as? String ?? "Sidechain", channels: bus["channels"] as? Int ?? 2)
                    })
            }
        case "midiStatus", "midiWarning":
            midiStatus(for: owner.profileID).receive(event)
        case "parameters", "parameterValues":
            guard let text = event["slotID"] as? String, let slotID = UUID(uuidString: text), inspecting.contains(slotID) else { return }
            controls(for: slotID).receive(event)
        case "parameterTouched":
            guard let text = event["slotID"] as? String, let slotID = UUID(uuidString: text),
                  let id = event["parameterID"] as? NSNumber, controls(for: slotID).choosingInEditor else { return }
            learn(slotID: slotID, parameterID: id.uint64Value)
        case "midiLearned":
            guard let text = event["slotID"] as? String, let slotID = UUID(uuidString: text),
                  let id = event["parameterID"] as? NSNumber, controls(for: slotID).learningParameterID == id.uint64Value,
                  let source = event["sourceID"] as? Int32, let channel = event["channel"] as? Int, let cc = event["controller"] as? Int else { return }
            controls(for: slotID).learningParameterID = nil
            midiLearned?(owner.profileID, .init(slotID: slotID, parameterID: id.uint64Value,
                parameterName: event["parameterName"] as? String ?? "Parameter", sourceID: source,
                sourceName: event["sourceName"] as? String ?? "MIDI input", channel: channel, controller: cc,
                pickup: event["input"] as? String != "note",
                input: event["input"] as? String == "note" ? .note : .controller,
                mode: event["input"] as? String == "note" ? .toggle : .knob))
            if controls(for: slotID).mappingActive {
                controls(for: slotID).choosingInEditor = true
                control("watchParameter", slotID: slotID)
            }
        case "loading":
            if pending === owner {
                statuses[owner.profileID]?.message = "Loading \(event["name"] as? String ?? "plug-in")…"
                statuses[owner.profileID]?.loading = true
            }
        case "fault", "error", "snapshotError":
            statuses[owner.profileID] = Status(message: event["message"] as? String ?? "The plug-in stopped responding.", active: active === owner)
            if active === owner, event["event"] as? String != "snapshotError" {
                owner.session?.setSidechainsEnabled(false)
                sidechainInputs.configure([])
            }
            for slot in owner.rack.slots where inspecting.contains(slot.id) {
                let model = controls(for: slot.id)
                model.error = event["message"] as? String ?? "The plug-in stopped responding."
                model.loading = false; model.learningParameterID = nil; model.choosingInEditor = false; model.mappingActive = false
            }
        case "latency":
            if active === owner {
                statuses[owner.profileID]?.latencyMilliseconds = Double(event["latencyFrames"] as? Int ?? 0) * 1000 / owner.sampleRate
            }
        case "state":
            guard let text = event["slotID"] as? String, let id = UUID(uuidString: text),
                  let encoded = event["state"] as? String, let data = Data(base64Encoded: encoded), data.count <= PluginRack.maximumStateBytes,
                  let index = owner.rack.slots.firstIndex(where: { $0.id == id }) else { return }
            owner.rack.slots[index].state = data
            stateChanged?(owner.profileID, id, data)
        case "editorClosed":
            guard let text = event["slotID"] as? String, let id = UUID(uuidString: text) else { return }
            guard nativeEditors[id] == owner.id else { return }
            // A native editor may load samples/presets that have no parameter
            // events. Prepare new linked copies from the complete captured
            // preset instead of mutating live render instances on the UI thread.
            var reloadLinked = false
            if event["requiresReload"] as? Bool == true,
               let encoded = event["state"] as? String, let data = Data(base64Encoded: encoded),
               data.count <= PluginRack.maximumStateBytes,
               let index = owner.rack.slots.firstIndex(where: { $0.id == id }) {
                owner.rack.slots[index].state = data
                stateChanged?(owner.profileID, id, data)
                owner.needsReload = true
                reloadLinked = owner === active
            }
            if controls(for: id).mappingActive {
                cancelLearn(slotID: id)
                control("endParameters", slotID: id)
                inspecting.remove(id)
            }
            editorClosed?(owner.profileID, id)
            nativeEditors[id] = nil
            closingNativeEditors.remove(id)
            if editors[id] === owner, !inspecting.contains(id) { editors[id] = nil }
            if reloadLinked { linkedEditorChanged?(owner.profileID) }
        default: break
        }
    }
}
