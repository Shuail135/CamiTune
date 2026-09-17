import Foundation

/// Describes the smallest safe runtime update between two validated graphs.
/// CamillaDSP can merge filter definitions, but pipeline topology is replaced
/// as a complete configuration so processors are never referenced halfway
/// through a structural edit.
enum ProcessingGraphUpdate: Equatable, Sendable {
    case unchanged
    case patch(processors: [ProcessingGraph.Processor])
    case replaceConfiguration

    var kind: String {
        switch self {
        case .unchanged: return "unchanged"
        case .patch: return "runtimePatch"
        case .replaceConfiguration: return "fullConfiguration"
        }
    }
}

struct ProcessingGraphDiffer: Sendable {
    func update(
        from current: ProcessingGraph,
        to next: ProcessingGraph
    ) -> ProcessingGraphUpdate {
        if current == next { return .unchanged }

        guard hasSameTopology(current, next) else {
            return .replaceConfiguration
        }

        // A prepared file may have changed bytes at an otherwise identical path.
        // Reload the full graph rather than submitting an identical merge patch.
        for (before, after) in zip(current.processors, next.processors) {
            if case .convolution(let a) = before.implementation,
               case .convolution(let b) = after.implementation, a.contentSHA256 != b.contentSHA256 {
                return .replaceConfiguration
            }
        }

        // Compare exactly the filter values the backend compiler sends. This
        // excludes EQ editor IDs/labels and analytical metadata. Changing a
        // backend filter implementation kind requires a full configuration;
        // parameter changes retain the compiler's supported patch semantics.
        let compiler = CamillaDSPCompiler()
        let previous = compiler.compileRuntimePatch(processors: current.processors).filters
        let upcoming = compiler.compileRuntimePatch(processors: next.processors).filters
        guard zip(current.processors, next.processors).allSatisfy({
            sameImplementationKind($0.implementation, $1.implementation)
        }) else {
            return .replaceConfiguration
        }
        let changed = next.processors.filter { processor in
            previous[processor.id] != upcoming[processor.id]
        }
        return changed.isEmpty ? .unchanged : .patch(processors: changed)
    }

    private func sameImplementationKind(_ a: ProcessingGraph.Processor.Implementation,
                                        _ b: ProcessingGraph.Processor.Implementation) -> Bool {
        // Two implementations can share a Camilla type but emit different key
        // sets (e.g. gain vs crossfeedGain's mute). A merge patch cannot safely
        // remove omitted keys across those implementation changes.
        switch (a, b) {
        case (.gain, .gain), (.biquad, .biquad), (.convolution, .convolution),
             (.delay, .delay), (.firstOrderLowpass, .firstOrderLowpass),
             (.crossfeedGain, .crossfeedGain), (.limiter, .limiter): return true
        default: return false
        }
    }

    private func hasSameTopology(
        _ current: ProcessingGraph,
        _ next: ProcessingGraph
    ) -> Bool {
        current.sampleRate == next.sampleRate
            && current.chunkSize == next.chunkSize
            && current.inputFormat.signalSignature == next.inputFormat.signalSignature
            && current.outputFormat.signalSignature == next.outputFormat.signalSignature
            && current.capture == next.capture
            && current.playback == next.playback
            && current.mixers.elementsEqual(next.mixers) {
                $0.id == $1.id && $0.inputChannelCount == $1.inputChannelCount
                    && $0.outputChannelCount == $1.outputChannelCount && $0.mappings == $1.mappings
                }
            && current.pipeline.elementsEqual(next.pipeline) {
                $0.kind == $1.kind && $0.scope == $1.scope && $0.channels == $1.channels && $0.processorIDs == $1.processorIDs
            }
            && current.processors.map(\.id) == next.processors.map(\.id)
    }
}
