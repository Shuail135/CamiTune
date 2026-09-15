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
    var selectedOutputs: Set<Int> = []

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
        selectedOutputs = []
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
            guard let discovered, let connectedEndpoint else {
                throw ProfileSettingsError.runtime(Self.incompleteMessage)
            }
            let assignment = AudioInterfaceConfiguration(deviceUID: discovered.deviceUID,
                hardwareChannelCount: discovered.declaredChannelCount,
                outputChannels: selectedOutputs.isEmpty ? [leftOutput, rightOutput].compactMap { $0 } : selectedOutputs.sorted(), connectedEndpoint: connectedEndpoint)
            try assignment.validate(deviceUID: candidate.outputDeviceUID)
            candidate.audioInterface = assignment
        }
        if needsSpeakers {
            guard var topology = candidate.speakerTopology,
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
                for index in topology.endpoints.indices where !assignment.hardware.enabledHardwareOutputs.contains(topology.endpoints[index].id.channelIndex) {
                    topology.endpoints[index].connectionState = .disabledByUser
                }
            }
            try topology.validate()
            let enabled = topology.endpoints.filter { $0.connectionState != .disabledByUser }
            guard !enabled.isEmpty, enabled.allSatisfy({ $0.role != .unknown || $0.position != nil }) else {
                throw ProfileSettingsError.runtime(Self.incompleteMessage)
            }
            candidate.speakerTopology = SpeakerLayoutGeometry.acceptingDefaultRoles(topology)
        }
        try candidate.migrateInterfaceTopology()
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
    @FocusState private var nameFocused: Bool
    @State private var nameHovered = false
    @State private var pageContentHeight: CGFloat = 0
    @State private var deviceTypePickerWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let pageTitles = ["Choose an output and configure its profile.", "Device Configuration"]
    private var lastStep: Int {
        switch draft.deviceType {
        case .headphones, .iem, .custom: return 0
        default: return 1
        }
    }
    private var selectedDevice: Binding<String?> {
        Binding(get: { draft.profile.outputDeviceUID.isEmpty ? nil : draft.profile.outputDeviceUID }, set: { uid in
            guard let device = audio.physicalOutputDevices.first(where: { $0.id == uid }),
                  device.id != draft.profile.outputDeviceUID else { return }
            draft.selectDevice(device, name: ProfileNamePolicy.uniqueName(base: device.name, existingNames: store.profiles.map(\.name)))
        })
    }

    init(state: AppState, initialUID: String?, onCancel: @escaping @MainActor () -> Void, onAdded: @escaping @MainActor (UUID) -> Void) {
        self.state = state
        _audio = ObservedObject(wrappedValue: state.coreAudio)
        _store = ObservedObject(wrappedValue: state.profiles)
        self.onCancel = onCancel
        self.onAdded = onAdded
        var initial = AddOutputDraft()
        let devices = state.coreAudio.physicalOutputDevices
        if let device = devices.first(where: { $0.id == initialUID }) ?? devices.first {
            initial.selectDevice(device, name: ProfileNamePolicy.uniqueName(base: device.name, existingNames: state.profiles.profiles.map(\.name)))
        }
        _draft = State(initialValue: initial)
    }

    private var connected: Bool { audio.physicalOutputDevices.contains { $0.id == draft.profile.outputDeviceUID } }
    private var canProceed: Bool {
        switch step {
        case 0: return connected && draft.deviceType != nil && !draft.profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (lastStep != 0 || draft.canAdd)
        default: return connected && draft.canAdd
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "speaker.wave.2.circle.fill")
                    .font(.system(size: 38)).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add Output Profile").font(.title2.bold())
                    Text(pageTitles[step]).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            ZStack(alignment: .topLeading) {
                stepPage
                    .id(step)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3), value: step)
            if let message {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 12)
            }
            if !connected && !draft.profile.outputDeviceUID.isEmpty {
                Text("Connect the selected output device to continue.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 12)
            }
            Divider()
            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if step > 0 { Button("Back") { move(to: step - 1) }.frame(minWidth: 70) }
                Button(step == lastStep ? "Add Profile" : "Next") {
                    guard canProceed else { incomplete(); return }
                    if step == lastStep { add() } else { move(to: step + 1) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canProceed)
            }.controlSize(.regular).padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 780, height: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .onChange(of: draft.profile.sampleRate) { rate in
            draft.profile.speakerTopology?.sampleRate = Double(rate)
        }
    }

    private var stepPage: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if step == 0 {
                        profileSettings
                    } else {
                        deviceConfiguration
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .background {
                    GeometryReader { content in
                        Color.clear.preference(key: OutputProfilePageHeightKey.self, value: content.size.height)
                    }
                }
            }
            .scrollDisabled(pageContentHeight <= viewport.size.height)
            .onPreferenceChange(OutputProfilePageHeightKey.self) { pageContentHeight = $0 }
        }
    }

    private var outputChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            List(selection: selectedDevice) {
                ForEach(audio.physicalOutputDevices) { device in
                    Label(device.name, systemImage: "speaker.wave.2")
                        .padding(.vertical, 8)
                        .tag(device.id)
                }
            }
            // The device list can overflow independently of the page.
            .environment(\.isScrollEnabled, true)
            .listStyle(.inset)
            .frame(height: min(228, max(163, CGFloat(audio.physicalOutputDevices.count) * 40 + 12)))
            .overlay {
                if audio.physicalOutputDevices.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "speaker.slash").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No Audio Outputs").font(.headline)
                        Text("Connect an audio device, then click Refresh.").foregroundStyle(.secondary)
                    }.allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Available audio outputs")
            HStack {
                Text("Choose the device this profile will play through.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await audio.refreshWithoutBlockingUI() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh audio outputs")
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .fixedSize()
                .help("Refresh connected audio outputs")
            }

        }
    }

    private var profileSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox { outputChooser.padding(8) } label: { Text("Audio Output") }
            GroupBox {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        Text("Profile Name")
                        TextField("Choose an output", text: $draft.profile.name)
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .focused($nameFocused)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Profile Name")
                        Image(systemName: "pencil")
                            .font(.caption).foregroundStyle(.secondary)
                            .opacity(nameHovered || nameFocused ? 1 : 0.6)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { nameFocused = true }
                    .onHover { nameHovered = $0 }
                    .background(Color.primary.opacity(0.065))
                    Divider()
                    HStack {
                        Text("Device Type")
                        Spacer()
                        WizardDeviceTypePicker(selection: $draft.deviceType).fixedSize()
                            .background {
                                GeometryReader { picker in
                                    Color.clear.preference(key: OutputProfilePickerWidthKey.self, value: picker.size.width)
                                }
                            }
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } label: { Text("Profile") }
            GroupBox {
                HStack {
                    Text("Sample Rate")
                    Spacer()
                    Picker("Sample Rate", selection: $draft.profile.sampleRate) {
                        ForEach([44100, 48000, 88200, 96000, 176400, 192000], id: \.self) {
                            Text("\(Double($0) / 1000, specifier: "%g") kHz").tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: deviceTypePickerWidth)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            } label: { Text("Audio") }
            Text("48 kHz is the recommended default. Higher rates increase CPU and bandwidth use but do not improve lower rate source audio.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onPreferenceChange(OutputProfilePickerWidthKey.self) { deviceTypePickerWidth = $0 > 0 ? $0 : nil }
    }

    @ViewBuilder private var deviceConfiguration: some View {
            if draft.deviceType == .audioInterface {
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Choose the stereo channel pair and the device connected to it.")
                            .font(.callout).foregroundStyle(.secondary)
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                            if let topology = draft.discovered {
                                GridRow {
                                    Text("Left Channel")
                                    Picker("Left Channel", selection: $draft.leftOutput) { outputOptions(topology) }
                                        .labelsHidden()
                                }
                                GridRow {
                                    Text("Right Channel")
                                    Picker("Right Channel", selection: $draft.rightOutput) { outputOptions(topology) }
                                        .labelsHidden()
                                }
                            }
                            GridRow {
                                Text("Connected Device")
                                Picker("Connected Device", selection: $draft.connectedEndpoint) {
                                    Text("Choose what is connected").tag(ProfileEndpointKind?.none)
                                    ForEach(ProfileEndpointKind.allCases.filter { $0 != .audioInterface }, id: \.self) {
                                        Text($0.displayName).tag(Optional($0))
                                    }
                                }.labelsHidden()
                            }
                        }
                        if draft.connectedEndpoint == .speakers, let topology = draft.discovered {
                            Text("Selected Speaker Channels").font(.headline)
                            ForEach(topology.endpoints) { endpoint in
                                Toggle("Channel \(endpoint.id.channelIndex + 1)", isOn: Binding(
                                    get: { draft.selectedOutputs.contains(endpoint.id.channelIndex) },
                                    set: { if $0 { draft.selectedOutputs.insert(endpoint.id.channelIndex) } else { draft.selectedOutputs.remove(endpoint.id.channelIndex) } }))
                            }
                        }
                        Divider()
                        discoveryControls
                    }.padding(8)
                } label: { Label("Audio Interface", systemImage: "hifispeaker") }
            }
            if draft.needsSpeakers {
                if draft.profile.speakerTopology != nil {
                    SpeakerSystemView(state: state, profile: $draft.profile, draftOnly: true, embedded: true)
                } else if !busy {
                    Text("Channels could not be discovered. Check the connection and try again.").foregroundStyle(.secondary)
                    Button("Discover Channels") { discover() }
                }
            } else if draft.deviceType != .audioInterface {
                Text("No additional configuration is required for \(draft.deviceType?.displayName ?? "this output").")
                Text("The profile starts in Direct. You can adjust its processing after adding it.").foregroundStyle(.secondary)
            }
    }

    @ViewBuilder private func outputOptions(_ topology: SpeakerTopology) -> some View {
        Text("Choose a channel").tag(Int?.none)
        ForEach(topology.endpoints) { endpoint in
            Text("\(endpoint.id.channelIndex + 1) · \(endpoint.displayName)").tag(Optional(endpoint.id.channelIndex))
        }
    }
    private var discoveryControls: some View {
        HStack {
            if let discovered = draft.discovered {
                Text("\(discovered.declaredChannelCount) hardware channels").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh Channels") { discover() }.controlSize(.small)
        }
    }
    private func move(to next: Int) {
        movingForward = next > step
        message = nil
        step = next
        if next == 1, draft.discovered == nil,
           draft.deviceType == .speakers || draft.deviceType == .audioInterface { discover() }
    }
    private func incomplete() {
        message = AddOutputDraft.incompleteMessage
        if draft.profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            step = 0; nameFocused = true
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
                draft.profile.speakerTopology = SpeakerLayoutGeometry.arrangedForEditing(topology)
                draft.profile.spatialSettings.seating = SpatialSeatingCalibration(outputDeviceUID: uid, name: "Default")
                draft.leftOutput = nil; draft.rightOutput = nil
            } catch { message = error.localizedDescription }
        }
    }
    private func add() {
        guard !busy else { return }
        guard connected && draft.canAdd else { incomplete(); return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do { onAdded(try await state.addProfile(from: draft)) }
            catch { message = error.localizedDescription }
        }
    }
}

