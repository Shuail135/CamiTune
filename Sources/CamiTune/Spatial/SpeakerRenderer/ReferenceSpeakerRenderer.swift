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
    private let exactRolesOnly: Bool
    private let endpoints: [SpeakerEndpoint]
    private let positioned: [SpeakerEndpoint]
    private let solver: VBAPSolver
    private var descriptors: [SpatialObject] = []
    private var targets: [[Float]] = []
    private var current: [SpatialObjectID: [Float]] = [:]
    private var sampleRate: Double = 0
    private var safetyGain: Float = 1
    private(set) var diagnostics = ReferenceSpeakerDiagnostics()

    init(topology: SpeakerTopology, exactRolesOnly: Bool = false) throws {
        self.exactRolesOnly = exactRolesOnly
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
        if exactRolesOnly {
            // Core Audio can expose ordinary stereo speakers without role
            // labels. Direct keeps their hardware channel order; missing
            // metadata must not turn confirmed physical outputs into silence.
            // Named routes above still take precedence, and disabled/silent
            // endpoints were excluded when constructing this renderer.
            if let endpoint = endpoints.first(where: {
                $0.role == .unknown && $0.id.channelIndex == object.audioPlaneIndex
            }) {
                gains[endpoint.id.channelIndex] = 1
            }
            return (gains, false)
        }
        guard let position = object.position else { return (gains, true) }
        let result = solver.gains(for: position)
        for i in positioned.indices { gains[positioned[i].id.channelIndex] = result.gains[i] }
        // Spread is reserved for an object provider; channel beds always use zero.
        // Unsupported spread is rejected by providers rather than guessed here.
        return (gains, result.fallback)
    }
}


/// Mode policies share one immutable physical topology and the existing VBAP mapper.
/// Confined to the PCM writer worker. Spatial adds the existing speaker processor's
/// wet difference as positioned scene objects; source channel intent is retained.
final class PhysicalSpeakerModeRenderer {
    private var direct: ReferenceSpeakerRenderer
    private var reference: ReferenceSpeakerRenderer
    private var spatial: ReferenceSpeakerRenderer
    private let enhancement = SpeakerSpatialRenderer()
    private var amount = SpatialScalarSmoother()
    private var cinema = SpatialScalarSmoother()
    private let rate: Double
    var diagnostics: ReferenceSpeakerDiagnostics { reference.diagnostics }
    private(set) var spatialDiagnostics = SpatialRenderDiagnostics()

    init(topology: SpeakerTopology) throws {
        direct = try ReferenceSpeakerRenderer(topology: topology, exactRolesOnly: true)
        reference = try ReferenceSpeakerRenderer(topology: topology)
        spatial = try ReferenceSpeakerRenderer(topology: topology)
        rate = topology.sampleRate
        enhancement.prepare(sampleRate: rate)
        amount.prepare(sampleRate: rate); cinema.prepare(sampleRate: rate, seconds: 0.15)
    }
    func reset() {
        direct.reset(); reference.reset(); spatial.reset(); enhancement.reset()
        amount.reset(); cinema.reset()
    }
    func render(_ frame: PCMFrame, mode: PlaybackMode, settings: SpatialRenderSettings) throws -> PCMFrame {
        var scene = try ChannelBasedSceneProvider().makeScene(from: frame)
        switch mode {
        case .direct: return try direct.render(scene)
        case .referencePlayback: return try reference.render(scene)
        case .spatialRender:
            let start = ProcessInfo.processInfo.systemUptime
            let isCinema = settings.contentSelection == .cinema || (settings.contentSelection == .automatic && frame.channelCount > 2)
            let strength = SpatialSafety.unit(isCinema ? settings.cinema.amount : settings.music.amount)
            let left = frame.channelLayout.roles.firstIndex(of: .left)
            let right = frame.channelLayout.roles.firstIndex(of: .right)
            let center = frame.channelLayout.roles.firstIndex(of: .center)
            let dialogue = isCinema ? 1 + 0.12 * SpatialSafety.unit(settings.cinema.dialogueFocus) : 1
            let count = frame.channelCount + 2
            var samples = [Float](repeating: 0, count: frame.frameCount * count)
            for i in 0..<frame.frameCount {
                for ch in 0..<frame.channelCount { samples[i * count + ch] = SpatialSafety.sample(frame.interleaved[i * frame.channelCount + ch]) }
                if let center { samples[i * count + center] *= dialogue }
                let l = left.map { samples[i * count + $0] } ?? 0
                let r = right.map { samples[i * count + $0] } ?? 0
                let shaped = enhancement.process(left: l, right: r, amount: amount.next(strength), cinema: cinema.next(isCinema ? 1 : 0))
                samples[i * count + frame.channelCount] = shaped.0 - l
                samples[i * count + frame.channelCount + 1] = shaped.1 - r
            }
            // Reuse standard surround intent, then the same authoritative room mapper.
            let wetRoles: [ChannelRole] = [.leftSurround, .rightSurround]
            for offset in 0..<2 {
                scene.objects.append(SpatialObject(id: SpatialObjectID(rawValue: UInt32(frame.channelCount + offset)),
                    audioPlaneIndex: frame.channelCount + offset,
                    position: StandardSpeakerPositions.position(for: wetRoles[offset]), role: .generic))
            }
            scene.audio = PCMFrame(interleaved: samples, channelCount: count, sampleRate: rate,
                channelLayout: LPCMChannelLayout(coreAudioTag: 0, roles: frame.channelLayout.roles + wetRoles),
                sourceBufferedFrames: frame.sourceBufferedFrames, sourceCapacityFrames: frame.sourceCapacityFrames)
            let rendered = try spatial.render(scene)
            spatialDiagnostics = SpatialRenderDiagnostics(renderer: .speakers, content: isCinema ? .cinema : .music,
                inputChannels: frame.channelCount,
                inputPeak: frame.interleaved.reduce(0) { max($0, abs(SpatialSafety.sample($1))) },
                outputPeak: rendered.interleaved.reduce(0) { max($0, abs($1)) },
                appliedHeadroomDB: spatial.diagnostics.headroomDB,
                processingTimeMicroseconds: (ProcessInfo.processInfo.systemUptime - start) * 1e6,
                invalidSamples: UInt64(spatial.diagnostics.invalidSamples))
            return rendered
        }
    }
}
