import CamiTuneAudio
import CamiTuneDomain
import Foundation

struct CamillaDSPDiagnostics: Sendable {
    var engineState: String
    var stopReason: String
    var processingLoadPercent: Double
    var resamplerLoadPercent: Double
    var bufferLevelFrames: UInt64
    var rateAdjustment: Double
    var clippedSamples: UInt64
    var lastGraphUpdate: GraphUpdateKind?
    var patchedFilterCount: Int
    var sampleRate: Double? = nil
    var blockFrames: Int? = nil

    enum GraphUpdateKind: String, Sendable {
        case fullConfiguration
        case fullConfigurationFallback
        case runtimePatch
        case unchanged
    }
}

extension AudioOutputTelemetry {
    init(camilla diagnostics: CamillaDSPDiagnostics) {
        self.init(backend: "CamillaDSP", engineState: diagnostics.engineState,
            stopReason: diagnostics.stopReason, processingLoadPercent: diagnostics.processingLoadPercent,
            resamplerLoadPercent: diagnostics.resamplerLoadPercent, bufferLevelFrames: diagnostics.bufferLevelFrames,
            rateAdjustment: diagnostics.rateAdjustment, clippedSamples: diagnostics.clippedSamples,
            sampleRate: diagnostics.sampleRate, blockFrames: diagnostics.blockFrames,
            processingBufferFrames: diagnostics.blockFrames)
    }
}

extension AudioRuntimeStatus {
    mutating func recordTelemetry(_ diagnostics: CamillaDSPDiagnostics, at now: Date) {
        recordTelemetry(AudioOutputTelemetry(camilla: diagnostics), at: now)
    }
}

/// Runtime boundary used by the application. It owns the active graph snapshot
/// and chooses between a small WebSocket patch and a full topology replacement.
@MainActor
final class CamillaDSPController: AudioProcessingBackend {
    private let manager: CamillaDSPManager
    var binary: URL
    private let compiler: CamillaDSPCompiler
    private let differ: ProcessingGraphDiffer
    private(set) var activeGraph: ProcessingGraph?
    private(set) var lastGraphUpdate: CamillaDSPDiagnostics.GraphUpdateKind?
    private var patchedFilterCount = 0
    private let applyConfiguration: (CamillaDSPConfiguration) async throws -> Void
    private let applyPatch: (CamillaDSPRuntimePatch) async throws -> Void

    init(
        manager: CamillaDSPManager,
        binary: URL = CamiTunePaths.supportDirectory.appendingPathComponent("bin/camilladsp"),
        compiler: CamillaDSPCompiler = CamillaDSPCompiler(),
        differ: ProcessingGraphDiffer = ProcessingGraphDiffer(),
        applyConfiguration: ((CamillaDSPConfiguration) async throws -> Void)? = nil,
        applyPatch: ((CamillaDSPRuntimePatch) async throws -> Void)? = nil
    ) {
        self.manager = manager
        self.binary = binary
        self.compiler = compiler
        self.differ = differ
        self.applyConfiguration = applyConfiguration ?? { try await manager.apply(configuration: $0) }
        self.applyPatch = applyPatch ?? { try await manager.apply(patch: $0) }
    }

    func configuration(for graph: ProcessingGraph) async -> CamillaDSPConfiguration {
        let compiler = self.compiler
        return await Task.detached(priority: .userInitiated) {
            compiler.compile(graph)
        }.value
    }

    func applyGraph(_ graph: ProcessingGraph, performanceRecorder: RuntimePerformanceRecorder? = nil) async throws {
        try graph.validate()
        let currentGraph = activeGraph
        let differ = self.differ
        let operation = performanceRecorder?.begin("Graph diff", reason: "backend")
        let update = await Task.detached(priority: .userInitiated) {
            currentGraph.map { differ.update(from: $0, to: graph) }
                ?? .replaceConfiguration
        }.value
        operation?.mark("classification: " + update.kind)
        operation?.finish("success")

        switch update {
        case .unchanged:
            lastGraphUpdate = .unchanged
            patchedFilterCount = 0
        case .patch(let processors):
            let compiler = self.compiler
            let patch = await Task.detached(priority: .userInitiated) {
                compiler.compileRuntimePatch(processors: processors)
            }.value
            // Once submitted, a lost reply cannot establish which graph is live.
            // Keep the cache unknown until a complete operation is acknowledged.
            activeGraph = nil
            do {
                try await applyPatch(patch)
                lastGraphUpdate = .runtimePatch
                patchedFilterCount = processors.count
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A full graph remains a compatibility and recovery path if a
                // running engine rejects a patch after its protocol/state changes.
                let configuration = await configuration(for: graph)
                try await applyConfiguration(configuration)
                lastGraphUpdate = .fullConfigurationFallback
                patchedFilterCount = 0
            }
        case .replaceConfiguration:
            let configuration = await configuration(for: graph)
            activeGraph = nil
            try await applyConfiguration(configuration)
            lastGraphUpdate = .fullConfiguration
            patchedFilterCount = 0
        }
        activeGraph = graph
    }

