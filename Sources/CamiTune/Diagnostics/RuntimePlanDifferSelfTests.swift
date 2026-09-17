import Foundation

extension DeveloperSelfTests {
    static func runtimePlanDifferCases() -> [DiagnosticCase] {
        func pure(_ id: String, _ name: String,
                  _ body: @escaping @MainActor () throws -> Void) -> DiagnosticCase {
            .init(id: id, suite: "Runtime Plan Differ", name: name, safety: .simulated) {
                try body(); return .init(summary: name)
            }
        }
        func pair(_ edit: (inout DeviceProfile) -> Void) throws -> (AudioRuntimePlan, AudioRuntimePlan) {
            let a = diffProfile(); var b = a; edit(&b)
            return (try diffPlan(a), try diffPlan(b, generation: 2))
        }
        func delta(_ edit: (inout DeviceProfile) -> Void) throws -> RuntimePlanDelta {
            let (a, b) = try pair(edit); return RuntimePlanDiffer().delta(from: a, to: b)
        }
        func patch(_ value: RuntimePlanDelta) throws {
            guard case .runtimePatch(let ids) = value.graph, !ids.isEmpty else { throw DiagnosticFailure(message: value.summary) }
            try diagnosticRequire(!value.requirements.usesExistingRestartPath, "Patch restarted the pipeline")
        }
        return [
            pure("D01", "Revision and preparation timestamp alone are no-op") {
                let profile = diffProfile(), a = try diffPlan(profile), b = try diffPlan(profile, generation: 2)
                let d = RuntimePlanDiffer().delta(from: a, to: b)
                try diagnosticRequire(d.isNoOp && d.isAcousticallyEquivalent && d.fromRevision != d.toRevision, d.summary)
                try diagnosticRequire(d == RuntimePlanDiffer().delta(from: a, to: b), "Differ is not deterministic")
            },
            pure("D02", "Profile rename publishes metadata without audio work") {
                let d = try delta { $0.name = "Renamed fixture" }
                try diagnosticRequire(d.disruptionLevel == .metadataOnly && d.graph == .unchanged
                    && !d.renderer.changed && d.isAcousticallyEquivalent && !d.isNoOp, d.summary)
            },
            pure("D03", "Graph title and channel labels are not backend topology") {
                let a = try diffPlan(diffProfile()).processingGraph; var b = a
                b.title = "Display only"
                b.inputFormat = .init(sampleRate: b.sampleRate, channels: b.inputFormat.channels.map {
                    .init(id: $0.id, role: $0.role, label: "Display label", kind: $0.kind, physicalOutputID: $0.physicalOutputID)
                })
                try diagnosticRequire(ProcessingGraphDiffer().update(from: a, to: b) == .unchanged, "Graph metadata replaced configuration")
                guard let index = b.processors.firstIndex(where: {
                    if case .gain = $0.implementation { return true }; return false
                }) else { throw DiagnosticFailure(message: "Missing fixture gain") }
                b.processors[index].implementation = .crossfeedGain(db: 0, muted: true, maximumBoostDB: 0)
                try diagnosticRequire(ProcessingGraphDiffer().update(from: a, to: b) == .replaceConfiguration,
                    "Different implementation kinds sharing the Camilla Gain type used an unsafe merge patch")
            },
            pure("D04", "EQ coefficients with stable identities use a patch") { try patch(delta { changeDiffEQ(&$0) }) },
            pure("D05", "EQ patch includes automatic headroom") {
                let d = try delta { changeDiffEQ(&$0, gain: 9) }
                try patch(d)
                guard case .runtimePatch(let ids) = d.graph else { return }
                try diagnosticRequire(ids.contains(ProcessingGraph.automaticHeadroomProcessorID), "Automatic headroom was omitted")
            },
            pure("D06", "Removing an active filter replaces graph without restart") {
                let d = try delta { $0.processing.global.stages.removeAll() }
                try diagnosticRequire(d.graph == .replaceConfiguration && d.disruptionLevel == .inPlace, d.summary)
            },
            pure("D07", "Adding a limiter replaces graph without route handoff") {
                let d = try delta { $0.processing.global.stages.append(.init(processor: .limiter(.standard))) }
                try diagnosticRequire(d.graph == .replaceConfiguration && !d.requirements.usesExistingRestartPath, d.summary)
            },
            pure("D08", "Sample-rate change restarts the pipeline") {
                let d = try delta { $0.sampleRate = 96_000 }
                try diagnosticRequire(d.transport.sampleRateChanged && d.transport.dspInputFormatChanged
                    && d.physicalRoute.hardwareOutputFormatChanged && d.requirements.requiresFullRuntimeRestart, d.summary)
            },
            pure("D09", "Source layout change restarts transport and PCM") {
                var a = diffProfile(); a.endpointKind = .custom
                var b = a; b.endpointKind = .headphones
                let d = RuntimePlanDiffer().delta(from: try diffPlan(a), to: try diffPlan(b))
                try diagnosticRequire(d.transport.sourceChannelLayoutChanged && d.requirements.requiresTransportRestart
                    && d.requirements.requiresPCMRestart && d.requirements.requiresEndpointMetadataUpdate, d.summary)
            },
            pure("D10", "Output UID change requires volume-safe handoff") {
                let d = try delta { $0.outputDevice = .init(uid: "diagnostic.other", name: "Other output") }
                try diagnosticRequire(d.physicalRoute.outputDeviceUIDChanged && d.requirements.requiresVolumeSafeHandoff
                    && d.disruptionLevel == .routeHandoff, d.summary)
            },
            pure("D11", "Critical hardware evidence change requires safe transition") {
                var profile = diffProfile(); profile.endpointKind = .audioInterface
                profile.audioInterface = .init(deviceUID: profile.outputDeviceUID, hardwareChannelCount: 4,
                    outputChannels: [0, 1], connectedEndpoint: .headphones)
                let a = try diffPlan(profile)
                profile.audioInterface = .init(deviceUID: profile.outputDeviceUID, hardwareChannelCount: 6,
                    outputChannels: [0, 1], connectedEndpoint: .headphones)
                let d = RuntimePlanDiffer().delta(from: a, to: try diffPlan(profile))
                try diagnosticRequire(d.physicalRoute.hardwareFingerprintChanged && d.requirements.requiresFullRuntimeRestart, d.summary)
            },
            pure("D12", "Listener tuning is a renderer-only in-place edit") {
                let d = try delta { changeDiffListener(&$0) }
                try diagnosticRequire(d.renderer.listenerTuningChanged && d.graph == .unchanged
                    && d.disruptionLevel == .inPlace && !d.transport.changed && !d.physicalRoute.changed, d.summary)
            },
            pure("D13", "Graph patch and renderer update coexist") {
                let d = try delta { changeDiffEQ(&$0); changeDiffListener(&$0) }
                try patch(d); try diagnosticRequire(d.renderer.changed, d.summary)
            },
            pure("D14", "Graph replacement and playback update coexist") {
                let d = try delta { $0.processing.global.stages.removeAll(); $0.setPlaybackMode(.spatialRender) }
                try diagnosticRequire(d.graph == .replaceConfiguration && d.renderer.playbackModeChanged
                    && d.disruptionLevel == .inPlace, d.summary)
            },
            pure("D15", "Rename and graph patch preserve independent effects") {
                let d = try delta { $0.name = "Renamed EQ"; changeDiffEQ(&$0) }
                try patch(d); try diagnosticRequire(d.requirements.requiresEndpointMetadataUpdate && !d.renderer.changed, d.summary)
            },
            pure("D22", "Chunk size requires engine quiescence, not route handoff") {
                let d = try delta { $0.chunkSize = 512 }
                try diagnosticRequire(d.graph == .replaceConfiguration && d.requirements.requiresEngineQuiescence
                    && !d.requirements.requiresFullRuntimeRestart && !d.requirements.requiresVolumeSafeHandoff, d.summary)
            },
            pure("D23", "Stable routing UID with renamed endpoint is metadata-only") {
                let d = try delta { $0.name = "New endpoint display" }
                try diagnosticRequire(d.endpoint.displayNameChanged && !d.endpoint.uidChanged
                    && !d.endpoint.routingDescriptorChanged && d.disruptionLevel == .metadataOnly, d.summary)
            },
            pure("D24", "Activation policy and persistence fields are outside runtime diff") {
                let d = try delta {
                    $0.autoActivateWhenProfileDeviceSelected.toggle(); $0.isEnabled.toggle()
                    $0.sectionLayout = .init(hidden: [.meters]); $0.outputVolumeScalar = 0.2; $0.lockOutputVolume.toggle()
                }
                try diagnosticRequire(d.isNoOp, d.summary)
            }
        ] + runtimePlanDifferIntegrationCases()
    }

