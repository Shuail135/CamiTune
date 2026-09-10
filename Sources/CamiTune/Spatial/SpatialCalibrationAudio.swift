import AVFoundation
import Combine
import Foundation

/// Prepared off the audio thread and replayed identically for every A/B trial.
/// The voice peaks at -20 dBFS before the existing master volume and limiter.
struct SpatialCalibrationClip: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let isAcousticMeasurement: Bool

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

    var isFinished: Bool { cursor >= (stopAt ?? clip.samples.count) }

    mutating func requestStop() {
        guard stopAt == nil else { return }
        fadeStart = cursor
        stopAt = min(clip.samples.count, cursor + max(2, Int(clip.sampleRate * 0.025) * 2))
    }

    mutating func nextFrame() -> PCMFrame? {
        guard !isFinished else { return nil }
        let end = min(stopAt ?? clip.samples.count, cursor + 512 * 2)
        var samples = Array(clip.samples[cursor..<end])
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
