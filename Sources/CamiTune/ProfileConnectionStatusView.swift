import SwiftUI

/// Observe runtime changes locally without invalidating the entire editor.
@MainActor
struct ProfileActiveIndicator: View {
    @ObservedObject var state: AppState
    let profileID: UUID

    private var isActive: Bool {
        state.isActive && state.activeProfileID == profileID
    }

    var body: some View {
        if isActive {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Active profile")
                .help("This profile’s audio runtime is running")
        }
    }
}

/// Isolates CoreAudio device-list publications from the full profile editor.
@MainActor
struct ProfileConnectionStatusView: View {
    @ObservedObject var coreAudio: CoreAudioManager
    let outputDeviceUID: String

    var body: some View {
        if coreAudio.cachedDevice(uid: outputDeviceUID) == nil {
            Label("Disconnected", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.orange)
        }
    }
}
