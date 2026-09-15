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

    enum GraphUpdateKind: String, Sendable {
        case fullConfiguration
        case runtimePatch
        case unchanged
    }
}

/// Runtime boundary used by the application. It owns the active graph snapshot
/// and chooses between a small WebSocket patch and a full topology replacement.
@MainActor
final class CamillaDSPController {
    private let manager: CamillaDSPManager
    private let compiler: CamillaDSPCompiler
    private let differ: ProcessingGraphDiffer
    private var activeGraph: ProcessingGraph?
    private var lastGraphUpdate: CamillaDSPDiagnostics.GraphUpdateKind?
    private var patchedFilterCount = 0

    init(
        manager: CamillaDSPManager,
        compiler: CamillaDSPCompiler = CamillaDSPCompiler(),
        differ: ProcessingGraphDiffer = ProcessingGraphDiffer()
    ) {
        self.manager = manager
        self.compiler = compiler
        self.differ = differ
    }

    func configuration(for graph: ProcessingGraph) async -> CamillaDSPConfiguration {
        let compiler = self.compiler
        return await Task.detached(priority: .userInitiated) {
            compiler.compile(graph)
        }.value
    }

    func applyGraph(_ graph: ProcessingGraph) async throws {
        try graph.validate()
        let currentGraph = activeGraph
        let differ = self.differ
        let update = await Task.detached(priority: .userInitiated) {
            currentGraph.map { differ.update(from: $0, to: graph) }
                ?? .replaceConfiguration
        }.value

        switch update {
        case .unchanged:
            lastGraphUpdate = .unchanged
            patchedFilterCount = 0
        case .patch(let processors):
            let compiler = self.compiler
            let patch = await Task.detached(priority: .userInitiated) {
                compiler.compileRuntimePatch(processors: processors)
            }.value
            do {
                try await manager.apply(patch: patch)
                lastGraphUpdate = .runtimePatch
                patchedFilterCount = processors.count
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A full graph remains a compatibility and recovery path if a
                // running engine rejects a patch after its protocol/state changes.
                let configuration = await Task.detached(priority: .userInitiated) {
                    compiler.compile(graph)
                }.value
                try await manager.apply(configuration: configuration)
                lastGraphUpdate = .fullConfiguration
                patchedFilterCount = 0
            }
        case .replaceConfiguration:
            let compiler = self.compiler
            let configuration = await Task.detached(priority: .userInitiated) {
                compiler.compile(graph)
            }.value
            try await manager.apply(configuration: configuration)
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

    func setVolume(_ db: Double) async throws {
        try await manager.rpc.setVolume(db)
    }

    func setMute(_ muted: Bool) async throws {
        try await manager.rpc.setMute(muted)
    }

    func fetchMeters() async throws -> SignalLevels {
        try await manager.rpc.signalLevels()
    }

    func fetchDiagnostics() async throws -> CamillaDSPDiagnostics {
        // These remain individual protocol reads so older/newer CamillaDSP
        // telemetry fields cannot become coupled to graph patching semantics.
        let engineState = try await manager.rpc.state()
        let stopReason = try await manager.rpc.stopReason()
        let processingLoad = try await manager.rpc.processingLoad()
        let resamplerLoad = try await manager.rpc.resamplerLoad()
        let bufferLevel = try await manager.rpc.bufferLevel()
        let rateAdjustment = try await manager.rpc.rateAdjust()
        let clippedSamples = try await manager.rpc.clippedSamples()
        return CamillaDSPDiagnostics(
            engineState: engineState,
            stopReason: stopReason,
            processingLoadPercent: processingLoad,
            resamplerLoadPercent: resamplerLoad,
            bufferLevelFrames: bufferLevel,
            rateAdjustment: rateAdjustment,
            clippedSamples: clippedSamples,
            lastGraphUpdate: lastGraphUpdate,
            patchedFilterCount: patchedFilterCount
        )
    }
}
