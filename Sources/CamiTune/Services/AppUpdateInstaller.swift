import AppKit
import Foundation
import Darwin
import SwiftUI

/// Runs in a second process, before the audio app or its single-instance lock
/// is created. Its window survives the app's shutdown and bundle replacement.
enum AppUpdateInstaller {
    struct Request: Codable {
        let id: UUID
        let parentPID: Int32
        let target: URL
        let staged: URL
        let version: String
        let directory: URL

        var candidate: URL { target.deletingLastPathComponent().appendingPathComponent(".CamiTune-update-\(id).app") }
        var backup: URL { target.deletingLastPathComponent().appendingPathComponent(".CamiTune-previous-\(id)") }
        var requestURL: URL { directory.appendingPathComponent("request.json") }
        func marker(_ name: String) -> URL { directory.appendingPathComponent(name) }
    }

    struct Result: Codable {
        let version: String
        let target: URL
        let succeeded: Bool
        let message: String
    }

    private struct ActiveInstallation: Codable {
        let request: Request
        let helperPID: Int32
        let isReplacing: Bool
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var resultURL: URL { CamiTunePaths.supportDirectory.appendingPathComponent("AppUpdateResult.json") }
    private static var activeURL: URL { CamiTunePaths.supportDirectory.appendingPathComponent("AppUpdateInProgress.json") }

    static func markActive(_ request: Request, replacing: Bool) throws {
        let active = ActiveInstallation(request: request, helperPID: ProcessInfo.processInfo.processIdentifier,
            isReplacing: replacing)
        try JSONEncoder().encode(active).write(to: activeURL, options: .atomic)
    }

    static func clearActive(_ request: Request) {
        guard let active = activeInstallation(), active.request.id == request.id else { return }
        try? FileManager.default.removeItem(at: activeURL)
    }

    private static func activeInstallation() -> ActiveInstallation? {
        guard let data = try? Data(contentsOf: activeURL) else { return nil }
        return try? JSONDecoder().decode(ActiveInstallation.self, from: data)
    }

    /// A manual launch during replacement must not start the old audio app.
    @MainActor
    static func redirectLaunchToInstaller() -> Bool {
        guard let active = activeInstallation(), active.isReplacing,
              active.request.target.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL,
              Darwin.kill(active.helperPID, 0) == 0 else { return false }
        NSRunningApplication(processIdentifier: active.helperPID)?.activate(options: [.activateIgnoringOtherApps])
        return true
    }

    @MainActor
    static func handoff(appURL: URL, directory: URL, version: String) async throws {
        let request = Request(id: UUID(), parentPID: ProcessInfo.processInfo.processIdentifier,
            target: Bundle.main.bundleURL.standardizedFileURL, staged: appURL, version: version,
            directory: directory.appendingPathComponent("Install-\(UUID())", isDirectory: true))
        try FileManager.default.createDirectory(at: request.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(request).write(to: request.requestURL, options: .atomic)
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["--install-app-update", request.requestURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // If the helper cannot start or display its window, keep the app open.
        do {
            try await waitForMarker("ready", request: request, process: process, timeout: 120)
            try Data().write(to: request.marker("authorized"), options: .atomic)
            DispatchQueue.main.async { NSApp.terminate(nil) }
            // A termination veto leaves this task alive. Do not leave the UI
            // spinning indefinitely or install later on an unrelated Quit.
            try await waitForMarker("parent-exited", request: request, process: process, timeout: 35)
        } catch {
            try? FileManager.default.removeItem(at: request.marker("authorized"))
            if process.isRunning { process.terminate() }
            clearActive(request)
            throw error
        }
    }

    @MainActor
    private static func waitForMarker(_ name: String, request: Request, process: Process,
                                      timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: request.marker(name).path) {
            if let message = try? String(contentsOf: request.marker("failure"), encoding: .utf8) {
                throw Failure(message: message)
            }
            guard process.isRunning else {
                throw Failure(message: "The update installer could not start. CamiTune is still open. Please try again.")
            }
            guard Date() < deadline else {
                throw Failure(message: "CamiTune could not restart to install the update. Finish any open dialogs, then try again.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    static func runIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--install-app-update") else { return false }
        guard CommandLine.arguments.count > index + 1,
              let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])),
              let request = try? JSONDecoder().decode(Request.self, from: data) else { return true }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = AppUpdateInstallerWindow(request: request)
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
        return true
    }

