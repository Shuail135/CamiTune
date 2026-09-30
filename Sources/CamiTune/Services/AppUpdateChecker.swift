import AppKit
import Foundation

struct AvailableAppUpdate: Equatable {
    let version: String
    let archiveURL: URL
}

struct AppUpdateNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class AppUpdateChecker: ObservableObject {
    @Published private(set) var availableUpdate: AvailableAppUpdate?
    @Published private(set) var isDownloadingUpdate = false
    @Published var notice: AppUpdateNotice?
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { defaults.set(automaticallyChecksForUpdates, forKey: Keys.automaticallyChecksForUpdates) }
    }

    var installedVersion: String { Self.currentVersion }

    private enum Keys {
        static let automaticallyChecksForUpdates = "appUpdate.automaticallyChecksForUpdates"
        static let skippedVersion = "appUpdate.skippedVersion"
        static let remindAfter = "appUpdate.remindAfter"
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft
            case prerelease
            case assets
        }
    }

    private struct PreparedUpdate {
        let appURL: URL
    }

    private enum UpdateError: LocalizedError {
        case appIsNotWritable
        case downloadFailed
        case archiveMissing
        case invalidBundle
        case invalidVersion
        case invalidSignature

        var errorDescription: String? {
            switch self {
            case .appIsNotWritable:
                return "CamiTune cannot replace the copy at its current location. Move it to a folder where your account can install applications, then try again."
            case .downloadFailed:
                return "The application archive could not be downloaded from GitHub."
            case .archiveMissing:
                return "The downloaded release does not contain CamiTune.app."
            case .invalidBundle:
                return "The downloaded application has an unexpected bundle identifier."
            case .invalidVersion:
                return "The downloaded application version does not match the GitHub release."
            case .invalidSignature:
                return "macOS could not validate the downloaded application bundle."
            }
        }
    }

    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/Shuail135/CamiTune/releases/latest"
    )!
    private static let reminderDelay: TimeInterval = 24 * 60 * 60
    private static let bundleIdentifier = "local.camilla.app"

    private let defaults: UserDefaults
    private let session: URLSession
    private var isChecking = false
    private var preparedUpdate: PreparedUpdate?

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        automaticallyChecksForUpdates = defaults.object(forKey: Keys.automaticallyChecksForUpdates) as? Bool ?? true
    }

    func start() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.checkOnLaunch()
        }
    }

    func checkOnLaunch() async {
        guard automaticallyChecksForUpdates else { return }
        await fetchLatestRelease()
    }

    func checkAfterReminderIfNeeded(now: Date = Date()) async {
        guard automaticallyChecksForUpdates else { return }
        guard let reminderDate = defaults.object(forKey: Keys.remindAfter) as? Date,
              now >= reminderDate else { return }
        await fetchLatestRelease()
    }

    func skipAvailableVersion() {
        guard let update = availableUpdate else { return }
        defaults.set(update.version, forKey: Keys.skippedVersion)
        defaults.removeObject(forKey: Keys.remindAfter)
        availableUpdate = nil
    }

    func remindLater() {
        defaults.set(
            Date().addingTimeInterval(Self.reminderDelay),
            forKey: Keys.remindAfter
        )
        availableUpdate = nil
    }

    func beginUpdate() {
        guard let update = availableUpdate, !isDownloadingUpdate else { return }
        availableUpdate = nil
        isDownloadingUpdate = true

        Task { [weak self] in
            guard let self else { return }
            await self.downloadAndPrepare(update)
        }
    }

    func installPreparedUpdateAfterExit() {
        guard let preparedUpdate else { return }
        let currentAppURL = Bundle.main.bundleURL.standardizedFileURL
        guard currentAppURL.pathExtension == "app",
              ["CamiTune.app", "CamillaApp.app"].contains(currentAppURL.lastPathComponent),
              currentAppURL.path != "/" else { return }

        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/zsh")
        installer.arguments = [
            "-c",
            Self.installerScript,
            "camilla-updater",
            String(ProcessInfo.processInfo.processIdentifier),
            currentAppURL.path,
            preparedUpdate.appURL.path
        ]
        installer.standardOutput = FileHandle.nullDevice
        installer.standardError = FileHandle.nullDevice
        try? installer.run()
        self.preparedUpdate = nil
    }

    private func fetchLatestRelease() async {
        guard !isChecking, availableUpdate == nil, !isDownloadingUpdate else { return }
        isChecking = true
        defer { isChecking = false }

        var request = URLRequest(url: Self.latestReleaseURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(
            "CamiTune/\(Self.currentVersion)",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else { return }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            defaults.removeObject(forKey: Keys.remindAfter)
            let expectedArchiveName = Self.archiveName(for: release.tagName)

            guard !release.draft,
                  !release.prerelease,
                  Self.isVersion(release.tagName, newerThan: Self.currentVersion),
                  defaults.string(forKey: Keys.skippedVersion) != release.tagName,
                  let archive = release.assets.first(where: { $0.name == expectedArchiveName }) else {
                return
            }

            availableUpdate = AvailableAppUpdate(
                version: release.tagName,
                archiveURL: archive.browserDownloadURL
            )
        } catch {
            // Update checks must never interrupt audio use. Another launch, or
            // a return from the menu bar after a reminder expires, can retry.
        }
    }

    private func downloadAndPrepare(_ update: AvailableAppUpdate) async {
        do {
            let currentAppURL = Bundle.main.bundleURL.standardizedFileURL
            guard FileManager.default.isWritableFile(
                atPath: currentAppURL.deletingLastPathComponent().path
            ) else {
                throw UpdateError.appIsNotWritable
            }

            var request = URLRequest(url: update.archiveURL)
            request.timeoutInterval = 120
            request.setValue(
                "CamiTune/\(Self.currentVersion)",
                forHTTPHeaderField: "User-Agent"
            )
            let (temporaryArchive, response) = try await session.download(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw UpdateError.downloadFailed
            }

            let prepared = try await Task.detached {
                try Self.prepareArchive(
                    temporaryArchive,
                    expectedVersion: update.version
                )
            }.value
            preparedUpdate = PreparedUpdate(
                appURL: prepared
            )
            defaults.removeObject(forKey: Keys.remindAfter)
            isDownloadingUpdate = false
            NSApp.terminate(nil)
            return
        } catch {
            availableUpdate = update
            notice = AppUpdateNotice(
                title: "Update Failed",
                message: error.localizedDescription
            )
        }
        isDownloadingUpdate = false
    }

    nonisolated private static func prepareArchive(
        _ temporaryArchive: URL,
        expectedVersion: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let updateRoot = CamiTunePaths.supportDirectory
            .appendingPathComponent("PreparedUpdate", isDirectory: true)
        let archiveURL = updateRoot.appendingPathComponent("update.zip")
        let unpackedURL = updateRoot.appendingPathComponent("Unpacked", isDirectory: true)
        let appURL = unpackedURL.appendingPathComponent("CamiTune.app", isDirectory: true)

        if fileManager.fileExists(atPath: updateRoot.path) {
            try fileManager.removeItem(at: updateRoot)
        }
        try fileManager.createDirectory(at: updateRoot, withIntermediateDirectories: true)
        try fileManager.moveItem(at: temporaryArchive, to: archiveURL)
        try fileManager.createDirectory(at: unpackedURL, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archiveURL.path, unpackedURL.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0,
              fileManager.fileExists(atPath: appURL.path) else {
            throw UpdateError.archiveMissing
        }

        guard let bundle = Bundle(url: appURL),
              bundle.bundleIdentifier == bundleIdentifier else {
            throw UpdateError.invalidBundle
        }
        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        guard version.map({ versionsAreEqual($0, expectedVersion) }) == true else {
            throw UpdateError.invalidVersion
        }

        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", appURL.path]
        verify.standardOutput = FileHandle.nullDevice
        verify.standardError = FileHandle.nullDevice
        try verify.run()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else {
            throw UpdateError.invalidSignature
        }

        try? fileManager.removeItem(at: archiveURL)
        return appURL
    }

    nonisolated static let installerScript = #"""
attempts=0
while /bin/kill -0 "$1" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -ge 120 ]]; then exit 1; fi
    /bin/sleep 1
