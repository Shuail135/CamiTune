import SwiftUI
import AppKit
import Darwin
import CoreImage
import Combine

private var isCamiTuneTestHost: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
}

private var isSpeakerSetupPreview: Bool {
#if DEBUG
    ProcessInfo.processInfo.arguments.contains("--speaker-setup-preview")
#else
    false
#endif
}

@main
enum CamiTuneLauncher {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--live-runtime-baseline"),
           CommandLine.arguments.count > index + 2 {
            let destination = CommandLine.arguments[index + 1]
            let silence = CommandLine.arguments[index + 2]
            Task { @MainActor in
                do { try await LiveRuntimeBaseline.capture(destination: destination, silence: silence); Darwin.exit(0) }
                catch { print("Live baseline failed: \(error.localizedDescription)"); Darwin.exit(1) }
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            Task { @MainActor in
                var failures = 0
                let cases = ProcessInfo.processInfo.environment["CAMITUNE_STAGE3_BASELINE_DIRECTORY"] == nil
                    ? DeveloperSelfTests.cases() : DeveloperSelfTests.presentationBenchmarkCases()
                for test in cases {
                    do {
                        let result = try await test.execute()
                        print("\(test.id) \(result.status.rawValue.uppercased()): \(result.summary)")
                        if result.status == .failed { failures += 1 }
                    } catch {
                        failures += 1
                        print("\(test.id) FAILED: \(error.localizedDescription)")
                    }
                }
                print("Self-tests complete: \(failures) failures")
                Darwin.exit(failures == 0 ? 0 : 1)
            }
            RunLoop.main.run()
            return
        }
#if DEBUG
        if isSpeakerSetupPreview { SpeakerSetupPreviewApp.main(); return }
#endif
        CamiTuneMain.main()
    }
}

struct CamiTuneMain: App {
    @NSApplicationDelegateAdaptor(CamiTuneAppDelegate.self) private var appDelegate
    @StateObject private var state: AppState

    init() {
        _state = StateObject(
            wrappedValue: CamiTunePresentationCoordinator.shared.state
        )
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView(state: state)
        } label: {
            CamiTuneMenuBarLabel(
                isActive: state.isActive
            )
        }
        .menuBarExtraStyle(.window)
        .commands {
            CamiTuneCommands(coordinator: CamiTunePresentationCoordinator.shared.commands,
                undo: state.undoCommands, showLicense: AppLicense.show)
        }
    }
}

private enum AppLicense {
    static func show() {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "CamiTune — GPL-3.0-only"
        alert.informativeText = "Copyright © 2026 CamiTune contributors. This program is free software and comes with ABSOLUTELY NO WARRANTY. The complete license and third-party notices are included in the application bundle and source repository."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }
}

private enum AppIcon {
    static let image: NSImage = {
#if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
#endif
        if let url = Bundle.main.url(forResource: "icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "CamiTune")
            ?? NSImage()
    }()

    static let activeMenuBarImage: NSImage = {
        menuBarImage(grayscale: false)
    }()

    static let inactiveMenuBarImage: NSImage = {
        menuBarImage(grayscale: true)
    }()

    private static func menuBarImage(grayscale: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)

        let result = NSImage(size: size)
        result.lockFocus()

        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1
        )

        result.unlockFocus()

        guard grayscale,
              let tiff = result.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let ciImage = CIImage(bitmapImageRep: bitmap),
              let filter = CIFilter(name: "CIColorControls")
        else {
            result.isTemplate = false
            return result
        }

        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)

        guard let output = filter.outputImage else {
            return result
        }

        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else {
            return result
        }

        let grayImage = NSImage(
            cgImage: cgImage,
            size: size
        )

        grayImage.isTemplate = false
        return grayImage
    }

    private static func menuBarImage(template: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let result = NSImage(size: size)
        result.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1
        )
        result.unlockFocus()
        result.isTemplate = template
        return result
    }
}

@MainActor
final class CamiTunePresentationCoordinator {
    static let shared = CamiTunePresentationCoordinator()

