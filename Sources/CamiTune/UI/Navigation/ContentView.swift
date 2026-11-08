import SwiftUI
import Foundation
import AppKit
import QuartzCore

enum SidebarDestination: Hashable, Sendable {
    case empty, settings, profile(UUID)

    var storageValue: String {
        switch self {
        case .empty: return "empty"
        case .settings: return "settings"
        case .profile(let id): return id.uuidString
        }
    }

    static func restore(_ saved: String?, profileIDs: Set<UUID>, fallbackProfileID: UUID?) -> Self {
        switch saved {
        case "settings", "global-settings", "default-profiles": return .settings
        default:
            if let saved, let id = UUID(uuidString: saved), profileIDs.contains(id) { return .profile(id) }
            if let fallbackProfileID, profileIDs.contains(fallbackProfileID) { return .profile(fallbackProfileID) }
            return .empty
        }
    }
}

@MainActor
struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: AppState
    private let history: UndoCoordinator
    private let preferences: UserDefaults
    let commands: MainWindowCommandCoordinator
    @State private var sidebarVisible = true
    @State private var discoveringOutput = false

    @State private var selection: SidebarDestination
    @State private var showingOutputPicker = false
    @State private var pendingOutputUID: String?
    @State private var pendingOutputFolderID: UUID?

    init(state: AppState, commands: MainWindowCommandCoordinator? = nil, preferences: UserDefaults = .standard) {
        self.commands = commands ?? MainWindowCommandCoordinator()
        self.state = state
        self.history = state.history
        self.preferences = preferences
        let saved = preferences.string(forKey: "lastSidebarSelection")
        let restored = SidebarDestination.restore(saved,
            profileIDs: Set(state.profiles.profiles.map(\.id)),
            fallbackProfileID: state.profiles.selectedProfileID)
        self._selection = State(initialValue: restored)
        self._sidebarVisible = State(initialValue:
            preferences.object(forKey: "mainWindowSidebarVisible") as? Bool ?? true)
    }

    var body: some View {
        MainWindowSplit(sidebarVisible: $sidebarVisible) {
            SidebarView(
                state: state,
                profileStore: state.profiles,
                selection: $selection,
                onAddOutput: { folderID in await beginAddingOutput(in: folderID) }
            )
            .transaction { $0.animation = nil }
        } detail: {
            ContentDetailView(
                state: state,
                profileStore: state.profiles,
                coreAudio: state.coreAudio,
                selection: selection
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay(Group {
                Divider()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }, alignment: .top)
            // The split view owns the slide. Editor controls should lay out
            // at their current width without starting nested animations.
            .transaction { $0.animation = nil }
        }


        .environmentObject(commands)
        .environment(\.undoCommandRouter, state.undoCommands)
        .modifier(HistoryReplayInteractionGate(history: history))
        .onAppear {
            commands.selection = selection
            commands.sidebarVisible = sidebarVisible
        }
        .onChange(of: sidebarVisible) { visible in
            commands.sidebarVisible = visible
            preferences.set(visible, forKey: "mainWindowSidebarVisible")
        }
        .onReceive(commands.$request) { request in
            guard let request else { return }
            switch request.intent {
            case .settings: selection = .settings
            case .appAudio:
                selection = commands.appAudioDestination(in: state.profiles, activeProfileID: state.activeProfileID)
            case .addOutput: Task { await beginAddingOutput() }
            case .openSetup:
                state.setupPresentation.isPresented = true
            case .toggleSidebar:
                sidebarVisible.toggle()
            case .rename, .profileSettings: return // The selected editor owns inline edit and its settings sheet.
            }
            commands.consume(request.id)
        }
        .onChange(of: showingOutputPicker) { if !$0 { commands.modalReservation = false } }
        .onChange(of: selection) { newSelection in
            commands.selection = newSelection
            preferences.set(newSelection.storageValue, forKey: "lastSidebarSelection")
            if case .profile(let id) = newSelection {
                state.profiles.selectedProfileID = id
            }
        }
        .sheet(isPresented: $showingOutputPicker) {
            AddOutputProfileSheet(state: state, initialUID: pendingOutputUID,
                onCancel: cancelAddingOutput) { id in
                    if let folderID = pendingOutputFolderID {
                        state.profiles.assignProfiles(ids: [id], toFolder: folderID)
                    }
                    selection = .profile(id)
                    showingOutputPicker = false
                    pendingOutputUID = nil
                    pendingOutputFolderID = nil
                }
        }
        .modifier(SetupPresentationModifier(state: state, presentation: state.setupPresentation))
        .modifier(ProfileConfirmationModifier(presentation: state.profileConfirmations, store: state.profiles))
        .modifier(AppErrorPresentationModifier(state: state))
        .modifier(AppUpdatePresentationModifier(updateChecker: state.updateChecker))
    }

    private func beginAddingOutput(in folderID: UUID? = nil) async {
        guard !discoveringOutput, !showingOutputPicker else { return }
        pendingOutputFolderID = folderID
        discoveringOutput = true
        commands.modalReservation = true
        defer { discoveringOutput = false }
        // The HAL/device scan itself runs off-main inside
        // refreshWithoutBlockingUI(); only the small state update returns here.
        await state.coreAudioService.refreshWithoutBlockingUI()
        let devices = state.coreAudio.physicalOutputDevices
        pendingOutputUID = devices.first(where: {
            $0.id == state.coreAudio.defaultOutputUID
        })?.id ?? devices.first?.id
        showingOutputPicker = true
    }

    private func cancelAddingOutput() {
        showingOutputPicker = false
        pendingOutputUID = nil
        pendingOutputFolderID = nil
    }

}

