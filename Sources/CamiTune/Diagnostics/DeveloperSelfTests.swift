import CamiTuneAudio
import CamiTuneDomain
import Foundation

/// Only measurements that depend on this computer belong in the app.
/// Deterministic regression tests and their fixtures live in the ignored Tests folder.
@MainActor
enum DeveloperSelfTests {
    static func cases() -> [DiagnosticCase] {
        [DiagnosticCase(id: "V08", suite: "Performance Measurement", name: "Tracing OFF/ON PCM and overhead baseline", safety: .simulated) {
            let workspace = try DiagnosticWorkspace()
            defer { workspace.cleanUp() }
            return try await performanceBenchmark(workspace)
        }, DiagnosticCase(id: "M36", suite: "Timeline Mixer", name: "Mixer performance on this computer", safety: .simulated) {
            try await mixerBenchmark()
        }]
    }

    private static func benchmarkEnvironment(queue: PCMQueueSnapshot) -> PerformanceEnvironment {
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return .init(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unavailable",
            configuration: configuration, macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture, activeApplications: 1, windowVisible: false, profileVisible: false,
            telemetryHealth: "Synthetic benchmark", queue: queue, recoveries: 0, droppedFrames: 0,
            transportDroppedFrames: 0, processCPUSeconds: RuntimePerformanceRecorder.cpuSeconds())
    }

    private static func mixerBenchmark() async throws -> DiagnosticObservation {
        let scenarios = [("Stereo, one client", 2, 1), ("Stereo, three clients", 2, 3),
                         ("Eight channels, three clients", 8, 3), ("32 channels, three clients", 32, 3)]
        var evidence: [DiagnosticEvidence] = []
        for (name, channels, clients) in scenarios {
            let mixer = PerAppTimelineMixer(storagePolicy: .init(maximumPacketFrames: 65_536))
            let samples = [Float](repeating: 0.125, count: 512 * channels)
            var durations: [Double] = []
            for cycle in 0..<80 {
                try Task.checkCancellation()
                for client in 0..<clients {
                    let packet = PerAppTimelinePacket(deviceObjectID: 100,
                        cycleCounter: UInt64(cycle), startSampleTime: Int64(cycle * 512), frameCount: 512,
                        channelCount: channels, sampleRate: 48_000,
                        channelLayout: LPCMChannelLayout(coreAudioTag: 0, channelCount: channels)!,
                        playbackMode: PlaybackMode.allCases[client % PlaybackMode.allCases.count])
                    let start = PerformanceClock.now()
                    _ = samples.withUnsafeBufferPointer {
                        mixer.mixProcessedPacket(mixer.preparePacket(packet), samples: $0,
                            policyNow: .init(rawValue: UInt64(cycle) * 512 * 1_000_000_000 / 48_000))
                    }
                    if cycle >= 10 { durations.append(PerformanceClock.milliseconds(start, PerformanceClock.now())) }
                }
                await Task.yield()
            }
            let distribution = LatencyDistribution(durations)
            evidence.append(.init(name: name,
                value: String(format: "Median %.3f ms · p99 %.3f ms · maximum %.3f ms", distribution.medianMilliseconds,
                    distribution.p99Milliseconds, distribution.maximumMilliseconds)))
        }
        return .init(summary: "Mixer timings measured for four workloads", evidence: evidence,
            details: "Synthetic PCM on this computer; first ten cycles excluded as warm-up. Results depend on build configuration and system load.")
    }

    private static func packet(_ client: UInt32 = 1, _ start: Double = 0, _ frames: Int = 4, _ value: Float = 0.25,
                               rate: Double = 48_000, channels: Int = 2) -> PerAppAudioPacket {
        PerAppAudioPacket(deviceObjectID: 100, clientID: client, processID: 0,
                         cycleCounter: UInt64(max(0, start / 4)), sampleTime: start,
                         interleaved: Array(repeating: value, count: frames * channels),
                         channelCount: channels, sampleRate: rate)
    }
    private static func traceIdentity(_ capture: AudioLatencyCapture, session: UUID, start: Int64 = 0,
                                      frames: Int = 512, epoch: UInt64 = 1) -> AudioTraceIdentity {
        .init(captureID: capture.id, runtimeSessionID: session, transportGeneration: 7, streamEpoch: epoch,
              deviceObjectID: 100, startSampleTime: start, frameCount: frames, sampleRate: 48_000, channelCount: 2)
    }
    private static func performanceBenchmark(_ box: DiagnosticWorkspace) async throws -> DiagnosticObservation {
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
            let profile = DeviceProfile(name: "Benchmark", outputDeviceUID: "benchmark.file", outputDeviceName: "File sink")
            await router.start(camillaSink: sink,
                renderConfiguration: RenderConfiguration(profile: profile, revision: .init(profileID: profile.id, generation: 0)),
                // File sinks have no playback clock; use queue-based rate matching for this measurement.
                deliveryConfiguration: .init(queue: .init(sampleRate: 48_000, operatingTargetFrames: 1920,
                    recoveryTargetFrames: 0, hardLimitFrames: 4800, recoveryStrategy: .clearAll,
                    rateTargetMode: .legacyBlockTarget), camillaQueueLimit: 4), backendChunkFrames: 1)
            var environment = benchmarkEnvironment(queue: router.statistics.camillaQueue)
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
            && baseline.samples.allSatisfy { $0.packetReceived != nil && $0.identity.runtimeSessionID == baseline.environment.sessionID },
            "Trace coverage or session identity incomplete: \(baseline.telemetryDrops) drops, \(baseline.packets.count)/48 packets, \(baseline.samples.count) writes")
        try diagnosticRequire(!baseline.samples.isEmpty && baseline.samples.allSatisfy { $0.rateMatch != nil },
            "Writer rate evidence missing from detailed tracing")
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
