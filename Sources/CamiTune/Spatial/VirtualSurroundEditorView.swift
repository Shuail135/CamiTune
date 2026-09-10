import SwiftUI

@MainActor
struct VirtualSurroundEditorView: View {
    @ObservedObject var state: AppState
    let profileID: UUID
    @Binding var layout: VirtualSurroundLayout
    @Environment(\.dismiss) private var dismiss
    @State private var selected: ChannelRole = .center
    @State private var context: SpatialCalibrationContext?
    @State private var playing = false
    @State private var playingDemo = false
    @State private var demoStarted = Date()
    @State private var playbackID = UUID()
    @State private var error: String?
    @State private var confirmingReset = false
    @State private var roomContext: SpatialCalibrationContext?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Calibrate Virtual 7.1").font(.title2.bold())
                Spacer()
                Button("Done") { finish(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Sit in your usual listening position. Play the selected channel and adjust the controls until you hear it from the direction shown on the fixed diagram. Adjustments save automatically. Done restores application audio.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Microphone / imported recording…") {
                    finish()
                    roomContext = state.beginSpatialCalibration(profileID: profileID, virtualSurround: true)
                    if roomContext == nil { error = "Activate this Virtual 7.1 profile before measuring." }
                }.disabled(roomCorrectionPresent || !state.isActive || state.activeProfileID != profileID)
                if roomCorrectionPresent {
                    Button("Remove room correction") {
                        finish()
                        Task { await state.removeRoomCorrection(profileID: profileID) }
                    }
                    Text("Remove the existing correction before remeasuring.").font(.caption)
                }
            }
            Text("FL / FR: front left / right · C: center · SL / SR: side surrounds · RL / RR: rear surrounds · LFE: bass")
                .font(.caption).foregroundStyle(.secondary)
            Text("The diagram is a recommended listening reference, not a map of your actual speakers or seat. It does not move when you adjust the sound.")
                .font(.caption).foregroundStyle(.secondary)
            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let radius = max(1, min(geometry.size.width, geometry.size.height) / 2 - 30)
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035))
                    Circle().stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5]))
                        .frame(width: radius * 1.6, height: radius * 1.6).position(center)
                    ForEach(VirtualSurroundLayout.roles.filter { $0 != .lowFrequencyEffects }, id: \.self) { role in
                        let reference = VirtualSurroundLayout.standard.position(for: role)
                        let target = CGPoint(x: center.x + CGFloat(reference.x) * radius,
                                             y: center.y + CGFloat(reference.y) * radius)
                        Path { path in
                            path.move(to: center)
                            path.addLine(to: target)
                        }.stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3]))
                        Circle().stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3]))
                            .frame(width: 44, height: 44).position(target)
                    }
                    Text("SCREEN / FRONT").font(.caption2).position(x: center.x, y: 12)
                    Text("BEHIND").font(.caption2).position(x: center.x, y: geometry.size.height - 12)
                    VStack(spacing: 2) {
                        Image(systemName: "person.fill")
                        Text("You ↑").font(.caption2)
                    }.position(center)
                    ForEach(VirtualSurroundLayout.roles, id: \.self) { role in
                        let position = VirtualSurroundLayout.standard.position(for: role)
                        Text(VirtualSurroundLayout.label(role)).font(.caption.bold())
                            .frame(width: 38, height: 38)
                            .background(selected == role ? Color.accentColor : Color.secondary.opacity(0.22), in: Circle())
                            .foregroundStyle(selected == role ? Color.white : Color.primary)
                            .contentShape(Circle())
                            .onTapGesture { selected = role }
                            .accessibilityLabel("\(VirtualSurroundLayout.label(role)) recommended direction. Select and adjust the sound with the controls below.")
                            .position(x: center.x + CGFloat(position.x) * radius,
                                      y: center.y + CGFloat(position.y) * radius)
                    }
                }.coordinateSpace(name: "speakerMap")
            }.frame(height: 330)
            Text("Highlighted channel: recommended direction to listen for. Use the controls below; the reference stays fixed.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Channel", selection: $selected) {
                    ForEach(VirtualSurroundLayout.roles, id: \.self) { Text(VirtualSurroundLayout.label($0)).tag($0) }
                }.frame(maxWidth: 180)
                Button {
                    if playing { stopSound() } else { audition() }
                } label: {
                    Label("Channel test", systemImage: playing ? "stop.fill" : "play.fill")
                }
                .help(playing ? "Stop channel test" : "Play continuously until stopped")
                .accessibilityValue(playing ? "Playing — press to stop" : "Stopped — press to play")
                .disabled(!playing && (!state.isActive || state.activeProfileID != profileID))
                .disabled(playing && playingDemo)
                Button {
                    if playingDemo && playing { stopSound() } else { audition(demo: true) }
                } label: {
                    Label("7.1 test", systemImage: playing && playingDemo ? "stop.fill" : "play.fill")
                }.disabled((playing && !playingDemo) || !state.isActive || state.activeProfileID != profileID)
            }
            HStack {
                if playing && playingDemo {
                    TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
                        let phase = max(0, timeline.date.timeIntervalSince(demoStarted)).truncatingRemainder(dividingBy: 24)
                        let stage = min(8, Int(phase / 2))
                        Text(stage < 8 ? "Channel: \(VirtualSurroundLayout.label(VirtualSurroundLayout.roles[stage]))" : "Full 7.1 ensemble")
                            .font(.caption)
                    }
                } else {
                    Text("Each channel in turn, then the whole bed. Repeats until stopped.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset channels") { confirmingReset = true }
            }
            adjustmentControl("Sound left / right", keyPath: \.x, negative: "Left", positive: "Right")
                .disabled(selected == .lowFrequencyEffects)
            adjustmentControl("Sound front / back", keyPath: \.y, negative: "Front", positive: "Back")
                .disabled(selected == .lowFrequencyEffects)
            Text("Channel levels are managed automatically with equal-power panning and shared headroom. No seat distance is assumed and direction adjustments do not add distance-based volume changes. Use a comfortable system volume; this is not a measured loudness calibration. LFE is non-directional and may be hard to hear on small speakers—do not turn it up sharply.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Multichannel input bypasses content sensing and stereo upmix. Each supported labeled channel goes directly to its virtual speaker, even when other channels are silent. Only explicitly stereo input can use the optional upmix. LFE remains low-passed and non-directional.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Output remains stereo. Rear localization on two speakers is approximate and depends strongly on your room and listening position; this is not a calibrated HRTF or a physical 7.1 output mode.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert("Are you sure you want to reset channel adjustments?", isPresented: $confirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset channels", role: .destructive) { layout.positions = [:] }
        } message: {
            Text("This restores all channel directions to their defaults. Your conversion settings will not change.")
        }
        .onDisappear { finish() }
        .sheet(item: $roomContext) { context in
            if let profile = state.profiles.profiles.first(where: { $0.id == profileID }) {
                ScrollView {
                    SpatialMicrophoneCalibrationView(state: state, context: context, profile: profile, roomCorrection: true)
                }.frame(width: 710, height: 780)
            }
        }
        .onChange(of: selected) { _ in stopSound() }
        .onChange(of: state.spatialCalibrationContext?.id) { id in
            if id != context?.id { playbackID = UUID(); playing = false; context = nil }
        }
    }

    private var roomCorrectionPresent: Bool {
        state.profiles.profiles.first(where: { $0.id == profileID })
            .map { SpatialRoomCorrection.isApplied(to: $0.processing) } ?? false
    }

    private func audition(demo: Bool = false) {
        error = nil
        if context == nil { context = state.beginSpatialCalibration(profileID: profileID, virtualSurround: true) }
        guard let context, var clip = SpatialCalibrationClip(virtualSpeaker: selected, sampleRate: context.sampleRate) else {
            error = "Activate this Virtual 7.1 profile on its selected output before playing a sample."
            return
        }
        clip.virtualSurroundDemo = demo
        state.holdSpatialMeasurement(context: context, enabled: true)
        let id = UUID()
        playbackID = id
        playing = true
        playingDemo = demo
        demoStarted = Date()
        if !state.playSpatialCalibration(context: context, clip: clip, tuning: .neutral, completion: {
            Task { @MainActor in
                guard playbackID == id else { return }
                playing = false
            }
        }) {
            finish()
            error = "Playback could not start. Check the active output and try again."
        }
    }

    private func stopSound() {
        playbackID = UUID()
        playing = false
        playingDemo = false
        if let context { state.pcmRouter.stopSpatialCalibrationSample(id: context.id) }
    }

    private func finish() {
        stopSound()
        if let context { state.endSpatialCalibration(id: context.id) }
        context = nil
    }

    private func coordinate(_ keyPath: WritableKeyPath<VirtualSpeakerPosition, Float>) -> Binding<Float> {
        Binding(get: { max(-1, min(1, layout.position(for: selected)[keyPath: keyPath] / 0.8)) }, set: { value in
            var position = layout.position(for: selected)
            position[keyPath: keyPath] = value * 0.8
            layout.positions[selected] = position.validated
        })
    }

    private func adjustmentControl(_ title: String, keyPath: WritableKeyPath<VirtualSpeakerPosition, Float>,
                                   negative: String, positive: String) -> some View {
        let value = coordinate(keyPath)
        return VStack(spacing: 3) {
            HStack {
                Text(title).frame(width: 120, alignment: .leading)
                Slider(value: value, in: -1...1)
                    .accessibilityLabel(title)
                    .accessibilityValue(String(Int((value.wrappedValue * 100).rounded())))
                Text(String(format: "%+d", Int((value.wrappedValue * 100).rounded())))
                    .monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            HStack {
                Text("−100 \(negative)")
                Spacer()
                Text("0")
                Spacer()
                Text("+100 \(positive)")
            }.font(.caption2).foregroundStyle(.secondary).padding(.leading, 128).padding(.trailing, 52)
        }
    }
}
