import SwiftUI

@MainActor
struct AppErrorPresentationModifier: ViewModifier {
    @ObservedObject var state: AppState

    func body(content: Content) -> some View {
        content.alert("CamiTune", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            if state.errorRecovery == .openSetup {
                Button("Open Setup") {
                    state.errorMessage = nil
                    // Present after the alert's dismissal has been processed.
                    DispatchQueue.main.async { state.setupPresentation.isPresented = true }
                }
                .keyboardShortcut(.defaultAction)
            }
            Button("Close", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

@MainActor
struct AppUpdatePresentationModifier: ViewModifier {
    @ObservedObject var updateChecker: AppUpdateChecker

    func body(content: Content) -> some View {
        content
            .alert("Update Available", isPresented: Binding(
                get: { updateChecker.availableUpdate != nil },
                set: { isPresented in
                    if !isPresented, updateChecker.availableUpdate != nil {
                        updateChecker.remindLater()
                    }
                }
            )) {
                Button("Skip This Version") {
                    updateChecker.skipAvailableVersion()
                }
                Button("Remind Me Later", role: .cancel) {
                    updateChecker.remindLater()
                }
                Button("Update") {
                    updateChecker.beginUpdate()
                }
                .keyboardShortcut(.defaultAction)
            } message: {
                if let update = updateChecker.availableUpdate {
                    Text("CamiTune \(update.version) is available. You are currently using version \(updateChecker.installedVersion).")
                }
            }
            .alert(item: $updateChecker.notice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .sheet(isPresented: Binding(get: { updateChecker.isDownloadingUpdate }, set: { _ in })) {
                VStack(alignment: .leading, spacing: 14) {
                    ProgressView("Downloading Update…")
                    Text("CamiTune will validate the download, then close. Reopen it to use the update.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(24).frame(width: 420)
                .interactiveDismissDisabled(true)
            }
    }
}


enum AppErrorRecovery: Equatable { case openSetup }

/// Presentation ownership is independent of high-rate runtime publications.
@MainActor
final class SetupPresentationState: ObservableObject {
    @Published var isPresented = false
    @Published var componentNotice: String?
    private var checkedInitialPresentation = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func begin(hasExistingProfiles: Bool) -> Bool {
        guard !checkedInitialPresentation else { return false }
        checkedInitialPresentation = true
        let hasSeenSetup = defaults.bool(forKey: "hasPresentedInitialSetup")
        defaults.set(true, forKey: "hasPresentedInitialSetup")
        if !hasSeenSetup && !hasExistingProfiles {
            isPresented = true
            return false
        }
        return true
    }

    func checkComponents(camilla: DependencyManager.Status, driver: DependencyManager.Status) {
        guard !isPresented else { return }
        func requiresSetup(_ status: DependencyManager.Status) -> Bool {
            switch status {
            case .missing, .failed: return true
            default: return false
            }
        }
        if requiresSetup(camilla) || requiresSetup(driver) {
            componentNotice = "An audio driver or managed component is missing or needs repair. Open Setup to check and update CamiTune’s components."
        }
    }
}

@MainActor
struct SetupPresentationModifier: ViewModifier {
    let state: AppState
    @ObservedObject var presentation: SetupPresentationState

    func body(content: Content) -> some View {
        content
            .task {
                guard presentation.begin(hasExistingProfiles: !state.profiles.profiles.isEmpty) else { return }
                await state.dependencies.refreshWithoutBlockingUI()
                presentation.checkComponents(camilla: state.dependencies.camillaDSPStatus,
                    driver: state.dependencies.audioDriverStatus)
            }
            .sheet(isPresented: $presentation.isPresented) {
                SetupPanel(state: state)
            }
            .alert("Audio Components Need Attention", isPresented: Binding(
                get: { presentation.componentNotice != nil },
                set: { if !$0 { presentation.componentNotice = nil } }
            )) {
                Button("Open Setup") {
                    presentation.componentNotice = nil
                    DispatchQueue.main.async { presentation.isPresented = true }
                }
                .keyboardShortcut(.defaultAction)
                Button("Later", role: .cancel) { presentation.componentNotice = nil }
            } message: {
                Text(presentation.componentNotice ?? "")
            }
    }
}

@MainActor
struct SetupPanel: View {
    let state: AppState
    @ObservedObject private var dependencies: DependencyManager
    @Environment(\.dismiss) private var dismiss

    init(state: AppState) {
        self.state = state
        _dependencies = ObservedObject(wrappedValue: state.dependencies)
    }

    var body: some View {
        VStack(spacing: 0) {
            SetupView(state: state)
            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(dependencies.setupInProgress)
            }
            .padding(16)
        }
        .frame(width: 700, height: 600)
        .interactiveDismissDisabled(dependencies.setupInProgress)
    }
}

@MainActor
final class ProfileConfirmationState: ObservableObject {
    @Published var showEnabledExplanation = false
}

@MainActor
struct ProfileConfirmationModifier: ViewModifier {
    @ObservedObject var presentation: ProfileConfirmationState
    @ObservedObject var store: ProfileStore
    @State private var doNotShowAgain = true

    func body(content: Content) -> some View {
        content.sheet(isPresented: $presentation.showEnabledExplanation, onDismiss: {
            store.showProfileEnabledExplanation = !doNotShowAgain
        }) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Profile Enabled").font(.title2.bold())
                Text("Enabling Profile only selects which profile CamiTune will use. Check the profile status to see whether it is Active or Inactive.")
                Toggle("Do not show this again", isOn: $doNotShowAgain)
                HStack {
                    Spacer()
                    Button("OK") { presentation.showEnabledExplanation = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24).frame(width: 440)
            .onAppear { doNotShowAgain = true }
        }
    }
}
