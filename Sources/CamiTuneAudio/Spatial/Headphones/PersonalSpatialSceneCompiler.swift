import CamiTuneDomain
import Foundation

package struct PersonalSpatialCoefficients {
    package let scene: PersonalSpatialSceneIntent
    package let sampleRate: Double
    package let referenceDelay: Int
    package let profileName: String
    package let direct: [HRIRPair]
    package let early: [HRIRPair]
}

/// Offline scene compilation. Impulcifer's speaker/ear matrix and shared gain
/// policy inform this implementation. The adjustable room uses synthesized
/// paths; the fixed studio uses measured KU100 BRIRs. Neither is a personal
/// calibration. Measured responses already contain interaural delay.
package enum PersonalSpatialSceneCompiler {
    package static func compile(scene: PersonalSpatialSceneIntent, tuning: PersonalHRTFTuning = .init(), rate: Double,
                                database: any HRTFDatabase) throws -> PersonalSpatialCoefficients {
        try tuning.validate()
        guard database.supportedSampleRates.contains(rate) else { throw BinauralConvolutionError.invalidConfiguration }
        switch scene {
        case .spatialListening(let listening, let layout):
            try listening.validate()
            let sources = try listening.sources(for: layout).compactMap(\.position)
            return try generic(scene: scene, sources: sources, active: Set(sources.indices),
                listener: listening.placement(for: layout).listener, directionalSource: false,
                tuning: tuning, rate: rate, database: database)
        case .speakerMimic(let mimic):
            try mimic.validate()
            return try compileMimic(mimic, tuning: tuning, rate: rate, database: database)
        }
    }

    private static func compileMimic(_ scene: VirtualSpeakerScene, tuning: PersonalHRTFTuning,
                                     rate: Double, database: any HRTFDatabase) throws -> PersonalSpatialCoefficients {
        if scene.roomModel == .sadieStudio {
            let origin = database.referenceDelayFrames(sampleRate: rate)
            let start = origin + Int(rate * 0.004), end = origin + Int(rate * 0.005)
            var direct: [HRIRPair] = [], room: [HRIRPair] = []
            for role in VirtualSpeakerScene.roles {
                let pair = try database.roomResponse(for: role, sampleRate: rate)
                func split(_ values: [Float]) -> ([Float], [Float]) {
                    var early = Array(values.prefix(end)), tail = values
                    for i in early.indices {
                        let weight = Float(max(0, min(end - start, end - i))) / Float(end - start)
                        early[i] *= weight; tail[i] -= early[i]
                    }
                    return (early, tail)
                }
                let l = split(pair.left), r = split(pair.right)
                direct.append(.init(left: l.0, right: r.0)); room.append(.init(left: l.1, right: r.1))
            }
            if scene.layout.hasSubwoofer {
                // SADIE supplies seven measured speakers, no subwoofer BRIR.
                // An explicitly added generic sub uses only its direct HRIR.
                let source = scene.position(for: .lowFrequencyEffects)
                let distance = SpatialVector3.distance(source, scene.effectiveListener)
                direct.append(try path(source, listener: scene.effectiveListener, gain: 1.5 / distance,
                    delay: Double(distance - 1.5) / 343, wall: false, tuning: .init(), rate: rate, database: database))
                room.append(.init(left: [0], right: [0]))
            }
            return .init(scene: .speakerMimic(scene), sampleRate: rate, referenceDelay: origin,
                profileName: "SADIE II KU100 · Genelec 8030/8040 studio", direct: direct, early: room)
        }
        let roles = VirtualSpeakerScene.roles + (scene.layout.hasSubwoofer ? [.lowFrequencyEffects] : [])
        let activeRoles = Set(scene.layout.speakerRoles)
        let sources = roles.map { scene.position(for: $0) }
        return try generic(scene: .speakerMimic(scene), sources: sources,
            active: Set(roles.indices.filter { activeRoles.contains(roles[$0]) }), listener: scene.listener,
            directionalSource: true, tuning: tuning, rate: rate, database: database)
    }

    /// Both experiences share the same propagation, image paths, measured ear
    /// responses and common time origin. A cabinet adds its emission directivity;
    /// Spatial listening uses an omnidirectional point source without cabinet EQ.
    private static func generic(scene: PersonalSpatialSceneIntent, sources: [SpatialVector3], active: Set<Int>,
                                listener: SpatialVector3, directionalSource: Bool, tuning: PersonalHRTFTuning,
                                rate: Double, database: any HRTFDatabase) throws -> PersonalSpatialCoefficients {
        // Remove only a common propagation delay, preserving source-to-source
        // distances and the measured HRIR's own common time origin.
        let nearest = active.map { SpatialVector3.distance(sources[$0], listener) }.min() ?? 1.2
        let bounds = scene.acoustics.bounds
        let reflectionGain = pow(Float(10), scene.acoustics.earlyReflectionsDB / 20)
        var direct: [HRIRPair] = [], early: [HRIRPair] = []
        for (index, source) in sources.enumerated() {
            guard active.contains(index) else {
                direct.append(.init(left: [0], right: [0])); early.append(.init(left: [0], right: [0]))
                continue
            }
            let distance = SpatialVector3.distance(source, listener)
            let directGain: Float = 1.2 / distance
            direct.append(try path(source, listener: listener, gain: directGain,
                delay: Double(distance - nearest) / 343, wall: false, tuning: tuning, rate: rate, database: database))
            var reflections: [HRIRPair] = []
            // Six first-order image sources in the independently saved room.
            // Pressure reflection is sqrt(1 - absorption).
            for axis in 0..<3 {
                let walls: [Float] = axis == 0 ? [bounds.minimum.x, bounds.maximum.x]
                    : axis == 1 ? [bounds.minimum.y, bounds.maximum.y] : [bounds.minimum.z, bounds.maximum.z]
                for wall in walls {
                    var image = source
                    if axis == 0 { image.x = 2 * wall - source.x }
                    if axis == 1 { image.y = 2 * wall - source.y }
                    if axis == 2 { image.z = 2 * wall - source.z }
                    let length = SpatialVector3.distance(image, listener)
                    let loss = sqrt(Float(1 - (axis == 2 ? 0.65 : 0.55)))
                    // The speaker faces the listener. Reflect the listener to get
                    // the path's emission direction, independently of ear arrival.
                    var target = listener
                    if axis == 0 { target.x = 2 * wall - target.x }
                    if axis == 1 { target.y = 2 * wall - target.y }
                    if axis == 2 { target.z = 2 * wall - target.z }
                    let forward = SpatialVector3(x: listener.x - source.x, y: listener.y - source.y, z: listener.z - source.z)
                    let emitted = SpatialVector3(x: target.x - source.x, y: target.y - source.y, z: target.z - source.z)
                    let cosine = (forward.x * emitted.x + forward.y * emitted.y + forward.z * emitted.z) / (distance * length)
                    let pair = try path(image, listener: listener,
                        gain: reflectionGain * loss * 1.2 / length,
                        delay: Double(length - nearest) / 343, wall: true, emissionCosine: directionalSource ? cosine : 1,
                        tuning: tuning, rate: rate, database: database)
                    reflections.append(pair)
                }
            }
            early.append(sum(reflections))
        }
        return .init(scene: scene, sampleRate: rate, referenceDelay: database.referenceDelayFrames(sampleRate: rate),
            profileName: database.profileName, direct: direct, early: early)
    }

    private static func path(_ source: SpatialVector3, listener: SpatialVector3, gain: Float,
                             delay: Double, wall: Bool, emissionCosine: Float = 1,
                             tuning: PersonalHRTFTuning, rate: Double, database: any HRTFDatabase) throws -> HRIRPair {
        let p = SpeakerLayoutGeometry.position(x: source.x - listener.x, y: source.y - listener.y, height: source.z - listener.z)
        let measured = try database.hrir(for: .init(azimuthDegrees: p.azimuthDegrees, elevationDegrees: p.elevationDegrees,
            distanceMeters: p.distanceMeters!), sampleRate: rate)
        let h = try PersonalHRTFAdjustment.apply(measured, tuning: tuning, rate: rate)
        // Frequency-dependent pressure loss; direct response is unfiltered.
        func shape(_ input: [Float], extraDelay: Double) -> [Float] {
            let samples = (delay + extraDelay) * rate
            let whole = Int(floor(samples)), fraction = Float(samples - floor(samples))
            let shapedFrames = input.count + (wall ? Int(ceil(rate * 0.006)) : 0)
            var output = [Float](repeating: 0, count: shapedFrames + whole + 2)
            let coefficient = Float(1 - exp(-2 * .pi * 5500 / rate))
            let emissionLowpass = Float(1 - exp(-2 * .pi * 900 / rate))
            // Generic subcardioid above 900 Hz, omnidirectional bass. This
            // bounded model is not measured directivity of a selected speaker.
            let emissionGain = 0.65 + 0.35 * max(-1, min(1, emissionCosine))
            var low: Float = 0, emissionLow: Float = 0
            for n in 0..<shapedFrames {
                let raw: Float = n < input.count ? input[n] : 0
                emissionLow += emissionLowpass * (raw - emissionLow)
                let emitted = wall ? emissionLow + emissionGain * (raw - emissionLow) : raw
                low += coefficient * (emitted - low)
                let value = gain * (wall ? 0.25 * emitted + 0.75 * low : emitted)
                output[n + whole] += value * (1 - fraction)
                output[n + whole + 1] += value * fraction
            }
            return output
        }
        return .init(left: shape(h.left, extraDelay: h.leftDelaySeconds), right: shape(h.right, extraDelay: h.rightDelaySeconds))
    }
    private static func sum(_ paths: [HRIRPair]) -> HRIRPair {
        let count = paths.map { max($0.left.count, $0.right.count) }.max() ?? 1
        var left = [Float](repeating: 0, count: count), right = left
        for p in paths {
            for i in p.left.indices { left[i] += p.left[i] }
            for i in p.right.indices { right[i] += p.right[i] }
        }
        return .init(left: left, right: right)
    }
}

