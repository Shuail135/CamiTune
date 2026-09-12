import Foundation
import SwiftUI

@MainActor
struct ProfileRoutingAndDeviceView: View {
    @ObservedObject var state: AppState
    @ObservedObject var coreAudio: CoreAudioManager
    @Binding var profile: DeviceProfile
    let graphModel: ProfileEditorGraphModel

    private typealias AutomaticActivationChoice = ProfileActivationMode

    private var profileIsActive: Bool {
        state.isActive && state.activeProfileID == profile.id
    }

    private var profileRoutingName: String {
        ProfileRoutingDescriptor.descriptors(for: state.profiles.profiles)[profile.id]?.name
            ?? profile.name
    }

    var body: some View {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Routing & device behavior").font(.title3.bold())
                    endpointKindPicker
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            systemRouteSummary
                            Image(systemName: "arrow.right")
                            physicalOutputSelection
                            Spacer()
                            activationStatus
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            systemRouteSummary
                            Image(systemName: "arrow.down")
                                .foregroundStyle(.secondary)
                            physicalOutputSelection
                            activationStatus
                        }
                    }
                    Divider()
                    if profileIsActive, state.activeVolumeMode == .softwareOnly {
                        Label(
                            "This output uses software volume. Apps playing directly to it bypass CamiTune’s volume control.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Text("Automatic activation").font(.headline)
                    Picker("How this profile starts", selection: automaticActivationBinding) {
                        Text("Physical output — when \(profile.outputDeviceName) is selected")
                            .tag(AutomaticActivationChoice.physicalOutput)
                        Text("Profile audio device — when \(profileRoutingName) is selected")
                            .tag(AutomaticActivationChoice.profileAudioDevice)
                        Text("Manual only — activate from CamiTune")
                            .tag(AutomaticActivationChoice.manual)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
        
                    Text(automaticActivationExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
        
                    if automaticActivationChoice == .manual {
                        Button(profileIsActive ? "Deactivate EQ" : "Activate EQ Now") {
                            Task {
                                if profileIsActive {
                                    await state.deactivate(manual: true)
                                } else {
                                    await state.activate(profile: profile)
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            !profileIsActive &&
                                (!profile.isEnabled || coreAudio.cachedDevice(uid: profile.outputDeviceUID) == nil)
                        )
                    }
        
                    if let otherProfile = physicalActivationOwner, otherProfile.id != profile.id {
                        Label(
                            "\(profile.outputDeviceName) currently starts \(otherProfile.name). Choose Physical output above only if you want this profile to become the new default.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.blue)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text("Processing sample rate")
                            Spacer()
                            sampleRatePicker
                                .frame(width: 190)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Processing sample rate")
                            sampleRatePicker
                                .frame(maxWidth: 240)
                        }
                    }
                    Text("Higher rates increase CPU and bandwidth use but do not improve lower-rate source audio; 48 kHz is the recommended default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }.padding(6)
            }
    }

    private var endpointKindPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Device / use type", selection: $profile.endpointKind) {
                ForEach(ProfileEndpointKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            Text("Describe what you use with this output. This label does not change playback processing or assign interface channels.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var systemRouteSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("System audio route")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(profileRoutingName)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var physicalOutputSelection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Physical audio output")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: outputDeviceBinding) {
                if coreAudio.cachedDevice(uid: profile.outputDeviceUID) == nil {
                    Text("\(profile.outputDeviceName) (Disconnected)")
                        .tag(profile.outputDeviceUID)
                }
                ForEach(coreAudio.physicalOutputDevices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
        }
    }

    private var activationStatus: some View {
        Text(profileIsActive ? "Activated" : "Not Activated")
            .font(.caption.bold())
            .foregroundStyle(profileIsActive ? Color.green : Color.secondary)
    }

    private var outputDeviceBinding: Binding<String> {
        Binding(
            get: { profile.outputDeviceUID },
            set: { newUID in
                guard let device = state.coreAudio.cachedDevice(uid: newUID) else { return }
                Task {
                    await state.setOutputDevice(profileID: profile.id, device: device)
                }
            }
        )
    }

    private var sampleRatePicker: some View {
        Picker("Sample rate", selection: Binding(
            get: { profile.sampleRate },
            set: { newRate in
                guard newRate != profile.sampleRate else { return }
                let profileID = profile.id
                let outputUID = profile.outputDeviceUID
                Task {
                    if let problem = await state
                        .processingSampleRateProblemWithoutBlockingUI(
                            rate: newRate,
                            outputUID: outputUID
                        ) {
                        state.reportProcessingSampleRateProblem(problem)
                        return
                    }
                    guard profile.id == profileID else { return }
                    profile.sampleRate = newRate
                    graphModel.seed(profile: profile, state: state)
                    if profileIsActive {
                        let updatedProfile = (try? state
                            .applyingSessionEQDrafts(to: profile)) ?? profile
                        await state.apply(profile: updatedProfile)
                    }
                }
            }
        )) {
            ForEach([44_100, 48_000, 88_200, 96_000, 176_400, 192_000], id: \.self) { rate in
                Text(rateLabel(rate))
                    .tag(rate)
            }
        }
        .labelsHidden()
    }

    private var physicalActivationOwner: DeviceProfile? {
        guard let profileID = state.profiles.automaticProfileID(
            forPhysicalDeviceUID: profile.outputDeviceUID
        ) else { return nil }
        return state.profiles.profiles.first(where: { $0.id == profileID })
    }

    private var automaticActivationChoice: AutomaticActivationChoice {
        state.profiles.activationMode(for: profile)
    }

    private var automaticActivationBinding: Binding<AutomaticActivationChoice> {
        Binding(
            get: { automaticActivationChoice },
            set: { choice in
                Task { await setAutomaticActivation(choice) }
            }
        )
    }

    private var automaticActivationExplanation: String {
        switch automaticActivationChoice {
        case .physicalOutput:
            return "This is the default profile for this hardware. Selecting the physical output in macOS routes audio through this EQ."
        case .profileAudioDevice:
            return "The physical output remains available for direct playback. Select the profile-named audio device in macOS when you want this EQ."
        case .manual:
            return "Changing the macOS audio output will not start this profile automatically."
        }
    }

    private func setAutomaticActivation(_ choice: AutomaticActivationChoice) async {
        await state.setActivationMode(profileID: profile.id, mode: choice)
    }

    private func rateLabel(_ rate: Int) -> String {
        rate % 1000 == 0 ? "\(rate / 1000) kHz" : String(format: "%.1f kHz", Double(rate) / 1000)
    }
}
