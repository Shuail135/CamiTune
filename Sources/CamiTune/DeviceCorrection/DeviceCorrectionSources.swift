import CamiTuneDomain
import Foundation

/// Structured acoustic-fixture identity used for compatibility decisions.
/// `rig` remains presentation/provenance text; matching never compares that
/// free-form string directly once this value has been resolved.

/// Stable device and configuration identity. Presentation names may change;
/// switch positions, pads, nozzles, ANC modes, and other variants do not share
/// a configuration ID with the base model.

/// Persisted provenance for one response used to build a correction. The UI deliberately
/// does not expose these as separate search results: users select a device/configuration,
/// then the catalog resolves all compatible measurements behind that selection.

struct DeviceCorrectionMeasurement: Codable, Hashable, Sendable {
    var source: DeviceMeasurementReference
    var response: FrequencyResponse
    var snapshot: MeasurementSnapshot? = nil

    static func local(response: FrequencyResponse, originalData: Data? = nil) -> Self {
        let encoded: Data
        if let originalData {
            encoded = originalData
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoded = (try? encoder.encode(response)) ?? Data(response.name.utf8)
        }
        let hash = StableContentHash.data(encoded)
        var source = DeviceMeasurementReference.local(name: response.name)
        source.deviceIdentity = .inferred(from: response.name)
        source.laboratoryID = "local-user"
        // File identity is not evidence of a different physical sample.
        source.unitID = nil
        source.measurementID = hash
        source.datasetID = "local-csv"
        return .init(
            source: source,
            response: response,
            snapshot: .init(
                providerID: "local",
                datasetID: "local-csv",
                datasetVersion: nil,
                measurementID: hash,
                contentHash: hash,
                retrievedAt: Date()
            )
        )
    }
}

struct DeviceCatalogEntry: Codable, Hashable, Sendable, Identifiable {
    var displayName: String
    var measurements: [DeviceMeasurementReference]
    var identity: DeviceConfigurationIdentity

    var id: String { identity.stableKey }

    init(
        displayName: String,
        measurements: [DeviceMeasurementReference],
        identity: DeviceConfigurationIdentity? = nil
    ) {
        self.displayName = displayName
        self.measurements = measurements
        self.identity = identity ?? .inferred(from: displayName)
    }
}

/// Manually reviewed spelling/model aliases. Rules replace only an exact name
/// or an exact leading token sequence; every unknown suffix (switch, nozzle,
/// pad, revision, ANC mode, and so on) remains part of configuration identity.

enum DeviceCatalogSearch {
    struct Index: Sendable {
        struct Row: Sendable {
            var entry: DeviceCatalogEntry
            var key: String
            var compact: String
            var identity: String
            var compatibilityKeys: Set<String>
        }
        let id = UUID()
        private let rows: [Row]

        init(entries: [DeviceCatalogEntry]) {
            rows = entries.sorted {
                if $0.displayName.count != $1.displayName.count { return $0.displayName.count < $1.displayName.count }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }.map {
                let key = DeviceNameAliasCatalog.canonicalKey(for: $0.displayName)
                return Row(entry: $0, key: key, compact: key.replacingOccurrences(of: " ", with: ""),
                           identity: $0.identity.stableKey, compatibilityKeys: Set($0.measurements.map(\.compatibilityKey)))
            }
        }

        func hasCompatibleDevice(keys: Set<String>, excluding identity: String?) -> Bool {
            !keys.isEmpty && rows.contains { $0.identity != identity && !$0.compatibilityKeys.isDisjoint(with: keys) }
        }

        func results(matching query: String, limit: Int = 40, compatibleKeys: Set<String>? = nil, excluding identity: String? = nil) -> [DeviceCatalogEntry] {
            let key = DeviceNameAliasCatalog.canonicalKey(for: query)
            guard !key.isEmpty, limit > 0 else { return [] }
            let compact = key.replacingOccurrences(of: " ", with: "")
            let tokens = key.split(separator: " ").map(String.init)
            var buckets = [[DeviceCatalogEntry](), [], []]
            for row in rows {
                if let identity, row.identity == identity { continue }
                if let compatibleKeys, row.compatibilityKeys.isDisjoint(with: compatibleKeys) { continue }
                guard row.compact.contains(compact) || tokens.allSatisfy(row.compact.contains) else { continue }
                let rank = row.compact == compact ? 0 : (row.compact.hasPrefix(compact) ? 1 : 2)
                if buckets[rank].count < limit { buckets[rank].append(row.entry) }
            }
            return Array(buckets.joined().prefix(limit))
        }
    }

