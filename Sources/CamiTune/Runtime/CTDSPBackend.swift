import CamiTuneAudio
import CamiTuneDomain
import Foundation

/// Device effects remain in the app. The numerical writer only sees PCMOutputSink.
/// This boundary also permits lifecycle checks without opening physical hardware.
protocol CTDSPHardwareOutput: PCMOutputSink {
    func snapshot(readMeters: Bool) -> CoreAudioOutputTransport.Snapshot
    func stop()
}

extension CoreAudioOutputTransport: CTDSPHardwareOutput {}

/// One generation owns its partial output before preparation can suspend. The
/// acquisition/retirement barrier also covers synchronous quit and late results.
private final class CTDSPRuntime: @unchecked Sendable {
    struct Installed {
        let output: any CTDSPHardwareOutput
        let sink: CTDSPInputSink
        var graph: ProcessingGraph
        var inputClaimed = false
    }
    private enum State {
        case preparing
        case acquiredOutput(any CTDSPHardwareOutput)
        case installed(Installed)
        case stopped
    }
    private let initialGraph: ProcessingGraph
    private let lock = NSLock()
    private let retirementRequested = PerformanceAtomic()
    private var state = State.preparing

    init(graph: ProcessingGraph) { initialGraph = graph }
    deinit { stop() }

    var installed: Installed? {
        lock.withLock {
            if case .installed(let value) = state { return value }
            return nil
        }
    }

    func prepare(makeOutput: @Sendable (ProcessingGraph) throws -> any CTDSPHardwareOutput,
                 loadAssets: @escaping CTDSPInputSink.AssetLoader) throws {
        try lock.withLock {
            guard retirementRequested.acquired == 0, case .preparing = state else { throw CancellationError() }
        }
        do {
            // File reads, decoding and numerical allocation do not hold the
            // retirement barrier. The worker owns their late result, while
            // synchronous stop can seal this generation immediately.
            let retirement = retirementRequested
            let sink = try CTDSPInputSink(graph: initialGraph, loadAssets: loadAssets, checkCancellation: {
                guard retirement.acquired == 0 else { throw CancellationError() }
            }) {
                try lock.withLock {
                    guard retirementRequested.acquired == 0, case .preparing = state else { throw CancellationError() }
                    let output = try makeOutput(initialGraph)
                    // Own the acquired output before releasing the barrier,
                    // including the gap before the complete sink is adopted.
                    state = .acquiredOutput(output)
                    return output
                }
            }
            let adopted = lock.withLock { () -> Bool in
                guard retirementRequested.acquired == 0, case .acquiredOutput(let output) = state else { return false }
                state = .installed(.init(output: output, sink: sink, graph: initialGraph))
                return true
            }
            if !adopted { sink.cancel(); throw CancellationError() }
        } catch {
            stop()
            throw error
        }
    }

    func installGraph(_ graph: ProcessingGraph) async throws {
        guard let current = installed, retirementRequested.acquired == 0 else { throw CancellationError() }
        try await current.sink.installGraph(graph)
        try lock.withLock {
            guard retirementRequested.acquired == 0, case .installed(var value) = state,
                  value.sink === current.sink else { throw CancellationError() }
            // Prepared selection is authoritative even while source input is paused.
            // Actual rendered activation remains on the delivery writer.
            value.graph = graph
            state = .installed(value)
        }
    }

    func claimInput() throws -> any PCMOutputSink {
        try lock.withLock {
            guard retirementRequested.acquired == 0, case .installed(var value) = state,
                  !value.inputClaimed, !value.sink.isCancelled else { throw CancellationError() }
            value.inputClaimed = true
            state = .installed(value)
            return value.sink
        }
    }

    func cancelInput() { installed?.sink.cancel() }
    func requestRetirement() { retirementRequested.publish(1) }

    func stop() {
        requestRetirement()
        lock.withLock {
            switch state {
            case .installed(let value):
                value.sink.cancel()
                value.output.stop()
            case .acquiredOutput(let output): output.stop()
            case .preparing, .stopped: break
            }
            state = .stopped
        }
    }
}

