import CamiTuneAudio
import CamiTuneDomain
import Foundation

/// HAL effects used only by the bridge implementation. Alternate capture
/// backends do not implement these device, volume-lease or transport operations.
@MainActor
struct SystemAudioBridgeCaptureEffects {
    typealias MasterControl = @Sendable (Float, Bool) -> Void
    var currentVolumeLease: () -> VolumeHandoffLease? = { nil }
    var bindingGeneration: () -> UInt64? = { nil }
    var publishedProfileUIDs: () -> Set<String>? = { nil }
    var rebindVolume: (VolumeHandoffLease, CoreAudioRuntimeBinding) async throws -> Void = { _, _ in }
    var volumeMasterControl: () -> MasterControl? = { nil }
    var updateTransportControl: (UInt32, @escaping MasterControl) -> Void = { _, _ in }
    var holdAudibility: (VolumeHandoffLease?) -> Void = { _ in }
    var permitAudibility: (VolumeHandoffLease?) -> Void = { _ in }
    var cancelReadiness: () -> Void = {}
    var statistics: () -> AudioCaptureStatistics = { .init() }
    var runtimeError: () -> String? = { nil }
    var controlSummary: () -> String = { "No volume control session" }
    var resolveBridge: () async -> AudioDeviceInfo?
    var presentationSupported: () async -> Bool
    var bridgeLayout: () -> LPCMChannelLayout?
    var supportsRate: (String, Double) async -> Bool
    var defaultOutput: () -> String?
    var freshDefaultOutput: () async -> String?
    var cachedDevice: (String) -> AudioDeviceInfo?
    var hasSnapshot: () -> Bool
    var resolveBinding: (String, String) async throws -> CoreAudioRuntimeBinding
    var synchronizeRouting: ([DeviceProfile], UUID?, Set<UUID>, [UUID: ProfileRoutingDescriptor]) async throws -> Void
    var waitForRouting: (UUID) async -> AudioDeviceInfo?
    var hideBridge: () async throws -> Void
    var setRate: (String, Double) async throws -> Void
    var setDefaultOutput: (String) async throws -> Void
    var startVolume: (AudioDeviceInfo, AudioDeviceInfo, UUID, RuntimeOwnershipID) async throws -> MasterControl
    var volumeMode: () -> SystemVolumeMode?
    var startTransport: (AudioDeviceInfo, AudioDeviceInfo, Double, AudioCaptureDelivery, @escaping MasterControl) async throws -> Void
    var prepareIncoming: () async throws -> Void
    var beginOutgoing: () async -> Void
    var stopTransport: () async -> Void
    var stopVolume: () async -> Void
    var stopTransportSynchronously: () -> Void
    var stopVolumeSynchronously: () -> Void
    var hideBridgeSynchronously: () throws -> Void
    var removeProfileDevices: () -> Void
    var sleep: (Duration) async throws -> Void
}

@MainActor
final class SystemAudioBridgeCaptureBackend: AudioCaptureBackend {
    var effects: SystemAudioBridgeCaptureEffects
    init(effects: SystemAudioBridgeCaptureEffects) { self.effects = effects }
    let name = "System Audio Bridge"
    var statistics: AudioCaptureStatistics { effects.statistics() }
    var runtimeError: String? { effects.runtimeError() }
    var controlSummary: String { effects.controlSummary() }

