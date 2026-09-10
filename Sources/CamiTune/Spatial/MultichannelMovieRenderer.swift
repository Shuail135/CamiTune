import Foundation

struct MultichannelMovieRenderDiagnostics: Equatable, Sendable {
    var activeRoles: Set<ChannelRole>
    var automaticHeadroomGain: Float
    var lfeWasActive: Bool

    static let neutral = MultichannelMovieRenderDiagnostics(
        activeRoles: [],
        automaticHeadroomGain: 1,
        lfeWasActive: false
    )
}

/// Prototype-3 semantic bed renderer. It uses the channel labels carried from
/// Core Audio rather than assuming a fixed numeric order, then produces the
/// stereo virtual bed consumed by FrontStageRenderer.
final class MultichannelMovieRenderer {
    private var sideLeftDelay = SpatialDelayLine()
    private var sideRightDelay = SpatialDelayLine()
    private var rearLeftDelay = SpatialDelayLine()
    private var rearRightDelay = SpatialDelayLine()
    private var configuredSampleRate = Double.zero
    private var lfeLowpass = Float.zero
    private var lfeLowpassCoefficient = Float.zero
    private var headroomGain = Float(1)
    private var headroomReleaseCoefficient = Float.zero
    private var limiterGain = Float(1)
    private var limiterReleaseCoefficient = Float.zero
    private var smoother = SpatialParameterSmoother()

    private(set) var diagnostics: MultichannelMovieRenderDiagnostics = .neutral

    func reset() {
        sideLeftDelay.reset()
        sideRightDelay.reset()
        rearLeftDelay.reset()
        rearRightDelay.reset()
        lfeLowpass = 0
        headroomGain = 1
        limiterGain = 1
        smoother.reset()
        diagnostics = .neutral
    }

    func render(
        frame: PCMFrame,
        intent requestedIntent: SpatialRenderIntent
    ) -> PCMFrame? {
        guard frame.channelCount > 2,
              frame.channelLayout.channelCount == frame.channelCount,
              frame.interleaved.count.isMultiple(of: frame.channelCount),
              frame.sampleRate.isFinite,
              frame.sampleRate >= 8_000,
              frame.sampleRate <= 384_000 else {
            return nil
        }
        prepare(sampleRate: frame.sampleRate)

        let targetIntent = requestedIntent.clamped
        let activity = roleActivity(in: frame)
        let targetHeadroom = automaticHeadroom(
            activeRoles: activity,
            intent: targetIntent
        )
        var output = [Float]()
        output.reserveCapacity(frame.frameCount * 2)

        for frameIndex in 0..<frame.frameCount {
            let intent = smoother.next(target: targetIntent, sampleRate: frame.sampleRate)
            let offset = frameIndex * frame.channelCount
            var frontLeft = Float.zero
            var frontRight = Float.zero
            var center = Float.zero
            var lfe = Float.zero
            var sideLeft = Float.zero
            var sideRight = Float.zero
            var rearLeft = Float.zero
            var rearRight = Float.zero

            for channel in 0..<frame.channelCount {
                let sample = finiteOrZero(frame.interleaved[offset + channel])
                switch frame.channelLayout.roles[channel] {
                case .left: frontLeft += sample
                case .right: frontRight += sample
                case .center: center += sample
                case .lowFrequencyEffects: lfe += sample
                case .leftSurround: sideLeft += sample
                case .rightSurround: sideRight += sample
                case .leftRearSurround: rearLeft += sample
                case .rightRearSurround: rearRight += sample
                case .unknown: break
                }
            }

            let delayedSideLeft = sideLeftDelay.process(sideLeft)
            let delayedSideRight = sideRightDelay.process(sideRight)
            let delayedRearLeft = rearLeftDelay.process(rearLeft)
            let delayedRearRight = rearRightDelay.process(rearRight)

            let frontGain = Float(0.82)
            let centerGain = 0.68 + (0.10 * intent.centerAnchor)
            let sideDirectGain = 0.30 + (0.12 * intent.envelopment)
            let sideDepthGain = 0.10 * intent.stageDepth
            let sideCrossGain = -0.055 * intent.stageWidth
            let rearDirectGain = 0.18 + (0.10 * intent.envelopment)
            let rearDepthGain = 0.12 * intent.stageDepth
            let rearCrossGain = -0.075 * intent.stageWidth

            // Low-pass the discrete effects feed before it reaches small
            // full-range speakers. A bounded cubic term supplies quiet upper
            // harmonics for impact without sending unfiltered LFE downstream.
            lfeLowpass += lfeLowpassCoefficient * (lfe - lfeLowpass)
            let boundedBass = max(-1, min(1, lfeLowpass))
            let bassHarmonic = boundedBass - (boundedBass * boundedBass * boundedBass)
            let protectedImpact = (lfeLowpass * 0.14) + (bassHarmonic * 0.04)

            var left = (frontLeft * frontGain) + (center * centerGain)
            var right = (frontRight * frontGain) + (center * centerGain)
            left += (sideLeft * sideDirectGain)
                + (delayedSideLeft * sideDepthGain)
                + (delayedSideRight * sideCrossGain)
            right += (sideRight * sideDirectGain)
                + (delayedSideRight * sideDepthGain)
                + (delayedSideLeft * sideCrossGain)
            left += (rearLeft * rearDirectGain)
                + (delayedRearLeft * rearDepthGain)
                + (delayedRearRight * rearCrossGain)
            right += (rearRight * rearDirectGain)
                + (delayedRearRight * rearDepthGain)
                + (delayedRearLeft * rearCrossGain)
            left += protectedImpact
            right += protectedImpact

            if targetHeadroom < headroomGain {
                headroomGain = targetHeadroom
            } else {
                headroomGain += (targetHeadroom - headroomGain)
                    * headroomReleaseCoefficient
            }
            left *= headroomGain
            right *= headroomGain

            let limited = limit(left: left, right: right, ceiling: 0.95)
            output.append(limited.left)
            output.append(limited.right)
        }

        diagnostics = MultichannelMovieRenderDiagnostics(
            activeRoles: activity,
            automaticHeadroomGain: headroomGain,
            lfeWasActive: activity.contains(.lowFrequencyEffects)
        )
        return PCMFrame(
            interleaved: output,
            channelCount: 2,
            sampleRate: frame.sampleRate,
            channelLayout: .stereo,
            sourceBufferedFrames: frame.sourceBufferedFrames,
            sourceCapacityFrames: frame.sourceCapacityFrames
        )
    }

