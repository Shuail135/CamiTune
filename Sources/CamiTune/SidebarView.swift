import SwiftUI
import Foundation

@MainActor
struct SidebarView: View {
    let state: AppState
    @ObservedObject var profileStore: ProfileStore
    @Binding var selection: String
    let onAddOutput: @MainActor () async -> Void

    @State private var renameProfileID: UUID?
    @State private var renameDraft = ""
    @FocusState private var focusedRenameID: UUID?

    var body: some View {
        List(selection: $selection) {
            Label("Setup", systemImage: "wrench.and.screwdriver").tag("setup")

            Button {
                Task { @MainActor in
                    await onAddOutput()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus.circle.fill").frame(width: 18)
                    Text("Add Output")
                }
                .fontWeight(.semibold)
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)

            Label("Default Profiles", systemImage: "speaker.wave.2.fill")
                .tag("default-profiles")

            Label("Applications", systemImage: "square.stack.3d.up.fill")
                .tag("applications")

            Section("Output profiles") {
                ForEach(profileStore.profiles) { profile in
                    profileRow(profile)
                }
            }
        }
        .navigationTitle("CamiTune")
        .onChange(of: focusedRenameID) { newFocus in
            if renameProfileID != nil, newFocus != renameProfileID {
                commitRename()
            }
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: DeviceProfile) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "speaker.wave.2")
                .foregroundStyle(profile.isEnabled ? Color.blue : Color.primary)

            if renameProfileID == profile.id {
                TextField("Profile name", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedRenameID, equals: profile.id)
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
            } else {
                Text(profile.name)
            }
        }
        .tag(profile.id.uuidString)
        .contextMenu {
            Button {
                Task {
                    await state.setProfileEnabled(
                        id: profile.id,
                        enabled: !profile.isEnabled
                    )
                }
            } label: {
                Label(
                    profile.isEnabled ? "Deactivate Profile" : "Activate Profile",
                    systemImage: profile.isEnabled ? "stop.circle" : "play.circle"
                )
            }

            Divider()

            Button("Rename") {
                beginRename(profile)
            }

            Divider()

            Button("Delete", role: .destructive) {
                deleteProfile(profile)
            }
        }
    }

    private func beginRename(_ profile: DeviceProfile) {
        renameProfileID = profile.id
        renameDraft = profile.name
        DispatchQueue.main.async {
            focusedRenameID = profile.id
        }
    }

    private func commitRename() {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = renameProfileID,
           !name.isEmpty,
           profileStore.profiles.contains(where: { $0.id == id }) {
            Task { await state.renameProfile(id: id, to: name) }
        }
        renameProfileID = nil
        focusedRenameID = nil
    }

    private func cancelRename() {
        renameProfileID = nil
        focusedRenameID = nil
        renameDraft = ""
    }

    private func deleteProfile(_ profile: DeviceProfile) {
        let id = profile.id
        cancelRename()
        selection = "setup"
        Task {
            if state.activeProfileID == id {
                await state.deactivate(manual: true)
            }
            profileStore.deleteProfile(id: id)
        }
    }
}
