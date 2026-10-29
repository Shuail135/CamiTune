import CamiTuneDomain
import Foundation

/// Signal-based estimates, not semantic probabilities or source separation.
package struct SpatialContentEstimate: Equatable, Sendable {
    package init(speech: Float = 0, music: Float = 0, ambience: Float = 0, impact: Float = 0, active: Bool = false) {
        self.speech = speech
        self.music = music
        self.ambience = ambience
        self.impact = impact
        self.active = active
    }

    package var speech: Float = 0
    package var music: Float = 0
    package var ambience: Float = 0
    package var impact: Float = 0
    package var active = false
    package static let unknown = Self()

    package var label: String {
        guard active else { return "Quiet / awaiting audio" }
        let ranked = [(speech, "Speech-like"), (music, "Music-like"),
                      (ambience, "Ambience-like"), (impact, "Impact-like")].sorted { $0.0 > $1.0 }
        guard ranked[0].0 >= 0.55, ranked[0].0 - ranked[1].0 >= 0.12 else { return "Mixed / uncertain" }
        return ranked[0].1
    }
}

/// Analysis-only mix for either detector. All non-LFE channels contribute with
/// equal energy weights. A cancelled window selects a stable energetic channel,
/// with hysteresis and a 20 ms ramp; playback samples are never changed.
package final class SpatialAnalysisMixer {
    private let base: UnsafeMutablePointer<Float>
    private let weights: UnsafeMutablePointer<Float>
    private let target: UnsafeMutablePointer<Float>
    private let energies: UnsafeMutablePointer<Double>
    private var mixedEnergy: Double = 0
    private var count = 0, ramp = 0
    private let channels: Int, window: Int, rampLength: Int
    private var dominant = 0
    package init(layout: LPCMChannelLayout, rate: Double) {
        channels = layout.channelCount
        base = .allocate(capacity: channels * 3)
        base.initialize(repeating: 0, count: channels * 3)
        weights = base.advanced(by: channels); target = weights.advanced(by: channels)
        energies = .allocate(capacity: channels)
        energies.initialize(repeating: 0, count: channels)
        let count = layout.roles.filter { $0 != .lowFrequencyEffects }.count
        let gain = count > 0 ? 1 / sqrt(Float(count)) : 0
        for index in layout.roles.indices { base[index] = layout.roles[index] == .lowFrequencyEffects ? 0 : gain }
        weights.update(from: base, count: channels); target.update(from: base, count: channels)
        dominant = layout.roles.firstIndex { $0 != .lowFrequencyEffects } ?? 0
        window = max(1, Int(rate * 0.1)); rampLength = max(1, Int(rate * 0.02))
    }
    deinit { base.deallocate(); energies.deallocate() }
    package func sample(_ samples: UnsafeBufferPointer<Float>, offset: Int) -> Float {
        var mixed: Float = 0, output: Float = 0
        for channel in 0..<channels where base[channel] != 0 {
            if ramp > 0 { weights[channel] += (target[channel] - weights[channel]) / Float(ramp) }
            let value = SpatialSafety.sample(samples[offset + channel])
            mixed += base[channel] * value; output += weights[channel] * value
            energies[channel] += Double(value) * Double(value)
        }
        if ramp > 0 { ramp -= 1 }
        mixedEnergy += Double(mixed) * Double(mixed)
        count += 1
        if count == window {
            var expected: Double = 0
            var strongest = dominant
            for channel in 0..<channels where base[channel] != 0 {
                expected += energies[channel] * Double(base[channel] * base[channel])
                if energies[channel] > energies[strongest] { strongest = channel }
            }
            if energies[strongest] > energies[dominant] * 1.5 { dominant = strongest }
            let cancelled = expected > Double(window) * 1e-8 && mixedEnergy < expected * 0.08
            var changed = false
            for channel in 0..<channels {
                let next: Float = cancelled ? (channel == dominant ? 1 : 0) : base[channel]
                if next != target[channel] { changed = true; target[channel] = next }
            }
            if changed { ramp = rampLength }
            count = 0; mixedEnergy = 0; energies.update(repeating: 0, count: channels)
        }
        return output
    }
    /// Batch entry keeps numerical preprocessing in the optimized Audio module,
    /// including when the app and platform-model adapter run in an Xcode Debug build.
    package func process(_ input: UnsafeBufferPointer<Float>, frameCount: Int,
                        output: UnsafeMutableBufferPointer<Float>) -> Double {
        precondition(input.count >= frameCount * channels && output.count >= frameCount)
        var energy: Double = 0
        for frame in 0..<frameCount {
            let value = sample(input, offset: frame * channels)
            output[frame] = value
            energy += Double(value) * Double(value)
        }
        return energy
    }
}

