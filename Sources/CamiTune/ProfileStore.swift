import Foundation

enum ProfileNamePolicy {
    static func uniqueName(base requestedBase: String, existingNames: [String]) -> String {
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

    static func isAvailable(_ name: String, in profiles: [DeviceProfile], excluding profileID: UUID? = nil) -> Bool {
        let key = comparisonKey(name)
        return !profiles.contains { profile in
            profile.id != profileID && comparisonKey(profile.name) == key
        }
    }

    static func normalized(_ profiles: [DeviceProfile]) -> [DeviceProfile] {
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

struct ProfileFolder: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var profileIDs: [UUID] = []
}

enum ProfileRootItem: Codable, Hashable, Sendable {
    case profile(UUID), folder(UUID)

    static func normalized(_ order: [Self], profiles: [DeviceProfile], folders: [ProfileFolder]) -> [Self] {
        let grouped = Set(folders.flatMap(\.profileIDs))
        let defaults = profiles.filter { !grouped.contains($0.id) }.map { Self.profile($0.id) }
            + folders.map { Self.folder($0.id) }
        let valid = Set(defaults)
        var seen = Set<Self>()
        return (order + defaults).filter { valid.contains($0) && seen.insert($0).inserted }
    }
}

@MainActor
final class ProfileStore: ObservableObject {
    weak var history: UndoCoordinator?
    private var organizationEditDepth = 0
    func organizationHistoryState() -> ProfileOrganizationHistoryState {
        ProfileOrganizationHistoryState(orderedProfileIDs: profiles.map(\.id), folders: folders, rootOrder: effectiveRootOrder)
    }
    private func beginOrganizationEdit() -> ProfileOrganizationHistoryState {
        organizationEditDepth += 1
        return organizationHistoryState()
    }
    private func endOrganizationEdit(_ before: ProfileOrganizationHistoryState) {
        organizationEditDepth -= 1
        guard organizationEditDepth == 0 else { return }
        history?.record(actionName: "Organize Profiles", target: .profileOrganization,
            before: .profileOrganization(before), after: .profileOrganization(organizationHistoryState()))
    }
    func restoreOrganizationHistoryState(_ state: ProfileOrganizationHistoryState) throws {
        let ids = Set(profiles.map(\.id))
        let ordered = Set(state.orderedProfileIDs)
        let folderIDs = Set(state.folders.map(\.id))
        let children = state.folders.flatMap(\.profileIDs)
        guard ordered.count == state.orderedProfileIDs.count, ordered.isSubset(of: ids),
              folderIDs.count == state.folders.count,
              Set(children).count == children.count, Set(children).isSubset(of: ids),
              Set(state.rootOrder).count == state.rootOrder.count,
              ProfileRootItem.normalized(state.rootOrder, profiles: profiles.filter { ordered.contains($0.id) }, folders: state.folders) == state.rootOrder else {
            throw HistoryRestoreError.invalidOrganization
        }
        let current = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let added = profiles.filter { !ordered.contains($0.id) }
        performBatchUpdate {
            profiles = state.orderedProfileIDs.compactMap { current[$0] } + added
            folders = state.folders
            rootOrder = state.rootOrder
        }
    }
    @Published var profiles: [DeviceProfile] = [] {
        didSet { save() }
    }
    @Published private(set) var physicalDeviceDefaults: [PhysicalDeviceDefaultProfile] = [] {
        didSet { save() }
    }
    @Published private(set) var folders: [ProfileFolder] = [] {
        didSet { save() }
    }
    @Published private(set) var rootOrder: [ProfileRootItem] = [] {
        didSet { save() }
    }
    var effectiveRootOrder: [ProfileRootItem] {
        ProfileRootItem.normalized(rootOrder, profiles: profiles, folders: folders)
    }
    @Published private(set) var layoutDefaults: [String: ProfileSectionLayout] = [:] {
        didSet { save() }
    }
    @Published var showProfileEnabledExplanation = true {
        didSet { save() }
    }
    func defaultLayout(for type: ProfileEndpointKind) -> ProfileSectionLayout {
        layoutDefaults[type.rawValue] ?? ProfileSectionLayout()
    }
    func effectiveLayout(for profile: DeviceProfile) -> ProfileSectionLayout {
        profile.sectionLayout ?? defaultLayout(for: profile.endpointKind)
    }
    func setDefaultLayout(_ layout: ProfileSectionLayout, for type: ProfileEndpointKind) {
        layoutDefaults[type.rawValue] = layout
    }
    func applyDefaultLayout(for type: ProfileEndpointKind, to ids: Set<UUID>) {
        // Explicitly opted-in profiles resume inheritance; other local layouts stay intact.
        performBatchUpdate {
            for index in profiles.indices where ids.contains(profiles[index].id) && profiles[index].endpointKind == type {
                profiles[index].sectionLayout = nil
            }
        }
    }

    static func settingsSnapshot(_ profile: DeviceProfile) -> DeviceProfile {
        var result = profile
        // Hardware volume events are live state, not conflicting settings edits.
        result.outputVolumeScalar = 0
        return result
    }
    func validateSettingsSnapshot(_ expected: DeviceProfile, activation: ProfileActivationMode) throws {
        guard let current = profiles.first(where: { $0.id == expected.id }),
              Self.settingsSnapshot(current) == Self.settingsSnapshot(expected),
              activationMode(for: current) == activation else { throw ProfileSettingsError.staleDraft }
        guard !protectsUnreadableStorage else {
            throw ProfileSettingsError.runtime(persistenceError ?? "Saved profiles cannot be overwritten.")
        }
    }

    /// Write the complete candidate atomically before publishing it to observers.
    /// A failed write leaves the original in-memory and persisted configuration intact.
    func commitSettings(_ candidate: DeviceProfile, expected: DeviceProfile,
                        originalActivation: ProfileActivationMode, activation: ProfileActivationMode) throws {
        try validateSettingsSnapshot(expected, activation: originalActivation)
        guard let index = profiles.firstIndex(where: { $0.id == candidate.id }),
              ProfileNamePolicy.isAvailable(candidate.name, in: profiles, excluding: candidate.id) else {
            throw ProfileSettingsError.runtime("A profile with that name already exists.")
        }
        var updated = profiles
        var saved = candidate
        saved.outputVolumeScalar = updated[index].outputVolumeScalar
        saved.autoActivateWhenProfileDeviceSelected = activation == .profileAudioDevice
        updated[index] = saved
        var defaults = physicalDeviceDefaults.filter { $0.profileID != candidate.id }
        if activation == .physicalOutput {
            defaults.removeAll { $0.physicalDevice.uid == candidate.outputDeviceUID }
            defaults.append(PhysicalDeviceDefaultProfile(physicalDevice: candidate.outputDevice, profileID: candidate.id))
        }
        let stored = StoredProfileConfiguration(profiles: updated, physicalDeviceDefaults: defaults,
            folders: folders, rootOrder: effectiveRootOrder, layoutDefaults: layoutDefaults,
            showProfileEnabledExplanation: showProfileEnabledExplanation)
        pendingPersistence?.cancel()
        pendingPersistence = nil
        persistenceRevision &+= 1
        do { try persistenceQueue.sync { try Self.persist(stored, to: url) } }
        catch {
            // Preserve a pending save of unrelated edits if this transaction fails.
            save()
            throw error
        }
        isLoading = true
        profiles = updated
        physicalDeviceDefaults = defaults
        isLoading = false
        persistenceError = nil
    }

    @Published var selectedProfileID: UUID? {
        didSet { userDefaults.set(selectedProfileID?.uuidString, forKey: "selectedProfileID") }
    }
    @Published private(set) var persistenceError: String?

    private let url: URL
    private let userDefaults: UserDefaults
    private var isLoading = true
    private var saveDeferralDepth = 0
    private var needsDeferredSave = false
    private var persistenceRevision: UInt64 = 0
    private var pendingPersistence: DispatchWorkItem?
    private let persistenceQueue = DispatchQueue(
        label: "CamiTune.ProfilePersistence",
        qos: .utility
    )
    /// An existing store that this version cannot decode may belong to a newer
    /// CamiTune version. Never replace it with the empty in-memory fallback.
    private var protectsUnreadableStorage = false

    init(storageURL: URL? = nil, userDefaults: UserDefaults = .standard) {
        let base = storageURL?.deletingLastPathComponent() ?? CamiTunePaths.supportDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = storageURL ?? base.appendingPathComponent("profiles.json")
        self.userDefaults = userDefaults
        load()
        sanitizeProfiles()
        sanitizePhysicalDeviceDefaults()
        sanitizeFolders()
        if let raw = userDefaults.string(forKey: "selectedProfileID"),
           let id = UUID(uuidString: raw),
           profiles.contains(where: { $0.id == id }) {
            selectedProfileID = id
        }
        if selectedProfileID == nil {
            selectedProfileID = profiles.first?.id
        }
        isLoading = false
    }

    deinit {
        pendingPersistence?.cancel()
    }

    var selectedProfile: DeviceProfile? {
        guard let id = selectedProfileID else { return nil }
        return profiles.first(where: { $0.id == id })
    }

    @discardableResult
    func addProfile(for device: AudioDeviceInfo) -> DeviceProfile? {
        guard !device.isRoutingDevice else { return nil }
        let isFirstProfileForDevice = !profiles.contains { $0.outputDeviceUID == device.id }
        let baseName = ProfileNamePolicy.uniqueName(
            base: device.name,
            existingNames: profiles.map(\.name)
        )
        let profile = DeviceProfile(
            name: baseName,
            outputDeviceUID: device.id,
            outputDeviceName: device.name,
            autoActivateWhenProfileDeviceSelected: !isFirstProfileForDevice
        )
        performBatchUpdate {
            profiles.append(profile)
            if isFirstProfileForDevice {
                setAutomaticProfile(physicalDevice: profile.outputDevice, profileID: profile.id)
            }
        }
        selectedProfileID = profile.id
        return profile
    }

    /// Wizard commit: persist a complete profile before publishing or exposing a route.
    func insertConfiguredProfile(_ candidate: DeviceProfile) throws -> UUID {
        guard !protectsUnreadableStorage else {
            throw ProfileSettingsError.runtime(persistenceError ?? "Saved profiles cannot be overwritten.")
        }
        guard !candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !candidate.outputDeviceUID.isEmpty,
              !profiles.contains(where: { $0.id == candidate.id }),
              ProfileNamePolicy.isAvailable(candidate.name, in: profiles) else {
            throw ProfileSettingsError.runtime("Enter a unique profile name before adding the profile.")
        }
        var profile = candidate
        let firstForOutput = !profiles.contains { $0.outputDeviceUID == profile.outputDeviceUID }
        profile.autoActivateWhenProfileDeviceSelected = !firstForOutput
        let updated = profiles + [profile]
        var defaults = physicalDeviceDefaults
        if firstForOutput {
            defaults.removeAll { $0.physicalDevice.uid == profile.outputDeviceUID }
            defaults.append(.init(physicalDevice: profile.outputDevice, profileID: profile.id))
        }
        let order = effectiveRootOrder + [.profile(profile.id)]
        let stored = StoredProfileConfiguration(profiles: updated, physicalDeviceDefaults: defaults,
            folders: folders, rootOrder: order, layoutDefaults: layoutDefaults,
            showProfileEnabledExplanation: showProfileEnabledExplanation)
        pendingPersistence?.cancel()
        pendingPersistence = nil
        persistenceRevision &+= 1
        do { try persistenceQueue.sync { try Self.persist(stored, to: url) } }
        catch { save(); throw error }
        isLoading = true
        profiles = updated
        physicalDeviceDefaults = defaults
        rootOrder = order
        isLoading = false
        persistenceError = nil
        selectedProfileID = profile.id
        return profile.id
    }

    func setAutoActivateWhenProfileDeviceSelected(profileID: UUID, enabled: Bool) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].autoActivateWhenProfileDeviceSelected = enabled
    }

