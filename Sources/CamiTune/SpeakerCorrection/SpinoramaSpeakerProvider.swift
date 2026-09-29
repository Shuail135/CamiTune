import CamiTuneDomain
import Foundation

actor SpinoramaSpeakerProvider: SpeakerMeasurementProvider {
    nonisolated let id = "spinorama"
    static let shared = SpinoramaSpeakerProvider()
    private let session: URLSession
    private let cache: SpeakerMeasurementCache
    private let baseURL: URL
    private(set) var offlineWarning: String?
    init(session: URLSession = .shared, cacheDirectory: URL? = nil, baseURL: URL = URL(string: "https://api.spinorama.org/v1")!) {
        self.session = session; self.baseURL = baseURL
        self.cache = .init(directory: cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CamiTune/Spinorama", isDirectory: true))
    }
    private func fetch(_ components: [String], refresh: Bool, ttl: TimeInterval = 7 * 86_400) async throws -> SpeakerMeasurementCache.Entry {
        let key = components.joined(separator: "/"), saved = cache.read(key)
        if !refresh, let saved, Date().timeIntervalSince(saved.retrievedAt) < ttl { return saved }
        let url = components.reduce(baseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url); request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 4 * 1024 * 1024 else {
                throw SpeakerCorrectionError.invalid("Spinorama returned an unavailable or oversized measurement.")
            }
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if let error = (object as? [String: Any])?["error"] as? String { throw SpeakerCorrectionError.invalid(error) }
            let entry = SpeakerMeasurementCache.Entry(data: data, retrievedAt: Date())
            try cache.write(entry, key: key)
            offlineWarning = nil
            return entry
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if var saved {
                saved.isStale = true
                offlineWarning = "Could not refresh Spinorama. Using the last cached measurement."
                return saved
            }
            throw SpeakerCorrectionError.invalid("Speaker measurement is unavailable offline. \(error.localizedDescription)")
        }
    }
    func currentWarning() async -> String? { offlineWarning }
    func catalog(refresh: Bool = false) async throws -> [SpeakerCatalogEntry] {
        let data = try await fetch(["speakers"], refresh: refresh).data
        return try JSONDecoder().decode([String].self, from: data).sorted().map { .init(name: $0) }
    }
    func metadata(for speaker: SpeakerCatalogEntry, refresh: Bool = false) async throws -> SpeakerMetadata {
        try await SpeakerMetadata.decode(fetch(["speaker", speaker.name, "metadata"], refresh: refresh).data)
    }
    func versions(for speaker: SpeakerCatalogEntry, refresh: Bool = false) async throws -> [SpeakerMeasurementVersion] {
        let metadata = try await metadata(for: speaker, refresh: refresh)
        let data = try await fetch(["speaker", speaker.name, "versions"], refresh: refresh).data
        let names = try JSONDecoder().decode([String].self, from: data)
        var versions: [SpeakerMeasurementVersion] = []
        for name in names.sorted() {
            try Task.checkCancellation()
            do {
                let payload = try await fetch(["speaker", speaker.name, "version", name, "measurements"], refresh: refresh).data
                let measurements = try JSONDecoder().decode([String].self, from: payload)
                versions.append(.init(id: name, sourceDisplayName: metadata.sources[name] ?? name, measurements: measurements))
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // One unavailable source must not hide other cached versions.
                versions.append(.init(id: name, sourceDisplayName: metadata.sources[name] ?? name, measurements: []))
            }
        }
        return versions
    }
    func cea2034(speaker: SpeakerCatalogEntry, version: SpeakerMeasurementVersion, refresh: Bool = false) async throws -> SpeakerCEA2034Measurement {
        guard version.supportsCEA2034 else { throw SpeakerCorrectionError.invalid("This version has no compatible CEA2034 measurement. Choose another source.") }
        let entry = try await fetch(["speaker", speaker.name, "version", version.id, "measurements", "CEA2034"], refresh: refresh, ttl: .infinity)
        return try SpeakerCEA2034Measurement.decode(entry.data, provenance: .init(speakerName: speaker.name, version: version.id,
            sourceDisplayName: version.sourceDisplayName, retrievedAt: entry.retrievedAt, isStale: entry.isStale))
    }
}
