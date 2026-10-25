import Foundation

package struct RoomMeasurementContext: Codable, Hashable, Sendable {
    package var topology: SpeakerTopology
    package var listener: SpatialVector3
    /// Exact downstream processing through which the sweep was measured, excluding room correction.
    package var processing: ProcessingProfile
    /// Editor settings retained for replacing previously imported correction.
    /// These bypassed settings are not part of acoustic equality or staleness.
    package var importBaselineProcessing: ProcessingProfile?
    package var revision = 1
    package var multichannel: MultichannelProcessingSettings?
    package init(topology: SpeakerTopology, listener: SpatialVector3, processing: ProcessingProfile) {
        self.topology = topology; self.listener = listener; self.processing = processing
    }
    package func canReprocess(to current: Self) -> Bool {
        var old = self
        old.topology.sampleRate = current.topology.sampleRate
        // Revision 2 retains more processing during measurement. Reuse older
        // captures only when their actual acoustic path is still identical.
        if old.revision == 1 && current.revision == 2 { old.revision = 2 }
        return old == current
    }
}
extension RoomMeasurementContext {
    /// Editor identities, locked bands and bypassed stages do not change what
    /// the microphone heard. Keep all enabled audio settings and their order.
    private var acousticProcessing: ProcessingProfile {
        let identity = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        func chain(_ source: ProcessingChain) -> ProcessingChain {
            var result = source
            result.stages = source.stages.compactMap { stage in
                guard stage.isEnabled else { return nil }
                var stage = stage
                stage.id = identity
                if case .gain(let gain) = stage.processor, gain.gainDB == 0 { return nil }
                if case .delay(let delay) = stage.processor, delay.milliseconds == 0 { return nil }
                if case .equalizer(var equalizer) = stage.processor {
                    equalizer.bands = equalizer.bands.filter { $0.enabled && !($0.kind.usesGain && ($0.gain ?? 0) == 0) }.map {
                        EQBand(id: identity, kind: $0.kind, frequency: $0.frequency,
                            gain: $0.gain, q: $0.q, bandwidth: $0.bandwidth)
                    }
                    guard !equalizer.bands.isEmpty else { return nil }
                    stage.processor = .equalizer(equalizer)
                }
                return stage
            }
            return result
        }
        var result = processing
        result.globalEqualizerProvenance = nil
        result.global = chain(result.global)
        for index in result.channels.indices { result.channels[index].chain = chain(result.channels[index].chain) }
        for index in result.groups.indices { result.groups[index].chain = chain(result.groups[index].chain) }
        return result
    }
    private var acousticTopology: SpeakerTopology {
        var value = topology
        value.createdAt = .distantPast; value.updatedAt = .distantPast
        for i in value.endpoints.indices { value.endpoints[i].displayName = "" }
        return value
    }
    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.acousticTopology == rhs.acousticTopology && lhs.listener == rhs.listener
            && lhs.acousticProcessing == rhs.acousticProcessing && lhs.revision == rhs.revision && lhs.multichannel == rhs.multichannel
    }
    package func hash(into hasher: inout Hasher) {
        hasher.combine(acousticTopology); hasher.combine(listener); hasher.combine(acousticProcessing)
        hasher.combine(revision); hasher.combine(multichannel)
    }
}
