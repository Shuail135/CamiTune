import SwiftUI

/// One local value owns every step. No profile exists in the store until Add.
struct AddOutputDraft {
    static let incompleteMessage = "Configure all required items before adding the profile."
    var profile = DeviceProfile(name: "", outputDeviceUID: "", outputDeviceName: "")
    var deviceType: ProfileEndpointKind?
    var discovered: SpeakerTopology?
    var connectedEndpoint: ProfileEndpointKind?
    var leftOutput: Int?
    var rightOutput: Int?
    var speakerConfigurationConfirmed = false

    var needsSpeakers: Bool { deviceType == .speakers || (deviceType == .audioInterface && connectedEndpoint == .speakers) }
    var canAdd: Bool { (try? candidate()) != nil }

    mutating func selectDevice(_ device: AudioDeviceInfo, name: String) {
        profile.outputDevice = PhysicalOutputIdentity(uid: device.id, name: device.name)
        profile.name = name
        profile.speakerTopology = nil
        profile.spatialSettings = SpatialRenderSettings()
        discovered = nil
        leftOutput = nil
        rightOutput = nil
        speakerConfigurationConfirmed = false
    }

    func candidate() throws -> DeviceProfile {
        guard let deviceType, !profile.outputDeviceUID.isEmpty,
              !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [44100, 48000, 88200, 96000, 176400, 192000].contains(profile.sampleRate) else {
            throw ProfileSettingsError.runtime(Self.incompleteMessage)
        }
        var candidate = profile
        candidate.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.endpointKind = deviceType
        candidate.setPlaybackMode(.direct)
        if deviceType == .audioInterface {
            guard let discovered, let connectedEndpoint, let leftOutput, let rightOutput else {
                throw ProfileSettingsError.runtime(Self.incompleteMessage)
            }
            let assignment = AudioInterfaceConfiguration(deviceUID: discovered.deviceUID,
                hardwareChannelCount: discovered.declaredChannelCount,
                outputChannels: [leftOutput, rightOutput], connectedEndpoint: connectedEndpoint)
            try assignment.validate(deviceUID: candidate.outputDeviceUID)
            candidate.audioInterface = assignment
        }
        if needsSpeakers {
            guard speakerConfigurationConfirmed, var topology = candidate.speakerTopology,
                  topology.deviceUID == candidate.outputDeviceUID,
                  topology.sampleRate == Double(candidate.sampleRate),
                  let seat = candidate.spatialSettings.seating,
                  seat.outputDeviceUID == candidate.outputDeviceUID,
                  !seat.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seat.leftDistanceMeters.isFinite, seat.rightDistanceMeters.isFinite,
                  seat.leftDistanceMeters > 0, seat.rightDistanceMeters > 0 else {
                throw ProfileSettingsError.runtime(Self.incompleteMessage)
            }
            if let assignment = candidate.audioInterface, deviceType == .audioInterface {
                for index in topology.endpoints.indices where !assignment.outputChannels.contains(topology.endpoints[index].id.channelIndex) {
                    topology.endpoints[index].connectionState = .disabledByUser
                }
            }
            try topology.validate()
            let enabled = topology.endpoints.filter { $0.connectionState != .disabledByUser }
            guard !enabled.isEmpty, enabled.allSatisfy({ $0.role != .unknown || $0.position != nil }) else {
                throw ProfileSettingsError.runtime(Self.incompleteMessage)
            }
            for index in topology.endpoints.indices where topology.endpoints[index].connectionState == .unknown {
                topology.endpoints[index].connectionState = .confirmedByUser
            }
            candidate.speakerTopology = topology
        }
        return candidate
    }
}

@MainActor
struct AddOutputProfileSheet: View {
    let state: AppState
    @ObservedObject private var audio: CoreAudioManager
    @ObservedObject private var store: ProfileStore
    let onCancel: @MainActor () -> Void
    let onAdded: @MainActor (UUID) -> Void
    @State private var draft = AddOutputDraft()
    @State private var step = 0
    @State private var movingForward = true
    @State private var busy = false
    @State private var message: String?
    @State private var showingSpeakerEditor = false
    @FocusState private var nameFocused: Bool
    private let steps = ["Choose Output", "Quick Configuration", "Device Configuration", "Review"]

