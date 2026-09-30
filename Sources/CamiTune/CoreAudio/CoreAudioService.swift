import CamiTuneDomain
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
final class CoreAudioService {
    // Driver 0.9.0 adds ordered producer closure and sealed-epoch records.
    // The companion must never infer this contract from a legacy v5 driver.
    static let minimumPresentationDriverVersion = "0.9.0"

    let snapshots = CoreAudioSnapshotStore()
    private(set) var outputDevices: [AudioDeviceInfo] = []
    var defaultOutputUID: String? {
        get { snapshots.defaultOutputUID }
        set { snapshots.publishDefault(newValue) }
    }
    var hasCompletedInitialRefresh: Bool { snapshots.hasCompletedInitialRefresh }
    typealias SampleRateCapabilities = CoreAudioRateCapabilities

    private var timer: Timer?
    private var periodicRefreshInFlight = false
    private var trailingRefresh = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var refreshCount = 0
    private(set) var coalescedRefreshCount = 0
    private(set) var recoveryRefreshCount = 0
    private(set) var lastRefreshMilliseconds: Double = 0
    private var defaultObservationRevision: UInt64 = 0
    var performanceRecorder: RuntimePerformanceRecorder?
    let backend: CoreAudioHALBackend
    private(set) var deviceGraphGeneration: UInt64 = 0
    private var publicationTasks: [UUID: Task<[CoreAudioWaitResult], Error>] = [:]
    private var readinessTasks: [UUID: Task<CoreAudioWaitResult, Error>] = [:]
    private(set) var lastWait: CoreAudioWaitResult?
    private(set) var fallbackConfirmations = 0
    private(set) var lastPublicationReceipt: CoreAudioEndpointPublicationReceipt?

