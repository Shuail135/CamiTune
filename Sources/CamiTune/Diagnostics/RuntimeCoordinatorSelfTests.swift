import Foundation

@MainActor
private final class CoordinatorFixture {
    let box: DiagnosticSandbox
    let fake: DiagnosticRuntimeFakes
    let state: AppState
    let profile: DeviceProfile
    init(configure: (@MainActor (inout AudioRuntimeServices, DiagnosticRuntimeFakes) -> Void)? = nil) throws {
        box = try DiagnosticSandbox(); fake = DiagnosticRuntimeFakes(.init(transportResults: Array(repeating: true, count: 30)))
        profile = DiagnosticSandbox.profile(); box.profiles.profiles = [profile]
        var services = fake.services(); configure?(&services, fake)
        state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: services)
    }
    var owner: AudioRuntimeCoordinator { state.runtimeCoordinator }
    func otherProfile() -> DeviceProfile {
        let other = DeviceProfile(name: "Other fixture", outputDeviceUID: profile.outputDeviceUID, outputDeviceName: profile.outputDeviceName)
        box.profiles.profiles.append(other); return other
    }
    func changed() -> DeviceProfile {
        var result = profile
        result.processing.global.stages.append(.init(processor: .gain(.init(gainDB: -3))))
        return result
    }
    func receipt() async throws -> RuntimeApplyReceipt {
        try await owner.applySettingsCandidate(original: profile, newRuntime: changed(), operation: nil, validatePersistence: {})
    }
    func cleanUp() async {
        await state.deactivate(); await owner.waitUntilSettled(); box.cleanUp()
    }
}

