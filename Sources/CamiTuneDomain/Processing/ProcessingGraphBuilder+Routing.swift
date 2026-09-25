import Foundation

extension ProcessingGraphBuilder {
    /// Compile explicit N→M routing before physical per-output processing. The
    /// mappings use processing-bus indices; calibration stays keyed by output ID.
    package func build(profile: DeviceProfile, inputFormat: AudioFormatDescriptor,
               mappings: [ProcessingGraph.Mixer.Mapping]) throws -> ProcessingGraph {
        try inputFormat.validate()
        guard inputFormat.sampleRate == profile.sampleRate else { throw ProcessingGraphError.invalidSampleRate }
        var graph = try build(profile: profile)
        let width = graph.inputFormat.channelCount
        graph.inputFormat = inputFormat
        let id = "source_to_processing"
        let stage = UUID(uuidString: "AD100000-0000-0000-0000-000000000001")!
        graph.mixers.insert(.init(id: id, sourceStageID: stage, inputChannelCount: inputFormat.channelCount,
            outputChannelCount: width, mappings: mappings), at: 0)
        graph.pipeline.insert(.init(id: stage, kind: .mixer(id: id), scope: .global, channels: [], processorIDs: []), at: 0)
        try graph.validate()
        graph.automaticHeadroomDB = ProcessingGraphHeadroomCalculator().calculate(for: graph,
            excludingGainStageIDs: [ProcessingProfile.userPreampStageID])
        if let index = graph.processors.firstIndex(where: { $0.id == ProcessingGraph.automaticHeadroomProcessorID }) {
            graph.processors[index].implementation = .gain(db: graph.automaticHeadroomDB)
        }
        try graph.validate()
        return graph
    }
}
