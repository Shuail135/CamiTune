import CamiTuneDomain
import Foundation

/// External effects only. This value owns no transition state or lifecycle policy.
/// Every field is required so simulated compositions cannot silently fall back to HAL.
@MainActor
struct AudioRuntimeServices {
    /// Optional pure configuration injection for controlled developer comparisons.
    var deliveryConfiguration: ((DeviceProfile) -> PCMDeliveryConfiguration)? = nil
    var currentVolumeLease: () -> VolumeHandoffLease? = { nil }
    var freshDefaultOutput: (() async -> String?)?
    var bindingGeneration: () -> UInt64? = { nil }
    var cancelReadiness: () -> Void = {}
    var resolveBinding: ((String, String) async throws -> CoreAudioRuntimeBinding)?
    var rebindVolume: (VolumeHandoffLease, CoreAudioRuntimeBinding) async throws -> Void = { _, _ in }
    var volumeMasterControl: () -> MasterControl? = { nil }
    var updateTransportControl: (UInt32, @escaping MasterControl) -> Void = { _, _ in }
    var synchronous: SynchronousRuntimeServices
    var holdAudibility: (VolumeHandoffLease?) -> Void = { _ in }
    var permitAudibility: (VolumeHandoffLease?) -> Void = { _ in }
    typealias MasterControl = @Sendable (Float, Bool) -> Void
    var refreshDependencies: () async -> Void
    var prepareAssets: (DeviceProfile) async throws -> PreparedRuntimeAssets
    var engineAvailable: () -> Bool
    var resolveBridge: () async -> AudioDeviceInfo?
    var freshBridge: () async -> AudioDeviceInfo?
    var presentationSupported: () async -> Bool
    var bridgeLayout: () -> LPCMChannelLayout?
    var resolveOutput: (String) async -> AudioDeviceInfo?
    var probeTopology: (AudioDeviceInfo) async throws -> SpeakerTopology
    var outputChannelCount: (AudioDeviceInfo) async throws -> Int
    var supportsRate: (String, Double) async -> Bool
    var defaultOutput: () -> String?
    var cachedDevice: (String) -> AudioDeviceInfo?
    var hasSnapshot: () -> Bool
    var nominalRate: (String) async -> Double?
    var synchronizeRouting: ([DeviceProfile], UUID?, Set<UUID>, [UUID: ProfileRoutingDescriptor]) async throws -> Void
    var waitForRouting: (UUID) async -> AudioDeviceInfo?
    var hideBridge: () async throws -> Void
    var setRate: (String, Double) async throws -> Void
    var setDefaultOutput: (String) async throws -> Void
    var startEngine: () async throws -> Void
    var resetEngine: () -> Void
    var playbackDevices: () async throws -> [String]
    var graphUpdateDescription: () -> String? = { nil }
    var applyGraph: (ProcessingGraph) async throws -> Void
    var startObservations: (AudioRuntimeSession) -> Void
    var startVolume: (AudioDeviceInfo, AudioDeviceInfo, UUID) async throws -> MasterControl
    var volumeMode: () -> SystemVolumeMode?
    var startPCM: (AudioRuntimePlan, AudioRuntimeSession) async throws -> Void
    var applyRenderConfiguration: (RenderConfiguration) -> Void
    var applyPCMDeliveryConfiguration: (PCMDeliveryConfiguration) -> Void
    var startTransport: (AudioDeviceInfo, AudioDeviceInfo, Double, @escaping MasterControl) async throws -> Void
    var prepareIncoming: () async throws -> Void
    var startSpectrum: (AudioRuntimeSession) async -> Void
    var beginOutgoing: () async -> Void
    var stopObservations: () -> Void
    var stopTransport: () async -> Void
    var stopPCM: () async -> Void
    var closeEngineInput: () async -> Void
    var stopSpectrum: () async -> Void
    var stopEngine: () async -> Void
    var stopVolume: () async -> Void
    var transportError: () -> String?
    var notifyActivation: () -> Void
    var notifyDeactivation: () -> Void
    var sleep: (Duration) async throws -> Void
    var transitionFinished: (Bool) -> Void
}

/// Synchronous service primitives for application termination. Ordering belongs
/// to the coordinator, just as it does for asynchronous retirement.
@MainActor
struct SynchronousRuntimeServices {
    let stopTransport: () -> Void
    let stopPCM: () -> Void
    let closeEngineInput: () -> Void
    let stopSpectrum: () -> Void
    let stopEngine: () -> Void
    let stopVolume: () -> Void
    let setDefaultOutput: (String) throws -> Void
    let hideBridge: () throws -> Void
    let removeProfileDevices: () -> Void
}
