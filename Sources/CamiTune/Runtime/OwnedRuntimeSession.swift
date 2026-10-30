import CamiTuneDomain
import Foundation

struct RuntimeResourceOwnership: OptionSet {
    let rawValue: UInt16
    static let engine = Self(rawValue: 1 << 0)
    static let observations = Self(rawValue: 1 << 1)
    static let pcm = Self(rawValue: 1 << 3)
    static let spectrum = Self(rawValue: 1 << 5)
}
struct OutputRestorationContext {
    var previousDefaultUID: String?
    let physicalOutputUID: String
}

/// Module-internal implementation types; instances never leave the coordinator.
/// A resource flag claims cleanup responsibility before a fallible acquisition,
/// including a service that throws after partially acquiring its resource.
@MainActor
final class OwnedRuntimeSession {
    let ownershipID: RuntimeOwnershipID
    let publicSession: AudioRuntimeSession
    var appliedPlan: AudioRuntimePlan { didSet { retainAssets() } }
    var acknowledgedPlan: AudioRuntimePlan? { didSet { retainAssets() } }
    private let retainedAssets: ProfileAssetLease
    private func retainAssets() {
        retainedAssets.update(.init(profiles: [appliedPlan.intent] + (acknowledgedPlan.map { [$0.intent] } ?? [])))
    }
    var restoration: OutputRestorationContext
    var resources: RuntimeResourceOwnership = []
    let capture: any AudioCaptureSession
    init(id: RuntimeOwnershipID, plan: AudioRuntimePlan, previousDefaultUID: String?, capture: any AudioCaptureSession) {
        self.capture = capture
        ownershipID = id; publicSession = AudioRuntimeSession(profileID: plan.revision.profileID)
        appliedPlan = plan
        retainedAssets = ProfileAssetStorage.shared.retain(.init(profiles: [plan.intent]))
        restoration = .init(previousDefaultUID: previousDefaultUID,
            physicalOutputUID: plan.hardwareEvidence.output.uid)
    }
}
@MainActor
final class RuntimeSettingsTransaction {
    let id: RuntimeTransactionID
    let generation: RuntimeIntentGeneration
    let original: DeviceProfile
    let intent: DeviceProfile
    let baseOwnershipID: RuntimeOwnershipID?
    let oldPlan: AudioRuntimePlan?
    private let retainedAssets: ProfileAssetLease
    let previousDefaultUID: String?
    let wasActive: Bool
    let operation: PerformanceOperation?
    let validatePersistence: () throws -> Void
    var candidate: AudioRuntimePlan?
    var delta: RuntimePlanDelta?
    var graphAttempted = false
    var rendererApplied = false
    var endpointAttempted = false
    enum Restart { case none, pcm, pipeline }
    var restart: Restart = .none
    var receipt: RuntimeApplyReceipt?
    var applyContinuation: CheckedContinuation<RuntimeApplyReceipt, Error>?
    var rollbackContinuation: CheckedContinuation<RuntimeCommandResult, Error>?
    var rollbackRequested = false
    init(id: RuntimeTransactionID, generation: RuntimeIntentGeneration, original: DeviceProfile,
         intent: DeviceProfile, owner: OwnedRuntimeSession?, operation: PerformanceOperation?,
         validatePersistence: @escaping () throws -> Void) {
        self.id = id; self.generation = generation; self.original = original; self.intent = intent
        baseOwnershipID = owner?.ownershipID; wasActive = owner?.publicSession.profileID == original.id
        oldPlan = wasActive ? owner?.appliedPlan : nil
        retainedAssets = ProfileAssetStorage.shared.retain(.init(profiles:
            [original, intent] + (oldPlan.map { [$0.intent] } ?? [])))
        previousDefaultUID = owner?.restoration.previousDefaultUID
        self.operation = operation; self.validatePersistence = validatePersistence
    }
}

/// Disk success/failure never grants ownership of a newer runtime.
enum RuntimePersistenceResolution: Sendable, Equatable { case finalizedCurrentRuntime, superseded }
