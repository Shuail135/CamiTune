import Foundation

package enum ProfileSettingsError: LocalizedError {
    case invalidName, staleDraft, busy, cancelled, runtime(String), rollback(String, String)
    package var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a profile name."
        case .staleDraft: return "This profile changed while Settings was open. Close Settings and reopen it to load the latest values."
        case .busy: return "Wait for the current audio operation to finish, then save again."
        case .cancelled: return "The audio operation was cancelled. Your settings were not saved."
        case .runtime(let detail): return detail
        case .rollback(let failure, let rollback): return "\(failure) The previous settings are still saved, but audio could not be restored: \(rollback)"
        }
    }
}
