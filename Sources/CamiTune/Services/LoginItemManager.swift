import Foundation
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    struct Notice {
        let title: String
        let message: String
        var requiresApproval = false
    }

    @Published private(set) var isEnabled = false
    @Published private(set) var isUpdating = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var requiresApproval = false

    init() {
        refresh()
    }

    func refresh() {
        requiresApproval = false

        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            statusMessage = "Enabled — CamiTune will start after you log in."
        case .requiresApproval:
            isEnabled = false
            requiresApproval = true
            statusMessage = "Approval is required in System Settings → General → Login Items."
        case .notRegistered:
            isEnabled = false
            statusMessage = "Check this if you want CamiTune will start after you log in."
        case .notFound:
            // Ad-hoc release builds can receive this after an older build's
            // registration was removed because each rebuild has a new code
            // hash. The app bundle may still be correctly installed.
            isEnabled = false
            statusMessage = "CamiTune will not start automatically now."
        @unknown default:
            isEnabled = false
            statusMessage = "The login-item status could not be determined."
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Notice? {
        guard !isUpdating else { return nil }
        if enabled && !isInApplicationsFolder {
            isEnabled = false
            requiresApproval = false
            statusMessage = "Move CamiTune to Applications, reopen it there, then enable login startup."
            return Notice(title: "Couldn’t Enable Login Startup", message: statusMessage)
        }
        isUpdating = true
        defer { isUpdating = false }

        do {
            if enabled {
                // A pending registration needs approval, not another registration.
                if SMAppService.mainApp.status != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
                refresh()
                if requiresApproval {
                    return Notice(title: "Login Startup Needs Approval", message: statusMessage, requiresApproval: true)
                }
                if !isEnabled {
                    statusMessage = "macOS did not enable login startup. Check CamiTune in System Settings → General → Login Items, then try again."
                    return Notice(title: "Couldn’t Enable Login Startup", message: statusMessage)
                }
            } else {
                try SMAppService.mainApp.unregister()
                refresh()
                if isEnabled || requiresApproval {
                    statusMessage = "macOS did not remove CamiTune from Login Items. Review it in System Settings → General → Login Items."
                    return Notice(title: "Couldn’t Disable Login Startup", message: statusMessage)
                }
                statusMessage = "CamiTune will not start automatically."
            }
        } catch {
            refresh()
            statusMessage = "Could not update the login item: \(error.localizedDescription)"
            return Notice(title: "Couldn’t Update Login Startup", message: statusMessage)
        }

        return nil
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private var isInApplicationsFolder: Bool {
        let appPath = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).path
        return ["/Applications", userApplications].contains { root in
            appPath == root || appPath.hasPrefix(root + "/")
        }
    }
}
