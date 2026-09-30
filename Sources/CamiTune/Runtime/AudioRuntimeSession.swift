import Foundation

struct AudioRuntimeSession: Equatable, Sendable {
    let id: UUID
    let profileID: UUID

    init(id: UUID = UUID(), profileID: UUID) {
        self.id = id
        self.profileID = profileID
    }
}
