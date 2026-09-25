import CamiTuneDomain
import Foundation

/// Scripted HAL, including listener installation races and a manually advanced clock.
/// No production defaults are used by these tests.
final class DiagnosticCoreAudioWorld: @unchecked Sendable {
    struct State {
        var outputs = [AudioDeviceInfo(id: "physical", objectID: 10, name: "Physical"), AudioDeviceInfo(id: AudioDeviceInfo.systemAudioBridgeUID, objectID: 20, name: "Bridge")]
        var defaultUID: String? = "physical"
        var rate: Double = 48_000
        var calls = 0
        var enumerations = 0
        var blockEnumeration: DispatchSemaphore?
        var onSubscribe: (@Sendable () -> Void)?
        var listeners: [UUID: (CoreAudioEvent, @Sendable () -> Void)] = [:]
        var timers: [UUID: (Duration, @Sendable () -> Void)] = [:]
        var setDefaultImmediately = true
        var setRateImmediately = true
        var writes: [UInt32] = []
        var removed = 0
        var postWriteReads = 0
    }
    private let lock = NSLock()
    private var state = State()
    @discardableResult func update<T>(_ body: (inout State) -> T) -> T { lock.withLock { body(&state) } }
    func emit(_ event: CoreAudioEvent) {
        let callbacks = update { $0.listeners.values.filter { $0.0 == event }.map { $0.1 } }
        callbacks.forEach { $0() }
    }
    func tick() {
        let callbacks: [@Sendable () -> Void] = update { state in
            guard let next = state.timers.values.map(\.0).min() else { return [] }
            let due = state.timers.filter { $0.value.0 == next }
            due.keys.forEach { state.timers.removeValue(forKey: $0) }
            return due.values.map(\.1)
        }
        callbacks.forEach { $0() }
    }
    var backend: CoreAudioHALBackend {
        .init(enumerateOutputs: {
            let (outputs, gate) = self.update { s in s.calls += 1; s.enumerations += 1; return (s.outputs, s.enumerations == 1 ? s.blockEnumeration : nil) }
            gate?.wait(); return outputs
        }, resolve: { uid in self.update { $0.calls += 1; return $0.outputs.first { $0.id == uid } } },
        readDefaultOutput: { self.update { $0.calls += 1; if !$0.writes.isEmpty { $0.postWriteReads += 1 }; return $0.defaultUID } },
        readRateCapabilities: { _ in .init(currentRate: 48_000, ranges: [44_100...192_000], isSettable: true) },
        subscribe: { event, callback in
            let hook = self.update { s in let hook = s.onSubscribe; s.onSubscribe = nil; return hook }
            hook?()
            let id = UUID(); self.update { $0.listeners[id] = (event, callback) }
            return CoreAudioListenerToken { self.update { if $0.listeners.removeValue(forKey: id) != nil { $0.removed += 1 } } }
        }, setDefaultOutput: { device in self.update { s in s.writes.append(device.objectID); if s.setDefaultImmediately { s.defaultUID = device.id } } },
        readNominalRate: { _ in self.update { if !$0.writes.isEmpty { $0.postWriteReads += 1 }; return $0.rate } },
        setNominalRate: { device, rate in self.update { s in s.writes.append(device.objectID); if s.setRateImmediately { s.rate = rate } } },
        schedule: { delay, callback in
            let id = UUID(); self.update { $0.timers[id] = (delay, callback) }
            return CoreAudioListenerToken { _ = self.update { $0.timers.removeValue(forKey: id) } }
        })
    }
}

@MainActor
private func coreAudioWaitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<50_000 { if condition() { return }; await Task.yield() }
    throw DiagnosticFailure(message: "Scripted CoreAudio operation did not reach its gate")
}

private final class HandoffMasterRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (Float, Bool) = (0, true)
    func set(_ gain: Float, _ muted: Bool) { lock.withLock { stored = (gain, muted) } }
    var value: (Float, Bool) { lock.withLock { stored } }
}

