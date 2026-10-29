import Foundation

/// Shared classification of stable identities and session-only placeholders.
package enum PerAppApplicationIdentityPolicy {
    package static func isEphemeralApplicationID(_ id: String) -> Bool {
        id.hasPrefix("pid:") || id.hasPrefix("client:")
    }

    package static func isPersistentApplicationID(_ id: String) -> Bool {
        !isEphemeralApplicationID(id)
    }
}
