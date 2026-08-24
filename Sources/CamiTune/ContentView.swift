import SwiftUI
import Foundation

@MainActor
struct ContentView: View {
    let state: AppState

    @State private var selection: String
    @State private var showingOutputPicker = false
    @State private var pendingOutputUID: String?

    init(state: AppState) {
        self.state = state
        let saved = UserDefaults.standard.string(forKey: "lastSidebarSelection")
        let restored: String
        if let saved,
           saved == "setup" || saved == "default-profiles" || saved == "applications" {
            restored = saved
        } else if let saved,
                  let id = UUID(uuidString: saved),
                  state.profiles.profiles.contains(where: { $0.id == id }) {
            restored = saved
        } else {
            restored = state.profiles.selectedProfileID?.uuidString ?? "setup"
        }
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
            UserDefaults.standard.set(newSelection, forKey: "lastSidebarSelection")
            if let id = UUID(uuidString: newSelection) {
                state.profiles.selectedProfileID = id
            }
        }
        .sheet(isPresented: $showingOutputPicker) {
            AddOutputProfileSheet(
                coreAudio: state.coreAudio,
                selectedUID: $pendingOutputUID,
                onCancel: cancelAddingOutput,
                onAdd: addSelectedOutput
            )
        }
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

    private func addSelectedOutput() {
        guard let pendingOutputUID,
              let device = state.coreAudio.physicalOutputDevices.first(where: {
                  $0.id == pendingOutputUID
              }) else { return }
        let profileID = state.addProfile(for: device)
        selection = profileID?.uuidString ?? "setup"
        showingOutputPicker = false
        self.pendingOutputUID = nil
    }
}
