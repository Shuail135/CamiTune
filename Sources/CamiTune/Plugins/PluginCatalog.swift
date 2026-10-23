import CamiTuneDomain
import Foundation
import Combine

@MainActor
final class PluginCatalog: ObservableObject {
    typealias Scanner = @Sendable ([String]) async throws -> [AudioPluginDescriptor]
    @Published private(set) var plugins: [AudioPluginDescriptor] = []
    @Published private(set) var customDirectories: [URL] = []
    @Published private(set) var isScanning = false
    @Published private(set) var resolvingName: String?
    @Published private(set) var progress = ""
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var errorMessage: String?
    private var scanTask: Task<Void, Never>?
    private var cacheTask: Task<Void, Never>?
    private var cacheWriteTask: Task<String?, Never>?
    private var bundles: [String: PluginDiscovery.BundleRecord] = [:]
    private let cacheURL: URL
    private let standardDirectories: [URL]
    private let scanner: Scanner
    var isBusy: Bool { isScanning || resolvingName != nil }

    private struct Cache: Codable {
        var plugins: [AudioPluginDescriptor]
        var failures: [String: String]
        // Optional fields preserve catalogs saved before custom folders and lazy discovery.
        var customDirectories: [String]?
        var bundles: [String: PluginDiscovery.BundleRecord]?
    }
    init(directory: URL = CamiTunePaths.supportDirectory, standardDirectories: [URL]? = nil,
         scanner: @escaping Scanner = { try await PluginCatalog.scanProcess($0) }) {
        cacheURL = directory.appendingPathComponent("PluginCatalog.json")
        self.standardDirectories = standardDirectories ?? [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/VST3"),
            URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3")]
        self.scanner = scanner
    }

    func load() async {
        if let cacheTask { await cacheTask.value; return }
        let url = cacheURL
        let task = Task {
            if let cached = await Task.detached(priority: .utility, operation: {
                guard let data = try? Data(contentsOf: url) else { return Cache?.none }
                return try? JSONDecoder().decode(Cache.self, from: data)
            }).value {
                plugins = cached.plugins; failures = cached.failures
                customDirectories = PluginDiscovery.uniqueDirectories((cached.customDirectories ?? []).map { URL(fileURLWithPath: $0) })
                bundles = cached.bundles ?? [:]
            }
        }
        cacheTask = task
        await task.value
    }

    func addDirectories(_ urls: [URL]) async {
        await load()
        guard !isBusy else { return }
        customDirectories = PluginDiscovery.uniqueDirectories(customDirectories + urls.filter(\.isFileURL))
        await saveCache()
    }
    func removeDirectory(_ url: URL) async {
        guard !isBusy else { return }
        customDirectories.removeAll { $0 == url }
        await saveCache()
    }

    func scan() {
        guard !isBusy else { return }
        isScanning = true; errorMessage = nil; progress = "Reading plug-in folders…"
        scanTask = Task { [weak self] in
            guard let self else { return }
            defer { isScanning = false; progress = ""; scanTask = nil }
            await load()
            let roots = standardDirectories + customDirectories, cached = bundles
            let worker = Task.detached(priority: .utility) { try PluginDiscovery.discover(in: roots, cached: cached) }
            do {
                let discovered = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                bundles = discovered
                // Audio Unit discovery reads the macOS registry; it does not instantiate effects.
                progress = "Finding Audio Units…"
                var audioUnits = plugins.filter { $0.format == .audioUnit }
                do { audioUnits = try await scanner(["--scan-au"]) }
                catch { if Task.isCancelled { throw CancellationError() }; errorMessage = error.localizedDescription }
                try Task.checkCancellation()
                plugins = Self.sortedUnique(audioUnits + discovered.keys.sorted().flatMap { discovered[$0]?.plugins ?? [] })
                failures = failures.filter { discovered[$0.key] != nil }
                await saveCache()
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
    }
    func cancelScan() { scanTask?.cancel() }

    func clearFailures() async {
        guard !isBusy else { return }
        failures = [:]
        await saveCache()
    }

    /// Only explicit Add loads a VST3 factory. A bundle without moduleinfo stays
    /// a named browser entry until then; racks never receive unresolved IDs.
    func resolveForAddition(_ plugin: AudioPluginDescriptor) async throws -> [AudioPluginDescriptor] {
        guard !isBusy else { throw PluginHostError(message: "Wait for the current plug-in operation to finish.") }
        guard plugin.format == .vst3 else { return [plugin] }
        resolvingName = plugin.name; errorMessage = nil
        defer { resolvingName = nil }
        let path = plugin.location, url = URL(fileURLWithPath: plugin.location)
        let fingerprint = await Task.detached(priority: .utility) { PluginDiscovery.fingerprint(url) }.value
        if let cached = bundles[path], cached.verified, cached.fingerprint == fingerprint {
            return choices(for: plugin, in: cached.plugins)
        }
        // Persist a crash marker without presenting an in-progress add as a failure.
        await saveCache(pendingAddition: path)
        do {
            try Task.checkCancellation()
            let resolved = try await scanner(["--scan-vst3", path])
            try Task.checkCancellation()
            guard !resolved.isEmpty else { throw PluginHostError(message: "This bundle does not contain a supported audio plug-in.") }
            bundles[path] = .init(fingerprint: fingerprint, plugins: resolved, verified: true)
            failures.removeValue(forKey: path)
            plugins = Self.sortedUnique(plugins.filter { $0.format != .vst3 || $0.location != path } + resolved)
            await saveCache()
            return choices(for: plugin, in: resolved)
        } catch {
            if error is CancellationError || Task.isCancelled { failures.removeValue(forKey: path) }
            else { failures[path] = error.localizedDescription }
            await saveCache()
            throw error
        }
    }
    private func choices(for plugin: AudioPluginDescriptor, in resolved: [AudioPluginDescriptor]) -> [AudioPluginDescriptor] {
        if let matching = resolved.first(where: { $0.id == plugin.id }) { return [matching] }
        return resolved
    }
    private static func sortedUnique(_ values: [AudioPluginDescriptor]) -> [AudioPluginDescriptor] {
        var seen = Set<String>()
        return values.filter { seen.insert("\($0.format.rawValue):\($0.id)").inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func saveCache(pendingAddition: String? = nil) async {
        var savedFailures = failures
        if let pendingAddition {
            savedFailures[pendingAddition] = "The previous add did not finish. Select the plug-in and choose Add to try again."
        }
        let value = Cache(plugins: plugins, failures: savedFailures, customDirectories: customDirectories.map(\.path), bundles: bundles)
        let url = cacheURL, previous = cacheWriteTask
        let task = Task.detached(priority: .utility) { () -> String? in
            _ = await previous?.value
            do {
                let data = try JSONEncoder().encode(value)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                return nil
            } catch { return "Could not save plug-in scan settings: \(error.localizedDescription)" }
        }
        cacheWriteTask = task
        if let message = await task.value { errorMessage = message }
    }

    nonisolated private static func scanProcess(_ arguments: [String]) async throws -> [AudioPluginDescriptor] {
        let host = try PluginHostProcess(arguments: arguments)
        defer { host.stop() }
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .utility) {
                let event = try host.wait(for: "scan", timeout: 12)
                guard let list = event["plugins"] as? [[String: Any]] else { throw PluginHostError(message: "The plug-in scan returned invalid information.") }
                return try JSONDecoder().decode([AudioPluginDescriptor].self, from: JSONSerialization.data(withJSONObject: list))
            }.value
        }, onCancel: { host.stop() })
    }
}

/// Filesystem and JSON5 only. Never load a vendor executable during discovery.
enum PluginDiscovery {
    struct BundleRecord: Codable, Sendable {
        let fingerprint: String
        let plugins: [AudioPluginDescriptor]
        let verified: Bool
        var metadataRevision: Int? = 3
    }
    static func uniqueDirectories(_ values: [URL]) -> [URL] {
        var seen = Set<String>()
        return values.map { $0.standardizedFileURL.resolvingSymlinksInPath() }.filter { seen.insert($0.path).inserted }
    }
    static func discover(in roots: [URL], cached: [String: BundleRecord]) throws -> [String: BundleRecord] {
        let manager = FileManager.default
        var result: [String: BundleRecord] = [:]
        for root in uniqueDirectories(roots) {
            try Task.checkCancellation()
            guard let files = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in files {
                try Task.checkCancellation()
                guard url.pathExtension.lowercased() == "vst3", (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                files.skipDescendants()
                let bundle = url.standardizedFileURL.resolvingSymlinksInPath(), path = bundle.path
                guard result[path] == nil else { continue }
                let stamp = fingerprint(bundle)
                if let saved = cached[path], saved.fingerprint == stamp, saved.metadataRevision == 3 {
                    result[path] = saved; continue
                }
                let maker = bundleManufacturer(bundle)
                // Keep verified names during migration, but recheck the factory
                // on the next Add so newly supported instrument classes appear.
                let previous = cached[path].flatMap { $0.fingerprint == stamp && $0.verified ? $0.plugins : nil }
                let entries = metadata(bundle) ?? previous ?? [.init(id: "vst3-bundle:" + path,
                    name: bundle.deletingPathExtension().lastPathComponent, manufacturer: maker ?? "Maker not identified", format: .vst3, location: path)]
                result[path] = .init(fingerprint: stamp, plugins: entries, verified: false)
            }
        }
        return result
    }
    static func fingerprint(_ bundle: URL) -> String {
        let executableDirectory = bundle.appendingPathComponent("Contents/MacOS")
        let executables = (try? FileManager.default.contentsOfDirectory(at: executableDirectory, includingPropertiesForKeys: nil)) ?? []
        let files = [bundle, bundle.appendingPathComponent("Contents/Info.plist"),
            bundle.appendingPathComponent("Contents/Resources/moduleinfo.json"), bundle.appendingPathComponent("Contents/moduleinfo.json")] + executables.sorted { $0.path < $1.path }
        return files.map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(url.lastPathComponent):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? 0)"
        }.joined(separator: "|")
    }
    private struct Module: Decodable {
        struct Factory: Decodable { let vendor: String?; enum CodingKeys: String, CodingKey { case vendor = "Vendor" } }
        struct Entry: Decodable {
            let id: String; let category: String; let name: String; let vendor: String?; let subcategories: [String]?
            enum CodingKeys: String, CodingKey { case id = "CID", category = "Category", name = "Name", vendor = "Vendor", subcategories = "Sub Categories" }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decode(String.self, forKey: .id)
                category = try values.decode(String.self, forKey: .category)
                name = try values.decode(String.self, forKey: .name)
                vendor = try? values.decode(String.self, forKey: .vendor)
                subcategories = (try? values.decode([String].self, forKey: .subcategories))
                    ?? (try? values.decode(String.self, forKey: .subcategories)).map { $0.components(separatedBy: "|") }
            }
        }
        struct ClassRecord: Decodable {
            let entry: Entry?
            init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
        }
        let factory: Factory?; let classes: [ClassRecord]
        enum CodingKeys: String, CodingKey { case factory = "Factory Info", classes = "Classes" }
    }
    private static func metadata(_ bundle: URL) -> [AudioPluginDescriptor]? {
        for relative in ["Contents/Resources/moduleinfo.json", "Contents/moduleinfo.json"] {
            let url = bundle.appendingPathComponent(relative)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024,
                  let data = try? Data(contentsOf: url) else { continue }
            let decoder = JSONDecoder(); decoder.allowsJSON5 = true
            guard let module = try? decoder.decode(Module.self, from: data) else { continue }
            let entries: [AudioPluginDescriptor] = module.classes.compactMap { record in
                guard let entry = record.entry else { return nil }
                guard entry.category == "Audio Module Class",
                      entry.id.utf8.count == 32, entry.id.allSatisfy(\.isHexDigit), !entry.name.isEmpty else { return nil }
                return .init(id: entry.id.uppercased(), name: entry.name,
                    manufacturer: nonempty(entry.vendor) ?? nonempty(module.factory?.vendor) ?? bundleManufacturer(bundle) ?? "Maker not identified",
                    format: .vst3, location: bundle.path,
                    kind: (entry.subcategories ?? []).contains("Instrument") || (entry.subcategories ?? []).contains("Generator") ? .instrument : .effect)
            }
            // A malformed class must not hide valid siblings or the entire
            // bundle. Leave a lazy Add entry when metadata is inconclusive.
            if !entries.isEmpty { return entries }
        }
        return nil
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.count <= 200, value.lowercased() != "unknown" else { return nil }
        return value
    }

