import SwiftUI
import AppKit
import Darwin

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
            CamillaMenuBarView(state: state)
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
        menuBarImage(template: false)
    }()

    static let inactiveMenuBarImage: NSImage = {
        menuBarImage(template: true)
    }()

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
private final class CamiTunePresentationCoordinator {
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

private struct CamillaMenuBarView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            PerAppMenuBarControls(controller: state.perAppAudio)
            Divider()

            HStack(spacing: 8) {
                Button {
                    CamiTunePresentationCoordinator.shared.showMainWindow()
                    Task { await state.updateChecker.checkAfterReminderIfNeeded() }
                } label: {
                    Label("Show CamiTune", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .frame(width: 18)
                }
                .buttonStyle(.bordered)
                .help("Quit CamiTune")
                .accessibilityLabel("Quit CamiTune")
                .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 300)
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

private struct PerAppMenuBarControls: View {
    @ObservedObject var controller: PerAppAudioController

    private var activeApplications: [PerAppAudioApplication] {
        controller.applications.filter(\.isActive)
    }

    var body: some View {
        VStack(alignment: .center, spacing: 9) {
            Text("Application Volume").font(.subheadline.bold())
            if activeApplications.isEmpty {
                Text("No eligible applications are running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(activeApplications) { application in
                            VStack(spacing: 8) {
                                Button {
                                    controller.setMuted(
                                        !application.settings.isMuted,
                                        for: application.id
                                    )
                                } label: {
                                    ZStack(alignment: .bottomTrailing) {
                                        Image(nsImage: PerAppIconCache.icon(for: application))
                                            .resizable()
                                            .frame(width: 32, height: 32)
                                            .opacity(application.settings.isMuted ? 0.45 : 1)
                                        if application.settings.isMuted {
                                            Image(systemName: "speaker.slash.fill")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(3)
                                                .background(.red, in: Circle())
                                                .offset(x: 3, y: 3)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .help(
                                    application.settings.isMuted
                                        ? "Unmute \(application.displayName)"
                                        : "Mute \(application.displayName)"
                                )

                                VerticalMeteredApplicationVolumeSlider(
                                    volume: application.settings.volume,
                                    level: application.level,
                                    isMuted: application.settings.isMuted,
                                    onVolumeChange: { volume, interactionFinished in
                                        controller.setVolume(
                                            volume,
                                            for: application.id,
                                            interactionFinished: interactionFinished
                                        )
                                    }
                                )
                                .frame(width: 28, height: 126)
                                .help(
                                    "\(application.displayName) volume: "
                                        + "\(Int((application.settings.volume * 100).rounded()))%"
                                )
                            }
                            .frame(width: 48)
                            .padding(.vertical, 8)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(.horizontal, 1)
                    .frame(minWidth: 270, alignment: .center)
                }
                .frame(height: 184)
            }
            Text("Click an app icon to mute. Menu-bar apps appear after producing audio; per-app EQ remains in the main window.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .onAppear {
            controller.setMeterPresentationActive(true, source: "menu")
        }
        .onDisappear {
            controller.setMeterPresentationActive(false, source: "menu")
        }
    }
}

private struct VerticalMeteredApplicationVolumeSlider: View {
    var volume: Double
    var level: Double
    var isMuted: Bool
    var onVolumeChange: (Double, Bool) -> Void
    @State private var interactionVolume: Double?

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 9
            let trackWidth: CGFloat = 7
            let track = CGRect(
                x: (geometry.size.width - trackWidth) / 2,
                y: inset,
                width: trackWidth,
                height: max(1, geometry.size.height - 2 * inset)
            )
            let meterAmount = isMuted ? 0 : min(1, max(0, level))
            let volumeAmount = min(1, max(0, interactionVolume ?? volume))
            let thumbY = track.maxY - track.height * volumeAmount
            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: track.width, height: track.height)
                    .position(x: track.midX, y: track.midY)
                Capsule()
                    .fill(.green)
                    .frame(width: track.width, height: track.height)
                    .scaleEffect(x: 1, y: meterAmount, anchor: .bottom)
                    .position(x: track.midX, y: track.midY)
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Circle().stroke(Color.primary.opacity(0.75), lineWidth: 1.5))
                    .frame(width: 17, height: 17)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .position(x: track.midX, y: thumbY)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(
                .linear(duration: UIRenderPerformance.animatedLevelTransitionDuration),
                value: meterAmount
            )
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { value in
                let adjusted = adjustedVolume(for: value.location.y, in: track)
                interactionVolume = adjusted
                onVolumeChange(adjusted, false)
            }.onEnded { value in
                let adjusted = adjustedVolume(for: value.location.y, in: track)
                interactionVolume = adjusted
                onVolumeChange(adjusted, true)
                DispatchQueue.main.async { interactionVolume = nil }
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Application volume")
        .accessibilityValue("\(Int(((interactionVolume ?? volume) * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let current = interactionVolume ?? volume
            let next: Double
            switch direction {
            case .increment: next = min(1, current + 0.01)
            case .decrement: next = max(0, current - 0.01)
            @unknown default: return
            }
            interactionVolume = next
            onVolumeChange(next, true)
            DispatchQueue.main.async { interactionVolume = nil }
        }
    }

    private func adjustedVolume(for y: CGFloat, in track: CGRect) -> Double {
        let ratio = min(1, max(0, (track.maxY - y) / track.height))
        return Double((ratio * 100).rounded()) / 100
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
