import Foundation

/// One-pole smoothing is performed per sample. This keeps source-format and
/// future calibration changes from moving the apparent stage abruptly.
struct SpatialParameterSmoother {
    private(set) var current: SpatialRenderIntent
    var settlingTime: TimeInterval
    private var coefficient = Float(1)
    private var configuredSampleRate = Double.zero
    private var configuredSettlingTime = TimeInterval.zero

    init(
        initial: SpatialRenderIntent = .neutral,
        settlingTime: TimeInterval = 0.040
    ) {
        current = initial.clamped
        self.settlingTime = settlingTime
    }

    mutating func reset(to intent: SpatialRenderIntent = .neutral) {
        current = intent.clamped
    }

    mutating func next(
        target: SpatialRenderIntent,
        sampleRate: Double
    ) -> SpatialRenderIntent {
        guard sampleRate.isFinite, sampleRate > 0 else {
            current = .neutral
            return current
        }
        let safeTime = max(0.001, min(0.5, settlingTime))
        if sampleRate != configuredSampleRate || safeTime != configuredSettlingTime {
            configuredSampleRate = sampleRate
            configuredSettlingTime = safeTime
            coefficient = Float(1 - exp(-1 / (sampleRate * safeTime)))
        }
        let target = target.clamped
        current = SpatialRenderIntent(
            frontStageStrength: approach(current.frontStageStrength, target.frontStageStrength, coefficient),
            stageWidth: approach(current.stageWidth, target.stageWidth, coefficient),
            stageDepth: approach(current.stageDepth, target.stageDepth, coefficient),
            centerAnchor: approach(current.centerAnchor, target.centerAnchor, coefficient),
            envelopment: approach(current.envelopment, target.envelopment, coefficient),
            localizationPrecision: approach(current.localizationPrecision, target.localizationPrecision, coefficient),
            centerExternalization: approach(current.centerExternalization, target.centerExternalization, coefficient),
            crosstalkControl: approach(current.crosstalkControl, target.crosstalkControl, coefficient),
            timbreCompensation: approach(current.timbreCompensation, target.timbreCompensation, coefficient)
        )
        return current
    }

    private func approach(_ value: Float, _ target: Float, _ coefficient: Float) -> Float {
        value + ((target - value) * coefficient)
    }
}