    /// Read data only; Bundle loading or guessing from reverse-DNS identifiers
    /// would either execute vendor code or misidentify a maker.
    private static func bundleManufacturer(_ bundle: URL) -> String? {
        let url = bundle.appendingPathComponent("Contents/Info.plist")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: url),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        for key in ["VST3Vendor", "VSTVendor", "CFBundleManufacturer", "Manufacturer", "Vendor"] {
            if let value = nonempty(info[key] as? String) { return value }
        }
        if let components = info["AudioComponents"] as? [[String: Any]] {
            let makers = Set(components.compactMap { component -> String? in
                guard let name = component["name"] as? String, let separator = name.firstIndex(of: ":") else { return nil }
                return nonempty(String(name[..<separator]))
            })
            if makers.count == 1 { return makers.first }
        }
        guard var owner = nonempty(info["NSHumanReadableCopyright"] as? String) else { return nil }
        owner = owner.replacingOccurrences(of: #"(?i)^\s*(copyright\s*)?(\(c\)|©)?\s*"#, with: "", options: .regularExpression)
        owner = owner.replacingOccurrences(of: #"^\s*(?:\d{4}(?:\s*[-–,]\s*\d{4})*\s*)"#, with: "", options: .regularExpression)
        owner = owner.replacingOccurrences(of: #"(?i)[.\s]*all rights reserved[.\s]*$"#, with: "", options: .regularExpression)
        owner = owner.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        guard owner.rangeOfCharacter(from: .letters) != nil, !owner.contains("\n"), owner.count <= 100 else { return nil }
        return nonempty(owner)
    }
}
