import CamiTuneDomain
import Foundation

/// Dedicated, versioned on-disk store for measurement catalogs and raw responses.
/// Cache schema changes use a new directory so incompatible data is never decoded
/// as current evidence.
final class DeviceMeasurementCache: @unchecked Sendable {
    static let schemaVersion = 4

    private struct Envelope<Value: Codable>: Codable {
        var schemaVersion: Int
        var savedAt: Date
        var value: Value
    }

    private let root: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        root: URL = CamiTunePaths.supportDirectory
            .appendingPathComponent("DeviceCorrectionCache", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.root = root.appendingPathComponent("v\(Self.schemaVersion)", isDirectory: true)
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadCatalog(providerID: String, maximumAge: TimeInterval?) throws
        -> [DeviceCatalogEntry]? {
        try load(from: catalogURL(providerID: providerID), maximumAge: maximumAge)
    }

    func saveCatalog(_ entries: [DeviceCatalogEntry], providerID: String) throws {
        try save(entries, to: catalogURL(providerID: providerID))
    }

    func loadMeasurement(
        referenceID: String,
        maximumAge: TimeInterval? = nil
    ) throws -> DeviceCorrectionMeasurement? {
        try load(from: measurementURL(referenceID: referenceID), maximumAge: maximumAge)
    }

    func saveMeasurement(
        _ measurement: DeviceCorrectionMeasurement,
        referenceID: String
    ) throws {
        try save(measurement, to: measurementURL(referenceID: referenceID))
    }

    private func load<Value: Codable>(from url: URL, maximumAge: TimeInterval?) throws -> Value? {
        try synchronized {
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let envelope = try decoder.decode(Envelope<Value>.self, from: Data(contentsOf: url))
            guard envelope.schemaVersion == Self.schemaVersion else { return nil }
            if let maximumAge, Date().timeIntervalSince(envelope.savedAt) > maximumAge {
                return nil
            }
            return envelope.value
        }
    }

    private func save<Value: Codable>(_ value: Value, to url: URL) throws {
        try synchronized {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let envelope = Envelope(schemaVersion: Self.schemaVersion, savedAt: Date(), value: value)
            try encoder.encode(envelope).write(to: url, options: .atomic)
        }
    }

    private func catalogURL(providerID: String) -> URL {
        root.appendingPathComponent(
            "catalog-\(StableContentHash.string(providerID)).json",
            isDirectory: false
        )
    }

    private func measurementURL(referenceID: String) -> URL {
        root.appendingPathComponent(
            "measurement-\(StableContentHash.string(referenceID)).json",
            isDirectory: false
        )
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
