import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarViewModel: ObservableObject {
    let state: AppState
    @Published private(set) var actionInFlight = false
    let reorder: MenuAppReorderCoordinator
    @Published var pendingOffProfileID: UUID?
    // Routing can temporarily lose its active profile during a mode change.
    // Keep the controls attached to the same profile until the command finishes.
    private var actionProfile: DeviceProfile?
    private var actionWasActive = false
    private var subscriptions: Set<AnyCancellable> = []
    private var isOpen = false
    private weak var menuWindow: NSWindow?
    private let menuWindows = NSHashTable<NSWindow>.weakObjects()
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?

    func registerMenuWindow(_ window: NSWindow?, root: Bool = false) {
        guard let window else { return }
        menuWindows.add(window)
        if root { menuWindow = window }
    }

    func dismissMenu() {
        pendingOffProfileID = nil
        close()
        for window in menuWindows.allObjects where window !== menuWindow {
            window.orderOut(nil)
        }
        menuWindow?.orderOut(nil)
    }

    private func containsMenuWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if menuWindows.contains(window) { return true }
        if let parent = window.parent ?? window.sheetParent {
            return containsMenuWindow(parent)
        }
        // AppKit owns the pull-down's tracking window, rather than SwiftUI.
        return window.level == .popUpMenu
    }

    private func startDismissalMonitoring() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            if let self, self.reorder.draggedApplicationID == nil, !self.containsMenuWindow(event.window) { self.dismissMenu() }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            guard let self, self.reorder.draggedApplicationID == nil else { return }
            self.dismissMenu()
        }
        deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isOpen, self.reorder.draggedApplicationID == nil else { return }
                self.dismissMenu()
            }
        }
    }

    private func stopDismissalMonitoring() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        localClickMonitor = nil
        globalClickMonitor = nil
        deactivateObserver = nil
    }

    deinit {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
    }

    init(state: AppState) {
        self.state = state
        reorder = MenuAppReorderCoordinator(store: state.perAppAudio.presentationStore)
        Publishers.Merge3(state.objectWillChange, state.profiles.objectWillChange,
                          state.coreAudio.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)

    }

    var profile: DeviceProfile? {
        let store = state.profiles
        if let actionProfile {
            return store.profiles.first { $0.id == actionProfile.id } ?? actionProfile
        }
        let output = state.coreAudio.defaultOutputUID
        let candidates = [state.activeProfileID,
            output.flatMap(ProfileRoutingDescriptor.profileID(from:)),
            output.flatMap { store.automaticProfileID(forPhysicalDeviceUID: $0) },
            store.selectedProfileID]
        return candidates.compactMap { id in store.profiles.first { $0.id == id } }.first
    }

    var isActive: Bool { state.isActive && state.activeProfileID == profile?.id }
    var runtimeControlSelection: Bool { actionInFlight ? actionWasActive : isActive }

    private func beginAction(profile: DeviceProfile) {
        actionWasActive = state.isActive && state.activeProfileID == profile.id
        actionProfile = profile
        actionInFlight = true
    }

    private func finishAction() {
        actionProfile = nil
        actionInFlight = false
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        startDismissalMonitoring()
        state.perAppAudio.setMeterPresentationActive(true, source: "menu")
    }

    func close() {
        isOpen = false
        stopDismissalMonitoring()
        state.perAppAudio.setMeterPresentationActive(false, source: "menu")
        reorder.cancel()
    }

    func setRuntimeActive(_ enabled: Bool) {
        guard !actionInFlight, !state.transitionInProgress, !state.isSavingProfileSettings, let profile else { return }
        if !enabled && state.profiles.activationMode(for: profile) == .physicalOutput {
            pendingOffProfileID = profile.id
            return
        }
        performRuntimeAction(profileID: profile.id, enabled: enabled, confirmed: false)
    }

    func confirmOff(profileID id: UUID) {
        pendingOffProfileID = nil
        performRuntimeAction(profileID: id, enabled: false, confirmed: true)
    }

    private func performRuntimeAction(profileID: UUID, enabled: Bool, confirmed: Bool) {
        guard !actionInFlight,
              let profile = state.profiles.profiles.first(where: { $0.id == profileID }) else { return }
        beginAction(profile: profile)
        Task {
            defer { finishAction() }
            if enabled {
                guard let current = state.profiles.profiles.first(where: { $0.id == profileID }) else { return }
                await state.activate(profile: current)
            } else {
                await state.deactivateProfileFromMenu(profileID: profileID, physicalOutputConfirmed: confirmed)
            }
        }
    }

    func selectOutputProfile(_ id: UUID) {
        guard !actionInFlight, !state.transitionInProgress,
              !state.isSavingProfileSettings, state.spatialCalibrationContext == nil,
              let profile = state.profiles.profiles.first(where: { $0.id == id && $0.isEnabled }),
              !(state.isActive && state.activeProfileID == id) else { return }
        pendingOffProfileID = nil
        beginAction(profile: profile)
        Task {
            defer { finishAction() }
            guard let current = state.profiles.profiles.first(where: { $0.id == id && $0.isEnabled }) else { return }
            await state.activate(profile: current)
        }
    }

    func setPlaybackMode(_ mode: PlaybackMode) {
        guard !actionInFlight,
              !state.transitionInProgress,
              !state.isSavingProfileSettings,
              let profile,
              profile.playbackMode != mode else {
            return
        }
        beginAction(profile: profile)
        Task {
            defer { finishAction() }
            await state.setPlaybackMode(
                profileID: profile.id,
                mode: mode
            )
            guard let updatedProfile = state.profiles.profiles.first(
                where: { $0.id == profile.id }
            ),
            updatedProfile.playbackMode == mode else {
                return
            }
            state.perAppAudio.setPlaybackModeForAllApplications(mode)
        }
    }
}