/// Diffuse late field: orthogonal eight-line feedback, frequency-dependent
/// damping, adjustable low-frequency T60, and different signed ear projections.
/// Starts after the retained first-order paths; no direct duplication.
private final class PersonalLateRoom {
    private struct DelayLine {
        let samples: SpatialSampleBuffer
        let feedback: Float
        var cursor = 0
        var low: Float = 0
    }
    private var lines: [DelayLine]
    private let damping: Float
    private let diffusionCosine: Float
    private let diffusionSine: Float
    private let preDelay: SpatialSampleBuffer
    private let scratch = SpatialSampleBuffer(count: 8)
    private var preCursor = 0
    init(rate: Double, decay: Float, roomSize: Float, diffusion: Float, preDelaySeconds: Double) {
        let seconds = [0.0137, 0.0179, 0.0197, 0.0233, 0.0299, 0.0317, 0.0371, 0.0411].map { $0 * Double(roomSize) }
        lines = seconds.map { DelayLine(samples: .init(count: Int(rate * $0)), feedback: Float(pow(0.001, $0 / Double(decay)))) }
        damping = Float(1 - exp(-2 * .pi * 4500 / rate))
        diffusionCosine = cos(diffusion * .pi / 4)
        diffusionSine = sin(diffusion * .pi / 4)
        preDelay = .init(count: Int(ceil(rate * preDelaySeconds)) + 128)
    }
    func reset() {
        for i in lines.indices { lines[i].samples.clear(); lines[i].cursor = 0; lines[i].low = 0 }
        preDelay.clear(); preCursor = 0
    }
    /// Borrow the delay histories once per tile. The feedback, summation order
    /// and every delay length are identical to the scalar implementation.
    func process(_ source: UnsafePointer<Float>, count: Int,
                 left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let taps = scratch.pointer, delayed = preDelay.pointer, preCount = preDelay.count
        var position = preCursor
        lines.withUnsafeMutableBufferPointer { lines in
            for n in 0..<count {
                let input = delayed[position]
                delayed[position] = source[n]; position += 1
                if position == preCount { position = 0 }
                var l: Float = 0, r: Float = 0
                for i in 0..<8 {
                    taps[i] = lines[i].samples.pointer[lines[i].cursor]
                    l += taps[i] * (i % 2 == 0 ? 1 : -1)
                    r += taps[i] * (i % 4 < 2 ? 1 : -1)
                }
                // Orthogonal butterflies change density without changing
                // feedback energy or the user's decay time.
                for stage in 0..<3 {
                    let step = 1 << stage
                    for start in stride(from: 0, to: 8, by: step * 2) {
                        for offset in 0..<step {
                            let a = start + offset, b = a + step, x = taps[a], y = taps[b]
                            taps[a] = diffusionCosine * x + diffusionSine * y
                            taps[b] = -diffusionSine * x + diffusionCosine * y
                        }
                    }
                }
                for i in 0..<8 {
                    lines[i].low += damping * (taps[i] - lines[i].low)
                    lines[i].samples.pointer[lines[i].cursor] = 0.3535534 * input + lines[i].feedback * lines[i].low
                    lines[i].cursor += 1
                    if lines[i].cursor == lines[i].samples.count { lines[i].cursor = 0 }
                }
                left[n] = l * 0.28; right[n] = r * 0.28
            }
        }
        preCursor = position
    }
}

