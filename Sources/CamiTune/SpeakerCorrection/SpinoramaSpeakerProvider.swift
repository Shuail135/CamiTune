import CamiTuneDomain
import Foundation

/// Uses the public website's catalog and Plotly measurement files. The separate
/// hosted API requires private credentials and is not used by the application.
actor SpinoramaSpeakerProvider: SpeakerMeasurementProvider {
    nonisolated let id = "spinorama"
    static let shared = SpinoramaSpeakerProvider()
    private let session: URLSession
    private let cache: SpeakerMeasurementCache
    private let baseURL: URL
    private var loadedCatalog: (retrievedAt: Date, speakers: [String: SpeakerMetadata])?
    private var warning: String?

    init(session: URLSession = .shared, cacheDirectory: URL? = nil,
         baseURL: URL = URL(string: "https://www.spinorama.org")!) {
        self.session = session
        self.baseURL = baseURL
        self.cache = .init(directory: cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CamiTune/Spinorama", isDirectory: true))
    }

    private struct HTTPFailure: LocalizedError {
        let status: Int
        var errorDescription: String? {
            switch status {
            case 401, 403: return "Spinorama denied access to this public data file (HTTP \(status))."
            case 404: return "This measurement is not available from Spinorama (HTTP 404)."
            default: return "Spinorama could not serve this data file (HTTP \(status))."
            }
        }
    }

    private func fetch<Value>(_ components: [String], refresh: Bool, maximumBytes: Int = 4 * 1024 * 1024,
                              decode: (SpeakerMeasurementCache.Entry) throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let url = components.reduce(baseURL) { $0.appendingPathComponent($1) }
        // Include the origin so old API responses cannot masquerade as website data.
        let key = url.absoluteString
        let saved = cache.read(key)
        if !refresh, let saved, Date().timeIntervalSince(saved.retrievedAt) < 7 * 86_400 {
            return try decode(saved)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 else { throw HTTPFailure(status: http.statusCode) }
            guard data.count <= maximumBytes else {
                throw SpeakerCorrectionError.invalid("Spinorama returned an oversized data file.")
            }
            let entry = SpeakerMeasurementCache.Entry(data: data, retrievedAt: Date())
            let value = try decode(entry)
            try cache.write(entry, key: key)
            return value
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            // Only connection/server failures permit stale data. A withdrawn,
            // denied or malformed source must remain an explicit failure.
            let transient = error is URLError || (error as? HTTPFailure).map { $0.status >= 500 } == true
            if transient, var saved {
                saved.isStale = true
                let value = try decode(saved)
                warning = "Could not refresh Spinorama. Using cached data. \(error.localizedDescription)"
                return value
            }
            throw error
        }
    }

    private func readCatalog(refresh: Bool) async throws -> [String: SpeakerMetadata] {
        try Task.checkCancellation()
        if !refresh, let loadedCatalog, Date().timeIntervalSince(loadedCatalog.retrievedAt) < 7 * 86_400 {
            return loadedCatalog.speakers
        }
        return try await fetch(["json", "metadata.json"], refresh: refresh, maximumBytes: 16 * 1024 * 1024) { entry in
            if let loadedCatalog, loadedCatalog.retrievedAt == entry.retrievedAt { return loadedCatalog.speakers }
            guard let object = try JSONSerialization.jsonObject(with: entry.data) as? [String: [String: Any]], !object.isEmpty else {
                throw SpeakerCorrectionError.invalid("Spinorama returned an incompatible speaker catalog.")
            }
            var speakers: [String: SpeakerMetadata] = [:]
            for (name, value) in object where value["kind"] as? String != "headphone" {
                speakers[name] = try SpeakerMetadata.decode(JSONSerialization.data(withJSONObject: value))
            }
            loadedCatalog = (entry.retrievedAt, speakers)
            return speakers
        }
    }

    func currentWarning() async -> String? { warning }

    func catalog(refresh: Bool = false) async throws -> [SpeakerCatalogEntry] {
        warning = nil
        return try await readCatalog(refresh: refresh).keys.sorted().map { .init(name: $0) }
    }

    func metadata(for speaker: SpeakerCatalogEntry, refresh: Bool = false) async throws -> SpeakerMetadata {
        guard let metadata = try await readCatalog(refresh: refresh)[speaker.name] else {
            throw SpeakerCorrectionError.invalid("This speaker is no longer in Spinorama's catalog. Refresh the speaker list.")
        }
        return metadata
    }

    func versions(for speaker: SpeakerCatalogEntry, refresh: Bool = false) async throws -> [SpeakerMeasurementVersion] {
        warning = nil
        let metadata = try await metadata(for: speaker, refresh: refresh)
        var versions: [SpeakerMeasurementVersion] = []
        for (name, origin) in metadata.origins.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            var version = SpeakerMeasurementVersion(id: name, sourceDisplayName: SpeakerMetadata.sourceName(origin), measurements: [])
            do {
                // The public catalog has no graph listing. Validate the actual
                // CEA2034 file once, then reuse its cache during optimization.
                _ = try await measurement(speaker: speaker, version: version, origin: origin, refresh: refresh)
                version.measurements = ["CEA2034"]
            } catch let error as HTTPFailure where error.status == 404 {
                // Other sources for this speaker can still be available.
            } catch let error as SpeakerCorrectionError {
                warning = error.localizedDescription
            }
            versions.append(version)
        }
        return versions
    }

    func cea2034(speaker: SpeakerCatalogEntry, version: SpeakerMeasurementVersion, refresh: Bool = false) async throws -> SpeakerCEA2034Measurement {
        warning = nil
        guard version.supportsCEA2034 else {
            throw SpeakerCorrectionError.invalid("This version has no compatible CEA2034 measurement. Choose another source.")
        }
        let metadata = try await metadata(for: speaker, refresh: false)
        guard let origin = metadata.origins[version.id] else {
            throw SpeakerCorrectionError.invalid("This measurement version is no longer in Spinorama's catalog.")
        }
        return try await measurement(speaker: speaker, version: version, origin: origin, refresh: refresh)
    }

    private func measurement(speaker: SpeakerCatalogEntry, version: SpeakerMeasurementVersion, origin: String,
                             refresh: Bool) async throws -> SpeakerCEA2034Measurement {
        let folder = origin.hasPrefix("Vendors-") ? String(origin.dropFirst(8)) : origin
        // Match the website's published filename convention, and keep remote
        // metadata inside one path component.
        func filename(_ value: String) throws -> String {
            guard !value.isEmpty, value != ".", value != ".." else {
                throw SpeakerCorrectionError.invalid("Spinorama returned an invalid measurement path.")
            }
            return String(value.map { "|:<>\"\\/?*".contains($0) ? "_" : $0 })
        }
        let path = try ["speakers", filename(speaker.name), filename(folder), filename(version.id), "CEA2034.json"]
        return try await fetch(path, refresh: refresh) { entry in
            try SpeakerCEA2034Measurement.decode(entry.data, provenance: .init(speakerName: speaker.name, version: version.id,
                sourceDisplayName: version.sourceDisplayName, retrievedAt: entry.retrievedAt, isStale: entry.isStale))
        }
    }
}
