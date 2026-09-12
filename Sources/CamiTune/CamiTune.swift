import SwiftUI
import AppKit
import Darwin
import CoreImage

@main
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
            CommandGroup(after: .appInfo) {
                Button("License & Warranty") { AppLicense.show() }
                Divider()
                Button("Recheck Audio Devices") {
                    Task { await state.coreAudio.refreshWithoutBlockingUI() }
                }
            }
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

    let state = AppState()
    private var mainWindow: NSWindow?
    private var mainWindowVisibilityObservers: [NSObjectProtocol] = []

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        let window: NSWindow
        if let mainWindow {
            window = mainWindow
        } else {
            let rootView = ContentView(state: state)
                .task { self.state.startAfterPresentation() }
            let controller = NSHostingController(rootView: rootView)
            let created = NSWindow(contentViewController: controller)
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

    func applicationWillFinishLaunching(_ notification: Notification) {
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
        guard !rejectedDuplicateInstance else { return }
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
        guard shouldClose() else { return false }
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
