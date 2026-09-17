import Foundation

extension DeveloperSelfTests {
    /// Explicit benchmark mode uses synthetic PCM and a file sink; never hardware.
    static func presentationBenchmarkCases() -> [DiagnosticCase] {
        [1, 2, 20].flatMap { count in [false, true].map { visible in
            DiagnosticCase(id: "B\(count)-\(visible ? "visible" : "hidden")", suite: "Presentation Benchmarks", name: "\(count) apps, UI \(visible ? "visible" : "hidden")", safety: .simulated) {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                let router = PCMRouter(); let session = UUID()
                router.performanceSource.setSession(session)
                let recorder = RuntimePerformanceRecorder(source: router.performanceSource, presentationSource: box.perApp.presentationPerformanceSource)
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: DiagnosticRuntimeFakes().services())
                let clients = (1...count).map { PerAppDriverClient(deviceObjectID: 100, clientID: UInt32($0),
                    processID: Int32(2_000_100_000 + $0), bundleID: "fixture.presentation.app\($0)", isActive: true, generation: 1) }
                box.perApp.updateClients(clients)
                await box.perApp.drainPresentationPreparation()
                box.perApp.setMeterPresentationActive(visible, source: "benchmark")
                await box.perApp.drainPresentationPreparation()
                let url = box.directory.appendingPathComponent("presentation.pcm")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let sink = try FileHandle(forWritingTo: url); defer { try? sink.close() }
                await router.start(camillaSink: sink)
                var environment = state.performanceEnvironment()
                environment.sessionID = session; environment.sampleRate = 48_000; environment.channelCount = 8
                environment.playbackMode = PlaybackMode.direct.rawValue; environment.activeApplications = count
                environment.windowVisible = visible; environment.profileVisible = visible
                environment.outputName = "Synthetic file sink (8-channel source → stereo writer)"; environment.outputUID = "fixture.file"
                recorder.start(options: .init(duration: 30, warmUp: 0,
                    scenario: .init(label: "Synthetic \(count) applications / 48 kHz / 8-channel source / Direct / UI \(visible ? "visible" : "hidden"); file sink, simulated receipt")), environment: {
                    var value = environment; let statistics = router.statistics
                    value.queue = statistics.camillaQueue; value.recoveries = statistics.camillaQueueRecoveries
                    value.droppedFrames = statistics.camillaDroppedFrames
                    value.presentationStatistics = box.perApp.presentationStatistics
                    value.processCPUSeconds = RuntimePerformanceRecorder.cpuSeconds()
                    return value
                })
                let ingestion = DispatchQueue(label: "CamiTune.SyntheticTransport")
                do {
                for cycle in 0..<64 {
                    await withCheckedContinuation { (completion: CheckedContinuation<Void, Never>) in
                        ingestion.async {
                            for client in clients {
                                let packet = PerAppAudioPacket(deviceObjectID: 100, clientID: client.clientID, processID: client.processID,
                                    cycleCounter: UInt64(cycle), sampleTime: Double(cycle * 512),
                                    interleaved: Array(repeating: Float(0.1 / Double(count)), count: 512 * 8), channelCount: 8,
                                    sampleRate: 48_000, sourceBufferedFrames: 512, sourceCapacityFrames: 65536)
                                let context = router.performanceSource.snapshot().map { binding in
                                    PacketPerformanceContext(capture: binding.capture,
                                        identity: .init(captureID: binding.capture.id, runtimeSessionID: session, transportGeneration: 1,
                                            streamEpoch: 0, deviceObjectID: 100, startSampleTime: Int64(cycle * 512), frameCount: 512,
                                            sampleRate: 48_000, channelCount: 8), received: PerformanceClock.now())
                                }
                                if let frame = box.perApp.ingest(packet, performance: context) { router.route(frame) }
                            }
                            completion.resume()
                        }
                    }
                    try await Task.sleep(for: .milliseconds(11))
                }
                try await Task.sleep(for: .milliseconds(120))
                await withCheckedContinuation { (completion: CheckedContinuation<Void, Never>) in
                    ingestion.async {
                        if case .flushed(let frame) = box.perApp.flushExpiredMix() { router.route(frame) }
                        completion.resume()
                    }
                }
                // Paced benchmark tail, not a race-selection test.
                try await Task.sleep(for: .milliseconds(120))
                await recorder.stop(); await router.stopWithoutBlockingUI()
                guard let baseline = recorder.baseline else { throw DiagnosticFailure(message: "Missing presentation baseline") }
                if let directory = ProcessInfo.processInfo.environment["CAMITUNE_STAGE3_BASELINE_DIRECTORY"] {
                    let name = "\(count)-apps-\(visible ? "visible" : "hidden")"
                    let path = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                    try baseline.json().write(to: path.appendingPathComponent(name + ".json"))
                    try baseline.report().write(to: path.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
                }
                try diagnosticRequire(!baseline.samples.isEmpty, "Synthetic capture has no completed writes")
                return .init(status: baseline.telemetryDrops == 0 ? .passed : .warning, summary: "\(baseline.telemetryDrops) timing observations dropped; \(baseline.packets.count) packets, \(baseline.samples.count) writes, \(baseline.presentation?.samples.count ?? 0) presentation observations")
                } catch {
                    await recorder.stop(); await router.stopWithoutBlockingUI(); throw error
                }
            }
        } }
    }
}

