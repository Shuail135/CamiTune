import Foundation
import CoreAudio
import AudioToolbox
import SystemAudioBridgeC
import Darwin

struct PhysicalVolumeTransferSnapshot: Sendable {
    let scalar: Float32?
    let decibels: [Float32]
}

struct OutputVolumeCapabilities: Sendable, Equatable {
    let volumeReadable: Bool
    let volumeWritable: Bool
    let muteReadable: Bool
    let muteWritable: Bool

    var supportsHardwareMirroring: Bool { volumeReadable && volumeWritable }
}

@MainActor
final class CoreAudioManager: ObservableObject {
    // Driver 0.8.2 reserves audio identity slots for running clients and retires
    // removed endpoints' registrations, preventing registry exhaustion and lost
    // per-app controls after profile reactivation.
    static let minimumPresentationDriverVersion = "0.8.2"

    @Published private(set) var outputDevices: [AudioDeviceInfo] = []
    @Published private(set) var defaultOutputUID: String?
    @Published private(set) var hasCompletedInitialRefresh = false

    private struct SampleRateCapabilities: Sendable {
        var currentRate: Double?
        var ranges: [ClosedRange<Double>]
        var isSettable: Bool
    }

    private var timer: Timer?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var periodicRefreshInFlight = false
    private var sampleRateCapabilitiesByUID: [String: SampleRateCapabilities] = [:]
    private var cachedHiddenSystemAudioBridge: AudioDeviceInfo?
    private var hasResolvedHiddenSystemAudioBridge = false

