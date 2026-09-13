import SwiftUI

@MainActor
struct SpeakerSystemView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    var draftOnly = false
    var listeningOnly = false
    var newPosition = false
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SpeakerTopology?
    @State private var seat: SpatialSeatingCalibration?
    @State private var originalSeat: SpatialSeatingCalibration?
    @State private var originalProfile: DeviceProfile?
    @State private var selected: PhysicalOutputID?
    @State private var busy = false
    @State private var message: String?
    @State private var context: SpatialCalibrationContext?
    @State private var playing: PhysicalOutputID?
    @State private var request = UUID()
    @State private var confirmClose = false
    @State private var editingTitle: PhysicalOutputID?
    @FocusState private var titleFocused: PhysicalOutputID?

    private var saved: Bool { draft == profile.speakerTopology && seat == originalSeat }
    private var canTest: Bool {
        !draftOnly && saved && profile.playbackMode == .referencePlayback
            && state.isActive && state.activeProfileID == profile.id && !busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(listeningOnly ? "Listening Position" : "Speaker and Listening Position").font(.title2.bold())
            HStack {
                Text(draft.map { "\($0.declaredChannelCount) physical outputs" } ?? "Discover the outputs on this device.")
                    .foregroundStyle(.secondary)
                Spacer()
                if !listeningOnly { Button("Discover Outputs") { discover() }.disabled(busy || playing != nil) }
            }
            if let draft {
                roomMap(draft)
                Text(listeningOnly
                     ? "Drag the listener to adjust this position. Speaker positions are locked."
                     : "Drag a speaker by its title to place it. Click its icon to play or stop identification audio.")
                    .font(.caption).foregroundStyle(.secondary)
                if !listeningOnly && !canTest {
                    Text("To identify outputs, save your changes and activate Reference on this profile.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let index = draft.endpoints.firstIndex(where: { $0.id == selected }), !listeningOnly {
                    heightEditor(index: index)
                }
                if seat != nil {
                    HStack {
                        Text("Listening Position")
                        TextField("Position name", text: Binding(get: { seat?.name ?? "" }, set: { seat?.name = String($0.prefix(80)) }))
                        if let seat {
                            Text("L \(seat.leftDistanceMeters, specifier: "%.2f") m · R \(seat.rightDistanceMeters, specifier: "%.2f") m")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Save") { save(close: false) }.disabled(draft == nil || busy || playing != nil || saved)
                Button("Close") { close() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
        }.padding(24).frame(width: 720)
        .onAppear {
            originalProfile = profile
            draft = profile.speakerTopology
            let existing = profile.effectiveSpatialSettings.seating
            seat = newPosition ? SpatialSeatingCalibration(outputDeviceUID: profile.outputDeviceUID) : existing
            if seat == nil { seat = SpatialSeatingCalibration(outputDeviceUID: profile.outputDeviceUID, name: "Primary") }
            originalSeat = newPosition ? nil : existing
        }
        .onDisappear { stop() }
        .interactiveDismissDisabled(!saved || busy)
        .confirmationDialog("Save changes before closing?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Save Changes") { save(close: true) }
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: state.spatialCalibrationContext?.id) { id in
            if let context, id != context.id { request = UUID(); playing = nil; self.context = nil }
        }
    }

    private func roomMap(_ topology: SpeakerTopology) -> some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 12, geometry.size.height / 10)
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(Color.secondary.opacity(0.07))
                VStack(spacing: 2) {
                    Image(systemName: "tv").font(.title2)
                    Text("FRONT / SCREEN").font(.caption2)
                }.position(x: geometry.size.width / 2, y: 28)
                ForEach(Array(topology.endpoints.enumerated()), id: \.element.id) { item in
                    let endpoint = item.element
                    let vector = SpeakerLayoutGeometry.vector(endpoint.position)
                    let point = endpoint.position == nil
                        ? CGPoint(x: 40 + CGFloat(item.offset % 12) * 50, y: geometry.size.height - 35)
                        : CGPoint(x: geometry.size.width / 2 + CGFloat(vector.x) * scale,
                                  y: geometry.size.height / 2 - CGFloat(vector.y) * scale)
                    speakerNode(endpoint)
                        .position(point)
                        .highPriorityGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("speakerRoom"))
                            .onChanged { value in
                                guard !listeningOnly, !busy, playing == nil,
                                      let index = draft?.endpoints.firstIndex(where: { $0.id == endpoint.id }) else { return }
                                selected = endpoint.id
                                let x = Float((value.location.x - geometry.size.width / 2) / scale)
                                let y = Float((geometry.size.height / 2 - value.location.y) / scale)
                                draft?.endpoints[index].position = SpeakerLayoutGeometry.position(
                                    x: min(5.5, max(-5.5, x)), y: min(4, max(-4, y)), height: vector.z)
                                draft?.endpoints[index].positionSource = .userPlacement
                                updateDistances()
                            }, including: listeningOnly ? .subviews : .all)
                }
                Image(systemName: "person.fill").font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .padding(10).background(.background, in: Circle())
                    .position(x: geometry.size.width / 2 + CGFloat(seat?.roomX ?? 0) * scale,
                              y: geometry.size.height / 2 - CGFloat(seat?.roomY ?? 0) * scale)
                    .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("speakerRoom"))
                        .onChanged { value in
                            guard !busy, playing == nil else { return }
                            seat?.roomX = min(5, max(-5, Float((value.location.x - geometry.size.width / 2) / scale)))
                            seat?.roomY = min(4, max(-4, Float((geometry.size.height / 2 - value.location.y) / scale)))
                            seat?.useMeasuredAlignment = false
                            updateDistances()
                        })
                    .accessibilityLabel("Listener position")
            }.coordinateSpace(name: "speakerRoom")
        }.frame(height: 370)
    }

    private func speakerNode(_ endpoint: SpeakerEndpoint) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 2) {
                Button {
                    selected = endpoint.id
                    if playing == endpoint.id { stop() }
                    else if canTest { stop(); audition(endpoint.id) }
                } label: {
                    Image(systemName: playing == endpoint.id ? "stop.circle.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(playing == endpoint.id ? Color.orange : Color.accentColor)
                }.buttonStyle(.plain)
                    .help(playing == endpoint.id ? "Stop identification" : "Identify output \(endpoint.id.channelIndex + 1)")
                    .accessibilityLabel(playing == endpoint.id ? "Stop identification" : "Identify \(endpoint.displayName)")
                if !listeningOnly {
                    Menu {
                        Button("Disabled") { setRole(nil, for: endpoint.id) }
                        Divider()
                        ForEach(ChannelRole.allCases, id: \.self) { role in
                            Button(role == .unknown ? "Custom / Unknown" : role.displayName) { setRole(role, for: endpoint.id) }
                        }
                    } label: { Image(systemName: "chevron.down").font(.caption2) }
                    .menuStyle(.borderlessButton).fixedSize().disabled(playing != nil || busy)
                }
            }
            if editingTitle == endpoint.id {
                TextField("Speaker title", text: titleBinding(endpoint.id))
                    .textFieldStyle(.plain).frame(width: 110).focused($titleFocused, equals: endpoint.id)
                    .onSubmit { editingTitle = nil }
                    .onExitCommand { editingTitle = nil }
            } else {
                HStack(spacing: 3) {
                    Text(endpoint.displayName).lineLimit(1)
                    if !listeningOnly {
                        Button { editingTitle = endpoint.id; titleFocused = endpoint.id } label: {
                            Image(systemName: "pencil")
                        }.buttonStyle(.plain).help("Rename speaker")
                    }
                }.font(.caption).frame(maxWidth: 115)
            }
            if selected == endpoint.id {
                Text("≈ \(SpeakerLayoutGeometry.distance(from: endpoint.position, listenerX: seat?.roomX ?? 0, listenerY: seat?.roomY ?? 0), specifier: "%.2f") m")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }.padding(5)
            .background(selected == endpoint.id ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .opacity(endpoint.connectionState == .disabledByUser ? 0.4 : 1)
            .onTapGesture { selected = endpoint.id }
    }

    private func titleBinding(_ id: PhysicalOutputID) -> Binding<String> {
        Binding(get: { draft?.endpoints.first(where: { $0.id == id })?.displayName ?? "" }, set: { value in
            guard let index = draft?.endpoints.firstIndex(where: { $0.id == id }) else { return }
            draft?.endpoints[index].displayName = String(value.prefix(80))
        })
    }

    private func setRole(_ role: ChannelRole?, for id: PhysicalOutputID) {
        guard let index = draft?.endpoints.firstIndex(where: { $0.id == id }), var endpoint = draft?.endpoints[index] else { return }
        SpeakerLayoutGeometry.setRole(role, on: &endpoint)
        draft?.endpoints[index] = endpoint
        selected = id
        updateDistances()
    }

    private func heightEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Height relative to your head")
                TextField("Metres", value: Binding(get: {
                    SpeakerLayoutGeometry.vector(draft?.endpoints[index].position).z
                }, set: { height in
                    guard height.isFinite else { return }
                    let point = SpeakerLayoutGeometry.vector(draft?.endpoints[index].position)
                    draft?.endpoints[index].position = SpeakerLayoutGeometry.position(x: point.x, y: point.y, height: min(10, max(-10, height)))
                    draft?.endpoints[index].positionSource = .userPlacement
                    updateDistances()
                }), format: .number.precision(.fractionLength(2))).frame(width: 70)
                Text("m").foregroundStyle(.secondary)
            }
            Text("Estimate how much higher (+) or lower (−) the speaker is than your head.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(playing != nil || busy)
    }

    private func updateDistances() {
        guard let draft else { return }
        for endpoint in draft.endpoints where endpoint.connectionState != .disabledByUser {
            let distance = SpeakerLayoutGeometry.distance(from: endpoint.position, listenerX: seat?.roomX ?? 0, listenerY: seat?.roomY ?? 0)
            if endpoint.role == .left { seat?.leftDistanceMeters = distance }
            if endpoint.role == .right { seat?.rightDistanceMeters = distance }
        }
    }

    private func close() {
        stop()
        if saved { dismiss() } else { confirmClose = true }
    }

    private func save(close: Bool) {
        stop()
        guard var value = draft, let seat else { return }
        do {
            guard let originalProfile, originalProfile.id == profile.id,
                  originalProfile.outputDeviceUID == profile.outputDeviceUID,
                  originalProfile.speakerTopology == profile.speakerTopology,
                  originalProfile.spatialSettings == profile.spatialSettings else {
                throw ProfileSettingsError.runtime("The speaker configuration changed. Close and reopen this editor before saving.")
            }
            try value.validate()
            guard !seat.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProfileSettingsError.runtime("Enter a listening-position name.")
            }
            value.updatedAt = Date()
            if draftOnly {
                profile.speakerTopology = value
                profile.spatialSettings.seating = seat
                draft = value; originalSeat = seat; self.originalProfile = profile
                if close { dismiss() }
            } else {
                var settings = ProfileSettingsDraft(profile: profile, activation: state.profiles.activationMode(for: profile))
                settings.speakerTopology = value
                settings.spatialSettings.seating = seat
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        try await state.saveProfileSettings(settings)
                        draft = value; originalSeat = seat; self.originalProfile = state.profiles.profiles.first { $0.id == profile.id }
                        if close { dismiss() }
                    } catch { message = error.localizedDescription }
                }
            }
        } catch { message = error.localizedDescription }
    }

    private func discover() {
        busy = true; message = nil
        let uid = profile.outputDeviceUID
        Task {
            defer { busy = false }
            do {
                guard let device = await state.coreAudio.resolveDeviceWithoutBlockingUI(uid: uid) else {
                    throw SpeakerTopologyProbe.ProbeError.malformedProperty
                }
                var found = try await Task.detached(priority: .userInitiated) { try SpeakerTopologyProbe().probe(device) }.value
                guard profile.outputDeviceUID == uid else { return }
                // Use the profile's requested processing rate; activation negotiates it.
                found.sampleRate = Double(profile.sampleRate)
                draft = found; selected = found.endpoints.first?.id
            } catch { message = error.localizedDescription }
        }
    }

    private func audition(_ output: PhysicalOutputID) {
        guard canTest, let topology = draft, let context = state.beginSpatialCalibration(profileID: profile.id) else {
            message = "Activate this saved profile before testing its outputs."; return
        }
        self.context = context
        let token = UUID(); request = token; playing = output
        state.pcmRouter.holdSpatialMeasurement(id: context.id, enabled: true)
        Task {
            let clip = await Task.detached(priority: .userInitiated) { SpatialCalibrationClip(physicalOutput: output, topology: topology) }.value
            guard request == token else { return }
            guard let clip, state.playSpatialCalibration(context: context, clip: clip, tuning: .neutral, completion: {
                Task { @MainActor in if request == token { stop() } }
            }) else { stop(); message = "The output changed or this channel is disabled. Save and activate the profile again."; return }
        }
    }

    private func stop() {
        request = UUID(); playing = nil
        if let context {
            state.pcmRouter.stopSpatialCalibrationSample(id: context.id)
            state.endSpatialCalibration(id: context.id)
        }
        context = nil
    }
}
