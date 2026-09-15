#if DEBUG
import SwiftUI

struct SpeakerSetupPreviewApp: App {
    @NSApplicationDelegateAdaptor(SpeakerSetupPreviewDelegate.self) private var delegate
    @StateObject private var state = CamiTunePresentationCoordinator.shared.state
    var body: some Scene {
        WindowGroup("Speaker Setup Preview") { SpeakerSetupPreview(state: state) }
    }
}

private final class SpeakerSetupPreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The production editor, with temporary profile state and a silent audition
/// callback. Launch the Debug app with --speaker-setup-preview.
struct SpeakerSetupPreview: View {
    @ObservedObject var state: AppState
    @State private var profile = Self.profile(channelCount: 12)
    @State private var capacity = 12
    @State private var lastTest: String?
    @State private var editorID = UUID()
    @State private var section = "Setup"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Simulated Speakers").font(.title2.bold())
                    Spacer()
                    Picker("Outputs", selection: $capacity) {
                        ForEach([2, 6, 8, 10, 12, 16, 32], id: \.self) { Text("\($0)").tag($0) }
                    }.frame(width: 150)
                    Button("Reset") { reset() }
                }
                Text("Preview only. Edits stay in this window and speaker tests highlight the selected output without playing audio.")
                    .font(.caption).foregroundStyle(.secondary)
                JoinedSegmentedControl(options: ["Setup", "Processing", "Bass & Routing", "Meters"], selection: $section, title: { $0 })
                    .frame(width: 510)
                if section == "Setup" {
                    SpeakerSystemView(state: state, profile: $profile, draftOnly: true, embedded: true,
                        auditionOverride: { lastTest = "Test selected: hardware output \($0.channelIndex + 1)" })
                        .id(editorID)
                } else if section == "Processing" {
                    PreviewHistoryButtons(history: state.history)
                    PerChannelProcessingView(state: state, profile: $profile).id(editorID)
                } else if section == "Bass & Routing" {
                    PreviewHistoryButtons(history: state.history)
                    MultichannelProcessingView(state: state, profile: $profile, previewOnly: true).id(editorID)
                } else {
                    Text("Simulated meter levels. No audio device is opened.").font(.caption).foregroundStyle(.secondary)
                    SignalMetersView(meters: state.meters, profile: profile)
                }
                if let lastTest { Text(lastTest).font(.callout).foregroundStyle(.secondary) }
            }.padding(24)
        }.frame(minWidth: 650, idealWidth: 850, minHeight: 650, idealHeight: 850)
            .onChange(of: capacity) { _ in reset() }
            .onAppear { refreshPreviewState() }
            .onChange(of: profile) { _ in refreshPreviewState() }
            .onChange(of: section) { value in
                if value != "Setup", let topology = profile.speakerTopology {
                    profile.speakerTopology = SpeakerLayoutGeometry.acceptingDefaultRoles(topology)
                }
            }
    }

    private func reset() {
        profile = Self.profile(channelCount: capacity)
        lastTest = nil; editorID = UUID()
        state.history.clear()
        if section != "Setup", let topology = profile.speakerTopology {
            profile.speakerTopology = SpeakerLayoutGeometry.acceptingDefaultRoles(topology)
        }
        refreshPreviewState()
    }

    private func refreshPreviewState() {
        state.profiles.profiles = [profile]
        let inputCount = (try? ActiveAudioRoute(profile: profile).dspInputFormat.channelCount) ?? capacity
        state.meters.setPreviewLevels(SignalLevels(
            capturePeak: (0..<inputCount).map { -12 - Double($0 % 6) * 4 },
            captureRMS: (0..<inputCount).map { -18 - Double($0 % 6) * 4 },
            playbackPeak: (0..<capacity).map { -15 - Double($0 % 5) * 5 },
            playbackRMS: (0..<capacity).map { -21 - Double($0 % 5) * 5 }), profileID: profile.id)
    }

    static func profile(channelCount: Int) -> DeviceProfile {
        var profile = DeviceProfile(name: "Simulated Speakers", outputDeviceUID: "preview:speakers", outputDeviceName: "Simulated Speakers")
        profile.endpointKind = .speakers
        // Literal preview capacities are bounded, and the real resolver validates them.
        let discovered = try! SpeakerTopologyResolver().resolve(deviceUID: profile.outputDeviceUID,
            sampleRate: 48_000, channelCount: channelCount, channels: [])
        profile.speakerTopology = SpeakerLayoutGeometry.arrangedForEditing(discovered)
        profile.spatialSettings.seating = SpatialSeatingCalibration(outputDeviceUID: profile.outputDeviceUID)
        return profile
    }
}

private struct PreviewHistoryButtons: View {
    @ObservedObject var history: UndoCoordinator
    var body: some View {
        HStack {
            Button("Undo") { Task { await history.undo() } }.disabled(!history.canUndo)
            Button("Redo") { Task { await history.redo() } }.disabled(!history.canRedo)
        }
    }
}
#endif
