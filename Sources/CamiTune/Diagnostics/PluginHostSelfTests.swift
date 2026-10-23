import CamiTuneAudio
import CamiTuneDomain
import Foundation

extension DeveloperSelfTests {
    static func pluginCases() -> [DiagnosticCase] {
        [
            .init(id: "PL01", suite: "Plug-ins", name: "Profiles migrate and preserve opaque plug-in state", safety: .simulated) {
                var profile = diffProfile()
                let data = try JSONEncoder().encode(profile)
                var document = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                document.removeValue(forKey: "pluginRack")
                let legacy = try JSONDecoder().decode(DeviceProfile.self, from: JSONSerialization.data(withJSONObject: document))
                try diagnosticRequire(legacy.pluginRack.slots.isEmpty, "Legacy profile gained effects")
                profile.pluginRack.slots = [.init(plugin: pluginTestDescriptor(), state: Data([0, 1, 2, 255]))]
                let restored = try JSONDecoder().decode(DeviceProfile.self, from: JSONEncoder().encode(profile))
                try diagnosticRequire(restored.pluginRack == profile.pluginRack, "Plug-in identity/state did not survive persistence")
                var duplicate = profile.pluginRack; duplicate.slots.append(duplicate.slots[0])
                do { try duplicate.validate(); throw DiagnosticFailure(message: "Duplicate slot IDs accepted") }
                catch is PluginRackError {}
                return .init(summary: "Legacy profiles remain empty; state and identity round-trip; duplicate slots rejected")
            },
            .init(id: "PL02", suite: "Plug-ins", name: "Rack changes prepare in place with final protection", safety: .simulated) {
                let profile = diffProfile(); var changed = profile
                changed.pluginRack.slots = [.init(plugin: pluginTestDescriptor())]
                let old = try diffPlan(profile), new = try diffPlan(changed, generation: 2)
                let delta = RuntimePlanDiffer().delta(from: old, to: new)
                try diagnosticRequire(delta.renderer.pluginRackChanged && delta.requirements.requiresRenderConfigurationUpdate
                    && !delta.requirements.usesExistingRestartPath, "Rack change restarted the audio pipeline")
                try diagnosticRequire(new.processingGraph.processors.contains { if case .limiter = $0.implementation { return true }; return false }, "Active rack has no output limiter")
                try diagnosticRequire(!changed.processing.limiterEnabled, "Runtime protection changed saved equalizer settings")
                return .init(summary: "Rack changes are prepared in place; final limiter is runtime-only")
            },
            .init(id: "PL03", suite: "Plug-ins", name: "Protection rejects invalid samples and bounds loud output", safety: .simulated) {
                var protection = PluginOutputProtection()
                var samples: [Float] = [.nan, .infinity, 1000, -1000, 0.25, -0.25]
                protection.process(&samples, sampleRate: 48000, enabled: true)
                try diagnosticRequire(samples.allSatisfy { $0.isFinite && abs($0) <= 0.981 }, "Invalid or excessive signal escaped protection")
                var identity = PluginOutputProtection(), clean: [Float] = [0.1, -0.2, 0.3, -0.4]
                let original = clean; identity.process(&clean, sampleRate: 48000, enabled: false)
                try diagnosticRequire(clean == original, "Bypassed rack changed samples")
                return .init(summary: "Invalid samples become silence; loud samples are bounded; bypass preserves PCM")
            },
            .init(id: "PL04", suite: "Plug-ins", name: "Delivery renders tails, bypasses cleanly and silences faults", safety: .simulated) {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                let path = box.directory.appendingPathComponent("plugin-delivery.pcm")
                FileManager.default.createFile(atPath: path.path, contents: nil)
                let file = try FileHandle(forWritingTo: path), router = PCMRouter()
                defer { router.stop(); try? file.close() }
                await router.start(camillaSink: file, activeRoute: nil, renderConfiguration: .init(),
                    deliveryConfiguration: .legacy(sampleRate: 48000, chunkSize: 128), backendChunkFrames: 128,
                    pluginProcessor: PluginDeliveryFixture())
                func deliver(frames: Int, value: Float, expectedFrames: Int) async throws -> [Float] {
                    router.route(.init(interleaved: Array(repeating: value, count: frames * 2), channelCount: 2, sampleRate: 48000))
                    router.finishProducerEpoch()
                    let deadline = PerformanceClock.now().advanced(seconds: 2)
                    var bytes = Data()
                    while PerformanceClock.now() < deadline {
                        bytes = try Data(contentsOf: path)
                        if bytes.count >= expectedFrames * 8 { break }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    try diagnosticRequire(bytes.count == expectedFrames * 8, "Plug-in tail or backend alignment lost/duplicated audio: \(bytes.count) bytes")
                    return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                }
                let processed = try await deliver(frames: 512, value: 0.2, expectedFrames: 768)
                try diagnosticRequire(processed[600] == 0.1 && processed.suffix(512).allSatisfy { $0 == 0.04 }, "Rack gain or tail did not reach delivery PCM")
                let work = router.takeAudioBufferWork()
                try diagnosticRequire(work.audioSeconds > 0 && work.pluginLoad > 0 && !work.pluginFailed,
                    "Plug-in work measurements were missing or treated healthy audio as failure")
                router.setPluginProcessor(nil)
                let bypassed = try await deliver(frames: 128, value: 0.3, expectedFrames: 896)
                try diagnosticRequire(bypassed.suffix(2).allSatisfy { $0 == 0.3 }, "Bypass transition did not finish across the resampler drain")
                router.setPluginProcessor(PluginDeliveryFixture(failing: true))
                let failed = try await deliver(frames: 512, value: 0.3, expectedFrames: 1408)
                try diagnosticRequire(failed.suffix(512).allSatisfy { $0 == 0 }, "Failed rack leaked unprocessed audio")
                return .init(summary: "Delivery applies gain, drains finite tails, restores dry audio and fades failures to silence")
            },
            .init(id: "PL05", suite: "Plug-ins", name: "Discovery is metadata-only; custom folders and deferred checks persist", safety: .simulated) {
                try await pluginCatalogDiscovery()
                return .init(summary: "Multiple folders, JSON5, deduplication, cache invalidation, cancellation and deferred factory checks passed")
            },
            .init(id: "PL06", suite: "Plug-ins", name: "Racks follow every supported profile channel layout", safety: .simulated) {
                let layouts = SpeakerLayoutTemplate.all.map(\.endpointRoles) + (1...32).map { Array(repeating: ChannelRole.unknown, count: $0) }
                for roles in layouts {
                    var profile = pluginChannelProfile(roles: roles)
                    profile.pluginRack.slots = [.init(plugin: pluginTestDescriptor())]
                    let plan = try diffPlan(profile)
                    try diagnosticRequire(plan.dspInputFormat.channels.map { $0.role ?? .unknown } == roles, "Rack changed the profile channel map")
                    try diagnosticRequire(plan.processingGraph.processors.contains { if case .limiter = $0.implementation { return true }; return false }, "Multichannel rack lost final output protection")
                }
                return .init(summary: "All speaker templates and 1–32 custom channels prepare with automatic rack routing and output protection")
            },
            .init(id: "PL07", suite: "Plug-ins", name: "Protection and failure fades cover every channel", safety: .simulated) {
                for channels in 1...32 {
                    var protection = PluginOutputProtection()
                    var samples = [Float](repeating: 0.25, count: 256 * channels)
                    samples[channels - 1] = 4
                    samples[channels] = .nan
                    protection.process(&samples, sampleRate: 48000, enabled: true, channelCount: channels)
                    try diagnosticRequire(samples.allSatisfy { $0.isFinite && abs($0) <= 0.981 }, "Unsafe sample escaped a multichannel rack")
                    if channels > 1 { try diagnosticRequire(abs(samples[0] / samples[channels - 1] - 0.0625) < 0.00001, "Protection changed channel balance") }
                    protection.beginTransition()
                    samples = [Float](repeating: 0, count: 256 * channels)
                    protection.process(&samples, sampleRate: 48000, enabled: true, channelCount: channels)
                    try diagnosticRequire(samples.suffix(128 * channels).allSatisfy { $0 == 0 }, "Failure fade left an audible channel")
                    var identity = PluginOutputProtection()
                    samples = (0..<(channels * 3)).map { Float($0) * 0.001 }; let original = samples
                    identity.process(&samples, sampleRate: 48000, enabled: false, channelCount: channels)
                    try diagnosticRequire(samples == original, "Multichannel bypass changed samples")
                }
                return .init(summary: "All 1–32 widths sanitize invalid samples, limit linked peaks, fade faults and preserve bypass")
            },
            .init(id: "PL08", suite: "Plug-ins", name: "Multichannel delivery preserves channel identity and tails", safety: .simulated) {
                try await pluginChannelDelivery()
                return .init(summary: "Mono, 5.1-width, 16- and 32-channel writers process every channel, drain tails and reject a stale stereo processor")
            },
            .init(id: "PL09", suite: "Plug-ins", name: "MIDI mappings migrate, persist and undo without changing audio setup", safety: .simulated) {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                var profile = diffProfile(); profile.pluginRack.slots = [.init(plugin: pluginTestDescriptor())]
                let original = profile.pluginRack
                var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
                oldJSON.removeValue(forKey: "midi")
                let legacy = try JSONDecoder().decode(PluginRack.self, from: JSONSerialization.data(withJSONObject: oldJSON))
                try diagnosticRequire(legacy == original && !legacy.midi.isEnabled, "Legacy rack enabled MIDI or lost audio settings")
                let mapping = PluginMIDIMapping(slotID: original.slots[0].id, parameterID: UInt64.max - 1, parameterName: "Frequency",
                    sourceID: -123, sourceName: "Controller", channel: 16, controller: 119, lower: 0.8, upper: 0.2)
                var legacyMappingJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mapping)) as! [String: Any]
                for key in ["input", "mode", "curve"] { legacyMappingJSON.removeValue(forKey: key) }
                let legacyMapping = try JSONDecoder().decode(PluginMIDIMapping.self, from: JSONSerialization.data(withJSONObject: legacyMappingJSON))
                try diagnosticRequire(legacyMapping == mapping, "Old mappings did not retain linear knob behavior")
                var velocity = mapping; velocity.input = .note; velocity.controller = 127; velocity.mode = .velocity; velocity.curve = .hard
                let velocityRestored = try JSONDecoder().decode(PluginMIDIMapping.self, from: JSONEncoder().encode(velocity))
                try diagnosticRequire(velocityRestored == velocity && abs(velocity.output(at: 0.5) - 0.65) < 0.000001,
                    "Velocity curve or reversed range did not persist")
                var noteMIDI = PluginMIDIConfiguration(); noteMIDI.mappings = [velocity]; try noteMIDI.validate()
                var midi = PluginMIDIConfiguration(); midi.isEnabled = true; midi.sourceID = -123; midi.channel = 16; midi.mappings = [mapping]
                var legacyMIDIJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(midi)) as! [String: Any]
                legacyMIDIJSON["sendsToPlugins"] = false
                let migratedMIDI = try JSONDecoder().decode(PluginMIDIConfiguration.self, from: JSONSerialization.data(withJSONObject: legacyMIDIJSON))
                let migratedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(migratedMIDI)) as! [String: Any]
                try diagnosticRequire(migratedMIDI == midi && migratedJSON["sendsToPlugins"] == nil,
                    "Legacy MIDI forwarding preference was retained or changed the input and mappings")
                try diagnosticRequire(migratedMIDI.programChangeSlotID == nil, "Legacy MIDI enabled program changes")
                midi.programChangeSlotID = original.slots[0].id
                profile.pluginRack.midi = midi
                let restored = try JSONDecoder().decode(DeviceProfile.self, from: JSONEncoder().encode(profile))
                try diagnosticRequire(restored.pluginRack.midi == midi && profile.pluginRack.audioConfiguration == original, "MIDI persistence changed parameter identity or audio configuration")
                var invalid = midi; invalid.mappings[0].controller = 120
                do { try invalid.validate(); throw DiagnosticFailure(message: "Reserved controller accepted for Learn") } catch is PluginRackError {}
                profile.pluginRack = original; box.profiles.profiles = [profile]
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: DiagnosticRuntimeFakes().services())
                try await state.commitPluginMIDI(midi, profileID: profile.id, action: "Map MIDI")
                try diagnosticRequire(box.profiles.profiles[0].pluginRack.midi == midi && state.history.undoStack.count == 1, "Mapping did not persist as one edit")
                // A later native editor snapshot must survive mapping undo.
                state.capturePluginState(profileID: profile.id, slotID: original.slots[0].id, data: Data([1, 2, 3]))
                await state.history.undo()
                var expected = original; expected.slots[0].state = Data([1, 2, 3])
                try diagnosticRequire(box.profiles.profiles[0].pluginRack == expected, "MIDI undo changed audio settings or rolled back a native editor snapshot")
                await state.history.redo()
                try diagnosticRequire(box.profiles.profiles[0].pluginRack.midi == midi, "MIDI redo lost the mapping")
                return .init(summary: "Legacy defaults, full parameter IDs, mapping ranges, validation, persistence and undo/redo passed")
            },
            .init(id: "PL10", suite: "Plug-ins", name: "Repeated reorders defer audio work and preserve live settings on undo", safety: .simulated) {
                try await pluginReorderBatching()
                return .init(summary: "Orders persist immediately; held drags defer loading; final order applies once; undo preserves live parameters")
            },
            .init(id: "PL11", suite: "Plug-ins", name: "Reorders serialize loading and invalidate stale snapshots", safety: .simulated) {
                try await pluginReorderScheduling()
                return .init(summary: "Moves during loading coalesce without cancellation; new drags invalidate snapshots; cancelled timers stay cancelled")
            },
            .init(id: "PL12", suite: "Plug-ins", name: "Metadata fallbacks retain effects and migrate maker names without loading binaries", safety: .simulated) {
                try pluginMetadataCompatibility()
                return .init(summary: "Bundle makers, Unicode, partial metadata, empty vendors, lazy fallback and verified-cache preservation passed")
            },
            .init(id: "PL13", suite: "Plug-ins", name: "External sends preserve packet order and bound missing input", safety: .simulated) {
                try pluginSidechainBuffers()
                return .init(summary: "Stereo sends preserve split blocks, sum clients, reject duplicates and clear stale/disconnected sources")
            },
            .init(id: "PL14", suite: "Plug-ins", name: "Mach-O discovery selects native or Intel without executing code", safety: .simulated) {
                try pluginArchitectureHeaders()
                return .init(summary: "Thin, universal and malformed headers select supported architectures without loading bundles")
            },
            .init(id: "PL15", suite: "Plug-ins", name: "Instrument delivery is paced and respects real source epochs", safety: .simulated) {
                try await pluginInstrumentDelivery()
                return .init(summary: "Idle instruments render at audio rate; source starvation does not invent frames; END resumes instruments and bypass stops them")
            }
        ]
    }

    private static func pluginSidechainBuffers() throws {
        let source = PluginSidechainSource(kind: .application, id: "fixture", name: "Fixture")
        let hub = PluginSidechainHub(), buffer = hub.subscribe(source, sampleRate: 48000)
        let now: UInt64 = 1_000_000_000
        let samples = (0..<512).flatMap { [Float($0) / 1024, -Float($0) / 1024] }
        func append(_ samples: [Float], time: Double, stream: UInt64 = 0) {
            samples.withUnsafeBufferPointer { buffer.append($0, channels: 2, rate: 48000, sampleTime: time, stream: stream, now: now) }
        }
        func read(_ frames: Int, at time: UInt64 = 1_000_000_000) -> [Float] {
            var result = [Float](repeating: .nan, count: frames * 2)
            result.withUnsafeMutableBufferPointer { buffer.read(into: $0, frames: frames, now: time) }
            return result
        }
        append(samples, time: 0); append(samples, time: 0) // duplicate cannot double the detector
        for block in 0..<4 {
            try diagnosticRequire(read(128) == Array(samples[(block * 256)..<((block + 1) * 256)]), "A capture packet was skipped or replayed across render blocks")
        }
        try diagnosticRequire(read(128).allSatisfy { $0 == 0 }, "An empty detector replayed its last block")
        append(samples, time: 512)
        try diagnosticRequire(read(128) == Array(samples.prefix(256)), "The reader ran ahead of a late capture packet")
        buffer.reset()
        append(samples, time: 0); append(samples, time: 0, stream: 1)
        try diagnosticRequire(read(128) == samples.prefix(256).map { $0 * 2 }, "Concurrent app clients did not sum")
        try diagnosticRequire(read(128, at: now + 250_000_000).allSatisfy { $0 == 0 }, "A stale detector replayed audio")
        append(samples, time: 512)
        hub.invalidate(kind: .application, id: "fixture")
        try diagnosticRequire(read(128).allSatisfy { $0 == 0 }, "Disconnected source retained detector audio")
        let input = PluginSidechainBuffer(source: .init(kind: .audioInput, id: "input", name: "Input", channelOffset: 2), sampleRate: 48000)
        let multichannel = Array(repeating: [Float](arrayLiteral: 0.1, 0.2, 0.3, 0.4), count: 256).flatMap { $0 }
        multichannel.withUnsafeBufferPointer { input.append($0, channels: 4, rate: 96000, sampleTime: 0, stream: 0, now: now) }
        var converted = [Float](repeating: 0, count: 256)
        converted.withUnsafeMutableBufferPointer { input.read(into: $0, frames: 128, now: now) }
        try diagnosticRequire(converted.enumerated().allSatisfy { abs($0.element - ($0.offset % 2 == 0 ? 0.3 : 0.4)) < 0.000001 }, "Audio-input channel selection or sample-rate conversion failed")
        buffer.setEnabled(false); append(samples, time: 1024)
        try diagnosticRequire(read(128).allSatisfy { $0 == 0 }, "An inactive prepared rack retained a live send")
        buffer.setEnabled(true); append(samples, time: 1536)
        try diagnosticRequire(read(128) == Array(samples.prefix(256)), "Reactivating a prepared rack did not resume its send")
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        let appID = "fixture.sidechain.drums"
        box.perApp.updateClients([.init(deviceObjectID: 100, clientID: 91, processID: 0, bundleID: appID, isActive: true, generation: 1)])
        box.perApp.setMuted(true, for: appID)
        let appSend = box.perApp.pluginSidechains.subscribe(.init(kind: .application, id: appID, name: "Drums"), sampleRate: 48000)
        _ = box.perApp.ingest(.init(deviceObjectID: 100, clientID: 91, cycleCounter: 1, sampleTime: 0,
            interleaved: Array(repeating: [Float](arrayLiteral: 0.3, 0.7), count: 128).flatMap { $0 }, channelCount: 2, sampleRate: 48000))
        var preFader = [Float](repeating: 0, count: 256)
        preFader.withUnsafeMutableBufferPointer { appSend.read(into: $0, frames: 128) }
        try diagnosticRequire(preFader.enumerated().allSatisfy { abs($0.element - ($0.offset % 2 == 0 ? 0.3 : 0.7)) < 0.000001 }, "Muting an app also muted its pre-fader sidechain")
        var rack = PluginRack(slots: [.init(plugin: pluginTestDescriptor(), sidechain: source, sidechainBus: 1)])
        let decoded = try JSONDecoder().decode(PluginRack.self, from: JSONEncoder().encode(rack))
        try diagnosticRequire(decoded == rack, "External routing did not persist")
        rack.slots[0].sidechain?.channelOffset = -1
        do { try rack.validate(); throw DiagnosticFailure(message: "Negative input channel accepted") } catch is PluginRackError {}
    }

    private static func pluginArchitectureHeaders() throws {
        func word(_ n: UInt32, little: Bool = false) -> [UInt8] {
            let bytes = [UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]
            return little ? bytes.reversed() : bytes
        }
        for architecture in [PluginArchitecture.arm64, .x86_64] {
            let thin = Data(word(0xfeedfacf, little: true) + word(architecture.cpuType, little: true) + Array(repeating: 0, count: 24))
            try diagnosticRequire(PluginArchitecture.architectures(in: thin) == [architecture], "Thin Mach-O header was misread")
        }
        for wide in [false, true] {
            for little in [false, true] {
                let header = word(wide ? 0xcafebabf : 0xcafebabe, little: little) + word(2, little: little)
                let arms = word(PluginArchitecture.arm64.cpuType, little: little) + Array(repeating: UInt8(0), count: wide ? 28 : 16)
                let intel = word(PluginArchitecture.x86_64.cpuType, little: little) + Array(repeating: UInt8(0), count: wide ? 28 : 16)
                try diagnosticRequire(PluginArchitecture.architectures(in: Data(header + arms + intel)) == [.arm64, .x86_64], "Universal Mach-O header was misread")
            }
        }
        for bad in [Data(), Data([0, 1, 2]), Data(word(0xcafebabe) + word(UInt32.max)), Data(word(0xcafebabe) + word(1))] {
            try diagnosticRequire(PluginArchitecture.architectures(in: bad).isEmpty, "Malformed Mach-O selected an architecture")
        }
    }

    private static func pluginInstrumentDelivery() async throws {
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        let path = box.directory.appendingPathComponent("instrument.pcm")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let file = try FileHandle(forWritingTo: path), router = PCMRouter()
        defer { router.stop(); try? file.close() }
        await router.start(camillaSink: file, activeRoute: nil, renderConfiguration: .init(),
            deliveryConfiguration: .legacy(sampleRate: 48000, chunkSize: 1024), backendChunkFrames: 1024,
            pluginProcessor: PluginInstrumentDeliveryFixture())
        try await Task.sleep(for: .milliseconds(100))
        let initial = try Data(contentsOf: path)
        try diagnosticRequire(initial.count >= 128 * 8 && initial.count < 16000 * 8, "Idle instrument clock stopped or ran without pacing")
        try diagnosticRequire(initial.withUnsafeBytes { $0.bindMemory(to: Float.self).suffix(256).contains { $0 > 0.05 } }, "Instrument output did not reach the sink")
        router.route(.init(interleaved: [Float](repeating: 0.2, count: 1024), channelCount: 2, sampleRate: 48000))
        try await Task.sleep(for: .milliseconds(80))
        let waiting = try Data(contentsOf: path).count
        try await Task.sleep(for: .milliseconds(40))
        let waitingAgain = try Data(contentsOf: path).count
        try diagnosticRequire(waitingAgain == waiting, "Temporary source starvation invented frames before producer END")
        router.finishProducerEpoch()
        try await Task.sleep(for: .milliseconds(60))
        let resumed = try Data(contentsOf: path).count
        try diagnosticRequire(resumed > waiting, "Producer END did not resume the instrument clock")
        let work = router.takeAudioBufferWork()
        try diagnosticRequire(work.audioSeconds > 0 && work.pluginLoad > 0 && !work.pluginFailed, "Instrument processing did not participate in buffer load observations")
        router.setPluginProcessor(nil)
        try await Task.sleep(for: .milliseconds(30))
        let stopped = try Data(contentsOf: path).count
        try await Task.sleep(for: .milliseconds(30))
        let stoppedAgain = try Data(contentsOf: path).count
        try diagnosticRequire(stoppedAgain == stopped && stopped % (1024 * 8) == 0, "Bypassed instrument kept its clock running or left a partial backend block")
    }

    private static func pluginReorderBatching() async throws {
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        var profile = DiagnosticSandbox.profile()
        profile.pluginRack.slots = (0..<3).map { _ in .init(plugin: pluginTestDescriptor()) }
        let ids = profile.pluginRack.slots.map(\.id)
        box.profiles.profiles = [profile]
        let fake = DiagnosticRuntimeFakes()
        var services = fake.services(), orders: [[UUID]] = []
        let startPCM = services.startPCM
        services.startPCM = { plan, session in
            orders.append(plan.intent.pluginRack.slots.map(\.id))
            try await startPCM(plan, session)
        }
        services.preparePluginRack = { orders.append($0.intent.pluginRack.slots.map(\.id)) }
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: services)
        defer { state.pluginReorderApplies.cancelPending(); state.runtimeCoordinator.shutdownSynchronously() }
        await state.activate(profile: profile)
        try diagnosticRequire(state.isActive && orders == [ids], "Reorder fixture did not activate: \(state.errorMessage ?? "no runtime error"), \(orders.count) prepared orders")
        try state.movePlugin(ids[0], relativeTo: ids[1], after: true, profileID: profile.id)
        try state.movePlugin(ids[1], relativeTo: ids[2], after: true, profileID: profile.id)
        let final = [ids[0], ids[2], ids[1]]
        try diagnosticRequire(box.profiles.profiles[0].pluginRack.slots.map(\.id) == final
            && orders == [ids] && state.pluginReorderApplies.applying.isEmpty,
            "Reordering waited for loading or applied before the idle interval")
        state.pluginReorderApplies.setDragging(true, profileID: profile.id)
        try await Task.sleep(for: .milliseconds(1150))
        try diagnosticRequire(orders == [ids], "An audio reload started during the next drag")
        state.pluginReorderApplies.setDragging(false, profileID: profile.id)
        try await Task.sleep(for: .milliseconds(150))
        try diagnosticRequire(orders == [ids], "Ending a drag did not restart the idle interval")
        let deadline = Date().addingTimeInterval(4)
        while (orders.count < 2 || state.pluginReorderApplies.applying.contains(profile.id)), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try diagnosticRequire(orders == [ids, final], "Intermediate orders were loaded or final order was lost: \(orders)")
        let updatedState = Data([4, 5, 6])
        state.capturePluginState(profileID: profile.id, slotID: ids[0], data: updatedState)
        await state.history.undo()
        await state.history.undo()
        try diagnosticRequire(box.profiles.profiles[0].pluginRack.slots.map(\.id) == ids
            && box.profiles.profiles[0].pluginRack.slots[0].state == updatedState,
            "Reorder undo rolled back the live parameter snapshot")
        try diagnosticRequire(orders.count == 2, "Undo started loading between consecutive moves")
        let undoDeadline = Date().addingTimeInterval(4)
        while (orders.count < 3 || state.pluginReorderApplies.applying.contains(profile.id)), Date() < undoDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try diagnosticRequire(orders == [ids, final, ids], "Consecutive undos did not apply only the final order")
        try await box.profiles.flushPendingSave()
        let persisted = try JSONDecoder().decode(ProfileDocument.self, from: Data(contentsOf: box.directory.appendingPathComponent("profiles.json")))
        try diagnosticRequire(persisted.profiles[0].pluginRack == box.profiles.profiles[0].pluginRack,
            "Deferred apply lost persisted order or plug-in settings")
        await state.deactivate()
    }

    private static func pluginReorderScheduling() async throws {
        let id = UUID(), gate = DiagnosticManualGate()
        var starts = 0, running = 0, maximumRunning = 0
        let scheduler = PluginRackReorderApply(delay: .milliseconds(40)) { _, _ in
            starts += 1; running += 1; maximumRunning = max(maximumRunning, running)
            if starts == 1 { try? await gate.enter() }
            running -= 1
            return true
        }
        defer { gate.release(); scheduler.cancelPending() }
        scheduler.schedule(id)
        try await gate.waitUntilEntered()
        scheduler.schedule(id); scheduler.schedule(id)
        try await Task.sleep(for: .milliseconds(100))
        try diagnosticRequire(starts == 1 && running == 1, "A later reorder cancelled or overlapped the current load")
        gate.release()
        let deadline = Date().addingTimeInterval(2)
        while starts < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try diagnosticRequire(starts == 2 && maximumRunning == 1, "Moves during loading did not coalesce into one subsequent load")
        scheduler.schedule(id); scheduler.cancelPending()
        try await Task.sleep(for: .milliseconds(100))
        try diagnosticRequire(starts == 2, "A cancelled timer applied stale order")

        let snapshot = DiagnosticManualGate()
        var snapshots = 0, applies = 0
        let held = PluginRackReorderApply(delay: .milliseconds(40)) { _, isCurrent in
            snapshots += 1
            if snapshots == 1 { try? await snapshot.enter() }
            guard isCurrent() else { return false }
            applies += 1
            return true
        }
        defer { snapshot.release(); held.cancelPending() }
        held.schedule(id)
        try await snapshot.waitUntilEntered()
        held.setDragging(true, profileID: id)
        snapshot.release()
        try await Task.sleep(for: .milliseconds(100))
        try diagnosticRequire(applies == 0 && held.applying.isEmpty, "A new drag allowed a stale snapshot to start loading")
        held.setDragging(false, profileID: id)
        let heldDeadline = Date().addingTimeInterval(2)
        while applies < 1 && Date() < heldDeadline { try await Task.sleep(for: .milliseconds(10)) }
        try diagnosticRequire(applies == 1, "Pending order was lost when snapshot preparation was interrupted by dragging")
    }

    static func pluginChannelProfile(roles: [ChannelRole]) -> DeviceProfile {
        var profile = DiagnosticSandbox.profile(); profile.endpointKind = .speakers
        profile.setPlaybackMode(.direct)
        profile.speakerTopology = .init(deviceUID: profile.outputDeviceUID, sampleRate: Double(profile.sampleRate), declaredChannelCount: roles.count,
            endpoints: roles.enumerated().map { index, role in
                .init(id: .init(deviceUID: profile.outputDeviceUID, channelIndex: index), role: role,
                    displayName: "Output \(index + 1)", connectionState: .confirmedByUser,
                    function: role == .lowFrequencyEffects ? .subwoofer : .fullRange)
            })
        return profile
    }

    private static func pluginChannelDelivery() async throws {
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        for channels in [1, 6, 16, 32] {
            var profile = pluginChannelProfile(roles: Array(repeating: .unknown, count: channels))
            profile.multichannel.routing.enabled = true
            profile.multichannel.routing.sourceLayout = .discrete
            profile.multichannel.routing.discreteChannelCount = channels
            profile.multichannel.routing.routes = profile.configuredSpeakerEndpoints.enumerated().map { .init(sourceChannel: $0.offset, destination: $0.element.id) }
            let plan = try diffPlan(profile), path = box.directory.appendingPathComponent("plugins-\(channels).pcm")
            FileManager.default.createFile(atPath: path.path, contents: nil)
            let file = try FileHandle(forWritingTo: path), router = PCMRouter()
            defer { router.stop(); try? file.close() }
            await router.start(camillaSink: file, activeRoute: plan.route, renderConfiguration: plan.renderConfiguration,
                deliveryConfiguration: .legacy(sampleRate: 48000, chunkSize: 128), backendChunkFrames: 128,
                pluginProcessor: PluginDeliveryFixture(channelCount: channels))
            let layout = plan.route.dspLayout
            func deliver(expectedFrames: Int) async throws -> [Float] {
                let samples = (0..<(256 * channels)).map { Float($0 % channels + 1) * 0.01 }
                router.route(.init(interleaved: samples, channelCount: channels, sampleRate: 48000, channelLayout: layout))
                router.finishProducerEpoch()
                let deadline = Date().addingTimeInterval(2)
                var bytes = Data()
                while Date() < deadline {
                    bytes = try Data(contentsOf: path)
                    if bytes.count >= expectedFrames * channels * 4 { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                try diagnosticRequire(bytes.count == expectedFrames * channels * 4, "Multichannel delivery lost frames: \(channels) channels, \(bytes.count) bytes")
                return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
            let output = try await deliver(expectedFrames: 512)
            for c in 0..<channels {
                try diagnosticRequire(abs(output[200 * channels + c] - Float(c + 1) * 0.005) < 0.00001, "Delivery changed channel \(c)")
            }
            try diagnosticRequire(output.suffix(256 * channels).allSatisfy { $0 == 0.04 }, "A channel lost the plug-in tail")
            // Simulate a stale prepared processor with the wrong format.
            router.setPluginProcessor(PluginDeliveryFixture(channelCount: channels == 2 ? 1 : 2, tailFrames: 0))
            let failed = try await deliver(expectedFrames: 768)
            try diagnosticRequire(failed.suffix(128 * channels).allSatisfy { $0 == 0 }, "A mismatched rack leaked audio")
        }
    }

    private static func pluginCatalogDiscovery() async throws {
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        let manager = FileManager.default
        let standard = box.directory.appendingPathComponent("Standard")
        let first = box.directory.appendingPathComponent("Custom One")
        let second = box.directory.appendingPathComponent("Custom Two")
        func bundle(_ root: URL, _ name: String, id: String? = nil, instrument: Bool = false, oldMetadata: Bool = false) throws -> URL {
            let url = root.appendingPathComponent(name + ".vst3")
            try manager.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            try manager.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            // These deliberately invalid executables must never be opened while scanning.
            try Data("not an executable".utf8).write(to: url.appendingPathComponent("Contents/MacOS/Effect"))
            if let id {
                let json = """
                { // VST3 metadata permits comments and trailing commas.
                  "Factory Info": {"Vendor": "Catalog Test",},
                  "Classes": [{"CID": "\(id)", "Category": "Audio Module Class", "Name": "\(name)",
                    "Sub Categories": ["\(instrument ? "Instrument" : "Fx")"],},],
                }
                """
                try Data(json.utf8).write(to: url.appendingPathComponent(oldMetadata ? "Contents/moduleinfo.json" : "Contents/Resources/moduleinfo.json"))
            }
            return url.standardizedFileURL.resolvingSymlinksInPath()
        }
        _ = try bundle(standard, "Metadata", id: String(repeating: "1", count: 32))
        let legacy = try bundle(first.appendingPathComponent("Nested"), "Older Bundle")
        _ = try bundle(second, "Instrument", id: String(repeating: "2", count: 32), instrument: true)
        _ = try bundle(second, "Old Metadata", id: String(repeating: "3", count: 32), oldMetadata: true)
        let alias = box.directory.appendingPathComponent("Folder Alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: first)
        let probe = PluginCatalogProbe(audioUnit: pluginTestDescriptor())
        let catalog = PluginCatalog(directory: box.directory, standardDirectories: [standard, first.appendingPathComponent("Nested")], scanner: { try await probe.scan($0) })
        await catalog.addDirectories([first, second, alias, first])
        try diagnosticRequire(catalog.customDirectories.count == 2, "Duplicate custom folder or symlink was saved")
        catalog.scan(); try await waitForPluginScan(catalog)
        let initialCalls = await probe.calls
        try diagnosticRequire(initialCalls == [["--scan-au"]], "Browsing executed a VST3 factory")
        try diagnosticRequire(catalog.plugins.count == 5 && catalog.plugins.filter { $0.location == legacy.path }.count == 1,
            "Nested folders, JSON5, instrument discovery or bundle deduplication failed")
        guard let unresolved = catalog.plugins.first(where: { $0.location == legacy.path }) else { throw DiagnosticFailure(message: "Missing legacy bundle") }
        try diagnosticRequire(unresolved.id.hasPrefix("vst3-bundle:"), "Legacy bundle was loaded during discovery")
        await probe.setHolding(true)
        let addition = Task { try await catalog.resolveForAddition(unresolved) }
        defer { addition.cancel() }
        let addDeadline = Date().addingTimeInterval(3)
        while await probe.calls.count < 2 && Date() < addDeadline { try await Task.sleep(for: .milliseconds(10)) }
        let pendingCalls = await probe.calls
        try diagnosticRequire(pendingCalls.count == 2 && catalog.failures.isEmpty, "An in-progress Add was presented as a failure")
        let pendingData = try Data(contentsOf: box.directory.appendingPathComponent("PluginCatalog.json"))
        let pendingCache = try JSONSerialization.jsonObject(with: pendingData) as? [String: Any]
        try diagnosticRequire((pendingCache?["failures"] as? [String: String])?[legacy.path] != nil, "Pending Add lost its persisted crash marker")
        await probe.setHolding(false)
        let choices = try await addition.value
        try diagnosticRequire(choices.count == 2 && choices.allSatisfy { $0.id.count == 32 }, "Explicit Add did not resolve a multi-effect bundle")
        let selected = try await catalog.resolveForAddition(choices[1])
        let cachedCalls = await probe.calls
        try diagnosticRequire(selected == [choices[1]] && cachedCalls.count == 2, "Choosing a resolved class loaded its factory again")
        // Changing the binary's size invalidates its verification without reading its contents.
        try Data("changed executable with a different size".utf8).write(to: legacy.appendingPathComponent("Contents/MacOS/Effect"))
        catalog.scan(); try await waitForPluginScan(catalog)
        let refreshedCalls = await probe.calls
        try diagnosticRequire(refreshedCalls.count == 3 && refreshedCalls.last == ["--scan-au"], "Rescan eagerly loaded a changed VST3")
        await probe.setFailing(true)
        do {
            _ = try await catalog.resolveForAddition(unresolved)
            throw DiagnosticFailure(message: "Rejected factory was accepted")
        } catch is PluginHostError {}
        try diagnosticRequire(catalog.failures[legacy.path] != nil, "Failed Add was not recorded")
        catalog.scan(); try await waitForPluginScan(catalog)
        let failureCalls = await probe.calls
        try diagnosticRequire(failureCalls.count == 5 && failureCalls.last == ["--scan-au"], "Rescan retried a failed factory")
        await probe.setFailing(false)
        _ = try await catalog.resolveForAddition(unresolved)
        try diagnosticRequire(catalog.failures.isEmpty, "Successful explicit retry retained its failure")
        let restored = PluginCatalog(directory: box.directory, standardDirectories: [], scanner: { try await probe.scan($0) })
        await restored.load()
        try diagnosticRequire(restored.customDirectories == catalog.customDirectories && restored.plugins == catalog.plugins, "Catalog or custom folders did not survive reopening")
        let beforeCancel = restored.plugins
        await probe.setHolding(true)
        restored.scan()
        try await Task.sleep(for: .milliseconds(30))
        restored.cancelScan(); try await waitForPluginScan(restored)
        try diagnosticRequire(restored.plugins == beforeCancel, "Cancelled scan discarded the visible catalog")
        await probe.setHolding(false)
        await restored.removeDirectory(first.standardizedFileURL.resolvingSymlinksInPath())
        restored.scan(); try await waitForPluginScan(restored)
        try diagnosticRequire(!restored.plugins.contains { $0.location == legacy.path }, "Removed scan folder remained in discovery")
        // Catalogs from the previous scanner have neither folders nor fingerprints.
        let oldDirectory = box.directory.appendingPathComponent("Old Cache")
        try manager.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let oldPlugins = try JSONSerialization.jsonObject(with: JSONEncoder().encode([pluginTestDescriptor()]))
        let oldData = try JSONSerialization.data(withJSONObject: ["plugins": oldPlugins, "failures": [String: String]()])
        try oldData.write(to: oldDirectory.appendingPathComponent("PluginCatalog.json"))
        let migrated = PluginCatalog(directory: oldDirectory, standardDirectories: [], scanner: { try await probe.scan($0) })
        await migrated.load()
        try diagnosticRequire(migrated.plugins == [pluginTestDescriptor()] && migrated.customDirectories.isEmpty, "Legacy catalog failed to migrate")
    }

    private static func pluginMetadataCompatibility() throws {
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        let manager = FileManager.default
        func bundle(_ name: String, info: [String: Any] = [:], metadata: String? = nil) throws -> URL {
            let url = box.directory.appendingPathComponent(name + ".vst3")
            try manager.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            try manager.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try Data("must never execute".utf8).write(to: url.appendingPathComponent("Contents/MacOS/Plugin"))
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
            if let metadata { try Data(metadata.utf8).write(to: url.appendingPathComponent("Contents/Resources/moduleinfo.json")) }
            return url.standardizedFileURL.resolvingSymlinksInPath()
        }
        let copyright = try bundle("Copyright", info: ["NSHumanReadableCopyright": "Copyright (C) 2018–2026 Créateur Audio. All rights reserved."])
        let explicit = try bundle("Explicit", info: ["VST3Vendor": " Explicit Maker ", "NSHumanReadableCopyright": "Different Owner"])
        let component = try bundle("Shared Component", info: ["AudioComponents": [["name": "Shared Maker: Effect"]]])
        let missing = try bundle("Unidentified", info: ["CFBundleIdentifier": "com.dont.guess", "NSHumanReadableCopyright": "Copyright © 2026. All rights reserved."])
        let partial = try bundle("Partial", metadata: """
        {"Factory Info":{"Vendor":"Factory Maker"},"Classes":[
          {"CID":99,"Category":"Audio Module Class"},
          {"CID":"11111111111111111111111111111111","Category":"Audio Module Class","Name":"Écho 音","Vendor":"  ","Sub Categories":"Fx|Delay"},
          {"CID":"22222222222222222222222222222222","Category":"Audio Module Class","Name":"Synth","Sub Categories":"Instrument|Synth"}
        ]}
        """)
        let malformed = try bundle("Malformed", info: ["Vendor": "Fallback Maker"], metadata: "{invalid json")
        let incomplete = try bundle("Incomplete", metadata: "{\"Classes\":[{\"Name\":\"Broken\"}]}")
        let entries = try PluginDiscovery.discover(in: [box.directory], cached: [:])
        func maker(_ url: URL) -> String? { entries[url.path]?.plugins.first?.manufacturer }
        try diagnosticRequire(maker(copyright) == "Créateur Audio" && maker(explicit) == "Explicit Maker"
            && maker(component) == "Shared Maker" && maker(missing) == "Maker not identified", "Static maker fallbacks guessed or lost a name")
        try diagnosticRequire(entries[partial.path]?.plugins.count == 2 && entries[partial.path]?.plugins.first?.name == "Écho 音"
            && maker(partial) == "Factory Maker" && entries[partial.path]?.plugins.last?.isInstrument == true, "One malformed entry hid a valid effect, blank vendor hid its factory, or an instrument lost its kind")
        try diagnosticRequire(maker(malformed) == "Fallback Maker"
            && entries[incomplete.path]?.plugins.first?.id.hasPrefix("vst3-bundle:") == true, "Incomplete metadata removed the bundle's deferred Add entry")
        var old = entries
        var oldDescriptor = entries[copyright.path]!.plugins[0]; oldDescriptor.manufacturer = "Unknown"
        old[copyright.path] = .init(fingerprint: PluginDiscovery.fingerprint(copyright), plugins: [oldDescriptor], verified: false, metadataRevision: nil)
        var verifiedDescriptor = entries[explicit.path]!.plugins[0]; verifiedDescriptor.manufacturer = "Verified factory"
        old[explicit.path] = .init(fingerprint: PluginDiscovery.fingerprint(explicit), plugins: [verifiedDescriptor], verified: true, metadataRevision: nil)
        let upgraded = try PluginDiscovery.discover(in: [box.directory], cached: old)
        try diagnosticRequire(upgraded[copyright.path]?.plugins.first?.manufacturer == "Créateur Audio"
            && upgraded[explicit.path]?.plugins.first?.manufacturer == "Verified factory"
            && upgraded[explicit.path]?.verified == false, "Metadata upgrade retained Unknown or discarded verified factory information")
    }

    static func waitForPluginScan(_ catalog: PluginCatalog) async throws {
        let deadline = Date().addingTimeInterval(3)
        while catalog.isScanning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try diagnosticRequire(!catalog.isScanning, "Catalog scan did not finish")
    }

    static func pluginTestDescriptor() -> AudioPluginDescriptor {
        .init(id: "au:61756678:62706173:6170706c", name: "AUBandpass", manufacturer: "Apple", format: .audioUnit,
            componentType: 0x61756678, componentSubtype: 0x62706173, componentManufacturer: 0x6170706c)
    }

#if DEBUG
    /// Exercise the app-side deadline and memory-ownership code against a real
    /// VST3 module. The fixture is built by Scripts/test-plugin-host.py.
    private static func pluginExpandedHostIntegration(root: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let directory = root.appendingPathComponent("build/plugin-host")
            let effect = AudioPluginDescriptor(id: "43616D6954756E655465737445666678", name: "Fixture", manufacturer: "Tests", format: .vst3,
                location: directory.appendingPathComponent("CamiTuneTest.vst3").path)
            var instrument = effect
            instrument.location = directory.appendingPathComponent("CamiTuneInstrumentTestx86_64.vst3").path
            instrument.kind = .instrument
            func state(_ mode: UInt32) throws -> Data {
                var gain: Float = 0.5, mode = mode
                var bytes = withUnsafeBytes(of: &gain) { Data($0) }; bytes.append(withUnsafeBytes(of: &mode) { Data($0) })
                return try PropertyListSerialization.data(fromPropertyList: ["component": bytes], format: .binary, options: 0)
            }
            try diagnosticRequire(PluginArchitecture.preferred(forVST3: URL(fileURLWithPath: instrument.location)) == .x86_64, "Intel-only bundle was not detected")
            let rack = PluginRack(slots: [.init(plugin: effect), .init(plugin: instrument, state: try state(21)), .init(plugin: effect)])
            let groups = PluginArchitecture.groups(for: rack.slots)
            try diagnosticRequire(groups.count == (PluginArchitecture.native == .arm64 ? 3 : 1), "Architecture grouping changed rack order")
            let session = try PluginHostSession(rack: rack, sampleRate: 48000, channelRoles: [.left, .right, .center, .lowFrequencyEffects, .leftSurround, .rightSurround]) { _ in }
            try diagnosticRequire(session.requiresContinuousRendering, "The app did not recognize the Intel instrument")
            var midi = PluginMIDIConfiguration(); midi.isEnabled = true; midi.sourceID = 123456789
            session.configureMIDI(midi, enabled: true)
            try await Task.sleep(for: .milliseconds(40))
            var samples = [Float](repeating: 0.2, count: 128 * 6)
            try diagnosticRequire(session.process(&samples, sampleRate: 48000, reset: false), "Mixed rack preparation failed")
            session.control(["command": "testMIDI", "messages": [["source": 123456789, "status": 0x90, "data1": 60, "data2": 100]]])
            try await Task.sleep(for: .milliseconds(30))
            var worst = 0.0
            for _ in 0..<100 {
                samples = [Float](repeating: 0.2, count: 128 * 6)
                let start = DispatchTime.now().uptimeNanoseconds
                try diagnosticRequire(session.process(&samples, sampleRate: 48000, reset: false), "Mixed native/Intel rack missed its single deadline: \(session.errorMessage ?? "unknown")")
                worst = max(worst, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                try diagnosticRequire(samples.enumerated().allSatisfy {
                    abs($0.element - ($0.offset % 6 == 0 ? 0.075 : $0.offset % 6 == 1 ? 0.1 : 0.05)) < 0.000001
                }, "Native/Intel stages ran out of order or duplicated the instrument")
            }
            let snapshots = await session.snapshot(close: false)
            try diagnosticRequire(snapshots.count == 3, "Mixed helper snapshots lost a slot")
            session.control(["command": "midiPanic"])
            try await Task.sleep(for: .milliseconds(30))
            samples = [Float](repeating: 0.2, count: 128 * 6)
            try diagnosticRequire(session.process(&samples, sampleRate: 48000, reset: false) && samples.allSatisfy { abs($0 - 0.05) < 0.000001 }, "Panic did not silence the bridged instrument")
            let hub = PluginSidechainHub(), source = PluginSidechainSource(kind: .application, id: "fixture", name: "Fixture")
            let detector = try PluginHostSession(rack: .init(slots: [.init(plugin: effect, state: try state(22), sidechain: source)]),
                sampleRate: 48000, sidechainHub: hub) { _ in }
            let external = [Float](repeating: 0.4, count: 1024)
            external.withUnsafeBufferPointer { hub.offer(kind: .application, id: "fixture", samples: $0, channels: 2, rate: 48000, sampleTime: 0, stream: 0) }
            for _ in 0..<4 {
                var signal = [Float](repeating: 0.2, count: 256)
                try diagnosticRequire(detector.process(&signal, sampleRate: 48000, reset: false) && signal.allSatisfy { abs($0 - 0.04) < 0.000001 }, "App-side sidechain split a packet incorrectly")
            }
            hub.invalidate(kind: .application, id: "fixture")
            var signal = [Float](repeating: 0.2, count: 256)
            try diagnosticRequire(detector.process(&signal, sampleRate: 48000, reset: false) && signal.allSatisfy { $0 == 0 }, "Disconnected app kept driving the sidechain")
            print("Mixed native/Intel/native rack: ordered instrument mix, snapshots, panic, single deadline and sidechain IPC passed; 128-frame maximum \(String(format: "%.3f", worst)) ms")
        }.value
    }

    fileprivate static func pluginMIDIProfileSwitching() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plugin = AudioPluginDescriptor(id: "43616D6954756E655465737445666678", name: "MIDI profile fixture", manufacturer: "Tests",
            format: .vst3, location: root.appendingPathComponent("build/plugin-host/CamiTuneTest.vst3").path)
        var gain: Float = 0.5, mode: UInt32 = 24
        var bytes = withUnsafeBytes(of: &gain) { Data($0) }
        bytes.append(withUnsafeBytes(of: &mode) { Data($0) })
        let preset = try PropertyListSerialization.data(fromPropertyList: ["component": bytes], format: .binary, options: 0)
        func profile(destination: Int) -> DeviceProfile {
            var value = diffProfile()
            value.pluginRack.slots = (0..<2).map { _ in AudioPluginSlot(plugin: plugin, state: preset) }
            value.pluginRack.midi.isEnabled = true
            value.pluginRack.midi.sourceID = 123456789
            value.pluginRack.midi.programChangeSlotID = value.pluginRack.slots[destination].id
            value.pluginRack.midi.mappings = value.pluginRack.slots.map {
                PluginMIDIMapping(slotID: $0.id, parameterID: 0, parameterName: "Gain", sourceID: 123456789,
                    sourceName: "Test", channel: 1, controller: 7, pickup: false)
            }
            return value
        }
        let manager = PluginRackManager(); defer { manager.stop() }
        func activate(_ profile: DeviceProfile) async throws -> PluginHostSession {
            let plan = try diffPlan(profile)
            try await manager.prepare(plan)
            guard let session = manager.commit(plan) as? PluginHostSession else { throw DiagnosticFailure(message: "MIDI profile did not activate") }
            _ = await session.snapshot(close: false)
            var block = [Float](repeating: 0.2, count: 256)
            try diagnosticRequire(session.process(&block, sampleRate: session.sampleRate, reset: false), "MIDI activation failed to render")
            return session
        }
        func send(_ session: PluginHostSession, status: Int, data1: Int, data2: Int = 0, expected: Float) async throws {
            session.control(["command": "testMIDI", "messages": [["source": 123456789, "status": status, "data1": data1, "data2": data2]]])
            _ = await session.snapshot(close: false)
            var block = [Float](repeating: 0.2, count: 256)
            try diagnosticRequire(session.process(&block, sampleRate: session.sampleRate, reset: false)
                && block.allSatisfy { abs($0 - expected) < 0.000001 }, "Profile MIDI routing produced unexpected audio: \(block.prefix(2)) expected \(expected)")
        }
        var firstProfile = profile(destination: 0)
        let secondProfile = profile(destination: 1)
        let first = try await activate(firstProfile)
        try await send(first, status: 0xc0, data1: 3, expected: 0.1)
        let second = try await activate(secondProfile)
        try await send(second, status: 0xc0, data1: 0, expected: 0)
        try await send(first, status: 0xc0, data1: 0, expected: 0.1) // inactive rack ignores input
        let returned = try await activate(firstProfile)
        try diagnosticRequire(returned === first, "Returning profile lost its prepared rack")
        try await send(returned, status: 0xc0, data1: 0, expected: 0)
        try await send(returned, status: 0xb0, data1: 7, data2: 127, expected: 0.2) // both mappings
        firstProfile.pluginRack.midi.programChangeSlotID = UUID()
        manager.updateMIDI(profileID: firstProfile.id, rack: firstProfile.pluginRack)
        _ = await returned.snapshot(close: false)
        try await send(returned, status: 0xc0, data1: 0, expected: 0.2) // no fallback
        try await send(returned, status: 0xb0, data1: 7, data2: 0, expected: 0) // mappings remain live
        firstProfile.pluginRack.midi.programChangeSlotID = firstProfile.pluginRack.slots[0].id
        firstProfile.pluginRack.slots[0].isEnabled = false
        let bypassed = try await activate(firstProfile)
        try await send(bypassed, status: 0xc0, data1: 0, expected: 0.1)
        print("MIDI profile switching restores the saved destination, silences inactive racks, ignores missing/bypassed targets and preserves all mappings")
    }

    static func pluginHostIntegration() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let location = root.appendingPathComponent("build/plugin-host/CamiTuneTest.vst3").path
        let audioUnit = pluginTestDescriptor()
        try await Task.detached(priority: .userInitiated) {
            let plugin = AudioPluginDescriptor(id: "43616D6954756E655465737445666678", name: "CamiTune Test Gain", manufacturer: "CamiTune Tests", format: .vst3, location: location)
            for mode in UInt32(0)...3 {
                var gain: Float = 0.5, value = mode
                var bytes = withUnsafeBytes(of: &gain) { Data($0) }
                bytes.append(withUnsafeBytes(of: &value) { Data($0) })
                let state = try PropertyListSerialization.data(fromPropertyList: ["component": bytes], format: .binary, options: 0)
                let rack = PluginRack(slots: [.init(plugin: plugin, state: state)])
                let session = try PluginHostSession(rack: rack, sampleRate: 48000) { event in
                    if event["event"] as? String == "snapshotError" { print("Snapshot failed: \(event["message"] ?? "")") }
                }
                var samples = [Float](repeating: 0.25, count: 256)
                try diagnosticRequire(session.process(&samples, sampleRate: 48000, reset: false), "Initial processing failed")
                try diagnosticRequire(samples.allSatisfy { abs($0 - 0.125) < 0.00001 }, "VST3 processing did not reach app-side PCM")
                samples = [Float](repeating: 0.25, count: 256)
                _ = session.process(&samples, sampleRate: 48000, reset: false)
                let start = DispatchTime.now().uptimeNanoseconds
                let accepted = session.process(&samples, sampleRate: 48000, reset: false)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                if mode != 0 {
                    try diagnosticRequire(!accepted && session.errorMessage != nil, "Faulted helper remained active")
                    try diagnosticRequire(elapsed < 200, "Stalled helper blocked app-side audio for \(elapsed) ms")
                    try diagnosticRequire(!session.process(&samples, sampleRate: 48000, reset: false), "Timed-out shared memory was reused")
                } else {
                    try diagnosticRequire(accepted, "Healthy helper failed")
                    let states = await session.snapshot(close: false)
                    try diagnosticRequire(states[rack.slots[0].id] != nil, "Editor snapshot did not reach saved app state (\(states.count) slots; \(session.errorMessage ?? "healthy host"))")
                }
                print("Plug-in host mode \(mode) passed (\(String(format: "%.3f", elapsed)) ms)")
            }
            // Use the actual app-side IPC deadline, including the editor's
            // idle path and preset snapshots. The waveform must be identical
            // to a closed editor even when requests arrive more than 10 ms apart.
            for rate in [44100.0, 48000.0, 96000.0] {
                for frames in [128, 1024] {
                    let rack = PluginRack(slots: [.init(plugin: audioUnit)])
                    let reference = try PluginHostSession(rack: rack, sampleRate: rate) { _ in }
                    let edited = try PluginHostSession(rack: rack, sampleRate: rate, editorOnly: true) { _ in }
                    var peakError: Float = 0, maximumMilliseconds = 0.0
                    for block in 0..<48 {
                        let samples = (0..<frames).flatMap { frame -> [Float] in
                            let value = Float(0.2 * sin(2 * Double.pi * 997 * Double(block * frames + frame) / rate))
                            return [value, value]
                        }
                        var expected = samples, actual = samples
                        try diagnosticRequire(reference.process(&expected, sampleRate: rate, reset: block == 0), "Reference AU failed: \(reference.errorMessage ?? "unknown")")
                        let start = DispatchTime.now().uptimeNanoseconds
                        try diagnosticRequire(edited.process(&actual, sampleRate: rate, reset: block == 0), "Editor AU failed: \(edited.errorMessage ?? "unknown")")
                        maximumMilliseconds = max(maximumMilliseconds, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                        for index in actual.indices { peakError = max(peakError, abs(actual[index] - expected[index])) }
                        if block % 16 == 0 { _ = await edited.snapshot(close: false) }
                        try await Task.sleep(for: .milliseconds(max(12, Double(frames) * 1000 / rate)))
                    }
                    try diagnosticRequire(peakError < 0.000001, "Opening the editor changed AU waveform history by \(peakError)")
                    print("Apple AU app transport: \(Int(rate)) Hz, \(frames) frames, waveform error \(peakError), max \(String(format: "%.3f", maximumMilliseconds)) ms; deadlines and snapshots passed")
                }
            }
        }.value
        try await pluginExpandedHostIntegration(root: root)
        try await pluginMIDIProfileSwitching()
        let manager = PluginRackManager()
        defer { manager.stop() }
        var profile = diffProfile()
        let plugin = AudioPluginDescriptor(id: "43616D6954756E655465737445666678", name: "CamiTune Test Gain", manufacturer: "CamiTune Tests", format: .vst3, location: location)
        profile.pluginRack.slots = [.init(plugin: plugin)]
        let first = try diffPlan(profile)
        try await manager.prepare(first)
        guard let original = manager.commit(first) else { throw DiagnosticFailure(message: "Prepared rack was not committed") }
        profile.pluginRack.slots.append(.init(plugin: plugin))
        let second = try diffPlan(profile, generation: 2)
        try await manager.prepare(second)
        let replacement = manager.commit(second)
        try diagnosticRequire(replacement !== original, "Changed rack reused the old processor")
        try diagnosticRequire(manager.commit(first) === original, "Rollback did not restore the prepared processor")
        profile.pluginRack.slots[0].plugin.location = "/tmp/camitune-missing-plugin.vst3"
        do {
            try await manager.prepare(diffPlan(profile, generation: 3))
            throw DiagnosticFailure(message: "Missing module was accepted")
        } catch is PluginHostError {}
        try diagnosticRequire(manager.commit(first) === original, "Failed preparation replaced the live processor")
        print("Plug-in rack preparation, commit, rollback and rejected-load isolation passed")
        for channels in [1, 3, 6, 12, 16, 32] {
            let roles = Array(repeating: ChannelRole.unknown, count: channels)
            try await Task.detached(priority: .userInitiated) {
                let rack = PluginRack(slots: [.init(plugin: plugin)])
                let session = try PluginHostSession(rack: rack, sampleRate: 48000, channelRoles: roles) { _ in }
                for frames in [1, 128, 1024, 2048, 4097] {
                    var samples = (0..<(frames * channels)).map { Float($0 % channels + 1) * 0.01 }
                    let expected = samples.map { $0 * 0.5 }
                    try diagnosticRequire(session.process(&samples, sampleRate: 48000, reset: false), "Multichannel app IPC failed: \(session.errorMessage ?? "unknown")")
                    try diagnosticRequire(zip(samples, expected).allSatisfy { abs($0 - $1) < 0.000001 }, "App IPC changed channel order/count")
                }
                let apple = try PluginHostSession(rack: .init(slots: [.init(plugin: audioUnit)]), sampleRate: 48000, channelRoles: roles, editorOnly: true) { _ in }
                for block in 0..<12 {
                    var samples = (0..<(1024 * channels)).map { Float(0.1 * sin(Double($0 / channels + block * 1024) * 0.1)) }
                    try diagnosticRequire(apple.process(&samples, sampleRate: 48000, reset: false), "Multichannel AU missed the app deadline: \(apple.errorMessage ?? "unknown")")
                    try diagnosticRequire(samples.allSatisfy(\.isFinite), "AU produced invalid multichannel audio")
                    try await Task.sleep(for: .milliseconds(25))
                }
            }.value
        }
        // Reprepare even when the rack/preset is identical and only the
        // profile's speaker identities/order or width has changed.
        var multichannel = pluginChannelProfile(roles: [.left, .right, .center, .lowFrequencyEffects, .leftSurround, .rightSurround])
        multichannel.pluginRack.slots = [.init(plugin: plugin)]
        let six = try diffPlan(multichannel)
        try await manager.prepare(six)
        let firstSix = manager.commit(six)
        try diagnosticRequire(firstSix?.channelCount == 6, "Manager reused a stereo processor for a surround profile")
        multichannel.speakerTopology?.endpoints[0].role = .right
        multichannel.speakerTopology?.endpoints[1].role = .left
        let reordered = try diffPlan(multichannel, generation: 3)
        try await manager.prepare(reordered)
        let nextSix = manager.commit(reordered)
        try diagnosticRequire(nextSix !== firstSix && nextSix?.channelCount == 6, "Speaker role changes reused an incompatible processor")
        try await manager.prepare(six)
        try diagnosticRequire(manager.commit(six) === firstSix, "Multichannel format rollback lost its prepared rack")
        // Mirror AppState's capturePluginState callback: a loaded effect has
        // already saved its initial preset. Reusing the original nil preset
        // would ask the manager to reset the effect, not just change MIDI.
        var captured = six.intent
        manager.stateChanged = { profileID, slotID, data in
            if profileID == captured.id, let index = captured.pluginRack.slots.firstIndex(where: { $0.id == slotID }) {
                captured.pluginRack.slots[index].state = data
            }
        }
        await manager.flushEditors(profileID: captured.id, close: false)
        try diagnosticRequire(captured.pluginRack.slots[0].state != nil, "The MIDI fixture did not capture the loaded preset")
        let beforeMIDI = try diffPlan(captured, generation: 4)
        var withMIDI = captured
        withMIDI.pluginRack.midi.isEnabled = true
        withMIDI.pluginRack.midi.sourceID = 123456789
        let midiPlan = try diffPlan(withMIDI, generation: 5)
        try await manager.prepare(midiPlan)
        try diagnosticRequire(manager.commit(midiPlan) === firstSix, "Enabling MIDI rebuilt the audio rack")
        try await manager.prepare(beforeMIDI)
        try diagnosticRequire(manager.commit(beforeMIDI) === firstSix, "MIDI undo rebuilt the audio rack")
        print("Plug-in app transport: 1–32 channels, 1–4097-frame batches, Apple AU deadlines and layout-aware preparation/rollback passed")
    }
#endif
}

private actor PluginCatalogProbe {
    let audioUnit: AudioPluginDescriptor
    private(set) var calls: [[String]] = []
    private var holding = false
    private var failing = false
    init(audioUnit: AudioPluginDescriptor) { self.audioUnit = audioUnit }
    func setHolding(_ value: Bool) { holding = value }
    func setFailing(_ value: Bool) { failing = value }
    func scan(_ arguments: [String]) async throws -> [AudioPluginDescriptor] {
        calls.append(arguments)
        while holding { try await Task.sleep(for: .milliseconds(10)) }
        if arguments == ["--scan-au"] { return [audioUnit] }
        if failing { throw PluginHostError(message: "Fixture factory rejected") }
        return ["A", "B"].map {
            .init(id: String(repeating: $0, count: 32), name: "Resolved Effect \($0)", manufacturer: "Catalog Test", format: .vst3, location: arguments[1])
        }
    }
}

private final class PluginDeliveryFixture: PluginAudioProcessor, @unchecked Sendable {
    let failing: Bool
    let channelCount: Int
    let tailFrames: Int
    init(channelCount: Int = 2, failing: Bool = false, tailFrames: Int = 256) {
        self.channelCount = channelCount; self.failing = failing; self.tailFrames = failing ? 0 : tailFrames
    }
    func process(_ samples: inout [Float], sampleRate: Double, reset: Bool) -> Bool {
        guard !failing else { return false }
        let silence = samples.allSatisfy { $0 == 0 }
        for index in samples.indices { samples[index] = silence ? 0.04 : samples[index] * 0.5 }
        return true
    }
}

#if DEBUG
import AppKit
import SwiftUI

@MainActor
extension UIInteractionSelfTests {
    static func automaticBufferInteractions(artifacts: URL) async throws {
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        let profile = DiagnosticSandbox.profile(); box.profiles.profiles = [profile]
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: DiagnosticRuntimeFakes().services())
        defer { state.shutdownSynchronously() }
        func choose<Content: View>(_ title: String, in fixture: WindowFixture<Content>) async throws {
            // Both Automatic and Global Default include their buffer details.
            // Match each option without confusing the two.
            func matches(_ item: String, _ choice: String) -> Bool {
                item == choice || (choice == "Automatic" && item.hasPrefix("Automatic ("))
                    || (choice == "Global Default" && item.hasPrefix("Global Default ("))
            }
            guard let picker = fixture.views.compactMap({ $0 as? NSPopUpButton }).first(where: {
                $0.itemTitles.contains { matches($0, "Automatic") }
            }), let index = picker.itemTitles.firstIndex(where: { matches($0, title) }) else {
                throw DiagnosticFailure(message: "Missing audio buffer choice: \(title)")
            }
            picker.selectItem(at: index)
            picker.menu?.performActionForItem(at: index)
            await fixture.settle()
        }
        do {
            let commands = MainWindowCommandCoordinator(); commands.settingsCategory = "Audio"
            let fixture = WindowFixture(SettingsView(state: state).environmentObject(commands), size: .init(width: 900, height: 650))
            defer { fixture.close() }
            await fixture.settle()
            try await choose("Automatic", in: fixture)
            try diagnosticRequire(box.profiles.audioBufferDefault == .automatic && box.profiles.profiles[0].usesGlobalAudioBuffer,
                "Global Automatic picker did not save or broke inheritance")
            try fixture.snapshot(to: artifacts.appendingPathComponent("automatic-buffer-global.png"))
        }
        do {
            let current = box.profiles.profiles[0]
            let fixture = WindowFixture(ProfileSettingsView(state: state, profile: current), size: .init(width: 780, height: 620))
            defer { fixture.close() }
            await fixture.settle()
            try await choose("Automatic", in: fixture)
            try diagnosticRequire(box.profiles.profiles[0].audioBufferOverride == nil, "Profile picker persisted an unsaved draft")
            try fixture.snapshot(to: artifacts.appendingPathComponent("automatic-buffer-profile.png"))
        }
        do {
            let fixture = WindowFixture(PluginSectionFixture(state: state, store: box.profiles), size: .init(width: 540, height: 450))
            defer { fixture.close() }
            await fixture.settle()
            try await choose("Automatic", in: fixture)
            try diagnosticRequire(box.profiles.profiles[0].audioBufferOverride == .automatic,
                "Plug-in Automatic picker did not save the shared preference")
            await state.history.undo(); await fixture.settle()
            try diagnosticRequire(box.profiles.profiles[0].usesGlobalAudioBuffer, "Buffer undo did not restore inheritance")
            try await choose("128 samples", in: fixture)
            try diagnosticRequire(box.profiles.profiles[0].audioBufferOverride == 128, "Manual buffer choice failed")
            try await choose("Global Default", in: fixture)
            try diagnosticRequire(box.profiles.profiles[0].usesGlobalAudioBuffer
                && box.profiles.profiles[0].audioBufferSetting == .automatic, "Reset did not resume global Automatic")
            try fixture.snapshot(to: artifacts.appendingPathComponent("automatic-buffer-plugins.png"))
        }
        print("ABUI: Native global/profile/plug-in Automatic pickers, draft isolation, manual sizes, inheritance and undo passed")
    }

    private static func pluginSidechainInteractions(artifacts: URL) async throws {
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        let descriptor = AudioPluginDescriptor(id: "sidechain-fixture", name: "Sidechain Fixture", manufacturer: "CamiTune Tests", format: .audioUnit,
            componentType: 0x61756678, componentSubtype: 5, componentManufacturer: 0x43545473)
        let source = PluginSidechainSource(kind: .application, id: "fixture.drums", name: "Drums")
        let slot = AudioPluginSlot(plugin: descriptor, sidechain: source)
        var profile = DiagnosticSandbox.profile(); profile.pluginRack.slots = [slot]
        box.profiles.profiles = [profile]
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: DiagnosticRuntimeFakes().services())
        defer { state.shutdownSynchronously() }
        var applied = false, result: PluginSidechainSource? = source
        let fixture = WindowFixture(PluginSidechainView(state: state, profile: profile, slot: slot) { source, _ in
            result = source; applied = true
        }, size: .init(width: 380, height: 250))
        defer { fixture.close() }
        let deadline = Date().addingTimeInterval(6)
        while state.pluginRackManager.capabilities[slot.id] == nil && Date() < deadline {
            await fixture.settle()
        }
        await fixture.settle()
        try diagnosticRequire(state.pluginRackManager.capabilities[slot.id]?.sidechainBuses.count == 1, "Routing did not discover the auxiliary input")
        guard let picker = fixture.views.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.itemTitles.contains("Off") }),
              let off = picker.itemTitles.firstIndex(of: "Off") else { throw DiagnosticFailure(message: "Routing source selector is missing") }
        try diagnosticRequire(picker.itemTitles.contains("Drums · Unavailable"), "A disconnected saved app disappeared from routing")
        try fixture.snapshot(to: artifacts.appendingPathComponent("plugin-sidechain.png"))
        picker.selectItem(at: off); picker.menu?.performActionForItem(at: off)
        await fixture.settle()
        guard let apply = fixture.views.first(where: { $0.identifier?.rawValue == "plugin-sidechain-apply" }) else {
            throw DiagnosticFailure(message: "Routing Apply button is missing")
        }
        fixture.click(in: apply, at: .init(x: apply.bounds.midX, y: apply.bounds.midY))
        await fixture.settle()
        try diagnosticRequire(applied && result == nil, "The routing selector could not disconnect its saved sidechain")
        try diagnosticRequire(state.pluginRackManager.statuses[profile.id]?.active != true, "Opening routing activated audio")
        print("PLUI: Sidechain source selector, unavailable app, bus discovery and Apply passed without opening audio inputs")
    }

    static func pluginInteractions(artifacts: URL) async throws {
        if ProcessInfo.processInfo.environment["CAMITUNE_UI_MIDI_PROGRAM_ONLY"] == "1" {
            try await pluginProgramInteractions(artifacts: artifacts)
            try await DeveloperSelfTests.pluginMIDIProfileSwitching()
            return
        }
        if ProcessInfo.processInfo.environment["CAMITUNE_UI_SIDECHAIN_ONLY"] == "1" {
            try await pluginSidechainInteractions(artifacts: artifacts)
            return
        }
        if ProcessInfo.processInfo.environment["CAMITUNE_UI_BUFFER_ONLY"] == "1" {
            try await automaticBufferInteractions(artifacts: artifacts)
            return
        }
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        var profile = DiagnosticSandbox.profile()
        profile.pluginRack.slots = [.init(plugin: DeveloperSelfTests.pluginTestDescriptor()),
            .init(plugin: .init(id: "43616D6954756E655465737445666678", name: "A longer VST3 effect name for layout", manufacturer: "CamiTune Tests", format: .vst3, location: "/tmp/Fixture.vst3")),
            .init(plugin: DeveloperSelfTests.pluginTestDescriptor(), state: Data([1, 2, 3]))]
        box.profiles.profiles = [profile]
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: DiagnosticRuntimeFakes().services())
        let fixture = WindowFixture(PluginSectionFixture(state: state, store: box.profiles), size: .init(width: 720, height: 650))
        defer { fixture.close(); state.cancelMultichannelAutosaves(); state.pluginReorderApplies.cancelPending() }
        fixture.host.autoresizingMask = []
        func control(_ id: String) throws -> NSView {
            guard let view = fixture.views.first(where: { $0.identifier?.rawValue == id }) else {
                throw DiagnosticFailure(message: "Missing plug-in control: \(id)")
            }
            return view
        }
        func frame(_ id: String) throws -> NSRect {
            let view = try control(id)
            return view.convert(view.bounds, to: fixture.host)
        }
        for width in [CGFloat(540), 900] {
            fixture.resize(width: width, height: 650)
            fixture.host.setFrameSize(.init(width: width, height: 650))
            await fixture.settle()
            let switches = fixture.views.compactMap { $0 as? NSSwitch }
            try diagnosticRequire(switches.count == 4 && switches.allSatisfy(\.isEnabled), "Rack or effect switches missing after resize")
            for control in switches {
                let frame = control.convert(control.bounds, to: fixture.host)
                try diagnosticRequire(frame.minX >= 0 && frame.maxX <= width, "Plug-in switch overflows the editor")
            }
            let header = try frame("plugin-rack-header"), add = try frame("plugin-rack-add")
            try diagnosticRequire(header.contains(add), "Add icon overflows the rack header")
            for slot in profile.pluginRack.slots {
                let title = try frame("plugin-title-\(slot.id)"), menu = try frame("plugin-presets-\(slot.id)")
                let remove = try frame("plugin-editor-\(slot.id)")
                try diagnosticRequire(abs(remove.minX - title.maxX - 6) < 2 && abs(remove.midY - title.midY) < 1,
                    "Editor icon is not beside the plug-in title")
                try diagnosticRequire(menu.minX >= 0 && menu.maxX <= width, "Preset menu overflows the rack")
                guard let row = fixture.views.compactMap({ $0 as? PluginRackDragSource.SourceView }).first(where: { $0.slotID == slot.id }) else {
                    throw DiagnosticFailure(message: "Missing whole-row drag surface")
                }
                let rowFrame = row.convert(row.bounds, to: fixture.host)
                try diagnosticRequire(rowFrame.insetBy(dx: -1, dy: -1).contains(title)
                    && rowFrame.insetBy(dx: -1, dy: -1).contains(menu)
                    && row.registeredDraggedTypes.contains(PluginRackDragSource.pasteboardType),
                    "Native drag/drop surface does not cover the responsive row")
                try diagnosticRequire(remove.minX >= 0 && remove.maxX <= width, "Editor icon overflows the rack")
            }
            let rows = fixture.views.compactMap { $0 as? PluginRackDragSource.SourceView }
            let slots = profile.pluginRack.slots
            guard let source = rows.first(where: { $0.slotID == slots[2].id }),
                  let destination = rows.first(where: { $0.slotID == slots[1].id }),
                  let coordinator = source.coordinator else { throw DiagnosticFailure(message: "Missing divider drag fixture") }
            try diagnosticRequire(source.toolTip == nil, "Drag surface still has a hover hint")
            _ = coordinator.begin(source.slotID, modifiers: .command)
            let divider = try control("plugin-divider-1")
            let drop = PluginDragInfo(source: source)
            drop.draggingLocation = divider.convert(.init(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
            try diagnosticRequire(destination.draggingEntered(drop) == .move, "Divider is not a native drop destination")
            await fixture.settle()
            let marker = try frame("plugin-reorder-marker"), dividerFrame = try frame("plugin-divider-1")
            try diagnosticRequire(abs(marker.midY - dividerFrame.midY) < 0.5
                && abs(marker.minX - dividerFrame.minX) < 0.5 && abs(marker.maxX - dividerFrame.maxX) < 0.5,
                "Blue insertion marker does not align with the grey divider")
            try fixture.snapshot(to: artifacts.appendingPathComponent("plugins-divider-\(Int(width)).png"))
            coordinator.cancel(); await fixture.settle()
            try fixture.snapshot(to: artifacts.appendingPathComponent("plugins-\(Int(width)).png"))
        }
        do {
            let probe = PluginMenuProbe()
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) {
                probe.menu = $0.object as? NSMenu
            }
            let dismiss = Timer(timeInterval: 0.15, repeats: true) { _ in probe.menu?.cancelTracking() }
            RunLoop.main.add(dismiss, forMode: .common)
            defer { dismiss.invalidate(); NotificationCenter.default.removeObserver(observer) }
            let menuButton = try control("plugin-presets-\(profile.pluginRack.slots[0].id)")
            for (x, y) in [(0.5, 0.5), (0.1, 0.1), (0.9, 0.1), (0.1, 0.9), (0.9, 0.9)] {
                probe.menu = nil
                fixture.click(in: menuButton, at: .init(x: menuButton.bounds.width * x, y: menuButton.bounds.height * y))
                await fixture.settle()
                let actions = probe.menu?.items.map(\.title).filter { !$0.isEmpty } ?? []
                try diagnosticRequire(actions == ["Save Preset…", "Load Preset…", "Reset to Default", "Sidechain…", "Remove Plug-in"],
                    "Options menu did not open across its full hit area (\(x), \(y)): \(actions)")
            }
        }
        do {
            let original = box.profiles.profiles[0].pluginRack, historyCount = state.history.undoStack.count
            let probe = PluginMenuProbe()
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) {
                probe.menu = $0.object as? NSMenu
            }
            let select = Timer(timeInterval: 0.15, repeats: true) { _ in
                guard let menu = probe.menu, let index = menu.items.firstIndex(where: { $0.title == "Sidechain…" }) else { return }
                probe.menu = nil
                menu.performActionForItem(at: index); menu.cancelTracking()
            }
            RunLoop.main.add(select, forMode: .common)
            defer { select.invalidate(); NotificationCenter.default.removeObserver(observer) }
            let menu = try control("plugin-presets-\(profile.pluginRack.slots[0].id)")
            fixture.click(in: menu, at: .init(x: menu.bounds.midX, y: menu.bounds.midY))
            await fixture.settle()
            let readyDeadline = Date().addingTimeInterval(6)
            while state.pluginRackManager.capabilities[profile.pluginRack.slots[0].id] == nil && Date() < readyDeadline {
                await fixture.settle()
            }
            await fixture.settle()
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            guard let cancel = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(descendants)
                .first(where: { $0.identifier?.rawValue == "plugin-sidechain-cancel" }), let window = cancel.window else {
                throw DiagnosticFailure(message: "Sidechain options menu did not open routing controls")
            }
            window.contentView?.layoutSubtreeIfNeeded(); window.contentView?.displayIfNeeded()
            window.makeKeyAndOrderFront(nil)
            let location = cancel.convert(NSPoint(x: cancel.bounds.midX, y: cancel.bounds.midY), to: nil)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            NSApp.postEvent(up, atStart: false); window.sendEvent(down)
            let dismissDeadline = Date().addingTimeInterval(2)
            while window.isVisible && Date() < dismissDeadline { await fixture.settle() }
            try diagnosticRequire(!window.isVisible, "Cancel did not close the sidechain popover")
            // Inspecting capabilities may capture the plug-in's initial DSP
            // state. Routing, slot identity and undo history must stay intact.
            var inspected = box.profiles.profiles[0].pluginRack
            for index in inspected.slots.indices {
                inspected.slots[index].state = original.slots.first(where: { $0.id == inspected.slots[index].id })?.state
            }
            try diagnosticRequire(inspected == original && state.history.undoStack.count == historyCount,
                "Opening and cancelling sidechain options changed routing")
        }
        print("PLUI: Options open at the center and all four corners; Sidechain opens and cancels without changing routing")
        // SwiftUI exposes the identifier on its accessibility wrapper rather
        // than the underlying NSSwitch on macOS 13. The rack switch is first.
        guard let toggle = fixture.views.compactMap({ $0 as? NSSwitch }).min(by: {
            $0.convert($0.bounds, to: fixture.host).minY < $1.convert($1.bounds, to: fixture.host).minY
        }) else {
            throw DiagnosticFailure(message: "Missing rack switch")
        }
        toggle.state = .off
        try diagnosticRequire(toggle.sendAction(toggle.action, to: toggle.target), "Rack bypass action was not delivered")
        await fixture.settle()
        try diagnosticRequire(!box.profiles.profiles[0].pluginRack.isEnabled && state.history.undoStack.count == 1, "Rack bypass was not saved as one undo action")
        await state.history.undo()
        try diagnosticRequire(box.profiles.profiles[0].pluginRack.isEnabled, "Undo did not restore rack")
        await state.history.redo()
        try diagnosticRequire(!box.profiles.profiles[0].pluginRack.isEnabled, "Redo did not bypass rack")
        guard let bufferPicker = fixture.views.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.itemTitles.contains(where: { $0.hasPrefix("Automatic") }) }),
              let automaticIndex = bufferPicker.itemTitles.firstIndex(where: { $0.hasPrefix("Automatic") }) else {
            throw DiagnosticFailure(message: "Automatic buffer option is missing from the plug-in section")
        }
        bufferPicker.selectItem(at: automaticIndex)
        bufferPicker.menu?.performActionForItem(at: automaticIndex)
        await fixture.settle()
        try diagnosticRequire(box.profiles.profiles[0].audioBufferOverride == .automatic, "Native Automatic picker did not save the shared preference")
        await state.history.undo(); await fixture.settle()
        try diagnosticRequire(box.profiles.profiles[0].usesGlobalAudioBuffer, "Undo did not restore buffer inheritance")
        let originalBuffer = box.profiles.profiles[0].chunkSize
        try await state.commitAudioBufferSize(128, profileID: profile.id)
        await state.history.undo()
        try diagnosticRequire(box.profiles.profiles[0].chunkSize == originalBuffer, "Buffer undo changed the wrong profile field")
        await fixture.settle()
        let originalRack = box.profiles.profiles[0].pluginRack, ids = originalRack.slots.map(\.id)
        guard let drag = fixture.views.compactMap({ $0 as? PluginRackDragSource.SourceView }).first(where: { $0.slotID == ids[0] }),
              let reorder = drag.coordinator else { throw DiagnosticFailure(message: "Missing native plug-in drag source") }
        try diagnosticRequire(!drag.capturesMouse(modifiers: []) && drag.capturesMouse(modifiers: .command),
            "Plug-in dragging captures ordinary clicks or rejects Command-drag")
        let undoBeforeDrag = state.history.undoStack.count
        try diagnosticRequire(!reorder.begin(ids[0], modifiers: []) && reorder.begin(ids[0], modifiers: .command), "Reordering does not require Command")
        guard let destination = fixture.views.compactMap({ $0 as? PluginRackDragSource.SourceView }).first(where: { $0.slotID == ids[2] }) else {
            throw DiagnosticFailure(message: "Missing native plug-in drop destination")
        }
        let drop = PluginDragInfo(source: drag)
        drop.draggingLocation = destination.convert(.init(x: destination.bounds.maxX - 4, y: destination.bounds.maxY - 2), to: nil)
        try diagnosticRequire(destination.draggingEntered(drop) == .move && destination.draggingUpdated(drop) == .move,
            "Native plug-in pasteboard was rejected by the destination")
        try diagnosticRequire(reorder.target == .init(id: ids[2], after: true), "Native drop selected the wrong insertion point")
        let hit = fixture.host.hitTest(fixture.host.superview?.convert(drop.draggingLocation, from: nil) ?? drop.draggingLocation)
        try diagnosticRequire(hit === destination, "Whole-row overlay is not reachable through native hit testing: \(String(describing: hit))")
        await fixture.settle()
        try diagnosticRequire(box.profiles.profiles[0].pluginRack == originalRack && state.history.undoStack.count == undoBeforeDrag,
            "Drag preview changed saved processing or history")
        try fixture.snapshot(to: artifacts.appendingPathComponent("plugins-reordering.png"))
        try diagnosticRequire(destination.prepareForDragOperation(drop) && destination.performDragOperation(drop), "Native reorder drop was rejected")
        await fixture.settle()
        try diagnosticRequire(box.profiles.profiles[0].pluginRack.slots == [originalRack.slots[1], originalRack.slots[2], originalRack.slots[0]]
            && state.history.undoStack.count == undoBeforeDrag + 1, "Drop lost slot identity/state or created multiple undo entries")
        await state.history.undo(); await fixture.settle()
        try diagnosticRequire(box.profiles.profiles[0].pluginRack == originalRack, "Undo did not restore the processing order")
        _ = reorder.begin(ids[0], modifiers: .command)
        reorder.updateTarget(.init(id: ids[1], after: false))
        try diagnosticRequire(!reorder.performDrop() && state.history.undoStack.count == undoBeforeDrag, "Unchanged drop recorded a redundant edit")
        _ = reorder.begin(ids[2], modifiers: .command)
        reorder.updateTarget(.init(id: ids[0], after: false))
        reorder.cancel()
        try diagnosticRequire(box.profiles.profiles[0].pluginRack == originalRack && reorder.target == nil, "Cancelled drag changed the rack")
        if ProcessInfo.processInfo.environment["CAMITUNE_UI_SYSTEM_MOUSE"] == "1" {
            try diagnosticRequire(CGPreflightPostEventAccess(), "Native drag test requires event-posting access")
            let originalFrame = fixture.window.frame
            let originalPointer = CGEvent(source: nil)?.location
            fixture.window.setFrameOrigin(.init(x: 100, y: 100))
            fixture.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            defer {
                fixture.window.setFrame(originalFrame, display: true)
                if let originalPointer {
                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: originalPointer,
                        mouseButton: .left)?.post(tap: .cghidEventTap)
                }
            }
            func dragRow(_ sourceID: UUID, to targetID: UUID, after: Bool) async throws {
                fixture.window.makeKeyAndOrderFront(nil)
                NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                await fixture.settle()
                try diagnosticRequire(NSApp.isActive, "System mouse test could not activate its window; an unlocked foreground desktop session is required")
                let rows = fixture.views.compactMap { $0 as? PluginRackDragSource.SourceView }
                guard let source = rows.first(where: { $0.slotID == sourceID }),
                      let target = rows.first(where: { $0.slotID == targetID }) else {
                    throw DiagnosticFailure(message: "Missing native drag rows")
                }
                func screenPoint(_ view: NSView, _ point: NSPoint) -> CGPoint {
                    let screen = fixture.window.convertPoint(toScreen: view.convert(point, to: nil))
                    return .init(x: screen.x, y: NSScreen.screens[0].frame.maxY - screen.y)
                }
                // Start on the row number; drop over the trailing controls, outside the title.
                let start = screenPoint(source, .init(x: 8, y: source.bounds.midY))
                let targetIndex = ids.firstIndex(of: targetID)! + (after ? 1 : 0)
                let end: CGPoint
                if targetIndex > 0 && targetIndex < ids.count {
                    let divider = try control("plugin-divider-\(targetIndex)")
                    end = screenPoint(divider, .init(x: divider.bounds.maxX - 8, y: divider.bounds.midY))
                } else {
                    end = screenPoint(target, .init(x: target.bounds.maxX - 8, y: after ? target.bounds.maxY - 3 : 3))
                }
                var pointer = start
                func send(_ type: CGEventType, _ point: CGPoint, command: Bool = true) {
                    pointer = point
                    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
                    event.flags = command ? .maskCommand : []
                    event.setIntegerValueField(.mouseEventClickState, value: 1)
                    event.post(tap: .cghidEventTap)
                }
                var buttonDown = true
                defer { if buttonDown { send(.leftMouseUp, pointer, command: false) } }
                send(.mouseMoved, start)
                send(.leftMouseDown, start)
                try await Task.sleep(for: .milliseconds(60))
                send(.leftMouseDragged, .init(x: start.x + 8, y: start.y))
                try await Task.sleep(for: .milliseconds(120))
                try diagnosticRequire(reorder.sourceID == sourceID, "System Command-drag did not start outside the title at width \(fixture.host.bounds.width), source \(sourceID), coordinator \(String(describing: reorder.sourceID))")
                for step in 1...12 {
                    let fraction = CGFloat(step) / 12
                    send(.leftMouseDragged, .init(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction))
                    try await Task.sleep(for: .milliseconds(20))
                }
                try await Task.sleep(for: .milliseconds(100))
                let actualIndex = reorder.target.flatMap { destination in ids.firstIndex(of: destination.id).map { $0 + (destination.after ? 1 : 0) } }
                try diagnosticRequire(actualIndex == targetIndex, "System drag did not reach the divider's insertion point")
                try diagnosticRequire(box.profiles.profiles[0].pluginRack == originalRack && state.history.undoStack.count == undoBeforeDrag,
                    "Mouse movement committed processing changes before drop")
                send(.leftMouseUp, end)
                buttonDown = false
                send(.mouseMoved, end, command: false)
                await fixture.settle()
                try diagnosticRequire(reorder.sourceID == nil && state.history.undoStack.count == undoBeforeDrag + 1
                    && state.pluginReorderApplies.applying.isEmpty && fixture.views.compactMap { $0 as? NSSwitch }.allSatisfy(\.isEnabled),
                    "System drop did not commit exactly one edit or blocked the next drag with loading")
            }
            for (width, sourceIndex, targetIndex, after, expected) in [
                (900, 0, 2, true, [1, 2, 0]), (900, 2, 0, false, [2, 0, 1]),
                (540, 0, 1, true, [1, 0, 2])
            ] {
                fixture.resize(width: CGFloat(width), height: 650)
                fixture.host.setFrameSize(.init(width: width, height: 650))
                try await dragRow(ids[sourceIndex], to: ids[targetIndex], after: after)
                try diagnosticRequire(box.profiles.profiles[0].pluginRack.slots == expected.map { originalRack.slots[$0] },
                    "System drag saved an incorrect order or lost effect state")
                await state.history.undo(); await fixture.settle()
                try diagnosticRequire(box.profiles.profiles[0].pluginRack == originalRack, "System drag undo did not restore the rack")
            }
            print("PLUI: Real system Command-drags moved rows down, up and into the middle at wide/narrow sizes, with one undo per drop")
        }
        do {
            let probe = PluginMenuProbe()
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) {
                probe.menu = $0.object as? NSMenu
            }
            let select = Timer(timeInterval: 0.15, repeats: true) { _ in
                guard let menu = probe.menu, let index = menu.items.firstIndex(where: { $0.title == "Remove Plug-in" }) else { return }
                probe.menu = nil
                menu.performActionForItem(at: index); menu.cancelTracking()
            }
            RunLoop.main.add(select, forMode: .common)
            defer { select.invalidate(); NotificationCenter.default.removeObserver(observer) }
            let menu = try control("plugin-presets-\(ids[2])")
            fixture.click(in: menu, at: .init(x: menu.bounds.midX, y: menu.bounds.midY))
            // SwiftUI button-style menus open on the queued mouse-up. Keep the
            // selection timer and observer alive until that event is handled.
            await fixture.settle()
        }
        try diagnosticRequire(box.profiles.profiles[0].pluginRack.slots == Array(originalRack.slots.prefix(2)),
            "Remove menu item did not remove only the selected effect: \(box.profiles.profiles[0].pluginRack.slots.map(\.id))")
        await state.history.undo(); await fixture.settle()
        try diagnosticRequire(box.profiles.profiles[0].pluginRack == originalRack, "Remove undo did not restore the effect's state and position")
        for roles in [LPCMChannelLayout.fivePointOne.roles, LPCMChannelLayout.ninePointOnePointSix.roles, Array(repeating: ChannelRole.unknown, count: 32)] {
            var multichannel = DeveloperSelfTests.pluginChannelProfile(roles: roles)
            multichannel.id = profile.id
            multichannel.pluginRack = originalRack
            multichannel.pluginRack.isEnabled = false
            box.profiles.update(multichannel)
            await fixture.settle()
            try diagnosticRequire(fixture.views.compactMap { $0 as? NSSwitch }.allSatisfy(\.isEnabled), "Multichannel profile disables rack/effect controls")
            let add = try control("plugin-rack-add")
            fixture.click(in: add, at: .init(x: add.bounds.midX, y: add.bounds.midY))
            await fixture.settle()
            try diagnosticRequire(fixture.window.attachedSheet != nil, "Multichannel profile cannot open Add Plug-in")
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            guard let content = fixture.window.attachedSheet?.contentView,
                  let cancel = descendants(content).first(where: { $0.identifier?.rawValue == "plugin-picker-cancel" }),
                  let sheet = cancel.window else { throw DiagnosticFailure(message: "Missing plug-in picker Cancel") }
            let location = cancel.convert(NSPoint(x: cancel.bounds.midX, y: cancel.bounds.midY), to: nil)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: sheet.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
                windowNumber: sheet.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            // Native buttons synchronously track until mouse-up, as in WindowFixture.click.
            NSApp.postEvent(up, atStart: false)
            sheet.sendEvent(down)
            await fixture.settle()
            try diagnosticRequire(fixture.window.attachedSheet == nil, "Cancel did not dismiss the multichannel plug-in picker")
        }
        print("PLUI: Native rack controls fit narrow/wide layouts; bypass, undo/redo and buffer persistence passed")
        print("PLUI: Native drop acceptance, full-row hit testing, cancellation, no-op and remove preserve slot state and undo")
        print("PLUI: 5.1, 9.1.6 and 32-channel profiles enable rack controls and Add without channel setup")
        try await pluginLoadingLayout(artifacts: artifacts)
        // Focused drag/layout checks do not need a plug-in editor or file panel.
        if ProcessInfo.processInfo.environment["CAMITUNE_UI_REORDER_ONLY"] == "1" { return }
        try await pluginPickerInteractions(artifacts: artifacts)
        try await pluginProgramInteractions(artifacts: artifacts)
        try await pluginMIDIInteractions(artifacts: artifacts)
    }

    private static func pluginProgramInteractions(artifacts: URL) async throws {
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        var profile = DiagnosticSandbox.profile()
        var descriptor = DeveloperSelfTests.pluginTestDescriptor()
        descriptor.name = "A longer plug-in name for program selection"
        let slot = AudioPluginSlot(plugin: descriptor)
        let otherSlot = AudioPluginSlot(plugin: descriptor)
        profile.pluginRack.slots = [slot, otherSlot]
        profile.pluginRack.midi.mappings = [slot, otherSlot].map {
            PluginMIDIMapping(slotID: $0.id, parameterID: 0, parameterName: "Gain",
                sourceID: 123456789, sourceName: "Test", channel: 1, controller: 7)
        }
        let mappings = profile.pluginRack.midi.mappings
        profile.pluginRack.midi.isEnabled = true
        profile.pluginRack.midi.sourceID = 123456789
        box.profiles.profiles = [profile]
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: DiagnosticRuntimeFakes().services())
        let fixture = WindowFixture(PluginProgramFixture(state: state, store: box.profiles), size: .init(width: 540, height: 320))
        defer { fixture.close(); state.shutdownSynchronously() }
        await fixture.settle()
        func clickKeyboard(_ id: UUID) async throws {
            guard let button = fixture.views.first(where: { $0.identifier?.rawValue == "plugin-midi-program-\(id)" }) else {
                throw DiagnosticFailure(message: "Missing MIDI program keyboard button")
            }
            fixture.click(in: button, at: .init(x: button.bounds.midX, y: button.bounds.midY))
            await fixture.settle()
        }
        try diagnosticRequire(profile.pluginRack.midi.programChangeSlotID == nil, "Program changes did not default to Off")
        try await clickKeyboard(slot.id)
        try diagnosticRequire(box.profiles.profiles[0].pluginRack.midi.programChangeSlotID == slot.id
            && state.history.undoStack.count == 1, "Program destination did not persist as one edit")
        await state.history.undo(); await fixture.settle()
        try diagnosticRequire(box.profiles.profiles[0].pluginRack.midi.programChangeSlotID == nil, "Program destination undo failed")
        await state.history.redo(); await fixture.settle()
        try diagnosticRequire(box.profiles.profiles[0].pluginRack.midi.programChangeSlotID == slot.id, "Program destination redo failed")
        try await clickKeyboard(otherSlot.id)
        try diagnosticRequire(box.profiles.profiles[0].pluginRack.midi.programChangeSlotID == otherSlot.id
            && box.profiles.profiles[0].pluginRack.midi.mappings == mappings, "Selecting another plug-in changed profile-wide mappings")
        let savedProfile = box.profiles.profiles[0]
        var otherProfile = DiagnosticSandbox.profile()
        otherProfile.name = "Second MIDI profile"
        let thirdSlot = AudioPluginSlot(plugin: descriptor)
        otherProfile.pluginRack.slots = [thirdSlot]
        otherProfile.pluginRack.midi.isEnabled = true
        otherProfile.pluginRack.midi.programChangeSlotID = thirdSlot.id
        box.profiles.profiles = [otherProfile, savedProfile]
        await fixture.settle()
        try await clickKeyboard(thirdSlot.id)
        try diagnosticRequire(box.profiles.profiles[0].pluginRack.midi.programChangeSlotID == nil
            && box.profiles.profiles[1].pluginRack.midi.programChangeSlotID == otherSlot.id, "Profile selection leaked between profiles")
        box.profiles.profiles.swapAt(0, 1)
        await fixture.settle()
        try diagnosticRequire(box.profiles.profiles[0].pluginRack.midi.programChangeSlotID == otherSlot.id
            && box.profiles.profiles[0].pluginRack.midi.mappings == mappings, "Returning to the profile lost MIDI settings")
        try await clickKeyboard(slot.id)
        for width in [CGFloat(420), 540, 900] {
            fixture.resize(width: width, height: 320); await fixture.settle()
            for id in ["plugin-midi-enabled", "plugin-midi-source", "plugin-midi-program-\(slot.id)"] {
                guard let view = fixture.views.first(where: { $0.identifier?.rawValue == id }) else {
                    throw DiagnosticFailure(message: "Missing MIDI input control: \(id)")
                }
                let frame = view.convert(view.bounds, to: fixture.host)
                try diagnosticRequire(fixture.host.bounds.insetBy(dx: -1, dy: -1).contains(frame), "MIDI input control is clipped at \(width): \(id)")
            }
            try fixture.snapshot(to: artifacts.appendingPathComponent("plugin-midi-program-\(Int(width)).png"))
        }
        try await clickKeyboard(slot.id)
        try diagnosticRequire(box.profiles.profiles[0].pluginRack.midi.programChangeSlotID == nil, "Off did not clear the program destination")
        print("PLUI: Program keyboard buttons save, disable and undo/redo; MIDI input controls fit narrow/wide layouts")
    }

    private struct PluginProgramFixture: View {
        let state: AppState
        @ObservedObject var store: ProfileStore
        @State private var error: String?
        var body: some View {
            VStack(alignment: .leading) {
                ForEach(store.profiles[0].pluginRack.slots) { slot in
                    HStack {
                        Text(slot.plugin.name).lineLimit(1)
                        Spacer()
                        PluginProgramButton(state: state, profile: store.profiles[0], slot: slot, error: $error)
                    }
                }
                PluginMIDIInputView(state: state, profile: Binding(get: { store.profiles[0] }, set: { store.update($0) }),
                    status: state.pluginRackManager.midiStatus(for: store.profiles[0].id))
            }.padding(16)
        }
    }

    private static func pluginLoadingLayout(artifacts: URL) async throws {
        for width in [CGFloat(540), 900] {
            let box = try DiagnosticSandbox(); defer { box.cleanUp() }
            var profile = DiagnosticSandbox.profile()
            profile.pluginRack.slots = (0..<2).map { _ in .init(plugin: DeveloperSelfTests.pluginTestDescriptor()) }
            box.profiles.profiles = [profile]
            let gate = DiagnosticManualGate()
            let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: DiagnosticRuntimeFakes().services())
            state.pluginReorderApplies = PluginRackReorderApply(delay: .milliseconds(40)) { _, _ in
                try? await gate.enter(); return true
            }
            let fixture = WindowFixture(PluginSectionFixture(state: state, store: box.profiles), size: .init(width: width, height: 650))
            defer { gate.release(); state.pluginReorderApplies.cancelPending(); fixture.close() }
            await fixture.settle()
            func frame(_ id: String) throws -> NSRect {
                guard let view = fixture.views.first(where: { $0.identifier?.rawValue == id }) else {
                    throw DiagnosticFailure(message: "Missing loading-layout anchor: \(id)")
                }
                return view.convert(view.bounds, to: fixture.host)
            }
            let anchors = ["plugin-rack-header", "plugin-rack-help", "plugin-rack-add", "plugin-rack-content", "plugin-title-\(profile.pluginRack.slots[0].id)"]
            let before = try anchors.map(frame)
            state.pluginReorderApplies.schedule(profile.id)
            try await gate.waitUntilEntered()
            await fixture.settle()
            let progress = try frame("plugin-rack-progress"), help = try frame("plugin-rack-help")
            let loading = try anchors.map(frame)
            try diagnosticRequire(before == loading, "Loading changed spacing or moved existing controls")
            try diagnosticRequire(abs(progress.midY - help.midY) < 1 && abs(progress.minX - help.maxX - 6) < 1,
                "Loading indicator is not beside the header tooltip")
            guard let row = fixture.views.compactMap({ $0 as? PluginRackDragSource.SourceView }).first,
                  let reorder = row.coordinator else { throw DiagnosticFailure(message: "Missing row during loading") }
            try diagnosticRequire(reorder.begin(row.slotID, modifiers: .command), "Loading blocked another reorder gesture")
            reorder.cancel()
            try fixture.snapshot(to: artifacts.appendingPathComponent("plugins-loading-\(Int(width)).png"))
            gate.release(); await fixture.settle()
            let finished = try anchors.map(frame)
            try diagnosticRequire(before == finished, "Finishing loading changed the section's layout")
        }
        print("PLUI: Loading stays beside the title tooltip with unchanged header, rows and section spacing at both widths")
    }

    private static func pluginMIDIInteractions(artifacts: URL) async throws {
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        var profile = DiagnosticSandbox.profile()
        let slot = AudioPluginSlot(plugin: DeveloperSelfTests.pluginTestDescriptor())
        profile.pluginRack.slots = [slot]
        profile.pluginRack.midi.isEnabled = true; profile.pluginRack.midi.sourceID = 123456789
        box.profiles.profiles = [profile]
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: DiagnosticRuntimeFakes().services())
        let model = state.pluginRackManager.controls(for: slot.id)
        let fixture = WindowFixture(PluginControlsFixture(state: state, store: box.profiles, slot: slot, model: model), size: .init(width: 700, height: 740))
        defer { fixture.close() }
        await fixture.settle()
        func anchor(_ id: String) throws -> NSView {
            guard let view = fixture.views.first(where: { $0.identifier?.rawValue == id }) else { throw DiagnosticFailure(message: "Missing MIDI control: \(id)") }
            return view
        }
        let learn = try anchor("plugin-midi-map-\(slot.id)")
        fixture.click(in: learn, at: .init(x: learn.bounds.midX, y: learn.bounds.midY))
        await fixture.settle()
        let deadline = Date().addingTimeInterval(10)
        while (model.loading || !model.mappingActive) && Date() < deadline { await fixture.settle() }
        guard let parameter = model.parameters.first else { throw DiagnosticFailure(message: "Map did not load parameters: \(model.error ?? "timeout")") }
        try diagnosticRequire(model.choosingInEditor, "Map did not watch the native editor")
        state.pluginRackManager.control("setParameter", slotID: slot.id, values: ["parameterID": parameter.id, "value": parameter.minimum + (parameter.maximum - parameter.minimum) * 0.4])
        let touchDeadline = Date().addingTimeInterval(3)
        while model.learningParameterID == nil && Date() < touchDeadline { await fixture.settle() }
        try diagnosticRequire(model.learningParameterID == parameter.id, "Editor gesture did not arm MIDI learning")
        state.pluginRackManager.control("testMIDI", slotID: slot.id, values: ["messages": [["source": 123456789, "status": 0xb0, "data1": 21, "data2": 64]]])
        let learnDeadline = Date().addingTimeInterval(3)
        while box.profiles.profiles[0].pluginRack.midi.mappings.isEmpty && Date() < learnDeadline { await fixture.settle() }
        guard let mapping = box.profiles.profiles[0].pluginRack.midi.mappings.first else { throw DiagnosticFailure(message: "Learn did not save a mapping: \(model.error ?? "no event")") }
        try diagnosticRequire(mapping.parameterID == parameter.id && mapping.controller == 21 && model.learningParameterID == nil, "Learn captured the wrong control")
        await fixture.settle()
        try fixture.snapshot(to: artifacts.appendingPathComponent("plugin-midi-controls.png"))
        let remove = try anchor("plugin-midi-remove-\(mapping.id)")
        fixture.click(in: remove, at: .init(x: remove.bounds.midX, y: remove.bounds.midY))
        await fixture.settle()
        try diagnosticRequire(box.profiles.profiles[0].pluginRack.midi.mappings.isEmpty, "Remove mapping failed")
        await state.history.undo(); await fixture.settle()
        try diagnosticRequire(box.profiles.profiles[0].pluginRack.midi.mappings == [mapping], "Mapping undo lost its source or parameter")
        for (placeholder, value, expected) in [("Min", "80", 0.8), ("Max", "20", 0.2)] {
            guard let field = fixture.textFields.first(where: { $0.placeholderString == placeholder }) else {
                throw DiagnosticFailure(message: "Missing mapping range field")
            }
            try await fixture.edit(field, text: value)
            fixture.window.makeFirstResponder(nil); await fixture.settle()
            let saved = box.profiles.profiles[0].pluginRack.midi.mappings[0]
            try diagnosticRequire((placeholder == "Min" ? saved.lower : saved.upper) == expected, "Range edit was not saved")
        }
        let reversed = box.profiles.profiles[0].pluginRack.midi.mappings[0]
        try diagnosticRequire(reversed.lower == 0.8 && reversed.upper == 0.2, "Editing Max reset Min instead of keeping the reversed range")
        guard let curve = fixture.views.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.itemTitles.contains("S-Curve") }) else {
            throw DiagnosticFailure(message: "Response curve picker is missing")
        }
        curve.selectItem(withTitle: "Hard")
        curve.menu?.performActionForItem(at: curve.indexOfSelectedItem)
        await fixture.settle()
        let curved = box.profiles.profiles[0].pluginRack.midi.mappings[0]
        try diagnosticRequire(curved.curve == .hard && curved.lower == 0.8 && curved.upper == 0.2, "Response curve changed the saved range")
        try fixture.snapshot(to: artifacts.appendingPathComponent("plugin-midi-response.png"))
        guard let mode = fixture.views.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.itemTitles.contains("Toggle Button") }) else {
            throw DiagnosticFailure(message: "Control mode picker is missing")
        }
        mode.selectItem(withTitle: "Toggle Button")
        mode.menu?.performActionForItem(at: mode.indexOfSelectedItem)
        await fixture.settle()
        try diagnosticRequire(box.profiles.profiles[0].pluginRack.midi.mappings[0].mode == .toggle, "Button mode did not save")
        await state.history.undo(); await fixture.settle()
        try diagnosticRequire(box.profiles.profiles[0].pluginRack.midi.mappings[0].mode == .knob, "Button mode undo failed")
        try diagnosticRequire(model.mappingActive && model.choosingInEditor, "Map mode did not remain active for another assignment")
        try diagnosticRequire(fixture.views.compactMap { $0 as? NSSlider }.isEmpty, "Removed parameter controls are still visible")
        for width in [CGFloat(640), 900] {
            fixture.resize(width: width, height: 740); await fixture.settle()
            let done = try anchor("plugin-midi-done"), frame = done.convert(done.bounds, to: fixture.host)
            try diagnosticRequire(fixture.host.bounds.insetBy(dx: -1, dy: -1).contains(frame), "MIDI Controls footer is clipped")
        }
        _ = await state.pluginRackManager.closeControls(slotID: slot.id)
        print("PLUI: MIDI Map selects native editor controls; min/max, curves, button modes, removal/undo and narrow/wide layouts passed")
    }

    private struct PluginControlsFixture: View {
        let state: AppState
        @ObservedObject var store: ProfileStore
        let slot: AudioPluginSlot
        let model: PluginControlsModel
        var body: some View {
            PluginMIDIMappingsView(state: state, profile: Binding(get: { store.profiles[0] }, set: { store.update($0) }))
        }
    }

    private static func pluginPickerInteractions(artifacts: URL) async throws {
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        let au = DeveloperSelfTests.pluginTestDescriptor()
        let vst = AudioPluginDescriptor(id: String(repeating: "A", count: 32), name: "VST3 Test Effect", manufacturer: "Catalog Test", format: .vst3, location: "/tmp/Test.vst3")
        let pluginJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode([au, vst]))
        let failures = Dictionary(uniqueKeysWithValues: (0..<20).map { ("/tmp/Failed \($0).vst3", "The plug-in bundle could not be opened. Select it and choose Add to try again.") })
        let data = try JSONSerialization.data(withJSONObject: ["plugins": pluginJSON, "failures": failures, "customDirectories": ["/tmp/Custom Effects", "/tmp/More Effects"]])
        try data.write(to: box.directory.appendingPathComponent("PluginCatalog.json"))
        let probe = PluginCatalogProbe(audioUnit: au)
        let catalog = PluginCatalog(directory: box.directory, standardDirectories: [], scanner: { try await probe.scan($0) })
        await catalog.load()
        let fixture = WindowFixture(PluginPickerView(catalog: catalog) { _ in }, size: .init(width: 600, height: 560))
        defer { catalog.cancelScan(); fixture.close() }
        await fixture.settle()
        func anchor(_ name: String) throws -> NSView {
            guard let view = fixture.views.first(where: { $0.identifier?.rawValue == "plugin-picker-" + name }) else {
                throw DiagnosticFailure(message: "Missing picker anchor: \(name)")
            }
            return view
        }
        func frame(_ name: String) throws -> NSRect {
            let view = try anchor(name)
            return view.convert(view.bounds, to: fixture.host)
        }
        let titleBefore = try frame("title"), actionsBefore = try frame("actions")
        let disclosure = try anchor("failures")
        fixture.click(in: disclosure, at: .init(x: disclosure.bounds.midX, y: disclosure.bounds.midY))
        await fixture.settle()
        let details = try frame("failure-details")
        try diagnosticRequire(details.height <= 101 && details.height >= 99, "Failure list grew beyond its scrolling area")
        let titleAfter = try frame("title"), actionsAfter = try frame("actions")
        try diagnosticRequire(abs(titleAfter.minY - titleBefore.minY) < 1 && abs(actionsAfter.minY - actionsBefore.minY) < 1,
            "Expanding failures moved the picker title or action row")
        for size in [NSSize(width: 600, height: 560), NSSize(width: 700, height: 620)] {
            fixture.resize(width: size.width, height: size.height)
            await fixture.settle()
            for name in ["title", "format", "folders", "actions", "failure-details"] {
                let rect = try frame(name)
                try diagnosticRequire(fixture.host.bounds.insetBy(dx: -1, dy: -1).contains(rect), "Picker \(name) was cropped at \(size)")
            }
            try fixture.snapshot(to: artifacts.appendingPathComponent("plugin-picker-expanded-\(Int(size.width)).png"))
        }
        guard let format = fixture.views.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.itemTitles.contains("AU") }) else {
            throw DiagnosticFailure(message: "Format is not a native dropdown")
        }
        try diagnosticRequire(["All", "AU", "VST3"].allSatisfy { format.itemTitles.contains($0) }, "Missing format choices")
        format.selectItem(withTitle: "AU")
        format.menu?.performActionForItem(at: format.indexOfSelectedItem)
        await fixture.settle()
        let rows = fixture.views.compactMap { $0.identifier?.rawValue }.filter { $0.hasPrefix("plugin-picker-row-") }
        try diagnosticRequire(rows.contains("plugin-picker-row-AU:\(au.id)") && !rows.contains("plugin-picker-row-VST3:\(vst.id)"), "Dropdown did not filter the visible effects")
        await probe.setHolding(true)
        catalog.scan()
        await fixture.settle()
        let progress = try frame("progress"), actions = try frame("actions")
        try diagnosticRequire(progress.minY >= actions.minY - 1 && progress.maxY <= actions.maxY + 1, "Scan loading indicator is outside the action row")
        let scanningTitle = try frame("title")
        try diagnosticRequire(fixture.host.bounds.contains(scanningTitle), "Scanning cropped the title")
        try fixture.snapshot(to: artifacts.appendingPathComponent("plugin-picker-scanning.png"))
        await probe.setHolding(false)
        try await DeveloperSelfTests.waitForPluginScan(catalog)
        print("PLUI: Expanded failures preserve title/actions at both sizes; format dropdown filters; scan progress stays in the action row")

        func openFolders() async throws -> NSWindow {
            let button = try anchor("folders")
            fixture.click(in: button, at: .init(x: button.bounds.midX, y: button.bounds.midY))
            await fixture.settle()
            func containsFolderPanel(_ view: NSView) -> Bool {
                view.identifier?.rawValue == "plugin-scan-folders" || view.subviews.contains(where: containsFolderPanel)
            }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView.map(containsFolderPanel) == true }) else {
                throw DiagnosticFailure(message: "Scan Folders did not open")
            }
            return window
        }
        func closeFolders(_ window: NSWindow) async {
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            window.sendEvent(escape)
            await fixture.settle()
        }
        let callsBeforeFolders = await probe.calls.count
        let firstFolder = box.directory.appendingPathComponent("First Custom Folder")
        let secondFolder = box.directory.appendingPathComponent("Second Custom Folder")
        let bundle = firstFolder.appendingPathComponent("New Effect.vst3")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        let folderWindow = try await openFolders()
        await catalog.addDirectories([firstFolder, secondFolder])
        await fixture.settle()
        let callsWhileOpen = await probe.calls.count
        try diagnosticRequire(callsWhileOpen == callsBeforeFolders, "Folder changes scanned before the panel closed")
        await closeFolders(folderWindow)
        try await DeveloperSelfTests.waitForPluginScan(catalog)
        let callsAfterClose = await probe.calls.count
        try diagnosticRequire(callsAfterClose == callsBeforeFolders + 1 && catalog.plugins.contains { $0.name == "New Effect" },
            "Closing changed folders did not discover their plug-ins exactly once")
        let unchangedWindow = try await openFolders()
        await closeFolders(unchangedWindow)
        let callsWithoutChanges = await probe.calls.count
        try diagnosticRequire(callsWithoutChanges == callsAfterClose, "Closing unchanged folders triggered a redundant scan")
        // NSOpenPanel may dismiss the popover before it returns its selected URLs.
        let lateSelectionWindow = try await openFolders()
        await closeFolders(lateSelectionWindow)
        await catalog.addDirectories([box.directory.appendingPathComponent("Late Selection")])
        await fixture.settle()
        try await DeveloperSelfTests.waitForPluginScan(catalog)
        await catalog.addDirectories([firstFolder])
        await fixture.settle()
        let callsAfterSelection = await probe.calls.count
        try diagnosticRequire(callsAfterSelection == callsAfterClose + 1, "A late or duplicate folder selection did not scan exactly once")
        print("PLUI: Changed folders scan once on close, unchanged folders do not rescan, and late file-panel selections scan once")
    }

    private struct PluginSectionFixture: View {
        let state: AppState
        @ObservedObject var store: ProfileStore
        var body: some View {
            ScrollView { PluginRackView(state: state, profile: Binding(get: { store.profiles[0] }, set: { store.update($0) })).padding(16) }
        }
    }
    @MainActor
    private final class PluginDragInfo: NSObject, NSDraggingInfo {
        var draggingDestinationWindow: NSWindow?
        var draggingSourceOperationMask: NSDragOperation = .move
        var draggingLocation = NSPoint.zero
        var draggedImageLocation = NSPoint.zero
        nonisolated var draggedImage: NSImage? { nil }
        let draggingPasteboard = NSPasteboard.withUniqueName()
        let draggingSource: Any?
        var draggingSequenceNumber = 1
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        var springLoadingHighlight: NSSpringLoadingHighlight = .none
        init(source: PluginRackDragSource.SourceView) {
            draggingSource = source
            super.init()
            let item = NSPasteboardItem()
            item.setString(source.slotID.uuidString, forType: PluginRackDragSource.pasteboardType)
            draggingPasteboard.writeObjects([item])
        }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func resetSpringLoading() {}
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
            classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    }

    private final class PluginMenuProbe { var menu: NSMenu? }
}
#endif

private final class PluginInstrumentDeliveryFixture: PluginAudioProcessor, @unchecked Sendable {
    var channelCount: Int { 2 }
    var latencyFrames: Int { 0 }
    var tailFrames: Int { 0 }
    var requiresContinuousRendering: Bool { true }
    func process(_ samples: inout [Float], sampleRate: Double, reset: Bool) -> Bool {
        for index in samples.indices { samples[index] += 0.1 }
        return true
    }
}