    /// Starts a new runtime generation. The next graph must seed CamillaDSP
    /// with a complete configuration before incremental patches are possible.
    func resetRuntime() {
        activeGraph = nil
        lastGraphUpdate = nil
        patchedFilterCount = 0
    }

    func fetchMeters() async throws -> SignalLevels {
        try await manager.rpc.signalLevels()
    }

    func fetchDiagnostics() async throws -> CamillaDSPDiagnostics {
        // These remain individual protocol reads so older/newer CamillaDSP
        // telemetry fields cannot become coupled to graph patching semantics.
        let graph = activeGraph
        let engineState = try await manager.rpc.state()
        let stopReason = try await manager.rpc.stopReason()
        let processingLoad = try await manager.rpc.processingLoad()
        let resamplerLoad = try await manager.rpc.resamplerLoad()
        let bufferLevel = try await manager.rpc.bufferLevel()
        let rateAdjustment = try await manager.rpc.rateAdjust()
        let clippedSamples = try await manager.rpc.clippedSamples()
        // Never publish observations from a graph replaced during these awaits.
        guard !Task.isCancelled, graph == activeGraph else { throw CancellationError() }
        return CamillaDSPDiagnostics(
            engineState: engineState,
            stopReason: stopReason,
            processingLoadPercent: processingLoad,
            resamplerLoadPercent: resamplerLoad,
            bufferLevelFrames: bufferLevel,
            rateAdjustment: rateAdjustment,
            clippedSamples: clippedSamples,
            lastGraphUpdate: lastGraphUpdate,
            patchedFilterCount: patchedFilterCount,
            sampleRate: graph.map { Double($0.sampleRate) },
            blockFrames: graph?.chunkSize
        )
    }
}

extension CamillaDSPController {
    var name: String { "CamillaDSP" }
    var playbackClock: AudioPlaybackClock? { manager.lastPlaybackClock }
    var isRunning: Bool { manager.isRunning }
    var graphUpdateDescription: String? { lastGraphUpdate?.rawValue }

    func validateAvailability() throws {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw AppState.AppError.missingCamillaDSP }
    }

    func start() async throws { try await manager.start(binary: binary) }

    func validateOutput(uid: String) async throws {
        let outputs = try await manager.rpc.availablePlaybackDevices(backend: "CoreAudio")
        guard outputs.contains(where: { $0.identifier == uid }) else { throw AppState.AppError.camillaDSPCoreAudioUIDUnsupported }
    }

    func makeInputSink() throws -> any PCMOutputSink {
        try CamillaPCMSink(duplicating: manager.audioInputHandle().fileDescriptor)
    }

    func fetchTelemetry() async throws -> AudioOutputTelemetry { .init(camilla: try await fetchDiagnostics()) }

    func measureWork() async -> AudioBackendWork {
        let load = try? await manager.rpc.processingLoad()
        let clock = try? await manager.rpc.playbackClock()
        return .init(loadPercent: load, clockEpoch: clock?.epoch, underrunFrames: clock?.underrunFrames)
    }

    func observePlaybackClock(session: UUID, consumer: @escaping @Sendable (AudioClockObservation) -> Void) {
        manager.observePlaybackClock(session: session, consumer: consumer)
    }

    func stopClockObservations() { manager.stopClockObservations() }
    func closeInput() async { await manager.closeAudioInputWithoutBlockingUI() }
    func closeInputSynchronously() { manager.closeAudioInput() }
    func stop() async { await manager.stop() }
    func stopSynchronously() { manager.forceStopAndWait() }
}
