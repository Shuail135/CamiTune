import SwiftUI

@MainActor
struct SpatialSeatingCalibrationView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    let context: SpatialCalibrationContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice = SpatialCalibrationVoice()
    @State private var draft: SpatialSeatingCalibration
    @State private var preview = true
    @State private var playing = false
    @State private var error: String?

    init(state: AppState, profile: Binding<DeviceProfile>, context: SpatialCalibrationContext, newPosition: Bool = false) {
        self.state = state; _profile = profile; self.context = context
        _draft = State(initialValue: (newPosition ? nil : profile.wrappedValue.effectiveSpatialSettings.seating)
            ?? SpatialSeatingCalibration(outputDeviceUID: context.outputDeviceUID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Listening position").font(.title2.bold())
            Text("Measure from each speaker to where you sit. The nearer speaker is gently delayed and reduced in level to help the centre image line up at your seat.")
                .foregroundStyle(.secondary)
            TextField("Position name", text: $draft.name)
            distance("Left speaker", value: $draft.leftDistanceMeters).disabled(draft.useMeasuredAlignment)
            distance("Right speaker", value: $draft.rightDistanceMeters).disabled(draft.useMeasuredAlignment)
            if draft.measuredArrivalDifferenceMS != nil {
                Toggle("Use microphone timing and level", isOn: $draft.useMeasuredAlignment)
            }
            Text("Fine-tune by ear: play the voice, then adjust until it sounds centred.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Left")
                Slider(value: $draft.balanceDB, in: -6...6).accessibilityLabel("Listening-position balance")
                Text("Right")
            }
            Button("Centre balance") { draft.balanceDB = 0 }.font(.caption)
            Toggle("Preview adjustment", isOn: $preview)
            HStack {
                Button(playing ? "Stop sample" : "Play centred voice") {
                    if playing {
                        state.pcmRouter.stopSpatialCalibrationSample(id: context.id)
                        playing = false
                    } else if let clip = voice.clip {
                        playing = state.playSpatialCalibration(context: context, clip: clip, tuning: .neutral) {
                            Task { @MainActor in playing = false }
                        }
                        if !playing { error = "The active output changed. Close and reopen calibration." }
                    }
                }.disabled(voice.clip == nil)
                if voice.isPreparing { ProgressView().controlSize(.small) }
            }
            if let message = error ?? voice.errorMessage { Text(message).foregroundStyle(.orange) }
            Text("Use a comfortable volume. This adjusts one listening position; it does not measure room reflections. Keep the default equal distances for headphones or a single soundbar.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save position") {
                    guard state.spatialCalibrationContext == context,
                          profile.id == context.profileID, profile.outputDeviceUID == context.outputDeviceUID else {
                        error = "The active output changed. Close and reopen calibration."; return
                    }
                    draft.name = String(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                    if draft.name.isEmpty { draft.name = "My listening position" }
                    draft.enabled = true
                    Task {
                        if await state.saveListeningPosition(context: context, position: draft) { dismiss() }
                        else { error = "The output changed. Reopen calibration and try again." }
                    }
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 440)
        .task { voice.prepare(sampleRate: context.sampleRate); applyPreview() }
        .onChange(of: draft) { _ in applyPreview() }
        .onChange(of: preview) { _ in applyPreview() }
        .onChange(of: state.spatialCalibrationContext?.id) { id in if id != context.id { dismiss() } }
        .onDisappear {
            voice.cancel()
            // Never let an old sheet mutate a newly activated audio session.
            if state.spatialCalibrationContext == context {
                if let saved = state.profiles.profiles.first(where: { $0.id == context.profileID && $0.outputDeviceUID == context.outputDeviceUID }) {
                    state.pcmRouter.setSpatialSettings(saved.effectiveSpatialSettings,
                        output: saved.effectiveSpatialSettings.resolvedOutput(deviceName: saved.outputDeviceName))
                }
                state.endSpatialCalibration(id: context.id)
            }
        }
    }
    private func distance(_ label: String, value: Binding<Float>) -> some View {
        HStack {
            Text(label).frame(width: 95, alignment: .leading)
            Slider(value: value, in: 0.2...10, step: 0.05)
            Text(String(format: "%.2f m", value.wrappedValue)).monospacedDigit().frame(width: 65)
        }
    }
    private func applyPreview() {
        guard state.spatialCalibrationContext == context, profile.outputDeviceUID == context.outputDeviceUID else { return }
        var settings = profile.effectiveSpatialSettings
        var seating = draft; seating.enabled = preview
        settings.seating = seating
        state.pcmRouter.setSpatialSettings(settings, output: .speakers)
    }
}