/// Development slice: fixed gain/EQ/delay/mixing and finite FIR graphs, with their required limiter.
/// Construction is inert. AppState selects it from the saved DSP engine preference;
/// capture, editors, persistence, routing and meter admission keep their owners.
@MainActor
final class CTDSPBackend: AudioProcessingBackend {
    typealias OutputFactory = @Sendable (ProcessingGraph) throws -> any CTDSPHardwareOutput
    private let makeOutput: OutputFactory
    private let loadAssets: CTDSPInputSink.AssetLoader
    private let checkOutput: @Sendable (String) throws -> Void
    private var generation: UUID?
    private var runtime: CTDSPRuntime?
    private var clockTask: Task<Void, Never>?
    private(set) var graphUpdateDescription: String?
    var name: String { "ctDSP" }
    var isRunning: Bool { generation != nil }
    var activeGraph: ProcessingGraph? { runtime?.installed?.graph }

    init(makeOutput: @escaping OutputFactory = { try CTDSPBackend.makeHardwareOutput($0) },
         checkOutput: @escaping @Sendable (String) throws -> Void = { try CTDSPBackend.checkHardwareOutput($0) },
         loadAssets: @escaping CTDSPInputSink.AssetLoader = { graph, check in
             try NativeAssetLoader().load(graph: graph,
                 maximumCoefficients: PreparedNativeGraph.maximumTotalFIRCoefficients, checkCancellation: check)
         }) {
        self.makeOutput = makeOutput
        self.checkOutput = checkOutput
        self.loadAssets = loadAssets
    }

    func validateAvailability() throws {}

    func start() async throws {
        try Task.checkCancellation()
        if generation != nil { return }
        guard runtime == nil else { throw Failure("ctDSP output retirement is still in progress.") }
        generation = UUID()
    }

    func resetRuntime() { graphUpdateDescription = nil }

    func validateOutput(uid: String) async throws {
        let check = checkOutput
        try await Task.detached(priority: .userInitiated) { try check(uid) }.value
        try Task.checkCancellation()
    }

