import AppKit
import SwiftUI

@MainActor
struct ProfileRoutingAndDeviceView: View {
    @ObservedObject var state: AppState
    @ObservedObject var coreAudio: CoreAudioManager
    @Binding var profile: DeviceProfile
    let graphModel: ProfileEditorGraphModel

    private var profileIsActive: Bool { state.isActive && state.activeProfileID == profile.id }
    private var profileRoutingName: String {
        ProfileRoutingDescriptor.descriptors(for: state.profiles.profiles)[profile.id]?.name ?? profile.name
    }
    private var activation: ProfileActivationMode { state.profiles.activationMode(for: profile) }
    private var activationBinding: Binding<ProfileActivationMode> {
        Binding(get: { activation }, set: { mode in
            Task { await state.setActivationMode(profileID: profile.id, mode: mode) }
        })
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Device Setup").font(.title3.bold())
                    Spacer()
                    Label(profileIsActive ? "Active" : "Inactive", systemImage: profileIsActive ? "circle.fill" : "circle")
                        .font(.callout).foregroundStyle(profileIsActive ? Color.green : Color.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                    GridRow {
                        Text("CamiTune Output").foregroundStyle(.secondary)
                        Text(profileRoutingName).textSelection(.enabled)
                    }
                    GridRow {
                        Text("Output Device").foregroundStyle(.secondary)
                        Picker("Output Device", selection: Binding(
                            get: { profile.outputDeviceUID },
                            set: { uid in
                                guard let device = coreAudio.cachedDevice(uid: uid) else { return }
                                Task {
                                    var draft = ProfileSettingsDraft(profile: profile, activation: activation)
                                    draft.outputDevice = PhysicalOutputIdentity(uid: device.id, name: device.name)
                                    do { try await state.saveProfileSettings(draft) }
                                    catch { state.presentError(error) }
                                }
                            })) {
                                if coreAudio.cachedDevice(uid: profile.outputDeviceUID) == nil {
                                    Text("\(profile.outputDeviceName) (Disconnected)").tag(profile.outputDeviceUID)
                                }
                                ForEach(coreAudio.physicalOutputDevices) { Text($0.name).tag($0.id) }
                            }.labelsHidden().frame(maxWidth: 350)
                    }
                }
                if profileIsActive && state.activeVolumeMode == .softwareOnly {
                    Label("This output uses software volume. Apps playing directly to it bypass CamiTune’s volume control.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("Activation Mode").font(.headline)
                Text("To activate CamiTune, choose the audio device from macOS Sound Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                activationRow(.physicalOutput, title: "When I select \(profile.outputDeviceName)",
                    hint: "CamiTune will automatically use this profile and route the audio through CamiTune.")
                activationRow(.profileAudioDevice, title: "When I select \(profileRoutingName)",
                    hint: "Use this profile when its CamiTune audio device is selected directly in macOS Sound Settings.")
                activationRow(.manual, title: "Only when I select it in CamiTune", hint: "Activate and deactivate in CamiTune.")
                if let owner = state.profiles.automaticProfileID(forPhysicalDeviceUID: profile.outputDeviceUID),
                   owner != profile.id, let other = state.profiles.profiles.first(where: { $0.id == owner }) {
                    Text("\(profile.outputDeviceName) currently starts \(other.name). Selecting the first option makes this profile the default for that output.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6)
        }
        .disabled(state.transitionInProgress || state.isSavingProfileSettings)
    }

    private func activationRow(_ mode: ProfileActivationMode, title: String, hint: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ActivationRadioButton(selection: activationBinding, value: mode, title: title, hint: hint)
                .frame(width: 18, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { activationBinding.wrappedValue = mode }
            Spacer(minLength: 8)
            if mode == .manual {
                Button(profileIsActive ? "Deactivate" : "Activate") {
                    Task {
                        if profileIsActive { await state.deactivate(manual: true) }
                        else { await state.activate(profile: profile) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(!profileIsActive && (activation != .manual || !profile.isEnabled || coreAudio.cachedDevice(uid: profile.outputDeviceUID) == nil))
            }
        }
    }
}

@MainActor
private struct ActivationRadioButton: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var selection: ProfileActivationMode
    let value: ProfileActivationMode
    let title: String
    let hint: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        NSButton(radioButtonWithTitle: "", target: context.coordinator, action: #selector(Coordinator.select))
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.state = selection == value ? .on : .off
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(hint)
    }
    @MainActor
    final class Coordinator: NSObject {
        var parent: ActivationRadioButton
        init(_ parent: ActivationRadioButton) { self.parent = parent }
        @objc func select() { parent.selection = parent.value }
    }
}