    struct Request: Hashable {
        var query: String
        var indexID: UUID
        var compatibleKeys: Set<String>? = nil
        var excludedIdentity: String? = nil
    }

    static func results(in entries: [DeviceCatalogEntry], matching query: String, limit: Int = 40) -> [DeviceCatalogEntry] {
        Index(entries: entries).results(matching: query, limit: limit)
    }
}

enum DeviceMatchPlanner {
    static func compatibleReferences(
        in targetEntry: DeviceCatalogEntry,
        sourceReferences: [DeviceMeasurementReference]
    ) -> [DeviceMeasurementReference] {
        let sourceKeys = Set(sourceReferences.map(\.compatibilityKey))
        guard !sourceKeys.isEmpty else { return [] }
        return targetEntry.measurements.filter {
            sourceKeys.contains($0.compatibilityKey)
        }
    }

    static func isCompatible(
        sourceReferences: [DeviceMeasurementReference],
        targetReferences: [DeviceMeasurementReference]
    ) -> Bool {
        let sourceKeys = Set(sourceReferences.map(\.compatibilityKey))
        let targetKeys = Set(targetReferences.map(\.compatibilityKey))
        return !sourceKeys.isEmpty && !sourceKeys.isDisjoint(with: targetKeys)
    }
}

protocol DeviceMeasurementProvider: Sendable {
    var id: String { get }
    func catalog(refresh: Bool) async throws -> [DeviceCatalogEntry]
    func measurement(
        for reference: DeviceMeasurementReference,
        refresh: Bool
    ) async throws
        -> DeviceCorrectionMeasurement
}

struct DeviceMeasurementCatalog: Sendable {
    private let providers: [any DeviceMeasurementProvider]

    init(providers: [any DeviceMeasurementProvider]) {
        self.providers = providers
    }

    static var online: DeviceMeasurementCatalog {
        DeviceMeasurementCatalog(providers: [AutoEqMeasurementProvider()])
    }

    func entries(refresh: Bool = false) async throws -> [DeviceCatalogEntry] {
        let providerEntries = await withTaskGroup(
            of: (Int, [DeviceCatalogEntry]?).self,
            returning: [(Int, [DeviceCatalogEntry])].self
        ) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    (index, try? await provider.catalog(refresh: refresh))
                }
            }
            var result: [(Int, [DeviceCatalogEntry])] = []
            for await (index, entries) in group {
                if let entries, !entries.isEmpty { result.append((index, entries)) }
            }
            // Task groups yield in completion order. Restore provider priority
            // before merging so a slow network response cannot change which
            // spelling/provenance becomes canonical.
            return result.sorted { $0.0 < $1.0 }
        }
        guard !providerEntries.isEmpty else { throw SourceError.downloadFailed }

        var merged: [String: DeviceCatalogEntry] = [:]
        for entry in providerEntries.flatMap(\.1) {
            let key = entry.identity.stableKey
            guard !key.isEmpty else { continue }
            if var existing = merged[key] {
                var known = Set(existing.measurements.map(\.id))
                existing.measurements.append(contentsOf: entry.measurements.filter {
                    known.insert($0.id).inserted
                })
                merged[key] = existing
            } else {
                var unique = entry
                var known = Set<String>()
                unique.measurements = entry.measurements.filter {
                    known.insert($0.id).inserted
                }
                merged[key] = unique
            }
        }
        return merged.values.map { entry in
            var entry = entry
            entry.measurements.sort(by: MeasurementSetPlanner.isOrderedBefore)
            return entry
        }.sorted {
            let comparison = $0.displayName.localizedStandardCompare($1.displayName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.id < $1.id
        }
    }

    func measurements(
        for entry: DeviceCatalogEntry,
        refresh: Bool = false
    ) async throws
        -> [DeviceCorrectionMeasurement] {
        let selected = Dictionary(grouping: entry.measurements, by: \.compatibilityKey)
            .sorted { $0.key < $1.key }.flatMap { MeasurementSetPlanner.references(from: $0.value) }
        guard !selected.isEmpty else { throw SourceError.noCompatibleMeasurements }
        let providersByID = Dictionary(
            providers.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let loaded = await withTaskGroup(of: DeviceCorrectionMeasurement?.self) { group in
            for reference in selected {
                guard let provider = providersByID[reference.resolvedRetrievalProviderID]
                else { continue }
                group.addTask {
                    try? await provider.measurement(for: reference, refresh: refresh)
                }
            }
            var result: [DeviceCorrectionMeasurement] = []
            for await measurement in group {
                if let measurement { result.append(measurement) }
            }
            return result
        }
        guard !loaded.isEmpty else { throw SourceError.downloadFailed }
        return loaded.sorted {
            if $0.source.reliability != $1.source.reliability {
                return $0.source.reliability > $1.source.reliability
            }
            return MeasurementSetPlanner.isOrderedBefore($0.source, $1.source)
        }
    }

    enum SourceError: LocalizedError {
        case noCompatibleMeasurements
        case downloadFailed

        var errorDescription: String? {
            switch self {
            case .noCompatibleMeasurements:
                return "No compatible frequency-response measurements are available for this configuration."
            case .downloadFailed:
                return "The measurements could not be downloaded. Check your connection and try again."
            }
        }
    }
}

