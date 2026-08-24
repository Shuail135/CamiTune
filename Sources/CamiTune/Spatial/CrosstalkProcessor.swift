import Foundation

/// Conservative, frequency-limited cross-channel cancellation for speakers.
/// It intentionally avoids sub-bass and upper-treble cancellation, where a
/// generic (uncalibrated) inverse is least robust to head movement and room
/// differences.
struct CrosstalkProcessor {
    private var leftDelay: [Float] = []
    private var rightDelay: [Float] = []
    private var writeIndex = 0
    private var delaySamples = 1
    private var configuredSampleRate = Double.zero
    private var leftLowpass = Float.zero
    private var rightLowpass = Float.zero
    private var previousLeftInput = Float.zero
    private var previousRightInput = Float.zero
    private var previousLeftHighpass = Float.zero
    private var previousRightHighpass = Float.zero
    private var highpassCoefficient = Float.zero
    private var lowpassCoefficient = Float.zero

    mutating func prepare(
        sampleRate: Double,
        calibration: SpatialCalibrationProfile
    ) {
        guard sampleRate != configuredSampleRate else { return }
        configuredSampleRate = sampleRate
        let safeRate = max(8_000, min(384_000, sampleRate))
        delaySamples = max(1, Int(
            (safeRate * Double(calibration.crosstalkDelayMicroseconds) / 1_000_000).rounded()
        ))
        leftDelay = [Float](repeating: 0, count: delaySamples + 1)
        rightDelay = [Float](repeating: 0, count: delaySamples + 1)
        writeIndex = 0
        let highpassRC = 1 / (2 * Double.pi * 180)
        let samplePeriod = 1 / safeRate
        highpassCoefficient = Float(highpassRC / (highpassRC + samplePeriod))
        lowpassCoefficient = Float(
            1 - exp(-2 * Double.pi * 6_500 / safeRate)
        )
        resetFilterState()
    }

    mutating func reset() {
        if !leftDelay.isEmpty {
            leftDelay = [Float](repeating: 0, count: leftDelay.count)
            rightDelay = [Float](repeating: 0, count: rightDelay.count)
        }
        writeIndex = 0
        resetFilterState()
    }

    mutating func process(
        left: Float,
        right: Float,
        amount: Float,
        spatialSafetyScale: Float,
        sampleRate: Double,
        calibration: SpatialCalibrationProfile
    ) -> (left: Float, right: Float) {
        prepare(sampleRate: sampleRate, calibration: calibration)
        guard !leftDelay.isEmpty else { return (left, right) }

        let highpassLeft = highpassCoefficient
            * (previousLeftHighpass + left - previousLeftInput)
        let highpassRight = highpassCoefficient
            * (previousRightHighpass + right - previousRightInput)
        previousLeftInput = left
        previousRightInput = right
        previousLeftHighpass = highpassLeft
        previousRightHighpass = highpassRight

        leftLowpass += lowpassCoefficient * (highpassLeft - leftLowpass)
        rightLowpass += lowpassCoefficient * (highpassRight - rightLowpass)

        let readIndex = writeIndex + 1 == leftDelay.count ? 0 : writeIndex + 1
        let delayedLeft = leftDelay[readIndex]
        let delayedRight = rightDelay[readIndex]
        leftDelay[writeIndex] = leftLowpass
        rightDelay[writeIndex] = rightLowpass
        writeIndex = readIndex

        let cancellation = calibration.crosstalkMaximumCancellation
            * max(0, min(1, amount))
            * max(0, min(1, spatialSafetyScale))
        return (
            left: left - (delayedRight * cancellation),
            right: right - (delayedLeft * cancellation)
        )
    }

    private mutating func resetFilterState() {
        leftLowpass = 0
        rightLowpass = 0
        previousLeftInput = 0
        previousRightInput = 0
        previousLeftHighpass = 0
        previousRightHighpass = 0
    }
}
