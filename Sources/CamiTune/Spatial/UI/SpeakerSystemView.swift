import SwiftUI

@MainActor
struct SpeakerSystemView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SpeakerTopology?
    @State private var selected: PhysicalOutputID?
    @State private var group: SpeakerLayer = .floor
    @State private var busy = false
    @State private var message: String?
    @State private var context: SpatialCalibrationContext?
    @State private var playing: PhysicalOutputID?
    @State private var request = UUID()

    private var saved: Bool { draft == profile.speakerTopology }
    private var canTest: Bool {
        saved && profile.playbackMode == .referencePlayback
            && state.isActive && state.activeProfileID == profile.id && !busy
    }
    private var visibleEndpoints: [SpeakerEndpoint] {
        guard let draft else { return [] }
        return draft.endpoints.count > 12 ? draft.endpoints.filter { $0.layer == group } : draft.endpoints
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your speaker system").font(.title2.bold())
            HStack {
                Text(draft.map { "\($0.declaredChannelCount) controllable outputs" } ?? "Discover the outputs on this device.")
                Spacer()
                Button("Discover outputs") { discover() }.disabled(busy || playing != nil)
            }
            if let draft {
                if draft.endpoints.count > 12 {
                    Picker("Speaker layer", selection: $group) {
                        Text("Floor").tag(SpeakerLayer.floor)
                        Text("Height").tag(SpeakerLayer.height)
                        Text("Subwoofers").tag(SpeakerLayer.subwoofer)
                        Text("Unplaced").tag(SpeakerLayer.custom)
                    }.pickerStyle(.segmented)
                }
                roomMap
                Text("Select a speaker to edit it, or drag it to match your room.").font(.caption).foregroundStyle(.secondary)
                if let index = draft.endpoints.firstIndex(where: { $0.id == selected }) {
                    endpointEditor(index: index)
                }
                Text("Reference preserves source channels. Stereo stays in the front pair. Unknown source channels and LFE without a subwoofer stay silent.")
                    .font(.caption).foregroundStyle(.secondary)
                if profile.playbackMode == .referencePlayback {
                    Text("Save and activate this profile, then test each output to confirm the channel order. Connected speakers need a role or a position before they can reproduce a scene.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Test selected output") { if let selected { audition(selected) } }
                        .disabled(!canTest || selected == nil || playing != nil)
                    Button("Stop") { stop() }.disabled(playing == nil)
                    if let playing { Text("Playing output \(playing.channelIndex + 1)…").font(.caption) }
                }
            }
            if state.isActive && state.activeProfileID == profile.id {
                DisclosureGroup("Playback diagnostics") {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        VStack(alignment: .leading, spacing: 4) {
                            if let render = state.pcmRouter.referenceSpeakerDiagnostics {
                                Text("Reference: \(render.outputChannels) outputs · \(render.unmappedObjects) unmapped source channels · \(render.geometryFallbacks) geometry fallbacks")
                                Text("Headroom: \(render.headroomDB, specifier: "%.1f") dB")
                            }
                            ForEach(state.perAppAudio.spatialInputDiagnostics.keys.sorted {
                                $0.deviceObjectID == $1.deviceObjectID ? $0.clientID < $1.clientID : $0.deviceObjectID < $1.deviceObjectID
                            }, id: \.self) { key in
                                if let input = state.perAppAudio.spatialInputDiagnostics[key] {
                                    Text("Source \(key.clientID): declared \(input.declaredLayout.channelCount) channels · proven \(input.capability.rawValue) · active \(input.activeChannels.count)")
                                }
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Save") { save() }.disabled(draft == nil || busy || playing != nil || saved)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 660)
        .onAppear { draft = profile.speakerTopology }
        .onDisappear { stop() }
        .onChange(of: state.spatialCalibrationContext?.id) { id in
            if let context, id != context.id { request = UUID(); playing = nil; self.context = nil }
        }
    }

    private var roomMap: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(Color.secondary.opacity(0.07))
                Text("SCREEN / FRONT").font(.caption).position(x: geometry.size.width / 2, y: 18)
                Image(systemName: "person.fill").position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                ForEach(Array(visibleEndpoints.enumerated()), id: \.element.id) { item in
                    let endpoint = item.element
                    let vector = endpoint.position?.unitVector
                    let point = CGPoint(
                        x: vector.map { geometry.size.width * (0.5 + Double($0.x) * 0.39) }
                            ?? (30 + Double(item.offset % 12) * 48),
                        y: vector.map { geometry.size.height * (0.5 - Double($0.y) * 0.35) }
                            ?? (geometry.size.height - 28))
                    Button { selected = endpoint.id } label: {
                        VStack(spacing: 2) {
                            Image(systemName: endpoint.layer == .subwoofer ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
                            Text("\(endpoint.id.channelIndex + 1) · \(endpoint.role.shortName)").font(.caption2)
                        }.padding(5)
                    }.buttonStyle(.bordered)
                        .tint(selected == endpoint.id ? .accentColor : .secondary)
                        .opacity(endpoint.connectionState == .disabledByUser ? 0.4 : 1)
                        .position(point)
                        .simultaneousGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("speakerRoom"))
                            .onChanged { value in
                                guard playing == nil, let index = self.draft?.endpoints.firstIndex(where: { $0.id == endpoint.id }), endpoint.layer != .subwoofer else { return }
                                selected = endpoint.id
                                let x = Float((value.location.x / geometry.size.width - 0.5) / 0.39)
                                let y = Float((0.5 - value.location.y / geometry.size.height) / 0.35)
                                guard x*x+y*y > 0.001 else { return }
                                var azimuth = atan2(x,y) * 180 / Float.pi
                                if azimuth >= 180 { azimuth -= 360 }
                                var position = endpoint.position ?? SpatialPosition(azimuthDegrees: 0, elevationDegrees: 0)
                                position.azimuthDegrees = azimuth
                                self.draft?.endpoints[index].position = position
                                self.draft?.endpoints[index].positionSource = .userPlacement
                                if endpoint.layer == .custom { self.draft?.endpoints[index].layer = .floor }
                            })
                        .accessibilityLabel("Output \(endpoint.id.channelIndex + 1), \(endpoint.displayName)")
                }
            }.coordinateSpace(name: "speakerRoom")
        }.frame(height: 290)
    }

    @ViewBuilder private func endpointEditor(index: Int) -> some View {
        if let endpoint = draft?.endpoints[index] {
            VStack(alignment: .leading, spacing: 8) {
                Text("Output \(endpoint.id.channelIndex + 1)").font(.headline)
                TextField("Speaker name", text: Binding(get: { draft?.endpoints[index].displayName ?? "" },
                    set: { draft?.endpoints[index].displayName = String($0.prefix(80)) }))
                HStack {
                    Picker("Role", selection: Binding(get: { draft?.endpoints[index].role ?? .unknown }, set: { role in
                        draft?.endpoints[index].role = role
                        draft?.endpoints[index].layer = role.speakerLayer
                        draft?.endpoints[index].isSubwooferLike = role == .lowFrequencyEffects
                        draft?.endpoints[index].position = StandardSpeakerPositions.position(for: role)
                        draft?.endpoints[index].positionSource = role == .unknown ? .unknown : .standardLayoutDefault
                    })) {
                        ForEach(ChannelRole.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("Connection", selection: Binding(get: { draft?.endpoints[index].connectionState ?? .unknown },
                        set: { draft?.endpoints[index].connectionState = $0 })) {
                        Text("Unchecked").tag(SpeakerConnectionState.unknown)
                        Text("Confirmed by listening").tag(SpeakerConnectionState.confirmedByUser)
                        Text("Silent").tag(SpeakerConnectionState.silent)
                        Text("Disabled").tag(SpeakerConnectionState.disabledByUser)
                        if endpoint.connectionState == .acousticallyDetected {
                            Text("Measured").tag(SpeakerConnectionState.acousticallyDetected)
                        }
                    }
                }
                if endpoint.layer != .subwoofer {
                    HStack {
                        Text("Direction \(Int(endpoint.position?.azimuthDegrees ?? 0))°").frame(width: 115, alignment: .leading)
                        Slider(value: angle(index, elevation: false), in: -180...179)
                        Text("Height \(Int(endpoint.position?.elevationDegrees ?? 0))°").frame(width: 90)
                        Slider(value: angle(index, elevation: true), in: -90...90)
                    }
                }
            }.disabled(playing != nil)
        }
    }

    private func angle(_ index: Int, elevation: Bool) -> Binding<Float> {
        Binding(get: {
            let position = draft?.endpoints[index].position
            return (elevation ? position?.elevationDegrees : position?.azimuthDegrees) ?? 0
        }, set: { value in
            var position = draft?.endpoints[index].position ?? SpatialPosition(azimuthDegrees: 0, elevationDegrees: 0)
            if elevation { position.elevationDegrees = value } else { position.azimuthDegrees = value }
            draft?.endpoints[index].position = position
            draft?.endpoints[index].positionSource = .userPlacement
            draft?.endpoints[index].layer = position.elevationDegrees > 10 ? .height : .floor
        })
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

    private func save() {
        stop()
        guard var value = draft else { return }
        do {
            try value.validate()
            value.updatedAt = Date()
            draft = value
            profile.speakerTopology = value
            state.profiles.update(profile)
            let updated = profile
            Task { await state.apply(profile: updated) }
        } catch { message = error.localizedDescription }
    }

    private func audition(_ output: PhysicalOutputID) {
        guard let topology = draft, let context = state.beginSpatialCalibration(profileID: profile.id) else {
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
