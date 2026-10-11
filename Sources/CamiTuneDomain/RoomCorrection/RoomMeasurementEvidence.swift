import Foundation

/// Acquisition facts, not claims about microphone accuracy or speaker distance.
/// Optional on observations so older magnitude-only sessions remain readable.
package struct RoomCaptureEvidence: Codable, Hashable, Sendable {
    package var recordingSampleRate: Double
    package var playbackSampleRate: Double
    package var analysisSampleRate: Double
    package var isLossy: Bool
    package var clippingFraction: Double
    /// Sensitivity subtracted from magnitude bins only. The raw diagnostic IR
    /// and relative phase have not been inverted or microphone-phase calibrated.
    package var calibrationApplied: MicrophoneCalibrationCurve?
    package var acquisition: RoomMeasurementSource.Kind?
    package var sweepBlockID: UUID?
    package var analysisVersion = 4
    package init(recordingSampleRate: Double, playbackSampleRate: Double, analysisSampleRate: Double,
                 isLossy: Bool, clippingFraction: Double, calibrationApplied: MicrophoneCalibrationCurve?) {
        self.recordingSampleRate = recordingSampleRate; self.playbackSampleRate = playbackSampleRate
        self.analysisSampleRate = analysisSampleRate; self.isLossy = isLossy
        self.clippingFraction = clippingFraction; self.calibrationApplied = calibrationApplied
    }
    package func validate() throws {
        guard [recordingSampleRate, playbackSampleRate, analysisSampleRate].allSatisfy({ $0.isFinite && (8000...192000).contains($0) }),
              clippingFraction.isFinite, (0...1).contains(clippingFraction), analysisVersion > 0 else {
            throw RoomCorrectionError.invalidSession
        }
        try calibrationApplied?.validateForRoomMeasurement()
    }
}

package enum RoomAnalysisPolicy: String, Codable, Sendable {
    case automaticUncalibrated, calibrated
    package static func resolve(_ source: RoomMeasurementSource) throws -> Self {
        guard let calibration = source.calibration else { return .automaticUncalibrated }
        try calibration.validateForRoomMeasurement()
        return .calibrated
    }
}

extension MicrophoneCalibrationCurve {
    /// Validate decoded/programmatically supplied curves too, not just text imports.
    package func validateForRoomMeasurement() throws {
        guard (2...10000).contains(points.count), points.allSatisfy({
            $0.frequency.isFinite && (10...40000).contains($0.frequency)
                && $0.correctionDB.isFinite && abs($0.correctionDB) <= 30
        }), zip(points, points.dropFirst()).allSatisfy({ $0.frequency < $1.frequency }) else {
            throw AcousticMeasurementError.invalidCalibrationFile
        }
    }
    package func coversRoomFrequency(_ frequency: Double) -> Bool {
        guard let first = points.first, let last = points.last else { return false }
        return (first.frequency...last.frequency).contains(frequency)
    }
}

/// Coordinates originate from the setup canvas and suggested microphone offsets.
/// They can rank nearby seats, but cannot establish acoustic delays or room modes.
package struct RoomGeometrySnapshot: Sendable {
    package enum Certainty: Sendable { case schematicEstimate }
    package let certainty: Certainty = .schematicEstimate
    package var physicalChannels: [PhysicalOutputID]
    package var listener: SpatialVector3
    package var positions: [RoomMeasurementPosition]
    package init(session: RoomMeasurementSession) {
        physicalChannels = session.context.topology.endpoints.map(\.id)
        listener = session.context.listener
        positions = session.positions.filter { !$0.skipped }
    }
    package func priority(of position: RoomMeasurementPosition) -> Double {
        if position.isMain { return 1 }
        func distance(_ point: SpatialVector3) -> Double {
            sqrt(Double(pow(point.x - listener.x, 2) + pow(point.y - listener.y, 2) + pow(point.z - listener.z, 2)))
        }
        let distances = positions.filter { !$0.isMain }.map { distance($0.coordinate) }.sorted()
        let typical = distances.isEmpty ? 1 : max(0.0001, distances[distances.count / 2])
        return max(0.5, 1 / (1 + 0.25 * distance(position.coordinate) / typical))
    }
}
