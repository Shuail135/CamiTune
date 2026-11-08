import Foundation
import ServiceManagement

enum LoginItemStatus: Equatable {
    case enabled, requiresApproval, notRegistered, notFound, unknown

    var message: String {
        switch self {
        case .enabled: return "Enabled — CamiTune will start after you log in."
        case .requiresApproval: return "Approval is required in System Settings → General → Login Items."
        case .notRegistered: return "Enable this to start CamiTune after you log in."
        case .notFound: return "CamiTune will not start automatically now."
        case .unknown: return "The login-item status could not be determined."
        }
    }
}

/// Registration and status belong to the same system service. Mutations must
/// verify their outcome; presentation and migration share this contract.
@MainActor
protocol LoginItemRegistration {
    var status: LoginItemStatus { get throws }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

private struct LoginItemFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor
final class LoginItemManager: ObservableObject {
    static let helperIdentifier = "local.camilla.app.LoginItem"
    static let helperRelativePath = "Contents/Library/LoginItems/CamiTuneLoginItem.app"

    weak var history: UndoCoordinator?
    struct Notice {
        let title: String
        let message: String
        var requiresApproval = false
    }
    private struct Presentation {
        var status: LoginItemStatus
        var message: String?
    }
    @Published private var presentation = Presentation(status: .notRegistered)
    @Published private(set) var isUpdating = false
    var isEnabled: Bool { presentation.status == .enabled }
    var requiresApproval: Bool { presentation.status == .requiresApproval }
    var statusMessage: String { presentation.message ?? presentation.status.message }

    private let registration: LoginItemRegistration
    private var previousRegistration: LoginItemRegistration?
    private let appURL: URL
    private let userApplicationsURL: URL

    convenience init() {
        if #available(macOS 13, *) {
            self.init(registration: AppServiceLoginItem(.mainApp),
                previousRegistration: AppServiceLoginItem(.loginItem(identifier: Self.helperIdentifier)))
        } else {
            self.init(registration: LegacyLoginItem(appURL: Bundle.main.bundleURL))
        }
    }

    init(registration: LoginItemRegistration, previousRegistration: LoginItemRegistration? = nil,
         appURL: URL = Bundle.main.bundleURL,
         userApplicationsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")) {
        self.registration = registration
        self.previousRegistration = previousRegistration
        self.appURL = appURL
        self.userApplicationsURL = userApplicationsURL
        // Only an installed app migrates a previously enabled helper. A denied
        // helper remains denied until the user explicitly changes the setting.
        do {
            if isInApplicationsFolder, let previous = try previousRegistration?.status {
                let current = try registration.status
                if previous == .enabled || (previous == .requiresApproval &&
                    (current == .enabled || current == .requiresApproval)) {
                    try changeRegistration(to: true)
                }
            }
            refresh()
        } catch {
            refresh()
            presentation.message = "Could not migrate login startup: \(error.localizedDescription)"
        }
    }

    func refresh() {
        do {
            let status = try registeredStatus()
            // Keep an operation failure visible through onAppear/activation
            // refreshes. A changed system state or successful action clears it.
            if status != presentation.status { presentation = Presentation(status: status) }
        } catch {
            presentation = Presentation(status: .unknown,
                message: "Could not read login startup: \(error.localizedDescription)")
        }
    }