@MainActor
struct MenuBarRootView: View {
    @StateObject private var model: MenuBarViewModel

    init(state: AppState) {
        _model = StateObject(wrappedValue: MenuBarViewModel(state: state))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            outputSection.padding(12)
            Divider()
            MenuBarApplicationsSection(controller: model.state.perAppAudio,
                presentation: model.state.perAppAudio.presentationStore, reorder: model.reorder,
                profile: model.isActive ? model.profile : nil)
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Button("Open CamiTune") {
                    model.dismissMenu()
                    CamiTunePresentationCoordinator.shared.showMainWindow()
                    Task { await model.state.updateChecker.checkAfterReminderIfNeeded() }
                }
                Button("Quit CamiTune") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(MenuBarCommandStyle())
            .padding(6)
        }
        .frame(width: 370)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(MenuBarPresentationObserver(windowChanged: { model.registerMenuWindow($0, root: true) }) { visible in
            if visible { model.open() } else { model.close() }
        })
        .controlSize(.small)
        .environmentObject(model)
        .onAppear { model.open() }
        .onDisappear { model.close() }
        .alert("CamiTune", isPresented: Binding(
            get: { model.state.errorMessage != nil },
            set: { if !$0 { model.state.errorMessage = nil } }
        )) {
            Button("OK") { model.state.errorMessage = nil }
        } message: { Text(model.state.errorMessage ?? "") }
    }

    private var offConfirmation: some View {
        Group {
            if let id = model.pendingOffProfileID {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Turn off this profile?")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Automatic activation will change from Physical output to Profile audio device. Audio will return to the original physical output.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Cancel", role: .cancel) { model.pendingOffProfileID = nil }
                            .keyboardShortcut(.cancelAction)
                        Button("Turn Off") { model.confirmOff(profileID: id) }
                            .keyboardShortcut(.defaultAction)
                    }
                    .controlSize(.small)
                }
                .padding(14)
                .frame(width: 340)
                .background(Color(nsColor: .windowBackgroundColor))
                .background(MenuBarPresentationObserver(windowChanged: { model.registerMenuWindow($0) }) { _ in })
            }
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("OUTPUT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 3) {
                        Image(systemName: model.isActive ? "circle.fill" : "circle.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 5, height: 5)

                        Text(model.isActive ? "Active" : "Inactive")
                            .font(.caption)
                    }
                    .foregroundStyle(model.isActive ? Color.green : Color.secondary)
            }
            if let profile = model.profile {
                HStack(spacing: 8) {
                    outputProfileMenu(title: profile.name)
                    Spacer(minLength: 0)
                    MenuBarRuntimeControl(
                        isActive: model.runtimeControlSelection,
                        isVisuallyEnabled:
                            !model.state.isSavingProfileSettings
                            && model.state.spatialCalibrationContext == nil,
                        isInteractive:
                            !model.actionInFlight
                            && !model.state.transitionInProgress
                            && !model.state.isSavingProfileSettings
                            && model.state.spatialCalibrationContext == nil,
                        confirmationID: model.pendingOffProfileID,
                        confirmation: AnyView(offConfirmation),
                        onChange: { model.setRuntimeActive($0) },
                        onDismissConfirmation: { model.pendingOffProfileID = nil }
                    )
                    .frame(width: 84, height: 24)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mode").font(.caption)
                    JoinedSegmentedControl(options: profile.availablePlaybackModes, selection: Binding(
                        get: { profile.playbackMode }, set: { model.setPlaybackMode($0) }
                    ), title: { $0.compactDisplayName }, symbol: { $0.systemImageName }, unavailableReason: { profile.playbackReadiness($0).reason })
                    .accessibilityLabel("Mode")
                    .disabled(model.actionInFlight || model.state.transitionInProgress || model.state.isSavingProfileSettings || model.state.spatialCalibrationContext != nil)
                }
            } else {
                outputProfileMenu(title: "No output profile")
            }
        }
    }

    private func outputProfileMenu(title: String) -> some View {
        outputProfileLabel(title: title)
            .overlay {
                Menu {
                    ForEach(model.state.profiles.effectiveRootOrder, id: \.self) { item in
                        switch item {
                        case .profile(let id):
                            if let profile = model.state.profiles.profiles.first(where: { $0.id == id && $0.isEnabled }) {
                                outputProfileOption(profile)
                            }
                        case .folder(let id):
                            if let folder = model.state.profiles.folders.first(where: { $0.id == id }) {
                                let profiles = folder.profileIDs.compactMap { id in
                                    model.state.profiles.profiles.first { $0.id == id && $0.isEnabled }
                                }
                                if !profiles.isEmpty {
                                    Menu(folder.name) {
                                        ForEach(profiles) { profile in outputProfileOption(profile) }
                                    }
                                }
                            }
                        }
                    }
                    if !model.state.profiles.profiles.contains(where: \.isEnabled) {
                        Text("No enabled profiles")
                    }
                } label: {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("Output profile: \(title)")
            }
        .disabled(model.actionInFlight || model.state.transitionInProgress
            || model.state.isSavingProfileSettings || model.state.spatialCalibrationContext != nil)
    }

    private func outputProfileLabel(title: String) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.headline).lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
                .fixedSize()
                .layoutPriority(1)
        }
        .frame(maxWidth: 238, minHeight: 24, alignment: .leading)
    }

    private func outputProfileOption(_ profile: DeviceProfile) -> some View {
        Toggle(profile.name, isOn: Binding(
            get: { model.state.isActive && model.state.activeProfileID == profile.id },
            set: { _ in model.selectOutputProfile(profile.id) }
        ))
    }
}

