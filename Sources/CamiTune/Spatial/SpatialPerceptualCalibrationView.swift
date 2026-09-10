import SwiftUI

@MainActor
struct SpatialPerceptualCalibrationView: View {
    @ObservedObject var state: AppState
    let context: SpatialCalibrationContext
    let outputName: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice = SpatialCalibrationVoice()
    @State private var calibration: SpatialPerceptualCalibration
    @State private var feedback = SpatialPositionFeedback()
    @State private var listenerName: String
    @State private var heard: Set<Audition> = []
    @State private var playing: Audition?
    @State private var playbackRequest = UUID()
    @State private var errorMessage: String?

    private enum Audition: String { case position, a, b, result }

    init(state: AppState, context: SpatialCalibrationContext, profile: DeviceProfile) {
        self.state = state
        self.context = context
        outputName = profile.outputDeviceName
        _calibration = State(initialValue: SpatialPerceptualCalibration(tuning: profile.spatialListenerTuning))
        _listenerName = State(initialValue: profile.spatialListenerProfile?.name ?? "My listening position")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Personalize Front Stage").font(.title2.bold())
            Text(outputName).foregroundStyle(.secondary)
            Text("Sit in your usual listening position and use a comfortable, low speaker volume. Each sample plays a centered voice followed by a quiet stereo texture. Other application audio is temporarily silenced while the sample plays.")
                .font(.callout)

            if voice.isPreparing {
                HStack { ProgressView().controlSize(.small); Text("Preparing voice sample…") }
            }
            if let message = voice.errorMessage {
                Text(message).foregroundStyle(.orange)
                Button("Retry voice sample") { voice.prepare(sampleRate: context.sampleRate) }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }

            Divider()
            if !calibration.hasPositionFeedback {
                positionStep
            } else if !calibration.isComplete {
                comparisonStep
            } else {
                resultStep
            }

            if playing != nil {
                HStack {
                    Image(systemName: "speaker.wave.2.fill")
                    Text("Playing sample…")
                    Spacer()
                    Button("Stop sample") { stopSample() }
                }
                .font(.callout)
            }

            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if calibration.isComplete {
                    Button("Save listener profile") {
                        stopSample()
                        if state.saveSpatialCalibration(context: context, name: listenerName, result: calibration) {
                            dismiss()
                        } else {
                            errorMessage = "The active output changed. Close this window and start calibration again."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(playing != nil)
                }
            }
        }
        .padding(24)
        .frame(width: 570)
        .fixedSize(horizontal: false, vertical: true)
        .task { voice.prepare(sampleRate: context.sampleRate) }
        .onChange(of: state.spatialCalibrationContext?.id) { id in
            if id != context.id { dismiss() }
        }
        .onDisappear {
            playbackRequest = UUID()
            voice.cancel()
            state.endSpatialCalibration(id: context.id)
        }
    }

    private var positionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("1. Place the voice").font(.headline)
            auditionButton("Play centered voice", audition: .position, tuning: calibration.tuning)
            Text("Where does the voice sound like it comes from?")
            Picker("Voice depth", selection: $feedback.depth) {
                ForEach(PerceivedVoiceDepth.allCases) { depth in
                    Text(depth.label).tag(depth)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("Where do you hear the voice horizontally?")
            HStack {
                Text("Left")
                Slider(value: Binding(
                    get: { Double(feedback.horizontalPosition) },
                    set: { feedback.horizontalPosition = Float($0) }
                ), in: -1...1)
                .accessibilityLabel("Perceived horizontal voice position")
                Text("Right")
            }
            Button("The voice is centered") { feedback.horizontalPosition = 0 }
                .font(.caption)
            Button("Continue to A/B comparisons") {
                calibration.setPosition(feedback)
                heard = []
            }
            .buttonStyle(.borderedProminent)
            .disabled(!heard.contains(.position) || playing != nil)
        }
    }

    private var comparisonStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("2. Compare — \(calibration.comparisonIndex + 1) of \(SpatialPerceptualCalibration.comparisonCount)")
                .font(.headline)
            Text("Which sounds more like a natural voice in front of you, with a stable center? Listen to both versions before choosing. Keep your volume and listening position unchanged.")
            HStack {
                auditionButton("Play A", audition: .a, tuning: calibration.candidates.a)
                auditionButton("Play B", audition: .b, tuning: calibration.candidates.b)
            }
            HStack {
                Button("Prefer A") { choose(.a) }
                Button("Prefer B") { choose(.b) }
                Button("No difference / keep current") { choose(.noDifference) }
            }
            .disabled(!heard.contains(.a) || !heard.contains(.b) || playing != nil)
            Text("Choose “keep current” if neither version sounds better.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var resultStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("3. Save your listening position").font(.headline)
            TextField("Listener profile name", text: $listenerName)
                .textFieldStyle(.roundedBorder)
            Text("Your choices will be used for both stereo and multichannel Front Stage on \(outputName). Recalibrate if you move the speakers or change your usual seat.")
                .font(.callout)
            auditionButton("Preview result", audition: .result, tuning: calibration.tuning)
        }
    }

    private func auditionButton(
        _ label: String, audition: Audition, tuning: SpatialListenerTuning
    ) -> some View {
        Button {
            guard let clip = voice.clip else { return }
            let request = UUID()
            playbackRequest = request
            playing = audition
            errorMessage = nil
            let started = state.playSpatialCalibration(context: context, clip: clip, tuning: tuning) {
                Task { @MainActor in
                    guard playbackRequest == request else { return }
                    playing = nil
                    heard.insert(audition)
                }
            }
            if !started {
                playing = nil
                errorMessage = "The audio route is no longer available. Close this window and activate the profile again."
            }
        } label: {
            Label(label, systemImage: heard.contains(audition) ? "checkmark.circle" : "play.fill")
        }
        .disabled(voice.clip == nil || voice.isPreparing || playing != nil)
    }

    private func choose(_ choice: SpatialPerceptualCalibration.Choice) {
        calibration.choose(choice)
        heard = []
    }

    private func stopSample() {
        playbackRequest = UUID()
        state.pcmRouter.stopSpatialCalibrationSample(id: context.id)
        playing = nil
    }
}
