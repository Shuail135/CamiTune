import CamiTuneDomain
import SwiftUI
import AppKit
import Foundation

@MainActor
struct ProfileEditorView: View {
    @EnvironmentObject private var commands: MainWindowCommandCoordinator
    let state: AppState
    let coreAudio: CoreAudioSnapshotStore
    @ObservedObject private var store: ProfileStore
    @State private var showingSettings = false
    @Binding var profile: DeviceProfile
    // Only graph views observe response publications. This owner retains the
    // model without making a response calculation rebuild the complete page.
    @State private var graphModel = ProfileEditorGraphModel()
    @State private var preparedSectionCount = 1
    @State private var isRenamingProfile = false
    @State private var titleHovered = false
    @FocusState private var titleFocused: Bool
    @State private var renamingProfileID: UUID?
    @State private var profileNameDraft = ""
    @State private var focusClearingMonitor: Any?
    @State private var focusClearingID: UUID?
    @FocusState private var profileNameFocused: Bool


    init(state: AppState, coreAudio: CoreAudioSnapshotStore, profile: Binding<DeviceProfile>) {
        self.state = state
        self.coreAudio = coreAudio
        _profile = profile
        _store = ObservedObject(wrappedValue: state.profiles)
    }

    private var layout: ProfileSectionLayout { store.effectiveLayout(for: profile) }
    private var sections: [ProfileSection] { layout.visibleSections(for: profile) }
    private func updateVisuals() {
        // EQ bands and per-channel controls also display spectrum/level data.
        let demand = layout.visualDemand(for: profile.effectiveEndpointKind)
        state.setRuntimeVisuals(profileID: profile.id, active: true,
            meters: demand.meters, spectrum: demand.spectrum)
        if !demand.spectrum { graphModel.cancel() }
    }

    private func seedGraphIfNeeded() {
        if layout.visualDemand(for: profile.effectiveEndpointKind).spectrum {
            graphModel.seed(profile: profile, state: state)
        } else { graphModel.cancel() }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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
                            .font(.system(size: 20, weight: .regular))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
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

                ForEach(Array(sections.prefix(preparedSectionCount))) { section in
                    StableEditorSection(revision: ProfileEditorSectionRevision(profile: profile, layout: layout)) {
                        profileSection(section)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .disclosureGroupStyle(SectionDisclosureStyle())
        .task(id: sections) {
            // Let AppKit present the header and handle input between expensive
            // section creations. Once prepared, sections stay mounted so
            // scrolling never rebuilds their native controls.
            while preparedSectionCount < sections.count {
                do { try await Task.sleep(for: .milliseconds(20)) }
                catch { return }
                preparedSectionCount += 1
            }
        }
        .onAppear {
            updateVisuals()
            seedGraphIfNeeded()
            installFocusClearingMonitor()
        }
        .onReceive(commands.$request) { request in
            guard let request else { return }
            switch request.intent {
            case .rename(let id) where id == profile.id: beginProfileRename()
            case .profileSettings(let id) where id == profile.id: showingSettings = true
            default: return
            }
            commands.consume(request.id)
        }
        .sheet(isPresented: $showingSettings, onDismiss: { titleFocused = true }) {
            ProfileSettingsView(state: state, profile: profile)
        }
        .onChange(of: showingSettings) { commands.modalReservation = $0 }
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
        .onChange(of: profile.processing) { _ in
            // Auto EQ persists before its replacement event. Keep the spectrum
            // current even while the equalizer section is hidden or preparing.
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
                    SignalMetersView(meters: state.meters, profile: profile)
                    Divider()
                    AudioRuntimeStatusView(monitor: state.meters, profileID: profile.id)
                }.padding(6)
            }
        case .spectrum:
            LiveSpectrumPanels(spectrum: state.spectrum, profileID: profile.id, graphModel: graphModel)
        case .mode:
            SpatialAudioEditorView(state: state, profile: $profile)
        case .deviceCorrection:
            DeviceCorrectionSectionView(state: state, profile: $profile)
        case .equalizer:
            // Keep the callback independent of the page's view state.
            let profileBinding = $profile
            let currentLayout = layout
            GlobalEqualizerEditorView(state: state, profile: $profile, graphModel: graphModel,
                presentation: layout.equalizer, needsResponseGraph: sections.contains(.spectrum) || layout.equalizer != .simpleTone,
                onPresentationChanged: { presentation in
                    var local = currentLayout
                    local.equalizer = presentation
                    profileBinding.wrappedValue.sectionLayout = local
                })
        case .crossfeed:
            EmptyView()
        case .multichannel:
            if profile.hasPhysicalSpeakerRoute { MultichannelProcessingView(state: state, profile: $profile) }
        case .subwooferControl:
            SubwooferControlView(state: state, store: state.profiles, profile: profile)
        case .perChannel:
            PerChannelProcessingView(state: state, profile: $profile)
        case .convolution:
            EmptyView() // Legacy layout identifiers are consolidated before presentation.
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
        let monitorID = UUID()
        focusClearingID = monitorID
        focusClearingMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let keyWindow = NSApp.keyWindow,
                  event.window === keyWindow,
                  let request = TextFocusClearRequest(window: keyWindow),
                  let contentView = keyWindow.contentView else { return event }

            // Most clicks have no text editing to finish. In particular, map
            // pans must not walk the entire retained editor tree before AppKit
            // can deliver mouseDown.
            let location = contentView.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            let clickedView = contentView.hitTest(location)
            // Navigating a read-only map is like scrolling: preserve the field
            // editor rather than committing an unrelated edit before panning.
            if let map = clickedView as? SpeakerRoomNSView, !map.acceptsFirstResponder { return event }

            // Do not mutate first-responder/layout state inside the mouse-down
            // monitor itself. Native controls and SwiftUI gestures must receive
            // the click first; otherwise a focused EQ field can commit/reorder
            // the editor during the same event that starts a slider drag.
            guard !Self.isTextInput(clickedView) else { return event }

            DispatchQueue.main.async {
                guard focusClearingID == monitorID else { return }
                request.perform()
            }
            return event
        }
    }

    private func removeFocusClearingMonitor() {
        focusClearingID = nil
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


private struct ProfileEditorSectionRevision: Equatable {
    let profile: DeviceProfile
    let layout: ProfileSectionLayout
}
