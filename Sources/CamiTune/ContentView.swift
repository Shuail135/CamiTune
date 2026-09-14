import SwiftUI
import Foundation

enum SidebarDestination: Hashable, Sendable {
    case empty, applications, settings, profile(UUID)

    var storageValue: String {
        switch self {
        case .empty: return "empty"
        case .applications: return "applications"
        case .settings: return "settings"
        case .profile(let id): return id.uuidString
        }
    }

    static func restore(_ saved: String?, profileIDs: Set<UUID>, fallbackProfileID: UUID?) -> Self {
        switch saved {
        case "applications": return .applications
        case "settings", "global-settings", "default-profiles": return .settings
        default:
            if let saved, let id = UUID(uuidString: saved), profileIDs.contains(id) { return .profile(id) }
            if let fallbackProfileID, profileIDs.contains(fallbackProfileID) { return .profile(fallbackProfileID) }
            return .empty
        }
    }
}

@MainActor
struct ContentView: View {
    let state: AppState
    @ObservedObject var commands: MainWindowCommandCoordinator
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var discoveringOutput = false

    @State private var selection: SidebarDestination
    @State private var showingOutputPicker = false
    @State private var pendingOutputUID: String?

    init(state: AppState, commands: MainWindowCommandCoordinator? = nil) {
        self.commands = commands ?? MainWindowCommandCoordinator()
        self.state = state
        let saved = UserDefaults.standard.string(forKey: "lastSidebarSelection")
        let restored = SidebarDestination.restore(saved,
            profileIDs: Set(state.profiles.profiles.map(\.id)),
            fallbackProfileID: state.profiles.selectedProfileID)
        self._selection = State(initialValue: restored)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                state: state,
                profileStore: state.profiles,
                selection: $selection,
                onAddOutput: beginAddingOutput
            )
        } detail: {
            ContentDetailView(
                state: state,
                profileStore: state.profiles,
                coreAudio: state.coreAudio,
                selection: selection
            )
        }
        .environmentObject(commands)
        .onAppear { commands.selection = selection }
        .onChange(of: columnVisibility) { commands.sidebarVisible = $0 != .detailOnly }
        .onReceive(commands.$request) { request in
            guard let request else { return }
            switch request.intent {
            case .settings: selection = .settings
            case .appAudio: selection = .applications
            case .addOutput: Task { await beginAddingOutput() }
            case .openSetup:
                commands.settingsCategory = "Drivers & Components"
                selection = .settings
            case .toggleSidebar: columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            case .rename, .profileSettings: return // The selected editor owns inline edit and its settings sheet.
            }
            commands.consume(request.id)
        }
        .onChange(of: showingOutputPicker) { if !$0 { commands.modalReservation = false } }
        .frame(minWidth: 800, minHeight: 620)
        .onChange(of: selection) { newSelection in
            commands.selection = newSelection
            UserDefaults.standard.set(newSelection.storageValue, forKey: "lastSidebarSelection")
            if case .profile(let id) = newSelection {
                state.profiles.selectedProfileID = id
            }
        }
        .sheet(isPresented: $showingOutputPicker) {
            AddOutputProfileSheet(state: state, initialUID: pendingOutputUID,
                onCancel: cancelAddingOutput) { id in
                    selection = .profile(id)
                    showingOutputPicker = false
                    pendingOutputUID = nil
                }
        }
        .modifier(SetupPresentationModifier(state: state, presentation: state.setupPresentation))
        .modifier(ProfileConfirmationModifier(presentation: state.profileConfirmations, store: state.profiles))
        .modifier(AppErrorPresentationModifier(state: state))
        .modifier(AppUpdatePresentationModifier(updateChecker: state.updateChecker))
    }

    private func beginAddingOutput() async {
        guard !discoveringOutput, !showingOutputPicker else { return }
        discoveringOutput = true
        commands.modalReservation = true
        defer { discoveringOutput = false }
        // The HAL/device scan itself runs off-main inside
        // refreshWithoutBlockingUI(); only the small state update returns here.
        await state.coreAudio.refreshWithoutBlockingUI()
        let devices = state.coreAudio.physicalOutputDevices
        pendingOutputUID = devices.first(where: {
            $0.id == state.coreAudio.defaultOutputUID
        })?.id ?? devices.first?.id
        showingOutputPicker = true
    }

    private func cancelAddingOutput() {
        showingOutputPicker = false
        pendingOutputUID = nil
    }

}