extension DeveloperSelfTests {
    static func coreAudioHandoffCases() -> [DiagnosticCase] {
        func check(_ id: String, _ name: String, _ body: @escaping @MainActor () async throws -> Void) -> DiagnosticCase {
            .init(id: id, suite: "CoreAudio & Route Handoff", name: name, safety: .simulated) {
                try await body(); return .init(summary: name)
            }
        }
        func volume(_ id: String, _ name: String, mode: SystemVolumeMode = .softwareOnly, muted: Bool = false,
                    _ body: @escaping @MainActor (SystemVolumeControlSession, HandoffMasterRecorder) async throws -> Void) -> DiagnosticCase {
            check(id, name) {
                let recorder = HandoffMasterRecorder()
                let session = SystemVolumeControlSession(scalar: 0.2, muted: muted, mode: mode,
                    transferCurve: .init(decibels: [-80, -20, 0]), onVolume: { _ in }, onMasterGain: { recorder.set($0, $1) })
                session.publishCurrent(); try await body(session, recorder); session.invalidate()
            }
        }
        return [
            check("K34", "Cancelling native visibility immediately removes the listener") {
                let world = DiagnosticCoreAudioWorld(), cancellation = CoreAudioPublicationCancellation()
                let backend = world.backend
                let task = Task.detached {
                    CoreAudioPublicationCancellation.$current.withValue(cancellation) {
                        CoreAudioConditionWaiter.waitSynchronously(backend: backend, event: .devices, timeout: .seconds(3), condition: { false })
                    }
                }
                try await coreAudioWaitUntil { world.update { $0.timers.count == 2 } }
                cancellation.cancel()
                let result = await task.value
                try diagnosticRequire(result.source == .cancelled && world.update { $0.listeners.isEmpty && $0.timers.isEmpty }, "Cancelled publication leaked a wait")
            },
            check("K33", "Native publication worker wakes by event and cleans its registration") {
                let world = DiagnosticCoreAudioWorld(), backend = DiagnosticCoreAudioWorld().backend
                _ = backend
                let io = world.backend
                let task = Task.detached {
                    CoreAudioConditionWaiter.waitSynchronously(backend: io, event: .devices, timeout: .seconds(3), condition: { io.readDefaultOutput() == "ready" })
                }
                try await coreAudioWaitUntil { world.update { $0.timers.count == 2 && $0.calls >= 2 } }
                world.update { $0.defaultUID = "ready" }; world.emit(.devices)
                let result = await task.value
                try diagnosticRequire(result.source == .notification && world.update { $0.listeners.isEmpty && $0.timers.isEmpty }, "Publisher wait did not wake or clean up")
            },
            check("K01", "Snapshot presentation never enters HAL") {
                let world = DiagnosticCoreAudioWorld(), store = CoreAudioSnapshotStore()
                store.publish(outputs: world.update { $0.outputs.map(CoreAudioOutputSnapshot.init) }, defaultUID: "physical")
                store.publishRates(["physical": .init(currentRate: 48_000, ranges: [], isSettable: false)])
                let calls = world.update { $0.calls }
                _ = store.physicalOutputDevices; _ = store.cachedDevice(uid: "physical"); _ = store.defaultOutputUID
                try diagnosticRequire(store.cachedSampleRateSupport(uid: "physical", rate: 48_000) == true && world.update { $0.calls } == calls, "Snapshot entered HAL")
            },
            check("K02", "Targeted default observation bypasses slow enumeration") {
                let world = DiagnosticCoreAudioWorld(), gate = DispatchSemaphore(value: 0)
                world.update { $0.blockEnumeration = gate }; defer { gate.signal() }
                let service = CoreAudioService(backend: world.backend)
                try await coreAudioWaitUntil { world.update { $0.enumerations == 1 } }
                world.update { $0.defaultUID = "changed" }; world.emit(.defaultOutput)
                try await coreAudioWaitUntil { service.snapshots.defaultOutputUID == "changed" }
                try diagnosticRequire(!service.snapshots.hasCompletedInitialRefresh, "Full enumeration unexpectedly completed")
            },
            check("K03", "Device event bursts retain only one trailing refresh") {
                let world = DiagnosticCoreAudioWorld(), gate = DispatchSemaphore(value: 0)
                world.update { $0.blockEnumeration = gate }
                let service = CoreAudioService(backend: world.backend)
                try await coreAudioWaitUntil { world.update { $0.enumerations == 1 } }
                for _ in 0..<100 { world.emit(.devices) }
                try await coreAudioWaitUntil { service.deviceGraphGeneration >= 100 }
                gate.signal(); await service.refreshWithoutBlockingUI()
                try diagnosticRequire(world.update { $0.enumerations } <= 2, "Burst scheduled unbounded scans")
            },
            check("K04", "Existing endpoint requires no listener") {
                let world = DiagnosticCoreAudioWorld()
                let backend = world.backend
                let result = try await CoreAudioConditionWaiter.wait(backend: backend, event: .devices, timeout: .seconds(2), condition: { backend.resolve("physical") != nil })
                try diagnosticRequire(result.source == .immediate && world.update { $0.listeners.isEmpty }, "Immediate endpoint installed a waiter")
            },
            check("K05", "Subscribe recheck closes the missed-event window") {
                let world = DiagnosticCoreAudioWorld()
                world.update { $0.onSubscribe = { world.update { $0.defaultUID = "ready" } } }
                let backend = world.backend
                let result = try await CoreAudioConditionWaiter.wait(backend: backend, event: .devices, timeout: .seconds(2), condition: { backend.readDefaultOutput() == "ready" })
                try diagnosticRequire(result.source == .immediate && world.update { $0.removed } == 1, "Post-subscription recheck missed readiness")
            },
            check("K06", "Endpoint notification completes without a polling tick") {
                let world = DiagnosticCoreAudioWorld()
                let service = CoreAudioService(observesHardware: false, backend: world.backend)
                let task = Task { await service.waitForDevice(uid: "new") }
                try await coreAudioWaitUntil { world.update { !$0.listeners.isEmpty } }
                world.update { $0.outputs.append(.init(id: "new", objectID: 30, name: "New")) }; world.emit(.devices)
                let device = await task.value
                try diagnosticRequire(device?.objectID == 30 && world.update { $0.listeners.isEmpty }, "Notification failed or leaked")
            },
            check("K07", "Cancelling a waiter removes its registration exactly once") {
                let world = DiagnosticCoreAudioWorld()
                let backend = world.backend
                let task = Task.detached { try await CoreAudioConditionWaiter.wait(backend: backend, event: .devices, timeout: .seconds(2), condition: { false }) }
                try await coreAudioWaitUntil { world.update { !$0.listeners.isEmpty } }
                task.cancel()
                do { _ = try await task.value; throw DiagnosticFailure(message: "Cancelled waiter succeeded") } catch is CancellationError {}
                world.emit(.devices)
                try diagnosticRequire(world.update { $0.removed == 1 && $0.listeners.isEmpty && $0.timers.isEmpty }, "Cancellation leaked registrations")
            },
            check("K08", "Manual deadline cleans listener and timers") {
                let world = DiagnosticCoreAudioWorld()
                let service = CoreAudioService(observesHardware: false, backend: world.backend)
                let task = Task { await service.waitForDevice(uid: "missing") }
                try await coreAudioWaitUntil { world.update { $0.timers.count == 2 } }
                world.tick(); world.tick()
                let value = await task.value
                try diagnosticRequire(value == nil && service.lastWait?.source == .timedOut && world.update { $0.removed == 1 }, "Timeout did not settle")
            },
            check("K09", "Default output acknowledges an actual notification") {
                let world = DiagnosticCoreAudioWorld(); world.update { $0.setDefaultImmediately = false }
                let service = CoreAudioService(observesHardware: false, backend: world.backend)
                world.update { $0.defaultUID = "old" }
                let task = Task { try await service.setDefaultOutputAndWait(uid: "physical") }
                try await coreAudioWaitUntil { world.update { $0.postWriteReads > 0 } }
                world.update { $0.defaultUID = "physical" }; world.emit(.defaultOutput)
                try await task.value
                try diagnosticRequire(service.lastWait?.source == .notification && service.fallbackConfirmations == 0, "Default output used fallback")
            },
            check("K10", "Lost default notification uses bounded fallback") {
                let world = DiagnosticCoreAudioWorld(); world.update { $0.setDefaultImmediately = false; $0.defaultUID = "old" }
                let service = CoreAudioService(observesHardware: false, backend: world.backend)
                let task = Task { try await service.setDefaultOutputAndWait(uid: "physical") }
                try await coreAudioWaitUntil { world.update { $0.postWriteReads > 0 && $0.timers.count == 2 } }
                world.update { $0.defaultUID = "physical" }; world.tick()
                try await task.value
                try diagnosticRequire(service.lastWait?.source == .fallback, "Lost event was not classified fallback")
            },
            check("K11", "Unacknowledged default mutation exhausts three attempts") {
                let world = DiagnosticCoreAudioWorld(); world.update { $0.defaultUID = "old"; $0.setDefaultImmediately = false }
                let service = CoreAudioService(observesHardware: false, backend: world.backend)
                let task = Task { try await service.setDefaultOutputAndWait(uid: "physical") }
                for attempt in 1...3 {
                    try await coreAudioWaitUntil { world.update { $0.writes.count == attempt && $0.timers.count == 2 } }
                    world.tick(); world.tick()
                }
                do { try await task.value; throw DiagnosticFailure(message: "Unacknowledged route succeeded") }
                catch CoreAudioService.AudioError.defaultOutputDidNotApply {}
                try diagnosticRequire(world.update { $0.listeners.isEmpty && $0.writes.count == 3 }, "Retry leaked")
            },
            check("K12", "Nominal rate acknowledges notification") {
                let world = DiagnosticCoreAudioWorld(); world.update { $0.setRateImmediately = false }
                let service = CoreAudioService(observesHardware: false, backend: world.backend)
                let task = Task { try await service.setSampleRate(uid: "physical", rate: 96_000) }
                try await coreAudioWaitUntil { world.update { $0.postWriteReads > 0 } }
                world.update { $0.rate = 96_000 }; world.emit(.nominalRate(10)); try await task.value
                try diagnosticRequire(service.lastWait?.source == .notification, "Rate event not observed")
            },
            check("K13", "Lost nominal-rate event has a bounded fallback") {
                let world = DiagnosticCoreAudioWorld(); world.update { $0.setRateImmediately = false }
                let service = CoreAudioService(observesHardware: false, backend: world.backend)
                let task = Task { try await service.setSampleRate(uid: "physical", rate: 96_000) }
                try await coreAudioWaitUntil { world.update { $0.postWriteReads > 0 && $0.timers.count == 2 } }
                world.update { $0.rate = 96_000 }; world.tick(); try await task.value
                try diagnosticRequire(service.lastWait?.source == .fallback, "Rate fallback not recorded")
            },
            volume("K19", "Incoming software volume is held despite physical readiness") { session, recorder in
                try diagnosticRequire(session.snapshot().audibility == .held && recorder.value.1, "Incoming path became audible")
            },
            volume("K20", "Permission cannot bypass hardware readiness", mode: .hardwareMirrored) { session, recorder in
                session.permitAudibility(); try diagnosticRequire(recorder.value.1, "Unready hardware unmuted")
                session.physicalTargetApplied(.init(scalar: 0.2, muted: false), succeeded: true)
                try diagnosticRequire(!recorder.value.1 && recorder.value.0 == 1, "Hardware readiness failed or doubled attenuation")
            },
            volume("K21", "Software-only permission preserves the calibrated curve") { session, recorder in
                session.permitAudibility()
                let expected = SystemVolumeTransferCurve(decibels: [-80, -20, 0]).physicalLinearGain(for: 0.2)
                try diagnosticRequire(!recorder.value.1 && recorder.value.0 == expected, "Transfer curve changed")
            },
            volume("K22", "User mute survives audibility permission", muted: true) { session, recorder in
                session.permitAudibility(); try diagnosticRequire(recorder.value.1 && session.snapshot().muted, "Permission cleared user mute")
            },
            volume("K23", "Held path retains the latest changing volume") { session, recorder in
                for scalar: Float in [0.2, 0.35, 0.52] { session.apply(scalar: scalar, muted: false) }
                try diagnosticRequire(recorder.value.1 && session.snapshot().scalar == 0.52, "Held target lost")
                session.permitAudibility(); try diagnosticRequire(!recorder.value.1, "Ready target remained held")
            },
            volume("K24", "Outgoing hold is synchronous before a suspended capture") { session, recorder in
                session.permitAudibility(); session.holdAudibility()
                let gate = DiagnosticManualGate()
                let task = Task { try await gate.enter() }; try await gate.waitUntilEntered()
                let held = recorder.value.1; gate.release(); try await task.value
                try diagnosticRequire(held, "Outgoing path stayed audible across await")
            },
            volume("K25", "Late media keys cannot clear the outgoing hold") { session, recorder in
                session.permitAudibility(); session.holdAudibility(); session.apply(scalar: 0.8, muted: false)
                try diagnosticRequire(recorder.value.1 && session.snapshot().scalar == 0.8, "Late event reopened route")
            },
            volume("K26", "Failed physical mirror remains silent", mode: .hardwareMirrored) { session, recorder in
                session.permitAudibility(); session.physicalTargetApplied(.init(scalar: 0.2, muted: false), succeeded: false)
                try diagnosticRequire(recorder.value.1 && !session.snapshot().physicalReady, "Mirror failure became audible")
            },
            volume("K27", "Old binding callback cannot overwrite a rebound session") { session, recorder in
                let old = session.beginBinding(); session.permitAudibility()
                let oldDriver = session.driverConsumer()
                _ = session.beginBinding()
                session.permitAudibility()
                oldDriver(0.9, false)
                session.apply(scalar: 0.9, muted: false, binding: old)
                try diagnosticRequire(session.snapshot().scalar == 0.2 && !recorder.value.1, "Old binding mutated new target")
            }
        ] + coreAudioCoordinatorCases()
    }
}