    init(state: AppState, initialUID: String?, onCancel: @escaping @MainActor () -> Void, onAdded: @escaping @MainActor (UUID) -> Void) {
        self.state = state
        _audio = ObservedObject(wrappedValue: state.coreAudio)
        _store = ObservedObject(wrappedValue: state.profiles)
        self.onCancel = onCancel
        self.onAdded = onAdded
        var initial = AddOutputDraft()
        if let device = state.coreAudio.physicalOutputDevices.first(where: { $0.id == initialUID }) {
            initial.selectDevice(device, name: ProfileNamePolicy.uniqueName(base: device.name, existingNames: state.profiles.profiles.map(\.name)))
        }
        _draft = State(initialValue: initial)
    }

    private var connected: Bool { audio.physicalOutputDevices.contains { $0.id == draft.profile.outputDeviceUID } }
    private var canProceed: Bool {
        switch step {
        case 0: return connected
        case 1: return draft.deviceType != nil && !draft.profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return connected && draft.canAdd
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Output Profile").font(.title.bold())
            Text("Step \(step + 1) of 4 · \(steps[step])").font(.headline)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { stepContent }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(2)
                    .id(step)
                    .transition(.asymmetric(insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity)))
            }
            if let message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            if !connected { Text("Connect the selected output device to continue.").foregroundStyle(.secondary) }
            Divider()
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if step > 0 { Button("Back") { move(to: step - 1) } }
                if step == 3 {
                    Button("Add Profile") { add() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canProceed)
                } else {
                    Button("Next") {
                        guard canProceed else { incomplete(); return }
                        move(to: step + 1)
                    }.keyboardShortcut(.defaultAction).disabled(!canProceed)
                }
            }
        }
        .padding(24).frame(width: 650, height: 570)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .sheet(isPresented: $showingSpeakerEditor) {
            SpeakerSystemView(state: state, profile: $draft.profile, draftOnly: true)
        }
        .onSubmit { if step == 3 { add() } }
        .onChange(of: draft.profile.speakerTopology) { _ in draft.speakerConfigurationConfirmed = false }
        .onChange(of: draft.deviceType) { _ in draft.speakerConfigurationConfirmed = false }
        .onChange(of: draft.connectedEndpoint) { _ in draft.speakerConfigurationConfirmed = false }
        .onChange(of: draft.leftOutput) { _ in draft.speakerConfigurationConfirmed = false }
        .onChange(of: draft.rightOutput) { _ in draft.speakerConfigurationConfirmed = false }
        .onChange(of: draft.profile.sampleRate) { rate in
            draft.profile.speakerTopology?.sampleRate = Double(rate)
            draft.speakerConfigurationConfirmed = false
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case 0:
            Text("Choose the physical audio output for this profile.")
            if audio.physicalOutputDevices.isEmpty {
                Text("No physical outputs are connected.").foregroundStyle(.secondary)
            }
            ForEach(audio.physicalOutputDevices) { device in
                Button {
                    draft.selectDevice(device, name: ProfileNamePolicy.uniqueName(base: device.name, existingNames: store.profiles.map(\.name)))
                } label: {
                    HStack {
                        Image(systemName: "speaker.wave.2")
                        Text(device.name)
                        Spacer()
                        if draft.profile.outputDeviceUID == device.id { Image(systemName: "checkmark") }
                    }.padding(8).contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
            }
            Button("Refresh Outputs") { Task { await audio.refreshWithoutBlockingUI() } }
        case 1:
            TextField("Profile name", text: $draft.profile.name).focused($nameFocused)
            Picker("Device Type", selection: $draft.deviceType) {
                Text("Choose a device type").tag(ProfileEndpointKind?.none)
                ForEach(ProfileEndpointKind.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
            }
            Picker("Processing Sample Rate", selection: $draft.profile.sampleRate) {
                ForEach([44100, 48000, 88200, 96000, 176400, 192000], id: \.self) {
                    Text("\(Double($0) / 1000, specifier: "%g") kHz").tag($0)
                }
            }
            Text("48 kHz is recommended. Device support is checked before the profile is added.").foregroundStyle(.secondary)
        case 2:
            if draft.deviceType == .audioInterface {
                Text("Choose the stereo pair of hardware outputs used by this profile. All other interface outputs remain silent for this profile.")
                discoveryControls
                if let topology = draft.discovered {
                    Picker("Left Output", selection: $draft.leftOutput) { outputOptions(topology) }
                    Picker("Right Output", selection: $draft.rightOutput) { outputOptions(topology) }
                }
                Picker("Connected Device", selection: $draft.connectedEndpoint) {
                    Text("Choose what is connected").tag(ProfileEndpointKind?.none)
                    ForEach(ProfileEndpointKind.allCases.filter { $0 != .audioInterface }, id: \.self) {
                        Text($0.displayName).tag(Optional($0))
                    }
                }
            }
            if draft.needsSpeakers {
                if draft.deviceType == .speakers { discoveryControls }
                Button("Speaker and Listening Position…") { showingSpeakerEditor = true }
                    .disabled(draft.profile.speakerTopology == nil)
                Text("Place the detected speakers relative to your listening position and assign a role or position to each output in use.")
                    .foregroundStyle(.secondary)
                if draft.profile.spatialSettings.seating != nil {
                    TextField("Listening position", text: Binding(
                        get: { draft.profile.spatialSettings.seating?.name ?? "Primary" },
                        set: { draft.profile.spatialSettings.seating?.name = $0 }))
                    distanceField("Left speaker distance (m)", left: true)
                    distanceField("Right speaker distance (m)", left: false)
                }
                Toggle("Speaker layout and listening position are configured", isOn: $draft.speakerConfigurationConfirmed)
            } else if draft.deviceType != .audioInterface {
                Text("No additional configuration is required for \(draft.deviceType?.displayName ?? "this output").")
                Text("The profile starts in Direct. You can adjust its processing after adding it.").foregroundStyle(.secondary)
            }
        default:
            LabeledContent("Profile", value: draft.profile.name)
            LabeledContent("Output Device", value: draft.profile.outputDeviceName)
            LabeledContent("Device Type", value: draft.deviceType?.displayName ?? "Not selected")
            LabeledContent("Processing Sample Rate", value: "\(Double(draft.profile.sampleRate) / 1000) kHz")
            LabeledContent("Mode", value: "Direct")
            if draft.deviceType == .audioInterface {
                LabeledContent("Hardware Outputs", value: "Left: \((draft.leftOutput ?? -1) + 1), Right: \((draft.rightOutput ?? -1) + 1)")
                LabeledContent("Connected Device", value: draft.connectedEndpoint?.displayName ?? "Not selected")
            }
            if draft.needsSpeakers {
                LabeledContent("Listening Position", value: draft.profile.spatialSettings.seating?.name ?? "Primary")
            }
            Text("The completed profile will be added when you choose Add Profile.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func outputOptions(_ topology: SpeakerTopology) -> some View {
        Text("Choose an output").tag(Int?.none)
        ForEach(topology.endpoints) { endpoint in
            Text("\(endpoint.id.channelIndex + 1) · \(endpoint.displayName)").tag(Optional(endpoint.id.channelIndex))
        }
    }
    private var discoveryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Discover Outputs") { discover() }
            if let discovered = draft.discovered { Text("\(discovered.declaredChannelCount) independently addressable outputs").foregroundStyle(.secondary) }
        }
    }
    private func distanceField(_ title: String, left: Bool) -> some View {
        TextField(title, value: Binding<Float>(
            get: { left ? (draft.profile.spatialSettings.seating?.leftDistanceMeters ?? 1) : (draft.profile.spatialSettings.seating?.rightDistanceMeters ?? 1) },
            set: {
                if left { draft.profile.spatialSettings.seating?.leftDistanceMeters = $0 }
                else { draft.profile.spatialSettings.seating?.rightDistanceMeters = $0 }
                draft.speakerConfigurationConfirmed = false
            }), format: .number)
    }
    private func move(to next: Int) {
        movingForward = next > step
        message = nil
        withAnimation(.easeInOut(duration: 0.18)) { step = next }
    }
    private func incomplete() {
        message = AddOutputDraft.incompleteMessage
        if draft.profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            step = 1; nameFocused = true
        }
    }
    private func discover() {
        guard !busy else { return }
        busy = true; message = nil
        let uid = draft.profile.outputDeviceUID
        Task {
            defer { busy = false }
            do {
                guard let device = await audio.resolveDeviceWithoutBlockingUI(uid: uid) else { throw AppState.AppError.outputMissing(draft.profile.outputDeviceName) }
                var topology = try await Task.detached(priority: .userInitiated) { try SpeakerTopologyProbe().probe(device) }.value
                guard draft.profile.outputDeviceUID == uid else { return }
                topology.sampleRate = Double(draft.profile.sampleRate)
                draft.discovered = topology
                draft.profile.speakerTopology = topology
                draft.profile.spatialSettings.seating = SpatialSeatingCalibration(outputDeviceUID: uid, name: "Primary")
                draft.leftOutput = nil; draft.rightOutput = nil
                draft.speakerConfigurationConfirmed = false
            } catch { message = error.localizedDescription }
        }
    }
    private func add() {
        guard !busy else { return }
        guard canProceed else { incomplete(); return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do { onAdded(try await state.addProfile(from: draft)) }
            catch { message = error.localizedDescription }
        }
    }
}
