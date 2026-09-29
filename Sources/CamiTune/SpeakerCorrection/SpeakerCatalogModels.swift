import CamiTuneDomain
import CryptoKit
import Foundation

struct SpeakerCatalogEntry: Hashable, Sendable, Identifiable {
    var name: String
    var id: String { name }
}
struct SpeakerMetadata: Hashable, Sendable {
    var preferredVersion: String?
    var sources: [String: String]
    static func decode(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] == nil else {
            throw SpeakerCorrectionError.invalid("Spinorama speaker metadata is unavailable.")
        }
        let measurements = object["measurements"] as? [String: [String: Any]] ?? [:]
        return .init(preferredVersion: object["default_measurement"] as? String,
                     sources: measurements.mapValues { sourceName($0["origin"] as? String ?? "Measurement source") })
    }
    static func sourceName(_ origin: String) -> String {
        switch origin {
        case "ErinsAudioCorner", "eac": return "Erin's Audio Corner"
        case "ASR", "AudioScienceReview", "asr": return "Audio Science Review"
        case "Princeton": return "Princeton / 3D3A"
        default: return origin
        }
    }
}
struct SpeakerMeasurementVersion: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var sourceDisplayName: String
    var measurements: [String]
    var supportsCEA2034: Bool { measurements.contains("CEA2034") }
    static func recommended(in versions: [Self], metadata: SpeakerMetadata) -> Self? {
        if let preferred = versions.first(where: { $0.id == metadata.preferredVersion && $0.supportsCEA2034 }) { return preferred }
        return versions.filter(\.supportsCEA2034).sorted { $0.id < $1.id }.first
    }
}
struct SpeakerMeasurementProvenance: Hashable, Sendable {
    var speakerName: String
    var version: String
    var sourceDisplayName: String
    var retrievedAt: Date
    var isStale: Bool
}
struct SpeakerCEA2034Measurement: Hashable, Sendable {
    var listeningWindow: FrequencyResponse?
    var onAxis: FrequencyResponse?
    var earlyReflections: FrequencyResponse?
    var soundPower: FrequencyResponse?
    var estimatedInRoom: FrequencyResponse?
    var earlyReflectionsDI: FrequencyResponse?
    var soundPowerDI: FrequencyResponse?
    var rawPayload: Data
    var provenance: SpeakerMeasurementProvenance
    var rawPayloadHash: String { Self.hash(rawPayload) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func decode(_ data: Data, provenance: SpeakerMeasurementProvenance) throws -> Self {
        var object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let array = object as? [String], let first = array.first, let inner = first.data(using: .utf8) {
            object = try JSONSerialization.jsonObject(with: inner)
        } else if let string = object as? String, let inner = string.data(using: .utf8) {
            object = try JSONSerialization.jsonObject(with: inner)
        }
        guard let payload = object as? [String: Any], let traces = payload["data"] as? [[String: Any]] else {
            throw SpeakerCorrectionError.invalid("This source did not return compatible CEA2034 data.")
        }
        let recognized: Set<String> = ["Listening Window", "On Axis", "Early Reflections", "Sound Power", "Estimated In-Room Response", "Early Reflections DI", "Sound Power DI"]
        var curves: [String: FrequencyResponse] = [:]
        for trace in traces {
            guard let name = trace["name"] as? String, recognized.contains(name) else { continue }
            let x = try numbers(trace["x"]), y = try numbers(trace["y"])
            guard x.count == y.count, x.count >= 16, x.allSatisfy({ $0.isFinite && $0 > 0 }),
                  y.allSatisfy(\.isFinite), zip(x, x.dropFirst()).allSatisfy({ $0 < $1 }), curves[name] == nil else {
                throw SpeakerCorrectionError.invalid("The CEA2034 measurement has an invalid frequency grid.")
            }
            curves[name] = FrequencyResponse(name: name, points: zip(x, y).map { .init(frequency: $0, magnitudeDB: $1) })
        }
        // Spinorama's CEA2034 plot commonly omits PIR. Reconstruct the
        // standard energy-weighted prediction, as the upstream bundle does.
        if curves["Estimated In-Room Response"] == nil, let lw = curves["Listening Window"],
           let er = curves["Early Reflections"], let sp = curves["Sound Power"] {
            let points = lw.points.compactMap { point -> FrequencyResponse.Point? in
                guard let erDB = er.magnitude(at: point.frequency), let spDB = sp.magnitude(at: point.frequency) else { return nil }
                let power = 0.12 * pow(10, point.magnitudeDB / 10) + 0.44 * pow(10, erDB / 10) + 0.44 * pow(10, spDB / 10)
                return .init(frequency: point.frequency, magnitudeDB: 10 * log10(power))
            }
            if points.count >= 16 { curves["Estimated In-Room Response"] = .init(name: "Predicted In-Room Response", points: points) }
        }
        guard curves["Listening Window"] != nil else { throw SpeakerCorrectionError.invalid("This CEA2034 measurement is missing its Listening Window.") }
        return .init(listeningWindow: curves["Listening Window"], onAxis: curves["On Axis"], earlyReflections: curves["Early Reflections"],
                     soundPower: curves["Sound Power"], estimatedInRoom: curves["Estimated In-Room Response"],
                     earlyReflectionsDI: curves["Early Reflections DI"], soundPowerDI: curves["Sound Power DI"], rawPayload: data, provenance: provenance)
    }
    private static func numbers(_ value: Any?) throws -> [Double] {
        if let array = value as? [NSNumber] { return array.map(\.doubleValue) }
        guard let encoded = value as? [String: Any], let dtype = encoded["dtype"] as? String,
              let base64 = encoded["bdata"] as? String, let data = Data(base64Encoded: base64), ["f8", "f4"].contains(dtype) else {
            throw SpeakerCorrectionError.invalid("The CEA2034 trace has unsupported numeric data.")
        }
        let bytes = [UInt8](data), width = dtype == "f8" ? 8 : 4
        guard bytes.count % width == 0 else { throw SpeakerCorrectionError.invalid("The CEA2034 trace is truncated.") }
        return stride(from: 0, to: bytes.count, by: width).map { offset in
            let bits = (0..<width).reduce(UInt64(0)) { $0 | (UInt64(bytes[offset + $1]) << ($1 * 8)) }
            return width == 8 ? Double(bitPattern: bits) : Double(Float(bitPattern: UInt32(bits)))
        }
    }
}
protocol SpeakerMeasurementProvider: Sendable {
    var id: String { get }
    func currentWarning() async -> String?
    func catalog(refresh: Bool) async throws -> [SpeakerCatalogEntry]
    func metadata(for speaker: SpeakerCatalogEntry, refresh: Bool) async throws -> SpeakerMetadata
    func versions(for speaker: SpeakerCatalogEntry, refresh: Bool) async throws -> [SpeakerMeasurementVersion]
    func cea2034(speaker: SpeakerCatalogEntry, version: SpeakerMeasurementVersion, refresh: Bool) async throws -> SpeakerCEA2034Measurement
}

extension SpeakerMeasurementProvider {
    func currentWarning() async -> String? { nil }
}
