import CamiTuneAudio
import CamiTuneDomain
import Foundation

struct ProfileLibraryRevision: RawRepresentable, Comparable, Hashable, Sendable {
    let rawValue: UInt64
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
struct ProfilePersistenceOperationID: Hashable, Sendable { let rawValue: UInt64 }
enum ProfilePersistenceKind: String, Sendable {
    case autosave, settingsTransaction, profileCreation, routingPolicy, history, shutdownFlush
}
struct ProfilePersistenceReceipt: Sendable {
    let operationID: ProfilePersistenceOperationID
    let kind: ProfilePersistenceKind
    let sourceLibraryRevision: ProfileLibraryRevision
    let documentRevision: ProfileDocumentRevision
    let completedAt: Date
    let submittedAt: PerformanceTick
    let writeStartedAt: PerformanceTick
    let writeCompletedAt: PerformanceTick
    let queueMilliseconds: Double
    let encodingMilliseconds: Double
    let writeMilliseconds: Double
}
enum ProfileAutosaveResult: Sendable {
    case committed(ProfilePersistenceReceipt)
    case superseded
}
struct ProfileRepositoryStatus: Sendable {
    var lastCommittedRevision = ProfileDocumentRevision(rawValue: 0)
    var inFlightOperation: ProfilePersistenceOperationID?
    var inFlightKind: ProfilePersistenceKind?
    var targetRevision: ProfileDocumentRevision?
    var sourceRevision: ProfileLibraryRevision?
    var pendingAutosave = false
    var pendingDurableCount = 0
    var lastReceipt: ProfilePersistenceReceipt?
    var lastError: String?
    var supersededAutosaveCount: UInt64 = 0
    var writeFailures: UInt64 = 0
    var protectedStorage = false
}
