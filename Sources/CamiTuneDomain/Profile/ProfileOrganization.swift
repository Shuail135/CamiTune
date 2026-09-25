import Foundation

package enum ProfileNamePolicy {
    package static func uniqueName(base requestedBase: String, existingNames: [String]) -> String {
        let trimmed = requestedBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Profile" : trimmed
        let existingKeys = Set(existingNames.map(comparisonKey))
        guard existingKeys.contains(comparisonKey(base)) else { return base }

        var suffix = 2
        while existingKeys.contains(comparisonKey("\(base) \(suffix)")) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    package static func isAvailable(_ name: String, in profiles: [DeviceProfile], excluding profileID: UUID? = nil) -> Bool {
        let key = comparisonKey(name)
        return !profiles.contains { profile in
            profile.id != profileID && comparisonKey(profile.name) == key
        }
    }

    package static func normalized(_ profiles: [DeviceProfile]) -> [DeviceProfile] {
        var result: [DeviceProfile] = []
        result.reserveCapacity(profiles.count)
        for var profile in profiles {
            profile.name = uniqueName(base: profile.name, existingNames: result.map(\.name))
            result.append(profile)
        }
        return result
    }

    private static func comparisonKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

package struct ProfileFolder: Identifiable, Codable, Equatable, Sendable {
    package init(id: UUID = UUID(), name: String, profileIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.profileIDs = profileIDs
    }

    package var id = UUID()
    package var name: String
    package var profileIDs: [UUID] = []
}

package enum ProfileRootItem: Codable, Hashable, Sendable {
    case profile(UUID), folder(UUID)

    package static func normalized(_ order: [Self], profiles: [DeviceProfile], folders: [ProfileFolder]) -> [Self] {
        let grouped = Set(folders.flatMap(\.profileIDs))
        let defaults = profiles.filter { !grouped.contains($0.id) }.map { Self.profile($0.id) }
            + folders.map { Self.folder($0.id) }
        let valid = Set(defaults)
        var seen = Set<Self>()
        return (order + defaults).filter { valid.contains($0) && seen.insert($0).inserted }
    }
}
