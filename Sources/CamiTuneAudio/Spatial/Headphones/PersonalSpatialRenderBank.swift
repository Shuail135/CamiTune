import CamiTuneDomain
import Foundation

package enum PersonalSpatialPreparationStatus: Equatable, Sendable {
    case active(PersonalSpatialRenderIntent)
    case preparing
    case unavailable(String)
}

/// Semantic controls approach an offset slowly and release toward the user's
/// manual setting. This timing is separate from the fast linked compressor.
package struct MovieControlSmoothing {
    let attack: Float, release: Float
    package init(settings: MovieSettings, rate: Double) {
        attack = Float(1 - exp(-1 / (settings.attackSeconds * rate)))
        release = Float(1 - exp(-1 / (settings.releaseSeconds * rate)))
    }
    package func advance(_ value: inout Float, toward target: Float) {
        let coefficient = abs(target - 1) > abs(value - 1) ? attack : release
        value += coefficient * (target - value)
    }
}

/// No lookahead: one linked detector preserves source-channel relationships.
/// Presence is a bounded broad band; it is not dialogue/stem extraction.
package final class MovieEnhancer {
    private var low = [Float](repeating: 0, count: 32)
    private var high = [Float](repeating: 0, count: 32)
    private let lower: Float, upper: Float, attack: Float, release: Float, smoothing: Float
    private var gain: Float = 1
    private var clarity: Float = 0
    private var ratio: Float = 1
    private var threshold: Float = 1
    private let rate: Double
    private var presenceGain: Float = 1, centerGain: Float = 1, additionalGain: Float = 1
    package init(rate: Double) {
        self.rate = rate
        lower = Float(1 - exp(-2 * .pi * 1200 / rate))
        upper = Float(1 - exp(-2 * .pi * 4000 / rate))
        attack = Float(1 - exp(-1 / (0.008 * rate)))
        release = Float(1 - exp(-1 / (0.25 * rate)))
        smoothing = Float(1 - exp(-1 / (0.05 * rate)))
    }
    package func reset() {
        for i in low.indices { low[i] = 0; high[i] = 0 }
        gain = 1; clarity = 0; ratio = 1; threshold = 1
        presenceGain = 1; centerGain = 1; additionalGain = 1
    }
    package func process(_ frame: inout PCMFrame, settings: MovieSettings, controls: MovieAutomaticControls = .neutral) {
        let targetRatio: Float = settings.dynamics == .original ? 1 : settings.dynamics == .balanced ? 1.5 : 2.5
        let targetThreshold: Float = settings.dynamics == .original ? 1 : settings.dynamics == .balanced ? 0.35 : 0.18
        let roles = frame.channelLayout.roles
        var centerMask: UInt32 = 0, lfeMask: UInt32 = 0
        for index in roles.indices {
            if roles[index] == .center { centerMask |= 1 << index }
            if roles[index] == .lowFrequencyEffects { lfeMask |= 1 << index }
        }
        let hasCenter = centerMask != 0
        let targetPresence = pow(10, controls.presenceDB / 20)
        let targetCenter = pow(10, controls.centerDB / 20)
        let targetAdditional = pow(10, -controls.additionalReductionDB / 20)
        let semantic = MovieControlSmoothing(settings: settings, rate: rate)
        let targetClarity = SpatialRenderIntent.unit(settings.dialogueClarity)
        let frames = frame.frameCount, channels = frame.channelCount
        low.withUnsafeMutableBufferPointer { lows in
            high.withUnsafeMutableBufferPointer { highs in
                frame.interleaved.withUnsafeMutableBufferPointer { samples in
                    for n in 0..<frames {
                        clarity += smoothing * (targetClarity - clarity)
                        ratio += smoothing * (targetRatio - ratio)
                        threshold += smoothing * (targetThreshold - threshold)
                        semantic.advance(&presenceGain, toward: targetPresence)
                        semantic.advance(&centerGain, toward: targetCenter)
                        semantic.advance(&additionalGain, toward: targetAdditional)
                        var peak: Float = 0
                        for c in 0..<channels {
                            let i = n * channels + c
                            let x = SpatialSafety.sample(samples[i])
                            lows[c] += lower * (x - lows[c]); highs[c] += upper * (x - highs[c])
                            let value: Float
                            if hasCenter { value = x * (centerMask & (1 << c) != 0 ? (1 + 0.2589254 * clarity) * centerGain : 1) }
                            else {
                                let manual = 0.2589254 * clarity
                                let presence = manual + (1 + manual) * (presenceGain - 1)
                                value = x + (lfeMask & (1 << c) != 0 ? 0 : presence * (highs[c] - lows[c]))
                            }
                            samples[i] = value; peak = max(peak, abs(value))
                        }
                        let target = peak > threshold ? pow(peak / threshold, 1 / ratio - 1) : 1
                        gain += (target < gain ? attack : release) * (target - gain)
                        for c in 0..<channels { samples[n * channels + c] *= gain * additionalGain }
                    }
                }
            }
        }
    }
}

