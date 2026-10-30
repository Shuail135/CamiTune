import CamiTuneDomain
import SwiftUI
import AppKit
import Foundation

enum AppAppearance: String, CaseIterable {
    case system, light, dark

    static let storageKey = "appAppearance"
    var displayName: String { rawValue.capitalized }

    @MainActor
    func apply() {
        // Let AppKit propagate the appearance to SwiftUI, native controls,
        // sheets, and menu bar windows without rebuilding their content.
        switch self {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func restore() {
        let saved = UserDefaults.standard.string(forKey: storageKey)
        (saved.flatMap(Self.init(rawValue:)) ?? .system).apply()
    }
}

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var commands: MainWindowCommandCoordinator
    let state: AppState
    @ObservedObject private var store: ProfileStore
    @ObservedObject private var loginItem: LoginItemManager
    @ObservedObject private var updateChecker: AppUpdateChecker
    @ObservedObject private var notifications: NotificationManager
    private var category: String { commands.settingsCategory }
    @State private var type: ProfileEndpointKind = .speakers
    @State private var showingApply = false
    @State private var selectedProfiles: Set<UUID> = []
    @State private var loginItemNotice: LoginItemManager.Notice?
    @AppStorage("hideCloseKeepsRunningHint") private var hideCloseKeepsRunningHint = false
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system
    private let categories = ["General", "App Audio", "Drivers & Components", "Section Layout", "Diagnostics"]

    init(state: AppState) {
        self.state = state
        _store = ObservedObject(wrappedValue: state.profiles)
        _loginItem = ObservedObject(wrappedValue: state.loginItem)
        _updateChecker = ObservedObject(wrappedValue: state.updateChecker)
        _notifications = ObservedObject(wrappedValue: state.notifications)
    }
    var body: some View {
        HStack(spacing: 0) {
            List(categories, id: \.self, selection: $commands.settingsCategory) { Text($0).tag($0) }
                .listStyle(.sidebar).frame(width: 185)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text(category).font(.title.bold())
                switch category {
                case "General":
                    ScrollView { generalSettings }
                        .scrollBounceWhenNeeded()
                case "Drivers & Components":
                    SetupView(state: state, embedded: true)
                case "App Audio":
                    ScrollView { PerAppAudioView(state: state) }
                        .scrollBounceWhenNeeded()
                case "Section Layout":
                    Picker("Device Type", selection: $type) {
                        ForEach(ProfileEndpointKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Text("New profiles and profiles using global defaults will use this layout.")
                        .foregroundStyle(.secondary)
                    SectionLayoutEditor(type: type, layout: Binding(
                        get: { store.defaultLayout(for: type) },
                        set: {
                            store.setDefaultLayout($0, for: type)
                            state.applySectionLayoutToActiveProfile()
                        }), requiresConfirmation: { section in
                            store.profiles.contains { profile in
                                profile.endpointKind == type && profile.sectionLayout == nil
                                    && state.sectionNeedsDisableConfirmation(section, profile: profile)
                            }
                        })
                    Button("Apply to Existing Profiles…") {
                        selectedProfiles = []
                        showingApply = true
                    }
                case "Diagnostics":
                    DiagnosticsView(state: state) {
                        commands.settingsCategory = "Drivers & Components"
                    }
                default: EmptyView()
                }
                Spacer(minLength: 0)
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showingApply) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Apply Layout to Existing Profiles").font(.title2.bold())
                Text("Selected profiles will use the global \(type.displayName) layout. Their local layout overrides will be replaced.")
                List(store.profiles.filter { $0.endpointKind == type }) { profile in
                    Toggle(profile.name, isOn: Binding(
                        get: { selectedProfiles.contains(profile.id) },
                        set: { if $0 { selectedProfiles.insert(profile.id) } else { selectedProfiles.remove(profile.id) } }))
                }
                HStack {
                    Spacer()
                    Button("Cancel") { showingApply = false }.keyboardShortcut(.cancelAction)
                    Button("Apply") {
                        store.applyDefaultLayout(for: type, to: selectedProfiles)
                        state.applySectionLayoutToActiveProfile()
                        showingApply = false
                    }.keyboardShortcut(.defaultAction).disabled(selectedProfiles.isEmpty)
                }
            }.padding(24).frame(width: 480, height: 390)
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Appearance", selection: Binding(get: { appearance }, set: { state.setAppearance($0) })) {
                ForEach(AppAppearance.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Toggle("Start CamiTune at login", isOn: Binding(
                get: { loginItem.isEnabled }, set: { loginItemNotice = loginItem.setEnabled($0) }))
                .disabled(loginItem.isUpdating)
                .alert(loginItemNotice?.title ?? "Login Startup", isPresented: Binding(
                    get: { loginItemNotice != nil },
                    set: { if !$0 { loginItemNotice = nil } }), presenting: loginItemNotice) { notice in
                        if notice.requiresApproval {
                            Button("Open System Settings") { loginItem.openSystemSettings() }
                        }
                        Button("OK", role: .cancel) { }
                    } message: { notice in
                        Text(notice.message)
                    }
            Toggle("Automatically check for updates", isOn: $updateChecker.automaticallyChecksForUpdates)
            Toggle("Show profile activation and deactivation notifications", isOn: $notifications.isEnabled)
            Divider().padding(.vertical, 4)
            Text("Confirmations").font(.headline)
            Toggle("Show profile enabled explanation", isOn: $store.showProfileEnabledExplanation)
            Toggle("Show window closing reminder", isOn: Binding(
                get: { !hideCloseKeepsRunningHint },
                    set: { state.setClosingReminder($0) }))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }
}