/// Constant-memory, 100 ms feature windows. The physical renderer and Movie's
/// Basic worker use the same feature calculations and input-mixing contract.
package final class SpatialContentAnalyzer {
    package init() {}

    package private(set) var estimate = SpatialContentEstimate.unknown
    private var rate = 0.0
    private var roles: [ChannelRole] = []
    private var count = 0
    private var energy = 0.0, lowEnergy = 0.0, voiceEnergy = 0.0
    private var leftEnergy = 0.0, rightEnergy = 0.0, cross = 0.0
    private var peak = 0.0
    private var crossings = 0
    private var previous = 0.0, low = 0.0, upper = 0.0
    private var lowCoefficient = 0.0, upperCoefficient = 0.0
    private var previousRMS = 0.0, envelopeChange = 0.0
    private var activeWindows = 0
    private var mixer: SpatialAnalysisMixer?

    package func reset() {
        estimate = .unknown; rate = 0; roles = []; count = 0
        energy = 0; lowEnergy = 0; voiceEnergy = 0
        leftEnergy = 0; rightEnergy = 0; cross = 0; peak = 0; crossings = 0
        previous = 0; low = 0; upper = 0; lowCoefficient = 0; upperCoefficient = 0
        previousRMS = 0; envelopeChange = 0; activeWindows = 0; mixer = nil
    }

    package func ingest(_ frame: PCMFrame) {
        frame.interleaved.withUnsafeBufferPointer {
            ingest($0, channelCount: frame.channelCount, sampleRate: frame.sampleRate, layout: frame.channelLayout)
        }
    }

    /// The analysis worker already owns a bounded input buffer. Borrow it for
    /// this call; retain only feature history, never its sample storage.
    package func ingest(_ samples: UnsafeBufferPointer<Float>, channelCount: Int,
                        sampleRate: Double, layout: LPCMChannelLayout) {
        guard sampleRate.isFinite, (8_000...384_000).contains(sampleRate),
              channelCount > 0, channelCount <= 32,
              layout.roles.count == channelCount,
              samples.count.isMultiple(of: channelCount) else { reset(); return }
        if rate != sampleRate || roles != layout.roles {
            reset()
            rate = sampleRate
            roles = layout.roles
            lowCoefficient = 1 - exp(-2 * .pi * 180 / rate)
            upperCoefficient = 1 - exp(-2 * .pi * 3_500 / rate)
            mixer = SpatialAnalysisMixer(layout: layout, rate: rate)
        }
        let mixer = mixer!
        let l = roles.firstIndex(of: .left), r = roles.firstIndex(of: .right)
        let window = max(1, Int(rate * 0.1))
        for offset in stride(from: 0, to: samples.count, by: channelCount) {
            let sample = Double(mixer.sample(samples, offset: offset))
            var left = l.map { clean(samples[offset + $0]) } ?? sample
            var right = r.map { clean(samples[offset + $0]) } ?? sample
            // A silent front pair supplies no stereo evidence for a center,
            // side, or height-only source. Analyze its waveform as mono.
            if abs(left) + abs(right) < 1e-8 { left = sample; right = sample }
            low += lowCoefficient * (sample - low)
            upper += upperCoefficient * (sample - upper)
            let voice = upper - low
            energy += sample * sample
            lowEnergy += low * low
            voiceEnergy += voice * voice
            leftEnergy += left * left
            rightEnergy += right * right
            cross += left * right
            peak = max(peak, abs(sample))
            if (sample >= 0) != (previous >= 0) { crossings += 1 }
            previous = sample
            count += 1
            if count == window { finishWindow() }
        }
    }

    private func finishWindow() {
        let rms = sqrt(energy / Double(count))
        // Side-only/out-of-phase stereo still counts as active audio.
        let stereoRMS = sqrt((leftEnergy + rightEnergy) / Double(count * 2))
        let active = max(rms, stereoRMS) > 0.0001
        activeWindows = active ? min(100, activeWindows + 1) : 0
        let change = abs(rms - previousRMS) / max(0.0001, max(rms, previousRMS))
        envelopeChange += 0.3 * (change - envelopeChange)
        let correlation = min(leftEnergy, rightEnergy) < max(leftEnergy, rightEnergy) * 1e-6
            ? 1 : abs(cross) / max(1e-12, sqrt(leftEnergy * rightEnergy))
        let voiceRatio = voiceEnergy / max(1e-12, energy)
        let lowRatio = lowEnergy / max(1e-12, energy)
        let crossingRate = Double(crossings) / Double(count) * rate / 48_000
        let crest = peak / max(0.0001, rms)
        let onset = max(0, (rms - previousRMS) / max(0.0001, rms))
        let voiced = unit((voiceRatio - 0.35) / 0.4) * unit((0.30 - crossingRate) / 0.2)
        let modulated = unit((envelopeChange - 0.06) / 0.28)
        let speech = voiced * modulated * (0.65 + 0.35 * unit(correlation))
        let ambience = unit((0.6 - correlation) / 0.9) * (1 - modulated * 0.6)
        let music = (1 - modulated) * (1 - ambience * 0.5)
        let impact = unit((crest - 2) / 4) * unit(onset * 1.5) * (0.5 + 0.5 * unit(lowRatio * 3))
        // Require 400 ms of evidence before widening for a guessed content type.
        let ready = active && activeWindows >= 4
        let target = SpatialContentEstimate(speech: ready ? Float(speech) : 0,
            music: ready ? Float(music) : 0, ambience: ready ? Float(ambience) : 0,
            impact: ready ? Float(impact) : 0, active: active)
        let alpha: Float = active ? 0.25 : 0.4
        estimate.speech += alpha * (target.speech - estimate.speech)
        estimate.music += alpha * (target.music - estimate.music)
        estimate.ambience += alpha * (target.ambience - estimate.ambience)
        estimate.impact += (target.impact > estimate.impact ? 0.7 : 0.2) * (target.impact - estimate.impact)
        estimate.active = active
        previousRMS = rms
        count = 0; energy = 0; lowEnergy = 0; voiceEnergy = 0
        leftEnergy = 0; rightEnergy = 0; cross = 0; peak = 0; crossings = 0
    }

    private func clean(_ sample: Float) -> Double { sample.isFinite ? Double(max(-4, min(4, sample))) : 0 }
    private func unit(_ value: Double) -> Double { max(0, min(1, value)) }
}

