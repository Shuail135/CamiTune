import CamiTuneDomain
import Foundation

/// Called only by the repository utility worker (except composition-time bootstrap).
/// No ordering, revision selection, runtime state, or MainActor dependency.
struct ProfileRepositoryFileIO: Sendable {
    struct Timings: Sendable { var encodingMilliseconds: Double; var writeMilliseconds: Double }
    var load: @Sendable (URL) throws -> ProfileDocument?
    var persist: @Sendable (ProfileDocument, URL) throws -> Timings
    static let live = Self(load: { url in
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url), decoder = JSONDecoder()
        if let stored = try? decoder.decode(ProfileDocument.self, from: data) { return stored }
        let legacy = try decoder.decode([LegacyStoredProfile].self, from: data)
        var claimed = Set<String>()
        let defaults = legacy.compactMap { item -> PhysicalDeviceDefaultProfile? in
            guard item.autoActivate, claimed.insert(item.profile.outputDeviceUID).inserted else { return nil }
            return .init(physicalDevice: item.profile.outputDevice, profileID: item.profile.id)
        }
        return ProfileDocument(profiles: legacy.map(\.profile), physicalDeviceDefaults: defaults,
            folders: [], rootOrder: [], layoutDefaults: [:], showProfileEnabledExplanation: true)
    }, persist: { document, url in
        let start = DispatchTime.now().uptimeNanoseconds
        let data = try JSONEncoder().encode(document)
        let encoded = DispatchTime.now().uptimeNanoseconds
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let written = DispatchTime.now().uptimeNanoseconds
        return .init(encodingMilliseconds: Double(encoded - start) / 1e6, writeMilliseconds: Double(written - encoded) / 1e6)
    })
}
