import Foundation

package struct SpatialSeatingCalibration: Codable, Hashable, Sendable, Identifiable {
    package var id = UUID()
    package var outputDeviceUID: String
    package var name = "Default"
    package var leftDistanceMeters: Float = 1
    package var rightDistanceMeters: Float = 1
    package var roomX: Float = 0
    package var roomY: Float = 0
    package var enabled = true
    /// A listening check may trim the dominant side without boosting either output.
    package var balanceDB: Float = 0
    package var measuredArrivalDifferenceMS: Double?
    package var measuredLevelDifferenceDB: Double?
    package var useMeasuredAlignment = false
    package var measuredAt: Date?
    package var microphoneName: String?
    package var measurementConfidence: AcousticMeasurementConfidence?
    package var roomCorrectionBands: [EQBand] = []
    package var roomCorrectionTopology: SpeakerTopology?

    package var roomCorrectionEnabled = true
    package var roomCorrectionSessionID: UUID?
    package var roomCorrectionSettings = RoomCorrectionSettings()
    package var roomCorrectionResult: RoomCorrectionResult?
    package var roomCorrectionRevision = 0

    private enum CodingKeys: String, CodingKey {
        case id, outputDeviceUID, name, leftDistanceMeters, rightDistanceMeters, roomX, roomY, enabled, balanceDB
        case measuredArrivalDifferenceMS, measuredLevelDifferenceDB, useMeasuredAlignment
        case measuredAt, microphoneName, measurementConfidence, roomCorrectionBands, roomCorrectionTopology
        case roomCorrectionEnabled, roomCorrectionSessionID, roomCorrectionSettings, roomCorrectionResult, roomCorrectionRevision
    }
    package init(outputDeviceUID: String, name: String = "Default",
         leftDistanceMeters: Float = 1, rightDistanceMeters: Float = 1) {
        self.outputDeviceUID = outputDeviceUID; self.name = name
        self.leftDistanceMeters = leftDistanceMeters; self.rightDistanceMeters = rightDistanceMeters
    }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        outputDeviceUID = try c.decode(String.self, forKey: .outputDeviceUID)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Default"
        leftDistanceMeters = Self.distance(try c.decodeIfPresent(Float.self, forKey: .leftDistanceMeters) ?? 1)
        rightDistanceMeters = Self.distance(try c.decodeIfPresent(Float.self, forKey: .rightDistanceMeters) ?? 1)
        roomX = try c.decodeIfPresent(Float.self, forKey: .roomX) ?? 0
        roomY = try c.decodeIfPresent(Float.self, forKey: .roomY) ?? 0
        if !roomX.isFinite { roomX = 0 }; if !roomY.isFinite { roomY = 0 }
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        balanceDB = min(6, max(-6, try c.decodeIfPresent(Float.self, forKey: .balanceDB) ?? 0))
        measuredArrivalDifferenceMS = try c.decodeIfPresent(Double.self, forKey: .measuredArrivalDifferenceMS)
        measuredLevelDifferenceDB = try c.decodeIfPresent(Double.self, forKey: .measuredLevelDifferenceDB)
        useMeasuredAlignment = try c.decodeIfPresent(Bool.self, forKey: .useMeasuredAlignment) ?? false
        measuredAt = try c.decodeIfPresent(Date.self, forKey: .measuredAt)
        microphoneName = try c.decodeIfPresent(String.self, forKey: .microphoneName)
        measurementConfidence = try c.decodeIfPresent(AcousticMeasurementConfidence.self, forKey: .measurementConfidence)
        roomCorrectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .roomCorrectionEnabled) ?? true
        roomCorrectionSessionID = try c.decodeIfPresent(UUID.self, forKey: .roomCorrectionSessionID)
        roomCorrectionSettings = try c.decodeIfPresent(RoomCorrectionSettings.self, forKey: .roomCorrectionSettings) ?? .init()
        roomCorrectionResult = try c.decodeIfPresent(RoomCorrectionResult.self, forKey: .roomCorrectionResult)
        roomCorrectionRevision = try c.decodeIfPresent(Int.self, forKey: .roomCorrectionRevision) ?? 0
        roomCorrectionTopology = try c.decodeIfPresent(SpeakerTopology.self, forKey: .roomCorrectionTopology)
        roomCorrectionBands = try c.decodeIfPresent([EQBand].self, forKey: .roomCorrectionBands) ?? []
    }

    package var alignment: (leftDelay: Double, rightDelay: Double, leftGain: Float, rightGain: Float) {
        let l = Self.distance(leftDistanceMeters), r = Self.distance(rightDistanceMeters)
        let far = max(l, r)
        // Delay and attenuate the nearer speaker; never boost the farther one.
        var ld = min(0.01, Double(far - l) / 343), rd = min(0.01, Double(far - r) / 343)
        var lg = max(0.5, l / far), rg = max(0.5, r / far)
        if useMeasuredAlignment, let arrival = measuredArrivalDifferenceMS,
           let level = measuredLevelDifferenceDB, arrival.isFinite, level.isFinite {
            ld = max(0, min(0.01, arrival / 1000)); rd = max(0, min(0.01, -arrival / 1000))
            // Positive R-L level means the right speaker is louder.
            lg = Float(pow(10, min(0, max(-6, level)) / 20))
            rg = Float(pow(10, min(0, max(-6, -level)) / 20))
        }
        let balance = balanceDB.isFinite ? min(6, max(-6, balanceDB)) : 0
        lg *= pow(10, min(0, -balance) / 20)
        rg *= pow(10, min(0, balance) / 20)
        return (ld, rd, lg, rg)
    }
    private static func distance(_ value: Float) -> Float {
        value.isFinite ? min(10, max(0.2, value)) : 1
    }
}
