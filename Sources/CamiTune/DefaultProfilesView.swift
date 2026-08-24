import SwiftUI
import Foundation

@MainActor
struct DefaultProfilesView: View {
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
            Text("Default Profiles").font(.largeTitle.bold())
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
