import SwiftUI
import AppKit
import Foundation

@MainActor
struct ProfileEditorView: View {
    let state: AppState
    let coreAudio: CoreAudioManager
    @ObservedObject private var store: ProfileStore
    @State private var showingSettings = false
    @State private var showingSpeakers = false
    @State private var openSpeakersAfterSettings = false
    @Binding var profile: DeviceProfile
    @StateObject private var graphModel = ProfileEditorGraphModel()
    @State private var isRenamingProfile = false
    @State private var titleHovered = false
    @FocusState private var titleFocused: Bool
    @State private var renamingProfileID: UUID?
    @State private var profileNameDraft = ""
    @State private var focusClearingMonitor: Any?
    @FocusState private var profileNameFocused: Bool


    init(state: AppState, coreAudio: CoreAudioManager, profile: Binding<DeviceProfile>) {
        self.state = state
        self.coreAudio = coreAudio
        _profile = profile
        _store = ObservedObject(wrappedValue: state.profiles)
    }

    private var layout: ProfileSectionLayout { store.effectiveLayout(for: profile) }
    private var sections: [ProfileSection] { layout.visibleSections(for: profile.endpointKind) }
    private func updateVisuals() {
        // EQ bands and per-channel controls also display spectrum/level data.
        let demand = layout.visualDemand(for: profile.endpointKind)
        state.setRuntimeVisuals(profileID: profile.id, active: true,
            meters: demand.meters, spectrum: demand.spectrum)
        if !demand.spectrum { graphModel.cancel() }
    }

    private func seedGraphIfNeeded() {
        if layout.visualDemand(for: profile.endpointKind).spectrum {
            graphModel.seed(profile: profile, state: state)
        } else { graphModel.cancel() }
    }

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
                        Button { beginProfileRename() } label: {
                            HStack(spacing: 8) {
                                Text(profile.name).font(.largeTitle.bold())
                                Image(systemName: "pencil")
                                    .font(.body).foregroundStyle(.secondary)
                                    .opacity(titleHovered || titleFocused ? 1 : 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focused($titleFocused)
                        .onHover { titleHovered = $0 }
                        .accessibilityLabel("Rename \(profile.name)")
                        .help("Click to rename this profile")
                    }
                    ProfileConnectionStatusView(
                        coreAudio: coreAudio,
                        outputDeviceUID: profile.outputDeviceUID
                    )
                    Spacer()
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Profile Settings")
                    .accessibilityLabel("Profile Settings")
                    Toggle("Enabled", isOn: Binding(
                        get: { profile.isEnabled },
                        set: { newValue in
                            Task { await state.setProfileEnabled(id: profile.id, enabled: newValue) }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Enable Profile")
                    .help("Make this profile available for activation")
                }

                ForEach(sections) { section in
                    profileSection(section)
                }
            }
            .padding(28)
        }
        .onAppear {
            updateVisuals()
            seedGraphIfNeeded()
            installFocusClearingMonitor()
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            if openSpeakersAfterSettings {
                openSpeakersAfterSettings = false
                DispatchQueue.main.async { showingSpeakers = true }
            }
        }) {
            ProfileSettingsView(state: state, profile: profile) { openSpeakersAfterSettings = true }
        }
        .sheet(isPresented: $showingSpeakers) { SpeakerSystemView(state: state, profile: $profile) }
        .onChange(of: layout) { _ in
            updateVisuals()
            if sections.contains(.equalizer) || sections.contains(.spectrum) {
                seedGraphIfNeeded()
            }
        }
        .onChange(of: profile.endpointKind) { _ in updateVisuals() }
        .onChange(of: profile.id) { _ in
            commitProfileRename()
            seedGraphIfNeeded()
        }
        .onChange(of: profile.sampleRate) { _ in
            seedGraphIfNeeded()
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

    @ViewBuilder
    private func profileSection(_ section: ProfileSection) -> some View {
        switch section {
        case .deviceSetup:
            ProfileRoutingAndDeviceView(state: state, coreAudio: coreAudio, profile: $profile, graphModel: graphModel)
        case .meters:
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Meters & Status").font(.title3.bold())
                    SignalMetersView(meters: state.meters, profileID: profile.id)
                    Divider()
                    AudioRuntimeStatusView(monitor: state.meters, profileID: profile.id)
                }.padding(6)
            }
        case .spectrum:
            LiveSpectrumPanels(spectrum: state.spectrum, profileID: profile.id, graphModel: graphModel)
        case .mode:
            SpatialAudioEditorView(state: state, profile: $profile)
        case .equalizer:
            GlobalEqualizerEditorView(state: state, profile: $profile, graphModel: graphModel,
                presentation: layout.equalizer, needsResponseGraph: sections.contains(.spectrum) || layout.equalizer != .simpleTone)
        case .convolution:
            ConvolutionEditorView(state: state, profile: $profile)
        case .crossfeed:
            CrossfeedEditorView(state: state, profile: $profile)
        case .perChannel:
            PerChannelProcessingView(state: state, profile: $profile)
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
