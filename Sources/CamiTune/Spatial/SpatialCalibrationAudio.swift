import CamiTuneAudio
import CamiTuneDomain
import AVFoundation
import Combine
import Foundation

/// Prepared off the audio thread and replayed identically for every A/B trial.
/// The voice peaks at -20 dBFS before the existing master volume and limiter.




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
