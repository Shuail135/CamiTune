import CamiTuneDomain
import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    weak var history: UndoCoordinator? {
        didSet { history?.retainAssets(in: assetStorage) }
    }
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
    @Published private var libraryProfiles: [DeviceProfile] = []
    var profiles: [DeviceProfile] {
        get { libraryProfiles }
        set {
            guard !stopping || isLoading else { return }
            if activeDurableCommit != nil && !isLoading {
                let old = Dictionary(uniqueKeysWithValues: libraryProfiles.map { ($0.id, Self.settingsSnapshot($0)) })
                guard newValue.count == libraryProfiles.count,
                      Set(newValue.map(\.id)).count == newValue.count,
                      newValue.allSatisfy({ old[$0.id] == Self.settingsSnapshot($0) }) else { return }
                if activeDurableCommit?.mutation.kind == .history,
                   newValue.map(\.id) != libraryProfiles.map(\.id) { return }
            }
            libraryProfiles = newValue.map { profile in
                var resolved = profile
                resolved.resolveAudioBuffer(default: audioBufferDefault)
                resolved.inheritedSectionLayouts = layoutDefaults
                return resolved
            }
            save()
        }
    }
    @Published private var libraryDefaults: [PhysicalDeviceDefaultProfile] = []
    private(set) var physicalDeviceDefaults: [PhysicalDeviceDefaultProfile] {
        get { libraryDefaults }
        set {
            guard isLoading || (!stopping && activeDurableCommit == nil) else { return }
            libraryDefaults = newValue; save()
        }
    }
    @Published private var libraryFolders: [ProfileFolder] = []
    private(set) var folders: [ProfileFolder] {
        get { libraryFolders }
        set {
            guard isLoading || (!stopping && activeDurableCommit?.mutation.kind != .history) else { return }
            libraryFolders = newValue; save()
        }
    }
    @Published private var libraryRootOrder: [ProfileRootItem] = []
    private(set) var rootOrder: [ProfileRootItem] {
        get { libraryRootOrder }
        set {
            guard isLoading || (!stopping && activeDurableCommit?.mutation.kind != .history) else { return }
            libraryRootOrder = newValue; save()
        }
    }
    var effectiveRootOrder: [ProfileRootItem] {
        ProfileRootItem.normalized(rootOrder, profiles: profiles, folders: folders)
    }
    @Published private(set) var audioBufferDefault: AudioBufferSetting = 1024
    @Published private(set) var layoutDefaults: [String: ProfileSectionLayout] = [:] {
        didSet {
            libraryProfiles = libraryProfiles.map { profile in
                var resolved = profile
                resolved.inheritedSectionLayouts = layoutDefaults
                return resolved
            }
            save()
        }
    }
    @Published var multichannelDrafts: [UUID: MultichannelHistoryState] = [:] {
        didSet { if oldValue != multichannelDrafts { save() } }
    }
    @Published var showProfileEnabledExplanation = true {
        didSet {
            if !isLoading {
                history?.record(actionName: "Change Profile Explanation", target: .preference(.enabledExplanation),
                    before: .boolean(oldValue), after: .boolean(showProfileEnabledExplanation))
            }
            save()
        }
    }
    /// Seed a new library with the shipped global layouts; saved libraries retain their choices.
    private static var firstLaunchLayoutDefaults: [String: ProfileSectionLayout] {
        Dictionary(uniqueKeysWithValues: ProfileEndpointKind.allCases.map { type in
            let order: [ProfileSection]
            switch type {
            case .speakers:
                order = [.deviceSetup, .mode, .meters, .spectrum, .deviceCorrection, .equalizer, .perChannel, .multichannel]
            case .iem:
                order = [.deviceSetup, .meters, .mode, .deviceCorrection, .spectrum, .equalizer, .perChannel, .multichannel]
            case .headphones, .audioInterface, .custom:
                order = [.deviceSetup, .meters, .mode, .spectrum, .deviceCorrection, .equalizer, .perChannel, .multichannel]
            }
            var layout = ProfileSectionLayout(order: order, hidden: [.meters])
            layout.equalizer = .simpleTone
            return (type.rawValue, layout)
        })
    }

    var automaticAudioBufferCache: Data? {
        get { userDefaults.data(forKey: "automaticAudioBufferCache.v1") }
        set { userDefaults.set(newValue, forKey: "automaticAudioBufferCache.v1") }
    }

    func commitAudioBufferDefault(_ frames: AudioBufferSetting, inheritingProfileIDs: Set<UUID> = []) async throws {
        try await commitAudioBufferDefault(frames, overrides: Dictionary(uniqueKeysWithValues: inheritingProfileIDs.map { ($0, nil) }))
    }
    func commitAudioBufferDefault(_ frames: AudioBufferSetting, overrides: [UUID: AudioBufferSetting?]) async throws {
        _ = try await commit(.audioBufferDefault(frames, overrides))
    }

    func defaultLayout(for type: ProfileEndpointKind) -> ProfileSectionLayout {
        layoutDefaults[type.rawValue] ?? ProfileSectionLayout(hidden: [.perChannel])
    }
    func effectiveLayout(for profile: DeviceProfile) -> ProfileSectionLayout {
        profile.sectionLayout ?? layoutDefaults[profile.endpointKind.rawValue] ?? profile.defaultSectionLayout
    }
    func setDefaultLayout(_ layout: ProfileSectionLayout, for type: ProfileEndpointKind) {
        guard settingsMutationsAllowed else { return }
        let before = defaultLayout(for: type)
        layoutDefaults[type.rawValue] = layout
        history?.record(actionName: "Change Default Section Layout", contextName: type.displayName, target: .globalSettings,
            before: .defaultLayout(type, before), after: .defaultLayout(type, layout))
    }
    func applyDefaultLayout(for type: ProfileEndpointKind, to ids: Set<UUID>) {
        guard settingsMutationsAllowed else { return }
        let before = profiles.filter { ids.contains($0.id) && $0.endpointKind == type }
            .map { ProfileLayoutHistoryState(profileID: $0.id, layout: $0.sectionLayout) }
        // Explicitly opted-in profiles resume inheritance; other local layouts stay intact.
        performBatchUpdate {
            for index in profiles.indices where ids.contains(profiles[index].id) && profiles[index].endpointKind == type {
                profiles[index].sectionLayout = nil
            }
        }
        history?.record(actionName: "Apply Default Section Layout", target: .globalSettings,
            before: .profileLayouts(before),
            after: .profileLayouts(before.map { .init(profileID: $0.profileID, layout: nil) }))
    }

    func restoreProfileLayouts(_ values: [ProfileLayoutHistoryState]) throws {
        guard settingsMutationsAllowed else { throw ProfileSettingsError.busy }
        guard Set(values.map(\.profileID)).isSubset(of: Set(profiles.map(\.id))) else { throw HistoryRestoreError.missingProfile }
        performBatchUpdate {
            for value in values {
                if let index = profiles.firstIndex(where: { $0.id == value.profileID }) {
                    profiles[index].sectionLayout = value.layout
                }
            }
        }
    }

    static func settingsSnapshot(_ profile: DeviceProfile) -> DeviceProfile {
        var result = profile
        // Hardware volume events are live state, not conflicting settings edits.
        result.outputVolumeScalar = 0
        result.inheritedSectionLayouts = [:]
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

    @discardableResult
    func commitSettings(_ candidate: DeviceProfile, expected: DeviceProfile,
                        originalActivation: ProfileActivationMode, activation: ProfileActivationMode,
                        restoringRouting: ProfileRoutingHistoryState? = nil) async throws -> ProfilePersistenceReceipt {
        try validateSettingsSnapshot(expected, activation: originalActivation)
        return try await commit(.settings(candidate, activation, restoringRouting))
    }

    func routingHistoryState(outputUIDs: Set<String>, profileIDs: Set<UUID>) -> ProfileRoutingHistoryState {
        .init(defaults: physicalDeviceDefaults.filter { outputUIDs.contains($0.physicalDevice.uid) },
              outputUIDs: outputUIDs,
              autoActivation: Dictionary(uniqueKeysWithValues: profiles.filter { profileIDs.contains($0.id) }
                .map { ($0.id, $0.autoActivateWhenProfileDeviceSelected) }))
    }

    func restoreRoutingHistoryState(_ value: ProfileRoutingHistoryState) throws {
        guard settingsMutationsAllowed else { throw ProfileSettingsError.busy }
        var restored = document
        try restored.restoreRouting(value)
        performBatchUpdate {
            profiles = restored.profiles
            physicalDeviceDefaults = restored.physicalDeviceDefaults
        }
    }

    @Published var selectedProfileID: UUID? {
        didSet { userDefaults.set(selectedProfileID?.uuidString, forKey: "selectedProfileID") }
    }
    @Published private(set) var persistenceError: String?

    let repository: ProfileRepository
    let assetStorage: ProfileAssetStorage
    private let liveAssets: ProfileAssetLease
    private(set) var libraryRevision = ProfileLibraryRevision(rawValue: 0)
    let userDefaults: UserDefaults
    private var isLoading = true
    private var saveDeferralDepth = 0
    private var needsDeferredSave = false
    private var pendingPersistence: Task<Void, Never>?
    @Published private(set) var hasDurableCommit = false
    private var activeDurableCommit: ProfileDurableCommit?
    private struct PendingPluginState {
        let plugin: AudioPluginDescriptor
        let previousState: Data?
        var state: Data
        var recordHistory: Bool
    }
    private var pendingPluginStates: [UUID: [UUID: PendingPluginState]] = [:]
    private(set) var deferredAutosaveNeeded = false
    private var stopping = false
    private var terminalDrainCompleted = false
    var performanceRecorder: RuntimePerformanceRecorder?
    /// Diagnostic delivery gate; it never occupies the repository worker.
    var beforeAutosaveResult: (@MainActor () async -> Void)?
    var settingsMutationsAllowed: Bool { !stopping && !hasDurableCommit }

    private var protectsUnreadableStorage: Bool { repository.status.protectedStorage }

    init(storageURL: URL? = nil, userDefaults: UserDefaults = .standard, fileIO: ProfileRepositoryFileIO = .live) {
        let base = storageURL?.deletingLastPathComponent() ?? CamiTunePaths.supportDirectory
        let assetStorage = storageURL == nil ? ProfileAssetStorage.shared : ProfileAssetStorage(directory: base)
        self.assetStorage = assetStorage
        liveAssets = assetStorage.retain()
        self.repository = ProfileRepository(url: storageURL ?? base.appendingPathComponent("profiles.json"), io: fileIO,
            assetStorage: assetStorage)
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
        liveAssets.update(.init(profiles: profiles))
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
        guard settingsMutationsAllowed, !device.isRoutingDevice else { return nil }
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
        recordProfileCreation(profile.id)
        return profiles.first { $0.id == profile.id }
    }

    /// Persist before publication, selection, or exposing a routing endpoint.
    func insertConfiguredProfile(_ candidate: DeviceProfile) async throws -> UUID {
        let position = history?.beginPendingEdit()
        defer { history?.endPendingEdit(position) }
        _ = try await commit(.creation(candidate))
        selectedProfileID = candidate.id
        recordProfileCreation(candidate.id, position: position)
        return candidate.id
    }

    private func recordProfileCreation(_ id: UUID, position: HistoryPosition? = nil) {
        let snapshot = captureDeletionSnapshot(profileIDs: [id])
        history?.record(actionName: "Add Output Profile", contextName: snapshot.profiles.first?.name, target: .profileOrganization,
            before: .deletion(snapshot, deleted: true), after: .deletion(snapshot, deleted: false), position: position)
    }
    @discardableResult
    func commitMenuDeactivationPolicy(profileID: UUID) async throws -> ProfilePersistenceReceipt {
        try await commit(.routingPolicy(profileID))
    }

    func setAutoActivateWhenProfileDeviceSelected(profileID: UUID, enabled: Bool) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].autoActivateWhenProfileDeviceSelected = enabled
    }

    func setProfileEnabled(profileID: UUID, enabled: Bool, recordHistory: Bool = true) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let before = profiles[index]
        profiles[index].isEnabled = enabled
        if recordHistory {
            history?.record(actionName: enabled ? "Enable Profile" : "Disable Profile", contextName: before.name,
                target: .profile(profileID), before: .profileEnabled(before.isEnabled), after: .profileEnabled(enabled))
        }
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
        guard settingsMutationsAllowed else { throw ProfileSettingsError.busy }
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
        guard settingsMutationsAllowed else { return }
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
        guard settingsMutationsAllowed else { return }
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

    func update(_ profile: DeviceProfile, recordLayoutHistory: Bool = true) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard profiles[index] != profile else { return }
        guard ProfileNamePolicy.isAvailable(profile.name, in: profiles, excluding: profile.id) else { return }
        let previous = profiles[index]
        profiles[index] = profile
        if recordLayoutHistory, profiles[index].sectionLayout != previous.sectionLayout {
            history?.record(actionName: "Change Section Layout", contextName: profile.name, target: .globalSettings,
                before: .profileLayouts([.init(profileID: profile.id, layout: previous.sectionLayout)]),
                after: .profileLayouts([.init(profileID: profile.id, layout: profile.sectionLayout)]))
        }
    }

    /// Host notifications can arrive while settings own the durable document.
    /// Coalesce only the preset, and never overwrite an explicit replacement or
    /// resurrect a removed slot when that transaction finishes.
    func capturePluginState(profileID: UUID, slotID: UUID, data: Data, recordHistory: Bool = false) {
        guard !stopping, data.count <= PluginRack.maximumStateBytes,
              var profile = profiles.first(where: { $0.id == profileID }),
              let index = profile.pluginRack.slots.firstIndex(where: { $0.id == slotID }) else { return }
        let slot = profile.pluginRack.slots[index]
        if activeDurableCommit != nil {
            pendingPluginStates[profileID, default: [:]][slotID] = .init(
                    plugin: slot.plugin, previousState: slot.state, state: data, recordHistory: recordHistory)
            return
        }
        guard slot.state != data else { return }
        profile.pluginRack.slots[index].state = data
        update(profile)
        if recordHistory { recordPluginState(profile: profile, slotID: slotID, before: slot.state, after: data) }
    }

    private func recordPluginState(profile: DeviceProfile, slotID: UUID, before: Data?, after: Data) {
        let target = HistoryTarget.plugin(profile.id, slotID)
        history?.record(actionName: "Edit Plug-in", contextName: profile.name, target: target,
            before: .pluginState(before), after: .pluginState(after),
            coalescingKey: .init(target: target, control: "parameters"))
    }

    @discardableResult
    private func mergePendingPluginStates(into document: inout ProfileDocument) -> Bool {
        let pending = pendingPluginStates
        pendingPluginStates.removeAll()
        var changed = false
        for profileIndex in document.profiles.indices {
            guard let states = pending[document.profiles[profileIndex].id] else { continue }
            for slotIndex in document.profiles[profileIndex].pluginRack.slots.indices {
                let slot = document.profiles[profileIndex].pluginRack.slots[slotIndex]
                guard let update = states[slot.id], slot.plugin == update.plugin,
                      slot.state == update.previousState, slot.state != update.state else { continue }
                document.profiles[profileIndex].pluginRack.slots[slotIndex].state = update.state
                if update.recordHistory {
                    recordPluginState(profile: document.profiles[profileIndex], slotID: slot.id, before: slot.state, after: update.state)
                }
                changed = true
            }
        }
        return changed
    }

    private func load() {
        if let stored = repository.loadedDocument {
            audioBufferDefault = stored.audioBufferDefault
            multichannelDrafts = stored.multichannelDrafts.filter { id, _ in stored.profiles.contains { $0.id == id } }
            layoutDefaults = stored.layoutDefaults; showProfileEnabledExplanation = stored.showProfileEnabledExplanation
            rootOrder = stored.rootOrder; folders = stored.folders; profiles = stored.profiles
            physicalDeviceDefaults = stored.physicalDeviceDefaults
        } else if !repository.status.protectedStorage {
            layoutDefaults = Self.firstLaunchLayoutDefaults
        }
        if repository.status.protectedStorage {
            persistenceError = "CamiTune could not read the saved profiles. The original profiles.json is protected and cannot be overwritten."
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

    var document: ProfileDocument {
        ProfileDocument(profiles: profiles, physicalDeviceDefaults: physicalDeviceDefaults,
            folders: folders, rootOrder: effectiveRootOrder, layoutDefaults: layoutDefaults,
            showProfileEnabledExplanation: showProfileEnabledExplanation, multichannelDrafts: multichannelDrafts,
            audioBufferDefault: audioBufferDefault)
    }
    private func save() {
        guard !isLoading, !stopping else { return }
        liveAssets.update(.init(profiles: profiles))
        libraryRevision = .init(rawValue: libraryRevision.rawValue + 1)
        guard !protectsUnreadableStorage else { return }
        if activeDurableCommit != nil { deferredAutosaveNeeded = true; return }
        guard saveDeferralDepth == 0 else { needsDeferredSave = true; return }
        let stored = document, revision = libraryRevision
        pendingPersistence?.cancel()
        pendingPersistence = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, !self.stopping, self.activeDurableCommit == nil, self.libraryRevision == revision else { return }
            let result = await self.repository.submit(stored, source: revision, kind: .autosave).value()
            if let gate = self.beforeAutosaveResult { await gate() }
            guard self.libraryRevision == revision else { return }
            self.pendingPersistence = nil
            self.publishPersistence(result)
        }
    }
    private func publishPersistence(_ result: Result<ProfileAutosaveResult, Error>) {
        switch result {
        case .success(.committed): persistenceError = nil
        case .success(.superseded): break
        case .failure(let error): persistenceError = "CamiTune could not save your profiles: \(error.localizedDescription)"
        }
    }
    private func publishDocument(_ value: ProfileDocument) {
        isLoading = true
        audioBufferDefault = value.audioBufferDefault
        profiles = value.profiles; physicalDeviceDefaults = value.physicalDeviceDefaults
        folders = value.folders; rootOrder = value.rootOrder
        multichannelDrafts = value.multichannelDrafts
        layoutDefaults = value.layoutDefaults; showProfileEnabledExplanation = value.showProfileEnabledExplanation
        isLoading = false
        liveAssets.update(.init(profiles: profiles))
        libraryRevision = .init(rawValue: libraryRevision.rawValue + 1)
    }
    private func commit(_ mutation: ProfileDocumentMutation) async throws -> ProfilePersistenceReceipt {
        guard settingsMutationsAllowed else { throw ProfileSettingsError.busy }
        guard !protectsUnreadableStorage else { throw ProfileRepositoryError.protectedStorage }
        let candidate = try mutation.applying(to: document)
        pendingPersistence?.cancel(); pendingPersistence = nil
        libraryRevision = .init(rawValue: libraryRevision.rawValue + 1)
        let operation = performanceRecorder?.begin("Profile persistence", reason: mutation.kind.rawValue, revision: libraryRevision.rawValue)
        operation?.mark("repository submission")
        let ticket = repository.submit(candidate, source: libraryRevision, kind: mutation.kind)
        activeDurableCommit = .init(mutation: mutation, ticket: ticket); hasDurableCommit = true
        defer {
            activeDurableCommit = nil; hasDurableCommit = false
            if !stopping {
                var latest = document
                if mergePendingPluginStates(into: &latest) {
                    publishDocument(latest)
                    deferredAutosaveNeeded = true
                }
            }
            if deferredAutosaveNeeded && !stopping {
                deferredAutosaveNeeded = false; save()
            }
        }
        do {
            let outcome = try await ticket.value().get()
            guard case .committed(let receipt) = outcome else { preconditionFailure("Durable transaction cannot be superseded") }
            operation?.recordPersistence(receipt)
            // Same-profile settings and policy were barred; apply only the typed
            // mutation to today's library, preserving new volume/organization.
            if !stopping { publishDocument(try mutation.applying(to: document)) }
            persistenceError = nil
            operation?.mark("MainActor publication"); operation?.finish("success")
            return receipt
        } catch {
            deferredAutosaveNeeded = true
            persistenceError = "CamiTune could not save your profiles: \(error.localizedDescription)"
            operation?.finish("failed")
            throw error
        }
    }
    func persistHistoryChanges() async throws { _ = try await commit(.history) }

    /// Awaitable flush for diagnostics/explicit durability. Ordinary edits retain debounce.
    func flushPendingSave() async throws {
        guard !hasDurableCommit, !stopping else { throw ProfileSettingsError.busy }
        pendingPersistence?.cancel(); pendingPersistence = nil
        let revision = libraryRevision
        let result = await repository.submit(document, source: revision, kind: .autosave).value()
        if let gate = beforeAutosaveResult { await gate() }
        if libraryRevision == revision { publishPersistence(result) }
        _ = try result.get()
    }
    func shutdownSynchronously() {
        guard !stopping else { return }
        stopping = true
        flushPendingSaveSynchronously()
        terminalDrainCompleted = true
    }
    /// Terminal/isolated diagnostic teardown only; no interactive callers.
    func flushPendingSaveSynchronously() {
        guard !isLoading, !terminalDrainCompleted else { return }
        pendingPersistence?.cancel(); pendingPersistence = nil
        // Finish accepted work first. The worker and ticket completion do not
        // depend on MainActor. A held durable candidate must never be replaced
        // by the older published library on termination.
        repository.drainSynchronously()
        var final = document
        if let active = activeDurableCommit,
           case .success(.committed) = active.ticket.waitSynchronously() {
            guard let merged = try? active.mutation.applying(to: final) else { return }
            final = merged
        }
        mergePendingPluginStates(into: &final)
        libraryRevision = .init(rawValue: libraryRevision.rawValue + 1)
        publishPersistence(repository.submit(final, source: libraryRevision, kind: .shutdownFlush).waitSynchronously())
        repository.drainSynchronously()
    }
    var repositorySummary: String {
        let state = repository.status, last = state.lastReceipt
        return [
            "Schema: \(ProfileDocument.currentSchemaVersion) • Durable revision: \(state.lastCommittedRevision.rawValue)",
            "Library revision: \(libraryRevision.rawValue) • Protected storage: \(state.protectedStorage)",
            "Writer: \(state.inFlightKind?.rawValue ?? "Idle") • Operation: \(state.inFlightOperation.map { String($0.rawValue) } ?? "—")",
            "Pending autosave: \(state.pendingAutosave) • Pending durable writes: \(state.pendingDurableCount)",
            "Store transaction: \(activeDurableCommit?.mutation.kind.rawValue ?? "None") • Deferred autosave: \(deferredAutosaveNeeded)",
            "Last operation: \(last?.kind.rawValue ?? "None") • Superseded autosaves: \(state.supersededAutosaveCount) • Failures: \(state.writeFailures)",
            String(format: "Last queue / encode / write: %.3f / %.3f / %.3f ms", last?.queueMilliseconds ?? 0, last?.encodingMilliseconds ?? 0, last?.writeMilliseconds ?? 0),
            "Storage state: \(state.lastError ?? "Healthy")"
        ].joined(separator: "\n")
    }
}
