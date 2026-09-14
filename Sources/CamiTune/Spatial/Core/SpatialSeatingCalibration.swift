import Foundation

/// Distances from each physical speaker to the listener, in metres. This is
/// arrival-time/level alignment, not generic crosstalk cancellation or room EQ.
struct SpatialSeatingCalibration: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var outputDeviceUID: String
    var name = "Default"
    var leftDistanceMeters: Float = 1
    var rightDistanceMeters: Float = 1
    var roomX: Float = 0
    var roomY: Float = 0
    var enabled = true
    /// A listening check may trim the dominant side without boosting either output.
    var balanceDB: Float = 0
    var measuredArrivalDifferenceMS: Double?
    var measuredLevelDifferenceDB: Double?
    var useMeasuredAlignment = false
    var measuredAt: Date?
    var microphoneName: String?
    var measurementConfidence: AcousticMeasurementConfidence?
    var roomCorrectionBands: [EQBand] = []
    var roomCorrectionTopology: SpeakerTopology?

    private enum CodingKeys: String, CodingKey {
        case id, outputDeviceUID, name, leftDistanceMeters, rightDistanceMeters, roomX, roomY, enabled, balanceDB
        case measuredArrivalDifferenceMS, measuredLevelDifferenceDB, useMeasuredAlignment
        case measuredAt, microphoneName, measurementConfidence, roomCorrectionBands, roomCorrectionTopology
    }
    init(outputDeviceUID: String, name: String = "Default",
         leftDistanceMeters: Float = 1, rightDistanceMeters: Float = 1) {
        self.outputDeviceUID = outputDeviceUID; self.name = name
        self.leftDistanceMeters = leftDistanceMeters; self.rightDistanceMeters = rightDistanceMeters
    }
    init(from decoder: Decoder) throws {
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
        roomCorrectionTopology = try c.decodeIfPresent(SpeakerTopology.self, forKey: .roomCorrectionTopology)
        roomCorrectionBands = try c.decodeIfPresent([EQBand].self, forKey: .roomCorrectionBands) ?? []
    }

    var alignment: (leftDelay: Double, rightDelay: Double, leftGain: Float, rightGain: Float) {
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

final class SpatialSeatAligner {
    private var left: [Float] = []
    private var right: [Float] = []
    private var cursor = 0
    private var rate: Double = 0
    private var leftDelay = SpatialScalarSmoother(), rightDelay = SpatialScalarSmoother()
    private var leftGain = SpatialScalarSmoother(), rightGain = SpatialScalarSmoother()

    func prepare(sampleRate: Double) {
        rate = sampleRate
        left = .init(repeating: 0, count: Int(ceil(sampleRate * 0.01)) + 2)
        right = .init(repeating: 0, count: left.count)
        leftDelay.prepare(sampleRate: rate); rightDelay.prepare(sampleRate: rate)
        leftGain.prepare(sampleRate: rate); rightGain.prepare(sampleRate: rate)
        reset()
    }
    func reset() {
        for i in left.indices { left[i] = 0; right[i] = 0 }
        cursor = 0
        leftDelay.reset(); rightDelay.reset(); leftGain.reset(to: 1); rightGain.reset(to: 1)
    }
    func process(_ l: Float, _ r: Float, alignment: (Double, Double, Float, Float)) -> (Float, Float) {
        guard !left.isEmpty else { return (l, r) }
        left[cursor] = l; right[cursor] = r
        let ld = leftDelay.next(Float(alignment.0 * rate))
        let rd = rightDelay.next(Float(alignment.1 * rate))
        let result = (read(left, delay: ld) * leftGain.next(alignment.2),
                      read(right, delay: rd) * rightGain.next(alignment.3))
        cursor = (cursor + 1) % left.count
        return result
    }
    private func read(_ buffer: [Float], delay: Float) -> Float {
        let whole = Int(delay), fraction = delay - Float(whole)
        let a = (cursor - whole + buffer.count) % buffer.count
        let b = (a - 1 + buffer.count) % buffer.count
        return buffer[a] + fraction * (buffer[b] - buffer[a])
    }
}