/// AppKit owns the split panes, including the sidebar material, divider and
/// collapse animation. SwiftUI retains the editor state inside each pane.
private struct MainWindowSplit<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    @Binding var sidebarVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    func makeNSViewController(context: Context) -> MainWindowSplitController {
        MainWindowSplitController(sidebarVisible: sidebarVisible)
    }
    func updateNSViewController(_ controller: MainWindowSplitController, context: Context) {
        controller.sidebar.rootView = AnyView(sidebar().environment(\.self, context.environment))
        controller.detail.rootView = AnyView(detail().environment(\.self, context.environment))
        controller.visibilityChanged = { if sidebarVisible != $0 { sidebarVisible = $0 } }
        // Collapsing synchronously lays out the hosted profile. Start after
        // SwiftUI finishes this update so that layout does not reenter its graph.
        // Read the binding then, so rapid requests use the latest visibility.
        DispatchQueue.main.async { [weak controller] in
            guard let controller else { return }
            controller.setSidebarVisible(sidebarVisible, animate: !reduceMotion && controller.view.window != nil)
        }
    }
}

private final class MainWindowSplitController: NSSplitViewController {
    let sidebar = NSHostingController(rootView: AnyView(EmptyView()))
    let detail = NSHostingController(rootView: AnyView(EmptyView()))
    var visibilityChanged: ((Bool) -> Void)?
    private var collapseObservation: NSKeyValueObservation?

    init(sidebarVisible: Bool) {
        super.init(nibName: nil, bundle: nil)
        // The split view owns pane sizes and the window owns its minimum size;
        // offscreen editors must not supply additional min/max constraints.
        if #available(macOS 13, *) {
            sidebar.sizingOptions = []
            detail.sizingOptions = []
        }
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let item = NSSplitViewItem(sidebarWithViewController: sidebar)
        item.minimumThickness = SidebarLayout.minimumWidth
        item.maximumThickness = 260
        item.preferredThicknessFraction = (SidebarLayout.minimumWidth + 15) / 1000
        item.canCollapse = true
        item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        // NSSplitViewItem uses its own "collapsed" animation. An enclosing
        // animation context does not override that animation's duration.
        let collapse = CABasicAnimation()
        collapse.duration = 0.3
        collapse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        item.animations = ["collapsed": collapse]
        item.isCollapsed = !sidebarVisible
        addSplitViewItem(item)
        addSplitViewItem(NSSplitViewItem(viewController: detail))
        collapseObservation = item.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            self?.visibilityChanged?(!item.isCollapsed)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setSidebarVisible(_ visible: Bool, animate: Bool) {
        guard let item = splitViewItems.first, item.isCollapsed == visible else { return }
        if animate {
            item.animator().isCollapsed = !visible
        } else { item.isCollapsed = !visible }
    }
}
