import CamiTuneDomain
import Foundation

/// Continuous external recording: acoustic codes own block identity; playback
/// timestamps only narrow searches. No absolute speaker delay is inferred.
struct RoomSimpleRecordingAnalysis {
    func analyze(_ recording: RoomMeasurementAnalyzer.Recording, block: RoomMeasurementBlock,
                 playbackRate: Double, expectedMarkerTime: Double?) throws -> RoomChannelObservation {
        var result = try RoomMeasurementAnalyzer().analyze(recording: recording, block: block,
            playbackRate: playbackRate, calibration: nil, expectedMarkerTime: expectedMarkerTime)
        result.captureEvidence?.acquisition = .recorder
        // Relative impulse/phase diagnostics are retained separately.
        result.timingEligible = false
        return result
    }
}
