import CamiTuneDomain
import Foundation

package struct RateMatchObservation: Sendable, Equatable {
    package init(bufferedFrames: Int, targetFrames: Int, sampleRate: Double, elapsedFrames: Int, recoveryGeneration: UInt64, requiresStandingBacklog: Bool = false, clockAdjustmentPPM: Double? = nil) {
        self.bufferedFrames = bufferedFrames
        self.targetFrames = targetFrames
        self.sampleRate = sampleRate
        self.elapsedFrames = elapsedFrames
        self.recoveryGeneration = recoveryGeneration
        self.requiresStandingBacklog = requiresStandingBacklog
        self.clockAdjustmentPPM = clockAdjustmentPPM
    }

    package let bufferedFrames: Int
    package let targetFrames: Int
    package let sampleRate: Double
    package let elapsedFrames: Int
    package let recoveryGeneration: UInt64
    package var requiresStandingBacklog = false
    package var clockAdjustmentPPM: Double? = nil
}

package struct AdaptiveRateController {
    package init() {}

    package static let maximumAdjustmentPPM = 500.0
    package private(set) var adjustmentPPM = 0.0
    private var integralPPM = 0.0
    private var filteredBufferedFrames: Double?
    private var generation: UInt64?
    private var rate: Double?

    package func diagnosticObservation(_ observation: RateMatchObservation, targetSource: String) -> RateMatchMeasurement {
        let target = Double(observation.targetFrames)
        let filtered = filteredBufferedFrames ?? target
        return .init(bufferedFrames: observation.bufferedFrames, targetFrames: target,
            filteredBufferedFrames: filtered, normalizedError: target > 0 ? (filtered - target) / target : 0,
            adjustmentPPM: adjustmentPPM, elapsedFrames: observation.elapsedFrames,
            sampleRate: observation.sampleRate, targetSource: targetSource,
            controlState: observation.requiresStandingBacklog && observation.bufferedFrames <= observation.elapsedFrames
                ? (observation.clockAdjustmentPPM == nil ? "emptyWriterQueue" : "clockTracking") : "tracking")
    }

    package mutating func update(_ observation: RateMatchObservation) -> Double {
        let sampleRate = observation.sampleRate, elapsedFrames = observation.elapsedFrames
        guard sampleRate.isFinite, sampleRate > 0, elapsedFrames > 0, observation.targetFrames > 0 else {
            return adjustmentPPM
        }
        if generation != observation.recoveryGeneration || rate != sampleRate {
            reset()
            generation = observation.recoveryGeneration; rate = sampleRate
        }
        let targetFrames = Double(observation.targetFrames)
        let bufferedFrames = observation.bufferedFrames
        let clockAdjustment = observation.clockAdjustmentPPM ?? 0
        guard clockAdjustment.isFinite, abs(clockAdjustment) <= Self.maximumAdjustmentPPM else {
            reset()
            return 0
        }

        // Experimental policy: with no queued PCM, current-block size measures
        // packetization, not a standing clock reservoir. Do not wind up PI from
        // it or retain a stale integral after that reservoir empties. Measured
        // clock drift, when supplied, remains observable with an empty queue.
        // Preserve the existing output slew toward that correction (or neutral).
        if observation.requiresStandingBacklog && bufferedFrames <= elapsedFrames {
            integralPPM = 0; filteredBufferedFrames = nil
            let step = max(0.25, 240 * Double(elapsedFrames) / sampleRate)
            adjustmentPPM += min(step, max(-step, clockAdjustment - adjustmentPPM))
            return adjustmentPPM
        }

        let deltaTime = Double(elapsedFrames) / sampleRate
        let observed = Double(max(0, bufferedFrames))
        var filtered = filteredBufferedFrames ?? targetFrames
        let smoothing = 1 - exp(-deltaTime / 0.5)
        filtered += (observed - filtered) * smoothing
        filteredBufferedFrames = filtered

        var normalizedError = (filtered - targetFrames) / targetFrames
        if abs(normalizedError) < 0.02 { normalizedError = 0 }
        integralPPM += normalizedError * 40 * deltaTime
        integralPPM = min(400, max(-400, integralPPM))

        let requestedPPM = min(
            Self.maximumAdjustmentPPM,
            max(-Self.maximumAdjustmentPPM, clockAdjustment + normalizedError * 180 + integralPPM)
        )
        let maximumStep = max(0.25, 240 * deltaTime)
        adjustmentPPM += min(maximumStep, max(-maximumStep, requestedPPM - adjustmentPPM))
        return adjustmentPPM
    }

    package mutating func reset() {
        adjustmentPPM = 0
        integralPPM = 0
        filteredBufferedFrames = nil
        generation = nil; rate = nil
    }
}
