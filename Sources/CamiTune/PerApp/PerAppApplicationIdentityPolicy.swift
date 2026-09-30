import Foundation

/// Shared classification of stable identities and session-only placeholders.
enum PerAppApplicationIdentityPolicy {
    static func isEphemeralApplicationID(_ id: String) -> Bool {
        id.hasPrefix("pid:") || id.hasPrefix("client:")
    }

    static func isPersistentApplicationID(_ id: String) -> Bool {
        !isEphemeralApplicationID(id)
    }
}
