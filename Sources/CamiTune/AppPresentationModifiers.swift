import SwiftUI

@MainActor
struct AppErrorPresentationModifier: ViewModifier {
    @ObservedObject var state: AppState

    func body(content: Content) -> some View {
        content.alert("CamiTune", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { state.errorMessage = nil }
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
            .overlay {
                if updateChecker.isDownloadingUpdate {
                    ZStack {
                        Color.black.opacity(0.18)
                            .ignoresSafeArea()
                        VStack(spacing: 14) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Downloading Update…")
                                .font(.headline)
                            Text("CamiTune will validate the download, then close. Reopen it to use the update.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(28)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .shadow(radius: 18)
                    }
                }
            }
    }
}
