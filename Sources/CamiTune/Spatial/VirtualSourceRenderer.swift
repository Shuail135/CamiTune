import Foundation

/// Mid/side placement plus quiet, band-limited early reflections. The direct
/// signal always remains dominant: width affects only the side component and
/// both reflection taps are mono, keeping a centered voice locked between the
/// physical speakers while giving it a cue in front of their plane.
struct VirtualSourceRenderer {
    private var delayLine: [Float] = []
    private var writeIndex = 0
    private var nearDelaySamples = 1
    private var farDelaySamples = 1
    private var reflectionLowpass = Float.zero
    private var reflectionLowpassCoefficient = Float.zero
    private var previousReflectionInput = Float.zero
    private var previousReflectionHighpass = Float.zero
    private var reflectionHighpassCoefficient = Float.zero
    private var configuredSampleRate = Double.zero

    mutating func prepare(
        sampleRate: Double,
        calibration: SpatialCalibrationProfile
    ) {
        guard sampleRate != configuredSampleRate else { return }
        configuredSampleRate = sampleRate
        let safeRate = max(8_000, min(384_000, sampleRate))
        nearDelaySamples = max(1, Int(
            safeRate * Double(calibration.nearReflectionDelayMilliseconds) / 1_000
        ))
        farDelaySamples = max(nearDelaySamples + 1, Int(
            safeRate * Double(calibration.farReflectionDelayMilliseconds) / 1_000
        ))
        delayLine = [Float](repeating: 0, count: farDelaySamples + 2)
        writeIndex = 0
        reflectionLowpass = 0
        previousReflectionInput = 0
        previousReflectionHighpass = 0
        reflectionLowpassCoefficient = Float(
            1 - exp(-2 * Double.pi * 3_200 / safeRate)
        )
        let highpassRC = 1 / (2 * Double.pi * 220)
        let samplePeriod = 1 / safeRate
        reflectionHighpassCoefficient = Float(
            highpassRC / (highpassRC + samplePeriod)
        )
    }

    mutating func reset() {
        if !delayLine.isEmpty {
            delayLine = [Float](repeating: 0, count: delayLine.count)
        }
        writeIndex = 0
        reflectionLowpass = 0
        previousReflectionInput = 0
        previousReflectionHighpass = 0
    }

    mutating func process(
        left: Float,
        right: Float,
        intent: SpatialRenderIntent,
        spatialSafetyScale: Float,
        sampleRate: Double,
        calibration: SpatialCalibrationProfile
    ) -> (left: Float, right: Float) {
        prepare(sampleRate: sampleRate, calibration: calibration)

        let mid = (left + right) * 0.5
        let side = (left - right) * 0.5
        let safeScale = max(0, min(1, spatialSafetyScale))
        let sideGain = 1 + (
            0.42 * intent.stageWidth * intent.localizationPrecision * safeScale
        )
        let centerGain = 1 + (0.08 * intent.centerAnchor)
        let anchoredMid = mid * centerGain
        var outputLeft = anchoredMid + (side * sideGain)
        var outputRight = anchoredMid - (side * sideGain)

        guard !delayLine.isEmpty else { return (outputLeft, outputRight) }
        let near = delayLine[readIndex(delay: nearDelaySamples)]
        let far = delayLine[readIndex(delay: farDelaySamples)]
        delayLine[writeIndex] = mid
        writeIndex += 1
        if writeIndex == delayLine.count { writeIndex = 0 }

        // Keep reflections out of the sibilance and bass bands. A subtle
        // band-limited reflection is a depth cue; a full-band echo would
        // pull dialogue away from the screen, color bass, and produce obvious
        // comb filtering.
        let reflectionInput = (near * 0.68) + (far * 0.32)
        let reflectionHighpass = reflectionHighpassCoefficient
            * (previousReflectionHighpass
                + reflectionInput
                - previousReflectionInput)
        previousReflectionInput = reflectionInput
        previousReflectionHighpass = reflectionHighpass
        reflectionLowpass += reflectionLowpassCoefficient
            * (reflectionHighpass - reflectionLowpass)
        let reflectionIntent = max(intent.stageDepth, intent.centerExternalization)
        let reflectionGain = calibration.maximumReflectionGain
            * reflectionIntent
            * safeScale
        let reflection = reflectionLowpass * reflectionGain
        outputLeft += reflection
        outputRight += reflection
        return (outputLeft, outputRight)
    }

    private func readIndex(delay: Int) -> Int {
        let index = writeIndex - delay
        return index >= 0 ? index : index + delayLine.count
    }
}