/// Keep one AppKit control and one popover anchor alive across SwiftUI updates.
/// Mode changes only update enabled state; they never replace the runtime view.
struct MenuBarRuntimeControl: NSViewRepresentable {
    let isActive: Bool
    let isVisuallyEnabled: Bool
    let isInteractive: Bool
    let confirmationID: UUID?
    let confirmation: AnyView
    let onChange: (Bool) -> Void
    let onDismissConfirmation: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["On", "Off"], trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.selectionChanged(_:)))
        control.segmentStyle = .rounded
        control.segmentDistribution = .fill
        control.controlSize = .small
        control.font = .systemFont(ofSize: 11)
        control.selectedSegmentBezelColor = .systemBlue
        control.setAccessibilityLabel("Profile runtime")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let selected = isActive ? 0 : 1
        if control.selectedSegment != selected { control.selectedSegment = selected }
        if control.isEnabled != isVisuallyEnabled {control.isEnabled = isVisuallyEnabled}

        if let confirmationID {
            guard coordinator.presentedID != confirmationID else { return }
            coordinator.presentedID = confirmationID
            coordinator.popover.contentViewController = NSHostingController(rootView: confirmation)
            coordinator.popover.show(relativeTo: control.bounds, of: control, preferredEdge: .minY)
        } else if coordinator.presentedID != nil {
            coordinator.presentedID = nil
            coordinator.popover.close()
        }
    }

    static func dismantleNSView(_ control: NSSegmentedControl, coordinator: Coordinator) {
        coordinator.popover.delegate = nil
        coordinator.popover.close()
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: MenuBarRuntimeControl
        var presentedID: UUID?
        let popover = NSPopover()

        init(parent: MenuBarRuntimeControl) {
            self.parent = parent
            super.init()
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let requested = sender.selectedSegment == 0
            sender.selectedSegment = parent.isActive ? 0 : 1
            guard parent.isInteractive else {
                return
            }
            guard requested != parent.isActive else {
                return
            }
            parent.onChange(requested)
        }
        
        func popoverDidClose(_ notification: Notification) {
            guard presentedID != nil else { return }
            presentedID = nil
            parent.onDismissConfirmation()
        }
    }
}