    let state: AppState = {
        guard isCamiTuneTestHost || isSpeakerSetupPreview else { return AppState() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CamiTuneTestHost-\(UUID())")
        let profiles = ProfileStore(storageURL: directory.appendingPathComponent("profiles.json"),
            userDefaults: UserDefaults(suiteName: "CamiTuneTestHost-\(UUID())")!)
        let audio = PerAppAudioController(settingsURL: directory.appendingPathComponent("apps.json"), monitorsRunningApplications: false)
        return AppState(profiles: profiles, perAppAudio: audio)
    }()
    lazy var commands: MainWindowCommandCoordinator = {
        let bridge = MainWindowCommandCoordinator()
        bridge.showMainWindow = { [weak self] in self?.showMainWindow() }
        bridge.resolveContext = { [weak self] selection, sidebar in
            guard let self else { return .init() }
            let profile: DeviceProfile?
            if case .profile(let id) = selection {
                profile = self.state.profiles.profiles.first { $0.id == id }
            } else { profile = nil }
            return .init(destination: selection, profileID: profile?.id,
                profileEnabled: profile?.isEnabled ?? false,
                profileActive: profile?.id == self.state.activeProfileID && self.state.isActive,
                mode: profile?.playbackMode,
                readiness: profile.map { profile in Dictionary(uniqueKeysWithValues:
                    profile.availablePlaybackModes.map { ($0, profile.playbackReadiness($0)) }) } ?? [:],
                mainWindowVisible: self.mainWindow?.isVisible == true && self.mainWindow?.isMiniaturized == false,
                modalActive: self.mainWindow?.attachedSheet != nil || NSApp.modalWindow != nil
                    || self.state.setupPresentation.isPresented
                    || self.state.profileConfirmations.showEnabledExplanation
                    || self.state.errorMessage != nil || self.state.updateChecker.isDownloadingUpdate,
                transitionInProgress: self.state.transitionInProgress || self.state.isSavingProfileSettings,
                sidebarVisible: sidebar)
        }
        bridge.performDomainAction = { [weak self] id, action in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.state.transitionInProgress, !self.state.isSavingProfileSettings,
                      let profile = self.state.profiles.profiles.first(where: { $0.id == id }) else { return }
                switch action {
                case .setEnabled(let enabled): await self.state.setProfileEnabled(id: id, enabled: enabled)
                case .setMode(let mode): await self.state.setPlaybackMode(profileID: id, mode: mode)
                case .setActive(let active):
                    if active {
                        guard profile.isEnabled else { return }
                        await self.state.activate(profile: profile)
                    } else if self.state.profiles.activationMode(for: profile) == .physicalOutput {
                        guard let window = self.mainWindow, window.attachedSheet == nil else { return }
                        let alert = NSAlert()
                        alert.messageText = "Deactivate CamiTune?"
                        alert.informativeText = "Activation Mode will change from Physical output to Profile audio device. Audio will return to the original physical output."
                        alert.addButton(withTitle: "Deactivate")
                        alert.addButton(withTitle: "Cancel")
                        alert.beginSheetModal(for: window) { [weak self] response in
                            guard response == .alertFirstButtonReturn else { return }
                            Task { @MainActor in
                                await self?.state.deactivateProfileFromMenu(profileID: id, physicalOutputConfirmed: true)
                            }
                        }
                    } else {
                        await self.state.deactivateProfileFromMenu(profileID: id, physicalOutputConfirmed: false)
                    }
                }
                self.commands.refresh()
            }
        }
        let publishers = [state.objectWillChange.eraseToAnyPublisher(),
            state.profiles.objectWillChange.eraseToAnyPublisher(),
            state.setupPresentation.objectWillChange.eraseToAnyPublisher(),
            state.profileConfirmations.objectWillChange.eraseToAnyPublisher(),
            state.updateChecker.objectWillChange.eraseToAnyPublisher()]
        Publishers.MergeMany(publishers).receive(on: RunLoop.main).sink { [weak bridge] _ in
            bridge?.refresh()
        }.store(in: &commandSubscriptions)
        return bridge
    }()
    private var commandSubscriptions: Set<AnyCancellable> = []
    private var mainWindow: NSWindow?
    private var mainWindowVisibilityObservers: [NSObjectProtocol] = []

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        let window: NSWindow
        if let mainWindow {
            window = mainWindow
        } else {
            let rootView = ContentView(state: state, commands: commands)
                .task { self.state.startAfterPresentation() }
            let controller = NSHostingController(rootView: rootView)
            let created = CamiTuneMainWindow(contentViewController: controller)
            created.title = "CamiTune"
            created.styleMask = [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ]
            created.minSize = NSSize(width: 800, height: 620)
            created.setContentSize(NSSize(width: 1_000, height: 700))
            created.isReleasedWhenClosed = false
            created.tabbingMode = .disallowed
            if !created.setFrameUsingName("CamiTuneMainWindow") {
                created.center()
            }
            created.setFrameAutosaveName("CamiTuneMainWindow")
            monitorPresentation(of: created)
            mainWindow = created
            window = created
        }
        window.makeKeyAndOrderFront(nil)
        state.setMainWindowPresentationActive(true)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.updatePresentation(for: window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func monitorPresentation(of window: NSWindow) {
        let center = NotificationCenter.default
        let willCloseNotification = NSWindow.willCloseNotification
        let names: [Notification.Name] = [
            NSWindow.willBeginSheetNotification,
            NSWindow.didEndSheetNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
            willCloseNotification
        ]
        mainWindowVisibilityObservers = names.map { name in
            let isCloseNotification = name == willCloseNotification
            return center.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let window = self.mainWindow else { return }
                    if isCloseNotification {
                        self.state.setMainWindowPresentationActive(false)
                        self.commands.refresh()
                    } else {
                        self.updatePresentation(for: window)
                    }
                }
            }
        }
    }

    private func updatePresentation(for window: NSWindow) {
        let isPresented = window.isVisible
            && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
        state.setMainWindowPresentationActive(isPresented)
        commands.refresh()
    }
}


