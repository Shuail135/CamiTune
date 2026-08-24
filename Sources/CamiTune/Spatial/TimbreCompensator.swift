import Foundation

/// Restores a small amount of center/high-frequency energy that is otherwise
/// perceived as lost after cross-channel cancellation. Compensation is
/// intentionally bounded and references the unprocessed center, so it cannot
/// turn side-only material into a moving phantom center.
struct TimbreCompensator {
    private var leftLowpass = Float.zero
    private var rightLowpass = Float.zero
    private var coefficient = Float.zero
    private var configuredSampleRate = Double.zero

    mutating func reset() {
        leftLowpass = 0
        rightLowpass = 0
    }

    mutating func process(
        left: Float,
        right: Float,
        referenceLeft: Float,
        referenceRight: Float,
        amount: Float,
        crosstalkAmount: Float,
        sampleRate: Double
    ) -> (left: Float, right: Float) {
        let safeAmount = max(0, min(1, amount))
        guard safeAmount > 0 else { return (left, right) }
        if sampleRate != configuredSampleRate {
            configuredSampleRate = sampleRate
            coefficient = Float(
                1 - exp(-2 * Double.pi * 2_400 / sampleRate)
            )
        }
        leftLowpass += coefficient * (left - leftLowpass)
        rightLowpass += coefficient * (right - rightLowpass)
        let leftHigh = left - leftLowpass
        let rightHigh = right - rightLowpass
        let referenceCenter = (referenceLeft + referenceRight) * 0.5
        let centerRestore = referenceCenter
            * 0.025
            * safeAmount
            * max(0, min(1, crosstalkAmount))
        let highRestore = 0.022 * safeAmount
        return (
            left: left + (leftHigh * highRestore) + centerRestore,
            right: right + (rightHigh * highRestore) + centerRestore
        )
    }
}
