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
        try synchronized {
            let url = catalogURL(providerID: providerID)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let envelope = try decoder.decode(
                Envelope<[DeviceCatalogEntry]>.self,
                from: Data(contentsOf: url)
            )
            guard envelope.schemaVersion == Self.schemaVersion else { return nil }
            if let maximumAge, Date().timeIntervalSince(envelope.savedAt) > maximumAge {
                return nil
            }
            return envelope.value
        }
    }

    func saveCatalog(_ entries: [DeviceCatalogEntry], providerID: String) throws {
        try synchronized {
            try prepareDirectory()
            let envelope = Envelope(
                schemaVersion: Self.schemaVersion,
                savedAt: Date(),
                value: entries
            )
            try encoder.encode(envelope).write(
                to: catalogURL(providerID: providerID),
                options: .atomic
            )
        }
    }

    func loadMeasurement(
        referenceID: String,
        maximumAge: TimeInterval? = nil
    ) throws -> DeviceCorrectionMeasurement? {
        try synchronized {
            let url = measurementURL(referenceID: referenceID)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let envelope = try decoder.decode(
                Envelope<DeviceCorrectionMeasurement>.self,
                from: Data(contentsOf: url)
            )
            guard envelope.schemaVersion == Self.schemaVersion else { return nil }
            if let maximumAge, Date().timeIntervalSince(envelope.savedAt) > maximumAge {
                return nil
            }
            return envelope.value
        }
    }

    func saveMeasurement(
        _ measurement: DeviceCorrectionMeasurement,
        referenceID: String
    ) throws {
        try synchronized {
            try prepareDirectory()
            let envelope = Envelope(
                schemaVersion: Self.schemaVersion,
                savedAt: Date(),
                value: measurement
            )
            try encoder.encode(envelope).write(
                to: measurementURL(referenceID: referenceID),
                options: .atomic
            )
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

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
