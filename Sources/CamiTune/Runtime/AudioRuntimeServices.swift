import CamiTuneDomain
import Foundation

/// External effects only. Transition state and lifecycle ordering belong to the coordinator.
@MainActor
struct AudioRuntimeServices {
    var startDirectOutput: (AudioRuntimePlan) async throws -> Void = { _ in
        throw ProfileSettingsError.runtime("Direct plug-in output is unavailable in this runtime.")
    }
    var directOutputNeedsRecovery: () -> Bool = { false }
    var preparePluginRack: (AudioRuntimePlan) async throws -> Void = { _ in }
    var commitPluginRack: (AudioRuntimePlan) -> Void = { _ in }
    /// Optional pure configuration injection for controlled developer comparisons.
    var deliveryConfiguration: ((DeviceProfile) -> PCMDeliveryConfiguration)? = nil
    var freshDefaultOutput: () async -> String?
    var physicalOutputs: () -> [AudioDeviceInfo]? = { nil }
    var automaticBufferSize: (DeviceProfile) -> Int = { AutomaticAudioBufferPolicy.startingFrames(sampleRate: $0.sampleRate) }
    var synchronous: SynchronousRuntimeServices
    var refreshDependencies: () async -> Void
    var prepareAssets: (DeviceProfile) async throws -> PreparedRuntimeAssets
    var captureBackend: any AudioCaptureBackend
    var processingBackend: any AudioProcessingBackend
    var resolveOutput: (String) async -> AudioDeviceInfo?
    var probeTopology: (AudioDeviceInfo) async throws -> SpeakerTopology
    var outputChannelCount: (AudioDeviceInfo) async throws -> Int
    var supportsRate: (String, Double) async -> Bool
    var defaultOutput: () -> String?
    var cachedDevice: (String) -> AudioDeviceInfo?
    var hasSnapshot: () -> Bool
    var nominalRate: (String) async -> Double?
    var setDefaultOutput: (String) async throws -> Void
    var startObservations: (AudioRuntimeSession) -> Void
    var startPCM: (AudioRuntimePlan, AudioRuntimeSession) async throws -> Void
    var applyRenderConfiguration: (RenderConfiguration) -> Void
    var applyPCMDeliveryConfiguration: (PCMDeliveryConfiguration) -> Void
    var startSpectrum: (AudioRuntimeSession) async -> Void
    var stopObservations: () -> Void
    var stopPCM: () async -> Void
    var closeEngineInput: () async -> Void
    var stopSpectrum: () async -> Void
    var stopEngine: () async -> Void
    var deliveryError: () -> String?
    var notifyActivation: (_ profileName: String) -> Void
    var notifyDeactivation: (_ profileName: String) -> Void
    var sleep: (Duration) async throws -> Void
    var transitionFinished: (Bool) -> Void
}

/// Synchronous service primitives for application termination. Ordering belongs
/// to the coordinator, just as it does for asynchronous retirement.
@MainActor
struct SynchronousRuntimeServices {
    let readDefaultOutput: () -> String?
    let stopPCM: () -> Void
    let closeEngineInput: () -> Void
    let stopSpectrum: () -> Void
    let stopEngine: () -> Void
    let setDefaultOutput: (String) throws -> Void
}
