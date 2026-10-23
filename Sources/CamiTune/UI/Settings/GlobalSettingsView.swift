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
    private var category: String { commands.settingsCategory }
    @State private var type: ProfileEndpointKind = .speakers
    @State private var showingApply = false
    @State private var showingApplyBuffer = false
    @State private var savingBuffer = false
    @State private var bufferFailure: String?
    @State private var selectedProfiles: Set<UUID> = []
    @State private var loginItemNotice: LoginItemManager.Notice?
    @AppStorage("hideCloseKeepsRunningHint") private var hideCloseKeepsRunningHint = false
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system
    private let categories = ["General", "Audio", "Drivers & Components", "Section Layout", "Diagnostics"]

    init(state: AppState) {
        self.state = state
        _store = ObservedObject(wrappedValue: state.profiles)
        _loginItem = ObservedObject(wrappedValue: state.loginItem)
        _updateChecker = ObservedObject(wrappedValue: state.updateChecker)
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
                case "Audio":
                    audioSettings
                case "Drivers & Components":
                    SetupView(state: state, embedded: true)
                case "Section Layout":
                    Picker("Device Type", selection: $type) {
                        ForEach(ProfileEndpointKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Text("New profiles and profiles using global defaults will use this layout.")
                        .foregroundStyle(.secondary)
                    SectionLayoutEditor(type: type, layout: Binding(
                        get: { store.defaultLayout(for: type) },
                        set: { store.setDefaultLayout($0, for: type) }))
                    Button("Apply to Existing Profiles…") {
                        selectedProfiles = []
                        showingApply = true
                    }
                case "Diagnostics":
                    DiagnosticsView(state: state)
                default: EmptyView()
                }
                Spacer(minLength: 0)
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: appearance) { $0.apply() }
        .alert("Audio Buffer", isPresented: Binding(get: { bufferFailure != nil }, set: { if !$0 { bufferFailure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(bufferFailure ?? "") }
        .sheet(isPresented: $showingApplyBuffer) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Apply Audio Buffer to Existing Profiles").font(.title2.bold())
                Text("Selected profiles will use the global audio buffer. Their local buffer overrides will be replaced.")
                List(store.profiles) { profile in
                    Toggle(profile.name, isOn: Binding(
                        get: { selectedProfiles.contains(profile.id) },
                        set: { if $0 { selectedProfiles.insert(profile.id) } else { selectedProfiles.remove(profile.id) } }))
                }
                HStack {
                    Spacer()
                    Button("Cancel") { showingApplyBuffer = false }.keyboardShortcut(.cancelAction)
                    Button("Apply") { saveBuffer(store.audioBufferDefault, inheriting: selectedProfiles) }
                        .keyboardShortcut(.defaultAction).disabled(selectedProfiles.isEmpty)
                }
            }.padding(24).frame(width: 480, height: 390)
                .disabled(savingBuffer).interactiveDismissDisabled(savingBuffer)
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
                        showingApply = false
                    }.keyboardShortcut(.defaultAction).disabled(selectedProfiles.isEmpty)
                }
            }.padding(24).frame(width: 480, height: 390)
        }
    }

    private var audioSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            ResponsiveStackLayout(minimumHorizontalWidth: 420, horizontalSpacing: 12, verticalSpacing: 6) {
                HStack(spacing: 6) {
                    Text("Audio Buffer")
                    DeviceCorrectionHelpIcon(title: "Audio Buffer", message: "New profiles and profiles using global defaults will use this buffer size.\n\nAutomatic learns from CamillaDSP and active plug-ins, then applies a suitable buffer after at least three seconds of complete silence, once queued audio and effect tails have cleared. It keeps the size fixed while audio is playing.\n\nTry 256 frames first, then 128 for less delay. Smaller buffers need more processing power; increase the size if audio crackles. Changing this briefly restarts audio.")
                }
                Picker("Audio Buffer", selection: Binding(
                    get: { store.audioBufferDefault }, set: { saveBuffer($0) })) {
                    ForEach(AudioBufferSetting.choices, id: \.self) { setting in
                        Text(setting.displayName).tag(setting)
                    }
                }.labelsHidden()
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Apply to Existing Profiles…") {
                selectedProfiles = []
                showingApplyBuffer = true
            }
            if savingBuffer { ProgressView("Applying audio buffer…").controlSize(.small) }
        }.disabled(savingBuffer)
    }

    private func saveBuffer(_ frames: AudioBufferSetting, inheriting ids: Set<UUID> = []) {
        guard !savingBuffer else { return }
        savingBuffer = true
        Task {
            defer { savingBuffer = false }
            do {
                try await state.saveGlobalAudioBuffer(frames, inheritingProfileIDs: ids)
                showingApplyBuffer = false
            } catch {
                showingApplyBuffer = false
                bufferFailure = error.localizedDescription
            }
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
            GroupBox {
                Toggle("Automatically check for updates", isOn: $updateChecker.automaticallyChecksForUpdates)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Confirmations").font(.headline)
            GroupBox {
                Toggle("Show profile enabled explanation", isOn: $store.showProfileEnabledExplanation)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                Toggle("Show window closing reminder", isOn: Binding(
                    get: { !hideCloseKeepsRunningHint },
                    set: { hideCloseKeepsRunningHint = !$0 }))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }
}