/// One joined track keeps icon/text labels and blue selection consistent,
/// including when the menu window does not have normal key-window emphasis.
struct JoinedSegmentedControl<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var symbol: (Value) -> String? = { _ in nil }
    var unavailableReason: (Value) -> String? = { _ in nil }
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    HStack(spacing: 4) {
                        if let image = symbol(option) { Image(systemName: image) }
                        Text(title(option)).lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .foregroundStyle(isEnabled && selection == option ? Color.white : Color.primary)
                    .background(selection == option
                        ? (isEnabled ? Color.blue : Color.secondary.opacity(0.25))
                        : Color.clear)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
                .disabled(unavailableReason(option) != nil)
                .help(unavailableReason(option) ?? title(option))

                if option != options.last {
                    Rectangle()
                        .fill(Color.gray.opacity(0.4))
                        .frame(width: 0.5, height: 16)
                        .accessibilityHidden(true)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .opacity(isEnabled ? 1 : 0.65)
        .transaction { $0.animation = nil }
    }
}

/// MenuBarExtra may retain its SwiftUI tree between openings. Observe the
/// window too, so reopening reranks apps and a hidden menu never retains meters.
private struct MenuBarPresentationObserver: NSViewRepresentable {
    var windowChanged: (NSWindow?) -> Void = { _ in }
    let visibilityChanged: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.windowChanged = windowChanged
        view.visibilityChanged = visibilityChanged
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.windowChanged = windowChanged
        view.visibilityChanged = visibilityChanged
    }

    final class VisibilityView: NSView {
        var windowChanged: ((NSWindow?) -> Void)?
        var visibilityChanged: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowChanged?(window)
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification,
                    object: window, queue: .main
                ) { [weak self] _ in self?.publishVisibility() }
            }
            DispatchQueue.main.async { [weak self] in self?.publishVisibility() }
        }
        private func publishVisibility() {
            visibilityChanged?(window?.isVisible == true && window?.occlusionState.contains(.visible) == true)
        }
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

