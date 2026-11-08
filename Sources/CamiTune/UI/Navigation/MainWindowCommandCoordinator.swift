import CamiTuneDomain
import AppKit
import Combine
import SwiftUI

/// App-domain commands for the manually hosted main window. Only IDs and
/// presentation facts cross this bridge; AppState remains the runtime owner.
@MainActor
final class MainWindowCommandCoordinator: ObservableObject {
    @Published var appAudioRevealProfileID: UUID?
    @Published var settingsCategory = "General"
    struct Context: Equatable {
        var destination: SidebarDestination = .empty
        var profileID: UUID?
        var profileEnabled = false
        var profileActive = false
        var mode: PlaybackMode?
        var readiness: [PlaybackMode: PlaybackModeReadiness] = [:]
        var mainWindowVisible = false
        var modalActive = false
        var transitionInProgress = false
        var sidebarVisible = true

        var canNavigate: Bool { !modalActive && !transitionInProgress }
        var canToggleSidebar: Bool { mainWindowVisible && canNavigate }
        var sidebarToggleTitle: String { sidebarVisible ? "Hide Sidebar" : "Show Sidebar" }
        var canEditProfile: Bool {
            guard let profileID else { return false }
            return canNavigate && mainWindowVisible && destination == .profile(profileID)
        }
        var canActivate: Bool { canEditProfile && (profileActive || profileEnabled) }
        var enableTitle: String { profileEnabled ? "Disable Profile" : "Enable Profile" }
        var activationTitle: String { profileActive ? "Deactivate" : "Activate" }
        func canSelectMode(_ mode: PlaybackMode) -> Bool {
            canEditProfile && readiness[mode]?.isReady == true
        }
    }

    enum Intent: Equatable {
        case settings, appAudio, addOutput, openSetup, toggleSidebar
        case rename(UUID), profileSettings(UUID)
    }
    struct Request: Equatable, Identifiable {
        let id = UUID()
        let intent: Intent
    }
    enum DomainAction: Equatable {
        case setEnabled(Bool), setActive(Bool), setMode(PlaybackMode)
    }

    @Published private(set) var context = Context()
    @Published private(set) var request: Request?
    var selection: SidebarDestination = .empty { didSet { refresh() } }
    var sidebarVisible = true { didSet { refresh() } }
    var modalReservation = false { didSet { refresh() } }
    var resolveContext: (SidebarDestination, Bool) -> Context = { selection, sidebar in
        Context(destination: selection, sidebarVisible: sidebar)
    }
    var showMainWindow: () -> Void = {}
    var performDomainAction: (UUID, DomainAction) -> Void = { _, _ in }

    func refresh() {
        var next = resolveContext(selection, sidebarVisible)
        next.modalActive = next.modalActive || modalReservation
        if next != context { context = next }
    }

    func appAudioDestination(in store: ProfileStore, activeProfileID: UUID?) -> SidebarDestination {
        let profile = [store.selectedProfileID, activeProfileID].compactMap { id in
            store.profiles.first { $0.id == id }
        }.first ?? store.profiles.first
        if let profile, store.effectiveLayout(for: profile).editorSections(for: profile).contains(.appAudio) {
            appAudioRevealProfileID = profile.id
            return .profile(profile.id)
        }
        appAudioRevealProfileID = nil
        settingsCategory = "App Audio"
        return .settings
    }

    @discardableResult
    func send(_ intent: Intent) -> Bool {
        refresh()
        guard context.canNavigate, request == nil else { return false }
        switch intent {
        case .toggleSidebar:
            guard context.canToggleSidebar else { return false }
        case .rename(let id), .profileSettings(let id):
            guard context.canEditProfile, context.profileID == id else { return false }
        default: break
        }
        // Reserve before showing the window: repeated shortcuts cannot race
        // the asynchronous output discovery or sheet attachment.
        switch intent {
        case .addOutput, .profileSettings: modalReservation = true
        default: break
        }
        showMainWindow()
        request = Request(intent: intent)
        return true
    }

    func consume(_ id: UUID) {
        if request?.id == id {
            request = nil
        } else {
            // @Published delivers before storing the new value. A view can
            // acknowledge it synchronously from onReceive during that delivery.
            DispatchQueue.main.async { [weak self] in
                guard self?.request?.id == id else { return }
                self?.request = nil
            }
        }
    }

    func perform(_ action: DomainAction) {
        refresh()
        guard context.canEditProfile, let id = context.profileID else { return }
        switch action {
        case .setMode(let mode): guard context.canSelectMode(mode) else { return }
        case .setActive: guard context.canActivate else { return }
        case .setEnabled: break
        }
        performDomainAction(id, action)
    }
}

/// The menu bar and the manually hosted windows share the same command owner.
/// Native validation runs when a menu opens or a shortcut is dispatched.
@MainActor
final class CamiTuneCommands {
    private let coordinator: MainWindowCommandCoordinator
    private let undo: UndoCommandRouter
    private let showLicense: () -> Void
    private let checkForUpdates: () -> Void
    private let showChangelog: () -> Void

    init(coordinator: MainWindowCommandCoordinator, undo: UndoCommandRouter,
         showLicense: @escaping () -> Void, checkForUpdates: @escaping () -> Void,
         showChangelog: @escaping () -> Void) {
        self.coordinator = coordinator
        self.undo = undo
        self.showLicense = showLicense
        self.checkForUpdates = checkForUpdates
        self.showChangelog = showChangelog
    }

