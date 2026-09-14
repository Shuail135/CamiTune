import SwiftUI

@MainActor
struct SpatialAudioEditorView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    @State private var showingSpeakerSystem = false
    @State private var modePreview: PlaybackMode?
    @State private var channelContext: SpatialCalibrationContext?
    @State private var creatingPosition = false
    @State private var showingListeningPosition = false
    @State private var microphoneContext: SpatialCalibrationContext?
    @State private var seatingContext: SpatialCalibrationContext?
    @State private var calibrationError: String?

    private var active: Bool { state.isActive && state.activeProfileID == profile.id }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Mode").font(.title3.bold())
                Picker("Mode", selection: playbackMode) {
                    ForEach(profile.availablePlaybackModes, id: \.self) { mode in
                        Label(mode.compactDisplayName, systemImage: mode.systemImageName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .tint(.blue)
                .disabled(state.transitionInProgress || state.isSavingProfileSettings || state.spatialCalibrationContext != nil)
                Text(playbackModeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if modePreview == .referencePlayback && profile.playbackMode != .referencePlayback {
                    Text("Finish Speaker and Listening Position in Profile Settings to use Reference. The saved mode is still \(profile.playbackMode.compactDisplayName).")
                        .font(.callout).foregroundStyle(.orange)
                }
                if profile.isPersonalListening && (profile.playbackMode == .referencePlayback || profile.processing.deviceCorrection != nil) {
                    ReferenceCorrectionView(state: state, profile: $profile)
                }
                if profile.playbackMode == .spatialRender {
                    HStack {
                        Text("Spatial").font(.callout)
                        Text("Focused").font(.caption).foregroundStyle(.secondary)
                        Slider(value: amount, in: 0...1)
                            .accessibilityLabel("Spatial amount")
                        Text("Expansive").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Try different settings by listening; maximum does not mean better.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Dialogue")
                        Slider(value: $profile.spatialSettings.cinema.dialogueFocus, in: 0...1)
                        Text("Clear").font(.caption).foregroundStyle(.secondary)
                    }
                    .disabled(profile.spatialSettings.contentSelection == .music)
                    HStack {
                        Text("Content Type").font(.callout)
                        Spacer()
                        Picker("Content Type", selection: $profile.spatialSettings.contentSelection) {
                            Text("Automatic").tag(SpatialContentSelection.automatic)
                            Text("Music").tag(SpatialContentSelection.music)
                            Text("Cinema").tag(SpatialContentSelection.cinema)
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                }
                if profile.playbackMode == .spatialRender && profile.effectiveEndpointKind == .speakers {
                    Button("Speaker and Listening Position") { showingSpeakerSystem = true; showingListeningPosition = false }
                }
                if profile.playbackMode == .spatialRender && profile.isPersonalListening {
                    Text("Personal-listening Spatial is still in development; the current renderer provides the supported effects shown here.")
                        .font(.caption).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let diagnostics = state.pcmRouter.spatialRenderDiagnostics
                        let rendering = active && diagnostics?.renderer == .headphones
                        let binaural = rendering && diagnostics?.hrtfProfile != nil
                        Text(binaural ? "Spatial renderer running" : rendering
                             ? "Limited stereo fallback; the binaural renderer is unavailable at this sample rate."
                             : "Spatial renderer not running")
                            .font(.caption).foregroundStyle(binaural ? Color.green : Color.secondary)
                    }
                }
                if profile.playbackMode == .spatialRender {
                    DisclosureGroup("Advanced & Calibration") {
                    VStack(alignment: .leading, spacing: 10) {
                        Group {
                            if profile.effectiveSpatialSettings.resolvedOutput(deviceName: profile.outputDeviceName) == .speakers {
                                HStack {
                                Picker("Listening Position", selection: selectedPosition) {
                                    Text("Uncalibrated").tag(UUID?.none)
                                    ForEach(profile.spatialSettings.listeningPositions.filter { $0.outputDeviceUID == profile.outputDeviceUID }) { seat in
                                        Text(seat.name).tag(Optional(seat.id))
                                    }
                                }
                                    Button("New Position…") {
                                        creatingPosition = true
                                        showingSpeakerSystem = false
                                        showingListeningPosition = true
                                    }.disabled(profile.speakerTopology == nil)
                                    Button("Adjust Position…") {
                                        creatingPosition = false
                                        showingSpeakerSystem = false
                                        showingListeningPosition = true
                                    }.disabled(profile.speakerTopology == nil || profile.effectiveSpatialSettings.seating == nil)
                                    if let seat = profile.effectiveSpatialSettings.seating {
                                        Button("Delete") {
                                            Task { await state.selectListeningPosition(profileID: profile.id, positionID: seat.id, delete: true) }
                                        }
                                    }
                                }
                                HStack {
                                    Button("Calibrate by Listening…") {
                                        creatingPosition = false
                                        seatingContext = state.beginSpatialCalibration(profileID: profile.id, spatialAudio: true)
                                        calibrationError = seatingContext == nil ? "Activate Spatial on this output before calibrating." : nil
                                    }.disabled(!active)
                                    Button("Room Correct…") {
                                        microphoneContext = state.beginSpatialCalibration(profileID: profile.id, spatialAudio: true)
                                        calibrationError = microphoneContext == nil ? "Activate Spatial Audio on this output before measuring." : nil
                                    }.disabled(!active || !profile.spatialSettings.enabled || SpatialRoomCorrection.isApplied(to: profile.processing))
                                    if SpatialRoomCorrection.isApplied(to: profile.processing) {
                                        Button("Remove room correction") {
                                            Task { await state.removeRoomCorrection(profileID: profile.id) }
                                        }
                                    }
                                }
                                if let seat = profile.effectiveSpatialSettings.seating {
                                    if let confidence = seat.measurementConfidence {
                                        Text(confidence == .limited ? "Measurement saved with limited confidence; previous alignment was kept." : "Microphone measurement: \(confidence.label) confidence")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                Text("Virtual speakers use the SADIE II KU100 head model at supported sample rates.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if profile.effectiveEndpointKind == .speakers {
                            Button("Test Speakers…") {
                                channelContext = state.beginSpatialCalibration(profileID: profile.id, spatialAudio: true)
                                calibrationError = channelContext == nil ? "Activate Spatial Audio on this output first." : nil
                            }.disabled(!active || !profile.spatialSettings.enabled)
                            }
                            if let calibrationError { Text(calibrationError).font(.caption).foregroundStyle(.orange) }
                        }.disabled(state.spatialCalibrationContext != nil || profile.usesReferenceSpeakers)
                    }.padding(.top, 6)
                    }.font(.callout)
                }
                if showingSpeakerSystem {
                    Divider()
                    SpeakerSystemView(state: state, profile: $profile, embedded: true,
                        onClose: { showingSpeakerSystem = false })
                }
                if showingListeningPosition {
                    Divider()
                    SpeakerSystemView(state: state, profile: $profile, listeningOnly: true,
                        newPosition: creatingPosition, embedded: true,
                        onClose: { showingListeningPosition = false })
                }
            }.padding(4)
        }
        .sheet(item: $seatingContext) { context in
            SpatialSeatingCalibrationView(state: state, profile: $profile, context: context, newPosition: creatingPosition)
                .id(context.id)
        }
        .sheet(item: $channelContext) { context in
            SpatialChannelCheckView(state: state, context: context,
                headphones: profile.effectiveSpatialSettings.resolvedOutput(deviceName: profile.outputDeviceName) == .headphones)
        }
        .sheet(item: $microphoneContext) { context in
            SpatialMicrophoneCalibrationView(state: state, context: context, profile: profile, roomCorrection: true)
                .id(context.id)
        }
        .onChange(of: profile.id) { _ in modePreview = nil }
        .onChange(of: profile.playbackMode) { _ in modePreview = nil }
        .onChange(of: profile.spatialSettings) { _ in
            guard profile.playbackMode == .spatialRender else { return }
            guard active, state.spatialCalibrationContext == nil else { return }
            state.pcmRouter.setSpatialSettings(profile.effectiveSpatialSettings,
                output: profile.effectiveSpatialSettings.resolvedOutput(deviceName: profile.outputDeviceName))
            state.pcmRouter.setSpatialRenderingMode(.spatialAudio)
        }
    }
    private var playbackMode: Binding<PlaybackMode> {
        Binding(get: { modePreview ?? profile.playbackMode }, set: { mode in
            if mode == .referencePlayback && !profile.isPersonalListening {
                var candidate = profile; candidate.setPlaybackMode(mode)
                if (try? candidate.validatedReferenceTopology()) == nil {
                    modePreview = mode; return
                }
            }
            modePreview = nil
            let id = profile.id
            Task { await state.setPlaybackMode(profileID: id, mode: mode) }
        })
    }
    private var playbackModeDescription: String {
        switch modePreview ?? profile.playbackMode {
        case .direct:
            return "No automatic adjustment for audio devices."
        case .referencePlayback:
            if profile.isPersonalListening {
                return profile.effectiveEndpointKind == .iem
                    ? "Fine-tunes your earphones to sound closer to your selected target."
                    : "Fine-tunes your headphones using your loaded correction filters."
            }
            return "Preserves source positions through the configured speaker map without creating surround or height content."
        case .spatialRender:
            return "Automatically make audio spatial and immersive."
        }
    }
    private var selectedPosition: Binding<UUID?> {
        Binding(get: { profile.effectiveSpatialSettings.selectedPositionID }, set: { id in
            Task { await state.selectListeningPosition(profileID: profile.id, positionID: id) }
        })
    }
    private var amount: Binding<Float> {
        Binding(get: {
            profile.spatialSettings.contentSelection == .cinema
                ? profile.spatialSettings.cinema.amount : profile.spatialSettings.music.amount
        }, set: { value in
            switch profile.spatialSettings.contentSelection {
            case .music: profile.spatialSettings.music.amount = value
            case .cinema: profile.spatialSettings.cinema.amount = value
            case .automatic:
                profile.spatialSettings.music.amount = value
                profile.spatialSettings.cinema.amount = value
            }
        })
    }
}