    init() {
        schedulePeriodicRefresh()
        installHardwareListeners()
        // Core Audio notifications drive normal updates. This slow poll is a
        // recovery path for a lost notification or a restarted coreaudiod, not
        // a permanent one-Hz tax on the HAL device graph.
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.schedulePeriodicRefresh()
            }
        }
    }

    deinit {
        timer?.invalidate()
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        if let deviceListListener {
            var address = Self.deviceListAddress
            _ = AudioObjectRemovePropertyListenerBlock(
                systemObject,
                &address,
                .main,
                deviceListListener
            )
        }
        if let defaultOutputListener {
            var address = Self.defaultOutputAddress
            _ = AudioObjectRemovePropertyListenerBlock(
                systemObject,
                &address,
                .main,
                defaultOutputListener
            )
        }
    }

    private func installHardwareListeners() {
        let refresh: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.schedulePeriodicRefresh() }
        }
        deviceListListener = refresh
        defaultOutputListener = refresh
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var deviceListAddress = Self.deviceListAddress
        var defaultOutputAddress = Self.defaultOutputAddress
        _ = AudioObjectAddPropertyListenerBlock(
            systemObject,
            &deviceListAddress,
            .main,
            refresh
        )
        _ = AudioObjectAddPropertyListenerBlock(
            systemObject,
            &defaultOutputAddress,
            .main,
            refresh
        )
    }

    nonisolated private static var deviceListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    nonisolated private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    func refresh() {
        // An explicit refresh is also the escape hatch after driver repair or a
        // coreaudiod restart, when the hidden bridge may receive a new object ID.
        cachedHiddenSystemAudioBridge = nil
        hasResolvedHiddenSystemAudioBridge = false
        let snapshot = Self.readDeviceSnapshot()
        apply(devices: snapshot.devices, defaultUID: snapshot.defaultUID)
    }

    func refreshWithoutBlockingUI() async {
        cachedHiddenSystemAudioBridge = nil
        hasResolvedHiddenSystemAudioBridge = false
        let snapshot = await Task.detached(priority: .utility) {
            Self.readDeviceSnapshot()
        }.value
        apply(devices: snapshot.devices, defaultUID: snapshot.defaultUID)
    }

    private func schedulePeriodicRefresh() {
        guard !periodicRefreshInFlight else { return }
        periodicRefreshInFlight = true
        Task.detached(priority: .utility) {
            let snapshot = Self.readDeviceSnapshot()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.periodicRefreshInFlight = false
                self.apply(devices: snapshot.devices, defaultUID: snapshot.defaultUID)
            }
        }
    }

    private func apply(devices: [AudioDeviceInfo], defaultUID: String?) {
        if outputDevices != devices {
            outputDevices = devices
            sampleRateCapabilitiesByUID.removeAll()
        }
        // Retry a previously missing hidden bridge on the next periodic HAL
        // snapshot, while still coalescing all lookups made by one UI render.
        if cachedHiddenSystemAudioBridge == nil {
            hasResolvedHiddenSystemAudioBridge = false
        }
        if defaultOutputUID != defaultUID { defaultOutputUID = defaultUID }
        if !hasCompletedInitialRefresh {
            hasCompletedInitialRefresh = true
        }
    }

    nonisolated private static func readDeviceSnapshot() -> (
        devices: [AudioDeviceInfo],
        defaultUID: String?
    ) {
        let devices = enumerateOutputDevices().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let defaultUID = defaultOutputDevice().flatMap(deviceUID)
        return (devices, defaultUID)
    }

    var physicalOutputDevices: [AudioDeviceInfo] {
        outputDevices.filter { !$0.isRoutingDevice }
    }

    /// A render-safe lookup that never enters Core Audio. SwiftUI body
    /// evaluation and periodic policy checks must use this snapshot rather than
    /// synchronously translating a UID through HAL on the main actor.
    func cachedDevice(uid: String) -> AudioDeviceInfo? {
        if uid == AudioDeviceInfo.systemAudioBridgeUID {
            return outputDevices.first(where: { $0.id == uid })
                ?? cachedHiddenSystemAudioBridge
        }
        return outputDevices.first(where: { $0.id == uid })
    }

    var systemAudioBridge: AudioDeviceInfo? {
        // CamiTune hides the base transport after publishing the profile
        // endpoints. Hidden devices are omitted from the hardware device list
        // on some macOS releases, but they remain addressable by UID. Always
        // fall back to UID translation so Setup does not report its own hidden
        // bridge as uninstalled after a restart or recheck.
        if let visible = cachedDevice(uid: AudioDeviceInfo.systemAudioBridgeUID) {
            cachedHiddenSystemAudioBridge = visible
            hasResolvedHiddenSystemAudioBridge = true
            return visible
        }
        if hasResolvedHiddenSystemAudioBridge { return cachedHiddenSystemAudioBridge }
        let resolved = Self.deviceInfo(forUID: AudioDeviceInfo.systemAudioBridgeUID)
        cachedHiddenSystemAudioBridge = resolved
        hasResolvedHiddenSystemAudioBridge = true
        return resolved
    }

    func resolveSystemAudioBridgeWithoutBlockingUI() async -> AudioDeviceInfo? {
        await resolveDeviceWithoutBlockingUI(uid: AudioDeviceInfo.systemAudioBridgeUID)
    }

    func resolveDeviceWithoutBlockingUI(uid: String) async -> AudioDeviceInfo? {
        if let cached = cachedDevice(uid: uid) { return cached }
        if uid == AudioDeviceInfo.systemAudioBridgeUID,
           hasResolvedHiddenSystemAudioBridge {
            return cachedHiddenSystemAudioBridge
        }
        let resolved = await Task.detached(priority: .utility) {
            Self.deviceInfo(forUID: uid)
        }.value
        if uid == AudioDeviceInfo.systemAudioBridgeUID {
            cachedHiddenSystemAudioBridge = resolved
            hasResolvedHiddenSystemAudioBridge = true
        }
        return resolved
    }

    /// Driver endpoint publication can rebuild Core Audio's object graph while
    /// preserving device UIDs. Resolve the base bridge from its UID again
    /// before opening a transport instead of trusting a cached object ID.
    func freshlyResolvedSystemAudioBridge() -> AudioDeviceInfo? {
        let resolved = Self.deviceInfo(forUID: AudioDeviceInfo.systemAudioBridgeUID)
        cachedHiddenSystemAudioBridge = resolved
        hasResolvedHiddenSystemAudioBridge = true
        return resolved
    }

    func freshlyResolvedSystemAudioBridgeWithoutBlockingUI() async -> AudioDeviceInfo? {
        let resolved = await Task.detached(priority: .userInitiated) {
            Self.deviceInfo(forUID: AudioDeviceInfo.systemAudioBridgeUID)
        }.value
        cachedHiddenSystemAudioBridge = resolved
        hasResolvedHiddenSystemAudioBridge = true
        return resolved
    }

    private func invalidateSystemAudioBridgeReference() {
        cachedHiddenSystemAudioBridge = nil
        hasResolvedHiddenSystemAudioBridge = false
    }

    var isSystemAudioBridgeTransportSupported: Bool {
        guard let device = systemAudioBridge else { return false }
        return sabr_client_transport_is_supported(device.objectID)
    }

    var installedSystemAudioBridgeVersion: String? {
        let path = "/Library/Audio/Plug-Ins/HAL/CamillaAudio.driver/Contents/Info.plist"
        guard let dictionary = NSDictionary(contentsOfFile: path) else { return nil }
        return dictionary["CFBundleShortVersionString"] as? String
    }

    var installedSystemAudioBridgeChannelLayout: LPCMChannelLayout? {
        let path = "/Library/Audio/Plug-Ins/HAL/CamillaAudio.driver/Contents/Info.plist"
        guard let dictionary = NSDictionary(contentsOfFile: path),
              let channelCount = dictionary["SystemAudioBridgeChannelCount"] as? Int else {
            return nil
        }
        if let tag = dictionary["SystemAudioBridgeChannelLayoutTag"] as? UInt32 {
            return LPCMChannelLayout(coreAudioTag: tag, channelCount: channelCount)
        }
        return LPCMChannelLayout.canonical(forChannelCount: channelCount)
    }

    var isSystemAudioBridgePresentationSupported: Bool {
        guard isSystemAudioBridgeTransportSupported,
              let version = installedSystemAudioBridgeVersion else { return false }
        return Self.version(version, isAtLeast: Self.minimumPresentationDriverVersion)
    }

    func systemAudioBridgePresentationIsSupportedWithoutBlockingUI() async -> Bool {
        guard let version = installedSystemAudioBridgeVersion,
              Self.version(version, isAtLeast: Self.minimumPresentationDriverVersion),
              let bridge = await resolveSystemAudioBridgeWithoutBlockingUI() else {
            return false
        }
        let objectID = bridge.objectID
        return await Task.detached(priority: .utility) {
            sabr_client_transport_is_supported(objectID)
        }.value
    }

    private static func version(_ candidate: String, isAtLeast minimum: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = minimum.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return true
    }

    func setSystemAudioBridgePresentation(name: String, visible: Bool) throws {
        guard let bridge = systemAudioBridge else {
            throw AudioError.deviceNotFound(AudioDeviceInfo.systemAudioBridgeUID)
        }
        let status = setSystemAudioBridgePresentation(
            objectID: bridge.objectID,
            name: name,
            visible: visible
        )
        guard status == noErr else { throw AudioError.osStatus(status) }
    }

    /// Core Audio plug-in property setters can wait for HAL to rebuild its
    /// device graph. Startup uses this form so that work never holds the main
    /// actor while the first window is being rendered.
    func setSystemAudioBridgePresentationWithoutBlockingUI(
        name: String,
        visible: Bool
    ) async throws {
        guard let bridge = await resolveSystemAudioBridgeWithoutBlockingUI() else {
            throw AudioError.deviceNotFound(AudioDeviceInfo.systemAudioBridgeUID)
        }
        let objectID = bridge.objectID
        let status = await Task.detached(priority: .utility) {
            name.withCString { displayName in
                sabr_client_set_presentation(objectID, displayName, visible)
            }
        }.value
        guard status == noErr else { throw AudioError.osStatus(status) }
    }

    private func setSystemAudioBridgePresentation(
        objectID: AudioObjectID,
        name: String,
        visible: Bool
    ) -> OSStatus {
        name.withCString { displayName in
            sabr_client_set_presentation(objectID, displayName, visible)
        }
    }

    func device(uid: String) -> AudioDeviceInfo? {
        if let cached = cachedDevice(uid: uid) { return cached }
        if uid == AudioDeviceInfo.systemAudioBridgeUID { return systemAudioBridge }
        return Self.deviceInfo(forUID: uid)
    }

    func profileRoutingDevice(profileID: UUID) -> AudioDeviceInfo? {
        device(uid: ProfileRoutingDescriptor.uid(for: profileID))
    }

    func waitForProfileRoutingDevice(profileID: UUID) async -> AudioDeviceInfo? {
        let uid = ProfileRoutingDescriptor.uid(for: profileID)
        for attempt in 0..<40 {
            if let device = outputDevices.first(where: { $0.id == uid }) {
                return device
            }
            // Publishing a native profile endpoint is asynchronous inside HAL.
            // Poll only the requested UID and keep that Core Audio lookup off the
            // main actor; enumerating every device here made activation and the
            // entire UI stall repeatedly while the endpoint appeared.
            let resolved = await Task.detached(priority: .userInitiated) {
                Self.deviceInfo(forUID: uid)
            }.value
            if let resolved { return resolved }
            guard attempt < 39, !Task.isCancelled else { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// Unpublishes the driver's native profile endpoints and removes any
    /// aggregate selectors left by an older CamiTune build.
    func destroyAllProfileRoutingDevices(fallbackUID: String? = nil) {
        refresh()
        var selectors = outputDevices.filter {
            ProfileRoutingDescriptor.isProfileRoutingUID($0.id)
        }
        if let defaultOutputUID,
           selectors.contains(where: { $0.id == defaultOutputUID }) {
            let fallback = fallbackUID.flatMap { requested in
                physicalOutputDevices.first(where: { $0.id == requested })?.id
            } ?? physicalOutputDevices.first?.id
            if let fallback { try? setDefaultOutput(uid: fallback) }
        }

        refresh()
        selectors = outputDevices.filter {
            ProfileRoutingDescriptor.isProfileRoutingUID($0.id)
        }
        for device in selectors where device.id != defaultOutputUID && isAggregateDevice(device.objectID) {
            let status = AudioHardwareDestroyAggregateDevice(device.objectID)
            guard status == noErr || status == kAudioHardwareBadObjectError else { continue }
        }
        if let bridge = systemAudioBridge {
            _ = sabr_client_set_profile_devices(bridge.objectID, [] as CFArray)
        }
        refresh()
    }

    @discardableResult
    func synchronizeProfileRoutingDevices(
        profiles: [DeviceProfile],
        activeProfileID: UUID?,
        additionallyVisible: Set<UUID> = []
    ) throws -> [UUID: ProfileRoutingDescriptor] {
        guard let bridge = systemAudioBridge else { throw AudioError.deviceNotFound(AudioDeviceInfo.systemAudioBridgeUID) }

        let descriptors = ProfileRoutingDescriptor.descriptors(for: profiles)
        let desired = ProfileRoutingDescriptor.visibleProfileIDs(
            profiles: profiles,
            activeProfileID: activeProfileID,
            defaultOutputUID: defaultOutputUID,
            additionallyVisible: additionallyVisible
        )

        // One-time migration: native driver endpoints replace the aggregate
        // selectors used by older builds.
        var migratedDefaultUID: String?
        for device in outputDevices where
            ProfileRoutingDescriptor.isProfileRoutingUID(device.id) &&
            isAggregateDevice(device.objectID) {
            if device.id == defaultOutputUID {
                migratedDefaultUID = device.id
                try setDefaultOutput(uid: bridge.id)
            }
            let status = AudioHardwareDestroyAggregateDevice(device.objectID)
            guard status == noErr || status == kAudioHardwareBadObjectError else {
                throw AudioError.osStatus(status)
            }
        }

        let profileDevices = try desired.sorted(by: { $0.uuidString < $1.uuidString }).compactMap { profileID -> ProfileEndpointState? in
            guard let descriptor = descriptors[profileID] else { return nil }
            return try ProfileEndpointState(payload: descriptor.formatPayload())
        }
        try ProfileEndpointPublication.publish(profileDevices, using: NativeProfileEndpointBackend(bridgeID: bridge.objectID))
        invalidateSystemAudioBridgeReference()
        if migratedDefaultUID != nil {
            refresh()
        }
        if let migratedDefaultUID, device(uid: migratedDefaultUID) != nil {
            try setDefaultOutput(uid: migratedDefaultUID)
        }
        return descriptors
    }

    /// Publishes already-migrated native profile endpoints without blocking
    /// the first window on a HAL device-graph rebuild. Legacy aggregate
    /// migration remains on the synchronous maintenance path above.
    @discardableResult
    func synchronizeProfileRoutingDevicesWithoutBlockingUI(
        profiles: [DeviceProfile],
        activeProfileID: UUID?,
        additionallyVisible: Set<UUID> = []
    ) async throws -> [UUID: ProfileRoutingDescriptor] {
        if outputDevices.contains(where: {
            ProfileRoutingDescriptor.isProfileRoutingUID($0.id)
                && isAggregateDevice($0.objectID)
        }) {
            return try synchronizeProfileRoutingDevices(
                profiles: profiles,
                activeProfileID: activeProfileID,
                additionallyVisible: additionallyVisible
            )
        }

        guard let bridge = await resolveSystemAudioBridgeWithoutBlockingUI() else {
            throw AudioError.deviceNotFound(AudioDeviceInfo.systemAudioBridgeUID)
        }
        let descriptors = ProfileRoutingDescriptor.descriptors(for: profiles)
        let desired = ProfileRoutingDescriptor.visibleProfileIDs(
            profiles: profiles,
            activeProfileID: activeProfileID,
            defaultOutputUID: defaultOutputUID,
            additionallyVisible: additionallyVisible
        )
        let profileDevices = try desired.sorted(by: { $0.uuidString < $1.uuidString }).compactMap { profileID -> ProfileEndpointState? in
            guard let descriptor = descriptors[profileID] else { return nil }
            return try ProfileEndpointState(payload: descriptor.formatPayload())
        }
        let objectID = bridge.objectID
        try await Task.detached(priority: .utility) {
            try ProfileEndpointPublication.publish(profileDevices, using: NativeProfileEndpointBackend(bridgeID: objectID))
        }.value
        invalidateSystemAudioBridgeReference()
        return descriptors
    }

    func supportsSampleRate(uid: String, rate: Double) -> Bool {
        guard rate.isFinite, rate > 0 else { return false }
        let capabilities: SampleRateCapabilities
        if let cached = sampleRateCapabilitiesByUID[uid] {
            capabilities = cached
        } else {
            // This method is queried repeatedly while SwiftUI builds the profile
            // editor. Prefer the already-refreshed snapshot so each device's HAL
            // capabilities are read only once. The base bridge is deliberately
            // hidden after native profile endpoints are published, however, and
            // some macOS releases omit hidden devices from that snapshot. Resolve
            // that one known transport by UID instead of treating every rate as
            // unsupported.
            let device = outputDevices.first(where: { $0.id == uid })
                ?? (uid == AudioDeviceInfo.systemAudioBridgeUID
                    ? systemAudioBridge
                    : nil)
            guard let device else {
                return false
            }
            capabilities = readSampleRateCapabilities(device: device)
            sampleRateCapabilitiesByUID[uid] = capabilities
        }
        if let current = capabilities.currentRate, abs(current - rate) < 0.5 {
            return true
        }
        return capabilities.isSettable && capabilities.ranges.contains {
            $0.contains(rate)
        }
    }

    func supportsSampleRateWithoutBlockingUI(uid: String, rate: Double) async -> Bool {
        guard rate.isFinite, rate > 0 else { return false }
        let capabilities: SampleRateCapabilities
        if let cached = sampleRateCapabilitiesByUID[uid] {
            capabilities = cached
        } else {
            guard let device = await resolveDeviceWithoutBlockingUI(uid: uid) else {
                return false
            }
            capabilities = await Task.detached(priority: .utility) {
                Self.readSampleRateCapabilities(device: device)
            }.value
            sampleRateCapabilitiesByUID[uid] = capabilities
        }
        if let current = capabilities.currentRate, abs(current - rate) < 0.5 {
            return true
        }
        return capabilities.isSettable && capabilities.ranges.contains {
            $0.contains(rate)
        }
    }

    private func readSampleRateCapabilities(
        device: AudioDeviceInfo
    ) -> SampleRateCapabilities {
        Self.readSampleRateCapabilities(device: device)
    }

    nonisolated private static func readSampleRateCapabilities(
        device: AudioDeviceInfo
    ) -> SampleRateCapabilities {
        var availableRatesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            device.objectID,
            &availableRatesAddress,
            0,
            nil,
            &size
        ) == noErr else {
            return SampleRateCapabilities(
                currentRate: nominalSampleRate(deviceID: device.objectID),
                ranges: [],
                isSettable: false
            )
        }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        guard count > 0 else {
            return SampleRateCapabilities(
                currentRate: nominalSampleRate(deviceID: device.objectID),
                ranges: [],
                isSettable: false
            )
        }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        let didReadRanges = AudioObjectGetPropertyData(
            device.objectID,
            &availableRatesAddress,
            0,
            nil,
            &size,
            &ranges
        ) == noErr

        var nominalRateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable: DarwinBoolean = false
        let isSettable = AudioObjectIsPropertySettable(
            device.objectID,
            &nominalRateAddress,
            &settable
        ) == noErr && settable.boolValue
        return SampleRateCapabilities(
            currentRate: nominalSampleRate(deviceID: device.objectID),
            ranges: didReadRanges
                ? ranges.map { $0.mMinimum...$0.mMaximum }
                : [],
            isSettable: isSettable
        )
    }

    func nominalSampleRate(uid: String) -> Double? {
        guard let device = device(uid: uid) else { return nil }
        return Self.nominalSampleRate(deviceID: device.objectID)
    }

    /// Runtime health monitoring awaits this detached read, keeping a slow HAL
    /// device from blocking input handling and SwiftUI rendering.
    func nominalSampleRateWithoutBlockingUI(uid: String) async -> Double? {
        let cachedObjectID = cachedDevice(uid: uid)?.objectID
        return await Task.detached(priority: .utility) {
            let objectID = cachedObjectID ?? Self.deviceObjectID(forUID: uid)
            guard let objectID else { return nil }
            return Self.nominalSampleRate(deviceID: objectID)
        }.value
    }

    nonisolated private static func nominalSampleRate(
        deviceID: AudioDeviceID
    ) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value
    }

    func setSampleRate(uid: String, rate: Double) async throws {
        guard let device = await resolveDeviceWithoutBlockingUI(uid: uid) else {
            throw AudioError.deviceNotFound(uid)
        }
        try await Task.detached(priority: .userInitiated) {
            if let actual = Self.nominalSampleRate(deviceID: device.objectID),
               abs(actual - rate) < 0.5 {
                return
            }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(
                device.objectID,
                &address,
                &settable
            ) == noErr, settable.boolValue else {
                throw AudioError.sampleRateNotSettable(device.name)
            }
            var value = rate
            let status = AudioObjectSetPropertyData(
                device.objectID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Double>.size),
                &value
            )
            guard status == noErr else { throw AudioError.osStatus(status) }
            for attempt in 0..<20 {
                let actual = Self.nominalSampleRate(deviceID: device.objectID)
                if let actual, abs(actual - rate) < 0.5 { return }
                guard attempt < 19 else {
                    throw AudioError.sampleRateDidNotApply(
                        device.name,
                        requested: rate,
                        actual: actual
                    )
                }
                try await Task.sleep(for: .milliseconds(25))
            }
        }.value
        sampleRateCapabilitiesByUID.removeValue(forKey: uid)
    }

    func setDefaultOutput(uid: String) throws {
        guard let device = device(uid: uid) else { throw AudioError.deviceNotFound(uid) }
        var id = AudioDeviceID(device.objectID)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
        guard status == noErr else { throw AudioError.osStatus(status) }
        // A successful HAL setter is authoritative. Updating this snapshot
        // directly avoids a full device enumeration on every activation; the
        // periodic refresh still reconciles external changes.
        defaultOutputUID = uid
    }

    func setDefaultOutputAndWait(uid: String) async throws {
        let fallbackName = cachedDevice(uid: uid)?.name ?? uid
        var lastError: Error = AudioError.deviceNotFound(uid)

        // Publishing or hiding driver endpoints can rebuild HAL's object graph.
        // Resolve the target UID afresh for every attempt so a cached AudioDeviceID
        // cannot make an otherwise valid restore fail intermittently.
        for attempt in 0..<3 {
            do {
                try await Task.detached(priority: .userInitiated) {
                    guard let device = Self.deviceInfo(forUID: uid) else {
                        throw AudioError.deviceNotFound(uid)
                    }
                    var id = AudioDeviceID(device.objectID)
                    var address = AudioObjectPropertyAddress(
                        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    let status = AudioObjectSetPropertyData(
                        AudioObjectID(kAudioObjectSystemObject),
                        &address,
                        0,
                        nil,
                        UInt32(MemoryLayout<AudioDeviceID>.size),
                        &id
                    )
                    guard status == noErr else { throw AudioError.osStatus(status) }
                    for confirmationAttempt in 0..<40 {
                        let current = Self.defaultOutputDevice().flatMap(Self.deviceUID)
                        if current == uid { return }
                        guard confirmationAttempt < 39 else {
                            throw AudioError.defaultOutputDidNotApply(device.name)
                        }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                }.value
                if defaultOutputUID != uid { defaultOutputUID = uid }
                return
            } catch {
                lastError = error
                guard attempt < 2 else { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        if case AudioError.deviceNotFound = lastError {
            throw AudioError.deviceNotFound(uid)
        }
        if case AudioError.defaultOutputDidNotApply = lastError {
            throw AudioError.defaultOutputDidNotApply(fallbackName)
        }
        throw lastError
    }

    func setVolume(uid: String, scalar: Float32) throws {
        guard let device = device(uid: uid) else { throw AudioError.deviceNotFound(uid) }
        try Self.setVolume(deviceID: device.objectID, scalar: scalar)
    }

    func setVolumeWithoutBlockingUI(uid: String, scalar: Float32) async throws {
        guard let device = await resolveDeviceWithoutBlockingUI(uid: uid) else {
            throw AudioError.deviceNotFound(uid)
        }
        try await setVolumeWithoutBlockingUI(deviceID: device.objectID, scalar: scalar)
    }

    func setVolumeWithoutBlockingUI(deviceID: AudioDeviceID, scalar: Float32) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.setVolume(deviceID: deviceID, scalar: scalar)
        }.value
    }

    func volume(uid: String) -> Float32? {
        guard let device = device(uid: uid) else { return nil }
        return Self.floatProperty(
            deviceID: device.objectID,
            selector: kAudioDevicePropertyVolumeScalar
        )
    }

    func volumeWithoutBlockingUI(uid: String) async -> Float32? {
        guard let device = await resolveDeviceWithoutBlockingUI(uid: uid) else { return nil }
        return await volumeWithoutBlockingUI(deviceID: device.objectID)
    }

    func volumeWithoutBlockingUI(deviceID: AudioDeviceID) async -> Float32? {
        await Task.detached(priority: .utility) {
            Self.floatProperty(
                deviceID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar
            )
        }.value
    }

    func outputVolumeCapabilitiesWithoutBlockingUI(
        deviceID: AudioDeviceID
    ) async -> OutputVolumeCapabilities {
        await Task.detached(priority: .userInitiated) {
            Self.outputVolumeCapabilities(deviceID: deviceID)
        }.value
    }

    nonisolated static func outputVolumeCapabilities(
        deviceID: AudioDeviceID
    ) -> OutputVolumeCapabilities {
        func capability(_ selector: AudioObjectPropertySelector) -> (Bool, Bool) {
            var readable = false
            var writable = false
            for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: element
                )
                guard AudioObjectHasProperty(deviceID, &address) else { continue }
                readable = true
                var settable: DarwinBoolean = false
                if AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
                   settable.boolValue {
                    writable = true
                }
            }
            return (readable, writable)
        }
        let volume = capability(kAudioDevicePropertyVolumeScalar)
        let mute = capability(kAudioDevicePropertyMute)
        return OutputVolumeCapabilities(
            volumeReadable: volume.0, volumeWritable: volume.1,
            muteReadable: mute.0, muteWritable: mute.1
        )
    }

    /// Only call from a control queue, never from a PCM callback.
    nonisolated static func volumeTarget(deviceID: AudioDeviceID) -> PhysicalVolumeTarget? {
        guard let scalar = floatProperty(
            deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar
        ), scalar.isFinite else { return nil }
        return PhysicalVolumeTarget(scalar: scalar, muted: isMuted(deviceID: deviceID) ?? false)
    }

    /// Snapshots the physical endpoint's scalar->dB transfer function before
    /// playback begins. Runtime media-key handling can then use pure in-memory
    /// interpolation and never query the active hardware endpoint.
    func volumeTransferSnapshotWithoutBlockingUI(
        deviceID: AudioDeviceID,
        intervals: Int = 256
    ) async -> PhysicalVolumeTransferSnapshot {
        let count = max(16, min(1024, intervals))
        return await Task.detached(priority: .utility) { () -> PhysicalVolumeTransferSnapshot in
            let scalar = Self.floatProperty(
                deviceID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar
            )
            let effectiveDecibels = Self.floatProperty(
                deviceID: deviceID,
                selector: kAudioDevicePropertyVolumeDecibels
            )
            let range = Self.volumeDecibelRange(deviceID: deviceID)
            let nativeSamples = (0...count).map { index in
                let scalar = Float32(index) / Float32(count)
                return Self.volumeDecibels(deviceID: deviceID, scalar: scalar)
            }
            return PhysicalVolumeTransferSnapshot(
                scalar: scalar,
                decibels: SystemVolumeTransferCurve.calibratedDecibels(
                    nativeSamples: nativeSamples,
                    scalar: scalar ?? 1,
                    effectiveDecibels: effectiveDecibels,
                    minimumDecibels: range.map { Float32($0.mMinimum) },
                    maximumDecibels: range.map { Float32($0.mMaximum) }
                )
            )
        }.value
    }

    func volumeDecibels(uid: String) -> Float32? {
        guard let device = device(uid: uid) else { return nil }
        return Self.floatProperty(
            deviceID: device.objectID,
            selector: kAudioDevicePropertyVolumeDecibels
        )
    }

    func volumeDecibelsWithoutBlockingUI(uid: String) async -> Float32? {
        guard let device = await resolveDeviceWithoutBlockingUI(uid: uid) else { return nil }
        return await Task.detached(priority: .utility) {
            Self.floatProperty(
                deviceID: device.objectID,
                selector: kAudioDevicePropertyVolumeDecibels
            )
        }.value
    }

    func isMuted(uid: String) -> Bool? {
        guard let device = device(uid: uid) else { return nil }
        return Self.isMuted(deviceID: device.objectID)
    }

    func isMutedWithoutBlockingUI(uid: String) async -> Bool? {
        guard let device = await resolveDeviceWithoutBlockingUI(uid: uid) else { return nil }
        return await isMutedWithoutBlockingUI(deviceID: device.objectID)
    }

    func isMutedWithoutBlockingUI(deviceID: AudioDeviceID) async -> Bool? {
        await Task.detached(priority: .utility) {
            Self.isMuted(deviceID: deviceID)
        }.value
    }

    func setMuted(uid: String, muted: Bool) {
        guard let device = device(uid: uid) else { return }
        Self.setMuted(deviceID: device.objectID, muted: muted)
    }

    func setMutedWithoutBlockingUI(uid: String, muted: Bool) async {
        guard let device = await resolveDeviceWithoutBlockingUI(uid: uid) else { return }
        await setMutedWithoutBlockingUI(deviceID: device.objectID, muted: muted)
    }

    func setMutedWithoutBlockingUI(deviceID: AudioDeviceID, muted: Bool) async {
        await Task.detached(priority: .userInitiated) {
            Self.setMuted(deviceID: deviceID, muted: muted)
        }.value
    }

    func unmute(uid: String) {
        setMuted(uid: uid, muted: false)
    }

    nonisolated static func setVolume(
        deviceID: AudioDeviceID,
        scalar: Float32
    ) throws {
        let value = max(0, min(1, scalar))
        var didSet = false
        var writeError: OSStatus?

        for element in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain), 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(
                deviceID,
                &address,
                &settable
            ) == noErr, settable.boolValue else { continue }
            var current: Float32 = 0
            var currentSize = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &currentSize,
                &current
            ) == noErr, abs(current - value) < 0.0005 {
                didSet = true
                // A master element controls every channel. Without one, keep
                // checking every channel so a prior interrupted write cannot
                // leave the physical output with mismatched left/right gains.
                if element == kAudioObjectPropertyElementMain { break }
                continue
            }
            var v = value
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &v
            )
            if status == noErr {
                didSet = true
                if element == kAudioObjectPropertyElementMain { break }
            } else {
                writeError = status
            }
        }
        if let writeError { throw AudioError.osStatus(writeError) }
        if !didSet { throw AudioError.volumeNotSettable }
    }

    nonisolated private static func floatProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> Float32? {
        for element in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain), 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                &value
            ) == noErr {
                return value
            }
        }
        return nil
    }

    nonisolated private static func volumeDecibels(
        deviceID: AudioDeviceID,
        scalar: Float32
    ) -> Float32 {
        let clamped = max(0, min(1, scalar))
        for element in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain), 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalarToDecibels,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value = clamped
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                &value
            ) == noErr, value.isFinite {
                return max(-150, min(0, value))
            }
        }

        // A few endpoints expose a scalar control without the conversion
        // property. Falling back to amplitude dB is monotonic, reaches 0 dB at
        // scalar 1, and keeps exact zero representable as Camilla's floor.
        guard clamped > 0 else { return -150 }
        return max(-150, min(0, 20 * log10f(clamped)))
    }

    nonisolated private static func volumeDecibelRange(
        deviceID: AudioDeviceID
    ) -> AudioValueRange? {
        for element in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain), 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeRangeDecibels,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value = AudioValueRange()
            var size = UInt32(MemoryLayout<AudioValueRange>.size)
            if AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                &value
            ) == noErr,
               value.mMinimum.isFinite,
               value.mMaximum.isFinite,
               value.mMaximum > value.mMinimum {
                return value
            }
        }
        return nil
    }

    nonisolated private static func isMuted(deviceID: AudioDeviceID) -> Bool? {
        for element in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain), 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                &value
            ) == noErr {
                return value != 0
            }
        }
        return nil
    }

    nonisolated private static func setMuted(
        deviceID: AudioDeviceID,
        muted: Bool
    ) {
        try? setMuteChecked(deviceID: deviceID, muted: muted)
    }

    nonisolated static func setMuteChecked(deviceID: AudioDeviceID, muted: Bool) throws {
        var didSet = false
        var writeError: OSStatus?
        for element in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain), 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(
                deviceID,
                &address,
                &settable
            ) == noErr, settable.boolValue else { continue }
            var value: UInt32 = muted ? 1 : 0
            var current: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &current) == noErr,
               current == value {
                didSet = true
                if element == kAudioObjectPropertyElementMain { break }
                continue
            }
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &value
            )
            if status == noErr {
                didSet = true
                if element == kAudioObjectPropertyElementMain { break }
            } else {
                writeError = status
            }
        }
        if let writeError { throw AudioError.osStatus(writeError) }
        if !didSet { throw AudioError.volumeNotSettable }
    }

    nonisolated private static func enumerateOutputDevices() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasOutputStreams(id), let uid = deviceUID(id), let name = deviceName(id) else { return nil }
            return AudioDeviceInfo(
                id: uid,
                objectID: id,
                name: name,
                transportType: uint32Property(id, selector: kAudioDevicePropertyTransportType) ?? 0
            )
        }
    }

    nonisolated private static func deviceInfo(forUID uid: String) -> AudioDeviceInfo? {
        guard let objectID = deviceObjectID(forUID: uid),
              Self.hasOutputStreams(objectID),
              let name = Self.deviceName(objectID) else { return nil }
        return AudioDeviceInfo(
            id: uid,
            objectID: objectID,
            name: name,
            transportType: Self.uint32Property(objectID, selector: kAudioDevicePropertyTransportType) ?? 0
        )
    }

    nonisolated private static func deviceObjectID(forUID uid: String) -> AudioDeviceID? {
        var uidValue = uid as CFString
        var objectID = AudioDeviceID(kAudioObjectUnknown)
        let status = withUnsafePointer(to: &uidValue) { uidPointer in
            withUnsafeMutablePointer(to: &objectID) { objectPointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(mutating: uidPointer),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(objectPointer),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDeviceForUID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &size,
                    &translation
                )
            }
        }
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    private func isAggregateDevice(_ objectID: AudioObjectID) -> Bool {
        Self.uint32Property(objectID, selector: kAudioObjectPropertyClass) == kAudioAggregateDeviceClassID
    }

    nonisolated private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    nonisolated private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    nonisolated private static func deviceName(_ id: AudioDeviceID) -> String? {
        stringProperty(id, selector: kAudioObjectPropertyName)
    }

    nonisolated private static func deviceUID(_ id: AudioDeviceID) -> String? {
        stringProperty(id, selector: kAudioDevicePropertyDeviceUID)
    }

    nonisolated private static func stringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    nonisolated private static func uint32Property(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    enum AudioError: LocalizedError {
        case deviceNotFound(String)
        case osStatus(OSStatus)
        case volumeNotSettable
        case sampleRateNotSettable(String)
        case sampleRateDidNotApply(String, requested: Double, actual: Double?)
        case defaultOutputDidNotApply(String)
        case profileDeviceConfigurationFailed(OSStatus)
        var errorDescription: String? {
            switch self {
            case .deviceNotFound(let uid): return "Audio device not found: \(uid)"
            case .osStatus(let status): return "CoreAudio error: \(status)"
            case .volumeNotSettable: return "This audio device does not expose a settable output volume."
            case .sampleRateNotSettable(let name): return "The sample rate for \(name) cannot be changed by the app."
            case .sampleRateDidNotApply(let name, let requested, let actual):
                let requestedText = String(format: "%.1f kHz", requested / 1_000)
                let actualText = actual.map { String(format: "%.1f kHz", $0 / 1_000) } ?? "an unknown rate"
                return "\(name) did not switch to \(requestedText); it remained at \(actualText)."
            case .defaultOutputDidNotApply(let name):
                return "macOS did not finish switching the default audio output to \(name)."
            case .profileDeviceConfigurationFailed(let status):
                return "System Audio Bridge could not publish the profile audio devices (CoreAudio \(status)). Reinstall the bundled driver."
            }
        }
    }
}