    /// The replacement app acknowledges only after its main window is visible.
    @MainActor
    static func acknowledgeRelaunch() {
        let request: Request?
        if let index = CommandLine.arguments.firstIndex(of: "--app-update-relaunch"),
           CommandLine.arguments.count > index + 1,
           let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])) {
            request = try? JSONDecoder().decode(Request.self, from: data)
        } else if let active = activeInstallation(), !active.isReplacing {
            request = active.request
        } else { request = nil }
        guard let request,
              request.target.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL else { return }
        try? Data().write(to: request.marker("reopened"), options: .atomic)
    }

    static func consumeResult(for appURL: URL, at url: URL = resultURL) -> Result? {
        guard let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(Result.self, from: data),
              result.target.standardizedFileURL == appURL.standardizedFileURL else { return nil }
        try? FileManager.default.removeItem(at: url)
        return result
    }

    static func recordResult(_ request: Request, succeeded: Bool, message: String) throws {
        let result = Result(version: request.version, target: request.target, succeeded: succeeded, message: message)
        try JSONEncoder().encode(result).write(to: resultURL, options: .atomic)
    }

    /// Copy before quitting. Both final moves then stay on the target volume,
    /// so a large bundle (or an app on another disk) needs only a brief restart.
    static func stageReplacement(_ request: Request, fileManager: FileManager = .default) throws {
        guard request.target.pathExtension == "app",
              request.target.standardizedFileURL != request.staged.standardizedFileURL,
              fileManager.fileExists(atPath: request.target.path),
              fileManager.fileExists(atPath: request.staged.path) else {
            throw Failure(message: "The application files are no longer available. Download the update again.")
        }
        do { try fileManager.copyItem(at: request.staged, to: request.candidate) }
        catch {
            try? fileManager.removeItem(at: request.candidate)
            throw Failure(message: "The update could not be copied to the application folder. Check free disk space and folder permissions, then try again. \(error.localizedDescription)")
        }
    }

    /// Keep the old bundle until the new application has actually reopened.
    /// A failed replacement restores it before surfacing the error.
    static func replaceApplication(_ request: Request, fileManager: FileManager = .default) throws {
        try fileManager.moveItem(at: request.target, to: request.backup)
        do {
            try fileManager.moveItem(at: request.candidate, to: request.target)
        } catch {
            do { try fileManager.moveItem(at: request.backup, to: request.target) }
            catch {
                throw Failure(message: "The update could not be installed or restored automatically. Your previous app is saved at \(request.backup.path). Move it back to \(request.target.path).")
            }
            throw Failure(message: "The update could not be installed. Your previous version has been restored. Please try again. \(error.localizedDescription)")
        }
    }

    /// The caller must stop applications using the target before restoring it.
    /// Preserve the failed update as well until the previous app acknowledges
    /// reopening. Every failed move leaves a recoverable application on disk.
    static func restorePreviousApplication(_ request: Request, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: request.backup.path) else {
            throw Failure(message: "The previous application is no longer available at \(request.backup.path).")
        }
        let hasTarget = fileManager.fileExists(atPath: request.target.path)
        if hasTarget { try fileManager.moveItem(at: request.target, to: request.candidate) }
        do { try fileManager.moveItem(at: request.backup, to: request.target) }
        catch {
            if hasTarget { try? fileManager.moveItem(at: request.candidate, to: request.target) }
            throw Failure(message: "The previous app could not be restored automatically. It is saved at \(request.backup.path). Close CamiTune, then move it back to \(request.target.path). \(error.localizedDescription)")
        }
    }
}

