import AVFoundation
import Combine
import Foundation

/// Prepared off the audio thread and replayed identically for every A/B trial.
/// The voice peaks at -20 dBFS before the existing master volume and limiter.
struct SpatialCalibrationClip: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let isAcousticMeasurement: Bool
    var virtualSpeakerRole: ChannelRole? = nil
    var virtualSurroundDemo = false
    var isVirtualAudition: Bool { virtualSpeakerRole != nil || virtualSurroundDemo }

    /// Broadband, tapered noise excites the pinna cues missing from a low chime.
    /// Generate off the UI/audio workers before handing the prepared clip to PCM.
    init?(spatialCheck role: ChannelRole, sampleRate: Double) {
        guard VirtualSurroundLayout.roles.contains(role), sampleRate.isFinite,
              (8000...192000).contains(sampleRate) else { return nil }
        self.sampleRate = sampleRate; isAcousticMeasurement = false; virtualSpeakerRole = role
        var random: UInt32 = 0x53414449
        var low: Float = 0, high: Float = 0
        let lowCoefficient = Float(1 - exp(-2 * Double.pi * 200 / sampleRate))
        let highCoefficient = Float(1 - exp(-2 * Double.pi * min(12000, sampleRate * 0.4) / sampleRate))
        let frames = Int(sampleRate * 4)
        var result = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            random = 1664525 &* random &+ 1013904223
            let white = Float(random) / Float(UInt32.max) * 2 - 1
            high += highCoefficient * (white - high)
            low += lowCoefficient * (high - low)
            let phase = Double(i).truncatingRemainder(dividingBy: sampleRate) / sampleRate
            let envelope = Float(min(1, max(0, min(phase / 0.06, (0.7 - phase) / 0.06))))
            let x = (high - low) * envelope * 0.05
            result[2 * i] = x; result[2 * i + 1] = x
        }
        samples = result
    }

    init?(virtualSpeaker role: ChannelRole, sampleRate: Double) {
        guard VirtualSurroundLayout.roles.contains(role), sampleRate.isFinite,
              (8_000...192_000).contains(sampleRate) else { return nil }
        self.sampleRate = sampleRate
        isAcousticMeasurement = false
        virtualSpeakerRole = role
        var result: [Float] = []
        result.reserveCapacity(Int(sampleRate * 8) * 2)
        for i in 0..<Int(sampleRate * 8) {
            let time = Double(i) / sampleRate
            // Integer-frequency harmonics repeat seamlessly over eight seconds.
            // No random texture, pulsing, or automatic spatial motion.
            let chime = Float(0.55 * sin(2 * Double.pi * 440 * time)
                + 0.25 * sin(2 * Double.pi * 880 * time)
                + 0.10 * sin(2 * Double.pi * 1320 * time))
            let source = role == .lowFrequencyEffects ? Float(sin(2 * Double.pi * 70 * time)) : chime
            let sample = source * 0.10
            result.append(sample); result.append(sample)
        }
        samples = result
    }

    init?(monoSpeech: [Float], speechSampleRate: Double, sampleRate: Double) {
        guard speechSampleRate.isFinite, (8_000...384_000).contains(speechSampleRate),
              sampleRate.isFinite, (8_000...384_000).contains(sampleRate),
              !monoSpeech.isEmpty else { return nil }
        let speech = monoSpeech.prefix(Int(speechSampleRate * 12)).map { $0.isFinite ? $0 : 0 }
        let peak = speech.reduce(Float.zero) { max($0, abs($1)) }
        guard peak > 0.000001 else { return nil }
        self.sampleRate = sampleRate
        isAcousticMeasurement = false
        let count = max(1, Int(Double(speech.count) * sampleRate / speechSampleRate))
        let fade = max(1, Int(sampleRate * 0.025))
        var result = [Float](repeating: 0, count: Int(sampleRate * 0.15) * 2)
        result.reserveCapacity((count + Int(sampleRate * 1.5)) * 2)
        for index in 0..<count {
            let position = Double(index) * speechSampleRate / sampleRate
            let lower = min(speech.count - 1, Int(position))
            let upper = min(speech.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            let envelope = min(1, Float(min(index, count - 1 - index)) / Float(fade))
            let value = (speech[lower] + (speech[upper] - speech[lower]) * fraction)
                * (0.10 / peak) * envelope
            result.append(value)
            result.append(value)
        }
        // A quiet, repeatable stereo texture makes width/depth comparisons
        // audible after the centered voice without changing the voice's pan.
        var random: UInt32 = 0x5343524E
        var left: Float = 0
        var right: Float = 0
        let textureCount = Int(sampleRate)
        for index in 0..<textureCount {
            random = 1664525 &* random &+ 1013904223
            left += 0.12 * (Float(random) / Float(UInt32.max) * 2 - 1 - left)
            random = 1664525 &* random &+ 1013904223
            right += 0.12 * (Float(random) / Float(UInt32.max) * 2 - 1 - right)
            let envelope = min(1, Float(min(index, textureCount - 1 - index)) / Float(fade))
            result.append(left * 0.025 * envelope)
            result.append(right * 0.025 * envelope)
        }
        result.append(contentsOf: repeatElement(0, count: Int(sampleRate * 0.15) * 2))
        samples = result
    }

    init?(measurementSamples: [Float], sampleRate: Double) {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              !measurementSamples.isEmpty, measurementSamples.count.isMultiple(of: 2),
              measurementSamples.count <= Int(sampleRate * 12) * 2,
              measurementSamples.allSatisfy({ $0.isFinite && abs($0) <= 0.030001 }) else { return nil }
        samples = measurementSamples
        self.sampleRate = sampleRate
        isAcousticMeasurement = true
    }
}