private struct MenuBarCommandStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CommandLabel(configuration: configuration)
    }

    private struct CommandLabel: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .foregroundStyle(hovering || configuration.isPressed ? Color.white : Color.primary)
                .background(hovering || configuration.isPressed ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

@MainActor
private struct MenuBarApplicationsSection: View {
    @EnvironmentObject private var model: MenuBarViewModel
    @ObservedObject var controller: PerAppAudioController
    @ObservedObject var presentation: AppPresentationStore
    @ObservedObject var reorder: MenuAppReorderCoordinator
    let profile: DeviceProfile?
    @State private var primaryCount = 6

    private var applications: [PerAppAudioApplication] {
        presentation.orderedApplications(controller.applications.filter(\.isActive), in: .shown)
    }

    private var showingMore: Binding<Bool> {
        Binding(get: { reorder.showingMoreApps }, set: {
            if $0 || reorder.draggedApplicationID == nil { reorder.showingMoreApps = $0 }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("APPLICATIONS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.bottom, 5)
            if applications.isEmpty {
                Text("No shown apps are playing audio.")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(Array(applications.prefix(primaryCount))) { app in row(app) }
            if applications.count > primaryCount, let boundary = applications.prefix(primaryCount).last {
                MenuAppDropBridge(applicationID: boundary.id, isMoreAppsBridge: true, coordinator: reorder) {
                    Button { reorder.openMoreApps() } label: {
                        HStack {
                            Text("More Apps")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                    }
                    .buttonStyle(MenuBarCommandStyle())
                    .background(reorder.hoveringBridge && reorder.draggedApplicationID != nil
                        ? Color.accentColor.opacity(0.12) : Color.clear)
                    .onHover { reorder.bridgeHover($0) }
                }
                .frame(height: 26)
                .popover(isPresented: showingMore, arrowEdge: .trailing) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(applications.dropFirst(primaryCount))) { app in row(app, isPopover: true) }
                        }.padding(8)
                    }
                    .frame(width: 360, height: min(330, CGFloat(applications.count - primaryCount) * 30 + 16))
                    .background(Color(nsColor: .windowBackgroundColor))
                    .background(MenuBarPresentationObserver(windowChanged: { model.registerMenuWindow($0) }) { _ in })
                    .onHover { reorder.popoverHover($0) }
                }
            }
        }
        .onAppear {
            let height = NSScreen.main?.visibleFrame.height ?? 800
            primaryCount = min(6, max(1, Int((height - 280) / 30)))
        }
        .onDisappear { reorder.cancel() }
    }

    private func row(_ app: PerAppAudioApplication, isPopover: Bool = false) -> some View {
        MenuAppDropBridge(applicationID: app.id, isPopover: isPopover, coordinator: reorder) {
            MenuBarApplicationRow(application: app, displayedName: presentation.displayName(for: app),
                controller: controller, context: profile.map(PerAppPlaybackContext.init(profile:)), reorder: reorder,
                isLoading: model.actionInFlight || model.state.transitionInProgress)
        }
        .frame(height: 30)
        .opacity(reorder.draggedApplicationID == app.id ? 0.6 : 1)
        .overlay(alignment: reorder.dropTarget?.after == true ? .bottom : .top) {
            if reorder.dropTarget?.applicationID == app.id {
                Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
            }
        }
    }
}

@MainActor
private struct MenuBarApplicationRow: View {
    let application: PerAppAudioApplication
    let displayedName: String
    let controller: PerAppAudioController
    let context: PerAppPlaybackContext?
    let reorder: MenuAppReorderCoordinator
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 6) {
            MenuAppDragSource(application: application, displayedName: displayedName, coordinator: reorder)
                .frame(width: 124, height: 30)
            Button {
                controller.setMuted(!application.settings.isMuted, for: application.id)
            } label: {
                Image(systemName: application.settings.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(application.settings.isMuted ? "Unmute" : "Mute") \(displayedName)")
            HorizontalMeteredVolumeSlider(volume: application.settings.volume,
                level: application.settings.isMuted ? 0 : application.level,
                applicationName: displayedName) { volume, finished in
                    controller.setVolume(volume, for: application.id, interactionFinished: finished)
                }
                .frame(maxWidth: .infinity).frame(height: 24)
            PerAppPlaybackModeMenu(application: application, displayedName: displayedName, controller: controller,
                context: context, isLoading: isLoading)
                .frame(width: 30)
        }
        .frame(height: 30)
    }
}

private struct HorizontalMeteredVolumeSlider: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let volume: Double
    let level: Double
    let applicationName: String
    let onVolumeChange: (Double, Bool) -> Void
    @State private var interactionVolume: Double?
    @State private var displayedLevel = 0.0

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 14)
            let amount = min(1, max(0, interactionVolume ?? volume))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.22)).frame(height: 5)
                Capsule().fill(Color.accentColor)
                    .frame(width: width * displayedLevel, height: 5)
                Circle().fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Circle().stroke(Color.secondary, lineWidth: 0.75))
                    .frame(width: 13, height: 13).offset(x: width * amount - 6.5)
            }
            .frame(width: width, height: geometry.size.height)
            .padding(.horizontal, 7)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let next = min(1, max(0, Double((value.location.x - 7) / width)))
                interactionVolume = next
                onVolumeChange(next, false)
            }.onEnded { value in
                let next = min(1, max(0, Double((value.location.x - 7) / width)))
                onVolumeChange(next, true)
                interactionVolume = nil
            })
        }
        .onAppear { displayedLevel = min(1, max(0, level)) }
        .onChange(of: level) { newLevel in
            withAnimation(reduceMotion ? nil : .easeOut(duration: newLevel > displayedLevel ? 0.06 : 0.24)) {
                displayedLevel = min(1, max(0, newLevel))
            }
        }
        .focusable()
        .onMoveCommand { direction in
            let increment: Double
            switch direction {
            case .up, .right: increment = 0.01
            case .down, .left: increment = -0.01
            default: return
            }
            onVolumeChange(min(1, max(0, (interactionVolume ?? volume) + increment)), true)
            interactionVolume = nil
        }
        .accessibilityElement()
        .accessibilityLabel("\(applicationName) volume")
        .accessibilityValue("\(Int(((interactionVolume ?? volume) * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onVolumeChange(min(1, volume + 0.01), true)
            case .decrement: onVolumeChange(max(0, volume - 0.01), true)
            @unknown default: break
            }
        }
    }
}
