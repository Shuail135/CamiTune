import CamiTuneDomain
import Foundation

/// Controlled, per-block direct capture. A validated sensitivity curve is
/// subtracted once in deconvolution; it never calibrates phase or absolute SPL.
struct RoomCalibratedMicrophoneAnalysis {
    func analyze(_ recording: RoomMeasurementAnalyzer.Recording, block: RoomMeasurementBlock,
                 playbackRate: Double, calibration: MicrophoneCalibrationCurve?) throws -> RoomChannelObservation {
        guard let calibration else { throw RoomCorrectionError.calibrationRequired }
        try calibration.validateForRoomMeasurement()
        guard !recording.isLossy else { throw RoomCorrectionError.unreliable }
        // Check the original capture before resampling can smooth ADC clipping.
        guard recording.samples.lazy.filter({ abs($0) >= 0.999 }).prefix(3).count < 3 else {
            throw RoomCorrectionError.inputClipped
        }
        var result: RoomChannelObservation
        do {
            result = try RoomMeasurementAnalyzer().analyze(recording: recording, block: block,
                playbackRate: playbackRate, calibration: calibration)
        } catch RoomCorrectionError.missingBlocks { throw RoomCorrectionError.microphoneSweepMissing }
        result.captureEvidence?.acquisition = .microphone
        // Input and output devices may have independent clocks even on this Mac.
        result.timingEligible = false
        return result
    }
}