struct SpatialCalibrationPlayback {
    let clip: SpatialCalibrationClip
    let completion: @Sendable () -> Void
    private var cursor = 0
    private var fadeStart: Int?
    private var stopAt: Int?

    init(clip: SpatialCalibrationClip, completion: @escaping @Sendable () -> Void) {
        self.clip = clip
        self.completion = completion
    }

    var isFinished: Bool {
        if let stopAt { return cursor >= stopAt }
        return !clip.isVirtualAudition && cursor >= clip.samples.count
    }

    mutating func requestStop() {
        guard stopAt == nil else { return }
        fadeStart = cursor
        let fadeEnd = cursor + max(2, Int(clip.sampleRate * 0.025) * 2)
        stopAt = !clip.isVirtualAudition ? min(clip.samples.count, fadeEnd) : fadeEnd
    }

    mutating func nextFrame() -> PCMFrame? {
        guard !isFinished else { return nil }
        let start = cursor
        let end = min(stopAt ?? (!clip.isVirtualAudition ? clip.samples.count : cursor + 1024), cursor + 1024)
        var samples = (cursor..<end).map { clip.samples[$0 % clip.samples.count] }
        if clip.isVirtualAudition {
            let fadeFrames = max(1, Int(clip.sampleRate * 0.12))
            for index in stride(from: 0, to: samples.count, by: 2) {
                let gain = min(1, Float((cursor + index) / 2) / Float(fadeFrames))
                samples[index] *= gain
                samples[index + 1] *= gain
            }
        }
        if let fadeStart, let stopAt {
            let frames = max(1, (stopAt - fadeStart) / 2 - 1)
            for index in stride(from: 0, to: samples.count, by: 2) {
                let remaining = max(0, (stopAt - cursor - index) / 2 - 1)
                let gain = min(1, Float(remaining) / Float(frames))
                samples[index] *= gain
                samples[index + 1] *= gain
            }
        }
        cursor = end
        if clip.virtualSurroundDemo {
            var bed = [Float](repeating: 0, count: samples.count / 2 * 8)
            let roles = VirtualSurroundLayout.roles
            for i in 0..<(samples.count / 2) {
                let time = Double(start / 2 + i) / clip.sampleRate
                let phase = time.truncatingRemainder(dividingBy: 24)
                let stage = min(8, Int(phase / 2))
                let local = stage < 8 ? phase - Double(stage) * 2 : phase - 16
                let duration = stage < 8 ? 2.0 : 8.0
                let envelope = Float(max(0, min(1, min(local / 0.08, (duration - local) / 0.08))))
                for (channel, role) in LPCMChannelLayout.sevenPointOne.roles.enumerated() {
                    guard stage == 8 || roles[stage] == role else { continue }
                    // Distinct harmonics in the ensemble make the bed richer;
                    // the bass channel stays bounded and low-frequency only.
                    let frequency = role == .lowFrequencyEffects ? 70.0 : 220 + Double(channel) * 55
                    let value = Float(sin(2 * Double.pi * frequency * time)) * 0.08
                    // Recover the already computed start/stop fade from the
                    // timeline, not by dividing a possibly zero tone sample.
                    var fade = min(1, Float(start / 2 + i) / Float(max(1, Int(clip.sampleRate * 0.12))))
                    if let fadeStart, let stopAt {
                        fade *= min(1, Float(max(0, (stopAt - start - i * 2) / 2 - 1))
                            / Float(max(1, (stopAt - fadeStart) / 2 - 1)))
                    }
                    bed[i * 8 + channel] = value * envelope * fade * (stage == 8 ? 0.45 : 1)
                }
            }
            return PCMFrame(interleaved: bed, channelCount: 8, sampleRate: clip.sampleRate, channelLayout: .sevenPointOne)
        }
        if let role = clip.virtualSpeakerRole,
           let channel = LPCMChannelLayout.sevenPointOne.roles.firstIndex(of: role) {
            var bed = [Float](repeating: 0, count: samples.count / 2 * 8)
            for i in 0..<(samples.count / 2) { bed[i * 8 + channel] = samples[i * 2] }
            return PCMFrame(interleaved: bed, channelCount: 8, sampleRate: clip.sampleRate, channelLayout: .sevenPointOne)
        }
        return PCMFrame(interleaved: samples, channelCount: 2, sampleRate: clip.sampleRate)
    }
}

