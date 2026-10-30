import CamiTuneDomain
import SwiftUI

@MainActor
struct SpatialAudioEditorView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    @State private var modePreview: PlaybackMode?
    @State private var setupProfile: DeviceProfile?

    private var displayedMode: PlaybackMode { modePreview ?? profile.playbackMode }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Mode").font(.title3.bold())
                JoinedSegmentedControl(
                    options: profile.availablePlaybackModes,
                    selection: playbackMode,
                    title: { $0.compactDisplayName },
                    symbol: { $0.systemImageName }
                )
                .accessibilityLabel("Mode")
                .uiInteractionAnchor("spatial-mode")
                .disabled(state.transitionInProgress || state.isSavingProfileSettings || state.spatialCalibrationContext != nil)

                if let description = playbackModeDescription {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
                if let reason = profile.playbackReadiness(displayedMode).reason {
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                }
                if modePreview != nil && displayedMode != profile.playbackMode {
                    Text("The saved mode is still \(profile.playbackMode.compactDisplayName).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if profile.isPersonalListening {
                    switch displayedMode {
                    case .direct:
                        EmptyView()
                    case .referencePlayback:
                        ReferenceCorrectionView(state: state, profile: $profile)
                    case .spatialRender:
                        PersonalSpatialEditorView(state: state, profile: profile) { setupProfile = profile }
                    }
                }
            }.padding(4)
        }
        .onChange(of: profile.id) { _ in modePreview = nil }
        .onChange(of: profile.playbackMode) { _ in modePreview = nil }
        .task(id: SetupContext(id: profile.id, device: profile.deviceTypeConfigurationKey, mode: profile.playbackMode)) {
            setupProfile = profile.playbackMode == .spatialRender && profile.needsPersonalSpatialSetup ? profile : nil
        }
        .sheet(item: $setupProfile) { profile in
            PersonalSpatialSetupSheet(state: state, profile: profile)
        }
    }

    private struct SetupContext: Equatable {
        let id: UUID
        let device: String
        let mode: PlaybackMode
    }

    private var playbackMode: Binding<PlaybackMode> {
        Binding(get: { displayedMode }, set: { mode in
            guard profile.playbackReadiness(mode).isReady else { modePreview = mode; return }
            modePreview = nil
            let id = profile.id
            Task { await state.setPlaybackMode(profileID: id, mode: mode) }
        })
    }

    private var playbackModeDescription: String? {
        switch displayedMode {
        case .direct:
            return "Plays audio without automatic device adjustment."
        case .referencePlayback:
            if profile.isPersonalListening {
                return profile.effectiveEndpointKind == .iem
                    ? "Fine-tunes your earphones to sound closer to your selected target."
                    : "Fine-tunes your headphones using your loaded correction filters."
            }
            return "Preserves source positions through the configured speaker map without creating surround or height content."
        case .spatialRender:
            // The physical-speaker mode keeps its button and saved behavior;
            // virtual-speaker controls belong only to personal listening.
            return nil
        }
    }
}