    private func prepare(sampleRate: Double) {
        guard sampleRate != configuredSampleRate else { return }
        configuredSampleRate = sampleRate
        sideLeftDelay.prepare(delaySamples: max(1, Int(sampleRate * 0.008)))
        sideRightDelay.prepare(delaySamples: max(1, Int(sampleRate * 0.008)))
        rearLeftDelay.prepare(delaySamples: max(1, Int(sampleRate * 0.014)))
        rearRightDelay.prepare(delaySamples: max(1, Int(sampleRate * 0.014)))
        lfeLowpassCoefficient = Float(1 - exp(-2 * Double.pi * 120 / sampleRate))
        headroomReleaseCoefficient = Float(1 - exp(-1 / (sampleRate * 0.080)))
        limiterReleaseCoefficient = Float(1 - exp(-1 / (sampleRate * 0.080)))
        reset()
    }

    private func roleActivity(in frame: PCMFrame) -> Set<ChannelRole> {
        var energyByRole: [ChannelRole: Double] = [:]
        var totalEnergy = Double.zero
        for frameIndex in 0..<frame.frameCount {
            let offset = frameIndex * frame.channelCount
            for channel in 0..<frame.channelCount {
                let sample = frame.interleaved[offset + channel]
                guard sample.isFinite else { continue }
                let energy = Double(sample) * Double(sample)
                energyByRole[frame.channelLayout.roles[channel], default: 0] += energy
                totalEnergy += energy
            }
        }
        let floor = max(Double(max(1, frame.frameCount)) * 1e-12, totalEnergy * 1e-7)
        return Set(energyByRole.compactMap { role, energy in
            role != .unknown && energy > floor ? role : nil
        })
    }

    private func automaticHeadroom(
        activeRoles: Set<ChannelRole>,
        intent: SpatialRenderIntent
    ) -> Float {
        let front = Float(0.82)
        let center = 0.68 + (0.10 * intent.centerAnchor)
        let sideDirect = 0.30 + (0.12 * intent.envelopment)
        let sideDelayed = 0.10 * intent.stageDepth
        let sideCross = 0.055 * intent.stageWidth
        let rearDirect = 0.18 + (0.10 * intent.envelopment)
        let rearDelayed = 0.12 * intent.stageDepth
        let rearCross = 0.075 * intent.stageWidth
        let impact = Float(0.18)

        var leftPotential = Float.zero
        var rightPotential = Float.zero
        if activeRoles.contains(.left) { leftPotential += front }
        if activeRoles.contains(.right) { rightPotential += front }
        if activeRoles.contains(.center) {
            leftPotential += center
            rightPotential += center
        }
        if activeRoles.contains(.leftSurround) {
            leftPotential += sideDirect + sideDelayed
            rightPotential += sideCross
        }
        if activeRoles.contains(.rightSurround) {
            rightPotential += sideDirect + sideDelayed
            leftPotential += sideCross
        }
        if activeRoles.contains(.leftRearSurround) {
            leftPotential += rearDirect + rearDelayed
            rightPotential += rearCross
        }
        if activeRoles.contains(.rightRearSurround) {
            rightPotential += rearDirect + rearDelayed
            leftPotential += rearCross
        }
        if activeRoles.contains(.lowFrequencyEffects) {
            leftPotential += impact
            rightPotential += impact
        }
        return min(1, 0.95 / max(0.95, max(leftPotential, rightPotential)))
    }

    private func limit(
        left: Float,
        right: Float,
        ceiling: Float
    ) -> (left: Float, right: Float) {
        let peak = max(abs(left), abs(right))
        let requiredGain = peak > ceiling ? ceiling / peak : Float(1)
        if requiredGain < limiterGain {
            limiterGain = requiredGain
        } else {
            limiterGain += (1 - limiterGain) * limiterReleaseCoefficient
        }
        return (
            max(-ceiling, min(ceiling, left * limiterGain)),
            max(-ceiling, min(ceiling, right * limiterGain))
        )
    }

    private func finiteOrZero(_ sample: Float) -> Float {
        sample.isFinite ? sample : 0
    }
}

private struct SpatialDelayLine {
    private var samples: [Float] = []
    private var index = 0

    mutating func prepare(delaySamples: Int) {
        samples = [Float](repeating: 0, count: max(1, delaySamples))
        index = 0
    }

    mutating func reset() {
        if !samples.isEmpty {
            samples = [Float](repeating: 0, count: samples.count)
        }
        index = 0
    }

    mutating func process(_ input: Float) -> Float {
        guard !samples.isEmpty else { return 0 }
        let delayed = samples[index]
        samples[index] = input
        index += 1
        if index == samples.count { index = 0 }
        return delayed
    }
}