enum MeasurementSetPlanner {
    static func references(
        from references: [DeviceMeasurementReference],
        maximumCount: Int = 8
    ) -> [DeviceMeasurementReference] {
        let deduplicated = Dictionary(references.map { ($0.id, $0) }, uniquingKeysWith: {
            if $0.reliability != $1.reliability {
                return $0.reliability > $1.reliability ? $0 : $1
            }
            return isOrderedBefore($0, $1) ? $0 : $1
        }).values.sorted(by: isOrderedBefore)
        let groups = Dictionary(grouping: deduplicated, by: \.compatibilityKey)
        guard let best = groups.sorted(by: { lhs, rhs in
            let leftScore = score(lhs.value)
            let rightScore = score(rhs.value)
            if leftScore != rightScore { return leftScore > rightScore }
            return lhs.key < rhs.key
        }).first?.value else { return [] }
        let evidence = Dictionary(grouping: best, by: \.independentEvidenceKey)
            .sorted { lhs, rhs in
                let leftScore = score(lhs.value)
                let rightScore = score(rhs.value)
                if leftScore != rightScore { return leftScore > rightScore }
                return lhs.key < rhs.key
            }
            .prefix(max(1, maximumCount))
        return evidence.flatMap { _, group in
            group.sorted {
                if $0.reliability != $1.reliability {
                    return $0.reliability > $1.reliability
                }
                return isOrderedBefore($0, $1)
            }
        }
    }

    static func isOrderedBefore(
        _ lhs: DeviceMeasurementReference,
        _ rhs: DeviceMeasurementReference
    ) -> Bool {
        stableSortKey(lhs) < stableSortKey(rhs)
    }

    private static func score(_ references: [DeviceMeasurementReference]) -> Double {
        let independent = Dictionary(grouping: references, by: \.independentEvidenceKey)
        return Double(independent.count) * 2
            + independent.values.compactMap { $0.map(\.reliability).max() }.reduce(0, +)
    }

    private static func stableSortKey(_ reference: DeviceMeasurementReference) -> String {
        [
            reference.id,
            reference.resolvedRetrievalProviderID,
            reference.datasetID ?? "",
            reference.datasetVersion ?? "",
            reference.sourceName,
            reference.form ?? "",
            reference.resolvedRigIdentity.stableKey
        ].joined(separator: "\u{1f}")
    }
}