@MainActor
final class CamiTuneMainWindow: NSWindow {
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        let editor = super.fieldEditor(createFlag, for: object)
        TextEditingCompatibility.prepare(editor)
        return editor
    }
}

/// SwiftUI sheets and popovers own windows that aren't CamiTuneMainWindow.
/// Prepare their field editors before AppKit starts text-selection tracking too.
@MainActor
final class TextEditingCompatibility: NSObject {
    private var eventMonitor: Any?

    static func prepare(_ editor: NSText?) {
        if #unavailable(macOS 14) {
            // The macOS 13 profile-rename hang was sampled inside TextKit 2's
            // NSTextSelectionNavigation. Accessing layoutManager opts into
            // Apple's TextKit 1 compatibility mode without replacing the editor.
            _ = (editor as? NSTextView)?.layoutManager
        }
    }

    func start() {
        guard #unavailable(macOS 14), eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            guard let window = event.window else { return event }
            Self.prepare(window.firstResponder as? NSTextView)
            if event.type != .keyDown, let content = window.contentView {
                let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                var target = content.hitTest(point)
                while let view = target {
                    if let editor = view as? NSTextView {
                        Self.prepare(editor)
                        break
                    }
                    if let field = view as? NSTextField, field.isEditable || field.isSelectable {
                        Self.prepare(window.fieldEditor(true, for: field))
                        break
                    }
                    target = view.superview
                }
            }
            // Preserve the original event and focus; AppKit handles the click.
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(editingDidBegin(_:)),
            name: NSControl.textDidBeginEditingNotification, object: nil)
    }

    @objc private func editingDidBegin(_ notification: Notification) {
        // AppKit posts this synchronously on the main thread. Also cover
        // editing initiated without a mouse or key event.
        Self.prepare((notification.object as? NSTextField)?.currentEditor())
    }

    func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        NotificationCenter.default.removeObserver(self)
        eventMonitor = nil
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        NotificationCenter.default.removeObserver(self)
    }
}

private struct CamiTuneMenuBarLabel: View {
    var isActive: Bool

    var body: some View {
        Image(nsImage: isActive ? AppIcon.activeMenuBarImage : AppIcon.inactiveMenuBarImage)
            .renderingMode(.original)
        .accessibilityLabel(isActive ? "CamiTune, processing active" : "CamiTune, processing inactive")
    }
}