    func validateAvailability() async throws {
        guard await effects.presentationSupported() else { throw AppState.AppError.outdatedRoutingDriver }
        guard effects.bridgeLayout() != nil else { throw AppState.AppError.unsupportedRoutingLayout }
    }
    func validateSource(sampleRate: Int) async throws {
        guard let bridge = await effects.resolveBridge() else { throw AppState.AppError.missingRoutingDriver }
        guard await effects.supportsRate(bridge.id, Double(sampleRate)) else {
            throw AppState.AppError.unsupportedSampleRate(sampleRate, bridge.name)
        }
    }
    func validatePlan(_ plan: AudioRuntimePlan) throws { _ = try plan.profileRoutingDescriptor.formatPayload() }
    func makeSession(plan: AudioRuntimePlan, ownershipID: RuntimeOwnershipID,
                     delivery: AudioCaptureDelivery, isOwned: @escaping () -> Bool) -> any AudioCaptureSession {
        SystemAudioBridgeCaptureSession(backend: self, plan: plan, ownershipID: ownershipID,
            delivery: delivery, isOwned: isOwned)
    }
    func profileID(forSelection uid: String) -> UUID? { ProfileRoutingDescriptor.profileID(from: uid) }
    func isCaptureDevice(_ uid: String) -> Bool {
        uid == AudioDeviceInfo.systemAudioBridgeUID || ProfileRoutingDescriptor.isProfileRoutingUID(uid)
    }
    func needsProfileSynchronization(_ profiles: [DeviceProfile], active: UUID?) -> Bool {
        guard effects.hasSnapshot(), let published = effects.publishedProfileUIDs() else { return false }
        let connected = Set(profiles.lazy.filter { self.effects.cachedDevice($0.outputDeviceUID)?.isRoutingDevice == false }.map(\.outputDeviceUID))
        let visible = ProfileRoutingDescriptor.visibleProfileIDs(profiles: profiles, activeProfileID: active,
            defaultOutputUID: effects.defaultOutput(), connectedOutputUIDs: connected)
        return published != Set(visible.map(ProfileRoutingDescriptor.uid))
    }
    func synchronizeProfiles(_ profiles: [DeviceProfile], active: UUID?, visible: Set<UUID>,
                             prepared: [UUID: AudioRuntimePlan]) async throws {
        try await effects.synchronizeRouting(profiles, active, visible, prepared.mapValues(\.profileRoutingDescriptor))
    }
    func profileRouteChanged(from profile: DeviceProfile, to plan: AudioRuntimePlan) -> Bool {
        ProfileRoutingDescriptor.descriptors(for: [profile])[profile.id] != plan.profileRoutingDescriptor
    }
    func updatePresentation() async throws { try await effects.hideBridge() }
    func cancelPendingOperations() { effects.cancelReadiness() }
    func shutdownSynchronously() { effects.removeProfileDevices() }
}

@MainActor
private final class SystemAudioBridgeCaptureSession: AudioCaptureSession {
    private let backend: SystemAudioBridgeCaptureBackend
    private let plan: AudioRuntimePlan
    private let ownershipID: RuntimeOwnershipID
    private let delivery: AudioCaptureDelivery
    private let isOwned: () -> Bool
    private var effects: SystemAudioBridgeCaptureEffects { backend.effects }
    private var binding: CoreAudioRuntimeBinding?
    private var volumeLease: VolumeHandoffLease?
    private var masterControl: SystemAudioBridgeCaptureEffects.MasterControl?
    private var ownsControl = false
    private var ownsTransport = false
    private var drainingProducer = false
    private(set) var redirectedDefaultOutput = false
    private(set) var volumeMode: SystemVolumeMode?
    private(set) var bindingAction = "No runtime binding"
    var selectionUID: String { plan.profileRoutingDescriptor.uid }
    var volumeSnapshot: SystemVolumeControlSession.Snapshot? { volumeLease?.controlSession.snapshot() }
    var audibilityHeld: Bool { volumeLease?.controlSession.snapshot().audibility == .held }
    var needsBindingRefresh: Bool {
        effects.bindingGeneration().map { binding?.graphGeneration != $0 } ?? false
    }
    var bindingSummary: String {
        guard let binding else { return "No runtime CoreAudio binding" }
        return "Binding action: \(bindingAction)\nBinding generation: \(binding.graphGeneration)\nBridge: \(binding.bridge.name)\nRouting: \(binding.routing.name)\nPhysical: \(binding.physical.name)"
    }

