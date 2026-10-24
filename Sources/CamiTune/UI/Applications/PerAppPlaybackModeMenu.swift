import CamiTuneDomain
import SwiftUI

/// Shared compact presentation of the existing runtime's effective override.
/// Saved unavailable overrides remain intact while the effective icon follows readiness.
struct PerAppPlaybackModeMenu: View {
    let application: PerAppAudioApplication
    let displayedName: String
    let controller: PerAppAudioController
    let context: PerAppPlaybackContext?
    var isLoading = false
    var scope: PerAppSettingsScope = .active
    var allowsStoredSelection = false

    var body: some View {
        let effective = context?.effectiveMode(for: application.settings.playbackModeOverride)
        let displayed = allowsStoredSelection ? application.settings.playbackModeOverride : effective
        Menu {
            if let context {
                Toggle(isOn: Binding(
                    get: { application.settings.playbackModeOverride == nil },
                    set: { _ in controller.setPlaybackModeOverride(nil, for: application.id, scope: scope) }
                )) { Label("Default", systemImage: context.profileMode.systemImageName) }
                Divider()
                ForEach(context.visibleModes, id: \.self) { mode in
                    let ready = context.readiness[mode]?.isReady == true
                    Toggle(isOn: Binding(
                        get: { application.settings.playbackModeOverride == mode },
                        set: { _ in if ready { controller.setPlaybackModeOverride(mode, for: application.id, scope: scope) } }
                    )) {
                        Label(mode.compactDisplayName + (ready ? "" : " — " + (context.readiness[mode]?.reason ?? "Unavailable")), systemImage: mode.systemImageName)
                    }.disabled(!ready)
                }
                if let saved = application.settings.playbackModeOverride, saved != effective {
                    Divider()
                    Text("\(saved.compactDisplayName) saved; following profile until available")
                }
            } else if allowsStoredSelection {
                Toggle(isOn: Binding(
                    get: { application.settings.playbackModeOverride == nil },
                    set: { _ in controller.setPlaybackModeOverride(nil, for: application.id, scope: scope) }
                )) { Label("Default", systemImage: "waveform.circle") }
                Divider()
                ForEach(PlaybackMode.allCases, id: \.self) { mode in
                    Toggle(isOn: Binding(
                        get: { application.settings.playbackModeOverride == mode },
                        set: { _ in controller.setPlaybackModeOverride(mode, for: application.id, scope: scope) }
                    )) { Label(mode.compactDisplayName, systemImage: mode.systemImageName) }
                }
            }
        } label: {
            Color.clear.frame(width: 28, height: 22).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .overlay {
            HStack(spacing: 2) {
                Image(systemName: displayed?.systemImageName ?? "waveform.circle")
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(isLoading || (context == nil && !allowsStoredSelection) ? Color.secondary : Color.primary)
            .allowsHitTesting(false)
        }
        .disabled(isLoading || (context == nil && !allowsStoredSelection))
        .accessibilityLabel("\(displayedName) playback mode: \(displayed?.compactDisplayName ?? (allowsStoredSelection ? "Default" : "No active profile"))")
    }
}
