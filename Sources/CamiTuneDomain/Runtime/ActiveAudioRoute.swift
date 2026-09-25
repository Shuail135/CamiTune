import Foundation

package enum AudioRouteFormatError: LocalizedError, Equatable {
    case malformedFrame
    case sampleRate(expected: Int)
    case unsupportedLayout
    case incompatibleOutput

    package var errorDescription: String? {
        switch self {
        case .malformedFrame: return "The source supplied an incomplete audio frame."
        case .sampleRate(let rate): return "Audio is paused because the source rate does not match the profile's \(rate) Hz."
        case .unsupportedLayout: return "The source channel layout does not match this profile. Select the profile's audio output in the source app."
        case .incompatibleOutput: return "The audio route does not match the configured speakers."
        }
    }
}

package struct ActiveAudioRoute: Hashable, Sendable {
    package let sourceFormat: AudioFormatDescriptor
    package let dspInputFormat: AudioFormatDescriptor
    package let hardwareOutputFormat: AudioFormatDescriptor
    package let usesPhysicalSpeakerBus: Bool
    package let usesSourceProcessingBus: Bool
    package let usesDiscreteSource: Bool

    package init(profile original: DeviceProfile) throws {
        var profile = original
        try profile.migrateInterfaceTopology()
        try profile.validateMultichannelSettings()
        usesSourceProcessingBus = profile.usesSourceProcessingBus
        usesDiscreteSource = usesSourceProcessingBus && profile.multichannel.routing.enabled && profile.multichannel.routing.sourceLayout == .discrete
        sourceFormat = try .source(sampleRate: profile.sampleRate, layout: ProfileRoutingDescriptor.sourceLayout(for: profile))
        if let topology = try profile.validatedPhysicalSpeakerTopology() {
            // Match the profile's confirmed processing targets. Sorting by stable
            // physical identity makes role/name edits independent of bus order.
            let ids = Set(profile.configuredProcessingChannels.map(\.physicalOutputID))
            let endpoints = topology.endpoints.filter { ids.contains($0.id) }.sorted { $0.id.channelIndex < $1.id.channelIndex }
            dspInputFormat = usesSourceProcessingBus ? sourceFormat : try .physicalEndpoints(sampleRate: profile.sampleRate, endpoints: endpoints)
            hardwareOutputFormat = try .hardwareOutputs(sampleRate: profile.sampleRate,
                deviceUID: profile.outputDeviceUID, channelCount: topology.declaredChannelCount)
            usesPhysicalSpeakerBus = true
        } else {
            // Existing personal/legacy renderers produce stereo. Their input may
            // still be multichannel and per-app modes remain independent.
            dspInputFormat = try .source(sampleRate: profile.sampleRate, layout: .stereo)
            hardwareOutputFormat = try .hardwareOutputs(sampleRate: profile.sampleRate,
                deviceUID: profile.outputDeviceUID, channelCount: profile.configuredPhysicalChannelCount)
            usesPhysicalSpeakerBus = false
        }
    }

    package func buildGraph(profile: DeviceProfile, assets: PreparedRuntimeAssets) throws -> ProcessingGraph {
        let builder = ProcessingGraphBuilder(channelCount: profile.processingChannelCount, preparedAssets: assets)
        var graph: ProcessingGraph
        if usesSourceProcessingBus {
            graph = try MultichannelGraphCompiler().build(profile: profile, inputFormat: dspInputFormat, assets: assets)
        } else if usesPhysicalSpeakerBus {
            let mappings = try dspInputFormat.channels.enumerated().map { index, channel -> ProcessingGraph.Mixer.Mapping in
                guard let output = channel.physicalOutputID else { throw AudioRouteFormatError.incompatibleOutput }
                return .init(destination: output.channelIndex, sources: [.init(channel: index)])
            }
            graph = try builder.build(profile: profile, inputFormat: dspInputFormat, mappings: mappings)
        } else {
            graph = try builder.build(profile: profile)
            graph.inputFormat = dspInputFormat
        }
        guard graph.inputFormat == dspInputFormat, graph.outputFormat == hardwareOutputFormat else {
            throw AudioRouteFormatError.incompatibleOutput
        }
        try graph.validate()
        return graph
    }

    /// Compatible subsets and alternate ordering retain their source roles.
    /// Discrete/unknown input is never guessed to be a named speaker layout.

    package var dspLayout: LPCMChannelLayout {
        LPCMChannelLayout(coreAudioTag: 0, roles: dspInputFormat.channels.map { $0.role ?? .unknown })
    }

    /// Adapter for the existing renderer and physical audition clips. Select by
    /// physical identity, then let the graph restore the hardware slot positions.

}
