import Foundation

struct RuntimeResourceOwnership: OptionSet {
    let rawValue: UInt16
    static let engine = Self(rawValue: 1 << 0)
    static let observations = Self(rawValue: 1 << 1)
    static let volume = Self(rawValue: 1 << 2)
    static let pcm = Self(rawValue: 1 << 3)
    static let transport = Self(rawValue: 1 << 4)
    static let spectrum = Self(rawValue: 1 << 5)
}
struct OutputRestorationContext {
    var previousDefaultUID: String?
    let physicalOutputUID: String
    let routingUID: String
    var defaultOutputWasRedirected = false
}

/// Module-internal implementation types; instances never leave the coordinator.
/// A resource flag claims cleanup responsibility before a fallible acquisition,
/// including a service that throws after partially acquiring its resource.
@MainActor
final class OwnedRuntimeSession {
    let ownershipID: RuntimeOwnershipID
    let publicSession: AudioRuntimeSession
    var appliedPlan: AudioRuntimePlan
    var acknowledgedPlan: AudioRuntimePlan?
    var restoration: OutputRestorationContext
    var resources: RuntimeResourceOwnership = []
    var volumeMode: SystemVolumeMode?
    var volumeSession: SystemVolumeControlSession?
    var masterControl: AudioRuntimeServices.MasterControl?
    init(id: RuntimeOwnershipID, plan: AudioRuntimePlan, previousDefaultUID: String?) {
        ownershipID = id; publicSession = AudioRuntimeSession(profileID: plan.revision.profileID)
        appliedPlan = plan
        restoration = .init(previousDefaultUID: previousDefaultUID,
            physicalOutputUID: plan.hardwareEvidence.output.uid, routingUID: plan.profileRoutingDescriptor.uid)
    }
}
@MainActor
final class ProvisionalRuntimeSession {
    let generation: RuntimeIntentGeneration
    let owner: OwnedRuntimeSession
    init(generation: RuntimeIntentGeneration, owner: OwnedRuntimeSession) {
        self.generation = generation; self.owner = owner
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
    let previousDefaultUID: String?
    let wasActive: Bool
    let operation: PerformanceOperation?
    let validatePersistence: () throws -> Void
    var candidate: AudioRuntimePlan?
    var delta: RuntimePlanDelta?
    var graphAttempted = false
    var rendererApplied = false
    var endpointAttempted = false
    var restarted = false
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
        previousDefaultUID = owner?.restoration.previousDefaultUID
        self.operation = operation; self.validatePersistence = validatePersistence
    }
}