    init(backend: SystemAudioBridgeCaptureBackend, plan: AudioRuntimePlan, ownershipID: RuntimeOwnershipID,
         delivery: AudioCaptureDelivery, isOwned: @escaping () -> Bool) {
        self.backend = backend; self.plan = plan; self.ownershipID = ownershipID
        self.delivery = delivery; self.isOwned = isOwned
    }
    private func checkOwnership() throws { guard isOwned() else { throw CancellationError() } }

    func prepareRoute(profiles: [DeviceProfile], validateHardware: () async throws -> Void,
                      checkCurrent: () throws -> Void, operation: PerformanceOperation?) async throws {
        try await backend.synchronizeProfiles(profiles, active: nil, visible: [plan.revision.profileID],
            prepared: [plan.revision.profileID: plan]); try checkCurrent()
        operation?.mark("routing endpoints synchronized")
        let routing = await effects.waitForRouting(plan.revision.profileID); try checkCurrent()
        guard let routing else { throw AppState.AppError.profileRoutingDeviceMissing(plan.intent.name) }
        try await validateHardware(); try checkCurrent()
        try await effects.hideBridge(); try checkCurrent()
        let binding = try await effects.resolveBinding(routing.id, plan.hardwareEvidence.output.uid); try checkCurrent()
        self.binding = binding
        operation?.mark("runtime binding resolved")
        operation?.mark("routing endpoint available")
        try await effects.setRate(binding.physical.id, Double(plan.sourceFormat.sampleRate)); try checkCurrent()
        try await effects.setRate(binding.bridge.id, Double(plan.sourceFormat.sampleRate)); try checkCurrent()
        operation?.mark("sample rates configured")
    }
    func startControl() async throws {
        guard let binding else { throw CancellationError() }
        ownsControl = true
        defer {
            ownsControl = true
            if !isOwned() { stopControlSynchronously() }
        }
        masterControl = try await effects.startVolume(binding.routing, binding.physical, plan.revision.profileID, ownershipID)
        volumeLease = effects.currentVolumeLease()
        volumeMode = effects.volumeMode()
    }

    func refreshBinding(permit: () -> Bool, operation: PerformanceOperation?) async throws {
        guard isOwned() else { return }
        let fresh = try await effects.resolveBinding(selectionUID, plan.hardwareEvidence.output.uid)
        try checkOwnership()
        let previous = binding
        let changed = previous?.hasSameObjects(as: fresh) != true
        if changed {
            holdAudibility()
            let restart = ownsTransport && previous?.bridge.objectID != fresh.bridge.objectID
            if restart {
                bindingAction = "Transport rebound"
                await effects.stopTransport(); try checkOwnership()
            } else if let masterControl { effects.updateTransportControl(0, masterControl) }
            if let volumeLease { try await effects.rebindVolume(volumeLease, fresh) }
            try checkOwnership()
            if let master = effects.volumeMasterControl() { masterControl = master }
            guard let masterControl else { throw CancellationError() }
            if restart {
                try await startTransport(binding: fresh, masterControl: masterControl)
            } else {
                bindingAction = "Volume/control binding refreshed"
                effects.updateTransportControl(fresh.routing.objectID, masterControl)
            }
            operation?.mark(bindingAction)
        } else { bindingAction = "Bindings unchanged" }
        try checkOwnership()
        binding = fresh
        let needsReadiness = changed || audibilityHeld
        if needsReadiness { try await effects.prepareIncoming(); try checkOwnership() }
        let selected = await effects.freshDefaultOutput(); try checkOwnership()
        guard selected == selectionUID else { holdAudibility(); return }
        if permit(), needsReadiness { permitAudibility() }
    }

