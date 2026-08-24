import SwiftUI

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