/// Keep native menu tracking independent of SwiftUI's grouped-form Picker bridge.
/// Selecting a type also changes wizard navigation, so publish after tracking exits.
@MainActor
struct WizardDeviceTypePicker: NSViewRepresentable {
    @Binding var selection: ProfileEndpointKind?

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSPopUpButton { context.coordinator.makeButton() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.updateSelection(button)
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var selection: Binding<ProfileEndpointKind?>
        private var tracking = false
        private var pendingIndex: Int?
        private weak var button: NSPopUpButton?

        init(selection: Binding<ProfileEndpointKind?>) { self.selection = selection }

        func makeButton() -> NSPopUpButton {
            let button = WizardDeviceTypePopUpButton(frame: .zero, pullsDown: false)
            button.controlSize = .regular
            button.addItems(withTitles: ["Choose a device type"] + ProfileEndpointKind.allCases.map(\.displayName))
            button.fitAllTitles()
            button.autoenablesItems = false
            button.target = self
            button.action = #selector(choseType(_:))
            button.menu?.delegate = self
            button.setAccessibilityLabel("Device Type")
            self.button = button
            updateSelection(button)
            return button
        }

        func updateSelection(_ button: NSPopUpButton) {
            guard !tracking else { return }
            let index = selection.wrappedValue.flatMap { ProfileEndpointKind.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            if button.indexOfSelectedItem != index { button.selectItem(at: index) }
        }

        func menuWillOpen(_ menu: NSMenu) { tracking = true }
        func menuDidClose(_ menu: NSMenu) {
            tracking = false
            publishPendingSelection()
        }

        @objc func choseType(_ sender: NSPopUpButton) {
            pendingIndex = sender.indexOfSelectedItem - 1
            publishPendingSelection()
        }

        private func publishPendingSelection() {
            guard !tracking, pendingIndex != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.tracking, let index = self.pendingIndex else { return }
                self.pendingIndex = nil
                self.selection.wrappedValue = ProfileEndpointKind.allCases.indices.contains(index)
                    ? ProfileEndpointKind.allCases[index] : nil
                if let button = self.button { self.updateSelection(button) }
            }
        }
    }
}

/// Use AppKit's own title/arrow/bezel measurement, fixed to the widest option.
@MainActor
final class WizardDeviceTypePopUpButton: NSPopUpButton {
    private var fittedWidth: CGFloat?
    override var intrinsicContentSize: NSSize {
        let native = super.intrinsicContentSize
        return NSSize(width: fittedWidth ?? native.width, height: native.height)
    }
    func fitAllTitles() {
        let original = indexOfSelectedItem
        var width: CGFloat = 0
        for index in 0..<numberOfItems {
            selectItem(at: index)
            width = max(width, super.intrinsicContentSize.width)
        }
        selectItem(at: original)
        fittedWidth = ceil(width)
        invalidateIntrinsicContentSize()
    }
}

private struct OutputProfilePageHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct OutputProfilePickerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
