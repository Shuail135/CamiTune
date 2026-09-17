import CryptoKit
import Foundation

extension DeveloperSelfTests {
    static func runtimePlanCases() -> [DiagnosticCase] {
        func check(_ id: String, _ name: String, _ body: @escaping @MainActor (DiagnosticSandbox) async throws -> String) -> DiagnosticCase {
            DiagnosticCase(id: id, suite: "Runtime Plan Authority", name: name, safety: .simulated) {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                return .init(summary: try await body(box))
            }
        }
        return [
            check("R01", "Stereo preparation needs no invented topology") { _ in
                let fake = DiagnosticRuntimeFakes(); var services = fake.services()
                services.probeTopology = { _ in throw DiagnosticFailure(message: "Stereo requested speaker geometry") }
                let profile = DiagnosticSandbox.profile()
                let plan = try await AudioRuntimePlanPreparer().prepare(profile: profile,
                    revision: .init(profileID: profile.id, generation: 1), services: services)
                try diagnosticRequire(plan.hardwareEvidence.speakerTopology == nil && plan.sourceFormat.channelCount == 2
                    && plan.dspInputFormat.channelCount == 2 && plan.hardwareOutputFormat.channelCount == 2,
                    "Stereo used a separate/fabricated topology path")
                try diagnosticRequire(fake.resources.isEmpty, "Preparation started runtime resources")
                return "Stereo compiles from endpoint, channel-count, and rate evidence without speaker geometry"
            },
            check("R02", "Multichannel uses the same prepared compiler") { _ in
                var profile = DiagnosticSandbox.profile(); profile.endpointKind = .speakers
                let topology = try DiagnosticHardware(channels: 8).topology(for: profile.outputDeviceUID, sampleRate: 48_000).speakerTopology
                profile.speakerTopology = SpeakerLayoutGeometry.acceptingDefaultRoles(topology)
                let plan = try AudioRuntimePlanPreparer.prepare(profile: profile, detectedHardware: topology)
                try diagnosticRequire(plan.hardwareOutputFormat.channelCount == 8 && plan.physicalEndpointFormat.channelCount == 8
                    && plan.processingGraph.outputFormat == plan.hardwareOutputFormat, "Multichannel formats diverged")
                var personal = DiagnosticSandbox.profile(); personal.endpointKind = .audioInterface
                personal.audioInterface = .init(deviceUID: personal.outputDeviceUID, hardwareChannelCount: 8,
                    outputChannels: [1, 6], connectedEndpoint: .headphones)
                let interface = try AudioRuntimePlanPreparer.prepare(profile: personal, detectedHardware: topology)
                try diagnosticRequire(interface.sourceFormat.channelCount == 8 && interface.dspInputFormat.channelCount == 2
                    && interface.physicalEndpointFormat.channelCount == 2 && interface.hardwareOutputFormat.channelCount == 8,
                    "Personal interface collapsed distinct source, DSP, endpoint, and hardware formats")
                return "Multichannel and personal interface plans retain all four format distinctions"
            },
            check("R03", "Hardware mismatch fails before runtime mutation") { box in
                let fake = DiagnosticRuntimeFakes(); var services = fake.services()
                services.outputChannelCount = { _ in 6 }
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: services)
                do { _ = try await state.prepareRuntimePlan(profile: DiagnosticSandbox.profile()) }
                catch SpeakerTopologyError.hardwareLayoutChanged {
                    try diagnosticRequire(fake.resources.isEmpty && fake.graphs.isEmpty, "Invalid candidate touched audio")
                    return "Mismatched physical width rejected before graph/PCM changes"
                }
                throw DiagnosticFailure(message: "Mismatched hardware was accepted")
            },
            check("R04", "Missing assets fail in preparation") { box in
                var profile = DiagnosticSandbox.profile()
                let asset = runtimePlanAsset()
                profile.processing.global.stages.append(.init(processor: .convolution(.init(asset: asset))))
                let fake = DiagnosticRuntimeFakes()
                do {
                    _ = try await AudioRuntimePlanPreparer().prepare(profile: profile,
                        revision: .init(profileID: profile.id, generation: 4), services: fake.services())
                } catch ProcessingGraphError.impulseResponseMissing {
                    try diagnosticRequire(fake.graphs.isEmpty && fake.resources.isEmpty, "Missing asset reached runtime")
                    return "Missing convolution file rejected before compile/backend/writer application"
                }
                throw DiagnosticFailure(message: "Missing asset was accepted")
            },
            check("R05", "Compilation is pure and deterministic") { box in
                var profile = DiagnosticSandbox.profile()
                let source = box.directory.appendingPathComponent("source.wav")
                try runtimePlanImpulseWAV().write(to: source)
                let store = ImpulseResponseStore(directory: box.directory.appendingPathComponent("assets"))
                let asset = try store.importWAV(at: source, expectedSampleRate: 48_000)
                profile.processing.global.stages.append(.init(processor: .convolution(.init(asset: asset))))
                profile = try AudioRuntimePlanPreparer.normalize(profile)
                let assets = try PreparedRuntimeAssets.prepare(profile: profile, directory: store.directory)
                let nonexistent = store.url(for: asset)
                try diagnosticRequire(assets.impulseResponses[asset.id]?.sha256.count == 64, "Asset content identity was not prepared")
                try FileManager.default.removeItem(at: nonexistent)
                let input = PreparedRuntimeInputs(revision: .init(profileID: profile.id, generation: 5), preparedAt: Date(timeIntervalSince1970: 0),
                    profile: profile, hardware: runtimePlanStereoEvidence(profile), assets: assets)
                let first = try AudioRuntimePlanCompiler().compile(input)
                let second = try AudioRuntimePlanCompiler().compile(input)
                try diagnosticRequire(first == second && !FileManager.default.fileExists(atPath: nonexistent.path),
                    "Compiler regenerated identity or consulted external assets")
                return "Identical prepared inputs produce identical plans without reading the referenced file"
            },
            check("R06", "Graph and renderer retain one intent revision") { _ in
                let profile = runtimePlanChangedProfile(DiagnosticSandbox.profile())
                let plan = try await AudioRuntimePlanPreparer().prepare(profile: profile,
                    revision: .init(profileID: profile.id, generation: 42), services: DiagnosticRuntimeFakes().services())
                try diagnosticRequire(plan.revision.generation == 42 && plan.renderConfiguration.revision == plan.revision
                    && plan.renderConfiguration.spatialContentMode == profile.spatialContentMode
                    && plan.playbackContext == PerAppPlaybackContext(profile: profile), "Mixed intent revisions")
                return "Revision 42 owns graph, renderer values, and default per-app playback context"
            },
            check("R07", "Delayed live RPC cannot reread a newer profile") { box in
                let fake = DiagnosticRuntimeFakes(); let original = DiagnosticSandbox.profile()
                box.profiles.profiles = [original]
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                await state.activate(profile: original)
                var a = runtimePlanChangedProfile(original); a.spatialContentMode = .musicSafe
                a.processing.global.stages.append(.init(processor: .gain(.init(gainDB: -3))))
                let gate = DiagnosticManualGate(); fake.scenario.graphGate = gate
                let request = Task { await state.apply(profile: a) }
                do {
                    try await gate.waitUntilEntered()
                    var b = a; b.spatialContentMode = .movieVideo; b.virtualSurroundLayout.upmixStereo = false
                    box.profiles.profiles = [b]
                    gate.release(); await request.value
                    try diagnosticRequire(fake.renderConfigurations.last?.spatialContentMode == a.spatialContentMode
                        && fake.renderConfigurations.last?.virtualSurroundLayout == a.virtualSurroundLayout,
                        "RPC for A configured renderer from mutable B")
                    await state.deactivate()
                    return "Graph A acknowledgement applies renderer A even when profile storage already contains B"
                } catch { gate.release(); await request.value; await state.deactivate(); throw error }
            },
            check("R08", "In-place settings applies every renderer field") { box in
                let fake = DiagnosticRuntimeFakes(); var original = DiagnosticSandbox.profile(); original.endpointKind = .headphones
                box.profiles.profiles = [original]
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                await state.activate(profile: original)
                var changed = runtimePlanChangedProfile(original)
                let response = FrequencyResponse(name: "Fixture", points: [.init(frequency: 20, magnitudeDB: 0), .init(frequency: 20_000, magnitudeDB: 0)])
                changed.setPersonalReferenceCorrection(.init(deviceName: "Fixture", policy: .recommended,
                    measurement: response, target: response, curve: .init(points: []), filters: [], preampDB: 0))
                changed.setPlaybackMode(.referencePlayback)
                box.profiles.profiles = [changed]
                var draft = ProfileSettingsDraft(profile: changed, activation: box.profiles.activationMode(for: changed))
                draft.spatialSettings.cinema.amount = 0.6
                do {
                    try await state.saveProfileSettings(draft)
                    let candidate = try draft.candidate()
                    try diagnosticRequire(candidate.playbackMode != original.playbackMode
                        && candidate.personalReferenceCorrection != original.personalReferenceCorrection,
                        "Fixture did not exercise mode/correction changes")
                    guard let applied = fake.renderConfigurations.last else { throw DiagnosticFailure(message: "No renderer update") }
                    let expected = RenderConfiguration(profile: candidate, revision: applied.revision)
                    try diagnosticRequire(applied == expected && fake.events.filter { $0 == "start PCM" }.count == 1,
                        "In-place settings omitted renderer fields or changed restart policy")
                    await state.deactivate()
                    return "Complete renderer value replaces the old subset of settings, without restarting PCM"
                } catch { await state.deactivate(); throw error }
            },
            check("R09", "Activation and live apply derive equivalent configuration") { box in
                let fake = DiagnosticRuntimeFakes(); let profile = runtimePlanChangedProfile(DiagnosticSandbox.profile())
                box.profiles.profiles = [profile]
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                await state.activate(profile: profile)
                await state.apply(profile: profile)
                do {
                    try diagnosticRequire(fake.graphs.count == 1 && state.lastRuntimePlanDelta?.isNoOp == true, "Equivalent live plan repeated graph work")
                    let configurations = fake.renderConfigurations
                    try diagnosticRequire(configurations.count == 1 && configurations.allSatisfy {
                        $0 == RenderConfiguration(profile: profile, revision: $0.revision)
                    }, "Activation/live renderer interpretation differs")
                    await state.deactivate()
                    return "Activation and live apply compile equal acoustic values through the same service"
                } catch { await state.deactivate(); throw error }
            },
            check("R10", "Writer snapshots all configuration fields per block") { box in
                let router = PCMRouter(); let profile = DiagnosticSandbox.profile()
                let a = RenderConfiguration(profile: profile, revision: .init(profileID: profile.id, generation: 10))
                let b = RenderConfiguration(profile: runtimePlanChangedProfile(profile), revision: .init(profileID: profile.id, generation: 11))
                let entered = DiagnosticManualGate(); let second = DiagnosticManualGate()
                let release = DispatchSemaphore(value: 0); let observations = RuntimePlanWriterObservations()
                let url = box.directory.appendingPathComponent("coherent.pcm")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let sink = try FileHandle(forWritingTo: url); defer { try? sink.close() }
                await router.start(camillaSink: sink, renderConfiguration: a, configurationObserver: { configuration in
                    let count = observations.append(configuration)
                    if count == 1 { Task { @MainActor in entered.release() }; release.wait() }
                    else { Task { @MainActor in second.release() } }
                })
                let frame = PCMFrame(interleaved: Array(repeating: Float(0.1), count: 1024), channelCount: 2, sampleRate: 48_000)
                do {
                    router.route(frame); try await entered.enter()
                    router.setRenderConfiguration(b); router.route(frame); release.signal()
                    try await second.enter(); await router.stopWithoutBlockingUI()
                    try diagnosticRequire(observations.values == [a, b], "A writer block observed mixed configuration fields")
                    return "Held block consumes all of A; following block consumes all of B"
                } catch { release.signal(); await router.stopWithoutBlockingUI(); throw error }
            },
            check("R11", "Failed settings commit rolls back the acknowledged plan") { box in
                let fake = DiagnosticRuntimeFakes(); let original = DiagnosticSandbox.profile()
                box.profiles.profiles = [original]; box.profiles.flushPendingSaveSynchronously()
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                await state.activate(profile: original)
                let oldRevision = state.acknowledgedPlanRevision; let oldGraph = fake.graphs.last; let oldRender = fake.renderConfigurations.last
                let storage = box.directory.appendingPathComponent("profiles.json")
                try FileManager.default.removeItem(at: storage)
                try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
                var draft = ProfileSettingsDraft(profile: original, activation: box.profiles.activationMode(for: original))
                draft.processing = original.processing; draft.processing?.global.stages.append(.init(processor: .gain(.init(gainDB: -3))))
                var failed = false
                do { try await state.saveProfileSettings(draft) } catch { failed = true }
                do {
                    try diagnosticRequire(failed && fake.graphs.count == 3 && fake.graphs.last == oldGraph
                        && fake.renderConfigurations.last == oldRender && state.acknowledgedPlanRevision == oldRevision,
                        "Rollback rebuilt or substituted the old acknowledged plan")
                    await state.deactivate()
                    return "Persistence failure restores exactly the old graph, renderer, context, and plan revision"
                } catch { await state.deactivate(); throw error }
            },
            check("R15", "Restart rollback reuses the original prepared revision") { box in
                let fake = DiagnosticRuntimeFakes(.init(transportResults: [true, true, true]))
                let original = DiagnosticSandbox.profile(); box.profiles.profiles = [original]
                box.profiles.flushPendingSaveSynchronously()
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                await state.activate(profile: original)
                let oldRevision = state.acknowledgedPlanRevision; let oldGraph = fake.graphs.last
                let oldRender = fake.renderConfigurations.last
                let storage = box.directory.appendingPathComponent("profiles.json")
                try FileManager.default.removeItem(at: storage)
                try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
                var draft = ProfileSettingsDraft(profile: original, activation: box.profiles.activationMode(for: original))
                draft.sampleRate = 96_000
                var failed = false
                do { try await state.saveProfileSettings(draft) } catch { failed = true }
                do {
                    try diagnosticRequire(failed && fake.events.filter { $0 == "start PCM" }.count == 3
                        && fake.graphs.last == oldGraph && fake.renderConfigurations.last == oldRender
                        && state.acknowledgedPlanRevision == oldRevision, "Restart rollback recompiled the old intent")
                    await state.deactivate()
                    return "Failed post-restart persistence restores the original graph/renderer revision without repreparation"
                } catch { await state.deactivate(); throw error }
            },
            check("R12", "Export describes the prepared revision") { _ in
                let profile = runtimePlanChangedProfile(DiagnosticSandbox.profile())
                let plan = try await AudioRuntimePlanPreparer().prepare(profile: profile,
                    revision: .init(profileID: profile.id, generation: 12), services: DiagnosticRuntimeFakes().services())
                let export = try AudioRuntimePlanDiagnostic(plan: plan)
                let decoded = try JSONDecoder.runtimePlan.decode(AudioRuntimePlanDiagnostic.self, from: export.json())
                try diagnosticRequire(decoded.revision == plan.revision && decoded.renderConfiguration == plan.renderConfiguration
                    && decoded.hardwareFingerprint == plan.hardwareFingerprint && decoded.sourceFormat == plan.sourceFormat
                    && decoded.camillaDSPConfiguration == CamillaDSPCompiler().compile(plan.processingGraph).yaml,
                    "Export reinterpreted profile intent")
                return "Exported formats, graph, fingerprint, and renderer belong to one revision"
            },
            check("R13", "Hardware change invalidates a waiting candidate") { box in
                let gate = DiagnosticManualGate(); let fake = DiagnosticRuntimeFakes(.init(routingGate: gate))
                var width = 2; var services = fake.services(); services.outputChannelCount = { _ in width }
                let profile = DiagnosticSandbox.profile(); box.profiles.profiles = [profile]
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: services)
                let activation = Task { await state.activate(profile: profile) }
                do {
                    try await gate.waitUntilEntered(); width = 6; gate.release(); await activation.value
                    try diagnosticRequire(!state.isActive && state.acknowledgedPlanRevision == nil
                        && !fake.events.contains("start engine") && !fake.events.contains("set rate physical"),
                        "Stale hardware evidence was executed")
                    return "Changed channel fingerprint rejected after endpoint wait and before rate/engine changes"
                } catch { gate.release(); await activation.value; await state.deactivate(); throw error }
            },
            check("R14", "Sent plans commit coherently while newer edits coalesce") { box in
                for latestFails in [false, true] {
                    let fake = DiagnosticRuntimeFakes(); let profile = DiagnosticSandbox.profile(); box.profiles.profiles = [profile]
                    let nextGate = DiagnosticManualGate()
                    var services = fake.services(); let applyGraph = services.applyGraph
                    services.applyGraph = { graph in
                        if fake.graphs.count == 2 { try await nextGate.enter() }
                        try await applyGraph(graph)
                    }
                    let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: services)
                    await state.activate(profile: profile)
                    let gate = DiagnosticManualGate(); fake.scenario.graphGate = gate
                    var a = runtimePlanChangedProfile(profile)
                    a.processing.global.stages.append(.init(processor: .gain(.init(gainDB: -3))))
                    var b = profile; b.spatialContentMode = .fixed
                    var c = profile; c.spatialContentMode = .movieVideo
                    c.processing.global.stages.append(.init(processor: .gain(.init(gainDB: -6))))
                    let first = Task { await state.apply(profile: a) }
                    do {
                        try await gate.waitUntilEntered()
                        let revision = state.liveApplyRequestRevision
                        let middle = Task { await state.apply(profile: b) }
                        while state.liveApplyRequestRevision < revision + 1 { try Task.checkCancellation(); await Task.yield() }
                        let latest = Task { await state.apply(profile: c) }
                        while state.liveApplyRequestRevision < revision + 2 { try Task.checkCancellation(); await Task.yield() }
                        gate.release()
                        try await nextGate.waitUntilEntered()
                        guard let transient = fake.renderConfigurations.last else { throw fake.fail("No transient renderer") }
                        try diagnosticRequire(fake.graphs.count == 2 && fake.graphs[0] != fake.graphs[1]
                            && fake.renderConfigurations.count == 2
                            && transient == RenderConfiguration(profile: a, revision: transient.revision)
                            && state.acknowledgedPlanRevision == transient.revision,
                            "Acknowledged graph A left the renderer or acknowledged plan on the original revision")
                        fake.scenario.graphFails = latestFails
                        nextGate.release(); await first.value; await middle.value; await latest.value
                        try diagnosticRequire(fake.graphs.count == 3
                            && fake.renderConfigurations.count == (latestFails ? 2 : 3),
                            "Unsent middle edit was applied or sent edit was discarded")
                        if latestFails {
                            try diagnosticRequire(fake.renderConfigurations.last == transient
                                && state.acknowledgedPlanRevision == transient.revision && state.errorMessage != nil,
                                "Failed latest edit displaced the last acknowledged configuration")
                        } else {
                            try diagnosticRequire(fake.renderConfigurations.last?.spatialContentMode == .movieVideo
                                && state.acknowledgedPlanRevision == fake.renderConfigurations.last?.revision,
                                "Latest edit did not become the complete applied configuration")
                        }
                        await state.deactivate()
                    } catch { gate.release(); nextGate.release(); await first.value; await state.deactivate(); throw error }
                }
                return "Sent A commits graph/renderer/revision; B coalesces; successful C replaces A, failed C retains A"
            },
            check("R16", "Late acknowledgement cannot restore a retired session") { box in
                for reactivate in [false, true] {
                    let fake = DiagnosticRuntimeFakes(); let profile = DiagnosticSandbox.profile(); box.profiles.profiles = [profile]
                    let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                    await state.activate(profile: profile)
                    let oldSession = state.activeSession?.id
                    let gate = DiagnosticManualGate(); fake.scenario.graphGate = gate
                    var changed = runtimePlanChangedProfile(profile)
                    changed.processing.global.stages.append(.init(processor: .gain(.init(gainDB: -3))))
                    let request = Task { await state.apply(profile: changed) }
                    do {
                        try await gate.waitUntilEntered()
                        await state.deactivate()
                        fake.scenario.graphGate = nil
                        gate.release(); await request.value
                        await state.runtimeCoordinator.waitUntilSettled()
                        try diagnosticRequire(!state.isActive && state.acknowledgedPlanRevision == nil,
                            "Sent exchange resurrected the runtime after Stop")
                        let retiredConfigurations = fake.renderConfigurations
                        if reactivate {
                            fake.scenario.transportResults.append(true)
                            await state.activate(profile: profile)
                            try diagnosticRequire(state.isActive && state.activeSession?.id != oldSession,
                                "Replacement session did not start")
                            try diagnosticRequire(fake.renderConfigurations.count == retiredConfigurations.count + 1,
                                "Retired exchange changed replacement renderer")
                        }
                        await state.deactivate()
                    } catch { gate.release(); await request.value; await state.deactivate(); throw error }
                }
                return "Sent exchange becomes coherent before retirement; a replacement owns a distinct session"
            },
            check("R17", "SHA-256 streams complete files across chunk boundaries") { box in
                let url = box.directory.appendingPathComponent("hash-fixture")
                for count in [0, 1, 65_535, 65_536, 65_537, 3 * 65_536 + 19] {
                    let bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 251) })
                    try bytes.write(to: url)
                    let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    let actual = try PreparedRuntimeAssets.contentSHA256(at: url)
                    try diagnosticRequire(actual == expected,
                        "Streaming digest omitted/duplicated bytes at file length \(count)")
                }
                try FileManager.default.removeItem(at: url)
                do { _ = try PreparedRuntimeAssets.contentSHA256(at: url) }
                catch { return "Streaming digests match complete-file SHA-256 for empty, exact-boundary, and multi-chunk files; read errors propagate" }
                throw DiagnosticFailure(message: "Missing-file read unexpectedly succeeded")
            }
        ]
    }

    @MainActor private static func runtimePlanStereoEvidence(_ profile: DeviceProfile) -> RuntimeHardwareEvidence {
        .init(output: profile.outputDevice, sampleRate: profile.sampleRate, physicalChannelCount: 2,
              speakerTopology: nil, fingerprint: .init(deviceUID: profile.outputDeviceUID, channelCount: 2), simulated: true)
    }
    static func runtimePlanImpulseWAV() -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8)); append(UInt32(36 + 64 * 4)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(3)); append(UInt16(1)); append(UInt32(48_000))
        append(UInt32(48_000 * 4)); append(UInt16(4)); append(UInt16(32))
        data.append(Data("data".utf8)); append(UInt32(64 * 4))
        for index in 0..<64 { append(Float(index == 0 ? 1 : 0).bitPattern) }
        return data
    }
    private static func runtimePlanAsset() -> ImpulseResponseAsset {
        let id = UUID()
        return .init(id: id, fileName: "\(id.uuidString.lowercased()).wav", displayName: "Fixture impulse",
                     sampleRate: 48_000, channelCount: 1, frameCount: 64, maximumMagnitudeDBByChannel: [0])
    }
    private static func runtimePlanChangedProfile(_ original: DeviceProfile) -> DeviceProfile {
        var profile = original
        profile.spatialContentMode = .musicSafe
        profile.virtualSurroundLayout.upmixStereo = true
        profile.spatialSettings.cinema.amount = 0.3
        profile.spatialListenerProfile = .init(name: "Fixture listener", outputDeviceUID: profile.outputDeviceUID,
            savedAt: Date(timeIntervalSince1970: 0), position: .init(), tuning: .init(width: 0.1), completedComparisons: 4)
        return profile
    }
}

private final class RuntimePlanWriterObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RenderConfiguration] = []
    func append(_ value: RenderConfiguration) -> Int { lock.lock(); defer { lock.unlock() }; storage.append(value); return storage.count }
    var values: [RenderConfiguration] { lock.lock(); defer { lock.unlock() }; return storage }
}
private extension JSONDecoder {
    static var runtimePlan: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
