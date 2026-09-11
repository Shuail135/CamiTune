import SwiftUI

@MainActor
struct SetupView: View {
    let state: AppState
    @ObservedObject private var dependencies: DependencyManager
    @ObservedObject private var loginItem: LoginItemManager

    init(state: AppState) {
        self.state = state
        self._dependencies = ObservedObject(wrappedValue: state.dependencies)
        self._loginItem = ObservedObject(wrappedValue: state.loginItem)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Setup").font(.largeTitle.bold())

                dependencyCard(
                    title: "CamillaDSP",
                    status: dependencies.camillaDSPStatus,
                    detail: "UID-capable build bundled with CamiTune; installed under ~/Library/Application Support/CamiTune/bin.",
                    action: {
                        Task {
                            guard await state.prepareForDependencyRepair() else { return }
                            await dependencies.installCamillaDSP()
                        }
                    }
                )

                dependencyCard(
                    title: "System Audio Bridge Driver",
                    status: dependencies.audioDriverStatus,
                    detail: "Installed under ~/Library/Application Support/CamiTune/Drivers; installation asks once for macOS administrator approval.",
                    action: {
                        Task {
                            guard await state.prepareForDependencyRepair() else { return }
                            await dependencies.installAudioDriver()
                        }
                    }
                )

                HStack {
                    Button("Install / Repair Everything") {
                        Task {
                            guard await state.prepareForDependencyRepair() else { return }
                            await dependencies.installEverything()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(dependencies.setupInProgress)
                    Button("Recheck") {
                        Task { await dependencies.recheck() }
                    }
                    .disabled(dependencies.setupInProgress)
                }

                if !dependencies.setupMessage.isEmpty {
                    HStack(spacing: 10) {
                        if dependencies.setupInProgress {
                            ProgressView().controlSize(.small)
                        } else if dependencies.setupFailed {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        } else {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        Text(dependencies.setupMessage)
                            .font(.callout.weight(.medium))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Toggle("Start CamiTune when I log in", isOn: Binding(
                                get: { loginItem.isEnabled },
                                set: { loginItem.setEnabled($0) }
                            ))
                            .disabled(loginItem.isUpdating)

                            if loginItem.isUpdating {
                                ProgressView().controlSize(.small)
                            }
                        }

                        Text(loginItem.statusMessage)
                            .font(.caption)
                            .foregroundStyle(loginItem.requiresApproval ? .orange : .secondary)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { loginItem.refresh() }

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("First use").font(.title2.bold())
                    Text("1. Select Install / Repair Everything, then approve the macOS administrator prompt.\n2. Restart the Mac only if Setup says the new audio device is not visible yet.\n3. Add your physical output as a profile from the sidebar.\n4. Open Settings → Profiles & Activation to choose which profile starts with each physical output.\n5. Adjust the visual equalizer, or import Equalizer APO text from a file or the clipboard.")
                }
            }
            .padding(32)
            .frame(maxWidth: 780, alignment: .leading)
        }
    }

    @ViewBuilder
    private func dependencyCard(title: String, status: DependencyManager.Status, detail: String, action: @escaping () -> Void) -> some View {
        GroupBox {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        statusIcon(status)
                        Text(title).font(.title3.bold())
                    }
                    Text(statusText(status)).font(.callout)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !isInstalled(status) {
                    Button("Install", action: action).disabled(isWorking(status))
                }
            }.padding(6)
        }
    }

    private func statusText(_ status: DependencyManager.Status) -> String {
        switch status {
        case .checking: return "Checking…"
        case .missing: return "Not installed"
        case .installed(let version): return version ?? "Installed"
        case .working(let message): return message
        case .failed(let message): return message
        }
    }

    private func isInstalled(_ status: DependencyManager.Status) -> Bool {
        if case .installed = status { return true }; return false
    }
    private func isWorking(_ status: DependencyManager.Status) -> Bool {
        if case .working = status { return true }; return false
    }
    @ViewBuilder private func statusIcon(_ status: DependencyManager.Status) -> some View {
        if isInstalled(status) { Image(systemName: "checkmark.circle.fill") }
        else if case .failed = status { Image(systemName: "exclamationmark.triangle.fill") }
        else if isWorking(status) { ProgressView().controlSize(.small) }
        else { Image(systemName: "circle") }
    }
}
