import Foundation

/// Describes the smallest safe runtime update between two validated graphs.
/// CamillaDSP can merge filter definitions, but pipeline topology is replaced
/// as a complete configuration so processors are never referenced halfway
/// through a structural edit.
enum ProcessingGraphUpdate: Equatable, Sendable {
    case unchanged
    case patch(processors: [ProcessingGraph.Processor])
    case replaceConfiguration
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

        let previousProcessors = Dictionary(
            current.processors.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let changed = next.processors.filter { processor in
            previousProcessors[processor.id]?.implementation != processor.implementation
        }
        return changed.isEmpty ? .unchanged : .patch(processors: changed)
    }

    private func hasSameTopology(
        _ current: ProcessingGraph,
        _ next: ProcessingGraph
    ) -> Bool {
        current.title == next.title
            && current.sampleRate == next.sampleRate
            && current.chunkSize == next.chunkSize
            && current.channelCount == next.channelCount
            && current.capture == next.capture
            && current.playback == next.playback
            && current.mixers == next.mixers
            && current.pipeline == next.pipeline
            && current.processors.map { ($0.id, $0.sourceStageID) }
                .elementsEqual(next.processors.map { ($0.id, $0.sourceStageID) }) {
                    $0.0 == $1.0 && $0.1 == $1.1
                }
    }
}