/// Test executor advances deadlines explicitly; no sleep decides publication races.
private final class ManualPresentationScheduler: @unchecked Sendable {
    private final class Timer: @unchecked Sendable {
        let deadline: PerformanceTick
        let job: PresentationPublicationScheduling.Job
        var cancelled = false
        init(_ deadline: PerformanceTick, _ job: @escaping PresentationPublicationScheduling.Job) { self.deadline = deadline; self.job = job }
    }
    var tick = PerformanceTick(rawValue: 1_000_000_000)
    var jobs: [PresentationPublicationScheduling.Job] = []
    var mainJobs: [PresentationPublicationScheduling.Job] = []
    private var timers: [Timer] = []
    private var onWorker = false
    var activeTimers: Int { timers.filter { !$0.cancelled }.count }
    var scheduling: PresentationPublicationScheduling {
        .init(now: { self.tick }, enqueue: { self.jobs.append($0) }, after: { delay, job in
            let timer = Timer(self.tick.advanced(seconds: delay), job); self.timers.append(timer)
            return { timer.cancelled = true }
        }, main: { self.mainJobs.append($0) }, assertWorker: { precondition(self.onWorker) })
    }
    func runWorker() {
        var count = 0
        while !jobs.isEmpty {
            precondition(count < 1000, "Unbounded drain loop"); count += 1
            let job = jobs.removeFirst(); onWorker = true; job(); onWorker = false
        }
    }
    func runMain() {
        let ready = mainJobs; mainJobs = []
        for job in ready { job() }
    }
    func advance(_ seconds: Double) {
        tick = tick.advanced(seconds: seconds)
        let ready = timers.filter { !$0.cancelled && $0.deadline <= tick }
        timers.removeAll { $0.cancelled || $0.deadline <= tick }
        jobs += ready.map(\.job); runWorker()
    }
    func settle() { runWorker(); runMain(); runWorker() }
}

private final class PresentationFixture: @unchecked Sendable {
    let scheduler = ManualPresentationScheduler()
    var input = PresentationFixture.input(revision: 1, level: 0.1)
    var delivered: [PerAppPresentationSnapshot] = []
    var observations: [AppPresentationObservation] = []
    lazy var publisher = PerAppPresentationPublisher(scheduling: scheduler.scheduling, performance: PerformanceTraceSource(),
        captureInput: { [weak self] in self?.input }, observeMetadata: { [weak self] in self?.observations += $0 },
        deliver: { [weak self] in self?.delivered.append($0) })
    static func input(revision: UInt64, level: Double, muted: Bool = false) -> PerAppPresentationInput {
        let identity = PerAppPresentationIdentity(id: "fixture.player", bundleID: "fixture.player", processID: 999999,
            displayName: "Player", isDockApplication: false, isAccessoryApplication: true)
        let client = PerAppDriverClient(clientID: 1, processID: identity.processID, bundleID: identity.id, isActive: true, generation: 1)
        var settings = PerAppAudioSettings(); settings.isMuted = muted
        return .init(revision: revision, clients: [client], identities: [client.transportKey: identity],
                     settings: [identity.id: settings], levels: [identity.id: level], observedAudioApplications: [identity.id])
    }
    func publish(_ request: ApplicationPublicationRequest = .immediate) { publisher.request(request); scheduler.settle() }
}

