import Foundation

enum AudioRouteFormatError: LocalizedError, Equatable {
    case malformedFrame
    case sampleRate(expected: Int)
    case unsupportedLayout
    case incompatibleOutput

    var errorDescription: String? {
        switch self {
        case .malformedFrame: return "The source supplied an incomplete audio frame."
        case .sampleRate(let rate): return "Audio is paused because the source rate does not match the profile's \(rate) Hz."
        case .unsupportedLayout: return "The source channel layout does not match this profile. Select the profile's audio output in the source app."
        case .incompatibleOutput: return "The audio route does not match the configured speakers."
        }
    }
}

/// Immutable for one activation. The writer prepares this exact DSP input bus;
/// the graph owns expansion to hardware slots and physical output processing.
struct ActiveAudioRoute: Hashable, Sendable {
    let sourceFormat: AudioFormatDescriptor
    let dspInputFormat: AudioFormatDescriptor
    let hardwareOutputFormat: AudioFormatDescriptor
    let usesPhysicalSpeakerBus: Bool
    let usesSourceProcessingBus: Bool
    let usesDiscreteSource: Bool

    init(profile original: DeviceProfile) throws {
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

    func buildGraph(profile: DeviceProfile) throws -> ProcessingGraph {
        let builder = ProcessingGraphBuilder(channelCount: profile.processingChannelCount)
        var graph: ProcessingGraph
        if usesSourceProcessingBus {
            graph = try MultichannelGraphCompiler().build(profile: profile, inputFormat: dspInputFormat)
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
    func validateSource(_ frame: PCMFrame) throws {
        try Self.validateFrame(frame)
        guard frame.sampleRate == Double(sourceFormat.sampleRate) else {
            throw AudioRouteFormatError.sampleRate(expected: sourceFormat.sampleRate)
        }
        let roles = frame.channelLayout.roles
        if usesDiscreteSource {
            guard roles.count == sourceFormat.channelCount, roles.allSatisfy({ $0 == .unknown }) else { throw AudioRouteFormatError.unsupportedLayout }
            return
        }
        guard !roles.contains(.unknown), Set(roles).count == roles.count else {
            throw AudioRouteFormatError.unsupportedLayout
        }
        if usesPhysicalSpeakerBus {
            let expected = Set(sourceFormat.channels.compactMap(\.role))
            guard Set(roles).isSubset(of: expected) else { throw AudioRouteFormatError.unsupportedLayout }
        }
    }

    static func validateFrame(_ frame: PCMFrame) throws {
        guard (1...32).contains(frame.channelCount), frame.sampleRate.isFinite, frame.sampleRate > 0,
              frame.channelLayout.channelCount == frame.channelCount, !frame.interleaved.isEmpty,
              frame.interleaved.count.isMultiple(of: frame.channelCount),
              frame.playbackModeSamples.values.allSatisfy({ $0.count == frame.interleaved.count }) else {
            throw AudioRouteFormatError.malformedFrame
        }
    }

    var dspLayout: LPCMChannelLayout {
        LPCMChannelLayout(coreAudioTag: 0, roles: dspInputFormat.channels.map { $0.role ?? .unknown })
    }

    func directMapper(for layout: LPCMChannelLayout) throws -> DirectChannelMapper {
        try DirectChannelMapper(sourceLayout: layout, outputFormat: dspInputFormat,
            preserveLegacyStereoOrder: usesPhysicalSpeakerBus && !usesSourceProcessingBus && hardwareOutputFormat.channelCount == 2,
            allowDiscreteOrder: usesDiscreteSource)
    }

    func validateDSPFrame(_ frame: PCMFrame) throws {
        try Self.validateFrame(frame)
        guard frame.sampleRate == Double(dspInputFormat.sampleRate),
              frame.channelLayout.roles == dspLayout.roles else { throw AudioRouteFormatError.incompatibleOutput }
    }

    /// Adapter for the existing renderer and physical audition clips. Select by
    /// physical identity, then let the graph restore the hardware slot positions.
    func preparePhysicalCompatibilityFrame(_ frame: PCMFrame) throws -> PCMFrame {
        try Self.validateFrame(frame)
        guard usesPhysicalSpeakerBus, !usesSourceProcessingBus, frame.channelCount == hardwareOutputFormat.channelCount,
              frame.sampleRate == Double(dspInputFormat.sampleRate) else { throw AudioRouteFormatError.incompatibleOutput }
        let slots = try dspInputFormat.channels.map { channel -> Int in
            guard let output = channel.physicalOutputID, (0..<frame.channelCount).contains(output.channelIndex) else {
                throw AudioRouteFormatError.incompatibleOutput
            }
            return output.channelIndex
        }
        var samples = [Float](repeating: 0, count: frame.frameCount * slots.count)
        for f in 0..<frame.frameCount {
            for (index, slot) in slots.enumerated() { samples[f * slots.count + index] = frame.interleaved[f * frame.channelCount + slot] }
        }
        return PCMFrame(interleaved: samples, channelCount: slots.count, sampleRate: frame.sampleRate,
            channelLayout: dspLayout, sourceBufferedFrames: frame.sourceBufferedFrames, sourceCapacityFrames: frame.sourceCapacityFrames)
    }
}

/// Direct role routing has no geometry, filtering or synthesized content. A
/// stereo subset leaves center, surround, height and LFE destinations silent.
struct DirectChannelMapper {
    let sourceLayout: LPCMChannelLayout
    let outputFormat: AudioFormatDescriptor
    private let assignments: [(source: Int, destination: Int, gain: Float)]

    init(sourceLayout: LPCMChannelLayout, outputFormat: AudioFormatDescriptor,
         preserveLegacyStereoOrder: Bool = false, allowDiscreteOrder: Bool = false) throws {
        try outputFormat.validate()
        if allowDiscreteOrder {
            guard sourceLayout.channelCount == outputFormat.channelCount,
                  sourceLayout.roles.allSatisfy({ $0 == .unknown }), outputFormat.channels.allSatisfy({ $0.role == .unknown }) else { throw AudioRouteFormatError.unsupportedLayout }
            self.sourceLayout = sourceLayout; self.outputFormat = outputFormat
            assignments = sourceLayout.roles.indices.map { (source: $0, destination: $0, gain: 1) }
            return
        }
        guard !sourceLayout.roles.isEmpty, !sourceLayout.roles.contains(.unknown),
              Set(sourceLayout.roles).count == sourceLayout.roles.count else { throw AudioRouteFormatError.unsupportedLayout }
        self.sourceLayout = sourceLayout
        self.outputFormat = outputFormat
        assignments = sourceLayout.roles.enumerated().flatMap { source, role in
            var destinations = outputFormat.channels.indices.filter { outputFormat.channels[$0].role == role }
            if destinations.isEmpty, preserveLegacyStereoOrder, sourceLayout.roles == LPCMChannelLayout.stereo.roles {
                // Existing two-channel profiles can label an output Custom.
                // Preserve their established L/R hardware order without assigning
                // semantic roles to discrete sources or larger custom systems.
                destinations = outputFormat.channels.indices.filter {
                    outputFormat.channels[$0].role == .unknown && outputFormat.channels[$0].physicalOutputID?.channelIndex == source
                }
            }
            // Preserve the existing level convention for duplicate named speakers.
            let gain = 1 / sqrt(Float(max(1, destinations.count)))
            return destinations.map { (source: source, destination: $0, gain: gain) }
        }
    }

    func prepare(_ frame: PCMFrame) throws -> PCMFrame {
        try ActiveAudioRoute.validateFrame(frame)
        guard frame.channelLayout == sourceLayout, frame.sampleRate == Double(outputFormat.sampleRate) else {
            throw AudioRouteFormatError.incompatibleOutput
        }
        let width = outputFormat.channelCount
        var samples = [Float](repeating: 0, count: frame.frameCount * width)
        for f in 0..<frame.frameCount {
            for assignment in assignments {
                let value = frame.interleaved[f * frame.channelCount + assignment.source]
                samples[f * width + assignment.destination] = (value.isFinite ? value : 0) * assignment.gain
            }
        }
        return PCMFrame(interleaved: samples, channelCount: width, sampleRate: frame.sampleRate,
            channelLayout: LPCMChannelLayout(coreAudioTag: 0, roles: outputFormat.channels.map { $0.role ?? .unknown }),
            sourceBufferedFrames: frame.sourceBufferedFrames, sourceCapacityFrames: frame.sourceCapacityFrames)
    }
}
