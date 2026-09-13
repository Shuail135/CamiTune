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

    @State private var selection: SidebarDestination
    @State private var showingOutputPicker = false
    @State private var pendingOutputUID: String?

    init(state: AppState) {
        self.state = state
        let saved = UserDefaults.standard.string(forKey: "lastSidebarSelection")
        let restored = SidebarDestination.restore(saved,
            profileIDs: Set(state.profiles.profiles.map(\.id)),
            fallbackProfileID: state.profiles.selectedProfileID)
        self._selection = State(initialValue: restored)
    }

    var body: some View {
        NavigationSplitView {
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
        .frame(minWidth: 800, minHeight: 620)
        .onChange(of: selection) { newSelection in
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