/// One cabinet owns its filter, bass split and convolution histories. These
/// scalar histories are never copied through parallel arrays in the sample loop.
private final class PersonalVirtualSpeaker {
    private let convolution: BinauralConvolver
    let roomHistoryFrames: Int
    private let finiteTail: Int
    private var remainingTail = 0
    private var filter = PerAppFilterBank()
    private var crossover = SpatialLowPass()

    init(direct: HRIRPair, early: HRIRPair, rate: Double, phase: Int, bands: [EQBand], crossoverHz: Float) throws {
        // A generic sub added to the measured studio has no recorded room
        // response. A zero response needs neither FFT storage nor rendering.
        let hasRoom = early.left.contains { $0 != 0 } || early.right.contains { $0 != 0 }
        convolution = try BinauralConvolver(hrir: direct, roomResponse: hasRoom ? early : nil,
            sampleRate: rate, schedulingPhase: phase)
        roomHistoryFrames = hasRoom ? convolution.historyFrameCount : 0
        finiteTail = convolution.historyFrameCount + 256
        filter.prepare(channelCount: 1, sampleRate: rate, bands: bands)
        crossover.prepare(rate: rate, cutoff: Double(crossoverHz))
    }
    func reset() {
        convolution.reset(); filter.reset(); crossover.reset()
        remainingTail = 0
    }
    /// Each source/filter keeps its own chronological history. Borrowing a tile
    /// avoids reference counting and exclusive-access checks per audio sample.
    func process(_ input: UnsafeMutableBufferPointer<Float>, redirectBass: Bool,
                 redirected: UnsafeMutablePointer<Float>, excitation: UnsafeMutablePointer<Float>,
                 room: UnsafePointer<Float>, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        if redirectBass {
            for n in input.indices {
                let low = crossover.process(input[n])
                input[n] -= low; redirected[n] += low
            }
        }
        filter.processPrepared(input)
        for n in input.indices { excitation[n] += input[n] }
        left.update(repeating: 0, count: input.count); right.update(repeating: 0, count: input.count)
        func render(_ range: Range<Int>) {
            _ = convolution.process(source: .init(start: input.baseAddress!.advanced(by: range.lowerBound), count: range.count),
                left: .init(start: left.advanced(by: range.lowerBound), count: range.count),
                right: .init(start: right.advanced(by: range.lowerBound), count: range.count),
                roomGains: .init(start: room.advanced(by: range.lowerBound), count: range.count))
        }
        // A tile is at most 256 frames, shorter than a source's finite tail.
        // Only the old tail can expire here; after a new nonzero sample the
        // rest of this tile is one continuous convolution interval.
        let first = input.firstIndex { $0 != 0 }
        let end = min(remainingTail, input.count)
        if let first, first < end {
            render(0..<input.count)
        } else {
            if end > 0 { render(0..<end) }
            if remainingTail > 0, end == remainingTail { convolution.reset() }
            if let first { render(first..<input.count) }
        }
        if let first {
            let last = input[(first + 1)...].lastIndex(where: { $0 != 0 }) ?? first
            remainingTail = finiteTail - (input.count - 1 - last)
        } else {
            remainingTail = max(0, remainingTail - input.count)
        }
    }

}

