import Foundation

struct RuntimeIntentGeneration: Hashable, Comparable, Sendable {
    let rawValue: UInt64
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
struct RuntimeOwnershipID: Hashable, Sendable { let rawValue: UInt64 }
struct RuntimeTransactionID: Hashable, Sendable { let rawValue: UInt64 }
struct RuntimeTransitionID: Hashable, Sendable { let rawValue: UInt64 }

enum AudioRuntimeStatusKind: String, Equatable, Sendable {
    case inactive, preparing, activating, active, applying, stopping, recovering
}
enum RuntimeStopReason: String, Sendable {
    case manual, externalRouteChange, physicalOutputMissing, sampleRateMismatch
    case transportFailure, profileDisabled, dependencyRepair, applicationTermination
}
enum RuntimeIntentSource: Sendable {
    case manualActivation, automaticRouting, liveEdit, settingsTransaction(RuntimeTransactionID), recovery
    case stop(RuntimeStopReason)
    var description: String {
        switch self {
        case .manualActivation: return "Manual activation"
        case .automaticRouting: return "Automatic routing"
        case .liveEdit: return "Live edit"
        case .settingsTransaction(let id): return "Settings transaction \(id.rawValue)"
        case .recovery: return "Recovery"
        case .stop(let reason): return "Stop: \(reason.rawValue)"
        }
    }
}
struct DesiredRuntimeIntent: Sendable {
    enum Target: Sendable { case inactive(restoreOutput: Bool), active(DeviceProfile) }
    let generation: RuntimeIntentGeneration
    let target: Target
    let source: RuntimeIntentSource
    let preparedPlan: AudioRuntimePlan?
    let reportErrors: Bool
    let reason: String
    let parentOperation: PerformanceOperationID?
    var profileID: UUID? { if case .active(let profile) = target { return profile.id }; return nil }
}
struct RuntimeTransitionSnapshot: Equatable, Sendable {
    let id: RuntimeTransitionID
    let generation: RuntimeIntentGeneration
    let phase: String
}
struct AudioRuntimeStateSnapshot: Equatable, Sendable {
    let status: AudioRuntimeStatusKind
    let session: AudioRuntimeSession?
    let acknowledgedPlanRevision: RuntimeIntentRevision?
    let volumeMode: SystemVolumeMode?
    let transition: RuntimeTransitionSnapshot?
    static let inactive = Self(status: .inactive, session: nil,
        acknowledgedPlanRevision: nil, volumeMode: nil, transition: nil)
}
enum RuntimeCommandResult: Equatable, Sendable {
    case satisfied, superseded, failed(String)
}
struct RuntimeApplyReceipt: Equatable, Sendable {
    let transactionID: RuntimeTransactionID
    let intentGeneration: RuntimeIntentGeneration
    let sessionID: UUID?
    let ownershipID: RuntimeOwnershipID?
    let oldPlanRevision: RuntimeIntentRevision?
    let candidatePlanRevision: RuntimeIntentRevision
}