done
target="$2"
staged="$3"
backup="${target}.previous-update.$1"
if [[ -e "$backup" ]]; then exit 1; fi
if ! /bin/mv "$target" "$backup"; then
    exit 1
fi
if /bin/mv "$staged" "$target"; then
    /bin/rm -rf "$backup"
    exit 0
else
    # The original app is known to be in backup before target can be
    # removed. If installation fails, restore it and retain the backup if
    # restoration itself cannot complete.
    if [[ -e "$target" ]]; then /bin/rm -rf "$target"; fi
    /bin/mv "$backup" "$target"
    exit 1
fi
"""#

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    nonisolated static func archiveName(for version: String) -> String {
        "CamiTune-\(normalizedTag(version))-app.zip"
    }

    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let candidateParts = numericVersionParts(candidate)
        let currentParts = numericVersionParts(current)
        guard !candidateParts.isEmpty, !currentParts.isEmpty else { return false }

        let componentCount = max(candidateParts.count, currentParts.count)
        for index in 0..<componentCount {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }
        return false
    }

    nonisolated private static func versionsAreEqual(_ lhs: String, _ rhs: String) -> Bool {
        numericVersionParts(lhs) == numericVersionParts(rhs)
    }

    nonisolated private static func normalizedTag(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? trimmed : "v\(trimmed)"
    }

    nonisolated private static func numericVersionParts(_ version: String) -> [Int] {
        var normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.first == "v" || normalized.first == "V" {
            normalized.removeFirst()
        }
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return []
        }
        let values = components.compactMap { Int($0) }
        return values.count == components.count ? values : []
    }
}