@MainActor
private final class AppUpdateInstallerWindow: NSObject, NSApplicationDelegate, ObservableObject {
    let request: AppUpdateInstaller.Request
    private var window: NSWindow!
    @Published private(set) var heading = "Preparing to restart"
    @Published private(set) var detail = "Preparing the update. CamiTune will close briefly and reopen automatically. Audio will pause during the restart."
    @Published private(set) var finished = false
    @Published private(set) var canOpen = false
    @Published private(set) var canRestore = false
    private var installed = false

    init(request: AppUpdateInstaller.Request) { self.request = request }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentViewController: NSHostingController(rootView: AppUpdateInstallerContent(controller: self)))
        window.styleMask = [.titled]
        window.title = "CamiTune Update"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await install() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        finished ? .terminateNow : .terminateCancel
    }

    private func install() async {
        do {
            let request = self.request
            try AppUpdateInstaller.markActive(request, replacing: true)
            try await Task.detached { try AppUpdateInstaller.stageReplacement(request) }.value
            try Data().write(to: request.marker("ready"), options: .atomic)
            heading = "Closing CamiTune"
            let deadline = Date().addingTimeInterval(30)
            while Darwin.kill(request.parentPID, 0) == 0 {
                guard Date() < deadline else {
                    throw AppUpdateInstaller.Failure(message: "CamiTune could not close for the update. Finish any open dialogs in CamiTune, then try Install & Restart again.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard FileManager.default.fileExists(atPath: request.marker("authorized").path) else {
                throw AppUpdateInstaller.Failure(message: "The update was interrupted before installation. Open CamiTune and try again.")
            }
            try Data().write(to: request.marker("parent-exited"), options: .atomic)
            heading = "Installing update"
            detail = "Keep this window open. CamiTune will reopen automatically when the update is complete."
            try await Task.detached { try AppUpdateInstaller.replaceApplication(request) }.value
            installed = true
            await reopen()
        } catch {
            AppUpdateInstaller.clearActive(request)
            try? FileManager.default.removeItem(at: request.candidate)
            try? error.localizedDescription.write(to: request.marker("failure"), atomically: true, encoding: .utf8)
            // Keep the error visible even if the parent is stuck in a quit
            // dialog. Once it can resume, handoff surfaces the same error in
            // the app and retires this helper.
            if Darwin.kill(request.parentPID, 0) != 0 {
                try? AppUpdateInstaller.recordResult(request, succeeded: false, message: error.localizedDescription)
            }
            showRecovery(title: "Update could not finish", message: error.localizedDescription)
        }
    }

    private func reopen() async {
        heading = "Reopening CamiTune"
        detail = installed ? "CamiTune \(request.version) is installed. Waiting for its window to open."
            : "Opening your previous version of CamiTune. You can try the update again from the app."
        canOpen = false
        canRestore = false
        finished = false
        do {
            // Each launch attempt needs its own acknowledgement; a previous
            // failed/rolled-back launch must not complete a later attempt.
            if FileManager.default.fileExists(atPath: request.marker("reopened").path) {
                try FileManager.default.removeItem(at: request.marker("reopened"))
            }
            try AppUpdateInstaller.markActive(request, replacing: false)
            let configuration = NSWorkspace.OpenConfiguration()
            // The updater is running from the old bundle with the same bundle
            // identifier, so Launch Services must create a new app process.
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--app-update-relaunch", request.requestURL.path]
            let pid: Int32 = try await withCheckedThrowingContinuation { continuation in
                NSWorkspace.shared.openApplication(at: request.target, configuration: configuration) { application, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let application { continuation.resume(returning: application.processIdentifier) }
                    else { continuation.resume(throwing: AppUpdateInstaller.Failure(message: "macOS could not open CamiTune.")) }
                }
            }
            let deadline = Date().addingTimeInterval(30)
            while !FileManager.default.fileExists(atPath: request.marker("reopened").path) {
                guard Darwin.kill(pid, 0) == 0, Date() < deadline else {
                    throw AppUpdateInstaller.Failure(message: "CamiTune did not finish reopening.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            if installed {
                do { try AppUpdateInstaller.recordResult(request, succeeded: true, message: "") }
                catch {
                    AppUpdateInstaller.clearActive(request)
                    showRecovery(title: "CamiTune reopened", message: "The update opened successfully, but its completion could not be saved. \(error.localizedDescription)")
                    return
                }
            }
            try? FileManager.default.removeItem(at: request.backup)
            try? FileManager.default.removeItem(at: request.candidate)
            AppUpdateInstaller.clearActive(request)
            try? FileManager.default.removeItem(at: request.directory.deletingLastPathComponent())
            finished = true
            DispatchQueue.main.async { NSApp.terminate(nil) }
        } catch {
            if installed {
                await restorePreviousVersion(reason: error.localizedDescription)
            } else {
                AppUpdateInstaller.clearActive(request)
                showRecovery(title: "CamiTune could not reopen",
                    message: "Click Open CamiTune to try again, or open it from Finder. \(error.localizedDescription)")
            }
        }
    }

    private func restorePreviousVersion(reason: String) async {
        let request = self.request
        heading = "Restoring the previous version"
        detail = "The update could not reopen. Restoring your previous CamiTune application."
        finished = false; canOpen = false; canRestore = false
        do {
            try AppUpdateInstaller.markActive(request, replacing: true)
            // Never move a bundle beneath a running audio application. A
            // stalled/vetoed quit leaves both versions intact and offers retry.
            let helperPID = ProcessInfo.processInfo.processIdentifier
            let applications = NSWorkspace.shared.runningApplications.filter {
                $0.processIdentifier != helperPID
                    && $0.bundleURL?.standardizedFileURL == request.target.standardizedFileURL
            }
            for application in applications where !application.isTerminated { application.terminate() }
            let deadline = Date().addingTimeInterval(5)
            while applications.contains(where: { !$0.isTerminated }) {
                guard Date() < deadline else {
                    throw AppUpdateInstaller.Failure(message: "Close the new CamiTune application, then choose Restore Previous Version. Your previous app is saved at \(request.backup.path).")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.detached { try AppUpdateInstaller.restorePreviousApplication(request) }.value
            installed = false
            try AppUpdateInstaller.recordResult(request, succeeded: false,
                message: "CamiTune \(request.version) could not reopen. Your previous version has been restored. \(reason)")
            await reopen()
        } catch {
            AppUpdateInstaller.clearActive(request)
            try? AppUpdateInstaller.recordResult(request, succeeded: false, message: error.localizedDescription)
            showRecovery(title: "Update recovery needs attention", message: error.localizedDescription)
        }
    }

    private func showRecovery(title: String, message: String) {
        heading = title
        detail = message
        finished = true
        canOpen = Darwin.kill(request.parentPID, 0) != 0 && FileManager.default.fileExists(atPath: request.target.path)
        canRestore = installed && FileManager.default.fileExists(atPath: request.backup.path)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openApplication() {
        Task { await reopen() }
    }

    func restoreApplication() {
        Task { await restorePreviousVersion(reason: "The update did not finish reopening.") }
    }

    func closeInstaller() { NSApp.terminate(nil) }
}

@MainActor
private struct AppUpdateInstallerContent: View {
    @ObservedObject var controller: AppUpdateInstallerWindow

    var body: some View {
        AppUpdatePanel(title: controller.heading, subtitle: "CamiTune \(controller.request.version)") {
            GroupBox {
                HStack(alignment: .top, spacing: 10) {
                    if !controller.finished { ProgressView().controlSize(.small) }
                    Text(controller.detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            if controller.finished {
                Button("Close") { controller.closeInstaller() }
                Spacer()
                if controller.canRestore {
                    Button("Restore Previous Version") { controller.restoreApplication() }
                }
                if controller.canOpen {
                    Button("Open CamiTune") { controller.openApplication() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            } else {
                Text("CamiTune will reopen automatically.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}