package final class PersonalVirtualSpeakerRenderer {
    package let coefficients: PersonalSpatialCoefficients
    package let latencyFrames: Int
    package let tailFrames: Int
    package let warmupFrames: Int
    private let speakers: [PersonalVirtualSpeaker]
    private let late: PersonalLateRoom?
    private var room = SpatialScalarSmoother()
    private var automaticLateGain: Float = 1
    private let workspace = SpatialSampleBuffer(count: 256 * 9)
    private var bass = BassManager()
    private var bassDelay: [Float]
    private var bassCursor = 0
    private var headphoneEQ = PerAppFilterBank()
    private let headphoneBands: [EQBand]
    private let headphoneGain: Float
    private var sends: [[(Int, Float)]] = []
    private var lfeIndices: [Int] = []
    private let subwooferIndex: Int?
    private let subGain: Float
    private var layout: LPCMChannelLayout?

    package init(_ coefficients: PersonalSpatialCoefficients, playbackDevice: SpatialPlaybackDevice? = nil, schedulingPhase: Int = 0) throws {
        try playbackDevice?.validate()
        self.coefficients = coefficients
        let rate = coefficients.sampleRate
        let bands: [[EQBand]]
        let crossoverHz: Float
        switch coefficients.scene {
        case .spatialListening:
            bands = Array(repeating: [], count: coefficients.direct.count)
            subwooferIndex = nil
            crossoverHz = 80
            subGain = 1
        case .speakerMimic(let scene):
            let roles = VirtualSpeakerScene.roles + (scene.layout.hasSubwoofer ? [.lowFrequencyEffects] : [])
            bands = roles.map { role in
                role == .lowFrequencyEffects ? scene.subwoofer.bands
                    : scene.layout.roles.contains(role) ? scene.speaker(for: role)?.bands ?? [] : []
            }
            subwooferIndex = scene.layout.hasSubwoofer ? roles.count - 1 : nil
            crossoverHz = scene.crossoverHz
            subGain = pow(10, scene.subwooferDB / 20)
        }
        speakers = try coefficients.direct.indices.map { index in
            return try PersonalVirtualSpeaker(direct: coefficients.direct[index], early: coefficients.early[index], rate: rate,
                phase: index * 512 + schedulingPhase, bands: bands[index], crossoverHz: crossoverHz)
        }
        latencyFrames = 128 + coefficients.referenceDelay
        warmupFrames = max(Int(rate * 0.08), speakers.map { $0.roomHistoryFrames + 128 }.max() ?? 0)
        // The validated correction is bounded to 20 Hz / Q 6 / +6 dB. Three
        // seconds covers its slowest pole below -140 dB without cutting tails.
        let correctionTail: Double = playbackDevice?.filters.isEmpty == false ? 3 : 0
        tailFrames = max(warmupFrames, Int(rate * max(0.9, correctionTail, Double(coefficients.scene.acoustics.decaySeconds) * 2 + 0.2)))
        bassDelay = .init(repeating: 0, count: latencyFrames)
        let reflectionSeconds = Double(coefficients.early.map { max($0.left.count, $0.right.count) }.max() ?? 0) / rate
        late = !coefficients.scene.isMeasured ? PersonalLateRoom(rate: rate, decay: coefficients.scene.acoustics.decaySeconds,
            roomSize: coefficients.scene.acoustics.size, diffusion: coefficients.scene.acoustics.diffusion,
            preDelaySeconds: max(0.04, reflectionSeconds)) : nil
        headphoneBands = playbackDevice?.filters ?? []
        headphoneGain = Float(pow(10, PerAppAudioSettings(eqBypassed: false, equalizerBands: headphoneBands).automaticHeadroomDB(sampleRate: rate) / 20))
        // Prepare coefficient/state storage here, on the preparation worker.
        var empty: [Float] = []
        headphoneEQ.process(&empty, channelCount: 2, sampleRate: rate, bands: headphoneBands, settingsRevision: 0)
        room.prepare(sampleRate: rate, seconds: 0.03)
        bass.prepare(sampleRate: rate)
    }
    package func reset() {
        speakers.forEach { $0.reset() }; late?.reset(); bass.reset()
        for i in bassDelay.indices { bassDelay[i] = 0 }; bassCursor = 0
        room.reset(); headphoneEQ.reset(); layout = nil
        automaticLateGain = 1
    }
    package static func supports(_ frame: PCMFrame) -> Bool {
        frame.channelCount > 0 && frame.channelLayout.channelCount == frame.channelCount &&
            frame.interleaved.count.isMultiple(of: frame.channelCount) &&
            (try? frame.channelLayout.validate()) != nil && frame.channelLayout.roles.indices.allSatisfy {
                frame.channelLayout.roles[$0] != .unknown || frame.channelLayout.positions?[$0] != nil
            }
    }

    private func routing(for input: LPCMChannelLayout) -> [[(Int, Float)]]? {
        switch coefficients.scene {
        case .spatialListening(_, let prepared):
            let destinations = prepared.roles.indices.filter { prepared.roles[$0] != .lowFrequencyEffects }
            var result = Array(repeating: [(Int, Float)](), count: destinations.count)
            if input.signalSignature == prepared.signalSignature {
                for (index, source) in destinations.enumerated() { result[index] = [(source, Float(1))] }
                return result
            }
            // Known subsets and alternate order can use the prepared bus. A
            // repeated/custom occurrence must match exactly to avoid guessing.
            guard !input.roles.contains(.unknown), Set(input.roles).count == input.roles.count,
                  Set(prepared.roles).count == prepared.roles.count else { return nil }
            for (source, role) in input.roles.enumerated() {
                guard let target = prepared.roles.firstIndex(of: role), input.positions?[source] == prepared.positions?[target] else { return nil }
                if role != .lowFrequencyEffects, let path = destinations.firstIndex(of: target) {
                    result[path].append((source, 1))
                }
            }
            return result
        case .speakerMimic(let scene):
            var matrix = VirtualSpeakerRouting.matrix(input: input.roles, scene: scene)
            if let positions = input.positions, positions.contains(where: { $0 != nil }) {
                let destinations = scene.layout.roles
                let solver = VBAPSolver(positions: destinations.map {
                    let p = scene.position(for: $0), l = scene.effectiveListener
                    return SpeakerLayoutGeometry.position(x: p.x - l.x, y: p.y - l.y, height: p.z - l.z)
                })
                for source in positions.indices where input.roles[source] != .lowFrequencyEffects {
                    guard let position = positions[source] else { continue }
                    for path in matrix.indices { matrix[path][source] = 0 }
                    let gains = solver.gains(for: position).gains
                    for (index, role) in destinations.enumerated() {
                        matrix[VirtualSpeakerScene.roles.firstIndex(of: role)!][source] = gains[index]
                    }
                }
            }
            return matrix.map { row in row.enumerated().compactMap { $0.element == 0 ? nil : ($0.offset, $0.element) } }
        }
    }

    /// The prepared routing owns layout validation. Signal shape is checked for
    /// every block; unchanged layout metadata reuses the validated sends.
    package func accepts(_ frame: PCMFrame) -> Bool {
        guard frame.sampleRate == coefficients.sampleRate, frame.channelCount > 0,
              frame.channelCount == frame.channelLayout.channelCount,
              frame.interleaved.count.isMultiple(of: frame.channelCount) else { return false }
        if layout != frame.channelLayout {
            guard Self.supports(frame), let routing = routing(for: frame.channelLayout) else { return false }
            sends = routing
            lfeIndices = frame.channelLayout.roles.indices.filter { frame.channelLayout.roles[$0] == .lowFrequencyEffects }
            layout = frame.channelLayout
        }
        return true
    }

    package func render(_ frame: PCMFrame, room target: Float, lateRoomGain: Float = 1, smoothing: MovieControlSmoothing? = nil) -> PCMFrame? {
        guard accepts(frame) else { return nil }
        let usesSubwoofer = subwooferIndex != nil
        let roomTarget = SpatialRenderIntent.unit(target)
        var output = [Float](repeating: 0, count: frame.frameCount * 2)
        let source = workspace.pointer, roomGains = source.advanced(by: 256)
        let renderedLeft = roomGains.advanced(by: 256), renderedRight = renderedLeft.advanced(by: 256)
        let redirected = renderedRight.advanced(by: 256), excitation = redirected.advanced(by: 256)
        let lfe = excitation.advanced(by: 256), sumLeft = lfe.advanced(by: 256), sumRight = sumLeft.advanced(by: 256)
        frame.interleaved.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                for start in stride(from: 0, to: frame.frameCount, by: 256) {
                    let count = min(256, frame.frameCount - start)
                    redirected.update(repeating: 0, count: count); excitation.update(repeating: 0, count: count)
                    sumLeft.update(repeating: 0, count: count); sumRight.update(repeating: 0, count: count)
                    for n in 0..<count {
                        let amount = room.next(roomTarget)
                        // Generic Room has 6 dB steps at 25/50/100%; the measured
                        // studio retains its recorded unity mix at 100%.
                        roomGains[n] = late == nil ? amount : 2 * amount
                        var low: Float = 0
                        for index in lfeIndices { low += SpatialSafety.sample(input[(start + n) * frame.channelCount + index]) }
                        lfe[n] = bass.process(low)
                    }
                    func render(_ speaker: PersonalVirtualSpeaker, redirectBass: Bool) {
                        speaker.process(.init(start: source, count: count), redirectBass: redirectBass,
                            redirected: redirected, excitation: excitation, room: roomGains,
                            left: renderedLeft, right: renderedRight)
                        for n in 0..<count { sumLeft[n] += renderedLeft[n]; sumRight[n] += renderedRight[n] }
                    }
                    for index in sends.indices {
                        sends[index].withUnsafeBufferPointer { routing in
                            for n in 0..<count {
                                var value: Float = 0
                                for (channel, gain) in routing { value += gain * SpatialSafety.sample(input[(start + n) * frame.channelCount + channel]) }
                                source[n] = value
                            }
                        }
                        render(speakers[index], redirectBass: usesSubwoofer)
                    }
                    if let subwooferIndex {
                        for n in 0..<count { source[n] = subGain * (redirected[n] + lfe[n]) }
                        render(speakers[subwooferIndex], redirectBass: false)
                    }
                    // Reuse the source output scratch after all sources have
                    // contributed. Automatic gain affects only the diffuse field.
                    if let late { late.process(excitation, count: count, left: renderedLeft, right: renderedRight) }
                    else { renderedLeft.update(repeating: 0, count: count); renderedRight.update(repeating: 0, count: count) }
                    for n in 0..<count {
                        if let smoothing { smoothing.advance(&automaticLateGain, toward: lateRoomGain) }
                        let low = bassDelay[bassCursor]
                        bassDelay[bassCursor] = usesSubwoofer ? 0 : lfe[n]
                        bassCursor = (bassCursor + 1) % bassDelay.count
                        output[2 * (start + n)] = 0.5 * (sumLeft[n] + roomGains[n] * automaticLateGain * renderedLeft[n] + low)
                        output[2 * (start + n) + 1] = 0.5 * (sumRight[n] + roomGains[n] * automaticLateGain * renderedRight[n] + low)
                    }
                }
            }
        }
        headphoneEQ.process(&output, channelCount: 2, sampleRate: frame.sampleRate, bands: headphoneBands, settingsRevision: 0)
        if headphoneGain != 1 { for i in output.indices { output[i] *= headphoneGain } }
        return .init(interleaved: output, channelCount: 2, sampleRate: frame.sampleRate, channelLayout: .stereo)
    }
}
