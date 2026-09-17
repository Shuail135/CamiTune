import Foundation

@MainActor
enum DeveloperSelfTests {
    static func cases() -> [DiagnosticCase] {
        profileCases() + planningCases() + pcmCases() + lifecycleCases() + healthCases() + performanceCases() + presentationCases() + runtimePlanCases() + runtimePlanDifferCases() + runtimeCoordinatorCases()
    }

    private static func test(_ id: String, _ suite: String, _ name: String,
                             _ body: @escaping @MainActor (DiagnosticSandbox) async throws -> DiagnosticObservation) -> DiagnosticCase {
        DiagnosticCase(id: id, suite: suite, name: name, safety: .simulated) {
            let sandbox = try DiagnosticSandbox()
            defer { sandbox.cleanUp() }
            return try await body(sandbox)
        }
    }

    private static func profileCases() -> [DiagnosticCase] {
        [
            test("P01", "Profiles", "Profile persistence round trip") { box in
                let profile = DiagnosticSandbox.profile()
                box.profiles.profiles = [profile]
                box.profiles.flushPendingSaveSynchronously()
                let restored = ProfileStore(storageURL: box.directory.appendingPathComponent("profiles.json"), userDefaults: box.defaults)
                try diagnosticRequire(restored.profiles == [profile], "Profile fields changed during persistence")
                return .init(summary: "All profile fields survived save and reload")
            },
            test("P02", "Profiles", "Legacy document migration") { box in
                let profile = DiagnosticSandbox.profile()
                let url = box.directory.appendingPathComponent("legacy.json")
                try JSONEncoder().encode([profile]).write(to: url)
                let restored = ProfileStore(storageURL: url, userDefaults: box.defaults)
                try diagnosticRequire(restored.profiles.first?.id == profile.id, "Legacy array was not loaded")
                restored.profiles[0].name = "Migrated fixture"
                restored.flushPendingSaveSynchronously()
                let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
                try diagnosticRequire(document?["schemaVersion"] != nil, "Legacy document did not save in the current schema")
                return .init(summary: "Legacy array migrated and saved as a versioned document")
            },
            test("P03", "Profiles", "Future schema protection") { box in
                let url = box.directory.appendingPathComponent("future.json")
                let bytes = Data(#"{"schemaVersion":2147483647,"profiles":[]}"#.utf8)
                try bytes.write(to: url)
                let restored = ProfileStore(storageURL: url, userDefaults: box.defaults)
                try diagnosticRequire(restored.persistenceError != nil, "Future schema did not report an error")
                restored.profiles = [DiagnosticSandbox.profile()]
                restored.flushPendingSaveSynchronously()
                let after = try Data(contentsOf: url)
                try diagnosticRequire(after == bytes, "Future schema storage was overwritten")
                return .init(summary: "Unsupported storage remained byte-for-byte unchanged")
            }
        ]
    }

    private static func planningCases() -> [DiagnosticCase] {
        [
            test("P04", "Planning & Configuration", "Stereo graph construction") { _ in
                let profile = DiagnosticSandbox.profile()
                let graph = try ActiveAudioRoute(profile: profile).buildGraph(profile: profile)
                try graph.validate()
                try diagnosticRequire(graph.inputFormat.channelCount == 2 && graph.outputFormat.channelCount == 2, "Unexpected stereo formats")
                return .init(summary: "Stereo graph validates", evidence: [.init(name: "Stages", value: "\(graph.pipeline.count)")])
            },
            test("P05", "Planning & Configuration", "Multichannel runtime plan") { _ in
                var profile = DiagnosticSandbox.profile()
                let hardware = DiagnosticHardware(channels: 6)
                profile.endpointKind = .speakers
                profile.speakerTopology = try SpeakerLayoutGeometry.acceptingDefaultRoles(hardware.topology(for: profile.outputDeviceUID, sampleRate: 48_000).speakerTopology)
                let plan = try AudioRuntimePlanPreparer.prepare(profile: profile, hardware: hardware)
                let route = try ActiveAudioRoute(profile: profile)
                try diagnosticRequire(plan.sourceFormat == route.sourceFormat && plan.dspInputFormat == route.dspInputFormat, "Plan source/DSP formats differ from the current route")
                try diagnosticRequire(plan.hardwareOutputFormat.channelCount == 6 && plan.physicalEndpointFormat.channelCount == 6, "Expected six physical channels")
                try diagnosticRequire(plan.profileRoutingDescriptor.uid == ProfileRoutingDescriptor.uid(for: profile.id), "Routing identity changed")
                let fingerprint = try hardware.topology(for: profile.outputDeviceUID, sampleRate: 48_000).fingerprint
                try diagnosticRequire(plan.hardwareFingerprint == fingerprint, "Hardware fingerprint mismatch")
                try plan.processingGraph.validate()
                return .init(summary: "All plan formats, routing identity, fingerprint, and graph verified")
            },
            test("P06", "Planning & Configuration", "Hardware channel mismatch") { _ in
                do {
                    _ = try AudioRuntimePlanPreparer.prepare(profile: DiagnosticSandbox.profile(), hardware: DiagnosticHardware(channels: 6))
                } catch SpeakerTopologyError.hardwareLayoutChanged {
                    return .init(summary: "Mismatched channel count rejected")
                }
                throw DiagnosticFailure(message: "Expected hardware layout mismatch")
            },
            test("P07", "Planning & Configuration", "Malformed processing input") { _ in
                var profile = DiagnosticSandbox.profile()
                profile.equalizerAPOText = "Filter 1: ON PK Fc invalid Hz Gain broken dB Q nope"
                do { _ = try ActiveAudioRoute(profile: profile).buildGraph(profile: profile) }
                catch { return .init(summary: "Malformed processing was rejected") }
                throw DiagnosticFailure(message: "Malformed EQ unexpectedly produced a graph")
            },
            test("P08", "Planning & Configuration", "Headroom invariants") { _ in
                let profile = DiagnosticSandbox.profile()
                let first = try ActiveAudioRoute(profile: profile).buildGraph(profile: profile)
                let second = try ActiveAudioRoute(profile: profile).buildGraph(profile: profile)
                try diagnosticRequire(first.automaticHeadroomDB.isFinite && first.automaticHeadroomDB <= 0 && first.automaticHeadroomDB >= -120, "Headroom outside the legal range")
                try diagnosticRequire(first.automaticHeadroomDB == second.automaticHeadroomDB, "Headroom is not deterministic")
                var disabled = profile
                disabled.processing.global.stages.append(.init(isEnabled: false, processor: .gain(.init(gainDB: 30))))
                let ignored = try ActiveAudioRoute(profile: disabled).buildGraph(profile: disabled)
                try diagnosticRequire(first.automaticHeadroomDB == ignored.automaticHeadroomDB, "Disabled gain affected headroom")
                return .init(summary: "Finite, bounded, repeatable headroom; disabled gain ignored")
            },
            test("P09", "Planning & Configuration", "Graph update behavior") { _ in
                let profile = DiagnosticSandbox.profile()
                let graph = try ActiveAudioRoute(profile: profile).buildGraph(profile: profile)
                let differ = ProcessingGraphDiffer()
                try diagnosticRequire(differ.update(from: graph, to: graph) == .unchanged, "Identical graph is not unchanged")
                var next = graph
                next.sampleRate = 96_000
                try diagnosticRequire(differ.update(from: graph, to: next) == .replaceConfiguration, "Format change did not require replacement")
                if let index = next.processors.firstIndex(where: { if case .gain = $0.implementation { return true }; return false }) {
                    next = graph
                    next.processors[index].implementation = .gain(db: -3)
                    guard case .patch = differ.update(from: graph, to: next) else { throw DiagnosticFailure(message: "Gain change did not use a patch") }
                } else { throw DiagnosticFailure(message: "Fixture lacks a gain processor") }
                return .init(summary: "Unchanged, gain patch, and full replacement paths verified")
            }
        ]
    }

    private static let instant = Date(timeIntervalSince1970: 1_000)
    private static func packet(_ client: UInt32 = 1, _ start: Double = 0, _ frames: Int = 4, _ value: Float = 0.25,
                               rate: Double = 48_000, channels: Int = 2) -> PerAppAudioPacket {
        PerAppAudioPacket(deviceObjectID: 100, clientID: client, processID: 0,
                         cycleCounter: UInt64(max(0, start / 4)), sampleTime: start,
                         interleaved: Array(repeating: value, count: frames * channels),
                         channelCount: channels, sampleRate: rate, sourceBufferedFrames: frames, sourceCapacityFrames: 65_536)
    }
    private static func flush(_ controller: PerAppAudioController) throws -> PCMFrame {
        guard case .flushed(let frame) = controller.flushExpiredMix(now: instant.addingTimeInterval(1)) else {
            throw DiagnosticFailure(message: "Expected pending audio to flush")
        }
        return frame
    }
    private static func samples(_ actual: [Float], _ expected: [Float]) throws {
        try diagnosticRequire(actual.count == expected.count && zip(actual, expected).allSatisfy { abs($0 - $1) < 0.0001 }, "PCM samples or frame count differ from the expected timeline")
    }

    private static func pcmCases() -> [DiagnosticCase] {
        [
            test("A01", "PCM / Timeline", "One client") { box in
                _ = box.perApp.ingest(packet(), now: instant)
                try samples(flush(box.perApp).interleaved, Array(repeating: 0.25, count: 8))
                return .init(summary: "Single-client samples preserved")
            },
            test("A02", "PCM / Timeline", "Two clients, same interval") { box in
                _ = box.perApp.ingest(packet(1), now: instant)
                _ = box.perApp.ingest(packet(2), now: instant)
                try samples(flush(box.perApp).interleaved, Array(repeating: 0.5, count: 8))
                return .init(summary: "Coincident intervals summed")
            },
            test("A03", "PCM / Timeline", "Overlapping intervals") { box in
                _ = box.perApp.ingest(packet(1, 0), now: instant)
                _ = box.perApp.ingest(packet(2, 2), now: instant)
                try samples(flush(box.perApp).interleaved, [0.25, 0.25, 0.25, 0.25, 0.5, 0.5, 0.5, 0.5, 0.25, 0.25, 0.25, 0.25])
                return .init(summary: "Overlap summed; both non-overlapping tails preserved")
            },
            test("A04", "PCM / Timeline", "Unequal packet sizes") { box in
                let first = box.perApp.ingest(packet(1, 0, 256), now: instant)
                let second = box.perApp.ingest(packet(2, 0, 1024), now: instant)
                try diagnosticRequire(first == nil && second == nil, "Current holdback policy changed")
                try samples(flush(box.perApp).interleaved, Array(repeating: 0.5, count: 512) + Array(repeating: 0.25, count: 1536))
                return .init(summary: "256/1024-frame packets retain holdback and mix correctly")
            },
            test("A05", "PCM / Timeline", "Late packet") { box in
                _ = box.perApp.ingest(packet(1, 400, 4, 1), now: instant)
                _ = box.perApp.ingest(packet(1, 404, 4, 0), now: instant)
                _ = box.perApp.ingest(packet(2, 400, 4, 2), now: instant)
                let emitted = box.perApp.ingest(packet(1, 408, 4, 0), now: instant)
                try samples(emitted?.interleaved ?? [], Array(repeating: 3, count: 8))
                let late = box.perApp.ingest(packet(2, 400, 4, 4), now: instant)
                try diagnosticRequire(late == nil, "Already emitted audio was replayed")
                _ = box.perApp.ingest(packet(2, 402, 4, 4), now: instant)
                let next = box.perApp.ingest(packet(1, 412, 4, 0), now: instant)
                try samples(next?.interleaved ?? [], [4, 4, 4, 4, 0, 0, 0, 0])
                return .init(summary: "Stale audio rejected; only the unrendered suffix of a partially late packet retained")
            },
            test("A06", "PCM / Timeline", "Short sound idle flush") { box in
                _ = box.perApp.ingest(packet(), now: instant)
                guard case .retryAfter = box.perApp.flushExpiredMix(now: instant.addingTimeInterval(0.003)) else {
                    throw DiagnosticFailure(message: "Tail flushed before its deadline")
                }
                guard case .flushed(let frame) = box.perApp.flushExpiredMix(now: instant.addingTimeInterval(0.020)) else {
                    throw DiagnosticFailure(message: "Short sound tail was lost")
                }
                try samples(frame.interleaved, Array(repeating: 0.25, count: 8))
                return .init(summary: "Tail emitted after an explicit 20 ms advance; no sleep")
            },
            test("A07", "PCM / Timeline", "Format change") { box in
                _ = box.perApp.ingest(packet(), now: instant)
                _ = box.perApp.ingest(packet(1, 0, 4, 0.5, rate: 96_000, channels: 1), now: instant)
                let frame = try flush(box.perApp)
                try diagnosticRequire(frame.sampleRate == 96_000 && frame.channelCount == 1, "New format did not replace pending timeline")
                try samples(frame.interleaved, Array(repeating: 0.5, count: 4))
                return .init(summary: "Rate/channel/layout change reset pending audio")
            },
            test("A08", "PCM / Timeline", "Runtime reset") { box in
                _ = box.perApp.ingest(packet(), now: instant)
                box.perApp.resetRuntime()
                guard case .idle = box.perApp.flushExpiredMix(now: instant.addingTimeInterval(1)) else {
                    throw DiagnosticFailure(message: "Old pending audio survived reset")
                }
                _ = box.perApp.ingest(packet(1, 0, 4, 0.5), now: instant)
                try samples(flush(box.perApp).interleaved, Array(repeating: 0.5, count: 8))
                return .init(summary: "Reset discarded prior stream and accepted a fresh timeline")
            }
        ]
    }

    private static func lifecycleCases() -> [DiagnosticCase] {
        func lifecycle(_ id: String, _ name: String, scenario: DiagnosticRuntimeFakes.Scenario = .init(),
                       body: @escaping @MainActor (AppState, DiagnosticRuntimeFakes, DeviceProfile) async throws -> Void) -> DiagnosticCase {
            test(id, "Runtime Lifecycle", name) { box in
                let fake = DiagnosticRuntimeFakes(scenario)
                let profile = DiagnosticSandbox.profile()
                box.profiles.profiles = [profile]
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                do {
                    try await body(state, fake, profile)
                    if state.isActive { await state.deactivate() }
                    try fake.assertStopped(state)
                } catch {
                    await state.deactivate()
                    throw DiagnosticFailure(message: "\(error.localizedDescription)\nEvents: \(fake.events.joined(separator: " → "))")
                }
                return .init(summary: "Production lifecycle assertions passed", evidence: fake.evidence)
            }
        }
        return [
            lifecycle("L01", "Normal activation") { state, fake, profile in
                await state.activate(profile: profile)
                try diagnosticRequire(state.isActive && state.activeSession?.profileID == profile.id, "Activation did not publish its session")
                for resource in ["engine", "volume", "PCM", "transport", "observations", "spectrum"] {
                    try diagnosticRequire(fake.events.filter { $0 == "start \(resource)" }.count == 1, "Expected one start for \(resource)")
                }
            },
            lifecycle("L02", "Missing physical output", scenario: .init(outputPresent: false)) { state, fake, profile in
                await state.activate(profile: profile)
                try diagnosticRequire(!state.isActive && !fake.events.contains("start engine") && fake.transportAttempts == 0, "Missing output reached pipeline startup")
            },
            lifecycle("L03", "Graph failure rollback", scenario: .init(graphFails: true)) { state, fake, profile in
                await state.activate(profile: profile)
                try diagnosticRequire(!state.isActive && fake.events.contains("start engine") && fake.events.contains("apply graph"), "Graph failure scenario did not run")
            },
            lifecycle("L04", "Stop during activation — never acknowledged") { state, fake, profile in
                let gate = DiagnosticManualGate()
                fake.scenario.routingGate = gate
                async let activation: Void = state.activate(profile: profile)
                do {
                    try await gate.waitUntilEntered()
                    try diagnosticRequire(state.transitionInProgress, "Activation was not suspended")
                    await state.deactivate()
                    try diagnosticRequire(state.transitionInProgress, "Suspended activation lost its transition context")
                    gate.release()
                    await activation
                    // The worker cleans the superseded provisional attempt.
                    try await fake.stopped.enter()
                    try diagnosticRequire(!fake.events.contains("notify activation"), "Superseded activation was acknowledged")
                } catch {
                    gate.cancel()
                    await activation
                    throw error
                }
            },
            lifecycle("L05", "Transport retries", scenario: .init(transportResults: [false, false, true])) { state, fake, profile in
                await state.activate(profile: profile)
                try diagnosticRequire(state.isActive && fake.transportAttempts == 3, "Expected activation after exactly three attempts")
            },
            lifecycle("L06", "Transport retry exhaustion", scenario: .init(transportResults: [false, false, false])) { state, fake, profile in
                await state.activate(profile: profile)
                try diagnosticRequire(!state.isActive && fake.transportAttempts == 3, "Expected rollback after three failures")
            },
            lifecycle("L07", "Output restoration failure", scenario: .init(restoreFails: true)) { state, _, profile in
                await state.activate(profile: profile)
                try diagnosticRequire(state.isActive, "Fixture failed to activate")
                await state.deactivate()
                try diagnosticRequire(state.errorMessage?.contains("could not switch back") == true, "Restoration failure was not reported")
            },
            lifecycle("L08", "Physical device disappearance") { state, fake, profile in
                await state.activate(profile: profile)
                try diagnosticRequire(state.isActive, "Fixture failed to activate")
                fake.scenario.outputPresent = false
                await state.monitorRouting()
                try diagnosticRequire(!state.isActive, "Removed output left runtime active")
            },
            test("L09", "Runtime Lifecycle", "Delayed old-session observation") { _ in
                let monitor = AudioRuntimeMonitor()
                let profileID = UUID()
                let a = AudioRuntimeSession(profileID: profileID)
                let b = AudioRuntimeSession(profileID: profileID)
                monitor.setPresentationActive(true, profileID: profileID)
                monitor.start(controller: nil, session: a, routeDiagnosticsProvider: { AudioRouteDiagnostics() })
                monitor.stop()
                monitor.start(controller: nil, session: b, routeDiagnosticsProvider: { AudioRouteDiagnostics() })
                let snapshot = PCMLevelSnapshot(peak: [0, 0], rms: [-3, -3], clippedSamples: 7, clippedSamplesByChannel: [4, 3])
                monitor.ingest(snapshot, session: a)
                try diagnosticRequire(monitor.activeSession == b && monitor.status.sourceClippedSamples == 0, "Old session changed replacement observations")
                monitor.ingest(snapshot, session: b)
                try diagnosticRequire(monitor.status.sourceClippedSamples == 7, "Current session was not accepted")
                monitor.stop()
                return .init(summary: "Delayed A observation rejected; B observation accepted for the same profile")
            }
        ]
    }

    private static func healthCases() -> [DiagnosticCase] {
        let now = Date(timeIntervalSince1970: 2_000)
        let healthyDSP = CamillaDSPDiagnostics(engineState: "Running", stopReason: "None",
            processingLoadPercent: 10, resamplerLoadPercent: 0, bufferLevelFrames: 256,
            rateAdjustment: 1, clippedSamples: 0, lastGraphUpdate: nil, patchedFilterCount: 0)
        return [
            test("H01", "Runtime Health", "Paused telemetry is independent of audio health") { _ in
                var status = AudioRuntimeStatus(isActive: true, engineIsRunning: true)
                status.route.sampleRate = 48_000
                status.route.activeChannels = 2
                try diagnosticRequire(status.pipelineAssessment(at: now) == .init(reasons: []), "Paused polling degraded the audio pipeline")
                try diagnosticRequire(status.telemetryAssessment(at: now) == .init(reasons: [.telemetryPaused]), "Paused polling was not identified")
                try diagnosticRequire(SystemDiagnostics.pipelineObservation(status, at: now).status == .passed, "S09 falsely warned about missing telemetry")
                try diagnosticRequire(SystemDiagnostics.telemetryObservation(status, at: now).status == .skipped, "S10 did not skip intentional polling suspension")
                return .init(summary: "Clean audio passes; intentionally paused telemetry is skipped separately")
            },
            test("H02", "Runtime Health", "Pending and failed diagnostic RPC") { _ in
                var status = AudioRuntimeStatus(isActive: true, telemetryPollingActive: true)
                try diagnosticRequire(status.telemetryAssessment(at: now).reasons == [.telemetryPending], "Initial polling was not pending")
                status.recordTelemetryFailure("Simulated RPC failure", at: now)
                try diagnosticRequire(status.telemetryAssessment(at: now).reasons == [.telemetryRPCFailed("Simulated RPC failure")], "RPC failure lost its cause")
                try diagnosticRequire(status.pipelineAssessment(at: now).health == .healthy, "RPC failure became an audio fault")
                try diagnosticRequire(SystemDiagnostics.telemetryObservation(status, at: now).summary.contains("Simulated RPC failure"), "RPC failure was absent from report")
                return .init(summary: "RPC failure explains the telemetry warning without degrading clean delivery")
            },
            test("H03", "Runtime Health", "All pipeline reasons and fault precedence") { _ in
                var status = AudioRuntimeStatus(isActive: true, engineIsRunning: false, transportError: "Simulated transport failure",
                    clippingIsRecent: true, telemetryPollingActive: true)
                var diagnostic = healthyDSP
                diagnostic.engineState = "Stalled"; diagnostic.stopReason = "Capture error"; diagnostic.processingLoadPercent = 90
                status.recordTelemetry(diagnostic, at: now)
                status.route.sourceFormatError = "Simulated format error"
                status.route.bridgeDroppedFrames = 1; status.route.bridgeConsumerOverrunCount = 2
                status.route.bridgeClientRegistryOverflowCount = 3; status.route.bridgeClientUseCountSaturationCount = 4
                status.route.bridgeMalformedPacketCount = 5; status.route.camillaDroppedFrames = 6
                status.route.camillaQueueRecoveries = 7; status.route.camillaWriteFailures = 8; status.route.rejectedSourceFrames = 9
                let expected: [AudioRuntimeHealthReason] = [.engineUnavailable, .transportFailure("Simulated transport failure"),
                    .sourceFormatError("Simulated format error"), .engineStalled, .engineStopped("Capture error"),
                    .processingOverload(90), .recentClipping, .bridgeDroppedFrames(1), .bridgeOverruns(2),
                    .clientRegistryOverflows(3), .clientUseCountSaturations(4), .malformedPackets(5),
                    .pcmDroppedFrames(6), .pcmQueueRecoveries(7), .pcmWriteFailures(8), .rejectedSourceFrames(9)]
                let assessment = status.pipelineAssessment(at: now)
                try diagnosticRequire(assessment.health == .fault && assessment.reasons == expected, "Pipeline reasons were dropped or fault severity was masked")
                let report = SystemDiagnostics.pipelineObservation(status, at: now)
                try diagnosticRequire(report.status == .failed && expected.allSatisfy { report.summary.contains($0.summary) }, "Report omitted a pipeline cause")
                try diagnosticRequire(status.telemetryAssessment(at: now).health == .healthy, "A reported DSP fault was confused with RPC availability")
                return .init(summary: "All observed causes retained; faults take precedence over warnings")
            },
            test("H04", "Runtime Health", "Stale DSP values do not become current audio faults") { _ in
                var status = AudioRuntimeStatus(isActive: true, telemetryPollingActive: true)
                var diagnostic = healthyDSP
                diagnostic.engineState = "Stalled"; diagnostic.stopReason = "Capture error"; diagnostic.processingLoadPercent = 95
                status.recordTelemetry(diagnostic, at: now)
                let later = now.addingTimeInterval(3)
                // Route refreshes must never refresh the DSP RPC timestamp.
                status.lastUpdated = later
                try diagnosticRequire(status.telemetryAssessment(at: later).reasons == [.telemetryStale], "Stale DSP observation appeared current")
                try diagnosticRequire(status.pipelineAssessment(at: later).health == .healthy, "Stale DSP state/load was treated as current")
                status.route.camillaWriteFailures = 1
                try diagnosticRequire(status.pipelineAssessment(at: later).reasons == [.pcmWriteFailures(1)], "Missing telemetry masked a PCM failure")
                return .init(summary: "DSP freshness uses its own timestamp; independent delivery faults remain visible")
            },
            test("H05", "Runtime Health", "Telemetry failure and recovery") { _ in
                var status = AudioRuntimeStatus(isActive: true, telemetryPollingActive: true)
                status.recordTelemetry(healthyDSP, at: now)
                status.recordTelemetryFailure("Simulated timeout", at: now.addingTimeInterval(1))
                try diagnosticRequire(status.hasFreshTelemetry(at: now.addingTimeInterval(1)), "Transient failure prematurely expired recent telemetry")
                status.recordTelemetryFailure("Simulated timeout", at: now.addingTimeInterval(3))
                try diagnosticRequire(!status.telemetryAvailable, "Expired telemetry remained available")
                try diagnosticRequire(status.telemetryAssessment(at: now.addingTimeInterval(3)).reasons == [.telemetryRPCFailed("Simulated timeout"), .telemetryStale], "Failure and stale evidence were not both retained")
                status.recordTelemetry(healthyDSP, at: now.addingTimeInterval(4))
                try diagnosticRequire(status.telemetryAssessment(at: now.addingTimeInterval(4)).health == .healthy && status.lastTelemetryError == nil, "Successful RPC did not clear telemetry failure")
                return .init(summary: "Transient error, expiration, and successful recovery are distinguished")
            },
            test("H06", "Runtime Health", "Monitor presentation does not own runtime activity") { _ in
                let monitor = AudioRuntimeMonitor()
                let session = AudioRuntimeSession(profileID: UUID())
                monitor.start(controller: nil, session: session, routeDiagnosticsProvider: { AudioRouteDiagnostics() })
                monitor.setPresentationActive(true, profileID: session.profileID)
                monitor.setPresentationActive(false, profileID: session.profileID)
                try diagnosticRequire(monitor.status.isActive && monitor.status.pipelineAssessment().health == .healthy, "Hiding the monitor marked the pipeline inactive or unhealthy")
                try diagnosticRequire(monitor.status.telemetryAssessment().reasons == [.telemetryPaused], "Hidden monitor did not report paused telemetry")
                monitor.stop()
                try diagnosticRequire(monitor.status.pipelineAssessment().reasons == [.runtimeInactive] && monitor.status.telemetryAssessment().reasons == [.runtimeInactive], "Stopped runtime retained active health")
                return .init(summary: "Presentation suspension preserves runtime activity; Stop clears both assessments")
            }
        ]
    }

}

extension DeveloperSelfTests {
    private static func traceIdentity(_ capture: AudioLatencyCapture, session: UUID, start: Int64 = 0,
                                      frames: Int = 512, epoch: UInt64 = 1) -> AudioTraceIdentity {
        .init(captureID: capture.id, runtimeSessionID: session, transportGeneration: 7, streamEpoch: epoch,
              deviceObjectID: 100, startSampleTime: start, frameCount: frames, sampleRate: 48_000, channelCount: 2)
    }
    private static func performanceCases() -> [DiagnosticCase] {
        [
            test("V01", "Performance Measurement", "Monotonic clock and percentile units") { _ in
                let a = PerformanceTick(rawValue: 1_000)
                try diagnosticRequire(PerformanceClock.milliseconds(a, a.advanced(seconds: 0.025)) == 25, "Incorrect monotonic conversion")
                try diagnosticRequire(PerformanceClock.duration(from: a, to: .init(rawValue: 0)) == 0, "Reversed ticks underflowed")
                let distribution = LatencyDistribution((1...100).map(Double.init) + [.nan, -.infinity, -1])
                try diagnosticRequire(distribution.sampleCount == 100 && distribution.medianMilliseconds == 50
                    && distribution.p95Milliseconds == 95 && distribution.p99Milliseconds == 99
                    && distribution.maximumMilliseconds == 100, "Percentile or invalid-value handling changed")
                let sizes = FrameSizeDistribution([1024, 256, 1024])
                try diagnosticRequire(sizes.minimumFrames == 256 && sizes.medianFrames == 1024, "Frame sizes lost their units")
                return .init(summary: "Monotonic durations, nearest-rank percentiles, and frame units verified")
            },
            test("V02", "Performance Measurement", "Bounded capture and warm-up exclusion") { _ in
                let start = PerformanceClock.now()
                let capture = AudioLatencyCapture(id: 1, start: start, deadline: start.advanced(seconds: 1), capacity: 2)
                let identity = traceIdentity(capture, session: UUID())
                let before = PerformanceTick(rawValue: start.rawValue - 1)
                capture.append(.packet(.init(identity: identity, received: before, processed: start)))
                for _ in 0..<5 { capture.append(.packet(.init(identity: identity, received: start, processed: start))) }
                try diagnosticRequire(capture.counts().packets == 2 && capture.telemetryDrops == 3, "Full storage changed the bounded/drop contract")
                capture.stop()
                capture.append(.packet(.init(identity: identity, received: start, processed: start)))
                try diagnosticRequire(capture.events().count == 2, "Stopped capture accepted a late observation")
                return .init(summary: "Warm-up excluded, full capture drops telemetry, stopped capture rejects late writes")
            },
            test("V03", "Performance Measurement", "Overlapping contributions and capture identity") { _ in
                let start = PerformanceClock.now()
                let capture = AudioLatencyCapture(id: 2, start: start, deadline: start.advanced(seconds: 60))
                let session = UUID()
                let identity = traceIdentity(capture, session: session, frames: 1024)
                var mix = MixPerformanceTrace(capture: capture, identity: identity, untracedUntil: 0, lastPolicyTick: start)
                for (offset, range) in [(0.0, 0..<1024), (0.002, 512..<1536), (0.004, 2048..<2304)] {
                    let receipt = start.advanced(seconds: offset)
                    let packet = PacketPerformanceContext(capture: capture, identity: identity, received: receipt)
                    mix.add(packet, processed: receipt.advanced(seconds: 0.001), start: Int64(range.lowerBound), end: Int64(range.upperBound), existingEnd: 0)
                }
                let first = mix.emit(start: 0, count: 256, eligible: start.advanced(seconds: 0.01), deadline: nil)
                let overlap = mix.emit(start: 256, count: 512, eligible: start.advanced(seconds: 0.01), deadline: nil)
                try diagnosticRequire(first?.contributingPackets == 1 && overlap?.contributingPackets == 2
                    && overlap?.lastPacketReceived == start.advanced(seconds: 0.002), "Unrelated or already emitted contribution joined the interval")
                let replacement = AudioLatencyCapture(id: 3, start: start, deadline: start.advanced(seconds: 60))
                let nextID = traceIdentity(replacement, session: UUID(), start: 2304, frames: 256)
                mix.add(.init(capture: replacement, identity: nextID, received: start), processed: start,
                        start: 2304, end: 2560, existingEnd: 2304)
                try diagnosticRequire(mix.emit(start: 768, count: 1536, eligible: start, deadline: nil) == nil, "Capture/session boundary joined old audio")
                let next = mix.emit(start: 2304, count: 256, eligible: start, deadline: nil)
                try diagnosticRequire(next?.identity == nextID, "Replacement capture failed to resume after old prefix")
                return .init(summary: "Partial prefixes, overlapping clients, unrelated tails, and capture/session replacement remain distinct")
            },
            test("V04", "Performance Measurement", "Timeline reset changes trace epoch") { box in
                let start = PerformanceClock.now()
                let capture = AudioLatencyCapture(id: 4, start: start, deadline: start.advanced(seconds: 60))
                let session = UUID()
                let identity = traceIdentity(capture, session: session, start: 10000, frames: 4)
                _ = box.perApp.ingest(packet(1, 10000), now: instant,
                    performance: .init(capture: capture, identity: identity, received: start))
                let old = try flush(box.perApp)
                _ = box.perApp.ingest(packet(), now: instant,
                    performance: .init(capture: capture, identity: traceIdentity(capture, session: session, frames: 4), received: start))
                let rewound = try flush(box.perApp)
                try diagnosticRequire(old.performanceTrace != nil && rewound.performanceTrace != nil
                    && old.performanceTrace?.identity.streamEpoch != rewound.performanceTrace?.identity.streamEpoch, "Timeline rewind retained its previous measurement epoch")
                box.perApp.resetRuntime()
                _ = box.perApp.ingest(packet(), now: instant,
                    performance: .init(capture: capture, identity: identity, received: start))
                let reset = try flush(box.perApp)
                try diagnosticRequire(reset.performanceTrace?.identity.streamEpoch != rewound.performanceTrace?.identity.streamEpoch, "Runtime reset retained its measurement epoch")
                capture.stop()
                for index in 1...3 {
                    let output = box.perApp.ingest(packet(1, Double(index * 4)), now: instant)
                    try diagnosticRequire(output?.performanceTrace == nil, "Stopped tracing remained attached to continuing audio")
                }
                return .init(summary: "Rewind and runtime reset prevent cross-stream latency joins")
            },
            test("V05", "Performance Measurement", "Queue observations preserve recovery policy") { _ in
                let start = PerformanceClock.now()
                let capture = AudioLatencyCapture(id: 5, start: start, deadline: start.advanced(seconds: 60), capacity: 1)
                let binding = PerformanceCaptureBinding(capture: capture, sessionID: UUID())
                var traced = LowLatencyPCMQueue(); var plain = LowLatencyPCMQueue()
                for count in [1024, 1024, 1024, 1024, 1024, 6000] {
                    let frame = PCMFrame(interleaved: Array(repeating: Float(0.1), count: count * 2), channelCount: 2, sampleRate: 48_000)
                    let off = plain.append(frame); let on = traced.append(frame, performance: binding)
                    try diagnosticRequire(off == on && plain.queuedFrames == traced.queuedFrames, "Tracing changed clear-on-overflow")
                    if count == 6000 {
                        try diagnosticRequire(traced.snapshot.capacityFrames == 6000 && traced.snapshot.lastRecoveryDroppedFrames == 1024, "Oversized-block capacity/recovery was reported incorrectly")
                    }
                }
                let rateChange = PCMFrame(interleaved: Array(repeating: Float(0.2), count: 1024), channelCount: 2, sampleRate: 96_000)
                try diagnosticRequire(traced.append(rateChange, performance: binding) == plain.append(rateChange), "Rate-change recovery changed")
                try diagnosticRequire(traced.snapshot.lastRecoverySampleRate == 48_000 && traced.snapshot.capacityFrames == 9600, "Recovery lost the dropped audio's sample rate")
                try samples(traced.removeFirst()!.interleaved, plain.removeFirst()!.interleaved)
                try diagnosticRequire(traced.snapshot.queuedFrames == 0 && traced.snapshot.latestBlockFrames == 512, "Dequeue snapshot is inaccurate")
                return .init(summary: "Tracing preserves overflow, rate-change clearing, oversized capacity, and delivered PCM")
            },
            test("V06", "Performance Measurement", "Production operation phases and hidden UI lifetime") { box in
                let fake = DiagnosticRuntimeFakes(.init(transportResults: [true, true]))
                let first = DiagnosticSandbox.profile(); var second = DiagnosticSandbox.profile(); second.name = "Second fixture"
                box.profiles.profiles = [first, second]
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                let recorder = state.performanceRecorder
                recorder.start(options: .init(duration: 30, warmUp: 0), environment: { state.performanceEnvironment() })
                do {
                    state.setMainWindowPresentationActive(false)
                    await state.activate(profile: first)
                    state.setEQDraft("Preamp: -1 dB", for: first.id)
                    state.setEQDraft("Preamp: -2 dB", for: first.id)
                    await state.apply(profile: try state.applyingSessionEQDrafts(to: first))
                    var draft = ProfileSettingsDraft(profile: first, activation: box.profiles.activationMode(for: first))
                    draft.sectionLayout = ProfileSectionLayout(hidden: [.meters])
                    try await state.saveProfileSettings(draft)
                    await state.activate(profile: second)
                    await state.deactivate()
                    try diagnosticRequire(recorder.isCapturing, "Hiding UI or stopping runtime cancelled the capture")
                    await recorder.stop()
                    guard let baseline = recorder.baseline else { throw DiagnosticFailure(message: "Missing operation baseline") }
                    for kind in ["Activation", "Deactivation", "Profile switch", "Live EQ apply", "Profile Save"] {
                        try diagnosticRequire(baseline.operations.contains { $0.kind == kind && $0.result == "success" }, "Missing successful \(kind) measurement")
                    }
                    try diagnosticRequire(baseline.operations.contains { $0.result == "coalesced" }, "Coalesced draft was counted as applied")
                    try diagnosticRequire(baseline.interactions["UI draft acceptance"]?.sampleCount == 2
                        && baseline.interactions["Live EQ runtime acknowledgement"]?.sampleCount == 1, "UI acceptance and runtime acknowledgement were not separated")
                    try diagnosticRequire(baseline.operations.contains { $0.kind == "Deactivation" && $0.parentID != nil }, "Profile switch lost its teardown child")
                    if let path = ProcessInfo.processInfo.environment["CAMITUNE_PERFORMANCE_BASELINE_PATH"] {
                        try baseline.json().write(to: URL(fileURLWithPath: path + ".operations.json"), options: .atomic)
                    }
                    let decoded = try JSONDecoder.performance.decode(PerformanceBaseline.self, from: baseline.json())
                    try diagnosticRequire(decoded.operations.count == baseline.operations.count && decoded.environment.outputUID == "<redacted>", "JSON round-trip/redaction failed")
                    try fake.assertStopped(state)
                    return .init(summary: "Actual lifecycle, EQ, and Save phases exported; coalescing and hidden capture lifetime preserved")
                } catch {
                    await state.deactivate(); await recorder.stop(); throw error
                }
            },
            test("V07", "Performance Measurement", "Cadence includes recovered blocks and scenario mismatch") { box in
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: DiagnosticRuntimeFakes().services())
                let start = PerformanceClock.now()
                let capture = AudioLatencyCapture(id: 7, start: start, deadline: start.advanced(seconds: 10))
                let id = traceIdentity(capture, session: UUID())
                for index in 0..<3 {
                    capture.append(.queue(.init(identity: id, timestamp: start.advanced(seconds: Double(index) * 0.01), isEntry: true,
                        queuedFrames: (index + 1) * 512, capacityFrames: 4800)))
                }
                capture.append(.recovery(.init(captureID: capture.id, runtimeSessionID: id.runtimeSessionID,
                    timestamp: start.advanced(seconds: 0.03), queuedFramesBeforeRecovery: 1536, incomingFrames: 4096,
                    droppedFrames: 1536, sampleRate: 48_000, writerBlockInProgressFrames: 0)))
                var scenario = PerformanceScenario(label: "Mixed sizes"); scenario.requiresMixedPacketSizes = true
                let baseline = PerformanceAggregator.build(capture: capture, startedAt: Date(), end: start.advanced(seconds: 0.04),
                    options: .init(scenario: scenario), environment: state.performanceEnvironment(), observations: [], operations: [], drops: 0, stopReason: "Fixture")
                try diagnosticRequire(baseline.audio["Input block cadence"]?.sampleCount == 2
                    && baseline.audio["Input block cadence"]?.medianMilliseconds == 10, "Recovered entries disappeared from cadence")
                try diagnosticRequire(baseline.samples.isEmpty && baseline.emittedSizes[512] == 3
                    && baseline.droppedFramesDuringCapture == 1536, "Queue observations require completed writes")
                try diagnosticRequire(baseline.scenarioMismatches.contains("Mixed packet sizes were not observed"), "Mismatched scenario was accepted")
                return .init(summary: "Queue cadence includes recovered entries; scenario mismatches remain explicit")
            },
            test("V08", "Performance Measurement", "Tracing OFF/ON PCM and overhead baseline") { box in
                try await performanceBenchmark(box)
            }
        ]
    }