    func cancelReadiness() { readinessTasks.values.forEach { $0.cancel() }; publicationTasks.values.forEach { $0.cancel() } }
    private func wait(event: CoreAudioEvent, timeout: Duration,
                      condition: @escaping @Sendable () -> Bool,
                      mutation: (@Sendable () throws -> Void)? = nil) async throws -> CoreAudioWaitResult {
        let operation = performanceRecorder?.begin("CoreAudio readiness", reason: String(describing: event))
        let backend = backend, id = UUID()
        let task = Task.detached(priority: .userInitiated) {
            try await CoreAudioConditionWaiter.wait(backend: backend, event: event, timeout: timeout, condition: condition, mutation: mutation)
        }
        readinessTasks[id] = task
        defer { readinessTasks.removeValue(forKey: id) }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            operation?.mark("acknowledgement: " + result.source.rawValue)
            operation?.finish(result.source == .timedOut ? "timed out" : "success")
            lastWait = result
            if result.source == .fallback { fallbackConfirmations += 1 }
            snapshots.publishDiagnostics("Graph generation: \(deviceGraphGeneration)\nLast readiness: \(result.source.rawValue), \(String(format: "%.2f", result.milliseconds)) ms\nFallback confirmations: \(fallbackConfirmations)")
            return result
        } catch {
            operation?.finish(error is CancellationError ? "cancelled" : "failed")
            lastWait = .init(source: .cancelled, milliseconds: 0)
            throw error
        }
    }

    func resolveRuntimeBinding(routingUID: String, physicalUID: String) async throws -> CoreAudioRuntimeBinding {
        let backend = backend
        for _ in 0..<3 {
            try Task.checkCancellation()
            let generation = deviceGraphGeneration
            let result = try await Task.detached(priority: .userInitiated) {
                guard let bridge = backend.resolve(AudioDeviceInfo.systemAudioBridgeUID),
                      let routing = backend.resolve(routingUID), let physical = backend.resolve(physicalUID) else {
                    throw AudioError.deviceNotFound(physicalUID)
                }
                return CoreAudioRuntimeBinding(bridge: bridge, routing: routing, physical: physical, graphGeneration: generation)
            }.value
            if generation == deviceGraphGeneration { return result }
        }
        throw ProfileSettingsError.runtime("Core Audio device bindings kept changing during route preparation.")
    }

    func probeSpeakerTopology(uid: String) async throws -> SpeakerTopology {
        let backend = backend
        return try await Task.detached(priority: .userInitiated) {
            guard let device = backend.resolve(uid) else { throw AudioError.deviceNotFound(uid) }
            return try SpeakerTopologyProbe().probe(device)
        }.value
    }
    func outputChannelCount(uid: String) async throws -> Int {
        let backend = backend
        return try await Task.detached(priority: .userInitiated) {
            guard let device = backend.resolve(uid) else { throw AudioError.deviceNotFound(uid) }
            return try SpeakerTopologyProbe().outputChannelCount(device)
        }.value
    }

    private var sampleRateCapabilitiesByUID: [String: SampleRateCapabilities] = [:]
    private var cachedHiddenSystemAudioBridge: AudioDeviceInfo?
    private var hasResolvedHiddenSystemAudioBridge = false

    init(observesHardware: Bool = true, backend: CoreAudioHALBackend = .live) {
        self.backend = backend
        guard observesHardware else { return }
        schedulePeriodicRefresh()
        installHardwareListeners()
        // Core Audio notifications drive normal updates. This slow poll is a
        // recovery path for a lost notification or a restarted coreaudiod, not
        // a permanent one-Hz tax on the HAL device graph.
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.recoveryRefreshCount += 1
                self.schedulePeriodicRefresh()
            }
        }
    }

    private var observationTokens: [CoreAudioListenerToken] = []
    deinit { timer?.invalidate(); observationTokens.forEach { $0.cancel() } }

    private func installHardwareListeners() {
        if let token = backend.subscribe(.devices, { [weak self] in
            Task { @MainActor [weak self] in self?.deviceGraphChanged() }
        }) { observationTokens.append(token) }
        if let token = backend.subscribe(.defaultOutput, { [weak self] in
            Task { @MainActor [weak self] in await self?.refreshDefaultOutput() }
        }) { observationTokens.append(token) }
    }

    private func deviceGraphChanged() {
        deviceGraphGeneration &+= 1
        invalidateSystemAudioBridgeReference()
        schedulePeriodicRefresh()
    }

    func readDefaultOutputWithoutBlockingUI() async -> String? {
        let backend = backend
        return await Task.detached(priority: .userInitiated) { backend.readDefaultOutput() }.value
    }

    func refreshDefaultOutput() async {
        defaultObservationRevision &+= 1
        let revision = defaultObservationRevision
        let backend = backend
        let uid = await Task.detached { backend.readDefaultOutput() }.value
        guard revision == defaultObservationRevision else { return }
        snapshots.publishDefault(uid)
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

    /// Synchronous maintenance only. Runtime and UI actions use the async path.
    func refresh() {
        invalidateSystemAudioBridgeReference()
        apply(devices: backend.enumerateOutputs(), defaultUID: backend.readDefaultOutput())
    }

    func refreshWithoutBlockingUI() async {
        schedulePeriodicRefresh()
        if periodicRefreshInFlight { await withCheckedContinuation { refreshWaiters.append($0) } }
    }

    private func schedulePeriodicRefresh() {
        guard !periodicRefreshInFlight else { trailingRefresh = true; coalescedRefreshCount += 1; return }
        periodicRefreshInFlight = true
        let backend = backend
        let operation = performanceRecorder?.begin("CoreAudio full snapshot")
        let start = Date()
        let defaultRevision = defaultObservationRevision
        Task {
            let result = await Task.detached(priority: .utility) {
                let devices = backend.enumerateOutputs().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                var rates: [String: CoreAudioRateCapabilities] = [:]
                for device in devices { rates[device.id] = backend.readRateCapabilities(device) }
                return (devices, backend.readDefaultOutput(), rates)
            }.value
            apply(devices: result.0, defaultUID: defaultRevision == defaultObservationRevision ? result.1 : snapshots.defaultOutputUID)
            sampleRateCapabilitiesByUID = result.2
            snapshots.publishRates(result.2)
            operation?.finish("success")
            refreshCount += 1; lastRefreshMilliseconds = Date().timeIntervalSince(start) * 1000
            periodicRefreshInFlight = false
            if trailingRefresh { trailingRefresh = false; schedulePeriodicRefresh() }
            else { let waiters = refreshWaiters; refreshWaiters = []; waiters.forEach { $0.resume() } }
        }
    }

    private func apply(devices: [AudioDeviceInfo], defaultUID: String?) {
        if outputDevices.map({ ($0.id, $0.objectID) }).elementsEqual(devices.map({ ($0.id, $0.objectID) }), by: { $0.0 == $1.0 && $0.1 == $1.1 }) == false {
            deviceGraphGeneration &+= 1
        }
        outputDevices = devices
        invalidateSystemAudioBridgeReference()
        snapshots.publish(outputs: devices.map(CoreAudioOutputSnapshot.init), defaultUID: defaultUID)
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
        let backend = backend
        return await Task.detached(priority: .utility) { backend.resolve(uid) }.value
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
        await resolveDeviceWithoutBlockingUI(uid: AudioDeviceInfo.systemAudioBridgeUID)
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
        guard let bridge = backend.resolve(AudioDeviceInfo.systemAudioBridgeUID) else {
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
        let backend = backend
        let status = try await Task.detached(priority: .utility) {
            guard let bridge = backend.resolve(AudioDeviceInfo.systemAudioBridgeUID) else { throw AudioError.deviceNotFound(AudioDeviceInfo.systemAudioBridgeUID) }
            return name.withCString { displayName in
                sabr_client_set_presentation(bridge.objectID, displayName, visible)
            }
        }.value
        guard status == noErr else { throw AudioError.osStatus(status) }
        deviceGraphChanged()
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
        return backend.resolve(uid)
    }

    func profileRoutingDevice(profileID: UUID) -> AudioDeviceInfo? {
        device(uid: ProfileRoutingDescriptor.uid(for: profileID))
    }

    func waitForProfileRoutingDevice(profileID: UUID) async -> AudioDeviceInfo? {
        await waitForDevice(uid: ProfileRoutingDescriptor.uid(for: profileID))
    }
    func waitForDevice(uid: String) async -> AudioDeviceInfo? {
        let backend = backend
        do {
            let result = try await wait(event: .devices, timeout: .seconds(2), condition: { backend.resolve(uid) != nil })
            guard result.source != .timedOut else { return nil }
            return await resolveDeviceWithoutBlockingUI(uid: uid)
        } catch { return nil }
    }

    func destroyAllProfileRoutingDevicesWithoutBlockingUI() async {
        let backend = backend
        await Task.detached(priority: .utility) {
            let devices = backend.enumerateOutputs()
            let current = backend.readDefaultOutput()
            if let current, ProfileRoutingDescriptor.isProfileRoutingUID(current),
               let physical = devices.first(where: { !$0.isRoutingDevice }),
               let fresh = backend.resolve(physical.id) { try? backend.setDefaultOutput(fresh) }
            for observed in devices where ProfileRoutingDescriptor.isProfileRoutingUID(observed.id) {
                guard let fresh = backend.resolve(observed.id),
                      Self.uint32Property(fresh.objectID, selector: kAudioObjectPropertyClass) == kAudioAggregateDeviceClassID else { continue }
                _ = AudioHardwareDestroyAggregateDevice(fresh.objectID)
            }
            if let bridge = backend.resolve(AudioDeviceInfo.systemAudioBridgeUID) { _ = try? backend.publishEndpoints(bridge, []) }
        }.value
        deviceGraphChanged()
        await refreshWithoutBlockingUI()
    }

    /// Unpublishes the driver's native profile endpoints and removes any
    /// aggregate selectors left by an older CamiTune build.
    func destroyAllProfileRoutingDevices(fallbackUID: String? = nil) {
        cancelReadiness()
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
            // Serialize with any cancelled publisher, including its rollback,
            // so an in-flight publication cannot recreate devices after cleanup.
            _ = try? backend.publishEndpoints(bridge, [])
        }
        refresh()
    }

    @discardableResult
    func synchronizeProfileRoutingDevices(
        profiles: [DeviceProfile],
        activeProfileID: UUID?,
        additionallyVisible: Set<UUID> = [],
        preparedDescriptors: [UUID: ProfileRoutingDescriptor] = [:]
    ) throws -> [UUID: ProfileRoutingDescriptor] {
        guard let bridge = systemAudioBridge else { throw AudioError.deviceNotFound(AudioDeviceInfo.systemAudioBridgeUID) }

        let request = try ProfileEndpointPublicationRequest(profiles: profiles, activeProfileID: activeProfileID,
            defaultOutputUID: defaultOutputUID, additionallyVisible: additionallyVisible, preparedDescriptors: preparedDescriptors)

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

        _ = try backend.publishEndpoints(bridge, request.endpoints)
        invalidateSystemAudioBridgeReference()
        if migratedDefaultUID != nil {
            refresh()
        }
        if let migratedDefaultUID, device(uid: migratedDefaultUID) != nil {
            try setDefaultOutput(uid: migratedDefaultUID)
        }
        return request.descriptors
    }

    /// Native publication and legacy compatibility execute off MainActor. Profile
    /// visibility/descriptor policy has already produced this immutable request.
    func publishProfileEndpoints(_ request: ProfileEndpointPublicationRequest) async throws -> CoreAudioEndpointPublicationReceipt {
        let backend = backend
        let legacy = outputDevices.filter { ProfileRoutingDescriptor.isProfileRoutingUID($0.id) && $0.transportType == kAudioDeviceTransportTypeAggregate }
        let migratedDefault = try await Task.detached(priority: .utility) {
            try Self.migrateLegacyEndpoints(legacy, backend: backend)
        }.value
        let receipt = try await publishEndpoints(request.endpoints)
        if let migratedDefault { try await setDefaultOutputAndWait(uid: migratedDefault) }
        return receipt
    }

    nonisolated private static func migrateLegacyEndpoints(_ observed: [AudioDeviceInfo], backend: CoreAudioHALBackend) throws -> String? {
        // Explicit compatibility path. Native endpoint publication never performs
        // a complete scan: legacy aggregate presence is observed by normal snapshots.
        guard !observed.isEmpty else { return nil }
        let previous = backend.readDefaultOutput()
        var migrated: String?
        for stale in observed {
            guard let device = backend.resolve(stale.id),
                  uint32Property(device.objectID, selector: kAudioObjectPropertyClass) == kAudioAggregateDeviceClassID else { continue }
            if previous == device.id {
                guard let bridge = backend.resolve(AudioDeviceInfo.systemAudioBridgeUID) else { throw AudioError.deviceNotFound(AudioDeviceInfo.systemAudioBridgeUID) }
                try backend.setDefaultOutput(bridge); migrated = previous
            }
            let status = AudioHardwareDestroyAggregateDevice(device.objectID)
            guard status == noErr || status == kAudioHardwareBadObjectError else { throw AudioError.osStatus(status) }
        }
        return migrated
    }

    /// Endpoint selection belongs to the caller. Publication invalidates bindings even
    /// if the HAL reuses numeric IDs; consumers must resolve the complete UID set again.
    func publishEndpoints(_ endpoints: [ProfileEndpointState]) async throws -> CoreAudioEndpointPublicationReceipt {
        let backend = backend
        let operation = performanceRecorder?.begin("CoreAudio endpoint publication")
        let waits: [CoreAudioWaitResult]
        let id = UUID(), cancellation = CoreAudioPublicationCancellation()
        let task = Task.detached(priority: .utility) {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try CoreAudioPublicationCancellation.$current.withValue(cancellation) {
                    guard let bridge = backend.resolve(AudioDeviceInfo.systemAudioBridgeUID) else { throw AudioError.deviceNotFound(AudioDeviceInfo.systemAudioBridgeUID) }
                    return try backend.publishEndpoints(bridge, endpoints)
                }
            } onCancel: { cancellation.cancel() }
        }
        publicationTasks[id] = task
        defer { publicationTasks.removeValue(forKey: id) }
        do {
            waits = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch { operation?.finish("failed"); deviceGraphChanged(); throw error }
        for wait in waits { operation?.mark("visibility: " + wait.source.rawValue) }
        operation?.finish("success")
        deviceGraphChanged()
        let receipt = CoreAudioEndpointPublicationReceipt(graphGeneration: deviceGraphGeneration, objectGraphMayHaveChanged: true, visibilityWaits: waits)
        lastPublicationReceipt = receipt
        return receipt
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
        let backend = backend
        return await Task.detached(priority: .utility) {
            guard let device = backend.resolve(uid) else { return false }
            return backend.readRateCapabilities(device).supports(rate)
        }.value
    }

    private func readSampleRateCapabilities(
        device: AudioDeviceInfo
    ) -> SampleRateCapabilities {
        Self.readSampleRateCapabilities(device: device)
    }

    nonisolated static func readSampleRateCapabilities(
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
        let backend = backend
        return await Task.detached(priority: .utility) { backend.resolve(uid).flatMap(backend.readNominalRate) }.value
    }

    nonisolated static func nominalSampleRate(
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
        let backend = backend
        guard let device = await resolveDeviceWithoutBlockingUI(uid: uid) else { throw AudioError.deviceNotFound(uid) }
        let result = try await wait(event: .nominalRate(device.objectID), timeout: .milliseconds(500), condition: {
            guard let fresh = backend.resolve(uid), let value = backend.readNominalRate(fresh) else { return false }
            return abs(value - rate) < 0.5
        }, mutation: {
            guard let fresh = backend.resolve(uid) else { throw AudioError.deviceNotFound(uid) }
            try backend.setNominalRate(fresh, rate)
        })
        guard result.source != .timedOut else {
            throw AudioError.sampleRateDidNotApply(device.name, requested: rate, actual: await nominalSampleRateWithoutBlockingUI(uid: uid))
        }
    }

    /// Synchronous application-termination/maintenance primitive; always resolve freshly.
    func setDefaultOutput(uid: String) throws {
        guard let device = backend.resolve(uid) else { throw AudioError.deviceNotFound(uid) }
        try backend.setDefaultOutput(device)
        defaultObservationRevision &+= 1
        snapshots.publishDefault(backend.readDefaultOutput())
    }

    func setDefaultOutputAndWait(uid: String) async throws {
        let backend = backend
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let result = try await wait(event: .defaultOutput, timeout: .seconds(1), condition: { backend.readDefaultOutput() == uid }, mutation: {
                    guard let fresh = backend.resolve(uid) else { throw AudioError.deviceNotFound(uid) }
                    try backend.setDefaultOutput(fresh)
                })
                guard result.source != .timedOut else { throw AudioError.defaultOutputDidNotApply(uid) }
                await refreshDefaultOutput()
                return
            } catch is CancellationError { throw CancellationError() }
            catch { if attempt == 2 { throw error } }
        }
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

    nonisolated static func enumerateOutputDevices() -> [AudioDeviceInfo] {
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

    nonisolated static func deviceInfo(forUID uid: String) -> AudioDeviceInfo? {
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

    nonisolated static func defaultOutputDevice() -> AudioDeviceID? {
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

    nonisolated static func deviceUID(_ id: AudioDeviceID) -> String? {
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
