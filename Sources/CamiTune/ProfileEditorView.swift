import SwiftUI
import AppKit
import Foundation

@MainActor
struct ProfileEditorView: View {
    let state: AppState
    let coreAudio: CoreAudioManager
    @Binding var profile: DeviceProfile
    @StateObject private var graphModel = ProfileEditorGraphModel()
    @State private var isRenamingProfile = false
    @State private var renamingProfileID: UUID?
    @State private var profileNameDraft = ""
    @State private var focusClearingMonitor: Any?
    @FocusState private var profileNameFocused: Bool


    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    if isRenamingProfile {
                        TextField("Profile name", text: $profileNameDraft)
                            .font(.largeTitle.bold())
                            .textFieldStyle(.plain)
                            .frame(minWidth: 180, maxWidth: 480)
                            .focused($profileNameFocused)
                            .onSubmit { commitProfileRename() }
                            .onExitCommand { cancelProfileRename() }
                    } else {
                        Text(profile.name)
                            .font(.largeTitle.bold())
                            .contentShape(Rectangle())
                            .onTapGesture { beginProfileRename() }
                            .help("Click to rename this profile")
                    }
                    ProfileConnectionStatusView(
                        coreAudio: coreAudio,
                        outputDeviceUID: profile.outputDeviceUID
                    )
                    Spacer()
                    Toggle("Enabled", isOn: Binding(
                        get: { profile.isEnabled },
                        set: { newValue in
                            Task { await state.setProfileEnabled(id: profile.id, enabled: newValue) }
                        }
                    ))
                    .toggleStyle(.switch)
                    .accessibilityLabel("Enable Profile")
                    .help("Make this profile available for activation")
                }

                Text("Enabled makes this profile available. Activation conditions decide when processing starts; Active means its audio runtime is running. Disabling stops this profile if it is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ProfileRoutingAndDeviceView(
                    state: state,
                    coreAudio: coreAudio,
                    profile: $profile,
                    graphModel: graphModel
                )

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Meters & status").font(.title3.bold())
                        SignalMetersView(meters: state.meters, profileID: profile.id)
                        Divider()
                        AudioRuntimeStatusView(monitor: state.meters, profileID: profile.id)
                    }.padding(6)
                }

                LiveSpectrumPanels(
                    spectrum: state.spectrum,
                    profileID: profile.id,
                    graphModel: graphModel
                )

                SpatialAudioEditorView(
                    state: state,
                    profile: $profile
                )

                GlobalEqualizerEditorView(
                    state: state,
                    profile: $profile,
                    graphModel: graphModel
                )

                ConvolutionEditorView(
                    state: state,
                    profile: $profile
                )

                CrossfeedEditorView(
                    state: state,
                    profile: $profile
                )

                PerChannelProcessingView(
                    state: state,
                    profile: $profile
                )
            }
            .padding(28)
        }
        .onAppear {
            state.setRuntimeVisuals(profileID: profile.id, active: true)
            graphModel.seed(profile: profile, state: state)
            installFocusClearingMonitor()
        }
        .onChange(of: profile.id) { _ in
            commitProfileRename()
            graphModel.seed(profile: profile, state: state)
        }
        .onChange(of: profile.sampleRate) { _ in
            graphModel.seed(profile: profile, state: state)
        }
        .onChange(of: profileNameFocused) { isFocused in
            if isRenamingProfile && !isFocused { commitProfileRename() }
        }
        .onDisappear {
            state.setRuntimeVisuals(profileID: profile.id, active: false)
            commitProfileRename()
            graphModel.cancel()
            removeFocusClearingMonitor()
        }
    }

    private func beginProfileRename() {
        profileNameDraft = profile.name
        renamingProfileID = profile.id
        isRenamingProfile = true
        DispatchQueue.main.async { profileNameFocused = true }
    }

    private func commitProfileRename() {
        guard isRenamingProfile else { return }
        let trimmedName = profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty,
           let profileID = renamingProfileID,
           state.profiles.profiles.contains(where: { $0.id == profileID }) {
            Task { await state.renameProfile(id: profileID, to: trimmedName) }
        }
        isRenamingProfile = false
        renamingProfileID = nil
        profileNameFocused = false
    }

    private func cancelProfileRename() {
        isRenamingProfile = false
        renamingProfileID = nil
        profileNameFocused = false
        profileNameDraft = ""
    }

    private func installFocusClearingMonitor() {
        guard focusClearingMonitor == nil else { return }
        focusClearingMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let keyWindow = NSApp.keyWindow,
                  event.window === keyWindow,
                  let contentView = keyWindow.contentView else { return event }

            let location = contentView.convert(event.locationInWindow, from: nil)
            let clickedView = contentView.hitTest(location)

            // Do not mutate first-responder/layout state inside the mouse-down
            // monitor itself. Native controls and SwiftUI gestures must receive
            // the click first; otherwise a focused EQ field can commit/reorder
            // the editor during the same event that starts a slider drag.
            guard !Self.isTextInput(clickedView),
                  let currentResponder = keyWindow.firstResponder as? NSView,
                  Self.isTextInput(currentResponder) else { return event }

            DispatchQueue.main.async {
                guard event.window === keyWindow,
                      let responder = keyWindow.firstResponder as? NSView,
                      Self.isTextInput(responder) else { return }
                keyWindow.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func removeFocusClearingMonitor() {
        guard let focusClearingMonitor else { return }
        NSEvent.removeMonitor(focusClearingMonitor)
        self.focusClearingMonitor = nil
    }

    private static func isTextInput(_ view: NSView?) -> Bool {
        var currentView = view
        while let view = currentView {
            if view is NSTextField || view is NSTextView { return true }
            currentView = view.superview
        }
        return false
    }

}
