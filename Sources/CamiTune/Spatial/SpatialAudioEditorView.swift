import SwiftUI

@MainActor
struct SpatialAudioEditorView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    @State private var channelContext: SpatialCalibrationContext?
    @State private var creatingPosition = false
    @State private var microphoneContext: SpatialCalibrationContext?
    @State private var seatingContext: SpatialCalibrationContext?
    @State private var calibrationError: String?

    private var active: Bool { state.isActive && state.activeProfileID == profile.id }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Group {
                    HStack {
                        Toggle("Spatial Audio", isOn: Binding(
                            get: { profile.spatialSettings.enabled },
                            set: { profile.spatialRenderingMode = .spatialAudio; profile.spatialSettings.enabled = $0 }))
                            .font(.headline)
                        Spacer()
                        if profile.spatialSettings.enabled {
                            Picker("Content", selection: $profile.spatialSettings.contentSelection) {
                                Text("Automatic").tag(SpatialContentSelection.automatic)
                                Text("Music").tag(SpatialContentSelection.music)
                                Text("Cinema").tag(SpatialContentSelection.cinema)
                            }.labelsHidden().frame(width: 130)
                        }
                    }
                    if profile.spatialSettings.enabled {
                        HStack {
                            Text("Space").font(.callout)
                            Slider(value: amount, in: 0...1)
                                .accessibilityLabel("Spatial amount")
                            Text("Immersive").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.disabled(state.spatialCalibrationContext != nil)
                DisclosureGroup("Advanced & calibration") {
                    VStack(alignment: .leading, spacing: 10) {
                        Group {
                            Picker("Output", selection: $profile.spatialSettings.outputSelection) {
                                Text("Automatic").tag(SpatialOutputSelection.automatic)
                                Text("Headphones").tag(SpatialOutputSelection.headphones)
                                Text("Speakers").tag(SpatialOutputSelection.speakers)
                            }
                            if profile.spatialSettings.contentSelection != .music {
                                HStack {
                                    Text("Dialogue")
                                    Slider(value: $profile.spatialSettings.cinema.dialogueFocus, in: 0...1)
                                    Text("Clear").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if profile.spatialSettings.resolvedOutput(deviceName: profile.outputDeviceName) == .speakers {
                                Picker("Listening position", selection: selectedPosition) {
                                    Text("Uncalibrated").tag(UUID?.none)
                                    ForEach(profile.spatialSettings.listeningPositions.filter { $0.outputDeviceUID == profile.outputDeviceUID }) { seat in
                                        Text(seat.name).tag(Optional(seat.id))
                                    }
                                }
                                HStack {
                                    Button("New position…") {
                                        creatingPosition = true
                                        seatingContext = state.beginSpatialCalibration(profileID: profile.id, spatialAudio: true)
                                        calibrationError = seatingContext == nil ? "Activate Spatial Audio on this output before calibrating." : nil
                                    }.disabled(!active || !profile.spatialSettings.enabled)
                                    Button("Adjust position…") {
                                        creatingPosition = false
                                        seatingContext = state.beginSpatialCalibration(profileID: profile.id, spatialAudio: true)
                                        calibrationError = seatingContext == nil ? "Activate Spatial Audio on this output before calibrating." : nil
                                    }.disabled(!active || !profile.spatialSettings.enabled || profile.effectiveSpatialSettings.seating == nil)
                                    if let seat = profile.effectiveSpatialSettings.seating {
                                        Button("Delete") {
                                            Task { await state.selectListeningPosition(profileID: profile.id, positionID: seat.id, delete: true) }
                                        }
                                    }
                                }
                                HStack {
                                    Button("Measure room with microphone…") {
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
                            Button("Check speaker positions…") {
                                channelContext = state.beginSpatialCalibration(profileID: profile.id, spatialAudio: true)
                                calibrationError = channelContext == nil ? "Activate Spatial Audio on this output first." : nil
                            }.disabled(!active || !profile.spatialSettings.enabled)
                            if let calibrationError { Text(calibrationError).font(.caption).foregroundStyle(.orange) }
                        }.disabled(state.spatialCalibrationContext != nil)
                    }.padding(.top, 6)
                }.font(.callout)
            }.padding(4)
        }
        .sheet(item: $seatingContext) { context in
            SpatialSeatingCalibrationView(state: state, profile: $profile, context: context, newPosition: creatingPosition)
                .id(context.id)
        }
        .sheet(item: $channelContext) { context in
            SpatialChannelCheckView(state: state, context: context,
                headphones: profile.spatialSettings.resolvedOutput(deviceName: profile.outputDeviceName) == .headphones)
        }
        .sheet(item: $microphoneContext) { context in
            SpatialMicrophoneCalibrationView(state: state, context: context, profile: profile, roomCorrection: true)
                .id(context.id)
        }
        .onChange(of: profile.spatialSettings) { _ in
            if !profile.spatialSettings.enabled && profile.spatialRenderingMode != .spatialAudio { return }
            profile.spatialRenderingMode = .spatialAudio
            guard active, state.spatialCalibrationContext == nil else { return }
            state.pcmRouter.setSpatialSettings(profile.effectiveSpatialSettings,
                output: profile.spatialSettings.resolvedOutput(deviceName: profile.outputDeviceName))
            state.pcmRouter.setSpatialRenderingMode(.spatialAudio)
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
