import SwiftUI
import Foundation

@MainActor
struct ContentDetailView: View {
    let state: AppState
    @ObservedObject var profileStore: ProfileStore
    let coreAudio: CoreAudioManager
    let selection: SidebarDestination

    var body: some View {
        switch selection {
        case .empty:
            VStack(spacing: 10) {
                Image(systemName: "speaker.wave.2").font(.largeTitle)
                Text("Add an output to get started").font(.title2)
                Text("Choose Add Output in the sidebar.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .settings:
            SettingsView(state: state)
        case .applications:
            PerAppAudioView(state: state)
        case .profile(let id):
            if let index = profileStore.profiles.firstIndex(where: { $0.id == id }) {
                ProfileEditorView(
                    state: state,
                    coreAudio: coreAudio,
                    profile: $profileStore.profiles[index]
                )
                .id(id)
                .onAppear { UIRenderPerformance.recordProfilePresentation() }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3").font(.largeTitle)
                    Text("Choose a profile").font(.title2)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}
