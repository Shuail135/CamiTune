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
    @State private var settingsDestination: ProfileSettingsView.Destination?
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
    private var sections: [ProfileSection] { layout.editorSections(for: profile) }
    private func updateVisuals() {
        // EQ bands and per-channel controls also display spectrum/level data.
        let demand = layout.visualDemand(for: profile)
        state.setRuntimeVisuals(profileID: profile.id, active: true,
            meters: demand.meters, spectrum: demand.spectrum)
        if !demand.spectrum { graphModel.cancel() }
    }

    private func seedGraphIfNeeded() {
        if layout.visualDemand(for: profile).spectrum {
            graphModel.seed(profile: profile, state: state)
        } else { graphModel.cancel() }
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ProfileHeaderLayout {
                    HStack(alignment: .firstTextBaseline) {
                        Button { beginProfileRename() } label: {
                            HStack(spacing: 8) {
                                Text(profile.name)
                                    .font(.largeTitle.bold())
                                    .lineLimit(1)
                                    .alignmentGuide(.profileNameTrailing) { $0[.trailing] }
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
                        .disabled(isRenamingProfile)
                        .accessibilityHidden(isRenamingProfile)
                        .opacity(isRenamingProfile ? 0 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Retain the title's size and baseline while editing.
                        .overlay(alignment: .leadingFirstTextBaseline) {
                            if isRenamingProfile {
                                TextField("Profile name", text: $profileNameDraft)
                                    .font(.largeTitle.bold())
                                    .textFieldStyle(.plain)
                                    .frame(maxWidth: 480)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .focused($profileNameFocused)
                                    .onSubmit { commitProfileRename() }
                                    .onExitCommand { cancelProfileRename() }
                            }
                        }
                        Button { settingsDestination = .general } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 20, weight: .regular))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
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
                    }
                    ProfileConnectionStatusView(
                        coreAudio: coreAudio,
                        outputDeviceUID: profile.outputDeviceUID
                    )
                    .fixedSize()
                }

                ForEach(Array(sections.prefix(preparedSectionCount))) { section in
                    StableEditorSection(revision: ProfileEditorSectionRevision(profile: profile, layout: layout)) {
                        profileSection(section).id(profile.deviceTypeConfigurationKey)
                    }
                    .groupBoxStyle(ProfileSectionBoxStyle())
                    .id(section)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: commands.appAudioRevealProfileID) {
            guard commands.appAudioRevealProfileID == profile.id else { return }
            preparedSectionCount = sections.count
            await Task.yield()
            proxy.scrollTo(ProfileSection.appAudio, anchor: .top)
            commands.appAudioRevealProfileID = nil
        }
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
            case .profileSettings(let id) where id == profile.id: settingsDestination = .general
            default: return
            }
            commands.consume(request.id)
        }
        .sheet(item: $settingsDestination, onDismiss: { titleFocused = true }) { destination in
            ProfileSettingsView(state: state, profile: profile, destination: destination)
        }
        .onChange(of: settingsDestination) { commands.modalReservation = $0 != nil }
        .onChange(of: layout) { _ in
            updateVisuals()
            if sections.contains(.equalizer) || sections.contains(.spectrum) {
                seedGraphIfNeeded()
            }
        }
        .onChange(of: profile.pluginRack.outputMode) { _ in updateVisuals(); seedGraphIfNeeded() }
        .onChange(of: profile.deviceTypeConfigurationKey) { _ in updateVisuals(); seedGraphIfNeeded() }
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
        case .appAudio:
            PerAppAudioView(state: state, profile: profile)
        case .meters:
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(ProfileSection.meters.title).font(.title3.bold())
                        Spacer(minLength: 0)
                        LiveClippingWarning(monitor: state.meters, profileID: profile.id)
                    }
                    SignalMetersView(meters: state.meters, profile: profile)
                    Divider()
                    MeterStatusDisclosure(monitor: state.meters, profileID: profile.id)
                }.padding(6)
            }
        case .spectrum:
            LiveSpectrumPanels(spectrum: state.spectrum, profileID: profile.id, graphModel: graphModel)
        case .mode:
            SpatialAudioEditorView(state: state, profile: $profile)
        case .deviceCorrection:
            DeviceCorrectionSectionView(state: state, profile: $profile)
        case .plugins:
            PluginRackView(state: state, profile: $profile)
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
            SubwooferControlView(state: state, store: state.profiles, profile: profile,
                onOpenSettings: { settingsDestination = .subwoofer })
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


/// Keep the status under the name's trailing edge, clamped to its leading edge
/// for short names. The status uses the existing gap below the header.
struct ProfileHeaderLayout: Layout {
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect,
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect,
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let headerView = subviews.first else { return }
        let headerProposal = ProposedViewSize(width: bounds.width, height: bounds.height)
        headerView.place(at: bounds.origin, anchor: .topLeading, proposal: headerProposal)
        // SwiftUI removes the conditional status child when the output connects.
        // This can happen on the initial device refresh as well as a profile edit.
        guard subviews.count > 1 else { return }
        let header = headerView.dimensions(in: headerProposal)
        let status = subviews[1].sizeThatFits(.unspecified)
        let statusX = max(0, header[.profileNameTrailing] - status.width)
        subviews[1].place(at: CGPoint(x: bounds.minX + statusX, y: bounds.maxY + 4),
            anchor: .topLeading, proposal: .unspecified)
    }
}

private extension HorizontalAlignment {
    private enum ProfileNameTrailing: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[.trailing]
        }
    }

    static let profileNameTrailing = HorizontalAlignment(ProfileNameTrailing.self)
}

private struct ProfileSectionBoxStyle: GroupBoxStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        // In light appearance, stay just below the surrounding profile surface.
        let background = colorScheme == .dark
            ? Color(.sRGB, red: 53.0 / 255, green: 54.0 / 255, blue: 54.0 / 255, opacity: 1)
            : Color.black.opacity(0.015)
        VStack(alignment: .leading, spacing: 8) {
            configuration.label.font(.headline)
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
    }
}

private struct ProfileEditorSectionRevision: Equatable {
    let profile: DeviceProfile
    let layout: ProfileSectionLayout
}