    func setProfileEnabled(profileID: UUID, enabled: Bool) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].isEnabled = enabled
    }

    func setOutputVolumeScalar(profileID: UUID, scalar: Double) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        guard abs(profiles[index].outputVolumeScalar - scalar) >= 0.0005 else { return }

        // Mutate a local copy, then publish the completed value. Avoid passing
        // the actor-isolated @Published array element as inout across an async
        // call boundary (rejected by Swift's strict actor isolation checks).
        var updated = profiles
        updated[index].outputVolumeScalar = scalar
        profiles = updated
    }

    func setOutputDevice(profileID: UUID, device: AudioDeviceInfo) {
        guard !device.isRoutingDevice else { return }
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let oldUID = profiles[index].outputDeviceUID
        guard oldUID != device.id || profiles[index].outputDeviceName != device.name else {
            return
        }
        let wasAutomaticDefault = automaticProfileID(forPhysicalDeviceUID: oldUID) == profileID

        performBatchUpdate {
            var updated = profiles
            updated[index].outputDeviceUID = device.id
            updated[index].outputDeviceName = device.name
            profiles = updated

            // A default belongs to a physical output, not merely a profile ID.
            // Moving that profile must not leave an impossible old mapping.
            physicalDeviceDefaults.removeAll { $0.profileID == profileID }
            if wasAutomaticDefault {
                setAutomaticProfile(
                    physicalDevice: PhysicalOutputIdentity(uid: device.id, name: device.name),
                    profileID: profileID
                )
            }
        }
    }

    func activationMode(for profile: DeviceProfile) -> ProfileActivationMode {
        if automaticProfileID(forPhysicalDeviceUID: profile.outputDeviceUID) == profile.id {
            return .physicalOutput
        }
        return profile.autoActivateWhenProfileDeviceSelected ? .profileAudioDevice : .manual
    }

    func automaticProfileID(forPhysicalDeviceUID uid: String) -> UUID? {
        physicalDeviceDefaults.first(where: { $0.physicalDevice.uid == uid })?.profileID
    }

    func automaticProfile(forPhysicalDeviceUID uid: String) -> DeviceProfile? {
        guard let profileID = automaticProfileID(forPhysicalDeviceUID: uid) else { return nil }
        return profiles.first {
            $0.id == profileID && $0.isEnabled && $0.outputDeviceUID == uid
        }
    }

    func setAutomaticProfile(physicalDevice: PhysicalOutputIdentity, profileID: UUID?) {
        var updated = physicalDeviceDefaults.filter { $0.physicalDevice.uid != physicalDevice.uid }
        if let profileID,
           profiles.contains(where: { $0.id == profileID && $0.outputDeviceUID == physicalDevice.uid }) {
            updated.append(PhysicalDeviceDefaultProfile(
                physicalDevice: physicalDevice,
                profileID: profileID
            ))
        }
        physicalDeviceDefaults = updated
    }

    func captureDeletionSnapshot(profileIDs: Set<UUID>, folderID: UUID? = nil) -> ProfileDeletionSnapshot {
        ProfileDeletionSnapshot(profiles: profiles.filter { profileIDs.contains($0.id) }, folderID: folderID,
            organization: organizationHistoryState(), physicalDeviceDefaults: physicalDeviceDefaults.filter { profileIDs.contains($0.profileID) },
            selectedProfileID: selectedProfileID)
    }

    func restoreDeletedProfiles(_ snapshot: ProfileDeletionSnapshot) throws {
        let restoredIDs = Set(snapshot.profiles.map(\.id))
        guard restoredIDs.count == snapshot.profiles.count,
              restoredIDs.isDisjoint(with: Set(profiles.map(\.id))),
              snapshot.profiles.allSatisfy({ ProfileNamePolicy.isAvailable($0.name, in: profiles) }),
              snapshot.folderID == nil || !folders.contains(where: { $0.id == snapshot.folderID }) else {
            throw HistoryRestoreError.invalidOrganization
        }
        // Build and validate the entire candidate before publishing any part.
        let combined = profiles + snapshot.profiles
        let order = snapshot.organization.orderedProfileIDs.filter { id in combined.contains { $0.id == id } }
            + profiles.map(\.id).filter { !snapshot.organization.orderedProfileIDs.contains($0) }
        guard Set(order) == Set(combined.map(\.id)), Set(order).count == order.count else {
            throw HistoryRestoreError.invalidOrganization
        }
        var candidateFolders = folders
        for old in snapshot.organization.folders {
            if old.id == snapshot.folderID { candidateFolders.append(old); continue }
            let restoredChildren = old.profileIDs.filter { restoredIDs.contains($0) }
            guard !restoredChildren.isEmpty else { continue }
            guard let index = candidateFolders.firstIndex(where: { $0.id == old.id }) else { throw HistoryRestoreError.invalidOrganization }
            let existing = candidateFolders[index].profileIDs
            candidateFolders[index].profileIDs = old.profileIDs.filter { restoredIDs.contains($0) || existing.contains($0) }
                + existing.filter { !old.profileIDs.contains($0) }
        }
        let candidateRoot = ProfileRootItem.normalized(snapshot.organization.rootOrder + effectiveRootOrder,
            profiles: combined, folders: candidateFolders)
        let children = candidateFolders.flatMap(\.profileIDs)
        guard Set(candidateFolders.map(\.id)).count == candidateFolders.count,
              Set(children).count == children.count, Set(children).isSubset(of: Set(order)),
              Set(candidateRoot).count == candidateRoot.count else {
            throw HistoryRestoreError.invalidOrganization
        }
        let byID = Dictionary(uniqueKeysWithValues: combined.map { ($0.id, $0) })
        performBatchUpdate {
            profiles = order.compactMap { byID[$0] }
            folders = candidateFolders
            rootOrder = candidateRoot
            let restoredUIDs = Set(snapshot.physicalDeviceDefaults.map { $0.physicalDevice.uid })
            physicalDeviceDefaults.removeAll { restoredUIDs.contains($0.physicalDevice.uid) }
            physicalDeviceDefaults += snapshot.physicalDeviceDefaults
            if let selected = snapshot.selectedProfileID, restoredIDs.contains(selected) { selectedProfileID = selected }
        }
    }

    func deleteProfile(id: UUID) {
        let fallback = nearbySurvivingProfile(excluding: [id])
        performBatchUpdate {
            physicalDeviceDefaults.removeAll { $0.profileID == id }
            profiles.removeAll { $0.id == id }
            for index in folders.indices { folders[index].profileIDs.removeAll { $0 == id } }
        }
        if selectedProfileID == id { selectedProfileID = fallback }
    }

    /// Uses the original list's insertion offset, as supplied by sidebar dragging.
    /// Presentation order only: route identities and automatic defaults stay intact.
    func moveProfiles(fromOffsets source: IndexSet, toOffset destination: Int) {
        let historyBefore = beginOrganizationEdit()
        defer { endOrganizationEdit(historyBefore) }
        guard !source.isEmpty,
              source.allSatisfy({ profiles.indices.contains($0) }),
              (0...profiles.count).contains(destination) else { return }
        let moved = source.map { profiles[$0] }
        var updated = profiles.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertion = destination - source.filter { $0 < destination }.count
        updated.insert(contentsOf: moved, at: insertion)
        guard updated != profiles else { return }
        profiles = updated
    }

    func folderID(for profileID: UUID) -> UUID? {
        folders.first { $0.profileIDs.contains(profileID) }?.id
    }

    func profiles(in folderID: UUID?) -> [DeviceProfile] {
        profiles.filter { self.folderID(for: $0.id) == folderID }
    }

    @discardableResult
    func addFolder(name: String) -> UUID {
        let historyBefore = beginOrganizationEdit()
        defer { endOrganizationEdit(historyBefore) }
        let folder = ProfileFolder(name: ProfileNamePolicy.uniqueName(base: name, existingNames: folders.map(\.name)))
        folders.append(folder)
        return folder.id
    }

    func renameFolder(id: UUID, name: String) {
        let historyBefore = beginOrganizationEdit()
        defer { endOrganizationEdit(historyBefore) }
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = ProfileNamePolicy.uniqueName(
            base: name, existingNames: folders.filter { $0.id != id }.map(\.name))
    }

    /// The caller confirms the contents and stops any affected runtime first.
    func deleteFolder(id: UUID) {
        guard folders.contains(where: { $0.id == id }) else { return }
        let deletedIDs = Set(profiles(in: id).map(\.id))
        let fallback = nearbySurvivingProfile(excluding: deletedIDs)
        performBatchUpdate {
            physicalDeviceDefaults.removeAll { deletedIDs.contains($0.profileID) }
            profiles.removeAll { deletedIDs.contains($0.id) }
            var remaining = folders.filter { $0.id != id }
            for index in remaining.indices {
                remaining[index].profileIDs.removeAll { deletedIDs.contains($0) }
            }
            folders = remaining
        }
        if let selectedProfileID, deletedIDs.contains(selectedProfileID) {
            self.selectedProfileID = fallback
        }
    }

    private func nearbySurvivingProfile(excluding deleted: Set<UUID>) -> UUID? {
        let ordered = effectiveRootOrder.flatMap { item -> [UUID] in
            switch item {
            case .profile(let id): return [id]
            case .folder(let id): return profiles(in: id).map(\.id)
            }
        }
        let anchor = ordered.firstIndex { $0 == selectedProfileID } ?? 0
        return ordered.dropFirst(anchor).first { !deleted.contains($0) }
            ?? ordered.prefix(anchor).last { !deleted.contains($0) }
    }

    func assignProfile(id: UUID, toFolder folderID: UUID?) {
        assignProfiles(ids: [id], toFolder: folderID)
    }

    func assignProfiles(ids: Set<UUID>, toFolder folderID: UUID?) {
        let historyBefore = beginOrganizationEdit()
        defer { endOrganizationEdit(historyBefore) }
        guard folderID == nil || folders.contains(where: { $0.id == folderID }) else { return }
        let orderedIDs = profiles.map(\.id).filter { ids.contains($0) }
        guard !orderedIDs.isEmpty else { return }
        let validIDs = Set(orderedIDs)
        var updated = folders
        for index in updated.indices {
            updated[index].profileIDs.removeAll { validIDs.contains($0) }
            if updated[index].id == folderID { updated[index].profileIDs.append(contentsOf: orderedIDs) }
        }
        folders = updated
    }

    @discardableResult
    func groupProfiles(ids: Set<UUID>, name: String) -> UUID {
        let historyBefore = beginOrganizationEdit()
        defer { endOrganizationEdit(historyBefore) }
        var folderID: UUID!
        performBatchUpdate {
            folderID = addFolder(name: name)
            assignProfiles(ids: ids, toFolder: folderID)
        }
        return folderID
    }

    /// A drag can both change membership and insert at a visible row boundary.
    func dropProfiles(ids: Set<UUID>, into folderID: UUID?, at destination: Int? = nil) {
        let historyBefore = beginOrganizationEdit()
        defer { endOrganizationEdit(historyBefore) }
        guard folderID == nil || folders.contains(where: { $0.id == folderID }) else { return }
        let visible = profiles(in: folderID)
        let offset = destination ?? visible.count
        guard (0...visible.count).contains(offset) else { return }
        let moved = profiles.filter { ids.contains($0.id) }
        guard !moved.isEmpty else { return }
        var ordered = visible.filter { !ids.contains($0.id) }
        let insertion = offset - visible.prefix(offset).filter { ids.contains($0.id) }.count
        ordered.insert(contentsOf: moved, at: insertion)
        performBatchUpdate {
            assignProfiles(ids: ids, toFolder: folderID)
            let slots = profiles.indices.filter { self.folderID(for: profiles[$0].id) == folderID }
            var updated = profiles
            for (slot, profile) in zip(slots, ordered) { updated[slot] = profile }
            if updated != profiles { profiles = updated }
        }
    }

    /// Root insertion offsets refer to the order before removal, just like AppKit.
    func dropRootItems(_ items: Set<ProfileRootItem>, at destination: Int?) {
        let historyBefore = beginOrganizationEdit()
        defer { endOrganizationEdit(historyBefore) }
        let roots = effectiveRootOrder
        let offset = destination ?? roots.count
        guard (0...roots.count).contains(offset) else { return }
        let validProfiles = Set(profiles.map { ProfileRootItem.profile($0.id) })
        let validFolders = Set(folders.map { ProfileRootItem.folder($0.id) })
        guard !items.isEmpty, items.isSubset(of: validProfiles.union(validFolders)) else { return }
        let ordered = roots.filter { items.contains($0) }
            + profiles.map { ProfileRootItem.profile($0.id) }.filter { items.contains($0) && !roots.contains($0) }
        var remaining = roots.filter { !items.contains($0) }
        let insertion = offset - roots.prefix(offset).filter { items.contains($0) }.count
        remaining.insert(contentsOf: ordered, at: insertion)
        let ids = Set(items.compactMap { item -> UUID? in
            if case .profile(let id) = item { return id }; return nil
        })
        performBatchUpdate {
            assignProfiles(ids: ids, toFolder: nil)
            rootOrder = remaining
        }
    }

    func moveProfiles(in folderID: UUID?, fromOffsets source: IndexSet, toOffset destination: Int) {
        let historyBefore = beginOrganizationEdit()
        defer { endOrganizationEdit(historyBefore) }
        let visible = profiles(in: folderID)
        guard !source.isEmpty, source.allSatisfy({ visible.indices.contains($0) }),
              (0...visible.count).contains(destination) else { return }
        let moved = source.map { visible[$0] }
        var ordered = visible.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        ordered.insert(contentsOf: moved, at: destination - source.filter { $0 < destination }.count)
        let slots = profiles.indices.filter { self.folderID(for: profiles[$0].id) == folderID }
        var updated = profiles
        for (slot, profile) in zip(slots, ordered) { updated[slot] = profile }
        if updated != profiles { profiles = updated }
    }

    /// Keyboard and accessibility movement uses the same insertion semantics as a drop.
    @discardableResult
    func moveSidebarItem(_ item: ProfileRootItem, by offset: Int) -> Bool {
        guard offset == -1 || offset == 1 else { return false }
        if case .profile(let id) = item, let folder = folderID(for: id) {
            let children = profiles(in: folder)
            guard let index = children.firstIndex(where: { $0.id == id }),
                  children.indices.contains(index + offset) else { return false }
            moveProfiles(in: folder, fromOffsets: IndexSet(integer: index), toOffset: index + (offset > 0 ? 2 : -1))
        } else {
            let roots = effectiveRootOrder
            guard let index = roots.firstIndex(of: item), roots.indices.contains(index + offset) else { return false }
            dropRootItems([item], at: index + (offset > 0 ? 2 : -1))
        }
        return true
    }

    private func sanitizeFolders() {
        var folderIDs = Set<UUID>()
        var claimedProfiles = Set<UUID>()
        let validProfiles = Set(profiles.map(\.id))
        var result: [ProfileFolder] = []
        for var folder in folders {
            if !folderIDs.insert(folder.id).inserted { folder.id = UUID(); folderIDs.insert(folder.id) }
            folder.name = ProfileNamePolicy.uniqueName(base: folder.name, existingNames: result.map(\.name))
            folder.profileIDs = folder.profileIDs.filter {
                validProfiles.contains($0) && claimedProfiles.insert($0).inserted
            }
            result.append(folder)
        }
        folders = result
    }

    func update(_ profile: DeviceProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard ProfileNamePolicy.isAvailable(profile.name, in: profiles, excluding: profile.id) else { return }
        profiles[index] = profile
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            protectUnreadableStorage(details: error.localizedDescription)
            return
        }
        let decoder = JSONDecoder()
        if let stored = try? decoder.decode(StoredProfileConfiguration.self, from: data) {
            layoutDefaults = stored.layoutDefaults
            showProfileEnabledExplanation = stored.showProfileEnabledExplanation
            rootOrder = stored.rootOrder
            folders = stored.folders
            profiles = stored.profiles
            physicalDeviceDefaults = stored.physicalDeviceDefaults
            return
        }
        guard let legacy = try? decoder.decode([LegacyStoredProfile].self, from: data) else {
            protectUnreadableStorage(
                details: "The file is damaged or was written by an incompatible CamiTune version."
            )
            return
        }
        profiles = legacy.map(\.profile)

        var claimedUIDs = Set<String>()
        physicalDeviceDefaults = legacy.compactMap { item in
            guard item.autoActivate,
                  claimedUIDs.insert(item.profile.outputDeviceUID).inserted else { return nil }
            return PhysicalDeviceDefaultProfile(
                physicalDevice: item.profile.outputDevice,
                profileID: item.profile.id
            )
        }
    }

    private func sanitizePhysicalDeviceDefaults() {
        var claimedUIDs = Set<String>()
        physicalDeviceDefaults = physicalDeviceDefaults.filter { mapping in
            guard let profile = profiles.first(where: { $0.id == mapping.profileID }),
                  profile.outputDeviceUID == mapping.physicalDevice.uid,
                  claimedUIDs.insert(mapping.physicalDevice.uid).inserted else {
                return false
            }
            return true
        }
    }

    private func sanitizeProfiles() {
        var usedIDs = Set<UUID>()
        var sanitized: [DeviceProfile] = []
        sanitized.reserveCapacity(profiles.count)
        for var profile in profiles {
            if !usedIDs.insert(profile.id).inserted {
                repeat { profile.id = UUID() } while !usedIDs.insert(profile.id).inserted
            }
            profile.name = ProfileNamePolicy.uniqueName(
                base: profile.name,
                existingNames: sanitized.map(\.name)
            )
            sanitized.append(profile)
        }
        profiles = sanitized
    }

    private func performBatchUpdate(_ changes: () -> Void) {
        saveDeferralDepth += 1
        changes()
        saveDeferralDepth -= 1
        if saveDeferralDepth == 0, needsDeferredSave {
            needsDeferredSave = false
            save()
        }
    }

    private func save() {
        guard !isLoading else { return }
        guard !protectsUnreadableStorage else { return }
        guard saveDeferralDepth == 0 else {
            needsDeferredSave = true
            return
        }
        let stored = StoredProfileConfiguration(
            profiles: profiles,
            physicalDeviceDefaults: physicalDeviceDefaults,
            folders: folders, rootOrder: effectiveRootOrder, layoutDefaults: layoutDefaults,
            showProfileEnabledExplanation: showProfileEnabledExplanation
        )
        persistenceRevision &+= 1
        let revision = persistenceRevision
        let destination = url
        pendingPersistence?.cancel()

        let work = DispatchWorkItem { [weak self] in
            let result = Result {
                try Self.persist(stored, to: destination)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.persistenceRevision == revision else { return }
                self.pendingPersistence = nil
                switch result {
                case .success:
                    self.persistenceError = nil
                case .failure(let error):
                    self.persistenceError = "CamiTune could not save your profiles: \(error.localizedDescription)"
                }
            }
        }
        pendingPersistence = work
        // Controls can publish dozens of values while the pointer is down.
        // Persist only the settled snapshot, and encode/write it away from the
        // main actor so AppKit scrolling and animations are never held up by
        // an atomic profiles.json replacement.
        persistenceQueue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// App termination is already synchronous. Flush the latest in-memory
    /// snapshot after all previously-started writes so the debounce never
    /// sacrifices durability.
    func persistHistoryChanges() throws {
        flushPendingSaveSynchronously()
        if let persistenceError { throw ProfileSettingsError.runtime(persistenceError) }
    }

    func flushPendingSaveSynchronously() {
        guard !isLoading, !protectsUnreadableStorage else { return }
        pendingPersistence?.cancel()
        pendingPersistence = nil
        persistenceRevision &+= 1
        let stored = StoredProfileConfiguration(
            profiles: profiles,
            physicalDeviceDefaults: physicalDeviceDefaults,
            folders: folders, rootOrder: effectiveRootOrder, layoutDefaults: layoutDefaults,
            showProfileEnabledExplanation: showProfileEnabledExplanation
        )
        let destination = url
        let result = persistenceQueue.sync {
            Result { try Self.persist(stored, to: destination) }
        }
        switch result {
        case .success:
            persistenceError = nil
        case .failure(let error):
            persistenceError = "CamiTune could not save your profiles: \(error.localizedDescription)"
        }
    }

    private nonisolated static func persist(
        _ stored: StoredProfileConfiguration,
        to url: URL
    ) throws {
        let data = try JSONEncoder().encode(stored)
        try data.write(to: url, options: .atomic)
    }

    private func protectUnreadableStorage(details: String) {
        protectsUnreadableStorage = true
        persistenceError = "CamiTune could not read the saved profiles, so the original profiles.json has been left unchanged and this session's profile edits cannot be saved. \(details)"
    }
}

