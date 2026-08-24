import Foundation

struct FrontStageRenderDiagnostics: Equatable, Sendable {
    var spatialSafetyScale: Float
    var automaticHeadroomGain: Float
    var limiterGain: Float

    static let neutral = FrontStageRenderDiagnostics(
        spatialSafetyScale: 1,
        automaticHeadroomGain: 1,
        limiterGain: 1
    )
}

/// Prototype-2 stereo Front Stage renderer. This runs only on the dedicated
/// CamillaDSP writer branch, never on Core Audio's realtime IO callback.
final class FrontStageRenderer {
    private let calibration: SpatialCalibrationProfile
    private var smoother: SpatialParameterSmoother
    private var virtualSources = VirtualSourceRenderer()
    private var crosstalk = CrosstalkProcessor()
    private var timbre = TimbreCompensator()
    private var limiter = StereoSafetyLimiter()
    private var sampleRate = Double.zero

    private(set) var diagnostics: FrontStageRenderDiagnostics = .neutral

    init(
        calibration: SpatialCalibrationProfile = .conservativeStereo,
        smoothingTime: TimeInterval = 0.040
    ) {
        self.calibration = calibration.validated
        smoother = SpatialParameterSmoother(settlingTime: smoothingTime)
    }

    func reset() {
        smoother.reset()
        virtualSources.reset()
        crosstalk.reset()
        timbre.reset()
        limiter.reset()
        diagnostics = .neutral
    }

    func render(
        frame: PCMFrame,
        intent requestedIntent: SpatialRenderIntent
    ) -> PCMFrame? {
        guard frame.channelCount == 2,
              frame.channelLayout.roles == LPCMChannelLayout.stereo.roles,
              frame.interleaved.count.isMultiple(of: 2),
              frame.sampleRate.isFinite,
              frame.sampleRate >= 8_000,
              frame.sampleRate <= 384_000 else {
            return nil
        }

        if sampleRate != frame.sampleRate {
            sampleRate = frame.sampleRate
            reset()
            virtualSources.prepare(sampleRate: sampleRate, calibration: calibration)
            crosstalk.prepare(sampleRate: sampleRate, calibration: calibration)
        }

        let intent = requestedIntent.clamped
        let safetyScale = spatialSafetyScale(for: frame)
        var rendered = [Float]()
        rendered.reserveCapacity(frame.interleaved.count)
        var lastHeadroom = Float(1)

        for index in stride(from: 0, to: frame.interleaved.count, by: 2) {
            // Non-finite samples must never poison persistent filter/delay
            // state. Replacing one invalid sample with silence is the closest
            // neutral realtime fallback available for a streaming block.
            let dryLeft = finiteOrZero(frame.interleaved[index])
            let dryRight = finiteOrZero(frame.interleaved[index + 1])
            let smoothed = smoother.next(target: intent, sampleRate: sampleRate)

            let placed = virtualSources.process(
                left: dryLeft,
                right: dryRight,
                intent: smoothed,
                spatialSafetyScale: safetyScale,
                sampleRate: sampleRate,
                calibration: calibration
            )
            let controlled = crosstalk.process(
                left: placed.left,
                right: placed.right,
                amount: smoothed.crosstalkControl,
                spatialSafetyScale: safetyScale,
                sampleRate: sampleRate,
                calibration: calibration
            )
            let compensated = timbre.process(
                left: controlled.left,
                right: controlled.right,
                referenceLeft: dryLeft,
                referenceRight: dryRight,
                amount: smoothed.timbreCompensation,
                crosstalkAmount: smoothed.crosstalkControl,
                sampleRate: sampleRate
            )

            let strength = smoothed.frontStageStrength
            var left = dryLeft + ((compensated.left - dryLeft) * strength)
            var right = dryRight + ((compensated.right - dryRight) * strength)
            let headroom = automaticHeadroom(
                for: smoothed,
                spatialSafetyScale: safetyScale
            )
            lastHeadroom = headroom
            left *= headroom
            right *= headroom

            let limited = limiter.process(
                left: left,
                right: right,
                ceiling: calibration.limiterCeiling,
                sampleRate: sampleRate
            )
            rendered.append(limited.left)
            rendered.append(limited.right)
        }

        diagnostics = FrontStageRenderDiagnostics(
            spatialSafetyScale: safetyScale,
            automaticHeadroomGain: lastHeadroom,
            limiterGain: limiter.gain
        )
        return PCMFrame(
            interleaved: rendered,
            channelCount: 2,
            sampleRate: frame.sampleRate,
            channelLayout: .stereo,
            sourceBufferedFrames: frame.sourceBufferedFrames,
            sourceCapacityFrames: frame.sourceCapacityFrames
        )
    }

    private func finiteOrZero(_ sample: Float) -> Float {
        sample.isFinite ? sample : 0
    }

    /// Anti-correlated content is already maximally wide. Reducing cancellation
    /// and reflection there avoids phasey sound, bass cancellation, and stage
    /// movement without collapsing the original stereo signal.
    private func spatialSafetyScale(for frame: PCMFrame) -> Float {
        var leftEnergy = Double.zero
        var rightEnergy = Double.zero
        var crossEnergy = Double.zero
        for index in stride(from: 0, to: frame.interleaved.count, by: 2) {
            let left = Double(finiteOrZero(frame.interleaved[index]))
            let right = Double(finiteOrZero(frame.interleaved[index + 1]))
            leftEnergy += left * left
            rightEnergy += right * right
            crossEnergy += left * right
        }
        let denominator = sqrt(leftEnergy * rightEnergy)
        guard denominator > 1e-12 else { return 1 }
        let correlation = max(-1, min(1, crossEnergy / denominator))
        guard correlation < -0.15 else { return 1 }
        return Float(max(0.15, (correlation + 1) / 0.85))
    }

    private func automaticHeadroom(
        for intent: SpatialRenderIntent,
        spatialSafetyScale: Float
    ) -> Float {
        let reflection = max(intent.stageDepth, intent.centerExternalization)
        let potentialBoost = (
            (0.24 * intent.stageWidth)
            + (0.08 * intent.centerAnchor)
            + (0.10 * reflection)
            + (calibration.crosstalkMaximumCancellation * intent.crosstalkControl)
            + (0.05 * intent.timbreCompensation)
        ) * spatialSafetyScale
        return 1 / (1 + (intent.frontStageStrength * potentialBoost))
    }
}

private struct StereoSafetyLimiter {
    private(set) var gain = Float(1)
    private var releaseCoefficient = Float.zero
    private var configuredSampleRate = Double.zero

    mutating func reset() {
        gain = 1
    }

    mutating func process(
        left: Float,
        right: Float,
        ceiling: Float,
        sampleRate: Double
    ) -> (left: Float, right: Float) {
        let peak = max(abs(left), abs(right))
        let requiredGain = peak > ceiling ? ceiling / peak : Float(1)
        if requiredGain < gain {
            // Immediate attack guarantees the current sample is bounded.
            gain = requiredGain
        } else {
            if sampleRate != configuredSampleRate {
                configuredSampleRate = sampleRate
                releaseCoefficient = Float(1 - exp(-1 / (sampleRate * 0.080)))
            }
            gain += (1 - gain) * releaseCoefficient
        }
        return (
            left: max(-ceiling, min(ceiling, left * gain)),
            right: max(-ceiling, min(ceiling, right * gain))
        )
    }
}
