import Foundation

@MainActor
final class VolumeHandoffLease {
    let id: UInt64
    let ownershipID: RuntimeOwnershipID
    let routingUID: String
    let physicalUID: String
    let controlSession: SystemVolumeControlSession
    let onMirrorFailure: @MainActor @Sendable () -> Void
    var mode: SystemVolumeMode { controlSession.mode }
    init(id: UInt64, ownershipID: RuntimeOwnershipID, routingUID: String, physicalUID: String,
         controlSession: SystemVolumeControlSession, onMirrorFailure: @escaping @MainActor @Sendable () -> Void) {
        self.id = id; self.ownershipID = ownershipID; self.routingUID = routingUID; self.physicalUID = physicalUID
        self.controlSession = controlSession; self.onMirrorFailure = onMirrorFailure
    }
}