@MainActor
private final class CoreAudioCoordinatorFixture {
    let box: DiagnosticSandbox
    let fake = DiagnosticRuntimeFakes(.init(transportResults: Array(repeating: true, count: 30)))
    let profile = DiagnosticSandbox.profile()
    var state: AppState!
    var lease: VolumeHandoffLease?
    var bridgeID: UInt32 = 20
    var routingID: UInt32 = 102
    var replaceOnPublish = false
    var replaceBridge = false
    var controlID: UInt32 = 102
    var held = 0
    var permitted = 0
    var rebound = 0
    var incomingGate: DiagnosticManualGate?
    init() throws {
        box = try DiagnosticSandbox(); box.profiles.profiles = [profile]
        var services = fake.services()
        services.resolveOutput = { [unowned self] uid in uid == fake.output.id ? fake.output : nil }
        services.prepareIncoming = { [unowned self] in try await incomingGate?.enter(); fake.record("prepare volume") }
        let start = services.startVolume
        services.startVolume = { [unowned self] routing, output, profile in
            let master = try await start(routing, output, profile)
            let session = SystemVolumeControlSession(scalar: 0.2, muted: false, transferCurve: .init(decibels: []), onVolume: { _ in }, onMasterGain: { _, _ in })
            lease = VolumeHandoffLease(id: UInt64(permitted + 1), ownershipID: state.runtimeCoordinator.currentOwnershipID!, routingUID: routing.id, physicalUID: output.id, controlSession: session, onMirrorFailure: {})
            return master
        }
        services.currentVolumeLease = { [unowned self] in lease }
        services.holdAudibility = { [unowned self] value in
            guard let value, value === lease else { return }; held += 1; value.controlSession.holdAudibility(); fake.record("hold audibility")
        }
        services.permitAudibility = { [unowned self] value in
            guard let value, value === lease else { return }; permitted += 1; value.controlSession.permitAudibility(); fake.record("permit audibility")
        }
        services.resolveBinding = { [unowned self] routing, _ in
            .init(bridge: .init(id: fake.bridge.id, objectID: bridgeID, name: fake.bridge.name),
                  routing: .init(id: routing, objectID: routingID, name: "Routing"), physical: fake.output, graphGeneration: UInt64(routingID))
        }
        services.synchronizeRouting = { [unowned self] _, _, _, _ in
            fake.record("synchronize routing")
            if replaceOnPublish { routingID += 1; if replaceBridge { bridgeID += 1 } }
        }
        services.rebindVolume = { [unowned self] value, _ in
            guard value === lease else { throw CancellationError() }; rebound += 1; _ = value.controlSession.beginBinding()
        }
        services.updateTransportControl = { [unowned self] id, _ in controlID = id }
        let stop = services.stopVolume
        services.stopVolume = { [unowned self] in lease?.controlSession.invalidate(); lease = nil; await stop() }
        state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: services)
    }
    func cleanUp() async { await state.deactivate(); await state.runtimeCoordinator.waitUntilSettled(); box.cleanUp() }
}

