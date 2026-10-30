import CamiTuneDomain
import SwiftUI

/// Draft the whole setup locally; Finish commits through the profile transaction.
@MainActor
struct PersonalSpatialSetupSheet: View {
    let state: AppState
    let profile: DeviceProfile
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settings: PersonalSpatialSettings
    @StateObject private var device: SpatialDeviceSelection
    @State private var step = 0
    @State private var movingForward = true
    @State private var busy = false
    @State private var error: String?
    @State private var choosingSpeaker = false
    @State private var saveTask: Task<Void, Never>?

    init(state: AppState, profile: DeviceProfile) {
        self.state = state
        self.profile = profile
        _settings = State(initialValue: profile.personalSpatial)
        _device = StateObject(wrappedValue: SpatialDeviceSelection(endpoint: profile.effectiveEndpointKind,
            genericName: profile.effectiveEndpointKind == .iem ? "Generic IEM" : "Generic Headphones",
            current: profile.personalSpatial.playbackDevice))
    }

    private var lastStep: Int { settings.experience == .speakerMimic ? 2 : 1 }
    private var subtitle: String {
        switch step {
        case 0: return "How would you like to listen?"
        case 1: return "Choose your headphones and sound signature."
        default: return "Choose the speakers you want to hear."
        }
    }

    var body: some View {
        SetupSheet(title: "Set Up Spatial Sound", subtitle: subtitle, symbol: "headphones.circle.fill") {
            ZStack(alignment: .topLeading) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        page
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
                .scrollBounceWhenNeeded()
                .id(step)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: step)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 12)
            }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                .uiInteractionAnchor("spatial-setup-cancel")
            Spacer()
            if busy { ProgressView("Preparing…").controlSize(.small) }
            if step > 0 {
                Button("Back") { move(to: step - 1) }.frame(minWidth: 70)
                    .uiInteractionAnchor("spatial-setup-back")
            }
            Button(step == lastStep ? "Finish Setup" : "Next") {
                if step == lastStep { finish() } else { move(to: step + 1) }
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            .disabled(step >= 1 && !device.supports(device.signature))
            .uiInteractionAnchor("spatial-setup-next")
        }
        .disabled(busy).interactiveDismissDisabled(busy)
        .task { await device.load() }
        .onDisappear { device.cancel(); saveTask?.cancel() }
        .sheet(isPresented: $choosingSpeaker) {
            SpatialSpeakerPicker(group: .front) { sound in
                settings.scene.assign(sound, to: .front)
                choosingSpeaker = false
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 0: experiencePage
        case 1:
            SpatialDeviceSelectionContent(selection: device)
            SpatialSoundSignatureContent(selection: device)
        default: speakerPage
        }
    }

    private var experiencePage: some View {
        HStack(spacing: 16) {
            experienceChoice(.spatialListening, title: "Spatial sound", symbol: "waveform.circle")
            experienceChoice(.speakerMimic, title: "Mimic speakers", symbol: "hifispeaker.2")
        }
    }

    private func experienceChoice(_ experience: PersonalSpatialExperience, title: String, symbol: String) -> some View {
        let selected = settings.experience == experience
        return Button { settings.experience = experience } label: {
            VStack(spacing: 18) {
                Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(Color.accentColor)
                Text(title).font(.headline)
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .frame(maxWidth: .infinity).frame(height: 200)
            .background(selected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .uiInteractionAnchor("spatial-setup-\(experience.rawValue)")
    }

    private var speakerPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Room", selection: $settings.scene.roomModel) {
                        ForEach(VirtualSpeakerRoom.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if settings.scene.roomModel == .generic {
                        HStack {
                            Text("Speaker model")
                            Spacer()
                            Text(settings.scene.speaker(for: .left)?.name ?? "Neutral Monitor").foregroundStyle(.secondary)
                            Button("Choose…") { choosingSpeaker = true }
                                .uiInteractionAnchor("spatial-setup-speakers")
                        }
                        Text("Choose one model to build a matching set, or keep the neutral speakers.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Hear the measured Genelec speakers in the SADIE II studio. Speaker positions and the room are fixed.")
                            .foregroundStyle(.secondary)
                    }
                    Picker("Speaker setup", selection: Binding(get: { settings.scene.layout }, set: { settings.scene.selectLayout($0) })) {
                        ForEach(VirtualSpeakerLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }.padding(8)
            } label: { Text("Speakers to Mimic") }
            Text("Fine-tune lets you change the placement, add a subwoofer, or customize individual speakers later.")
                .foregroundStyle(.secondary)
        }.font(.callout)
    }

    private func move(to next: Int) {
        movingForward = next > step
        step = next
        error = nil
    }

    private func finish() {
        busy = true; error = nil
        saveTask = Task {
            defer { busy = false }
            do {
                var value = settings
                value.playbackDevice = try await device.prepare()
                try Task.checkCancellation()
                var draft = ProfileSettingsDraft(profile: profile, activation: state.profiles.activationMode(for: profile))
                draft.personalSpatial = value
                try await state.saveProfileSettings(draft, historyAction: "Set Up Spatial Sound")
                dismiss()
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
