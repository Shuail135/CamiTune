import CamiTuneAudio
import CamiTuneDomain
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
    @MainActor
    static func main() {
        if AppUpdateInstaller.runIfRequested() { return }
        if AppUpdateInstaller.redirectLaunchToInstaller() { return }
        // AppKit's native tooltip delay is in milliseconds. Register before
        // creating UI; this process-local default preserves explicit preferences.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 250])
        if let index = CommandLine.arguments.firstIndex(of: "--pcm-delivery-baseline"), CommandLine.arguments.count > index + 2 {
            let destination = CommandLine.arguments[index + 1], silence = CommandLine.arguments[index + 2]
            let showsUI = ProcessInfo.processInfo.environment["CAMITUNE_DELIVERY_UI"] == "1"
            if showsUI { NSApplication.shared.setActivationPolicy(.regular) }
            Task { @MainActor in
                do { try await LiveRuntimeBaseline.capture(destination: destination, silence: silence, deliveryEvidence: true); Darwin.exit(0) }
                catch { print("PCM delivery baseline failed: \(error.localizedDescription)"); Darwin.exit(1) }
            }
            if showsUI { NSApplication.shared.run() }
            else { RunLoop.main.run() }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--timeline-policy-soak"), CommandLine.arguments.count > index + 2 {
            let destination = CommandLine.arguments[index + 1], silence = CommandLine.arguments[index + 2]
            Task { @MainActor in
                do { try await LiveRuntimeBaseline.policySoak(destination: destination, silence: silence); Darwin.exit(0) }
                catch { print("Policy soak failed: \(error.localizedDescription)"); Darwin.exit(1) }
            }
            RunLoop.main.run(); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--replay-timeline-policy"), CommandLine.arguments.count > index + 1 {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                let document = try JSONDecoder().decode(TimelinePolicyTraceDocument.self, from: data)
                let override = CommandLine.arguments.count > index + 2
                    ? try JSONDecoder().decode(TimelineReorderPolicyConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 2]))) : nil
                let result = document.replay(configuration: override)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(result), as: UTF8.self))
                Darwin.exit(result.decisionMismatches == 0 && document.droppedEvents == 0 ? 0 : 1)
            } catch { print("Policy replay failed: \(error.localizedDescription)"); Darwin.exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--live-route-handoff"), CommandLine.arguments.count > index + 2 {
            let destination = CommandLine.arguments[index + 1], silence = CommandLine.arguments[index + 2]
            Task { @MainActor in
                do { try await LiveRuntimeBaseline.routeHandoff(destination: destination, silence: silence); Darwin.exit(0) }
                catch { print("Live handoff failed: \(error.localizedDescription)"); Darwin.exit(1) }
            }
            RunLoop.main.run(); return
        }
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
        let localTestCommands = ["--ui-self-test", "--ui-app-self-test", "--plugin-host-self-test", "--replay-producer-completion"]
        if CommandLine.arguments.contains(where: localTestCommands.contains) {
            print("Regression runners live in the local Tests folder. Use CAMITUNE_LOCAL_TESTS=diagnostics swift test.")
            Darwin.exit(2)
        }
        if CommandLine.arguments.contains("--self-test") {
            Task { @MainActor in
                var failures = 0
                let cases = DeveloperSelfTests.cases()
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
                    || self.state.errorMessage != nil || self.state.updateChecker.isPresentingUpdate,
                transitionInProgress: self.state.transitionInProgress,
                sidebarVisible: sidebar)
        }
        bridge.performDomainAction = { [weak self] id, action in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.state.transitionInProgress,
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
            // This window has an explicit minimum size. Asking SwiftUI to
            // derive it from every offscreen editor repeats the entire page's
            // intrinsic layout whenever a meter or field changes.
            controller.sizingOptions = []
            let created = CamiTuneMainWindow(contentViewController: controller)
            created.configureContentLayout()
            created.configureSidebarToolbar(commands: commands)
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
final class CamiTuneMainWindow: NSWindow, NSToolbarDelegate {
    static let minimumContentSize = NSSize(width: 800, height: 620)
    private static let sidebarItemIdentifier = NSToolbarItem.Identifier("CamiTune.ToggleSidebar")
    private static let titleItemIdentifier = NSToolbarItem.Identifier("CamiTune.WindowTitle")
    private weak var sidebarCommands: MainWindowCommandCoordinator?
    private var sidebarSubscription: AnyCancellable?
    private var sidebarToolbarItem: NSToolbarItem?

    func configureSidebarToolbar(commands: MainWindowCommandCoordinator) {
        sidebarCommands = commands
        let toolbar = NSToolbar(identifier: "CamiTune.MainWindow")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.titleItemIdentifier]
        self.toolbar = toolbar
        toolbarStyle = .unifiedCompact
        sidebarSubscription = commands.$context.sink { [weak self] context in
            self?.updateSidebarToolbar(context)
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarItemIdentifier, .sidebarTrackingSeparator, Self.titleItemIdentifier, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == Self.titleItemIdentifier {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let label = NSTextField(labelWithString: "CamiTune")
            label.font = .titleBarFont(ofSize: 0)
            label.textColor = .labelColor
            let title = NSStackView(views: [label])
            title.orientation = .horizontal
            title.alignment = .centerY
            title.spacing = 6
            item.view = title
            item.label = "CamiTune"
            item.autovalidates = false
            item.isEnabled = true
            item.visibilityPriority = .high
            return item
        }
        guard itemIdentifier == Self.sidebarItemIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar")
            .flatMap { $0.withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) }
        item.image?.size = NSSize(width: 16, height: 16)
        // Keep this item before the sidebar separator, beside the traffic lights.
        item.isNavigational = false
        item.toolTip = ""
        item.target = self
        item.action = #selector(toggleProfileSidebar(_:))
        item.autovalidates = false
        sidebarToolbarItem = item
        if let context = sidebarCommands?.context { updateSidebarToolbar(context) }
        return item
    }

    private func updateSidebarToolbar(_ context: MainWindowCommandCoordinator.Context) {
        sidebarToolbarItem?.label = context.sidebarToggleTitle
        sidebarToolbarItem?.paletteLabel = context.sidebarToggleTitle
        sidebarToolbarItem?.isEnabled = context.canToggleSidebar
    }

    @objc private func toggleProfileSidebar(_ sender: Any?) {
        sidebarCommands?.send(.toggleSidebar)
    }

    func configureContentLayout() {
        title = "CamiTune"
        // The sidebar material reaches the top of the window. Its tracking
        // separator keeps the app title in the detail pane, past the sidebar.
        styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        contentMinSize = Self.minimumContentSize
        if let contentView {
            // AppKit ignores contentMinSize for Auto Layout windows. These two
            // constant constraints enforce the same content minimum without
            // asking SwiftUI to measure every offscreen editor on each update.
            NSLayoutConstraint.activate([
                contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumContentSize.width),
                contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumContentSize.height)
            ])
        }
    }

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
            Self.prepare(for: event, in: window)
            // Preserve the original event and focus; AppKit handles the click.
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(editingDidBegin(_:)),
            name: NSControl.textDidBeginEditingNotification, object: nil)
    }

    static func prepare(for event: NSEvent, in window: NSWindow) {
        prepare(window.firstResponder as? NSTextView)
        if event.type != .keyDown, let content = window.contentView {
            let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            var target = content.hitTest(point)
            while let view = target {
                if let editor = view as? NSTextView {
                    prepare(editor)
                    break
                }
                if let field = view as? NSTextField, field.isEditable || field.isSelectable {
                    prepare(window.fieldEditor(true, for: field))
                    break
                }
                target = view.superview
            }
        }
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
        AppAppearance.restore()
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
        AppUpdateInstaller.acknowledgeRelaunch()
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