/// One scene's two independent convolution/room histories. All members are
/// prepared together off the writer; immutable coefficient arrays share storage.
package final class PersonalSpatialRenderBank {
    package let ordinary: PersonalVirtualSpeakerRenderer
    package let movie: PersonalVirtualSpeakerRenderer
    private let enhancer: MovieEnhancer
    private var remainingTails: [ProcessingCohort: Int] = [:]
    package let intent: PersonalSpatialRenderIntent
    package var rate: Double { ordinary.coefficients.sampleRate }
    package var latency: Int { ordinary.latencyFrames }
    package var tailFrames: Int { ordinary.tailFrames }
    package init(intent: PersonalSpatialRenderIntent, rate: Double, database: any HRTFDatabase) throws {
        self.intent = intent
        let coefficients = try PersonalSpatialSceneCompiler.compile(scene: intent.scene, tuning: intent.hrtf, rate: rate, database: database)
        ordinary = try .init(coefficients, playbackDevice: intent.playbackDevice)
        movie = try .init(coefficients, playbackDevice: intent.playbackDevice, schedulingPhase: 256)
        enhancer = .init(rate: rate)
    }
    package func reset() { ordinary.reset(); movie.reset(); enhancer.reset(); remainingTails.removeAll(keepingCapacity: true) }
    package func render(_ frame: PCMFrame, cohort: ProcessingCohort, settings: PersonalSpatialSettings, movieScores: MovieContentScores? = nil) -> PCMFrame? {
        guard (cohort == .spatialMovie ? movie : ordinary).accepts(frame) else { return nil }
        let hasInput = frame.interleaved.contains { $0 != 0 }
        let remaining = hasInput ? tailFrames : remainingTails[cohort, default: 0]
        guard hasInput || remaining > 0 else {
            return PCMFrame(interleaved: .init(repeating: 0, count: frame.frameCount * 2), channelCount: 2, sampleRate: frame.sampleRate)
        }
        remainingTails[cohort] = hasInput ? tailFrames : max(0, remaining - frame.frameCount)
        defer {
            if !hasInput && remaining <= frame.frameCount {
                if cohort == .spatialMovie { movie.reset(); enhancer.reset() }
                else { ordinary.reset() }
            }
        }
        if cohort == .spatialMovie {
            var processed = frame
            var controls = MovieAutomaticControls.neutral
            if intent.scene.experience == .spatialListening && settings.experience == .spatialListening && settings.movie.enabled {
                controls = MovieEnhancementPolicy.controls(scores: movieScores ?? .init(), settings: settings.movie)
                enhancer.process(&processed, settings: settings.movie, controls: controls)
            }
            return movie.render(processed, room: settings.room(for: intent.scene.experience),
                lateRoomGain: pow(10, controls.lateRoomDB / 20), smoothing: .init(settings: settings.movie, rate: rate))
        }
        return ordinary.render(frame, room: settings.room(for: intent.scene.experience))
    }
}

/// Whole-scene transition, advanced once per timeline interval, not once per
/// cohort. Ownership of the outgoing bank transfers to the preparation worker.
package final class PersonalSpatialTransition {
    package private(set) var active: PersonalSpatialRenderBank
    private var incoming: PersonalSpatialRenderBank?
    private var retired: PersonalSpatialRenderBank?
    private var position = 0
    private var warmFrames: Int
    private let fadeFrames: Int
    package init(_ initial: PersonalSpatialRenderBank) {
        active = initial
        warmFrames = initial.ordinary.warmupFrames
        fadeFrames = Int(initial.rate * 0.05)
    }
    package func replace(_ next: PersonalSpatialRenderBank) -> Bool {
        guard incoming == nil, retired == nil, next.rate == active.rate else { return false }
        incoming = next; warmFrames = next.ordinary.warmupFrames; position = 0; return true
    }
    package func reset() { active.reset(); incoming?.reset(); position = 0 }
    package func render(_ frame: PCMFrame, cohort: ProcessingCohort, settings: PersonalSpatialSettings, movieScores: MovieContentScores? = nil) -> PCMFrame? {
        guard var output = active.render(frame, cohort: cohort, settings: settings, movieScores: movieScores) else { return nil }
        if let incoming {
            guard let next = incoming.render(frame, cohort: cohort, settings: settings, movieScores: movieScores) else { return nil }
            for n in 0..<frame.frameCount {
                let mix = Float(max(0, min(fadeFrames, position + n - warmFrames))) / Float(fadeFrames)
                for c in 0..<2 {
                    let i = 2 * n + c
                    output.interleaved[i] += mix * (next.interleaved[i] - output.interleaved[i])
                }
            }
        }
        return output
    }
    package func finishInterval(frames: Int) -> PersonalSpatialRenderBank? {
        if let incoming {
            position += frames
            if position >= warmFrames + fadeFrames {
                retired = active; active = incoming; self.incoming = nil
            }
        }
        let result = retired; retired = nil; return result
    }
}