extension DeveloperSelfTests {
    static func presentationCases() -> [DiagnosticCase] {
        func check(_ id: String, _ name: String, _ body: @escaping @MainActor () async throws -> String) -> DiagnosticCase {
            DiagnosticCase(id: id, suite: "Presentation Publication", name: name, safety: .simulated) { .init(summary: try await body()) }
        }
        return [
            check("W01", "Packet bursts coalesce before construction") {
                let fixture = PresentationFixture(); let publisher = fixture.publisher
                _ = publisher.setActive(true, source: "test")
                for revision in 1...100 {
                    fixture.input = PresentationFixture.input(revision: UInt64(revision), level: Double(revision) / 100)
                    publisher.request(.meter)
                }
                try diagnosticRequire(fixture.scheduler.jobs.count == 1 && publisher.statistics.requests == 100
                    && publisher.statistics.coalescedRequests == 99, "Packet burst enqueued one job per request")
                fixture.scheduler.settle()
                try diagnosticRequire(fixture.delivered.count == 1 && fixture.delivered.first?.revision == 100
                    && fixture.delivered.first?.applications.first?.level == 1, "Burst did not build the latest state")
                try diagnosticRequire(publisher.statistics.maximumPendingDrains == 1, "More than one drain pending")
                return "100 invalidations → one worker drain and the latest row"
            },
            check("W02", "Blocked row construction cannot block PCM") {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                let entered = DiagnosticManualGate(); let release = DispatchSemaphore(value: 0)
                let once = PerformanceAtomic()
                let controller = PerAppAudioController(settingsURL: box.directory.appendingPathComponent("blocked.json"), monitorsRunningApplications: false,
                    presentationRowsBuilder: { input in
                        if once.exchange(1) == 0 {
                            Task { @MainActor in entered.release() }
                            release.wait()
                        }
                        return PerAppPresentationSnapshot.makeRows(input)
                    })
                defer { release.signal() }
                try await entered.enter()
                let frame = await Task.detached {
                    var output: PCMFrame?
                    for index in 0..<4 {
                        let packet = PerAppAudioPacket(deviceObjectID: 100, clientID: 1, processID: 0,
                            cycleCounter: UInt64(index), sampleTime: Double(index * 512),
                            interleaved: Array(repeating: Float(0.25), count: 1024), channelCount: 2,
                            sampleRate: 48_000, sourceBufferedFrames: 512, sourceCapacityFrames: 65536)
                        output = controller.ingest(packet) ?? output
                    }
                    return output
                }.value
                try diagnosticRequire(frame?.frameCount == 512 && frame?.interleaved.first == 0.25,
                    "PCM did not progress while the presentation builder was held")
                try diagnosticRequire(controller.presentationStatistics.snapshotsBuilt == 0,
                    "Builder gate was not held during ingestion")
                return "PCM and control-state access continued while the publication worker was blocked"
            },
            check("W03", "Trailing short sound survives becoming hidden") {
                let fixture = PresentationFixture(); _ = fixture.publisher.setActive(true, source: "test")
                fixture.publish(.meter)
                fixture.scheduler.advance(0.02)
                fixture.input = PresentationFixture.input(revision: 2, level: 0.8)
                fixture.publisher.request(.meter); fixture.scheduler.runWorker()
                try diagnosticRequire(fixture.scheduler.activeTimers == 1 && fixture.delivered.count == 1, "Throttle did not retain one trailing deadline")
                _ = fixture.publisher.setActive(false, source: "test")
                fixture.scheduler.advance(0.08); fixture.scheduler.runMain(); fixture.scheduler.runWorker()
                try diagnosticRequire(fixture.delivered.last?.applications.first?.level == 0.8
                    && fixture.publisher.statistics.trailingBuilds == 1, "Promised final meter value was lost when hidden")
                return "Final short-sound level delivered at the manual deadline even after hiding"
            },
            check("W04", "Hidden and suspended views suppress routine builds") {
                let fixture = PresentationFixture()
                for _ in 0..<100 { fixture.publisher.request(.meter) }
                try diagnosticRequire(fixture.scheduler.jobs.isEmpty, "Hidden packets created worker backlog")
                _ = fixture.publisher.setActive(true, source: "test"); _ = fixture.publisher.setSuspended(true, source: "test")
                fixture.publisher.request(.meter)
                try diagnosticRequire(fixture.scheduler.jobs.isEmpty, "Suspended view built routine rows")
                let resumed = fixture.publisher.setSuspended(false, source: "test")
                try diagnosticRequire(resumed, "Active presentation source did not resume")
                fixture.input = PresentationFixture.input(revision: 101, level: 0.7); fixture.publish()
                try diagnosticRequire(fixture.delivered.count == 1 && fixture.delivered[0].revision == 101, "Show did not publish the latest hidden state")
                return "Hidden/suspended packet updates schedule no routine work; resume publishes latest state"
            },
            check("W05", "Hidden discovery, stable controls, and registry gaps") {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                let controller = box.perApp
                let client = PerAppDriverClient(deviceObjectID: 100, clientID: 1, processID: 2_000_222_222,
                    bundleID: "fixture.hidden.player", isActive: true, generation: 1)
                controller.updateClients([client]); await controller.drainPresentationPreparation()
                controller.setVolume(0.4, for: "fixture.hidden.player")
                await controller.drainPresentationPreparation()
                let builds = controller.presentationStatistics.snapshotsBuilt
                _ = controller.ingest(PerAppAudioPacket(deviceObjectID: 100, clientID: 1, processID: client.processID,
                    cycleCounter: 1, sampleTime: 0, interleaved: Array(repeating: Float(0.5), count: 1024),
                    channelCount: 2, sampleRate: 48_000, sourceBufferedFrames: 512, sourceCapacityFrames: 65536))
                controller.flushPendingSaveSynchronously()
                try diagnosticRequire(controller.presentationStore.seenIDs.contains("fixture.hidden.player"), "Hidden audio discovery was not persisted")
                try diagnosticRequire(controller.presentationStatistics.snapshotsBuilt == builds, "Hidden packet built a row snapshot")
                controller.updateClients([]); await controller.drainPresentationPreparation()
                controller.setMeterPresentationActive(true, source: "test"); await controller.drainPresentationPreparation()
                try diagnosticRequire(controller.applications.first { $0.id == "fixture.hidden.player" }?.settings.volume == 0.4,
                    "Registry gap lost the packet-proven owner or its saved controls")
                return "Hidden audio learns persistent identity; registry gaps preserve the same row and controls"
            },
            check("W06", "Immediate settings outrank the meter deadline") {
                let fixture = PresentationFixture(); _ = fixture.publisher.setActive(true, source: "test")
                fixture.publish(.meter); fixture.scheduler.advance(0.02)
                fixture.publisher.request(.meter); fixture.scheduler.runWorker()
                fixture.scheduler.advance(0.01)
                fixture.input = PresentationFixture.input(revision: 3, level: 0.3, muted: true)
                fixture.publish()
                try diagnosticRequire(fixture.delivered.last?.applications.first?.settings.isMuted == true
                    && fixture.scheduler.tick.rawValue == 1_030_000_000, "Settings waited for the 100 ms throttle")
                let count = fixture.delivered.count
                fixture.scheduler.advance(0.1); fixture.scheduler.settle()
                try diagnosticRequire(fixture.delivered.count == count, "Superseded trailing work published again")
                return "Immediate controls publish at 30 ms and cancel the stale trailing deadline"
            },
            check("W07", "MainActor backlog delivers the newest revision only") {
                let fixture = PresentationFixture()
                for revision in 10...12 {
                    fixture.input = PresentationFixture.input(revision: UInt64(revision), level: Double(revision) / 20)
                    fixture.publisher.request(.immediate); fixture.scheduler.runWorker()
                }
                try diagnosticRequire(fixture.scheduler.mainJobs.count == 1 && fixture.delivered.isEmpty, "Unbounded MainActor backlog")
                fixture.scheduler.runMain(); fixture.scheduler.runWorker()
                try diagnosticRequire(fixture.delivered.map(\.revision) == [12], "MainActor delivered an obsolete snapshot")
                return "Three worker snapshots coalesce to revision 12 with one lock-free MainActor delivery"
            },
            check("W08", "Metadata is not persisted at meter cadence") {
                let fixture = PresentationFixture(); _ = fixture.publisher.setActive(true, source: "test")
                for revision in 1...10 {
                    fixture.input = PresentationFixture.input(revision: UInt64(revision), level: Double(revision) / 10)
                    fixture.publish(.meter); fixture.scheduler.advance(0.1)
                }
                try diagnosticRequire(fixture.observations.count == 1 && fixture.delivered.count == 10, "Unchanged metadata was repeatedly observed")
                let key = fixture.input.clients[0].transportKey
                fixture.input.identities[key]?.displayName = "Renamed Player"; fixture.publish()
                try diagnosticRequire(fixture.observations.count == 2 && fixture.observations.last?.systemDisplayName == "Renamed Player", "Changed metadata was lost")
                return "Ten meter snapshots submit metadata once; an actual identity change submits it again"
            },
            check("W09", "Reset cannot resurrect a stale meter snapshot") {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                let scheduler = ManualPresentationScheduler()
                let controller = PerAppAudioController(settingsURL: box.directory.appendingPathComponent("reset.json"), monitorsRunningApplications: false,
                    publicationScheduling: scheduler.scheduling)
                controller.updateClients([.init(deviceObjectID: 100, clientID: 1, processID: 2_000_333_333,
                    bundleID: "fixture.reset.player", isActive: true, generation: 1)])
                await controller.drainPresentationPreparation(); scheduler.settle()
                controller.setMeterPresentationActive(true, source: "test"); scheduler.settle()
                _ = controller.ingest(PerAppAudioPacket(deviceObjectID: 100, clientID: 1, processID: 2_000_333_333,
                    cycleCounter: 1, sampleTime: 0, interleaved: Array(repeating: Float(0.5), count: 1024),
                    channelCount: 2, sampleRate: 48_000, sourceBufferedFrames: 512, sourceCapacityFrames: 65536))
                scheduler.runWorker()
                controller.resetRuntime(); scheduler.settle()
                let revision = controller.applicationPublicationRevision
                scheduler.advance(0.2); scheduler.settle()
                try diagnosticRequire(controller.applications.allSatisfy { $0.level == 0 }
                    && controller.applicationPublicationRevision >= revision, "A pre-reset trailing snapshot resurrected the old meter")
                return "Reset forces cleared levels and supersedes the old trailing publication"
            },
            check("W10", "Shutdown cancels replaceable delivery, not accepted metadata") {
                let fixture = PresentationFixture()
                fixture.publisher.request(.immediate); fixture.scheduler.runWorker()
                fixture.publisher.shutdown(); fixture.scheduler.runMain(); fixture.scheduler.runWorker()
                fixture.publisher.request(.immediate); fixture.scheduler.advance(1); fixture.scheduler.settle()
                try diagnosticRequire(fixture.delivered.isEmpty && fixture.observations.count == 1
                    && fixture.scheduler.activeTimers == 0, "Shutdown delivered stale rows or discarded accepted metadata")
                return "Closed publisher rejects work and UI delivery; already submitted metadata remains accepted"
            },
            check("W11", "Pure builder preserves identity merge and filtering") {
                var input = PresentationFixture.input(revision: 1, level: 0.6)
                let source = PerAppObservedAudioSource(transportKey: input.clients[0].transportKey, processID: 999999,
                    applicationID: "fixture.player", identity: input.identities.values.first)
                input.clients = []; input.identities = [:]; input.observedAudioSources = [source]
                let gap = PerAppPresentationSnapshot.build(from: input)
                try diagnosticRequire(gap.applications.map(\.id) == ["fixture.player"] && gap.applications[0].level == 0.6, "Packet evidence required a live registry entry")
                input.runningApplications["fixture.idle"] = .init(id: "fixture.idle", bundleID: "fixture.idle", processID: 42,
                    displayName: "Idle", isDockApplication: true, isAccessoryApplication: false)
                try diagnosticRequire(PerAppPresentationSnapshot.build(from: input).applications.count == 1, "An idle Workspace app became audio-proven")
                input.observedAudioSources = []; input.runningApplications = [:]
                let temporary = PerAppPresentationIdentity(id: "pid:123", processID: 123, displayName: "Temporary",
                    isDockApplication: false, isAccessoryApplication: true)
                let client = PerAppDriverClient(clientID: 3, processID: 123, isActive: true, generation: 1)
                input.clients = [client]; input.identities = [client.transportKey: temporary]; input.observedAudioApplications = [temporary.id]
                try diagnosticRequire(PerAppPresentationSnapshot.build(from: input).applications.isEmpty, "Temporary identity bypassed retry exhaustion")
                input.exhaustedClientKeys = [client.transportKey]
                try diagnosticRequire(PerAppPresentationSnapshot.build(from: input).applications.map(\.id) == ["pid:123"], "Exhausted temporary identity disappeared")
                return "Packet evidence, idle-owner filtering, and ephemeral retry rules match existing behavior"
            }
        ]
    }
}
