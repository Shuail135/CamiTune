import Foundation

final class SpeakerSpatialRenderer: SpatialAudioRenderer {
    private var width = FrequencyDependentWidth()
    private var ambience = StereoAmbienceExtractor()
    private var decorrelator = StereoDecorrelator()
    private var midEnergy: Float = 0
    private var sideEnergy: Float = 0
    private var energyCoefficient: Float = 0
    func prepare(sampleRate: Double) {
        energyCoefficient = Float(1 - exp(-1 / (sampleRate * 0.05)))
        midEnergy = 0; sideEnergy = 0
        width.prepare(sampleRate: sampleRate)
        ambience.prepare(sampleRate: sampleRate)
        decorrelator.prepare(sampleRate: sampleRate)
    }
    func reset() {
        width.reset(); ambience.reset(); decorrelator.reset()
        midEnergy = 0; sideEnergy = 0
    }
    func process(left: Float, right: Float, amount: Float, cinema: Float) -> (Float, Float) {
        let mid = 0.5 * (left + right), side = 0.5 * (left - right)
        // A smoothed energy estimate avoids modulating width at every zero
        // crossing. Negative correlation only reduces the added branch.
        midEnergy += energyCoefficient * (mid * mid - midEnergy)
        sideEnergy += energyCoefficient * (side * side - sideEnergy)
        let total = midEnergy + sideEnergy
        let correlation = total > 1e-10 ? (midEnergy - sideEnergy) / total : 1
        let correlationSafety = 1 - 0.75 * SpatialSafety.unit(-correlation)
        let strength = amount * amount * correlationSafety
        let shaped = width.process(side, amount: strength * (1 - cinema))
        let room = decorrelator.process(ambience.process(left: left, right: right))
        // Antisymmetric wet field preserves the original mono fold-down exactly.
        let wet = (room.0 - room.1) * strength * (0.025 + 0.05 * cinema)
        return (mid + shaped + wet, mid - shaped - wet)
    }
}
