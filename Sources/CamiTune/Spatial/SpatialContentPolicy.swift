import Foundation

enum SpatialContentMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case automatic, movieVideo, musicSafe, fixed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .movieVideo: return "Movie / Video"
        case .musicSafe: return "Music-safe"
        case .fixed: return "Fixed (no analysis)"
        }
    }
}

/// Signal-based estimates, not semantic probabilities or source separation.
struct SpatialContentEstimate: Equatable, Sendable {
    var speech: Float = 0
    var music: Float = 0
    var ambience: Float = 0
    var impact: Float = 0
    var active = false
    static let unknown = Self()

    var label: String {
        guard active else { return "Quiet / awaiting audio" }
        let ranked = [(speech, "Speech-like"), (music, "Music-like"),
                      (ambience, "Ambience-like"), (impact, "Impact-like")].sorted { $0.0 > $1.0 }
        guard ranked[0].0 >= 0.55, ranked[0].0 - ranked[1].0 >= 0.12 else { return "Mixed / uncertain" }
        return ranked[0].1
    }
}

/// Constant-memory, 100 ms feature windows on the existing PCM writer worker.
/// No microphone, FFT, model, network, or additional audio queue is involved.
struct SpatialContentAnalyzer {
    private(set) var estimate = SpatialContentEstimate.unknown
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

    mutating func reset() { self = Self() }

    mutating func ingest(_ frame: PCMFrame) {
        guard frame.sampleRate.isFinite, (8_000...384_000).contains(frame.sampleRate),
              frame.channelCount > 0, frame.channelCount <= 32,
              frame.channelLayout.roles.count == frame.channelCount,
              frame.interleaved.count.isMultiple(of: frame.channelCount),
              let l = frame.channelLayout.roles.firstIndex(of: .left),
              let r = frame.channelLayout.roles.firstIndex(of: .right) else { reset(); return }
        if rate != frame.sampleRate || roles != frame.channelLayout.roles {
            reset()
            rate = frame.sampleRate
            roles = frame.channelLayout.roles
            lowCoefficient = 1 - exp(-2 * .pi * 180 / rate)
            upperCoefficient = 1 - exp(-2 * .pi * 3_500 / rate)
        }
        let center = roles.firstIndex(of: .center)
        let window = max(1, Int(rate * 0.1))
        for offset in stride(from: 0, to: frame.interleaved.count, by: frame.channelCount) {
            let left = clean(frame.interleaved[offset + l])
            let right = clean(frame.interleaved[offset + r])
            // Center energy contributes evidence, but its channel name alone
            // never classifies dialogue. Surround roles remain renderer-owned.
            let c = center.map { clean(frame.interleaved[offset + $0]) } ?? 0
            var sample = (left + right) * 0.5 + c * 0.707
            for channel in 0..<frame.channelCount where channel != l && channel != r && channel != center {
                let discrete = clean(frame.interleaved[offset + channel]) * 0.5
                if abs(discrete) > abs(sample) { sample = discrete }
            }
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

    private mutating func finishWindow() {
        let rms = sqrt(energy / Double(count))
        // Side-only/out-of-phase stereo still counts as active audio.
        let stereoRMS = sqrt((leftEnergy + rightEnergy) / Double(count * 2))
        let active = max(rms, stereoRMS) > 0.0001
        activeWindows = active ? min(100, activeWindows + 1) : 0
        let change = abs(rms - previousRMS) / max(0.0001, max(rms, previousRMS))
        envelopeChange += 0.3 * (change - envelopeChange)
        let correlation = cross / max(1e-12, sqrt(leftEnergy * rightEnergy))
        let voiceRatio = voiceEnergy / max(1e-12, energy)
        let lowRatio = lowEnergy / max(1e-12, energy)
        let crossingRate = Double(crossings) / Double(count)
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

enum AdaptiveSpatialContentPolicy {
    static func intent(base: SpatialRenderIntent, mode: SpatialContentMode,
                       estimate: SpatialContentEstimate, multichannel: Bool) -> SpatialRenderIntent {
        guard mode != .fixed else { return base.clamped }
        var result = base.clamped
        if mode == .musicSafe || (mode == .automatic && !multichannel) {
            // Conservative stereo is the fallback, including mixed content.
            result.stageWidth = min(result.stageWidth, 0.40)
            result.stageDepth = min(result.stageDepth, 0.16)
            result.envelopment = min(result.envelopment, 0.12)
            result.crosstalkControl = min(result.crosstalkControl, 0.28)
            result.centerExternalization = min(result.centerExternalization, 0.44)
            result.timbreCompensation = min(result.timbreCompensation, 0.35)
        }
        guard mode != .musicSafe, estimate.active else { return result.clamped }
        // Do not turn weak estimates into large stage changes. Music evidence
        // suppresses ambience/impact expansion, even in Movie / Video mode.
        func evidence(_ value: Float) -> Float { max(0, min(1, (value - 0.4) / 0.6)) }
        let speech = evidence(estimate.speech)
        let music = evidence(estimate.music)
        let ambience = evidence(estimate.ambience) * (1 - music)
        let impact = max(0, min(1, (estimate.impact - 0.15) / 0.55)) * (1 - music)
        result.centerAnchor += 0.12 * speech
        result.localizationPrecision += 0.10 * max(speech, impact)
        result.stageWidth += 0.10 * ambience + 0.04 * impact
        result.stageDepth += 0.10 * ambience - 0.06 * speech - 0.10 * music
        result.envelopment += 0.12 * ambience - 0.08 * speech - 0.10 * music
        result.crosstalkControl -= 0.06 * music
        // Intent only: no bass boost, input gain, limiter, or physical speaker
        // protection constants can be changed by a content estimate.
        return result.clamped
    }
}