    @MainActor static func diffProfile() -> DeviceProfile {
        var profile = DiagnosticSandbox.profile(); profile.endpointKind = .headphones
        profile.replaceProcessing(.init(global: .init(stages: [
            .init(processor: .equalizer(.init(bands: [.init(kind: .peaking, frequency: 1_000, gain: 3, q: 1)])))
        ])))
        return profile
    }
    static func changeDiffEQ(_ profile: inout DeviceProfile, gain: Double = 4) {
        guard case .equalizer(var equalizer) = profile.processing.global.stages[0].processor else { return }
        equalizer.bands[0].gain = gain
        profile.processing.global.stages[0].processor = .equalizer(equalizer)
    }
    static func changeDiffListener(_ profile: inout DeviceProfile) {
        profile.spatialListenerProfile = .init(name: "Fixture listener", outputDeviceUID: profile.outputDeviceUID,
            savedAt: Date(timeIntervalSince1970: 0), position: .init(), tuning: .init(width: 0.1), completedComparisons: 4)
    }
    @MainActor static func diffPlan(_ profile: DeviceProfile, generation: UInt64 = 1) throws -> AudioRuntimePlan {
        let hardware = try DiagnosticHardware(channels: profile.configuredPhysicalChannelCount)
            .topology(for: profile.outputDeviceUID, sampleRate: Double(profile.sampleRate)).speakerTopology
        return try AudioRuntimePlanPreparer.prepare(profile: profile, detectedHardware: hardware,
            revision: .init(profileID: profile.id, generation: generation))
    }
    static func runtimePlanDifferIntegrationCases() -> [DiagnosticCase] {
        func check(_ id: String, _ name: String,
                   _ body: @escaping @MainActor (DiagnosticSandbox) async throws -> String) -> DiagnosticCase {
            .init(id: id, suite: "Runtime Plan Differ", name: name, safety: .simulated) {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                return .init(summary: try await body(box))
            }
        }
        return [
            check("D16", "System master controls bypass preparation and diff") { box in
                let fake = DiagnosticRuntimeFakes(), profile = diffProfile(); box.profiles.profiles = [profile]
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                await state.activate(profile: profile)
                let revision = state.candidatePlanRevision, events = fake.events
                state.pcmRouter.setSystemMaster(linearGain: 0.5, muted: false)
                state.pcmRouter.setSystemMaster(linearGain: 0.25, muted: true)
                let unchanged = state.candidatePlanRevision == revision && state.lastRuntimePlanDelta == nil && fake.events == events
                await state.deactivate()
                try diagnosticRequire(unchanged, "System master entered plan preparation/diff")
                return "Live system gain and mute do no global configuration work"
            },
            check("D17", "Per-app controls bypass preparation and diff") { box in
                let fake = DiagnosticRuntimeFakes(), profile = diffProfile(); box.profiles.profiles = [profile]
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                await state.activate(profile: profile)
                let revision = state.candidatePlanRevision, events = fake.events
                box.perApp.setVolume(0.6, for: "fixture.player"); box.perApp.setMuted(true, for: "fixture.player")
                let unchanged = state.candidatePlanRevision == revision && state.lastRuntimePlanDelta == nil && fake.events == events
                await state.deactivate()
                try diagnosticRequire(unchanged, "Per-app controls entered global plan preparation/diff")
                return "Per-app gain/mute retain their independent control path"
            },
            check("D18", "Acknowledged plan wins over newer persisted intent") { box in
                let fake = DiagnosticRuntimeFakes(), a = diffProfile(); box.profiles.profiles = [a]
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                await state.activate(profile: a)
                let oldRevision = state.acknowledgedPlanRevision
                var c = a; changeDiffEQ(&c); box.profiles.profiles = [c]
                await state.apply(profile: c)
                let d = state.lastRuntimePlanDelta
                let valid = d?.fromRevision == oldRevision && d?.requirements.requiresGraphUpdate == true && fake.graphs.count == 2
                await state.deactivate()
                try diagnosticRequire(valid, "Compared persisted C against C instead of acknowledged A against C")
                return "Persisted profile can run ahead; classification still starts at the acknowledged revision"
            },
            check("D19", "Backend patch fallback can acknowledge the candidate") { box in
                try await diffControllerCase(box, fallbackFails: false)
            },
            check("D20", "Failed patch and fallback preserve both acknowledgements") { box in
                try await diffControllerCase(box, fallbackFails: true)
            },
            check("D21", "No-op live apply and Save produce zero runtime work") { box in
                let fake = DiagnosticRuntimeFakes(), profile = diffProfile(); box.profiles.profiles = [profile]
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                await state.activate(profile: profile)
                let effects = diffEffects(fake), revision = state.acknowledgedPlanRevision
                await state.apply(profile: profile)
                var draft = ProfileSettingsDraft(profile: profile, activation: box.profiles.activationMode(for: profile))
                draft.sectionLayout = .init(hidden: [.meters])
                do {
                    try await state.saveProfileSettings(draft)
                    try diagnosticRequire(diffEffects(fake) == effects && state.acknowledgedPlanRevision == revision
                        && state.lastRuntimePlanDelta?.isNoOp == true, "No-op repeated backend/renderer/routing work")
                    await state.deactivate()
                    return "Equivalent plans skip RPCs, renderer setters, routing sync, and lifecycle changes"
                } catch { await state.deactivate(); throw error }
            },
            check("D25", "Editable-setting classification inventory") { _ in try diffEditableSettingAudit() },
            check("D26", "Save and live apply share metadata/renderer/graph classifications") { box in
                for edit in 0..<3 {
                    let fake = DiagnosticRuntimeFakes(), profile = diffProfile(); box.profiles.profiles = [profile]
                    let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                    await state.activate(profile: profile)
                    var candidate = profile
                    if edit == 0 { candidate.name = "Renamed endpoint" }
                    if edit == 1 { candidate.spatialSettings.cinema.amount = 0.7 }
                    if edit == 2 { candidate.processing.global.stages.append(.init(processor: .limiter(.standard))) }
                    let expected = RuntimePlanDiffer().delta(from: try diffPlan(profile), to: try diffPlan(candidate))
                    var draft = ProfileSettingsDraft(profile: profile, activation: box.profiles.activationMode(for: profile))
                    draft.name = candidate.name; draft.spatialSettings = candidate.spatialSettings; draft.processing = candidate.processing
                    do {
                        try await state.saveProfileSettings(draft)
                        try diagnosticRequire(state.lastRuntimePlanDelta?.requirements == expected.requirements,
                            "Save used a different policy from the pure/live differ")
                        try diagnosticRequire(fake.events.filter { $0 == "start PCM" }.count == 1
                            && fake.graphs.count == (edit == 2 ? 2 : 1)
                            && fake.renderConfigurations.count == (edit == 1 ? 2 : 1), "Unnecessary runtime effects")
                        await state.deactivate()
                    } catch { await state.deactivate(); throw error }
                }
                return "Rename publishes metadata, spatial edit sets renderer, structural EQ sends full graph; all stay in place"
            },
            check("D27", "Metadata failure rolls back without acknowledging candidate") { box in
                for settings in [false, true] {
                    let fake = DiagnosticRuntimeFakes(), profile = diffProfile(); box.profiles.profiles = [profile]
                    var failMetadata = false
                    var services = fake.services(); let sync = services.synchronizeRouting
                    services.synchronizeRouting = { profiles, active, visible, descriptors in
                        if failMetadata { failMetadata = false; throw fake.fail("Simulated metadata failure") }
                        try await sync(profiles, active, visible, descriptors)
                    }
                    let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: services)
                    await state.activate(profile: profile)
                    let revision = state.acknowledgedPlanRevision, graph = fake.graphs.last, render = fake.renderConfigurations.last
                    var candidate = profile; candidate.name = "Rename and edit"; changeDiffEQ(&candidate); changeDiffListener(&candidate)
                    failMetadata = true
                    if settings {
                        var draft = ProfileSettingsDraft(profile: profile, activation: box.profiles.activationMode(for: profile))
                        draft.name = candidate.name; draft.processing = candidate.processing
                        draft.spatialSettings.cinema.amount = 0.7
                        do { try await state.saveProfileSettings(draft); throw fake.fail("Expected metadata failure") }
                        catch { /* Assertions below distinguish rollback from accidental success. */ }
                    } else { await state.apply(profile: candidate) }
                    let restored = state.acknowledgedPlanRevision == revision && fake.graphs.last == graph
                        && fake.renderConfigurations.last == render && fake.graphs.count == 3 && state.isActive
                    await state.deactivate()
                    try diagnosticRequire(restored, "Partial effect failure advanced acknowledgement or failed rollback")
                }
                return "Both paths restore the exact graph/renderer/revision after endpoint publication fails"
            },
            check("D28", "Signal labels and physical renderer geometry are distinct") { _ in
                var a = diffProfile(); a.endpointKind = .speakers
                a.speakerTopology = try SpeakerLayoutGeometry.acceptingDefaultRoles(DiagnosticHardware().topology(
                    for: a.outputDeviceUID, sampleRate: 48_000).speakerTopology)
                let old = try diffPlan(a)
                var renamed = a; renamed.speakerTopology?.endpoints[0].displayName = "Left desk speaker"
                renamed.speakerTopology?.updatedAt = .distantFuture
                let names = RuntimePlanDiffer().delta(from: old, to: try diffPlan(renamed))
                try diagnosticRequire(names.isNoOp, "Cosmetic speaker label/timestamp changed signal identity: \(names.summary)")
                var moved = a; moved.speakerTopology?.endpoints[0].position = .init(azimuthDegrees: -25, elevationDegrees: 0, distanceMeters: 1.5)
                let geometry = RuntimePlanDiffer().delta(from: old, to: try diffPlan(moved))
                try diagnosticRequire(geometry.renderer.referenceTopologyChanged && geometry.requirements.requiresPCMRestart,
                    "Immutable physical renderer geometry was updated in place")
                return "Names/timestamps are ignored; changed construction-time geometry restarts PCM"
            },
            check("D29", "Prepared asset content participates in graph classification") { box in
                let source = box.directory.appendingPathComponent("source.wav")
                var bytes = runtimePlanImpulseWAV(); try bytes.write(to: source)
                let store = ImpulseResponseStore(directory: box.directory.appendingPathComponent("assets"))
                let asset = try store.importWAV(at: source, expectedSampleRate: 48_000)
                var profile = diffProfile()
                let hardware = try DiagnosticHardware().topology(for: profile.outputDeviceUID, sampleRate: 48_000).speakerTopology
                func prepare(_ profile: DeviceProfile) throws -> AudioRuntimePlan {
                    try AudioRuntimePlanPreparer.prepare(profile: profile, detectedHardware: hardware, assetDirectory: store.directory)
                }
                let plain = try prepare(profile)
                profile.processing.global.stages.append(.init(processor: .convolution(.init(asset: asset))))
                let original = try prepare(profile)
                let added = RuntimePlanDiffer().delta(from: plain, to: original)
                try diagnosticRequire(added.graph == .replaceConfiguration && !added.requirements.usesExistingRestartPath,
                    "Convolution stage addition restarted the route")
                // Same filename, valid WAV metadata, different impulse payload.
                bytes[46] = 0; bytes[47] = 0x3f
                try bytes.write(to: store.url(for: asset))
                let changed = RuntimePlanDiffer().delta(from: original, to: try prepare(profile))
                try diagnosticRequire(changed.graph == .replaceConfiguration && !changed.requirements.usesExistingRestartPath,
                    "Prepared content change was ignored because the path was unchanged")
                return "Convolution topology and same-path content changes independently request backend replacement"
            },
            check("D30", "Settings acknowledgement waits for endpoint publication") { box in
                let fake = DiagnosticRuntimeFakes(), profile = diffProfile(); box.profiles.profiles = [profile]
                let gate = DiagnosticManualGate(); var shouldWait = false
                var services = fake.services(); let sync = services.synchronizeRouting
                services.synchronizeRouting = { profiles, active, visible, descriptors in
                    if shouldWait { shouldWait = false; try await gate.enter() }
                    try await sync(profiles, active, visible, descriptors)
                }
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: services)
                await state.activate(profile: profile)
                let old = state.acknowledgedPlanRevision
                var changed = profile; changeDiffEQ(&changed)
                var draft = ProfileSettingsDraft(profile: profile, activation: box.profiles.activationMode(for: profile))
                draft.name = "Delayed metadata"; draft.processing = changed.processing; draft.spatialSettings.cinema.amount = 0.7
                shouldWait = true
                let save = Task { try await state.saveProfileSettings(draft) }
                do {
                    try await gate.waitUntilEntered()
                    try diagnosticRequire(fake.graphs.count == 2 && fake.renderConfigurations.count == 2
                        && state.acknowledgedPlanRevision == old && box.profiles.profiles[0].name == profile.name,
                        "Candidate acknowledged or persisted before remaining endpoint effect")
                    gate.release(); try await save.value
                    try diagnosticRequire(state.acknowledgedPlanRevision != old && box.profiles.profiles[0].name == draft.name,
                        "Successful transaction was not acknowledged")
                    await state.deactivate()
                    return "Graph and renderer can be accepted while the transaction acknowledgement waits for metadata/persistence"
                } catch { gate.release(); _ = try? await save.value; await state.deactivate(); throw error }
            },
            check("D31", "Inactive settings validate without inventing running hardware") { box in
                let fake = DiagnosticRuntimeFakes(.init(outputPresent: false)), profile = diffProfile()
                box.profiles.profiles = [profile]
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                var draft = ProfileSettingsDraft(profile: profile, activation: box.profiles.activationMode(for: profile))
                draft.name = "Disconnected profile"
                try await state.saveProfileSettings(draft)
                try diagnosticRequire(fake.graphs.isEmpty && fake.renderConfigurations.isEmpty && fake.resources.isEmpty
                    && state.acknowledgedPlanRevision == nil && state.lastRuntimePlanDelta == nil
                    && !fake.events.contains("resolve output"), "Inactive Save executed or compared a pretend active plan")
                return "Declared evidence validates disconnected storage; no runtime plan is acknowledged or diffed"
            },
            check("D32", "Quiescence uses the existing safe pipeline transition") { box in
                let fake = DiagnosticRuntimeFakes(.init(transportResults: [true, true])), profile = diffProfile()
                box.profiles.profiles = [profile]
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                await state.activate(profile: profile)
                var changed = profile; changed.chunkSize = 512
                await state.apply(profile: changed)
                let valid = state.isActive && state.lastRuntimePlanDelta?.disruptionLevel == .engineQuiescence
                    && fake.events.filter { $0 == "start PCM" }.count == 2 && fake.graphs.last?.chunkSize == 512
                await state.deactivate()
                try diagnosticRequire(valid, "Engine-global change was applied to a feeding PCM writer")
                return "Chunk-size classification stays distinct; Stage 5 conservatively executes it through stop/start"
            },
            check("D33", "Failed settings rollback retires the uncertain runtime") { box in
                let fake = DiagnosticRuntimeFakes(), profile = diffProfile(); box.profiles.profiles = [profile]
                var rejectMetadata = false
                var services = fake.services(); let sync = services.synchronizeRouting
                services.synchronizeRouting = { profiles, active, visible, descriptors in
                    if rejectMetadata && active != nil { throw fake.fail("Metadata publication rejected") }
                    try await sync(profiles, active, visible, descriptors)
                }
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: services)
                await state.activate(profile: profile)
                var changed = profile; changeDiffEQ(&changed)
                var draft = ProfileSettingsDraft(profile: profile, activation: box.profiles.activationMode(for: profile))
                draft.name = "Failed publication"; draft.processing = changed.processing
                rejectMetadata = true
                var failed = false
                do { try await state.saveProfileSettings(draft) } catch { failed = true }
                try diagnosticRequire(failed && !state.isActive && state.acknowledgedPlanRevision == nil && fake.resources.isEmpty,
                    "Failed rollback left an acknowledged plan over uncertain runtime effects")
                return "Failed candidate and rollback publication stop the pipeline and clear acknowledgement"
            }
        ]
    }

    @MainActor private static func diffEffects(_ fake: DiagnosticRuntimeFakes) -> [String] {
        fake.events.filter { $0 == "apply graph" || $0 == "apply renderer" || $0 == "synchronize routing"
            || $0.hasPrefix("start ") || $0.hasPrefix("stop ") || $0.hasPrefix("set rate") }
    }

    @MainActor private static func diffControllerCase(_ box: DiagnosticSandbox, fallbackFails: Bool) async throws -> String {
        var fullCount = 0, patchCount = 0
        let controller = CamillaDSPController(manager: CamillaDSPManager(), applyConfiguration: { _ in
            fullCount += 1
            if fallbackFails && fullCount > 1 { throw DiagnosticFailure(message: "Full configuration rejected") }
        }, applyPatch: { _ in patchCount += 1; throw DiagnosticFailure(message: "Patch rejected") })
        let fake = DiagnosticRuntimeFakes(), profile = diffProfile(); box.profiles.profiles = [profile]
        var services = fake.services()
        var recorder: RuntimePerformanceRecorder?
        services.applyGraph = { try await controller.applyGraph($0, performanceRecorder: recorder) }
        services.graphUpdateDescription = { controller.lastGraphUpdate?.rawValue }
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: services)
        await state.activate(profile: profile)
        let old = state.acknowledgedPlanRevision, oldGraph = controller.activeGraph
        recorder = state.performanceRecorder
        recorder?.start(options: .init(duration: 30, warmUp: 0), environment: { state.performanceEnvironment() })
        var candidate = profile; changeDiffEQ(&candidate)
        await state.apply(profile: candidate)
        await recorder?.stop()
        do {
            guard let baseline = recorder?.baseline else { throw fake.fail("Missing graph/diff performance capture") }
            try diagnosticRequire(baseline.operations.contains {
                $0.kind == "Graph diff" && $0.result == "success" && $0.phases.contains { $0.name == "classification: runtimePatch" }
            } && baseline.transitions["Graph diff: total"]?.sampleCount == 1
                && baseline.transitions["Plan diff: total"]?.sampleCount == 1, "Missing aggregated comparison measurements")
            if !fallbackFails, let path = ProcessInfo.processInfo.environment["CAMITUNE_PERFORMANCE_BASELINE_PATH"] {
                try baseline.json().write(to: URL(fileURLWithPath: path + ".backend.operations.json"), options: .atomic)
            }
            try diagnosticRequire(patchCount == 1 && fullCount == 2, "Controller did not attempt patch then full fallback")
            guard case .runtimePatch = state.lastRuntimePlanDelta?.graph else { throw fake.fail("Plan did not predict patch") }
            if fallbackFails {
                try diagnosticRequire(state.acknowledgedPlanRevision == old && controller.activeGraph == oldGraph,
                    "Failed backend operation advanced an acknowledged snapshot")
            } else {
                let expectedGraph = try diffPlan(candidate).processingGraph
                try diagnosticRequire(controller.lastGraphUpdate == .fullConfigurationFallback
                    && state.acknowledgedPlanRevision != old && controller.activeGraph == expectedGraph,
                    "Successful fallback was not acknowledged")
            }
            await state.deactivate()
            return fallbackFails ? "Application and controller retain A after patch/fallback rejection" : "Predicted patch, actual full fallback, candidate acknowledged after success"
        } catch { await state.deactivate(); throw error }
    }

    @MainActor private static func diffEditableSettingAudit() throws -> String {
        let base = diffProfile()
        let cases: [(String, (inout DeviceProfile) -> Void, RuntimeDisruptionLevel)] = [
            ("Profile name", { $0.name = "Renamed" }, .metadataOnly),
            ("Physical output", { $0.outputDevice = .init(uid: "other.output", name: "Other") }, .routeHandoff),
            ("Sample rate", { $0.sampleRate = 96_000 }, .pipelineRestart),
            ("Chunk size", { $0.chunkSize = 512 }, .engineQuiescence),
            ("Endpoint type affecting source format", { $0.endpointKind = .custom }, .pipelineRestart),
            ("Playback mode", { $0.setPlaybackMode(.spatialRender) }, .inPlace),
            ("Legacy spatial mode (effective mode comes from playback)", { $0.spatialRenderingMode = .spatialAudio }, .none),
            ("Spatial music amount", { $0.spatialSettings.music.amount = 0.2 }, .inPlace),
            ("Spatial cinema amount", { $0.spatialSettings.cinema.amount = 0.2 }, .inPlace),
            ("Spatial dialogue focus", { $0.spatialSettings.cinema.dialogueFocus = 0.2 }, .inPlace),
            ("Legacy spatial output (effective output comes from endpoint type)", { $0.spatialSettings.outputSelection = .speakers }, .none),
            ("Spatial content selection", { $0.spatialSettings.contentSelection = .music }, .inPlace),
            ("Content mode", { $0.spatialContentMode = .musicSafe }, .inPlace),
            ("Virtual surround", { $0.virtualSurroundLayout.upmixStereo.toggle() }, .inPlace),
            ("Listener tuning", { changeDiffListener(&$0) }, .inPlace),
            ("EQ gain", { changeDiffEQ(&$0) }, .inPlace),
            ("EQ frequency/Q", {
                if case .equalizer(var eq) = $0.processing.global.stages[0].processor {
                    eq.bands[0].frequency = 800; eq.bands[0].q = 1.5; $0.processing.global.stages[0].processor = .equalizer(eq)
                }
            }, .inPlace),
            ("Stage bypass", { $0.processing.global.stages[0].isEnabled = false }, .inPlace),
            ("Virtual speaker position", { $0.virtualSurroundLayout.positions[.left] = .init(x: -0.4, y: -0.6) }, .inPlace),
            ("Listening position", { $0.spatialSettings.seating = .init(outputDeviceUID: $0.outputDeviceUID, leftDistanceMeters: 1.1) }, .inPlace),
            ("Personal reference correction", {
                let response = FrequencyResponse(name: "Fixture", points: [.init(frequency: 20, magnitudeDB: 0), .init(frequency: 20_000, magnitudeDB: 0)])
                $0.setPersonalReferenceCorrection(.init(deviceName: "Fixture", policy: .recommended,
                    measurement: response, target: response, curve: .init(points: []), filters: [], preampDB: -1))
            }, .inPlace),
            ("Preamp", { $0.processing.global.stages.append(.init(processor: .gain(.init(gainDB: -2)))) }, .inPlace),
            ("Limiter", { $0.processing.global.stages.append(.init(processor: .limiter(.standard))) }, .inPlace),
            ("Per-channel processing", { $0.processing.channels[0].chain.stages.append(.init(processor: .gain(.init(gainDB: -2)))) }, .inPlace),
            ("Per-channel delay", { $0.processing.channels[0].chain.stages.append(.init(processor: .delay(.init(milliseconds: 2)))) }, .inPlace),
            ("Crossfeed", { $0.processing.global.stages.append(.init(processor: .crossfeed(.standard))) }, .inPlace),
            ("Section layout", { $0.sectionLayout = .init(hidden: [.meters]) }, .none),
            ("Activation policy", { $0.autoActivateWhenProfileDeviceSelected.toggle() }, .none),
            ("Profile enabled", { $0.isEnabled.toggle() }, .none),
            ("Legacy volume preference", { $0.outputVolumeScalar = 0.4; $0.lockOutputVolume.toggle() }, .none),
            ("Inactive endpoint mode", { $0.playbackModesByEndpoint[ProfileEndpointKind.speakers.rawValue] = .spatialRender }, .none)
        ]
        let old = try diffPlan(base)
        for (name, mutate, expected) in cases {
            var candidate = base; mutate(&candidate)
            let d = RuntimePlanDiffer().delta(from: old, to: try diffPlan(candidate))
            try diagnosticRequire(d.disruptionLevel == expected, "\(name): expected \(expected.description), got \(d.summary)")
        }
        var checked = cases.count
        func verify(_ name: String, _ original: DeviceProfile, _ expected: RuntimeDisruptionLevel,
                    _ mutate: (inout DeviceProfile) throws -> Void) throws {
            var candidate = original; try mutate(&candidate)
            let d = RuntimePlanDiffer().delta(from: try diffPlan(original), to: try diffPlan(candidate))
            try diagnosticRequire(d.disruptionLevel == expected, "\(name): expected \(expected.description), got \(d.summary)")
            checked += 1
        }
        var speakers = base; speakers.endpointKind = .speakers
        speakers.speakerTopology = try SpeakerLayoutGeometry.acceptingDefaultRoles(DiagnosticHardware().topology(
            for: base.outputDeviceUID, sampleRate: 48_000).speakerTopology)
        try verify("Speaker group processing", speakers, .inPlace) {
            var settings = ChannelProcessingSettings.identity; settings.gainDB = -2
            try $0.setGroupProcessing(id: .init(rawValue: "standard:front"), settings: settings)
        }
        try verify("Physical-channel processing", speakers, .inPlace) {
            try $0.setChannelProcessing(index: 0, role: .left, gainDB: -2, bands: [], delayMilliseconds: 1, limiterEnabled: true)
        }
        try verify("Speaker placement", speakers, .pipelineRestart) {
            $0.speakerTopology?.endpoints[0].position = .init(azimuthDegrees: -25, elevationDegrees: 0, distanceMeters: 1.5)
        }
        try verify("Speaker labels", speakers, .none) { $0.speakerTopology?.endpoints[0].displayName = "Desk Left" }
        try verify("Physical role assignment", speakers, .pipelineRestart) {
            $0.speakerTopology?.endpoints[0].role = .right; $0.speakerTopology?.endpoints[1].role = .left
        }
        try verify("Room correction", speakers, .inPlace) {
            var seat = SpatialSeatingCalibration(outputDeviceUID: $0.outputDeviceUID)
            seat.roomCorrectionBands = [.init(kind: .peaking, frequency: 500, gain: -3, q: 1)]
            $0.spatialSettings.seating = seat; $0.synchronizeListeningPositionCorrection()
        }
        try verify("Routing enable", speakers, .pipelineRestart) {
            $0.multichannel.routing.enabled = true
            $0.multichannel.routing.routes = $0.configuredSpeakerEndpoints.enumerated().map {
                .init(sourceChannel: $0.offset, destination: $0.element.id)
            }
        }
        var routed = speakers; routed.multichannel.routing.enabled = true
        routed.multichannel.routing.routes = routed.configuredSpeakerEndpoints.enumerated().map {
            .init(sourceChannel: $0.offset, destination: $0.element.id)
        }
        try verify("Routing matrix coefficients", routed, .inPlace) { $0.multichannel.routing.routes[0].gainDB = -3 }
        try verify("Routing source layout", routed, .pipelineRestart) { $0.multichannel.routing.sourceLayout = .sevenPointOne }
        var bass = speakers
        bass.speakerTopology = .init(deviceUID: base.outputDeviceUID, sampleRate: 48_000, declaredChannelCount: 6,
            endpoints: LPCMChannelLayout.fivePointOne.roles.enumerated().map {
                .init(id: .init(deviceUID: base.outputDeviceUID, channelIndex: $0.offset), role: $0.element,
                    displayName: $0.element.rawValue, connectionState: .confirmedByUser,
                    function: $0.element == .lowFrequencyEffects ? .subwoofer : .fullRange)
            })
        bass.multichannel.bass = bass.defaultBassManagement
        try verify("Bass management enable", bass, .pipelineRestart) { $0.multichannel.bass.enabled = true }
        bass.multichannel.bass.enabled = true
        try verify("Bass crossover", bass, .inPlace) { $0.multichannel.bass.groups[0].crossoverHz = 100 }
        try verify("LFE gain", bass, .inPlace) { $0.multichannel.bass.lfeGainDB = -3 }
        var active = speakers
        active.speakerTopology = .init(deviceUID: base.outputDeviceUID, sampleRate: 48_000, declaredChannelCount: 4,
            endpoints: (0..<4).map { index in
                .init(id: .init(deviceUID: base.outputDeviceUID, channelIndex: index), role: index < 2 ? .left : .right,
                    displayName: "Driver \(index)", connectionState: .confirmedByUser,
                    function: index % 2 == 0 ? .woofer : .tweeter)
            })
        active.multichannel.crossover.enabled = true
        active.multichannel.crossover.reviewedHardware = try .init(topology: active.speakerTopology!)
        for endpoint in active.configuredSpeakerEndpoints {
            let highPass: Double? = endpoint.function == .tweeter ? 2_000 : nil
            active.multichannel.crossover.endpoints.append(.init(endpointID: endpoint.id, highPassHz: highPass,
                lowPassHz: endpoint.function == .woofer ? 2_000 : nil))
            active.multichannel.crossover.protection[endpoint.id] = .init(requiredHighPassHz: highPass)
        }
        try verify("Active crossover lowpass", active, .inPlace) { $0.multichannel.crossover.endpoints[0].lowPassHz = 1_800 }
        try verify("Active crossover protected highpass", active, .inPlace) { $0.multichannel.crossover.endpoints[1].highPassHz = 2_200 }
        try verify("Active crossover slope", active, .inPlace) { $0.multichannel.crossover.endpoints[0].slope = .lr48 }
        var interface = base; interface.endpointKind = .audioInterface
        interface.audioInterface = .init(deviceUID: base.outputDeviceUID, hardwareChannelCount: 4,
            outputChannels: [0, 1], connectedEndpoint: .headphones)
        try verify("Interface endpoint mapping", interface, .pipelineRestart) { $0.audioInterface?.outputChannels = [2, 3] }
        try verify("Interface endpoint type", interface, .pipelineRestart) { $0.audioInterface?.connectedEndpoint = .custom }
        return "\(checked) editable-setting mutations matched the documented runtime or excluded classification"
    }
}
