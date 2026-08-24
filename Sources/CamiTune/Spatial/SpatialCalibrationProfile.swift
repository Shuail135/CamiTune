import Foundation

/// Safe physical constants used by the Prototype-2 renderer. Later microphone
/// and perceptual calibration milestones can replace these values without
/// changing the realtime renderer's public intent model.
struct SpatialCalibrationProfile: Hashable, Sendable {
    var crosstalkDelayMicroseconds: Float
    var crosstalkMaximumCancellation: Float
    var nearReflectionDelayMilliseconds: Float
    var farReflectionDelayMilliseconds: Float
    var maximumReflectionGain: Float
    var limiterCeiling: Float

    static let conservativeStereo = SpatialCalibrationProfile(
        crosstalkDelayMicroseconds: 210,
        crosstalkMaximumCancellation: 0.16,
        nearReflectionDelayMilliseconds: 7.5,
        farReflectionDelayMilliseconds: 13.0,
        maximumReflectionGain: 0.10,
        limiterCeiling: 0.98
    )

    var validated: SpatialCalibrationProfile {
        SpatialCalibrationProfile(
            crosstalkDelayMicroseconds: Self.bound(
                crosstalkDelayMicroseconds,
                fallback: 210,
                range: 80...600
            ),
            crosstalkMaximumCancellation: Self.bound(
                crosstalkMaximumCancellation,
                fallback: 0.16,
                range: 0...0.25
            ),
            nearReflectionDelayMilliseconds: Self.bound(
                nearReflectionDelayMilliseconds,
                fallback: 7.5,
                range: 3...18
            ),
            farReflectionDelayMilliseconds: Self.bound(
                farReflectionDelayMilliseconds,
                fallback: 13,
                range: 6...30
            ),
            maximumReflectionGain: Self.bound(
                maximumReflectionGain,
                fallback: 0.10,
                range: 0...0.16
            ),
            limiterCeiling: Self.bound(
                limiterCeiling,
                fallback: 0.98,
                range: 0.80...0.99
            )
        )
    }

    private static func bound(
        _ value: Float,
        fallback: Float,
        range: ClosedRange<Float>
    ) -> Float {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
