import Foundation

package struct RuntimeIntentRevision: Codable, Hashable, Sendable {
    package init(profileID: UUID, generation: UInt64) {
        self.profileID = profileID
        self.generation = generation
    }

    package let profileID: UUID
    package let generation: UInt64
}