    private static func performanceBenchmark(_ box: DiagnosticSandbox) async throws -> DiagnosticObservation {
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: DiagnosticRuntimeFakes().services())
        let template = state.performanceEnvironment()
        struct Run {
            let bytes: Data
            let statistics: PCMRouter.Statistics
            let cpu: Double
            let duration: Double
            let baseline: PerformanceBaseline?
        }
        func run(tracing: Bool) async throws -> Run {
            box.perApp.resetRuntime()
            let router = PCMRouter(); let session = UUID()
            router.performanceSource.setSession(session)
            let recorder = RuntimePerformanceRecorder(source: router.performanceSource)
            let url = box.directory.appendingPathComponent(tracing ? "traced.pcm" : "plain.pcm")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let sink = try FileHandle(forWritingTo: url)
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? sink.close(); try? reader.close() }
            await router.start(camillaSink: sink)
            var environment = template
            environment.sessionID = session; environment.sampleRate = 48_000; environment.channelCount = 2
            environment.playbackMode = PlaybackMode.direct.rawValue; environment.activeApplications = 1
            environment.outputName = "Synthetic file sink"; environment.outputUID = "fixture.file"
            if tracing {
                recorder.start(options: .init(duration: 30, warmUp: 0,
                    scenario: .init(label: "Synthetic isolated PCM; file sink; transport receipt simulated")), environment: {
                    var value = environment; let statistics = router.statistics
                    value.queue = statistics.camillaQueue; value.recoveries = statistics.camillaQueueRecoveries
                    value.droppedFrames = statistics.camillaDroppedFrames
                    value.processCPUSeconds = RuntimePerformanceRecorder.cpuSeconds()
                    return value
                })
            }
            let start = PerformanceClock.now(); let cpu = RuntimePerformanceRecorder.cpuSeconds()
            var outputBlocks = 0
            func routeAndWait(_ frame: PCMFrame) async throws {
                let before = try reader.seekToEnd()
                router.route(frame); outputBlocks += 1
                let limit = PerformanceClock.now().advanced(seconds: 2)
                while try reader.seekToEnd() == before {
                    try Task.checkCancellation()
                    guard PerformanceClock.now() < limit else { throw DiagnosticFailure(message: "Fixture writer made no progress") }
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
            do {
                for index in 0..<48 {
                    let source = packet(1, Double(index * 512), 512, Float(index % 8 + 1) / 64)
                    let binding = router.performanceSource.snapshot()
                    let context = binding.map { PacketPerformanceContext(capture: $0.capture,
                        identity: traceIdentity($0.capture, session: session, start: Int64(index * 512)), received: PerformanceClock.now()) }
                    if let frame = box.perApp.ingest(source, performance: context) { try await routeAndWait(frame) }
                    try await Task.sleep(for: .milliseconds(11))
                }
                try await Task.sleep(for: .milliseconds(20))
                if case .flushed(let frame) = box.perApp.flushExpiredMix() { try await routeAndWait(frame) }
                if tracing, let capture = router.performanceSource.snapshot()?.capture {
                    let limit = PerformanceClock.now().advanced(seconds: 2)
                    while capture.counts().audio < outputBlocks && PerformanceClock.now() < limit {
                        try await Task.sleep(for: .milliseconds(1))
                    }
                    try diagnosticRequire(capture.counts().audio == outputBlocks, "Writer failed to record a completed block")
                    await recorder.stop()
                }
                let duration = PerformanceClock.milliseconds(start, PerformanceClock.now()) / 1000
                let usedCPU = RuntimePerformanceRecorder.cpuSeconds() - cpu
                await router.stopWithoutBlockingUI()
                return Run(bytes: try Data(contentsOf: url), statistics: router.statistics, cpu: usedCPU,
                           duration: duration, baseline: recorder.baseline)
            } catch { await router.stopWithoutBlockingUI(); await recorder.stop(); throw error }
        }
        let off = try await run(tracing: false)
        let on = try await run(tracing: true)
        try diagnosticRequire(!off.bytes.isEmpty && off.bytes == on.bytes, "Tracing changed deterministic PCM output")
        try diagnosticRequire(off.statistics.camillaQueueRecoveries == 0 && on.statistics.camillaQueueRecoveries == 0
            && off.statistics.camillaDroppedFrames == 0 && on.statistics.camillaDroppedFrames == 0, "Isolated paced fixture recovered its queue")
        guard var baseline = on.baseline else { throw DiagnosticFailure(message: "Missing tracing baseline") }
        try diagnosticRequire(baseline.telemetryDrops == 0 && baseline.packets.count == 48
            && baseline.samples.allSatisfy { $0.packetReceived != nil && $0.identity.runtimeSessionID == baseline.environment.sessionID }, "Trace coverage or session identity incomplete")
        for name in ["Per-client processing", "Mixer policy wait", "Mixer emission work", "PCM queue residence",
                     "Rendering (including analysis/reset)", "Resampling/rate-match", "System master", "Payload preparation", "Pipe write", "Receipt → Camilla input"] {
            try diagnosticRequire(baseline.audio[name]?.sampleCount ?? 0 > 0, "Missing timing stage: \(name)")
        }
        baseline.overheadComparison = .init(workload: "48 × 512-frame packets at 48 kHz, 2 channels; file sink; simulated transport receipt; no hardware or CamillaDSP", identicalPCM: off.bytes == on.bytes,
            offRecoveries: off.statistics.camillaQueueRecoveries, onRecoveries: on.statistics.camillaQueueRecoveries,
            offQueuePeakFrames: off.statistics.camillaQueue.peakQueuedFrames, onQueuePeakFrames: on.statistics.camillaQueue.peakQueuedFrames,
            offDroppedFrames: off.statistics.camillaDroppedFrames, onDroppedFrames: on.statistics.camillaDroppedFrames,
            offCPUSeconds: off.cpu, onCPUSeconds: on.cpu, offDurationSeconds: off.duration, onDurationSeconds: on.duration,
            onWriterP99Milliseconds: baseline.audio["Writer execution"]?.p99Milliseconds ?? 0)
        let comparison = "Isolated identical PCM (\(on.bytes.count) bytes). OFF/ON: recoveries \(off.statistics.camillaQueueRecoveries)/\(on.statistics.camillaQueueRecoveries); queue peak \(off.statistics.camillaQueue.peakQueuedFrames)/\(on.statistics.camillaQueue.peakQueuedFrames) frames; CPU seconds \(off.cpu)/\(on.cpu); elapsed \(off.duration)/\(on.duration) s. ON writer p99 \(baseline.audio["Writer execution"]?.p99Milliseconds ?? 0) ms. OFF phase timing is intentionally unavailable. No bridge, CamillaDSP, or physical output was exercised."
        if let path = ProcessInfo.processInfo.environment["CAMITUNE_PERFORMANCE_BASELINE_PATH"] {
            try baseline.json().write(to: URL(fileURLWithPath: path), options: .atomic)
            try (baseline.report() + "\n\nTracing sanity check\n" + comparison).write(toFile: path + ".txt", atomically: true, encoding: .utf8)
        }
        return .init(summary: "Tracing preserves PCM; all stages captured without queue recovery or telemetry loss",
                     evidence: [.init(name: "OFF/ON sanity check", value: comparison)])
    }
}

private extension JSONDecoder {
    static var performance: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}
