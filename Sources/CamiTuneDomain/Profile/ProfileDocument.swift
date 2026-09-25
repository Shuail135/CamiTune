import Foundation

package struct ProfileDocument: Codable, Sendable {
    package static let currentSchemaVersion = 7
    package var schemaVersion: Int = currentSchemaVersion
    package var documentRevision = ProfileDocumentRevision(rawValue: 0)
    package var profiles: [DeviceProfile]
    package var physicalDeviceDefaults: [PhysicalDeviceDefaultProfile]
    package var folders: [ProfileFolder]
    package var rootOrder: [ProfileRootItem]
    package var layoutDefaults: [String: ProfileSectionLayout]
    package var showProfileEnabledExplanation: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, documentRevision, profiles, physicalDeviceDefaults, folders, rootOrder, layoutDefaults, showProfileEnabledExplanation
    }

    package init(
        profiles: [DeviceProfile],
        physicalDeviceDefaults: [PhysicalDeviceDefaultProfile],
        folders: [ProfileFolder],
        rootOrder: [ProfileRootItem],
        layoutDefaults: [String: ProfileSectionLayout],
        showProfileEnabledExplanation: Bool
    ) {
        self.layoutDefaults = layoutDefaults
        self.showProfileEnabledExplanation = showProfileEnabledExplanation
        self.rootOrder = rootOrder
        self.folders = folders
        self.profiles = profiles
        self.physicalDeviceDefaults = physicalDeviceDefaults
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // The original document had no version. Accept that exact legacy
        // shape, but reject explicit unsupported versions before decoding data.
        if values.contains(.schemaVersion) {
            let version = try values.decode(Int.self, forKey: .schemaVersion)
            guard (1...Self.currentSchemaVersion).contains(version) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schemaVersion,
                    in: values,
                    debugDescription: "Unsupported profile schema version: \(version)"
                )
            }
        }
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        documentRevision = version >= 7 ? try values.decode(ProfileDocumentRevision.self, forKey: .documentRevision) : .init(rawValue: 0)
        layoutDefaults = try values.decodeIfPresent([String: ProfileSectionLayout].self, forKey: .layoutDefaults) ?? [:]
        showProfileEnabledExplanation = try values.decodeIfPresent(Bool.self, forKey: .showProfileEnabledExplanation) ?? true
        rootOrder = try values.decodeIfPresent([ProfileRootItem].self, forKey: .rootOrder) ?? []
        folders = try values.decodeIfPresent([ProfileFolder].self, forKey: .folders) ?? []
        profiles = try values.decode([DeviceProfile].self, forKey: .profiles)
        physicalDeviceDefaults = try values.decode(
            [PhysicalDeviceDefaultProfile].self, forKey: .physicalDeviceDefaults
        )
    }
}

package struct LegacyStoredProfile: Decodable {
    package let profile: DeviceProfile
    package let autoActivate: Bool

    private enum CodingKeys: String, CodingKey {
        case autoActivate
    }

    package init(from decoder: Decoder) throws {
        profile = try DeviceProfile(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        autoActivate = try values.decodeIfPresent(Bool.self, forKey: .autoActivate) ?? false
    }
}