    func applyGraph(_ graph: ProcessingGraph, performanceRecorder: RuntimePerformanceRecorder?) async throws {
        try Task.checkCancellation()
        guard let generation else { throw CancellationError() }
        if let existing = runtime {
            guard let installed = existing.installed else { throw Failure("ctDSP graph preparation is already in progress.") }
            if !installed.sink.isCancelled {
                var current = installed.graph, requested = graph
                current.title = ""; requested.title = ""
                if current == requested {
                    graphUpdateDescription = "unchanged"
                    return
                }
                try await existing.installGraph(graph)
                guard self.generation == generation, runtime === existing else { throw CancellationError() }
                graphUpdateDescription = "selected"
                return
            }
            // PCM rebuild has cancelled the old writer. Its retained sink owns
            // numerical storage until it exits; a new writer gets fresh storage.
            await Task.detached(priority: .userInitiated) { existing.stop() }.value
            guard self.generation == generation, runtime === existing else { throw CancellationError() }
            runtime = nil
        }
        let prepared = CTDSPRuntime(graph: graph)
        runtime = prepared
        let factory = makeOutput
        let assets = loadAssets
        let operation = performanceRecorder?.begin("Prepare native graph", reason: "backend")
        do {
            try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try prepared.prepare(makeOutput: factory, loadAssets: assets)
                }.value
                try Task.checkCancellation()
                guard self.generation == generation, runtime === prepared else { throw CancellationError() }
            } onCancel: {
                prepared.requestRetirement()
            }
            // Prepared readiness precedes makeInputSink and the first PCM. This
            // acknowledges installation, never an invented rendered interval.
            graphUpdateDescription = "installed"
            operation?.finish("success")
        } catch {
            prepared.requestRetirement()
            await Task.detached(priority: .userInitiated) { prepared.stop() }.value
            if runtime === prepared { runtime = nil }
            operation?.finish(error is CancellationError ? "cancelled" : "failed")
            throw error
        }
    }

    func makeInputSink() throws -> any PCMOutputSink {
        guard generation != nil, let runtime else { throw CancellationError() }
        return try runtime.claimInput()
    }

    var playbackClock: AudioPlaybackClock? {
        guard let value = runtime?.installed?.output.snapshot(readMeters: false), let clock = value.clock else { return nil }
        return .init(epoch: clock.epoch, sampleTime: clock.sampleTime, hostTime: clock.hostTime,
            nominalRate: clock.nominalRate, timestampFlags: clock.timestampFlags,
            demandFrames: value.demandFrames, underrunFrames: value.underrunFrames,
            callbackFrames: value.callbackFrames, bufferedFrames: Int(value.bufferedFrames),
            renderEntryHostTime: value.renderEntryHostTime)
    }

    func fetchMeters() async throws -> SignalLevels {
        guard let installed = runtime?.installed else { throw CancellationError() }
        let value = installed.output.snapshot(readMeters: true)
        // Input metering is already supplied by the shared, presentation-gated
        // PCM observer. The backend contributes only the actual device output.
        return .init(capturePeak: [], captureRMS: [], playbackPeak: value.peak, playbackRMS: value.rms)
    }

    func fetchTelemetry() async throws -> AudioOutputTelemetry {
        guard let runtime, let installed = runtime.installed else { throw CancellationError() }
        let value = installed.output.snapshot(readMeters: false)
        return .init(backend: name, engineState: value.error == nil ? "Running" : "Stopped",
            stopReason: value.error ?? "None", processingLoadPercent: installed.sink.loadPercent,
            bufferLevelFrames: value.bufferedFrames, clippedSamples: value.clippedSamples,
            sampleRate: Double(installed.graph.sampleRate), blockFrames: value.callbackFrames,
            processingBufferFrames: 0, underrunFrames: value.underrunFrames)
    }

    func measureWork() async -> AudioBackendWork {
        guard let installed = runtime?.installed else { return .init() }
        let value = installed.output.snapshot(readMeters: false)
        return .init(loadPercent: installed.sink.loadPercent, clockEpoch: value.clock?.epoch, underrunFrames: value.underrunFrames)
    }

    func observePlaybackClock(session: UUID, consumer: @escaping @Sendable (AudioClockObservation) -> Void) {
        stopClockObservations()
        guard let runtime else { return }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.runtime === runtime, let output = runtime.installed?.output else { return }
                if let clock = output.snapshot(readMeters: false).clock { consumer(clock) }
                do { try await RuntimeClock.sleep(seconds: 0.5) } catch { return }
            }
        }
    }

    func stopClockObservations() { clockTask?.cancel(); clockTask = nil }
    func closeInputSynchronously() { runtime?.cancelInput() }
    func closeInput() async {
        let runtime = runtime
        await Task.detached(priority: .userInitiated) { runtime?.cancelInput() }.value
    }

    func stopSynchronously() {
        stopClockObservations()
        generation = nil
        runtime?.stop()
        runtime = nil
    }

    func stop() async {
        stopClockObservations()
        generation = nil
        let retiring = runtime
        retiring?.requestRetirement()
        await Task.detached(priority: .userInitiated) { retiring?.stop() }.value
        if runtime === retiring { runtime = nil }
    }

    private nonisolated static func checkHardwareOutput(_ uid: String) throws {
        guard CoreAudioService.deviceInfo(forUID: uid) != nil else { throw Failure("The ctDSP output device is unavailable.") }
    }

    private nonisolated static func makeHardwareOutput(_ graph: ProcessingGraph) throws -> any CTDSPHardwareOutput {
        guard let device = CoreAudioService.deviceInfo(forUID: graph.playback.deviceUID) else {
            throw Failure("The ctDSP output device is unavailable.")
        }
        let channels = try SpeakerTopologyProbe.outputChannelCount(objectID: device.objectID)
        guard channels == graph.outputFormat.channelCount else {
            throw Failure("The ctDSP graph does not match the output device's channel layout.")
        }
        return try CoreAudioOutputTransport(deviceID: device.objectID, sampleRate: Double(graph.sampleRate),
            outputChannels: channels, bufferPolicy: .standard(processingFrames: graph.chunkSize))
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
