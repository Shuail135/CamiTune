import SwiftUI

@MainActor
struct FrontStageEditorView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    @State private var calibrationContext: SpatialCalibrationContext?
    @State private var microphoneContext: SpatialCalibrationContext?
    @State private var calibrationError: String?

    private var profileIsActive: Bool {
        state.isActive && state.activeProfileID == profile.id
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        heading
                        Spacer()
                        modePicker
                            .frame(width: 230)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        heading
                        modePicker
                            .frame(maxWidth: 300)
                    }
                }

                if profile.spatialRenderingMode == .frontStage {
                    Text("Front Stage automatically detects stereo, 5.1, and 7.1 PCM. Dialogue is anchored to the screen, front channels form the main stage, surrounds add width and depth, and LFE receives protected impact processing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    Picker("Content policy", selection: contentModeBinding) {
                        ForEach(SpatialContentMode.allCases) { Text($0.label).tag($0) }
                    }.disabled(state.spatialCalibrationContext != nil)
                    Text("Automatic uses conservative stereo when uncertain. Movie / Video allows more depth; Music-safe limits added width and depth. Fixed retains the original Front Stage policy. Calibration uses a fixed policy.")
                        .font(.caption).foregroundStyle(.secondary)
                    if profileIsActive && (profile.spatialContentMode == .automatic || profile.spatialContentMode == .movieVideo) {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let estimate = state.pcmRouter.spatialContentEstimate
                            Text("Signal estimate: \(estimate.label) — DSP heuristic, not source separation")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let measurement = profile.spatialAcousticProfile {
                        Text(measurement.applies(to: profile)
                             ? "Microphone measurement: \(measurement.confidence.label) confidence · \(measurement.microphone.name)"
                             : "Microphone measurement is out of date. Measure again after changing output or EQ.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let listener = profile.spatialListenerProfile {
                        if listener.outputDeviceUID == profile.outputDeviceUID, listener.version == 1 {
                            Text("Listener profile: \(listener.name)").font(.callout)
                        } else {
                            Text("The saved listener profile does not apply to this output. Calibrate this output to personalize it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button(profile.spatialListenerProfile == nil ? "Calibrate listening position…" : "Recalibrate…") {
                            calibrationContext = state.beginSpatialCalibration(profileID: profile.id)
                            calibrationError = calibrationContext == nil
                                ? "Activate this profile on its selected output before calibrating." : nil
                        }
                        .disabled(!profileIsActive || state.spatialCalibrationContext != nil)
                        if profile.spatialListenerProfile != nil {
                            Button(profile.spatialAcousticProfile?.applies(to: profile) == true ? "Use measured tuning" : "Use default tuning") {
                                state.clearSpatialCalibration(profileID: profile.id)
                            }
                        }
                    }
                    if !profileIsActive {
                        Text("Activate this profile to hear the calibration samples.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Measure with microphone…") {
                        microphoneContext = state.beginSpatialCalibration(profileID: profile.id)
                        calibrationError = microphoneContext == nil ? "Activate this profile on its selected output before measuring." : nil
                    }.disabled(!profileIsActive || state.spatialCalibrationContext != nil)
                    if let calibrationError { Text(calibrationError).font(.caption).foregroundStyle(.orange) }
                } else {
                    Text("Standard adds no spatial processing: stereo remains unchanged and multichannel audio uses the conservative role-aware fallback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
        .sheet(item: $calibrationContext) { context in
            SpatialPerceptualCalibrationView(state: state, context: context, profile: profile)
                .id(context.id)
        }
        .sheet(item: $microphoneContext) { context in
            SpatialMicrophoneCalibrationView(state: state, context: context, profile: profile).id(context.id)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Spatial Rendering(beta").font(.title3.bold())
            Text("For making macbook speaker/soundbar more spatial like.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modePicker: some View {
        Picker("Listening mode", selection: modeBinding) {
            ForEach(SpatialRenderingMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var modeBinding: Binding<SpatialRenderingMode> {
        Binding(
            get: { profile.spatialRenderingMode },
            set: { mode in
                guard mode != profile.spatialRenderingMode else { return }
                profile.spatialRenderingMode = mode
                guard profileIsActive else { return }
                let updated = profile
                Task { await state.apply(profile: updated) }
            }
        )
    }

    private var contentModeBinding: Binding<SpatialContentMode> {
        Binding(get: { profile.spatialContentMode }, set: { mode in
            profile.spatialContentMode = mode
            if profileIsActive { state.pcmRouter.setSpatialContentMode(mode) }
        })
    }
}
