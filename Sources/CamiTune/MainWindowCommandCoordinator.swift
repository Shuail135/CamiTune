import AppKit
import Combine
import SwiftUI

/// App-domain commands for the manually hosted main window. Only IDs and
/// presentation facts cross this bridge; AppState remains the runtime owner.
@MainActor
final class MainWindowCommandCoordinator: ObservableObject {
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

    @discardableResult
    func send(_ intent: Intent) -> Bool {
        refresh()
        guard context.canNavigate, request == nil else { return false }
        switch intent {
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

struct CamiTuneCommands: Commands {
    @ObservedObject var coordinator: MainWindowCommandCoordinator
    @ObservedObject var undo: UndoCommandRouter
    var showLicense: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(undo.undoMenuTitle) { undo.performUndo() }
                .keyboardShortcut("z", modifiers: .command).disabled(!undo.canUndo)
            Button(undo.redoMenuTitle) { undo.performRedo() }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!undo.canRedo)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { coordinator.send(.settings) }
                .keyboardShortcut(",")
                .disabled(!coordinator.context.canNavigate)
        }
        CommandGroup(after: .appInfo) {
            Button("License & Warranty", action: showLicense)
            Button("Open Setup…") { coordinator.send(.openSetup) }
                .disabled(!coordinator.context.canNavigate)
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Output…") { coordinator.send(.addOutput) }
                .keyboardShortcut("n")
                .disabled(!coordinator.context.canNavigate)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Window") { NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil) }
                .keyboardShortcut("w")
                .disabled(!coordinator.context.mainWindowVisible || coordinator.context.modalActive)
        }
        CommandGroup(replacing: .sidebar) {
            Button(coordinator.context.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                coordinator.send(.toggleSidebar)
            }.disabled(!coordinator.context.canNavigate)
            Divider()
            Button("App Audio") { coordinator.send(.appAudio) }
                .disabled(!coordinator.context.canNavigate)
            Button("Settings") { coordinator.send(.settings) }
                .disabled(!coordinator.context.canNavigate)
        }
        CommandMenu("Profile") {
            Button("Rename Profile") {
                if let id = coordinator.context.profileID { coordinator.send(.rename(id)) }
            }.disabled(!coordinator.context.canEditProfile)
            Button(coordinator.context.enableTitle) {
                coordinator.perform(.setEnabled(!coordinator.context.profileEnabled))
            }.disabled(!coordinator.context.canEditProfile)
            Button(coordinator.context.activationTitle) {
                coordinator.perform(.setActive(!coordinator.context.profileActive))
            }.disabled(!coordinator.context.canActivate)
            Button("Profile Settings…") {
                if let id = coordinator.context.profileID { coordinator.send(.profileSettings(id)) }
            }.disabled(!coordinator.context.canEditProfile)
            Divider()
            Menu("Mode") {
                ForEach(PlaybackMode.allCases, id: \.self) { mode in
                    Toggle(isOn: Binding(get: { coordinator.context.mode == mode }, set: { selected in
                        if selected { coordinator.perform(.setMode(mode)) }
                    })) {
                        Label(mode.compactDisplayName, systemImage: mode.systemImageName)
                    }
                    .disabled(!coordinator.context.canSelectMode(mode))
                    .help(coordinator.context.readiness[mode]?.reason ?? mode.compactDisplayName)
                }
            }
        }
        CommandGroup(replacing: .help) {
            Button("Open Setup…") { coordinator.send(.openSetup) }
                .disabled(!coordinator.context.canNavigate)
        }
    }
}
