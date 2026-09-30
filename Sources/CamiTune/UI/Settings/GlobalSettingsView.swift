import CamiTuneDomain
import SwiftUI
import AppKit
import Foundation

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
    @State private var selectedProfiles: Set<UUID> = []
    @AppStorage("hideCloseKeepsRunningHint") private var hideCloseKeepsRunningHint = false
    private let categories = ["General", "Section Layout", "Drivers & Components", "Diagnostics", "Confirmations"]

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
                    Toggle("Start CamiTune at login", isOn: Binding(
                        get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                        .disabled(loginItem.isUpdating)
                    Text(loginItem.statusMessage).font(.callout).foregroundStyle(.secondary)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Automatically check for updates", isOn: $updateChecker.automaticallyChecksForUpdates)
                            Text("Check for new CamiTune versions when the app starts and when update reminders are due.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
                case "Drivers & Components":
                    SetupView(state: state, embedded: true)
                case "Diagnostics":
                    DiagnosticsView(state: state)
                case "Confirmations":
                    Text("Choose which pop-ups to show. Turn an option back on here after selecting “Do not show this again.”")
                        .foregroundStyle(.secondary)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Show profile enabled explanation", isOn: $store.showProfileEnabledExplanation)
                            Text("Show an explanation when you manually enable a profile.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Show window closing reminder", isOn: Binding(
                                get: { !hideCloseKeepsRunningHint },
                                set: { hideCloseKeepsRunningHint = !$0 }))
                            Text("Remind you that CamiTune keeps running when you close its window.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                        showingApply = false
                    }.keyboardShortcut(.defaultAction).disabled(selectedProfiles.isEmpty)
                }
            }.padding(24).frame(width: 480, height: 390)
        }
    }
}

