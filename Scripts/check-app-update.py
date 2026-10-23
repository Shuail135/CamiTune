#!/usr/bin/env python3
"""Exercise the production updater against disposable app bundles.

Pass --integration to also show its native installer window and verify that
the old process exits, the replacement opens, and the helper gets its receipt.
No installed copy of CamiTune or user preferences are changed.
"""
import argparse
import contextlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time


HARNESS = r'''
import AppKit
import Foundation
import SwiftUI

struct CheckFailure: Error { let message: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message: message) }
}

final class FailingMoves: FileManager {
    let failures: Set<Int>
    var moves = 0
    init(_ failures: Set<Int>) { self.failures = failures; super.init() }
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moves += 1
        if failures.contains(moves) { throw CheckFailure(message: "Injected move failure") }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

final class ReleaseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let release = #"{"tag_name":"v99.0.0","draft":false,"prerelease":false,"assets":[{"name":"CamiTune-v99.0.0-app.zip","browser_download_url":"https://example.invalid/update.zip"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(release.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
func unitChecks() async throws {
    let fm = FileManager.default
    func fixture(_ name: String) throws -> AppUpdateInstaller.Request {
        let directory = CamiTunePaths.supportDirectory.appendingPathComponent(name)
        let target = directory.appendingPathComponent("CamiTune with spaces.app")
        let staged = directory.appendingPathComponent("Staged.app")
        for (url, version) in [(target, "old"), (staged, "new")] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try version.write(to: url.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        }
        return .init(id: UUID(), parentPID: 0, target: target, staged: staged,
            version: "v2.0.0", directory: directory)
    }
    func version(_ url: URL) -> String? { try? String(contentsOf: url.appendingPathComponent("version")) }
    let success = try fixture("success")
    try AppUpdateInstaller.stageReplacement(success)
    try require(version(success.target) == "old", "Staging must leave the running app untouched")
    try require(version(success.candidate) == "new", "Candidate must contain the downloaded update")
    try AppUpdateInstaller.replaceApplication(success)
    try require(version(success.target) == "new", "The replacement must be installed")
    try require(version(success.backup) == "old", "The original must survive until reopening is acknowledged")

    for failures: Set<Int> in [[1], [2], [2, 3]] {
        let request = try fixture("failure-\(UUID())")
        try AppUpdateInstaller.stageReplacement(request)
        do {
            try AppUpdateInstaller.replaceApplication(request, fileManager: FailingMoves(failures))
            throw CheckFailure(message: "Injected failure was ignored")
        } catch is CheckFailure where failures == [1] {} // Initial move fails before replacement.
        catch is AppUpdateInstaller.Failure {}
        if failures == [2, 3] {
            try require(version(request.backup) == "old", "A failed rollback must preserve the old app")
        } else {
            try require(version(request.target) == "old", "A failed installation must preserve or restore the old app")
        }
    }
    let missing = try fixture("missing")
    try fm.removeItem(at: missing.staged)
    do {
        try AppUpdateInstaller.stageReplacement(missing)
        throw CheckFailure(message: "Missing staged application was accepted")
    } catch is AppUpdateInstaller.Failure {}
    try require(version(missing.target) == "old", "Missing update must not change the original")

    try AppUpdateInstaller.recordResult(success, succeeded: true, message: "")
    try require(AppUpdateInstaller.consumeResult(for: missing.target) == nil, "Another app copy must not consume the receipt")
    let receipt = AppUpdateInstaller.consumeResult(for: success.target)
    try require(receipt?.succeeded == true && receipt?.version == "v2.0.0", "Completion must persist across launches")
    try require(AppUpdateInstaller.consumeResult(for: success.target) == nil, "Completion must be shown only once")
    try AppUpdateInstaller.recordResult(success, succeeded: false, message: "Rollback completed")
    try require(AppUpdateInstaller.consumeResult(for: success.target)?.message == "Rollback completed", "Failures must persist across launches")

    let suite = "CamiTuneUpdaterCheck-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ReleaseProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let checker = AppUpdateChecker(defaults: defaults, session: session)
    await checker.checkOnLaunch()
    try require(checker.availableUpdate?.version == "v99.0.0", "Release checking must offer an update")
    if CommandLine.arguments.contains("--snapshots") {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        if let icon = NSImage(contentsOf: CamiTunePaths.supportDirectory.appendingPathComponent("icon.png")) {
            app.applicationIconImage = icon
        }
        for (name, appearance) in [("update-prompt-light", NSAppearance.Name.aqua), ("update-prompt-dark", .darkAqua)] {
            let host = NSHostingView(rootView: AppUpdateProgressView(checker: checker)
                .environment(\.colorScheme, appearance == .aqua ? .light : .dark)
                .environment(\.controlActiveState, .key))
            host.appearance = NSAppearance(named: appearance)
            let size = host.fittingSize
            host.setFrameSize(size)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            window.displayIfNeeded()
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                    CGWindowID(window.windowNumber), [.boundsIgnoreFraming]) else {
                throw CheckFailure(message: "Could not render update prompt")
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            try bitmap.representation(using: .png, properties: [:])!.write(to: CamiTunePaths.supportDirectory.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
    }
    checker.beginUpdate()
    try require(checker.phase == .downloading && checker.availableUpdate == nil, "Download must use one progress surface")
    for _ in 0..<100 where checker.phase != .failed { try await Task.sleep(for: .milliseconds(10)) }
    try require(checker.phase == .failed && checker.isPresentingUpdate, "An unsupported location must show a failure without quitting")
    try require(checker.availableUpdate == nil && checker.canRetry, "Failure must offer retry without a competing release alert")
    checker.dismissUpdate()
    try require(checker.phase == .idle, "Dismissal must leave the updater idle")
    defaults.removeObject(forKey: "appUpdate.remindAfter")
    await checker.checkOnLaunch()
    checker.beginUpdate()
    checker.dismissUpdate()
    try await Task.sleep(for: .milliseconds(30))
    try require(checker.phase == .idle, "Cancelled download must not publish a later failure or quit")
    print("PASS: staging, replacement, rollback, rollback failure, missing files, receipts, failure UI state, cancellation")
}

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        try? Data().write(to: CamiTunePaths.supportDirectory.appendingPathComponent("fixture-started"))
        if let index = CommandLine.arguments.firstIndex(of: "--handoff-test") {
            let stage = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task {
                do {
                    try await AppUpdateInstaller.handoff(appURL: stage,
                        directory: stage.deletingLastPathComponent(), version: "v2.0.0")
                } catch {
                    try? error.localizedDescription.write(to: CamiTunePaths.supportDirectory.appendingPathComponent("handoff-error"),
                        atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                }
            }
        } else {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            window?.title = "CamiTune update test completed"
            window?.makeKeyAndOrderFront(nil)
            AppUpdateInstaller.acknowledgeRelaunch()
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            try? version.write(to: CamiTunePaths.supportDirectory.appendingPathComponent("relaunched"), atomically: true, encoding: .utf8)
            Task {
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard CommandLine.arguments.contains("--handoff-test") else { return .terminateNow }
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(finishQuit), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        return .terminateLater
    }
    @objc private func finishQuit() { NSApp.reply(toApplicationShouldTerminate: true) }
}

@main enum Harness {
    @MainActor static func main() {
        if AppUpdateInstaller.runIfRequested() { return }
        if AppUpdateInstaller.redirectLaunchToInstaller() {
            try? Data().write(to: CamiTunePaths.supportDirectory.appendingPathComponent("redirected"))
            return
        }
        if CommandLine.arguments.contains("--unit-tests") {
            Task {
                do { try await unitChecks(); exit(0) }
                catch { print("FAIL: \(error)"); exit(1) }
            }
            RunLoop.main.run()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = FixtureDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--integration", action="store_true")
    parser.add_argument("--artifacts", type=Path, help="Keep fixtures and receipts in an empty directory for inspection")
    parser.add_argument("--snapshots", action="store_true", help="Render the update prompt in light and dark mode")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    directory = contextlib.nullcontext(str(args.artifacts.resolve())) if args.artifacts else tempfile.TemporaryDirectory(prefix="camitune-update-check-")
    with directory as temporary:
        root = Path(temporary)
        root.mkdir(parents=True, exist_ok=True)
        shutil.copy2(repo / "Sources/CamiTune/icon.png", root / "icon.png")
        harness = root / "Harness.swift"
        harness.write_text(HARNESS + "\nenum CamiTunePaths { static let supportDirectory = URL(fileURLWithPath: "
                           + json.dumps(str(root)) + ") }\n")
        executable = root / "UpdateCheck"
        sources = repo / "Sources/CamiTune/Services"
        subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(root / "ModuleCache"),
                        str(sources / "AppUpdateChecker.swift"), str(sources / "AppUpdateInstaller.swift"),
                        str(repo / "Sources/CamiTune/UI/Navigation/AppUpdatePanel.swift"),
                        str(harness), "-o", str(executable)], check=True)
        subprocess.run([str(executable), "--unit-tests"] + (["--snapshots"] if args.snapshots else []), check=True, timeout=30)
        if not args.integration:
            return

        def app_bundle(path, version):
            macos = path / "Contents/MacOS"
            macos.mkdir(parents=True)
            shutil.copy2(executable, macos / "UpdateCheck")
            resources = path / "Contents/Resources"
            resources.mkdir()
            shutil.copy2(repo / "Sources/CamiTune/icon.png", resources / "icon.png")
            with (path / "Contents/Info.plist").open("wb") as stream:
                plistlib.dump({"CFBundleIdentifier": "local.camilla.update-check",
                              "CFBundleExecutable": "UpdateCheck", "CFBundlePackageType": "APPL",
                              "CFBundleName": "CamiTune Update Check", "CFBundleShortVersionString": version}, stream)
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(path)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            return macos / "UpdateCheck"

        target = root / "Applications with spaces/CamiTune.app"
        staged = root / "Prepared Update/Staged.app"
        old = app_bundle(target, "1.0.0")
        app_bundle(staged, "2.0.0")
        parent = subprocess.Popen([str(old), "--handoff-test", str(staged)])
        helper_pid = None
        manual_launch_checked = False
        try:
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                parent.poll()  # Reap the old process so kill(pid, 0) observes its exit.
                active = root / "AppUpdateInProgress.json"
                if active.exists():
                    state = json.loads(active.read_text())
                    helper_pid = state["helperPID"]
                    if state["isReplacing"] and not manual_launch_checked:
                        subprocess.run([str(old)], check=True, timeout=5)
                        assert (root / "redirected").exists(), "Manual launch must return to the installer"
                        manual_launch_checked = True
                error = root / "handoff-error"
                if error.exists():
                    raise RuntimeError(error.read_text())
                if (root / "relaunched").exists() and not (root / "AppUpdateInProgress.json").exists():
                    break
                time.sleep(0.1)
            else:
                markers = [str(p.relative_to(root)) for p in root.rglob("*")
                           if p.name in {"ready", "authorized", "parent-exited", "failure", "reopened", "fixture-started", "AppUpdateInProgress.json"}]
                raise RuntimeError(f"Timed out waiting for the replacement app to acknowledge reopening. Markers: {markers}")
            assert parent.wait(timeout=5) == 0, "The original app did not exit normally"
            assert manual_launch_checked
            assert (root / "relaunched").read_text() == "2.0.0", "The wrong version reopened"
            receipt = json.loads((root / "AppUpdateResult.json").read_text())
            assert receipt["succeeded"] and receipt["version"] == "v2.0.0"
            assert not list(target.parent.glob(".CamiTune-previous-*")), "Backup was not cleaned up after reopening"
            assert not staged.parent.exists(), "Prepared update was not cleaned up after reopening"
            time.sleep(1.2)  # Let the fixture window finish its scheduled exit.
            print("PASS: native installer handoff, manual launch redirection, clean parent exit, installation, automatic reopen, acknowledgment, cleanup")
        finally:
            if parent.poll() is None:
                parent.terminate()
                parent.wait(timeout=5)
            if helper_pid:
                try:
                    os.kill(helper_pid, 15)
                except ProcessLookupError:
                    pass


if __name__ == "__main__":
    main()
