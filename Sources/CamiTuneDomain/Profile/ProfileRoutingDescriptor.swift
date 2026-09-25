import Foundation

package struct ProfileRoutingDescriptor: Hashable, Sendable {
    package static let uidPrefix = "local.camilla.profile."
    private static let legacyUIDPrefixes = ["local.camillaeq.profile."]

    package let profileID: UUID
    package let uid: String
    package let name: String
    package let channelCount: Int
    package let channelLayoutTag: UInt32
    package let supportedSampleRates: [Int]

    package init(profileID: UUID, uid: String, name: String, sourceLayout: LPCMChannelLayout = .stereo,
         supportedSampleRates: [Int] = [48_000]) {
        self.profileID = profileID; self.uid = uid; self.name = name
        channelCount = sourceLayout.channelCount
        channelLayoutTag = sourceLayout.coreAudioTag
        self.supportedSampleRates = supportedSampleRates
    }

    /// Publication uses an explicit source layout, independent of hardware capacity.

    package static func descriptors(for profiles: [DeviceProfile], sourceLayouts: [UUID: LPCMChannelLayout] = [:]) -> [UUID: ProfileRoutingDescriptor] {
        let bases = profiles.map { profile in
            (profile: profile, base: baseName(for: profile))
        }
        let groups = Dictionary(grouping: bases) {
            $0.base.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        }

        return Dictionary(bases.map { item in
            let collides = (groups[item.base.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )]?.count ?? 0) > 1
            let suffix = item.profile.id.uuidString.prefix(6).uppercased()
            let displayName = collides ? "\(item.base) [\(suffix)]" : item.base
            let descriptor = ProfileRoutingDescriptor(
                profileID: item.profile.id,
                uid: uid(for: item.profile.id),
                name: displayName,
                sourceLayout: sourceLayouts[item.profile.id] ?? sourceLayout(for: item.profile),
                supportedSampleRates: [item.profile.sampleRate]
            )
            return (item.profile.id, descriptor)
        }, uniquingKeysWith: { first, _ in first })
    }

    package static func sourceLayout(for profile: DeviceProfile) -> LPCMChannelLayout {
        if profile.hasPhysicalSpeakerRoute && profile.multichannel.routing.enabled {
            return profile.multichannel.routing.sourceLayout.layout(channelCount: profile.multichannel.routing.discreteChannelCount)
        }
        if profile.hasPhysicalSpeakerRoute, let topology = profile.speakerTopology {
            if let layout = SpeakerLayoutTemplate.selected(in: topology)?.sourceLayout { return layout }
            // Custom physical setups still receive a known content layout when
            // all enabled role assignments match it. Never infer from capacity.
            let roles = profile.configuredSpeakerEndpoints.filter { !($0.function == .subwoofer && $0.role == .unknown) }.map(\.role)
            if let template = SpeakerLayoutTemplate.all.first(where: {
                $0.endpointRoles.count == roles.count && Set($0.endpointRoles) == Set(roles)
            }), let layout = template.sourceLayout { return layout }
            // Preserve arbitrary/custom output identity at the boundary. Direct
            // discrete routing is added with the PCM route contract in Phase 5.
            return .stereo
        }
        // Existing per-app mode buses can request reference/spatial rendering
        // independently of the profile mode. Preserve their multichannel input.
        if profile.isPersonalListening { return .sevenPointOne }
        return profile.playbackMode == .direct ? .stereo : .sevenPointOne
    }

    package static func uid(for profileID: UUID) -> String {
        uidPrefix + profileID.uuidString.lowercased()
    }

    package static func profileID(from uid: String) -> UUID? {
        for prefix in [uidPrefix] + legacyUIDPrefixes where uid.hasPrefix(prefix) {
            return UUID(uuidString: String(uid.dropFirst(prefix.count)))
        }
        return nil
    }

    package static func isProfileRoutingUID(_ uid: String) -> Bool {
        ([uidPrefix] + legacyUIDPrefixes).contains { uid.hasPrefix($0) }
    }

    package static func visibleProfileIDs(
        profiles: [DeviceProfile],
        activeProfileID: UUID?,
        defaultOutputUID: String?,
        additionallyVisible: Set<UUID> = []
    ) -> Set<UUID> {
        var result = additionallyVisible
        for profile in profiles where profile.isEnabled {
            if profile.autoActivateWhenProfileDeviceSelected {
                result.insert(profile.id)
            }
        }
        if let defaultOutputUID,
           let selectedProfileID = profileID(from: defaultOutputUID),
           profiles.contains(where: { $0.id == selectedProfileID && $0.isEnabled }) {
            result.insert(selectedProfileID)
        }
        // Keep the active native profile endpoint published. The driver routes
        // every profile endpoint into the same hidden PCM transport.
        if let activeProfileID { result.insert(activeProfileID) }
        return result
    }

    private static func baseName(for profile: DeviceProfile) -> String {
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileName = trimmed.isEmpty ? "EQ Profile" : trimmed
        if profileName.localizedCaseInsensitiveCompare(profile.outputDeviceName) == .orderedSame {
            return "\(profileName)-Cami"
        }
        return profileName
    }
}
