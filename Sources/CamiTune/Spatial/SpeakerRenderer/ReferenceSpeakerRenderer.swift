import Foundation

struct ReferenceSpeakerDiagnostics: Sendable {
    var outputChannels = 0
    var unmappedObjects = 0
    var geometryFallbacks = 0
    var headroomDB: Float = 0
    var invalidSamples = 0
}

/// Maps a source scene to the current physical speaker topology.
/// Reference mode does not invent surround content from stereo.
/// Construct on a lifecycle worker. Geometry is immutable for a running route.
struct ReferenceSpeakerRenderer {
    let topology: SpeakerTopology
    private let endpoints: [SpeakerEndpoint]
    private let positioned: [SpeakerEndpoint]
    private let solver: VBAPSolver
    private var descriptors: [SpatialObject] = []
    private var targets: [[Float]] = []
    private var current: [SpatialObjectID: [Float]] = [:]
    private var sampleRate: Double = 0
    private var safetyGain: Float = 1
    private(set) var diagnostics = ReferenceSpeakerDiagnostics()

    init(topology: SpeakerTopology) throws {
        try topology.validate()
        self.topology = topology
        endpoints = topology.endpoints.filter {
            $0.connectionState == .acousticallyDetected || $0.connectionState == .confirmedByUser
        }
        positioned = endpoints.filter { $0.position != nil && $0.layer != .subwoofer && !$0.isSubwooferLike }
        solver = VBAPSolver(positions: positioned.compactMap(\.position))
        diagnostics.outputChannels = topology.declaredChannelCount
    }

    mutating func reset() {
        descriptors = []; targets = []; current = [:]; sampleRate = 0; safetyGain = 1
        diagnostics = ReferenceSpeakerDiagnostics(outputChannels: topology.declaredChannelCount)
    }

    mutating func render(_ scene: SpatialSceneFrame) throws -> PCMFrame {
        try scene.validate()
        guard scene.objects.allSatisfy({ $0.spread == 0 }) else { throw SpatialSceneFrame.SceneError.invalidScene }
        guard scene.audio.sampleRate == topology.sampleRate else { throw SpeakerTopologyError.invalidSampleRate }
        if sampleRate != scene.audio.sampleRate { reset(); sampleRate = scene.audio.sampleRate }
        if descriptors != scene.objects {
            diagnostics.unmappedObjects = 0; diagnostics.geometryFallbacks = 0
            targets = scene.objects.map { object in
                let result = route(object)
                if object.active && !result.gains.contains(where: { $0 > 0 }) { diagnostics.unmappedObjects += 1 }
                if result.fallback { diagnostics.geometryFallbacks += 1 }
                return result.gains.map { $0 * object.gainLinear }
            }
            descriptors = scene.objects
            let ids = Set(descriptors.map(\.id))
            current = current.filter { ids.contains($0.key) }
        }
        let count = topology.declaredChannelCount
        var rows = descriptors.enumerated().map { i, object in current[object.id] ?? targets[i] }
        // Bound the real block, including both ends of moving gain ramps.
        // Silent padded bed channels must not attenuate stereo. A fast attack /
        // slow release gain handles coherent overload without hard clipping.
        var peaks = [Double](repeating: 0, count: scene.audio.channelCount)
        for index in scene.audio.interleaved.indices {
            let value = scene.audio.interleaved[index]
            if value.isFinite { peaks[index % peaks.count] = max(peaks[index % peaks.count], abs(Double(value))) }
        }
        var maximumSum: Double = 1
        for output in 0..<count {
            var sum: Double = 0
            for i in rows.indices { sum += Double(max(rows[i][output], targets[i][output])) * peaks[descriptors[i].audioPlaneIndex] }
            maximumSum = max(maximumSum, sum)
        }
        let targetSafety = Float(1 / maximumSum)
        if targetSafety < safetyGain { safetyGain = targetSafety }
        else { safetyGain += Float(1 - exp(-Double(scene.audio.frameCount) / sampleRate / 0.25)) * (targetSafety-safetyGain) }
        let headroom = safetyGain
        diagnostics.headroomDB = 20 * log10(max(1e-38, headroom))
        let smoothing = Float(1 - exp(-1 / (sampleRate * 0.03)))
        var output = [Float](repeating: 0, count: scene.audio.frameCount * count)
        for frame in 0..<scene.audio.frameCount {
            for (i, object) in descriptors.enumerated() {
                let value = scene.audio.interleaved[frame * scene.audio.channelCount + object.audioPlaneIndex]
                if !value.isFinite { diagnostics.invalidSamples += 1 }
                let sample = value.isFinite ? value * headroom : 0
                for channel in 0..<count {
                    rows[i][channel] += smoothing * (targets[i][channel] - rows[i][channel])
                    output[frame * count + channel] += sample * rows[i][channel]
                }
            }
        }
        for (i, object) in descriptors.enumerated() { current[object.id] = rows[i] }
        var roles = [ChannelRole](repeating: .unknown, count: count)
        for endpoint in topology.endpoints { roles[endpoint.id.channelIndex] = endpoint.role }
        return PCMFrame(interleaved: output, channelCount: count, sampleRate: sampleRate,
            channelLayout: LPCMChannelLayout(coreAudioTag: 0, roles: roles),
            sourceBufferedFrames: scene.audio.sourceBufferedFrames,
            sourceCapacityFrames: scene.audio.sourceCapacityFrames)
    }

    private func route(_ object: SpatialObject) -> (gains: [Float], fallback: Bool) {
        var gains = [Float](repeating: 0, count: topology.declaredChannelCount)
        guard object.active else { return (gains, false) }
        if object.role == .lowFrequency {
            let subs = endpoints.filter { $0.layer == .subwoofer || $0.isSubwooferLike }
            // No unverified full-range fallback and no implicit LFE +10 dB boost.
            for sub in subs { gains[sub.id.channelIndex] = 1 / Float(subs.count) }
            return (gains, subs.isEmpty)
        }
        if case .bed(let role) = object.role, role != .unknown {
            let exact = endpoints.filter { $0.role == role && $0.layer != .subwoofer }
            if !exact.isEmpty {
                for endpoint in exact { gains[endpoint.id.channelIndex] = 1 / sqrt(Float(exact.count)) }
                return (gains, false)
            }
        }
        guard let position = object.position else { return (gains, true) }
        let result = solver.gains(for: position)
        for i in positioned.indices { gains[positioned[i].id.channelIndex] = result.gains[i] }
        // Spread is reserved for an object provider; channel beds always use zero.
        // Unsupported spread is rejected by providers rather than guessed here.
        return (gains, result.fallback)
    }
}