    func connect(checkCurrent: () throws -> Void, operation: PerformanceOperation?) async throws {
        guard let initial = binding else { throw CancellationError() }
        var lastError: Error?
        var transportFailures = 0, producerRetries = 0
        while true {
            if drainingProducer {
                let selected = await effects.freshDefaultOutput(); try checkCurrent()
                guard selected == initial.physical.id else { throw CancellationError() }
            }
            try await refreshBinding(permit: { false }, operation: operation); try checkCurrent()
            guard let binding, let masterControl else { throw CancellationError() }
            do {
                try await startTransport(binding: binding, masterControl: masterControl)
                try checkCurrent()
                return
            } catch {
                try checkCurrent(); lastError = error
                if (error as? SystemAudioBridgeTransport.TransportError)?.producerIsActive == true {
                    guard producerRetries < 30 else { break }
                    if !drainingProducer {
                        let selected = await effects.freshDefaultOutput(); try checkCurrent()
                        guard selected == initial.routing.id || selected == initial.bridge.id || selected == initial.physical.id else { break }
                        if selected != initial.physical.id {
                            holdAudibility()
                            try await effects.prepareIncoming(); try checkCurrent()
                            redirectedDefaultOutput = true
                            try await effects.setDefaultOutput(initial.physical.id); try checkCurrent()
                        }
                        drainingProducer = true
                        operation?.mark("waiting for bridge clients to stop")
                    }
                    producerRetries += 1
                } else {
                    transportFailures += 1
                    if transportFailures >= 3 { break }
                }
                try await effects.sleep(.milliseconds(100)); try checkCurrent()
            }
        }
        throw lastError ?? AppState.AppError.missingRoutingDriver
    }
    private func startTransport(binding: CoreAudioRuntimeBinding, masterControl: @escaping SystemAudioBridgeCaptureEffects.MasterControl) async throws {
        ownsTransport = true
        defer {
            ownsTransport = true
            if !isOwned() { stopCaptureSynchronously() }
        }
        try await effects.startTransport(binding.bridge, binding.routing, Double(plan.sourceFormat.sampleRate), delivery, masterControl)
    }
    func prepareIncoming() async throws { try await effects.prepareIncoming() }
    func selectRoute(checkCurrent: () throws -> Void) async throws {
        if drainingProducer {
            let selected = await effects.freshDefaultOutput(); try checkCurrent()
            guard selected == plan.hardwareEvidence.output.uid else { throw CancellationError() }
        }
        if effects.defaultOutput() != selectionUID {
            redirectedDefaultOutput = true
            try await effects.setDefaultOutput(selectionUID); try checkCurrent()
        }
    }
    func holdAudibility() { effects.holdAudibility(volumeLease) }
    func permitAudibility() { effects.permitAudibility(volumeLease) }
    func beginOutgoing() async { if ownsControl { await effects.beginOutgoing() } }
    func stopCapture() async {
        guard ownsTransport else { return }
        await effects.stopTransport(); ownsTransport = false
    }
    func stopControl() async {
        guard ownsControl else { return }
        await effects.stopVolume(); ownsControl = false
        volumeLease = nil; masterControl = nil
    }
    func stopCaptureSynchronously() {
        guard ownsTransport else { return }
        ownsTransport = false; effects.stopTransportSynchronously()
    }
    func stopControlSynchronously() {
        guard ownsControl else { return }
        ownsControl = false; effects.stopVolumeSynchronously()
        volumeLease = nil; masterControl = nil
    }
    func updatePresentationSynchronously() { try? effects.hideBridgeSynchronously() }
}