final class CamiTuneAppDelegate: NSObject, NSApplicationDelegate {
    private static let showMainWindowNotification = Notification.Name(
        "local.camilla.app.show-main-window"
    )
    private var closeObserver: NSObjectProtocol?
    private var keyObserver: NSObjectProtocol?
    private var windowDelegateProxies: [ObjectIdentifier: WindowCloseDelegateProxy] = [:]
    private let closeHintKey = "hideCloseKeepsRunningHint"
    private var instanceLockFileDescriptor: Int32 = -1
    private var rejectedDuplicateInstance = false
    @MainActor private lazy var textEditingCompatibility = TextEditingCompatibility()

    func applicationWillFinishLaunching(_ notification: Notification) {
        textEditingCompatibility.start()
        guard !isCamiTuneTestHost else { return }
        let supportDirectory = CamiTunePaths.supportDirectory
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let lockURL = supportDirectory.appendingPathComponent("application.lock")
            let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { return }

            guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
                Darwin.close(descriptor)
                rejectedDuplicateInstance = true
                activateExistingInstance()
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return
            }

            _ = Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            instanceLockFileDescriptor = descriptor
        } catch {
            // Failure to create a lock must not make the audio application unusable.
            // Normal macOS bundle launching still coalesces duplicate launches.
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !rejectedDuplicateInstance, !isCamiTuneTestHost else { return }
        NSApp.applicationIconImage = AppIcon.image
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showMainWindowRequested(_:)),
            name: Self.showMainWindowNotification,
            object: nil
        )
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  window.title == "CamiTune" else { return }
            self?.mainWindowDidClose(window)
        }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  window.title == "CamiTune" else { return }
            NSApp.setActivationPolicy(.regular)
            self?.installCloseDelegate(on: window)
        }
        for window in NSApp.windows where window.title == "CamiTune" {
            installCloseDelegate(on: window)
        }
        CamiTunePresentationCoordinator.shared.showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        CamiTunePresentationCoordinator.shared.showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        textEditingCompatibility.stop()
        DistributedNotificationCenter.default().removeObserver(self)
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        if instanceLockFileDescriptor >= 0 {
            _ = Darwin.lockf(instanceLockFileDescriptor, F_ULOCK, 0)
            Darwin.close(instanceLockFileDescriptor)
            instanceLockFileDescriptor = -1
        }
    }

    private func activateExistingInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.showMainWindowNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != currentPID })?
            .activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    @objc private func showMainWindowRequested(_ notification: Notification) {
        Task { @MainActor in
            CamiTunePresentationCoordinator.shared.showMainWindow()
        }
    }

    private func installCloseDelegate(on window: NSWindow) {
        let key = ObjectIdentifier(window)
        if let proxy = windowDelegateProxies[key], window.delegate === proxy { return }
        let proxy = WindowCloseDelegateProxy(original: window.delegate) { [weak self] in
            self?.confirmWindowClose() ?? true
        }
        windowDelegateProxies[key] = proxy
        window.delegate = proxy
    }

    private func confirmWindowClose() -> Bool {
        guard !UserDefaults.standard.bool(forKey: closeHintKey) else { return true }
        let alert = NSAlert()
        alert.messageText = "CamiTune will keep running"
        alert.informativeText = "Closing this window keeps System-wide EQ and audio processing active. Use the menu-bar icon to reopen the app or quit it completely."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show this again"
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: closeHintKey)
        }
        return true
    }

    private func mainWindowDidClose(_ window: NSWindow) {
        windowDelegateProxies.removeValue(forKey: ObjectIdentifier(window))
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private final class WindowCloseDelegateProxy: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    private let shouldClose: () -> Bool

    init(original: NSWindowDelegate?, shouldClose: @escaping () -> Bool) {
        self.original = original
        self.shouldClose = shouldClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.attachedSheet == nil, shouldClose() else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if original?.responds(to: selector) == true { return original }
        return super.forwardingTarget(for: selector)
    }
}