private struct StoredProfileConfiguration: Codable, Sendable {
    static let currentSchemaVersion = 6
    var schemaVersion: Int = currentSchemaVersion
    var profiles: [DeviceProfile]
    var physicalDeviceDefaults: [PhysicalDeviceDefaultProfile]
    var folders: [ProfileFolder]
    var rootOrder: [ProfileRootItem]
    var layoutDefaults: [String: ProfileSectionLayout]
    var showProfileEnabledExplanation: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, profiles, physicalDeviceDefaults, folders, rootOrder, layoutDefaults, showProfileEnabledExplanation
    }

    init(profiles: [DeviceProfile], physicalDeviceDefaults: [PhysicalDeviceDefaultProfile], folders: [ProfileFolder], rootOrder: [ProfileRootItem], layoutDefaults: [String: ProfileSectionLayout], showProfileEnabledExplanation: Bool) {
        self.layoutDefaults = layoutDefaults
        self.showProfileEnabledExplanation = showProfileEnabledExplanation
        self.rootOrder = rootOrder
        self.folders = folders
        self.profiles = profiles
        self.physicalDeviceDefaults = physicalDeviceDefaults
    }

    init(from decoder: Decoder) throws {
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

private struct LegacyStoredProfile: Decodable {
    let profile: DeviceProfile
    let autoActivate: Bool

    private enum CodingKeys: String, CodingKey {
        case autoActivate
    }

    init(from decoder: Decoder) throws {
        profile = try DeviceProfile(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        autoActivate = try values.decodeIfPresent(Bool.self, forKey: .autoActivate) ?? false
    }
}