extension DeveloperSelfTests {
    static func coreAudioCoordinatorCases() -> [DiagnosticCase] {
        func check(_ id: String, _ name: String, _ body: @escaping @MainActor () async throws -> Void) -> DiagnosticCase {
            .init(id: id, suite: "CoreAudio & Route Handoff", name: name, safety: .simulated) { try await body(); return .init(summary: name) }
        }
        func fixture(_ id: String, _ name: String, _ body: @escaping @MainActor (CoreAudioCoordinatorFixture) async throws -> Void) -> DiagnosticCase {
            check(id, name) {
                let f = try CoreAudioCoordinatorFixture()
                do { try await body(f); await f.cleanUp() } catch { await f.cleanUp(); throw error }
            }
        }
        func binding(_ id: String, _ name: String, bridge: Bool) -> DiagnosticCase {
            check(id, name) {
                let world = DiagnosticCoreAudioWorld()
                world.update { $0.outputs.append(.init(id: "routing", objectID: 100, name: "Routing")) }
                var backend = world.backend
                backend.publishEndpoints = { _, _ in
                    world.update { s in s.outputs = s.outputs.map {
                        .init(id: $0.id, objectID: $0.id == "routing" ? 205 : (bridge && $0.id == AudioDeviceInfo.systemAudioBridgeUID ? 73 : $0.objectID), name: $0.name)
                    } }
                    return []
                }
                let service = CoreAudioService(observesHardware: false, backend: backend)
                let before = try await service.resolveRuntimeBinding(routingUID: "routing", physicalUID: "physical")
                let receipt = try await service.publishEndpoints([])
                let after = try await service.resolveRuntimeBinding(routingUID: "routing", physicalUID: "physical")
                try diagnosticRequire(before.routing.objectID == 100 && after.routing.objectID == 205 && after.graphGeneration >= receipt.graphGeneration, "Publication retained a stale binding")
                if bridge { try diagnosticRequire(after.bridge.objectID == 73, "Bridge binding was stale") }
            }
        }
        return [
            binding("K14", "Endpoint publication invalidates routing object identity", bridge: false),
            binding("K15", "Complete runtime binding freshly resolves the base bridge", bridge: true),
            fixture("K16", "Active rename refreshes controls without restarting engine or PCM") { f in
                await f.state.activate(profile: f.profile)
                let initialStarts = f.fake.events.filter { $0 == "start engine" || $0 == "start PCM" || $0 == "start transport" }
                f.replaceOnPublish = true
                var renamed = f.profile; renamed.name += " renamed"
                await f.state.apply(profile: renamed)
                try diagnosticRequire(f.state.isActive && f.rebound == 1 && f.controlID == f.routingID, "Rename lost volume/control binding")
                try diagnosticRequire(initialStarts == f.fake.events.filter { $0 == "start engine" || $0 == "start PCM" || $0 == "start transport" }, "Control rebind restarted audio")
                try diagnosticRequire(f.lease?.controlSession.snapshot().audibility == .permitted, "Rename left audio held")
            },
            fixture("K17", "Bridge replacement restarts only transport while held") { f in
                await f.state.activate(profile: f.profile)
                let oldEngineStarts = f.fake.events.filter { $0 == "start engine" || $0 == "start PCM" }
                f.replaceOnPublish = true; f.replaceBridge = true
                var renamed = f.profile; renamed.name += " renamed"
                await f.state.apply(profile: renamed)
                try diagnosticRequire(f.state.isActive && f.fake.transportAttempts == 2, "Bridge was not rebound")
                try diagnosticRequire(oldEngineStarts == f.fake.events.filter { $0 == "start engine" || $0 == "start PCM" }, "Binding recovery restarted engine/PCM")
                try diagnosticRequire(f.lease?.controlSession.snapshot().audibility == .permitted, "Binding recovery did not permit ready audio")
            },
            check("K18", "Volume mirror progresses while enumeration is blocked") {
                let world = DiagnosticCoreAudioWorld(), gate = DispatchSemaphore(value: 0)
                world.update { $0.blockEnumeration = gate }; defer { gate.signal() }
                let service = CoreAudioService(backend: world.backend)
                try await coreAudioWaitUntil { world.update { $0.enumerations == 1 } }
                let recorder = HandoffMasterRecorder()
                let mirror = PhysicalVolumeMirror(queue: DispatchQueue(label: "CamiTune.Diagnostic.Volume"),
                    capabilities: .init(volumeReadable: true, volumeWritable: true, muteReadable: false, muteWritable: false),
                    operations: .init(read: { nil }, setVolume: { recorder.set($0, false) }, setMute: { _ in }), onApplied: { _, _ in }, onPhysicalChange: { _ in })
                mirror.submit(scalar: 0.35, muted: false); await mirror.flush()
                try diagnosticRequire(recorder.value.0 == 0.35 && !service.snapshots.hasCompletedInitialRefresh, "Enumeration blocked volume queue")
            },
            fixture("K35", "Route return remains held until coordinator readiness completes") { f in
                await f.state.activate(profile: f.profile)
                f.fake.defaultUID = "external"; f.state.runtimeCoordinator.handleDefaultOutputChange("external")
                let gate = DiagnosticManualGate(); f.incomingGate = gate
                f.fake.defaultUID = f.lease!.routingUID
                f.state.runtimeCoordinator.handleDefaultOutputChange(f.fake.defaultUID)
                try await gate.waitUntilEntered()
                let held = f.lease?.controlSession.snapshot().audibility == .held
                gate.release(); await f.state.runtimeCoordinator.waitUntilSettled()
                try diagnosticRequire(held && f.lease?.controlSession.snapshot().audibility == .permitted, "Route return bypassed readiness")
            },
            fixture("K28", "External route departure holds the current owner immediately") { f in
                await f.state.activate(profile: f.profile); f.fake.defaultUID = "external"
                f.state.runtimeCoordinator.handleDefaultOutputChange("external")
                try diagnosticRequire(f.lease?.controlSession.snapshot().audibility == .held && f.state.isActive, "Departure was not held synchronously")
            },
            fixture("K29", "Stale return observation cannot resume or alter the new owner") { f in
                await f.state.activate(profile: f.profile)
                let old = f.lease!
                let other = DeviceProfile(name: "Other", outputDeviceUID: f.profile.outputDeviceUID, outputDeviceName: f.profile.outputDeviceName)
                f.box.profiles.profiles.append(other); await f.state.activate(profile: other)
                let before = f.lease!.controlSession.snapshot()
                f.state.runtimeCoordinator.handleDefaultOutputChange(old.routingUID)
                try diagnosticRequire(f.lease!.controlSession.snapshot() == before && old.controlSession.snapshot().audibility == .held, "Stale return altered ownership")
            },
            fixture("K30", "Stop during endpoint readiness never grants audibility") { f in
                let gate = DiagnosticManualGate(); f.fake.scenario.routingGate = gate
                let task = Task { await f.state.activate(profile: f.profile) }
                try await gate.waitUntilEntered(); await f.state.deactivate(manual: true); gate.release(); await task.value
                await f.state.runtimeCoordinator.waitUntilSettled()
                try diagnosticRequire(!f.state.isActive && f.permitted == 0, "Stale activation became audible")
            },
            check("K31", "Restoration writes the freshly resolved object ID") {
                let world = DiagnosticCoreAudioWorld()
                let actual = CoreAudioService(observesHardware: false, backend: world.backend)
                world.update { $0.outputs[0] = .init(id: "physical", objectID: 92, name: "Physical"); $0.defaultUID = "old" }
                try await actual.setDefaultOutputAndWait(uid: "physical")
                try diagnosticRequire(world.update { $0.writes == [92] }, "Restoration used cached object identity")
            },
            fixture("K32", "Missing previous output falls back to the owned physical route") { f in
                f.fake.defaultUID = "missing previous"
                // This resolver distinguishes absent previous UID from the real output.
                // The coordinator's restoration lookup must call it afresh.
                await f.state.activate(profile: f.profile)
                await f.state.deactivate()
                try diagnosticRequire(f.fake.defaultUID == f.profile.outputDeviceUID, "Missing restoration UID was reused")
            }
        ]
    }
}