extension DeveloperSelfTests {
    static func runtimeCoordinatorCases() -> [DiagnosticCase] {
        func check(_ id: String, _ name: String, _ body: @escaping @MainActor () async throws -> Void) -> DiagnosticCase {
            .init(id: id, suite: "Runtime Coordinator", name: name, safety: .simulated) {
                try await body(); return .init(summary: name)
            }
        }
        func fixture(_ id: String, _ name: String,
                     configure: (@MainActor (inout AudioRuntimeServices, DiagnosticRuntimeFakes) -> Void)? = nil,
                     _ body: @escaping @MainActor (CoordinatorFixture) async throws -> Void) -> DiagnosticCase {
            check(id, name) {
                let f = try CoordinatorFixture(configure: configure)
                do {
                    try await body(f); await f.cleanUp()
                    try diagnosticRequire(f.fake.resources.isEmpty, "Leaked resources: \(f.fake.resources)")
                } catch { await f.cleanUp(); throw error }
            }
        }
        func reused(_ id: String, _ prior: String, _ name: String) -> DiagnosticCase {
            check(id, name) {
                let cases = runtimePlanCases() + runtimePlanDifferCases()
                guard let test = cases.first(where: { $0.id == prior }) else { throw DiagnosticFailure(message: "Missing regression \(prior)") }
                _ = try await test.execute()
            }
        }
        return [
            fixture("C01", "Ownership extraction preserves activation/failure/retry contracts") { f in
                f.fake.scenario.transportResults = [false, false, true]
                await f.state.activate(profile: f.profile)
                try diagnosticRequire(f.state.isActive && f.fake.transportAttempts == 3, "Retry contract changed")
                await f.state.deactivate()
                f.fake.scenario.engineFails = true
                await f.state.activate(profile: f.profile)
                try diagnosticRequire(!f.state.isActive && f.fake.resources.isEmpty, "Failed acquisition leaked")
            },
            fixture("C02", "Teardown preserves transport, PCM, pipe, engine, volume order") { f in
                await f.state.activate(profile: f.profile); await f.state.deactivate()
                let indices = ["stop transport", "stop PCM", "close engine input", "stop engine", "stop volume"].compactMap { f.fake.events.lastIndex(of: $0) }
                try diagnosticRequire(indices.count == 5 && indices == indices.sorted(), "Teardown order changed")
            },
            fixture("C03", "Graph and volume precede PCM; readiness precedes output switch") { f in
                await f.state.activate(profile: f.profile)
                let indices = ["apply graph", "start volume", "start PCM", "start transport", "prepare volume", "select routing"].compactMap { f.fake.events.firstIndex(of: $0) }
                try diagnosticRequire(indices.count == 6 && indices == indices.sorted(), "Unsafe activation order")
            },
            fixture("C04", "Synchronous shutdown retires owned resources exactly once") { f in
                await f.state.activate(profile: f.profile)
                f.state.shutdownSynchronously(); f.state.shutdownSynchronously()
                try diagnosticRequire(!f.state.isActive && f.fake.resources.isEmpty, "Shutdown leaked")
                for name in ["transport", "PCM", "engine", "volume", "spectrum", "observations"] {
                    try diagnosticRequire(f.fake.events.filter { $0 == "stop \(name)" }.count == 1, "Duplicate/missing stop: \(name)")
                }
            },
            fixture("C05", "Stop during endpoint wait never acknowledges the provisional session") { f in
                let gate = DiagnosticManualGate(); defer { gate.release() }
                f.fake.scenario.routingGate = gate
                let activation = Task { await f.state.activate(profile: f.profile) }
                try await gate.waitUntilEntered(); await f.state.deactivate(); gate.release(); await activation.value
                try diagnosticRequire(!f.state.isActive && !f.fake.events.contains("notify activation")
                    && !f.fake.events.contains("start engine") && !f.fake.events.contains("stop engine"), "Stale activation acquired or published resources")
            },
            fixture("C06", "Activate A then B discards A and acknowledges B") { f in
                let b = f.otherProfile(), gate = DiagnosticManualGate(); defer { gate.release() }
                f.fake.scenario.routingGate = gate
                let a = Task { await f.state.activate(profile: f.profile) }
                try await gate.waitUntilEntered()
                let generation = f.owner.desiredRuntime.generation
                let next = Task { await f.state.activate(profile: b) }
                try await coordinatorWait { f.owner.desiredRuntime.generation > generation }
                gate.release(); await a.value; await next.value
                try diagnosticRequire(f.state.activeProfileID == b.id && f.fake.events.filter { $0 == "notify activation" }.count == 1, "A won over B")
            },
            fixture("C07", "Activate A then B then Stop settles inactive") { f in
                let b = f.otherProfile(), gate = DiagnosticManualGate(); defer { gate.release() }
                f.fake.scenario.graphGate = gate
                let a = Task { await f.state.activate(profile: f.profile) }
                try await gate.waitUntilEntered()
                let generation = f.owner.desiredRuntime.generation
                let next = Task { await f.state.activate(profile: b) }
                try await coordinatorWait { f.owner.desiredRuntime.generation > generation }
                await f.state.deactivate(); gate.release(); await a.value; await next.value
                try diagnosticRequire(!f.state.isActive && f.fake.resources.isEmpty && !f.fake.events.contains("notify activation"), "Earlier intent resurrected audio")
            },
            fixture("C08", "Delayed old-owner fault cannot retire its replacement") { f in
                await f.state.activate(profile: f.profile)
                let old = try coordinatorOwnership(f.owner)
                await f.state.deactivate(); await f.state.activate(profile: f.otherProfile())
                let current = f.state.activeSession
                f.owner.reportRuntimeFault("old fault", ownershipID: old)
                await f.owner.waitUntilSettled()
                try diagnosticRequire(f.state.activeSession == current && f.state.errorMessage == nil, "Old callback affected B")
            },
            check("C09", "Suspended old cleanup finishes before B acquires global resources") {
                let gate = DiagnosticManualGate(); defer { gate.release() }
                var hold = false
                let f = try CoordinatorFixture { services, fake in
                    services.stopTransport = { if hold { try? await gate.enter() }; fake.stop("transport") }
                }
                do {
                    await f.state.activate(profile: f.profile); hold = true
                    let stop = Task { await f.state.deactivate() }
                    try await gate.waitUntilEntered()
                    let generation = f.owner.desiredRuntime.generation
                    let b = f.otherProfile(), start = Task { await f.state.activate(profile: f.box.profiles.profiles.last!) }
                    try await coordinatorWait { f.owner.desiredRuntime.generation > generation }
                    try diagnosticRequire(f.fake.events.filter { $0 == "start engine" }.count == 1, "B acquired resources while A cleanup was suspended")
                    hold = false; gate.release(); await stop.value; await start.value
                    try diagnosticRequire(f.state.activeProfileID == b.id && f.fake.resources.contains("transport"), "Old cleanup stopped B")
                    await f.cleanUp()
                } catch { hold = false; gate.release(); await f.cleanUp(); throw error }
            },
            fixture("C10", "Device removal during startup rejects stale hardware evidence") { f in
                let gate = DiagnosticManualGate(); defer { gate.release() }; f.fake.scenario.routingGate = gate
                let task = Task { await f.state.activate(profile: f.profile) }
                try await gate.waitUntilEntered(); f.fake.scenario.outputPresent = false
                gate.release(); await task.value
                try diagnosticRequire(!f.state.isActive && f.fake.resources.isEmpty, "Removed output acknowledged")
            },
            fixture("C11", "Final sample-rate validation rejects drift during startup", configure: { services, _ in
                services.nominalRate = { _ in 96_000 }
            }) { f in
                await f.state.activate(profile: f.profile)
                try diagnosticRequire(!f.state.isActive && !f.fake.events.contains("notify activation") && f.fake.resources.isEmpty, "Drifted rate acknowledged")
            },
            fixture("C12", "Manual Stop suppresses same-output automatic activation") { f in
                await f.state.activate(profile: f.profile); await f.state.deactivate()
                await f.state.activate(profile: f.profile, automatic: true)
                try diagnosticRequire(!f.state.isActive, "Automatic request defeated Stop")
            },
            fixture("C13", "Physical route change clears automatic suppression") { f in
                await f.state.activate(profile: f.profile); await f.state.deactivate()
                f.fake.defaultUID = "diagnostic.other"; f.owner.handleDefaultOutputChange(f.fake.defaultUID)
                f.fake.defaultUID = f.profile.outputDeviceUID
                await f.state.activate(profile: f.profile, automatic: true)
                try diagnosticRequire(f.state.isActive, "Route change did not clear suppression")
            },
            fixture("C14", "Automatic failure after Stop cannot schedule resurrection") { f in
                let gate = DiagnosticManualGate(); defer { gate.release() }
                f.fake.scenario.engineGate = gate; f.fake.scenario.engineFails = true
                let task = Task { await f.state.activate(profile: f.profile, automatic: true) }
                try await gate.waitUntilEntered(); await f.state.deactivate(); gate.release(); await task.value
                f.fake.scenario.engineFails = false; await f.state.activate(profile: f.profile, automatic: true)
                try diagnosticRequire(!f.state.isActive && f.owner.coordinatorSummary.contains("Automatic retry: None"), "Stale failure enabled retry after Stop")
            },
            check("C15", "Unsent live plans coalesce while preparation is suspended") {
                let gate = DiagnosticManualGate(); defer { gate.release() }; var hold = false
                let f = try CoordinatorFixture { services, fake in
                    services.resolveOutput = { _ in if hold { try? await gate.enter() }; return fake.output }
                }
                do {
                    await f.state.activate(profile: f.profile); hold = true
                    let b = Task { await f.state.apply(profile: f.changed()) }
                    try await gate.waitUntilEntered()
                    var successors: [Task<Void, Never>] = []
                    for gain in [-4.0, -5.0, -6.0] {
                        var candidate = f.profile
                        candidate.processing.global.stages.append(.init(processor: .gain(.init(gainDB: gain))))
                        let generation = f.owner.desiredRuntime.generation
                        successors.append(Task { await f.state.apply(profile: candidate) })
                        try await coordinatorWait { f.owner.desiredRuntime.generation > generation }
                    }
                    hold = false; gate.release(); await b.value
                    for task in successors { await task.value }
                    try diagnosticRequire(f.fake.graphs.count == 2, "Unsent intermediate plans reached the backend")
                    await f.cleanUp()
                } catch { hold = false; gate.release(); await f.cleanUp(); throw error }
            },
            reused("C16", "R14", "Acknowledged superseded graph commits matching local effects before successor"),
            reused("C17", "D20", "Rejected patch and fallback retain the old applied plan"),
            reused("C18", "R11", "Settings persistence failure restores the exact prior plan"),
            fixture("C19", "Stop invalidates a tentative Save receipt; rollback cannot reactivate") { f in
                await f.state.activate(profile: f.profile)
                let receipt = try await f.receipt()
                await f.state.deactivate()
                let result = try await f.owner.rollback(receipt)
                try diagnosticRequire(result == .superseded && !f.state.isActive && f.fake.resources.isEmpty, "Old Save rollback defeated Stop")
            },
            fixture("C20", "Profile switch invalidates the old Save rollback receipt") { f in
                await f.state.activate(profile: f.profile); let receipt = try await f.receipt()
                let b = f.otherProfile(); await f.state.activate(profile: b)
                let session = f.state.activeSession, events = f.fake.events
                let result = try await f.owner.rollback(receipt)
                try diagnosticRequire(result == .superseded && f.state.activeSession == session && f.fake.events == events,
                    "Old Save rollback mutated B")
            },
            reused("C21", "D33", "Rollback failure retires the affected runtime"),
            reused("C22", "D27", "Endpoint failure restores exact graph, renderer and acknowledgement"),
            reused("C23", "D32", "Engine quiescence stays distinct from route handoff"),
            fixture("C24", "Cross-profile switch conservatively retires and reacquires resources") { f in
                await f.state.activate(profile: f.profile); let first = try coordinatorOwnership(f.owner)
                await f.state.activate(profile: f.otherProfile())
                try diagnosticRequire(f.owner.currentOwnershipID != first && f.fake.events.filter { $0 == "start engine" }.count == 2
                    && f.fake.events.filter { $0 == "stop engine" }.count == 1, "Cross-profile resources were reused")
            },
            check("C25", "Runtime overlay retirement precedes PCM teardown") {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                let fake = DiagnosticRuntimeFakes(), profile = DiagnosticSandbox.profile()
                let owner = AudioRuntimeCoordinator(services: fake.services(), perAppAudio: box.perApp,
                    performanceRecorder: RuntimePerformanceRecorder(source: PerformanceTraceSource()), callbacks: .init(
                        profiles: { [profile] }, automaticProfile: { _ in nil }, applyingDrafts: { $0 }, settingsBusy: { false },
                        retireOverlays: { fake.record("retire overlays") }, cancelStartup: {}, reportError: { _ in },
                        reportMessage: { _ in }, currentError: { nil }, clearError: {}))
                await owner.activate(profile: profile); await owner.deactivate()
                let overlay = fake.events.firstIndex(of: "retire overlays"), pcm = fake.events.firstIndex(of: "stop PCM")
                try diagnosticRequire(overlay != nil && pcm != nil && overlay! < pcm!, "Overlay outlived its PCM session")
            },
            fixture("C26", "Late volume mirror failure is rejected by ownership identity") { f in
                await f.state.activate(profile: f.profile); let old = try coordinatorOwnership(f.owner)
                await f.state.deactivate(); await f.state.activate(profile: f.profile)
                f.owner.reportVolumeMirrorFailure(ownershipID: old)
                try diagnosticRequire(f.state.errorMessage == nil, "Old volume callback affected current session")
                f.owner.reportVolumeMirrorFailure(ownershipID: try coordinatorOwnership(f.owner))
                try diagnosticRequire(f.state.errorMessage?.contains("volume") == true, "Current volume callback was ignored")
            },
            fixture("C27", "Shutdown during suspended startup prevents late acknowledgement") { f in
                let gate = DiagnosticManualGate(); defer { gate.release() }; f.fake.scenario.graphGate = gate
                let task = Task { await f.state.activate(profile: f.profile) }
                try await gate.waitUntilEntered(); f.state.shutdownSynchronously(); gate.release(); await task.value
                try diagnosticRequire(!f.state.isActive && f.fake.resources.isEmpty && !f.fake.events.contains("notify activation"), "Shutdown continuation resurrected runtime")
            },
            reused("C28", "D21", "No-op desired plan performs no runtime effects"),
            fixture("C29", "Normal telemetry leaves desired generation unchanged") { f in
                await f.state.activate(profile: f.profile)
                let generation = f.owner.desiredRuntime.generation
                guard let session = f.state.activeSession else { throw DiagnosticFailure(message: "Missing session") }
                let levels = PCMLevelSnapshot(peak: [-6, -6], rms: [-12, -12], clippedSamples: 0, clippedSamplesByChannel: [0, 0])
                for _ in 0..<100 { f.state.meters.ingest(levels, session: session) }
                try diagnosticRequire(f.owner.desiredRuntime.generation == generation, "Telemetry commanded reconciliation")
            },
            check("C31", "Deferred live edit cannot replace a pending manual Stop") {
                let gate = DiagnosticManualGate(); defer { gate.release() }; var hold = false
                let f = try CoordinatorFixture { services, fake in
                    services.stopTransport = { if hold { try? await gate.enter() }; fake.stop("transport") }
                }
                do {
                    await f.state.activate(profile: f.profile); hold = true
                    let stop = Task { await f.state.deactivate() }
                    try await gate.waitUntilEntered()
                    let generation = f.owner.desiredRuntime.generation
                    await f.state.apply(profile: f.changed())
                    try diagnosticRequire(f.owner.desiredRuntime.generation == generation, "Late editor update replaced Stop")
                    hold = false; gate.release(); await stop.value
                    try diagnosticRequire(!f.state.isActive, "Late editor update resurrected audio")
                    await f.cleanUp()
                } catch { hold = false; gate.release(); await f.cleanUp(); throw error }
            },
            check("C32", "Shutdown cleans a late acquisition even when the service ignores cancellation") {
                let gate = DiagnosticManualGate(); defer { gate.release() }
                let f = try CoordinatorFixture { services, fake in
                    services.startEngine = { try? await gate.enter(); fake.start("engine") }
                }
                do {
                    let task = Task { await f.state.activate(profile: f.profile) }
                    try await gate.waitUntilEntered(); f.state.shutdownSynchronously(); gate.release(); await task.value
                    try diagnosticRequire(!f.state.isActive && f.fake.resources.isEmpty, "Late acquired engine survived shutdown")
                    await f.cleanUp()
                } catch { gate.release(); await f.cleanUp(); throw error }
            },
            fixture("C33", "Superseded Save receipt cannot commit acknowledgement") { f in
                await f.state.activate(profile: f.profile); let receipt = try await f.receipt()
                await f.state.deactivate()
                do { try f.owner.commit(receipt); throw DiagnosticFailure(message: "Old receipt committed") }
                catch ProfileSettingsError.cancelled { }
                try diagnosticRequire(f.state.acknowledgedPlanRevision == nil, "Old receipt published a plan")
            },
            check("C34", "External output selection during final startup validation is preserved") {
                let gate = DiagnosticManualGate(); defer { gate.release() }
                let f = try CoordinatorFixture { services, _ in services.nominalRate = { _ in try? await gate.enter(); return 48_000 } }
                do {
                    let task = Task { await f.state.activate(profile: f.profile) }
                    try await gate.waitUntilEntered(); f.fake.defaultUID = "diagnostic.external-selection"
                    gate.release(); await task.value
                    try diagnosticRequire(!f.state.isActive && f.fake.defaultUID == "diagnostic.external-selection", "Startup overwrote external selection")
                    await f.cleanUp()
                } catch { gate.release(); await f.cleanUp(); throw error }
            },
            check("C35", "Startup endpoint maintenance runs on the lifecycle worker") {
                let gate = DiagnosticManualGate(); defer { gate.release() }
                let f = try CoordinatorFixture { services, fake in
                    services.hideBridge = { try await gate.enter(); fake.record("hide bridge") }
                }
                do {
                    f.owner.requestStartupPresentation(publishProfiles: true)
                    try await gate.waitUntilEntered()
                    let generation = f.owner.desiredRuntime.generation
                    let start = Task { await f.state.activate(profile: f.profile) }
                    try await coordinatorWait { f.owner.desiredRuntime.generation > generation }
                    try diagnosticRequire(!f.fake.events.contains("start engine"), "Activation overlapped endpoint maintenance")
                    gate.release(); await start.value
                    try diagnosticRequire(f.state.isActive && f.owner.maximumWorkerCount == 1, "Startup worker did not settle")
                    await f.cleanUp()
                } catch { gate.release(); await f.cleanUp(); throw error }
            },
            fixture("C36", "Disabled-profile maintenance cannot redirect an owned audio session") { f in
                await f.state.activate(profile: f.profile)
                let session = f.state.activeSession, route = f.fake.defaultUID
                do {
                    try await f.owner.synchronizeProfileEndpoints(restoringDisabledProfile: f.profile)
                    throw DiagnosticFailure(message: "Maintenance redirected an owned route")
                } catch ProfileSettingsError.busy { }
                try diagnosticRequire(f.state.activeSession == session && f.fake.defaultUID == route,
                    "Endpoint maintenance stole route ownership")
            },
            check("C37", "Manual Stop remains a retirement barrier before same-profile reactivation") {
                let gate = DiagnosticManualGate(); defer { gate.release() }; var hold = false
                let f = try CoordinatorFixture { services, fake in
                    services.resolveOutput = { _ in if hold { try? await gate.enter() }; return fake.output }
                }
                do {
                    await f.state.activate(profile: f.profile)
                    let original = try coordinatorOwnership(f.owner); hold = true
                    let edit = Task { await f.state.apply(profile: f.profile) }
                    try await gate.waitUntilEntered(); await f.state.deactivate()
                    let generation = f.owner.desiredRuntime.generation
                    let reactivate = Task { await f.state.activate(profile: f.profile) }
                    try await coordinatorWait { f.owner.desiredRuntime.generation > generation }
                    hold = false; gate.release(); await edit.value; await reactivate.value
                    try diagnosticRequire(f.state.isActive && f.owner.currentOwnershipID != original
                        && f.fake.events.filter { $0 == "stop engine" }.count == 1,
                        "Same-profile activation coalesced away the manual Stop barrier")
                    await f.cleanUp()
                } catch { hold = false; gate.release(); await f.cleanUp(); throw error }
            },
            fixture("C38", "Known transport failure cannot be acknowledged as active", configure: { services, fake in
                services.transportError = { fake.resources.contains("transport") ? "Transport failed during readiness" : nil }
            }) { f in
                await f.state.activate(profile: f.profile)
                try diagnosticRequire(!f.state.isActive && f.fake.resources.isEmpty && !f.fake.events.contains("notify activation"),
                    "Known failed transport was acknowledged")
            },
            fixture("C39", "Same-profile activation intent uses plan requirements without needless restart") { f in
                await f.state.activate(profile: f.profile)
                let original = try coordinatorOwnership(f.owner)
                await f.state.activate(profile: f.changed())
                try diagnosticRequire(f.owner.currentOwnershipID == original && f.fake.graphs.count == 2
                    && !f.fake.events.contains("stop engine"), "Compatible same-profile intent restarted the pipeline")
            },
            fixture("C30", "Many concurrent commands never create two transition workers") { f in
                let gate = DiagnosticManualGate(); defer { gate.release() }; f.fake.scenario.routingGate = gate
                var tasks = [Task { await f.state.activate(profile: f.profile) }]
                try await gate.waitUntilEntered()
                for _ in 0..<12 {
                    let generation = f.owner.desiredRuntime.generation
                    tasks.append(Task { await f.state.activate(profile: f.profile) })
                    try await coordinatorWait { f.owner.desiredRuntime.generation > generation }
                }
                await f.state.deactivate(); gate.release()
                for task in tasks { await task.value }
                try diagnosticRequire(f.owner.maximumWorkerCount == 1 && !f.state.isActive, "Multiple workers or stale final state")
            }
        ]
    }
}

@MainActor
private func coordinatorWait(_ predicate: () -> Bool) async throws {
    for _ in 0..<10_000 {
        if predicate() { return }
        try Task.checkCancellation(); await Task.yield()
    }
    throw DiagnosticFailure(message: "Intent was not submitted")
}
@MainActor
private func coordinatorOwnership(_ owner: AudioRuntimeCoordinator) throws -> RuntimeOwnershipID {
    guard let id = owner.currentOwnershipID else { throw DiagnosticFailure(message: "No resource owner") }
    return id
}
