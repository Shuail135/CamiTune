import SwiftUI

/// Shared by the in-app sheet and the installer that survives the restart.
/// Uses the same header, separators, padding and native buttons as Add Output.
struct AppUpdatePanel<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: appIcon)
                    .resizable().scaledToFit().frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(24)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            Divider()
            HStack(spacing: 12) {
                actions
            }
            .controlSize(.regular)
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var appIcon: NSImage {
#if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) { return image }
#endif
        if let url = Bundle.main.url(forResource: "icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) { return image }
        return NSApp.applicationIconImage
    }
}

@MainActor
struct AppUpdateProgressView: View {
    @ObservedObject var checker: AppUpdateChecker

    private var title: String {
        switch checker.phase {
        case .idle: return "Update available"
        case .downloading: return "Downloading update"
        case .verifying: return "Verifying update"
        case .ready: return "Ready to install"
        case .restarting: return "Restarting CamiTune"
        case .failed: return "Update could not finish"
        case .completed: return "What’s new"
        }
    }

    private var subtitle: String {
        if checker.phase == .completed { return "CamiTune \(checker.installedVersion)" }
        if let version = checker.availableUpdate?.version ?? checker.updateVersion {
            return "CamiTune \(checker.installedVersion) → \(version)"
        }
        return "CamiTune \(checker.installedVersion)"
    }

    var body: some View {
        AppUpdatePanel(title: title, subtitle: subtitle) {
            switch checker.phase {
            case .idle:
                explanation("A new version of CamiTune is available. Download it now, then choose when to install and restart.")
            case .downloading:
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        ProgressView(value: checker.downloadProgress).progressViewStyle(.linear)
                            .accessibilityLabel("Download progress")
                        Text(downloadDescription).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
                explanation("CamiTune will stay open. You’ll choose when to restart once the update is ready.")
            case .verifying:
                status("Checking the downloaded application…", working: true)
                explanation("CamiTune will stay open. You’ll choose when to restart once the update is ready.")
            case .ready:
                status("Download verified. Ready to install.", working: false)
                explanation("Installing will briefly close CamiTune and pause audio. The update window will stay open until CamiTune reopens automatically.")
            case .restarting:
                status("Starting the update installer…", working: true)
                explanation("CamiTune will close briefly and reopen automatically. The update window will show you when it’s finished.")
            case .failed:
                explanation(checker.failureMessage)
            case .completed:
                status("CamiTune is up to date.", working: false)
                AppChangelogView()
            }
        } actions: {
            switch checker.phase {
            case .idle:
                Button("Skip Version") { checker.skipAvailableVersion() }
                Spacer()
                Button("Later", role: .cancel) { checker.remindLater() }
                Button("Download Update") { checker.beginUpdate() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .downloading:
                Button("Cancel Download", role: .cancel) { checker.dismissUpdate() }
                Spacer()
            case .ready:
                Button("Cancel Update", role: .cancel) { checker.dismissUpdate() }
                Spacer()
                Button("Install & Restart") { checker.installAndRestart() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .failed:
                Button("Close", role: .cancel) { checker.dismissUpdate() }
                Spacer()
                if checker.canRetry {
                    Button("Try Again") { checker.retryUpdate() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            case .completed:
                Spacer()
                Button("Done") { checker.dismissUpdate() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            default:
                Text("Please wait…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var downloadDescription: String {
        guard checker.downloadedBytes > 0 else { return "Connecting…" }
        let received = ByteCountFormatter.string(fromByteCount: checker.downloadedBytes, countStyle: .file)
        guard checker.expectedBytes > 0, let progress = checker.downloadProgress else { return "\(received) downloaded" }
        let total = ByteCountFormatter.string(fromByteCount: checker.expectedBytes, countStyle: .file)
        return "\(received) of \(total) · \(Int(progress * 100))%"
    }

    private func status(_ message: String, working: Bool) -> some View {
        GroupBox {
            HStack(spacing: 10) {
                if working { ProgressView().controlSize(.small) }
                else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                Text(message).font(.callout.weight(.medium))
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func explanation(_ message: String) -> some View {
        Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
enum AppChangelogWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let content = AppUpdatePanel(title: "Changelog", subtitle: version.map { "CamiTune \($0)" } ?? "CamiTune") {
                AppChangelogView()
            } actions: {
                Spacer()
                Button("Done") { window?.close() }
                    .keyboardShortcut(.defaultAction)
            }
            let created = NSWindow(contentViewController: NSHostingController(rootView: content))
            created.title = "CamiTune Changelog"
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Release notes are authored by the user and shipped with this exact app version.
/// Loading once avoids file reads during presentation updates and works offline.
private struct AppChangelogView: View {
    private static let notes: NSAttributedString = {
#if SWIFT_PACKAGE
        let bundle = Bundle.module
#else
        let bundle = Bundle.main
#endif
        let text = bundle.url(forResource: "CHANGELOG", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ChangelogMarkdown.render(text.isEmpty ? "No release notes were provided for this version." : text)
    }()

    var body: some View {
        ChangelogTextView(content: Self.notes)
            .frame(height: 280)
    }
}