/// Synthesizes into memory, never directly to the default output. Playback is
/// explicitly routed through CamiTune's active PCM/DSP/master-volume path.
@MainActor
final class SpatialCalibrationVoice: ObservableObject {
    @Published private(set) var clip: SpatialCalibrationClip?
    @Published private(set) var isPreparing = false
    @Published private(set) var errorMessage: String?
    private var synthesizer: AVSpeechSynthesizer?
    private var generation = UUID()
    private var timeout: Task<Void, Never>?

    func prepare(sampleRate: Double) {
        if clip?.sampleRate == sampleRate { return }
        cancel()
        let generation = UUID()
        self.generation = generation
        isPreparing = true
        errorMessage = nil
        let collector = SpeechCollector()
        let synthesizer = AVSpeechSynthesizer()
        self.synthesizer = synthesizer
        let utterance = AVSpeechUtterance(string: "The morning light filled the room. A quiet voice tells the story.")
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.generation == generation, self.isPreparing else { return }
            self.cancel()
            self.errorMessage = "The voice sample could not be prepared. Check that a system speech voice is installed, then retry."
        }
        synthesizer.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength > 0 {
                collector.append(pcm)
                return
            }
            guard let speech = collector.finish() else { return }
            Task.detached(priority: .userInitiated) { [weak self] in
                let clip = SpatialCalibrationClip(
                    monoSpeech: speech.samples, speechSampleRate: speech.sampleRate,
                    sampleRate: sampleRate
                )
                await self?.finished(clip, generation: generation)
            }
        }
    }

    private func finished(_ clip: SpatialCalibrationClip?, generation: UUID) {
        guard self.generation == generation else { return }
        timeout?.cancel()
        timeout = nil
        isPreparing = false
        self.clip = clip
        if clip == nil { errorMessage = "The system voice returned no usable audio. Please retry." }
    }

    func cancel() {
        generation = UUID()
        timeout?.cancel()
        timeout = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        isPreparing = false
    }
}

private final class SpeechCollector: @unchecked Sendable {
    struct Result: Sendable { let samples: [Float]; let sampleRate: Double }
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate = Double.zero
    private var finished = false

    func append(_ pcm: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, pcm.format.sampleRate.isFinite,
              (8_000...384_000).contains(pcm.format.sampleRate) else { return }
        if sampleRate == 0 { sampleRate = pcm.format.sampleRate }
        guard pcm.format.sampleRate == sampleRate else { return }
        let channels = Int(pcm.format.channelCount)
        guard channels > 0, channels <= 8 else { return }
        let frames = min(Int(pcm.frameLength), max(0, Int(sampleRate * 12) - samples.count))
        for frame in 0..<frames {
            var sample: Float = 0
            for channel in 0..<channels {
                if let data = pcm.floatChannelData {
                    sample += pcm.format.isInterleaved
                        ? data[0][frame * channels + channel] : data[channel][frame * pcm.stride]
                } else if let data = pcm.int16ChannelData {
                    let value = pcm.format.isInterleaved
                        ? data[0][frame * channels + channel] : data[channel][frame * pcm.stride]
                    sample += Float(value) / 32768
                }
            }
            samples.append(sample.isFinite ? sample / Float(channels) : 0)
        }
    }

    func finish() -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        finished = true
        return Result(samples: samples, sampleRate: sampleRate)
    }
}
