import SwiftUI
import Foundation

@MainActor
struct ProfilesActivationSettingsView: View {
    let state: AppState
    @ObservedObject private var profileStore: ProfileStore
    @ObservedObject private var coreAudio: CoreAudioManager

    init(state: AppState) {
        self.state = state
        self._profileStore = ObservedObject(wrappedValue: state.profiles)
        self._coreAudio = ObservedObject(wrappedValue: state.coreAudio)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Profiles & Activation").font(.title2.bold())
            Text("Choose the profile that starts when each physical output is selected in macOS. Only one profile can be the hardware default; other profiles can still use their profile-named audio devices.")
                .foregroundStyle(.secondary)

            Divider()

            if knownPhysicalOutputs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "speaker.slash").font(.largeTitle)
                    Text("No Physical Outputs").font(.title2.bold())
                    Text("Add an output profile in the main CamiTune window first.")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(knownPhysicalOutputs) { device in
                            GroupBox {
                                ViewThatFits(in: .horizontal) {
                                    HStack(alignment: .center, spacing: 18) {
                                        deviceLabel(device)
                                        Spacer()
                                        defaultProfilePicker(for: device)
                                            .frame(width: 280)
                                    }

                                    VStack(alignment: .leading, spacing: 10) {
                                        deviceLabel(device)
                                        defaultProfilePicker(for: device)
                                            .frame(maxWidth: 360)
                                    }
                                }
                                .padding(6)
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func deviceLabel(_ device: PhysicalOutputIdentity) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(device.name).font(.headline)
            Text(device.uid)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func defaultProfilePicker(for device: PhysicalOutputIdentity) -> some View {
        Picker("Starts profile", selection: automaticProfileBinding(for: device)) {
            Text("None").tag(UUID?.none)
            ForEach(profiles(for: device.uid)) { profile in
                Text(profile.isEnabled ? profile.name : "\(profile.name) (Disabled)")
                    .tag(Optional(profile.id))
            }
        }
    }

    private var knownPhysicalOutputs: [PhysicalOutputIdentity] {
        var devicesByUID: [String: PhysicalOutputIdentity] = [:]
        for selection in profileStore.physicalDeviceDefaults {
            devicesByUID[selection.physicalDevice.uid] = selection.physicalDevice
        }
        for profile in profileStore.profiles where devicesByUID[profile.outputDeviceUID] == nil {
            devicesByUID[profile.outputDeviceUID] = profile.outputDevice
        }
        for device in coreAudio.physicalOutputDevices {
            devicesByUID[device.id] = PhysicalOutputIdentity(uid: device.id, name: device.name)
        }
        return devicesByUID.values.sorted {
            if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame {
                return $0.uid < $1.uid
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func profiles(for physicalDeviceUID: String) -> [DeviceProfile] {
        profileStore.profiles
            .filter { $0.outputDeviceUID == physicalDeviceUID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func automaticProfileBinding(for device: PhysicalOutputIdentity) -> Binding<UUID?> {
        Binding(
            get: {
                let profileID = profileStore.automaticProfileID(forPhysicalDeviceUID: device.uid)
                return profiles(for: device.uid).contains(where: { $0.id == profileID }) ? profileID : nil
            },
            set: { profileID in
                Task {
                    await state.setAutomaticProfile(for: device, profileID: profileID)
                }
            }
        )
    }
}

@MainActor
struct SettingsView: View {
    let state: AppState
    @ObservedObject private var store: ProfileStore
    @ObservedObject private var loginItem: LoginItemManager
    @State private var category = "General"
    @State private var type: ProfileEndpointKind = .speakers
    @State private var showingApply = false
    @State private var selectedProfiles: Set<UUID> = []
    private let categories = ["General", "Profiles & Activation", "Section Layout", "Drivers & Components", "Confirmations"]

    init(state: AppState) {
        self.state = state
        _store = ObservedObject(wrappedValue: state.profiles)
        _loginItem = ObservedObject(wrappedValue: state.loginItem)
    }
    var body: some View {
        HStack(spacing: 0) {
            List(categories, id: \.self, selection: $category) { Text($0).tag($0) }
                .listStyle(.sidebar).frame(width: 185)
            Divider()
            if category == "Profiles & Activation" {
                ProfilesActivationSettingsView(state: state)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text(category).font(.title.bold())
                    switch category {
                    case "General":
                        Toggle("Start CamiTune at login", isOn: Binding(
                            get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                            .disabled(loginItem.isUpdating)
                        Text(loginItem.statusMessage).font(.callout).foregroundStyle(.secondary)
                    case "Section Layout":
                        Picker("Device Type", selection: $type) {
                            ForEach(ProfileEndpointKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        Text("New profiles and profiles using global defaults will use this layout.")
                            .foregroundStyle(.secondary)
                        SectionLayoutEditor(type: type, layout: Binding(
                            get: { store.defaultLayout(for: type) },
                            set: { store.setDefaultLayout($0, for: type) }))
                        Button("Apply to Existing Profiles…") {
                            selectedProfiles = []
                            showingApply = true
                        }
                    case "Drivers & Components":
                        Text("Install or repair CamiTune’s audio components.")
                        Button("Open Setup…") { state.setupPresentation.isPresented = true }
                    case "Confirmations":
                        Toggle("Show profile enabled explanation", isOn: $store.showProfileEnabledExplanation)
                        Text("Show an explanation when you manually enable a profile.").foregroundStyle(.secondary)
                    default: EmptyView()
                    }
                    Spacer(minLength: 0)
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .sheet(isPresented: $showingApply) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Apply Layout to Existing Profiles").font(.title2.bold())
                Text("Selected profiles will use the global \(type.displayName) layout. Their local layout overrides will be replaced.")
                List(store.profiles.filter { $0.endpointKind == type }) { profile in
                    Toggle(profile.name, isOn: Binding(
                        get: { selectedProfiles.contains(profile.id) },
                        set: { if $0 { selectedProfiles.insert(profile.id) } else { selectedProfiles.remove(profile.id) } }))
                }
                HStack {
                    Spacer()
                    Button("Cancel") { showingApply = false }.keyboardShortcut(.cancelAction)
                    Button("Apply") {
                        store.applyDefaultLayout(for: type, to: selectedProfiles)
                        showingApply = false
                    }.keyboardShortcut(.defaultAction).disabled(selectedProfiles.isEmpty)
                }
            }.padding(24).frame(width: 480, height: 390)
        }
    }
}

@MainActor
struct SectionLayoutEditor: View {
    let type: ProfileEndpointKind
    @Binding var layout: ProfileSectionLayout

    private var movable: [ProfileSection] {
        layout.normalizedOrder.filter { $0 != .deviceSetup && $0.applies(to: type) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drag sections to reorder them. Hidden sections keep their processing settings.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                HStack {
                    Text(ProfileSection.deviceSetup.title)
                    Spacer()
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Always visible and first")
                }
                ForEach(movable) { section in
                    Toggle(section.title, isOn: Binding(
                        get: { !layout.hidden.contains(section) },
                        set: { if $0 { layout.hidden.remove(section) } else { layout.hidden.insert(section) } }))
                }
                .onMove { source, destination in
                    var reordered = movable
                    reordered.move(fromOffsets: source, toOffset: destination)
                    var iterator = reordered.makeIterator()
                    // Leave temporarily inapplicable sections in their remembered slots.
                    layout.order = layout.normalizedOrder.map { section in
                        movable.contains(section) ? (iterator.next() ?? section) : section
                    }
                }
            }
            .frame(minHeight: 245)
            Picker("Equalizer", selection: $layout.equalizer) {
                ForEach(EqualizerPresentation.allCases) { Text($0.title).tag($0) }
            }
        }
    }
}

@MainActor
struct ProfileSettingsView: View {
    let state: AppState
    @ObservedObject private var store: ProfileStore
    @ObservedObject private var audio: CoreAudioManager
    @State private var draft: ProfileSettingsDraft
    @State private var category = "General"
    @State private var saving = false
    @State private var failure: String?
    @State private var recovery: AppErrorRecovery?
    @State private var showingRepair = false
    @Environment(\.dismiss) private var dismiss

    init(state: AppState, profile: DeviceProfile) {
        self.state = state
        _store = ObservedObject(wrappedValue: state.profiles)
        _audio = ObservedObject(wrappedValue: state.coreAudio)
        _draft = State(initialValue: ProfileSettingsDraft(profile: profile, activation: state.profiles.activationMode(for: profile)))
    }
    private var categories: [String] {
        ["General", "Device", "Processing", "Activation", "Section Layout"]
            + ((draft.selectedType == .speakers || (draft.selectedType == .audioInterface && draft.original.audioInterface?.connectedEndpoint == .speakers)) ? ["Speaker & Listening Position"] : [])
    }
    private var hasChanges: Bool {
        (try? draft.candidate()) != draft.original || draft.activation != draft.originalActivation
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(categories, id: \.self, selection: $category) { Text($0).tag($0) }
                    .listStyle(.sidebar).frame(width: 200)
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Profile Settings").font(.title.bold())
                    Text(category).font(.headline)
                    switch category {
                    case "General":
                        TextField("Profile name", text: $draft.name)
                    case "Device":
                        Picker("Device Type", selection: $draft.selectedType) {
                            ForEach(ProfileEndpointKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        Picker("Output Device", selection: Binding(
                            get: { draft.outputDevice.uid },
                            set: { uid in
                                if let device = audio.physicalOutputDevices.first(where: { $0.id == uid }) {
                                    draft.outputDevice = PhysicalOutputIdentity(uid: uid, name: device.name)
                                }
                            })) {
                            if !audio.physicalOutputDevices.contains(where: { $0.id == draft.outputDevice.uid }) {
                                Text("\(draft.outputDevice.name) (Disconnected)").tag(draft.outputDevice.uid)
                            }
                            ForEach(audio.physicalOutputDevices) { Text($0.name).tag($0.id) }
                        }
                        Text("Changing device type keeps your EQ and saved device configuration. A new device type starts in Direct unless it has a remembered supported mode.")
                            .font(.callout).foregroundStyle(.secondary)
                        if draft.selectedType == .audioInterface {
                            Text("Direct is available. Other modes require a configured output assignment.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    case "Processing":
                        Picker("Processing Sample Rate", selection: $draft.sampleRate) {
                            ForEach(Array(Set([44100, 48000, 88200, 96000, 176400, 192000, draft.sampleRate])).sorted(), id: \.self) {
                                Text("\(Double($0) / 1000, specifier: "%g") kHz").tag($0)
                            }
                        }
                        Text("48 kHz is the recommended default. Higher rates increase CPU and bandwidth use but do not improve lower rate source audio.")
                            .foregroundStyle(.secondary)
                    case "Activation":
                        Picker("Activation Mode", selection: $draft.activation) {
                            Text("When I select \(draft.outputDevice.name)").tag(ProfileActivationMode.physicalOutput)
                            Text("When I select \(draft.name)").tag(ProfileActivationMode.profileAudioDevice)
                            Text("Only when I select it in CamiTune").tag(ProfileActivationMode.manual)
                        }.pickerStyle(.radioGroup)
                        Text("To activate CamiTune, choose the audio device from macOS Sound Settings.")
                            .foregroundStyle(.secondary)
                    case "Section Layout":
                        Toggle("Use global defaults", isOn: Binding(
                            get: { draft.sectionLayout == nil },
                            set: { draft.sectionLayout = $0 ? nil : store.defaultLayout(for: draft.selectedType) }))
                        SectionLayoutEditor(type: draft.selectedType, layout: Binding(
                            get: { draft.sectionLayout ?? store.defaultLayout(for: draft.selectedType) },
                            set: { draft.sectionLayout = $0 }))
                        Button("Reset to Global Defaults") { draft.sectionLayout = nil }
                            .disabled(draft.sectionLayout == nil)
                    case "Speaker & Listening Position":
                        ScrollView {
                            SpeakerSystemView(state: state, profile: Binding(
                                get: { (try? draft.candidate()) ?? draft.original },
                                set: { value in
                                    draft.speakerTopology = value.speakerTopology
                                    draft.spatialSettings = value.spatialSettings
                                }), draftOnly: true, embedded: true)
                        }
                    default: EmptyView()
                    }
                    Spacer(minLength: 0)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                if recovery == .openSetup {
                    Button("Open Setup…") { showingRepair = true }
                }
                HStack {
                    if saving { ProgressView().controlSize(.small); Text("Saving…") }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        saving = true
                        failure = nil
                        recovery = nil
                        Task {
                            do { try await state.saveProfileSettings(draft); dismiss() }
                            catch {
                                failure = error.localizedDescription
                                recovery = (error as? AppState.AppError)?.recovery
                            }
                            saving = false
                        }
                    }.keyboardShortcut(.defaultAction).disabled(!hasChanges)
                }
            }.padding(16)
        }
        .frame(width: category == "Speaker & Listening Position" ? 960 : 780, height: category == "Speaker & Listening Position" ? 760 : 620)
        .disabled(saving)
        .interactiveDismissDisabled(hasChanges || saving)
        .sheet(isPresented: $showingRepair) { SetupPanel(state: state) }
        .onChange(of: draft.selectedType) { _ in
            if !categories.contains(category) { category = "Device" }
        }
        .task { await audio.refreshWithoutBlockingUI() }
    }
}
