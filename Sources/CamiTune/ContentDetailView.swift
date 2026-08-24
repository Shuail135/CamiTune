import SwiftUI
import Foundation

@MainActor
struct ContentDetailView: View {
    let state: AppState
    @ObservedObject var profileStore: ProfileStore
    let coreAudio: CoreAudioManager
    let selection: String

    var body: some View {
        if selection == "setup" {
            SetupView(state: state)
        } else if selection == "default-profiles" {
            DefaultProfilesView(state: state)
        } else if selection == "applications" {
            PerAppAudioView(controller: state.perAppAudio)
        } else if let id = UUID(uuidString: selection),
                  let index = profileStore.profiles.firstIndex(where: { $0.id == id }) {
            ProfileEditorView(
                state: state,
                coreAudio: coreAudio,
                profile: $profileStore.profiles[index]
            )
            .id(id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3").font(.largeTitle)
                Text("Choose a profile").font(.title2)
            }
            .foregroundStyle(.secondary)
        }
    }
}