extension SystemAudioBridgeCaptureBackend {
    convenience init(coreAudio: CoreAudioService, performanceRecorder: RuntimePerformanceRecorder,
                     onVolume: @escaping (UUID, RuntimeOwnershipID, Double) -> Void,
                     onMasterGain: @escaping SystemAudioBridgeCaptureEffects.MasterControl,
                     onMirrorFailure: @escaping (RuntimeOwnershipID) -> Void) {
        let transport = SystemAudioBridgeTransport()
        let volume = VolumeHandoffService()
        volume.performanceRecorder = performanceRecorder
        self.init(effects: .init(
            currentVolumeLease: { volume.currentLease },
            bindingGeneration: { coreAudio.deviceGraphGeneration },
            publishedProfileUIDs: { Set(coreAudio.outputDevices.lazy.map(\.id).filter(ProfileRoutingDescriptor.isProfileRoutingUID)) },
            rebindVolume: { try await volume.rebind($0, binding: $1) },
            volumeMasterControl: { volume.currentLease?.controlSession.driverConsumer() },
            updateTransportControl: { transport.updateControlDeviceObjectID($0, consumer: $1) },
            holdAudibility: { volume.holdAudibility($0) },
            permitAudibility: { volume.permitAudibility($0) },
            cancelReadiness: { coreAudio.cancelReadiness() },
            statistics: { transport.statistics },
            runtimeError: { transport.runtimeError },
            controlSummary: { volume.diagnosticSummary },
            resolveBridge: { await coreAudio.resolveSystemAudioBridgeWithoutBlockingUI() },
            presentationSupported: { await coreAudio.systemAudioBridgePresentationIsSupportedWithoutBlockingUI() },
            bridgeLayout: { coreAudio.installedSystemAudioBridgeChannelLayout },
            supportsRate: { await coreAudio.supportsSampleRateWithoutBlockingUI(uid: $0, rate: $1) },
            defaultOutput: { coreAudio.defaultOutputUID },
            freshDefaultOutput: { await coreAudio.readDefaultOutputWithoutBlockingUI() },
            cachedDevice: { coreAudio.cachedDevice(uid: $0) },
            hasSnapshot: { coreAudio.hasCompletedInitialRefresh },
            resolveBinding: { try await coreAudio.resolveRuntimeBinding(routingUID: $0, physicalUID: $1) },
            synchronizeRouting: { profiles, active, visible, descriptors in
                let request = try ProfileEndpointPublicationRequest(profiles: profiles, activeProfileID: active,
                    defaultOutputUID: coreAudio.defaultOutputUID,
                    connectedOutputUIDs: Set(coreAudio.physicalOutputDevices.map(\.id)),
                    additionallyVisible: visible, preparedDescriptors: descriptors)
                _ = try await coreAudio.publishProfileEndpoints(request)
            },
            waitForRouting: { await coreAudio.waitForProfileRoutingDevice(profileID: $0) },
            hideBridge: { try await coreAudio.setSystemAudioBridgePresentationWithoutBlockingUI(name: AudioDeviceInfo.systemAudioBridgeName, visible: false) },
            setRate: { try await coreAudio.setSampleRate(uid: $0, rate: $1) },
            setDefaultOutput: { try await coreAudio.setDefaultOutputAndWait(uid: $0) },
            startVolume: { routing, output, profileID, ownershipID in
                let lease = try await volume.acquire(ownershipID: ownershipID, routingDevice: routing,
                    physicalUID: output.id, coreAudio: coreAudio,
                    onVolume: { onVolume(profileID, ownershipID, $0) }, onMasterGain: onMasterGain,
                    onMirrorFailure: { onMirrorFailure(ownershipID) })
                return lease.controlSession.driverConsumer()
            },
            volumeMode: { volume.mode },
            startTransport: { bridge, routing, rate, delivery, control in
                try await transport.start(deviceObjectID: bridge.objectID, controlDeviceObjectID: routing.objectID,
                    expectedSampleRate: rate, delivery: delivery, masterControlConsumer: control)
            },
            prepareIncoming: { try await volume.prepareIncoming() },
            beginOutgoing: { await volume.beginOutgoing() },
            stopTransport: { await transport.stopWithoutBlockingUI() },
            stopVolume: { await volume.stopWithoutBlockingUI() },
            stopTransportSynchronously: { transport.stop() },
            stopVolumeSynchronously: { volume.stop() },
            hideBridgeSynchronously: { try coreAudio.setSystemAudioBridgePresentation(name: AudioDeviceInfo.systemAudioBridgeName, visible: false) },
            removeProfileDevices: { coreAudio.destroyAllProfileRoutingDevices() },
            sleep: { try await Task.sleep(for: $0) }))
    }
}