    func install() {
        let root = NSMenu()
        let app = submenu("CamiTune", in: root)
        standard("About CamiTune", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), in: app)
        item("Check for Updates…", in: app, enabled: { $0.canNavigate }, action: checkForUpdates)
        app.addItem(.separator())
        item("License & Warranty", in: app, action: showLicense)
        item("Open Setup…", in: app, enabled: { $0.canNavigate }) { self.coordinator.send(.openSetup) }
        app.addItem(.separator())
        item("Settings…", key: ",", in: app, enabled: { $0.canNavigate }) { self.coordinator.send(.settings) }
        app.addItem(.separator())
        let services = submenu("Services", in: app)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        standard("Hide CamiTune", action: #selector(NSApplication.hide(_:)), key: "h", in: app)
        standard("Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], in: app)
        standard("Show All", action: #selector(NSApplication.unhideAllApplications(_:)), in: app)
        app.addItem(.separator())
        standard("Quit CamiTune", action: #selector(NSApplication.terminate(_:)), key: "q", in: app)

        let file = submenu("File", in: root)
        item("Add Output…", key: "n", in: file, enabled: { $0.canNavigate }) { self.coordinator.send(.addOutput) }
        item("Close Window", key: "w", in: file, enabled: { $0.mainWindowVisible && !$0.modalActive }) {
            NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
        }
        let edit = submenu("Edit", in: root)
        item("Undo", key: "z", in: edit, update: { $0.title = self.undo.undoMenuTitle() },
             enabled: { _ in self.undo.canUndo() }) { self.undo.performUndo() }
        item("Redo", key: "z", modifiers: [.command, .shift], in: edit,
             update: { $0.title = self.undo.redoMenuTitle() }, enabled: { _ in self.undo.canRedo() }) { self.undo.performRedo() }
        edit.addItem(.separator())
        standard("Cut", action: #selector(NSText.cut(_:)), key: "x", in: edit)
        standard("Copy", action: #selector(NSText.copy(_:)), key: "c", in: edit)
        standard("Paste", action: #selector(NSText.paste(_:)), key: "v", in: edit)
        standard("Delete", action: #selector(NSText.delete(_:)), in: edit)
        standard("Select All", action: #selector(NSText.selectAll(_:)), key: "a", in: edit)

        let view = submenu("View", in: root)
        item("Hide Sidebar", key: "s", modifiers: [.command, .control], in: view,
             update: { $0.title = self.coordinator.context.sidebarToggleTitle }, enabled: { $0.canToggleSidebar }) {
            self.coordinator.send(.toggleSidebar)
        }
        view.addItem(.separator())
        item("App Audio", in: view, enabled: { $0.canNavigate }) { self.coordinator.send(.appAudio) }
        item("Settings", in: view, enabled: { $0.canNavigate }) { self.coordinator.send(.settings) }
        view.addItem(.separator())
        standard("Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.control, .command], in: view)

        let profile = submenu("Profile", in: root)
        item("Rename Profile", in: profile, enabled: { $0.canEditProfile }) {
            if let id = self.coordinator.context.profileID { self.coordinator.send(.rename(id)) }
        }
        item("Enable Profile", in: profile, update: { $0.title = self.coordinator.context.enableTitle }, enabled: { $0.canEditProfile }) {
            self.coordinator.perform(.setEnabled(!self.coordinator.context.profileEnabled))
        }
        item("Activate", in: profile, update: { $0.title = self.coordinator.context.activationTitle }, enabled: { $0.canActivate }) {
            self.coordinator.perform(.setActive(!self.coordinator.context.profileActive))
        }
        item("Profile Settings…", in: profile, enabled: { $0.canEditProfile }) {
            if let id = self.coordinator.context.profileID { self.coordinator.send(.profileSettings(id)) }
        }
        profile.addItem(.separator())
        let modes = submenu("Mode", in: profile)
        for mode in PlaybackMode.allCases {
            item(mode.compactDisplayName, in: modes, update: {
                $0.state = self.coordinator.context.mode == mode ? .on : .off
                $0.image = NSImage(systemSymbolName: mode.systemImageName, accessibilityDescription: nil)
                $0.toolTip = self.coordinator.context.readiness[mode]?.reason
            }, enabled: { $0.canSelectMode(mode) }) { self.coordinator.perform(.setMode(mode)) }
        }
        let window = submenu("Window", in: root)
        standard("Minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m", in: window)
        standard("Zoom", action: #selector(NSWindow.performZoom(_:)), in: window)
        window.addItem(.separator())
        standard("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), in: window)
        NSApp.windowsMenu = window
        let help = submenu("Help", in: root)
        item("Open Changelog", in: help, action: showChangelog)
        item("Open Setup…", in: help, enabled: { $0.canNavigate }) { self.coordinator.send(.openSetup) }
        NSApp.helpMenu = help
        NSApp.mainMenu = root
    }

    private func submenu(_ title: String, in menu: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        menu.addItem(item)
        return submenu
    }

    private func standard(_ title: String, action: Selector, key: String = "",
                          modifiers: NSEvent.ModifierFlags = .command, in menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
    }

    private func item(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                      in menu: NSMenu, update: @escaping (NSMenuItem) -> Void = { _ in },
                      enabled: @escaping (MainWindowCommandCoordinator.Context) -> Bool = { _ in true },
                      action: @escaping () -> Void) {
        let item = ValidatedCommandItem(title: title, action: nil, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = item
        item.action = #selector(ValidatedCommandItem.invoke(_:))
        item.refresh = { [coordinator] item in
            coordinator.refresh()
            update(item)
            return enabled(coordinator.context)
        }
        item.perform = action
        menu.addItem(item)
    }
}

@MainActor
private final class ValidatedCommandItem: NSMenuItem, NSMenuItemValidation {
    var refresh: (NSMenuItem) -> Bool = { _ in true }
    var perform: () -> Void = {}
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { refresh(menuItem) }
    @objc func invoke(_ sender: Any?) { if refresh(self) { perform() } }
}