    private func registeredStatus() throws -> LoginItemStatus {
        let current = try registration.status
        let previous = try previousRegistration?.status
        // A failed migration can leave the old registration active. Report
        // the actual combined state instead of claiming startup is off.
        if current == .enabled || previous == .enabled { return .enabled }
        if current == .requiresApproval || previous == .requiresApproval { return .requiresApproval }
        if current == .unknown || previous == .unknown { return .unknown }
        return current
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Notice? {
        guard !isUpdating else { return nil }
        let before = isEnabled
        if enabled && !isInApplicationsFolder {
            presentation.message = "Move CamiTune to Applications, reopen it there, then enable login startup."
            return Notice(title: "Couldn’t Enable Login Startup", message: statusMessage)
        }
        isUpdating = true
        defer { isUpdating = false }
        do {
            try changeRegistration(to: enabled)
            presentation = Presentation(status: try registeredStatus())
            if enabled && requiresApproval {
                return Notice(title: "Login Startup Needs Approval", message: statusMessage, requiresApproval: true)
            }
            guard isEnabled == enabled, !requiresApproval, presentation.status != .unknown else {
                throw LoginItemFailure("macOS did not confirm the requested login-startup setting.")
            }
            if !enabled { presentation.message = "CamiTune will not start automatically." }
        } catch {
            refresh()
            presentation.message = "Could not update login startup: \(error.localizedDescription)"
            return Notice(title: "Couldn’t Update Login Startup", message: statusMessage)
        }
        history?.record(actionName: "Change Login Startup", target: .preference(.loginStartup),
            before: .boolean(before), after: .boolean(isEnabled))
        return nil
    }

    private func changeRegistration(to enabled: Bool) throws {
        let previous = try previousRegistration?.status
        guard previous != .unknown else {
            throw LoginItemFailure("The previous login-item status could not be determined. Review Login Items in System Settings before changing startup.")
        }
        let hadPrevious = previous == .enabled || previous == .requiresApproval
        if !enabled {
            // Remove both registrations when disabling after an OS upgrade.
            if hadPrevious { try previousRegistration?.setEnabled(false) }
            try registration.setEnabled(false)
            previousRegistration = nil
            return
        }
        let before = try registration.status
        try registration.setEnabled(true)
        if hadPrevious {
            do {
                try previousRegistration?.setEnabled(false)
            } catch {
                // The old helper still owns startup. Undo only a registration
                // made here; an existing main-app registration belongs to the user.
                let remaining = try previousRegistration?.status
                if (before == .notRegistered || before == .notFound) &&
                    (remaining == .enabled || remaining == .requiresApproval) {
                    do { try registration.setEnabled(false) }
                    catch let rollbackError {
                        throw LoginItemFailure("The previous login item could not be removed (\(error.localizedDescription)), and the new registration could not be rolled back (\(rollbackError.localizedDescription)). Disable login startup and try again.")
                    }
                }
                throw error
            }
        }
        previousRegistration = nil
    }

    func openSystemSettings() { registration.openSystemSettings() }

    private var isInApplicationsFolder: Bool {
        let path = appURL.resolvingSymlinksInPath().standardizedFileURL.path
        return [URL(fileURLWithPath: "/Applications"), userApplicationsURL].contains {
            let root = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return path.hasPrefix(root + "/") && appURL.pathExtension == "app"
        }
    }
}

@available(macOS 13, *)
@MainActor
private struct AppServiceLoginItem: LoginItemRegistration {
    let service: SMAppService
    init(_ service: SMAppService) { self.service = service }
    var status: LoginItemStatus {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if status != .enabled && status != .requiresApproval { try service.register() }
            guard status == .enabled || status == .requiresApproval else {
                throw LoginItemFailure("macOS did not enable the login item.")
            }
        } else {
            if status != .notRegistered && status != .notFound { try service.unregister() }
            guard status == .notRegistered || status == .notFound else {
                throw LoginItemFailure("macOS did not remove the login item. Review Login Items in System Settings.")
            }
        }
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
struct LegacyLoginItem: LoginItemRegistration {
    let appURL: URL
    var status: LoginItemStatus {
        get throws {
            // Apple's SDK explicitly retains this API for reading the state of
            // SMLoginItemSetEnabled registrations on systems before SMAppService.
            guard let jobs = SMCopyAllJobDictionaries(kSMDomainUserLaunchd)?.takeRetainedValue() as? [[String: Any]] else {
                throw LoginItemFailure("macOS could not read the registered login items.")
            }
            guard let job = jobs.first(where: { $0["Label"] as? String == LoginItemManager.helperIdentifier }) else {
                return .notRegistered
            }
            guard let enabled = job["OnDemand"] as? Bool else {
                throw LoginItemFailure("macOS returned an unreadable login-item status.")
            }
            return enabled ? .enabled : .notRegistered
        }
    }
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            let helperURL = appURL.appendingPathComponent(LoginItemManager.helperRelativePath)
            guard let helper = Bundle(url: helperURL), helper.bundleIdentifier == LoginItemManager.helperIdentifier,
                  let executable = helper.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw LoginItemFailure("The login launcher is missing. Reinstall CamiTune to restore login startup.")
            }
        }
        if try (status == .enabled) == enabled { return }
        guard SMLoginItemSetEnabled(LoginItemManager.helperIdentifier as CFString, enabled) else {
            throw LoginItemFailure("macOS could not \(enabled ? "enable" : "disable") the login launcher.")
        }
        guard try (status == .enabled) == enabled else {
            throw LoginItemFailure("macOS did not confirm the login launcher’s new status.")
        }
    }
    func openSystemSettings() { }
}
