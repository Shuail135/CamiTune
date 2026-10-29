import CamiTuneDomain
import Foundation

package struct SpatialCalibrationClip: Sendable {
    package static let subwooferTestGainRangeDB: ClosedRange<Double> = -6...6
    package let samples: [Float]
    package let sampleRate: Double
    package let isAcousticMeasurement: Bool
    package var physicalOutput: PhysicalOutputID? = nil
    package var measurementReferenceOutput: PhysicalOutputID? = nil
    package var physicalLayout: LPCMChannelLayout? = nil
    package var channelCount: Int { physicalLayout?.channelCount ?? 2 }
    package private(set) var virtualSource: (index: Int, layout: LPCMChannelLayout)? = nil
    package private(set) var repeatsUntilStopped = false
    package var loops: Bool { repeatsUntilStopped }
    package var isVirtualAudition: Bool { virtualSource != nil }

    /// Bounded, finite, tapered physical-channel probe. Prepared off the audio worker.
    package init?(physicalOutput: PhysicalOutputID, topology: SpeakerTopology, subwooferTestGainDB: Double = 0) {
        guard (try? topology.validate()) != nil, physicalOutput.deviceUID == topology.deviceUID,
              let endpoint = topology.endpoints.first(where: { $0.id == physicalOutput }),
              endpoint.connectionState != .disabledByUser,
              !endpoint.isSubwooferLike || subwooferTestGainDB.isFinite,
              (8000...192000).contains(topology.sampleRate) else { return nil }
        sampleRate = topology.sampleRate
        isAcousticMeasurement = true
        self.physicalOutput = physicalOutput
        var roles = [ChannelRole](repeating: .unknown, count: topology.declaredChannelCount)
        for endpoint in topology.endpoints { roles[endpoint.id.channelIndex] = endpoint.role }
        physicalLayout = LPCMChannelLayout(coreAudioTag: 0, roles: roles)
        let count = topology.declaredChannelCount
        let frames = Int(sampleRate * 1.5)
        let fade = max(1, Int(sampleRate * 0.05))
        var result = [Float](repeating: 0, count: frames * count)
        var random: UInt32 = 0x43414D49
        var high: Float = 0, low: Float = 0
        let isSub = endpoint.isSubwooferLike
        let upper = Float(1 - exp(-2 * Double.pi * 4000 / sampleRate))
        let lower = Float(1 - exp(-2 * Double.pi * 300 / sampleRate))
        let peakLimit: Float = 0.25
        var sumSquares = 0.0
        var peak: Float = 0
        for i in 0..<frames {
            let signal: Float
            if isSub {
                // Narrow-band filtered noise loses most of its level, especially
                // at high sample rates. A bass tone concentrates identification
                // energy below typical subwoofer crossovers.
                signal = Float(sin(2 * Double.pi * 60 * Double(i) / sampleRate)) * 0.02
            } else {
                random = 1664525 &* random &+ 1013904223
                let white = Float(random) / Float(UInt32.max) * 2 - 1
                high += upper * (white - high)
                low += lower * (high - low)
                signal = (high - low) * 0.02
            }
            let envelope = min(1, Float(min(i, frames-1-i)) / Float(fade))
            let sample = signal * envelope
            result[i * count + physicalOutput.channelIndex] = sample
            sumSquares += Double(sample) * Double(sample)
            peak = max(peak, abs(sample))
        }
        // Match the complete, faded identification clips to -26 dBFS RMS
        // by default, with an optional test-only subwoofer adjustment. Measure
        // only the selected channel so unused outputs do not change its level.
        // Limit gain rather than clipping peaks, preserving the signal shape.
        let rms = sqrt(sumSquares / Double(frames))
        if rms > 0, peak > 0 {
            let testGainDB = isSub ? min(Self.subwooferTestGainRangeDB.upperBound,
                max(Self.subwooferTestGainRangeDB.lowerBound, subwooferTestGainDB)) : 0
            let targetRMS = pow(10, (-26 + testGainDB) / 20)
            let gain = Float(min(targetRMS / rms, Double(peakLimit / peak)))
            for i in 0..<frames {
                result[i * count + physicalOutput.channelIndex] *= gain
            }
        }
        samples = result
    }

    /// Broadband, tapered noise excites the pinna cues missing from a low chime.
    /// Generate off the UI/audio workers before handing the prepared clip to PCM.
    package init?(spatialCheck channel: Int, layout: LPCMChannelLayout, sampleRate: Double) {
        guard (try? layout.validate()) != nil, layout.roles.indices.contains(channel), sampleRate.isFinite,
              (8000...192000).contains(sampleRate) else { return nil }
        self.sampleRate = sampleRate; isAcousticMeasurement = false
        virtualSource = (channel, layout)
        let role = layout.roles[channel]
        var random: UInt32 = 0x53414449
        var low: Float = 0, high: Float = 0
        let lowCoefficient = Float(1 - exp(-2 * Double.pi * 200 / sampleRate))
        let highCoefficient = Float(1 - exp(-2 * Double.pi * min(12000, sampleRate * 0.4) / sampleRate))
        let frames = Int(sampleRate * 4)
        let level: Float = role == .lowFrequencyEffects ? 0.2 : 0.05
        var result = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let signal: Float
            if role == .lowFrequencyEffects {
                // A bass tone stays audible and rate-independent after the LFE
                // send; narrow-band white noise becomes too quiet at high rates.
                signal = Float(sin(2 * .pi * 60 * Double(i) / sampleRate))
            } else {
                random = 1664525 &* random &+ 1013904223
                let white = Float(random) / Float(UInt32.max) * 2 - 1
                high += highCoefficient * (white - high)
                low += lowCoefficient * (high - low)
                signal = high - low
            }
            let phase = Double(i).truncatingRemainder(dividingBy: sampleRate) / sampleRate
            let envelope = Float(min(1, max(0, min(phase / 0.06, (0.7 - phase) / 0.06))))
            let x = signal * envelope * level
            result[2 * i] = x; result[2 * i + 1] = x
        }
        samples = result
    }


    package init?(roomMeasurement: [Float], physicalOutput: PhysicalOutputID, topology: SpeakerTopology, repeatsUntilStopped: Bool = false, markerChannel: Int? = nil) {
        guard (try? topology.validate()) != nil, physicalOutput.deviceUID == topology.deviceUID,
              topology.endpoints.contains(where: { $0.id == physicalOutput && $0.connectionState != .disabledByUser }),
              (8000...192000).contains(topology.sampleRate), !roomMeasurement.isEmpty,
              roomMeasurement.count <= Int(topology.sampleRate * 12),
              roomMeasurement.allSatisfy({ $0.isFinite && abs($0) <= RoomMeasurementSignal.maximumSourcePeak }) else { return nil }
        self.sampleRate = topology.sampleRate; self.isAcousticMeasurement = true; self.physicalOutput = physicalOutput
        self.repeatsUntilStopped = repeatsUntilStopped
        if let markerChannel {
            guard topology.endpoints.contains(where: { $0.id.channelIndex == markerChannel && !$0.isSubwooferLike && $0.connectionState != .disabledByUser }) else { return nil }
            measurementReferenceOutput = .init(deviceUID: topology.deviceUID, channelIndex: markerChannel)
        }
        var roles = [ChannelRole](repeating: .unknown, count: topology.declaredChannelCount)
        for endpoint in topology.endpoints { roles[endpoint.id.channelIndex] = endpoint.role }
        self.physicalLayout = LPCMChannelLayout(coreAudioTag: 0, roles: roles)
        var interleaved = [Float](repeating: 0, count: roomMeasurement.count * roles.count)
        for i in roomMeasurement.indices {
            let time = Double(i) / topology.sampleRate
            let isMarker = time < RoomMeasurementSignal.sweepStart || time >= RoomMeasurementSignal.endMarkerStart
            let channel = isMarker ? (markerChannel ?? physicalOutput.channelIndex) : physicalOutput.channelIndex
            interleaved[i * roles.count + channel] = roomMeasurement[i]
        }
        self.samples = interleaved
    }

    package init?(measurementSamples: [Float], sampleRate: Double) {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              !measurementSamples.isEmpty, measurementSamples.count.isMultiple(of: 2),
              measurementSamples.count <= Int(sampleRate * 12) * 2,
              measurementSamples.allSatisfy({ $0.isFinite && abs($0) <= 0.030001 }) else { return nil }
        samples = measurementSamples
        self.sampleRate = sampleRate
        isAcousticMeasurement = true
    }
}

