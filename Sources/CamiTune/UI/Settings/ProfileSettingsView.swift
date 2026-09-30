import CamiTuneDomain
import SwiftUI
import AppKit

@MainActor
struct ProfileSettingsView: View {
    let state: AppState
    @ObservedObject private var store: ProfileStore
    @ObservedObject private var audio: CoreAudioSnapshotStore
    @State private var draft: ProfileSettingsDraft
    @State private var category = "General"
    @State private var saving = false
    @State private var failure: String?
    @State private var recovery: AppErrorRecovery?
    @State private var showingRepair = false
    @State private var confirmClose = false
    @Environment(\.dismiss) private var dismiss

    init(state: AppState, profile: DeviceProfile) {
        self.state = state
        _store = ObservedObject(wrappedValue: state.profiles)
        _audio = ObservedObject(wrappedValue: state.coreAudio)
        _draft = State(initialValue: ProfileSettingsDraft(profile: profile, activation: state.profiles.activationMode(for: profile)))
    }
    private func save() {
        saving = true; failure = nil; recovery = nil
        Task {
            do { try await state.saveProfileSettings(draft); dismiss() }
            catch { failure = error.localizedDescription; recovery = (error as? AppState.AppError)?.recovery }
            saving = false
        }
    }
    private var categories: [String] {
        ["General", "Section Layout"]
            + ((draft.selectedType == .speakers || (draft.selectedType == .audioInterface && draft.audioInterface?.connectedEndpoint == .speakers)) ? ["Speaker & Listening Position"] : [])
    }
    private var hasChanges: Bool {
        (try? draft.candidate()) != draft.original || draft.activation != draft.originalActivation
    }
    private var generalSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Profile name", text: $draft.name)
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
                    InterfaceAssignmentEditor(state: state, output: draft.outputDevice,
                        sampleRate: draft.sampleRate, assignment: $draft.audioInterface,
                        topology: $draft.speakerTopology)

                }
                Picker("Processing Sample Rate", selection: $draft.sampleRate) {
                    ForEach(Array(Set([44100, 48000, 88200, 96000, 176400, 192000, draft.sampleRate])).sorted(), id: \.self) {
                        Text("\(Double($0) / 1000, specifier: "%g") kHz").tag($0)
                    }
                }
                Text("48 kHz is the recommended default. Higher rates increase CPU and bandwidth use but do not improve lower rate source audio.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                        generalSettings
                    case "Section Layout":
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
                                }), draftOnly: true, embedded: true, compact: true)
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
                    Button("Cancel") { if hasChanges { confirmClose = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                    Button("Save") { save()                    }.keyboardShortcut(.defaultAction).disabled(!hasChanges || (try? draft.candidate()) == nil)
                }
            }.padding(16)
        }
        .frame(width: 780, height: 620)
        .disabled(saving)
        .interactiveDismissDisabled(hasChanges || saving)
        .alert("Save changes to this profile?", isPresented: $confirmClose) {
            Button("Save Changes") { save() }
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Your changes have not been saved.") }
        .sheet(isPresented: $showingRepair) { SetupPanel(state: state) }
        .onChange(of: draft.selectedType) { _ in
            if !categories.contains(category) { category = "General" }
        }
        .task { await state.coreAudioService.refreshWithoutBlockingUI() }
    }
}