struct AutoEqMeasurementProvider: DeviceMeasurementProvider, @unchecked Sendable {
    let id = "autoeq-measurements"
    private static let rawMeasurementMaximumAge: TimeInterval = 30 * 24 * 60 * 60

    private let baseURL: URL
    private let session: URLSession
    private let cache: DeviceMeasurementCache

    init(
        baseURL: URL = URL(string: "https://autoeq.app")!,
        session: URLSession = .shared,
        cache: DeviceMeasurementCache = DeviceMeasurementCache()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.cache = cache
    }

    func catalog(refresh: Bool = false) async throws -> [DeviceCatalogEntry] {
        if !refresh,
           let cached = try? cache.loadCatalog(
            providerID: id,
            maximumAge: 7 * 24 * 60 * 60
           ) {
            return cached
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("entries"))
        request.timeoutInterval = 25
        request.cachePolicy = refresh
            ? .reloadIgnoringLocalCacheData
            : .useProtocolCachePolicy
        request.setValue("CamiTune Device Correction", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            try Self.validate(response)
            let decoded = try JSONDecoder().decode([String: [Entry]].self, from: data)
            let version = Self.datasetVersion(from: response)
            let entries = Self.catalogEntries(
                from: decoded,
                providerID: id,
                datasetVersion: version,
                catalogHash: StableContentHash.data(data)
            )
            try? cache.saveCatalog(entries, providerID: id)
            return entries
        } catch {
            if let stale = try? cache.loadCatalog(providerID: id, maximumAge: nil) { return stale }
            throw error
        }
    }

