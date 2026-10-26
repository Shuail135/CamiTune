import CamiTuneAudio
import CamiTuneDomain
import Foundation

struct AudioCaptureStatistics: Sendable {
    var packetCount: UInt64 = 0
    var latestPacketFrames: UInt32 = 0
    var minimumPacketFrames: UInt32 = 0
    var maximumPacketFrames: UInt32 = 0
    var bufferedFrames: UInt64 = 0
    var droppedFrames: UInt64 = 0
    var consumerOverrunCount: UInt64 = 0
    var starvationCount: UInt64 = 0
    var latestChannels: UInt32 = 0
    var latestChannelLayoutTag: UInt32 = 0
    var latestSampleRate: Double = 0
    var clientRegistryOverflowCount: UInt64 = 0
    var clientUseCountSaturationCount: UInt64 = 0
    var malformedPacketCount: UInt64 = 0
    var masterControlGeneration: UInt64 = 0
    var masterLinearGain: Float = 1
    var masterMuted = false
    var ringCapacityFrames: UInt32 = 0
    var rateAdjustmentPPM: Double = 0
    var rateMatchBufferedFrames: UInt64 = 0
    var completion = ProducerCompletionStatistics()
}

@MainActor
protocol AudioCaptureBackend: AnyObject {
    var name: String { get }
    var statistics: AudioCaptureStatistics { get }
    var runtimeError: String? { get }
    var controlSummary: String { get }
    func validateAvailability() async throws
    func validateSource(sampleRate: Int) async throws
    func validatePlan(_ plan: AudioRuntimePlan) throws
    func makeSession(plan: AudioRuntimePlan, ownershipID: RuntimeOwnershipID,
                     delivery: AudioCaptureDelivery, isOwned: @escaping () -> Bool) -> any AudioCaptureSession
    func profileID(forSelection uid: String) -> UUID?
    func isCaptureDevice(_ uid: String) -> Bool
    func needsProfileSynchronization(_ profiles: [DeviceProfile], active: UUID?) -> Bool
    func synchronizeProfiles(_ profiles: [DeviceProfile], active: UUID?, visible: Set<UUID>,
                             prepared: [UUID: AudioRuntimePlan]) async throws
    func profileRouteChanged(from profile: DeviceProfile, to plan: AudioRuntimePlan) -> Bool
    func updatePresentation() async throws
    func cancelPendingOperations()
    func shutdownSynchronously()
}

/// One capture generation. It owns its routing/control resources independently
/// of the processing engine and retains them until both async and late cleanup finish.
@MainActor
protocol AudioCaptureSession: AnyObject {
    var selectionUID: String { get }
    var redirectedDefaultOutput: Bool { get }
    var volumeMode: SystemVolumeMode? { get }
    var volumeSnapshot: SystemVolumeControlSession.Snapshot? { get }
    var audibilityHeld: Bool { get }
    var needsBindingRefresh: Bool { get }
    var bindingAction: String { get }
    var bindingSummary: String { get }
    func prepareRoute(profiles: [DeviceProfile], validateHardware: () async throws -> Void,
                      checkCurrent: () throws -> Void, operation: PerformanceOperation?) async throws
    func startControl() async throws
    func connect(checkCurrent: () throws -> Void, operation: PerformanceOperation?) async throws
    func prepareIncoming() async throws
    func selectRoute(checkCurrent: () throws -> Void) async throws
    func refreshBinding(permit: () -> Bool, operation: PerformanceOperation?) async throws
    func holdAudibility()
    func permitAudibility()
    func beginOutgoing() async
    func stopCapture() async
    func stopControl() async
    func stopCaptureSynchronously()
    func stopControlSynchronously()
    func updatePresentationSynchronously()
}