package struct SpatialCalibrationPlayback {
    package let clip: SpatialCalibrationClip
    package let completion: @Sendable () -> Void
    private let started: (@Sendable (TimeInterval) -> Void)?
    private var cursor = 0
    private var fadeStart: Int?
    private var stopAt: Int?
    private var levelCheckGain: Float = 1
    private var targetLevelCheckGain: Float = 1
    private var gainRampFrames = 0

    package init(clip: SpatialCalibrationClip, levelCheckGain: Float = 1, started: (@Sendable (TimeInterval) -> Void)? = nil, completion: @escaping @Sendable () -> Void) {
        self.clip = clip
        self.started = started
        self.completion = completion
        if clip.repeatsUntilStopped {
            self.levelCheckGain = levelCheckGain.isFinite ? min(1, max(0, levelCheckGain)) : 0
            self.targetLevelCheckGain = self.levelCheckGain
        }
    }

    /// Attenuation of a clip already prepared at its safe ceiling. Never boost
    /// above that ceiling or change a recorded measurement's calibrated gain.
    package mutating func setLevelCheckGain(_ gain: Float) {
        guard clip.repeatsUntilStopped, stopAt == nil, gain.isFinite else { return }
        targetLevelCheckGain = min(1, max(0, gain))
        gainRampFrames = max(1, Int(clip.sampleRate * 0.03))
    }

    package var isFinished: Bool {
        if let stopAt { return cursor >= stopAt }
        return !clip.loops && cursor >= clip.samples.count
    }

    package mutating func requestStop() {
        guard stopAt == nil else { return }
        fadeStart = cursor
        let fadeEnd = cursor + max(2, Int(clip.sampleRate * 0.025) * clip.channelCount)
        stopAt = !clip.loops ? min(clip.samples.count, fadeEnd) : fadeEnd
    }

    package mutating func nextFrame() -> PCMFrame? {
        guard !isFinished else { return nil }
        if cursor == 0 { started?(ProcessInfo.processInfo.systemUptime) }
        let blockSamples = 512 * clip.channelCount
        let end = min(stopAt ?? (!clip.loops ? clip.samples.count : cursor + blockSamples), cursor + blockSamples)
        var samples = (cursor..<end).map { clip.samples[$0 % clip.samples.count] }
        if clip.repeatsUntilStopped {
            for index in stride(from: 0, to: samples.count, by: clip.channelCount) {
                if gainRampFrames > 0 {
                    levelCheckGain += (targetLevelCheckGain - levelCheckGain) / Float(gainRampFrames)
                    gainRampFrames -= 1
                }
                for channel in 0..<clip.channelCount { samples[index + channel] *= levelCheckGain }
            }
        }
        if clip.loops {
            let fadeFrames = max(1, Int(clip.sampleRate * 0.12))
            let channels = clip.channelCount
            for index in stride(from: 0, to: samples.count, by: channels) {
                let gain = min(1, Float((cursor + index) / channels) / Float(fadeFrames))
                for channel in 0..<channels { samples[index + channel] *= gain }
            }
        }
        if let fadeStart, let stopAt {
            let count = clip.channelCount
            let frames = max(1, (stopAt - fadeStart) / count - 1)
            for index in stride(from: 0, to: samples.count, by: count) {
                let remaining = max(0, (stopAt - cursor - index) / count - 1)
                let gain = min(1, Float(remaining) / Float(frames))
                for channel in 0..<count { samples[index + channel] *= gain }
            }
        }
        cursor = end
        if let source = clip.virtualSource {
            let count = source.layout.channelCount
            var bed = [Float](repeating: 0, count: samples.count / 2 * count)
            for i in 0..<(samples.count / 2) { bed[i * count + source.index] = samples[i * 2] }
            return PCMFrame(interleaved: bed, channelCount: count, sampleRate: clip.sampleRate, channelLayout: source.layout)
        }
        return PCMFrame(interleaved: samples, channelCount: clip.channelCount, sampleRate: clip.sampleRate, channelLayout: clip.physicalLayout)
    }
}