    func measurement(
        for reference: DeviceMeasurementReference,
        refresh: Bool = false
    ) async throws
        -> DeviceCorrectionMeasurement {
        if !refresh,
           let cached = try? cache.loadMeasurement(
               referenceID: reference.id,
               maximumAge: Self.rawMeasurementMaximumAge
           ),
           reference.datasetVersion == nil
            || cached.source.datasetVersion == reference.datasetVersion {
            return cached
        }
        let staleFallback = refresh
            ? nil
            : try? cache.loadMeasurement(referenceID: reference.id)
        var request = URLRequest(url: baseURL.appendingPathComponent("equalize"))
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CamiTune Device Correction", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(MeasurementRequest(
            name: reference.catalogName,
            source: reference.sourceName,
            rig: reference.rig,
            response: .init(frFields: ["frequency", "raw"])
        ))
        do {
            let (data, response) = try await session.data(for: request)
            try Self.validate(response)
            let decoded = try JSONDecoder().decode(MeasurementResponse.self, from: data)
            guard decoded.fr.frequency.count == decoded.fr.raw.count else {
                throw ProviderError.invalidResponse
            }
            let points = zip(decoded.fr.frequency, decoded.fr.raw).map {
                FrequencyResponse.Point(frequency: $0.0, magnitudeDB: $0.1)
            }
            let frequencyResponse = FrequencyResponse(name: reference.catalogName, points: points)
            guard frequencyResponse.points.count >= 24 else {
                throw ProviderError.invalidResponse
            }
            let responseVersion = Self.datasetVersion(from: response)
            var refreshedReference = reference
            if let responseVersion { refreshedReference.datasetVersion = responseVersion }
            let snapshot = MeasurementSnapshot(
                providerID: reference.providerID,
                retrievalProviderID: id,
                datasetID: reference.datasetID ?? "autoeq-api",
                datasetVersion: responseVersion ?? reference.datasetVersion,
                measurementID: reference.measurementID ?? reference.id,
                contentHash: StableContentHash.data(data),
                retrievedAt: Date()
            )
            let measurement = DeviceCorrectionMeasurement(
                source: refreshedReference,
                response: frequencyResponse,
                snapshot: snapshot
            )
            try? cache.saveMeasurement(measurement, referenceID: reference.id)
            return measurement
        } catch {
            // Stale data is an offline fallback, not a successful refresh. Its
            // original cache timestamp remains unchanged, so the next load will
            // attempt the network again instead of making it permanently fresh.
            if let staleFallback { return staleFallback }
            throw error
        }
    }

    static func catalogEntries(
        from entries: [String: [Entry]],
        providerID retrievalProviderID: String = "autoeq-measurements",
        datasetVersion: String? = nil,
        catalogHash: String? = nil
    ) -> [DeviceCatalogEntry] {
        entries.compactMap { name, sources in
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return nil }
            let identity = DeviceConfigurationIdentity.inferred(from: trimmedName)
            let references = sources.map { source in
                let attribution = attribution(for: source.source)
                return DeviceMeasurementReference(
                    providerID: attribution.providerID,
                    retrievalProviderID: retrievalProviderID,
                    catalogName: trimmedName,
                    sourceName: source.source,
                    form: source.form,
                    rig: source.rig,
                    origin: attribution.origin,
                    reliability: reliability(for: source.source),
                    deviceIdentity: identity,
                    laboratoryID: DeviceNameNormalizer.key(for: source.source),
                    unitID: nil,
                    measurementID: StableContentHash.string([
                        trimmedName, source.source, source.rig ?? ""
                    ].joined(separator: "|")),
                    datasetID: attribution.datasetID,
                    datasetVersion: datasetVersion ?? catalogHash,
                    rigIdentity: .inferred(fromLegacyName: source.rig)
                )
            }
            return DeviceCatalogEntry(
                displayName: trimmedName,
                measurements: references,
                identity: identity
            )
        }
    }

    struct Entry: Codable, Hashable, Sendable {
        var form: String?
        var rig: String?
        var source: String
    }

    private struct MeasurementRequest: Encodable {
        struct ResponseOptions: Encodable {
            var frFields: [String]

            enum CodingKeys: String, CodingKey {
                case frFields = "fr_fields"
            }
        }

        var name: String
        var source: String
        var rig: String?
        var response: ResponseOptions
    }

    private struct MeasurementResponse: Decodable {
        struct Response: Decodable {
            var frequency: [Double]
            var raw: [Double]
        }

        var fr: Response
    }

    private enum ProviderError: LocalizedError {
        case server(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .server(let status): return "The measurement service returned HTTP \(status)."
            case .invalidResponse: return "The measurement service returned invalid frequency-response data."
            }
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw ProviderError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private static func datasetVersion(from response: URLResponse) -> String? {
        guard let response = response as? HTTPURLResponse else { return nil }
        return response.value(forHTTPHeaderField: "ETag")
            ?? response.value(forHTTPHeaderField: "Last-Modified")
    }

    private static func reliability(for source: String) -> Double {
        switch source.lowercased() {
        case "oratory1990": return 1
        case "crinacle": return 0.97
        case "rtings", "innerfidelity", "headphone.com legacy": return 0.94
        case "hypethesonics", "kuulokenurkka": return 0.9
        default: return squiglinkSourceKeys.contains(
            DeviceNameNormalizer.key(for: source)
        ) ? 0.84 : 0.8
        }
    }

    private static func attribution(
        for source: String
    ) -> (
        providerID: String,
        origin: DeviceMeasurementOrigin,
        datasetID: String
    ) {
        if squiglinkSourceKeys.contains(DeviceNameNormalizer.key(for: source)) {
            return ("squiglink", .squiglink, "squiglink-via-autoeq-api")
        }
        let key = DeviceNameNormalizer.key(for: source)
        if independentSources.contains(key) {
            return (
                "independent:\(key)",
                .independent,
                "independent:\(key)-via-autoeq-api"
            )
        }
        // AutoEQ is provenance only for responses that are unique to its own
        // catalog. It remains the retrieval transport for every entry above.
        return ("autoeq-measurements", .autoEq, "autoeq-api")
    }

    private static let independentSources: Set<String> = [
        "oratory1990", "crinacle", "rtings", "innerfidelity",
        "headphone com legacy", "hypethesonics"
    ]

    private static let squiglinkSourceKeys: Set<String> = [
        "auriculares argentina", "bakkwatan", "dhrme", "fahryst", "filk",
        "freeryder05", "harpo", "hi end portable", "jaytiss", "kazi", "kr0mka",
        "kuulokenurkka", "regan cipher", "rikudougoku", "super review",
        "ted s squig hoard", "tonedeafmonk"
    ]
}
