import CamiTuneDomain
import Foundation

/// Immutable for one activation. The writer prepares this exact DSP input bus;
/// the graph owns expansion to hardware slots and physical output processing.
extension ActiveAudioRoute {
    package func validateSource(_ frame: PCMFrame) throws {
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

    package static func validateFrame(_ frame: PCMFrame) throws {
        guard (1...32).contains(frame.channelCount), frame.sampleRate.isFinite, frame.sampleRate > 0,
              frame.channelLayout.channelCount == frame.channelCount, !frame.interleaved.isEmpty,
              frame.interleaved.count.isMultiple(of: frame.channelCount),
              frame.playbackModeSamples.values.allSatisfy({ $0.count == frame.interleaved.count }) else {
            throw AudioRouteFormatError.malformedFrame
        }
    }

    package func directMapper(for layout: LPCMChannelLayout) throws -> DirectChannelMapper {
        try DirectChannelMapper(sourceLayout: layout, outputFormat: dspInputFormat,
            preserveLegacyStereoOrder: usesPhysicalSpeakerBus && !usesSourceProcessingBus && hardwareOutputFormat.channelCount == 2,
            allowDiscreteOrder: usesDiscreteSource)
    }

    package func validateDSPFrame(_ frame: PCMFrame) throws {
        try Self.validateFrame(frame)
        guard frame.sampleRate == Double(dspInputFormat.sampleRate),
              frame.channelLayout.roles == dspLayout.roles else { throw AudioRouteFormatError.incompatibleOutput }
    }

    package func preparePhysicalCompatibilityFrame(_ frame: PCMFrame) throws -> PCMFrame {
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
            channelLayout: dspLayout)
    }
}

/// Direct role routing has no geometry, filtering or synthesized content. A
/// stereo subset leaves center, surround, height and LFE destinations silent.
package struct DirectChannelMapper {
    package let sourceLayout: LPCMChannelLayout
    package let outputFormat: AudioFormatDescriptor
    private let assignments: [(source: Int, destination: Int, gain: Float)]

    package init(sourceLayout: LPCMChannelLayout, outputFormat: AudioFormatDescriptor,
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

    package func prepare(_ frame: PCMFrame) throws -> PCMFrame {
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
            channelLayout: LPCMChannelLayout(coreAudioTag: 0, roles: outputFormat.channels.map { $0.role ?? .unknown }))
    }
}
