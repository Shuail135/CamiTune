import CamiTuneDomain
import Foundation

/// One writer's existing rate controller and cubic interpolation history.
/// Source/output clock evidence is supplied by the synchronized delivery owner.
package struct RateMatchedPCMStage {
    package struct Output {
        package let frame: PCMFrame
        package let adjustmentPPM: Double
        package let observation: RateMatchMeasurement?
    }
    private var controller = AdaptiveRateController()
    private var resampler = AdaptivePCMResampler()
    package init() {}

    package mutating func process(_ rendered: PCMFrame, inputFrames: Int, queuedFrames: Int,
                                  policy: PCMQueuePolicy, recoveryGeneration: UInt64,
                                  clockAdjustmentPPM: Double?, isCalibrationSample: Bool,
                                  recordObservation: Bool) -> Output {
        let input = RateMatchObservation(bufferedFrames: inputFrames + queuedFrames,
            targetFrames: policy.rateTarget(writerBlockFrames: inputFrames),
            sampleRate: rendered.sampleRate, elapsedFrames: inputFrames,
            recoveryGeneration: recoveryGeneration,
            requiresStandingBacklog: policy.rateTargetMode == .configuredWhenQueued || policy.rateTargetMode == .clockTracked,
            clockAdjustmentPPM: clockAdjustmentPPM)
        let adjustment = isCalibrationSample ? 0 : controller.update(input)
        let observation = recordObservation && !isCalibrationSample
            ? controller.diagnosticObservation(input, targetSource: policy.rateTargetMode.rawValue) : nil
        let frame = isCalibrationSample ? rendered : resampler.process(rendered, adjustmentPPM: adjustment)
        return Output(frame: frame, adjustmentPPM: adjustment, observation: observation)
    }

    /// Called only for an authoritative producer END, never from an idle guess.
    package mutating func finish(discard: Bool) -> PCMFrame? {
        let tail: PCMFrame?
        if discard { resampler.reset(); tail = nil }
        else { tail = resampler.finish(adjustmentPPM: controller.adjustmentPPM) }
        controller.reset()
        return tail
    }

    package mutating func reset() {
        controller.reset()
        resampler.reset()
    }
}
