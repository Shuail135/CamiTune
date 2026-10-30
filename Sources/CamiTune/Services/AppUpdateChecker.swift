import AppKit
import Foundation

struct AvailableAppUpdate: Equatable {
    let version: String
    let archiveURL: URL
    var presentation: AppUpdateCheckPresentation = .sheet
}

enum AppUpdateCheckPresentation: Equatable {
    case background, sheet, changelog
}

enum AppUpdateCheckResult: Equatable {
    case upToDate, updateAvailable, failed
}

enum AppUpdatePhase: Equatable {
    case checking(AppUpdateCheckPresentation), upToDate, checkFailed
    case idle, downloading, verifying, ready, restarting, failed, completed
}

@MainActor
final class AppUpdateChecker: ObservableObject {
    weak var history: UndoCoordinator?
    @Published private(set) var availableUpdate: AvailableAppUpdate?
    @Published private(set) var lastCheckResult: AppUpdateCheckResult?
    @Published private(set) var phase: AppUpdatePhase = .idle
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var expectedBytes: Int64 = 0
    @Published private(set) var updateVersion: String?
    @Published private(set) var failureMessage = ""
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            history?.record(actionName: "Change Automatic Updates", target: .preference(.automaticUpdates),
                before: .boolean(oldValue), after: .boolean(automaticallyChecksForUpdates))
            defaults.set(automaticallyChecksForUpdates, forKey: Keys.automaticallyChecksForUpdates)
            scheduleAutomaticCheck()
        }
    }

    var installedVersion: String { Self.currentVersion }
    // The installer owns progress during restart. Leaving our sheet attached
    // would both duplicate its window and prevent AppKit from terminating us.
    var isPresentingUpdate: Bool {
        switch phase {
        case .checking(.background), .checking(.changelog), .restarting: return false
        case .idle: return availableUpdate.map { $0.presentation != .changelog } ?? false
        default: return true
        }
    }
    var canRetry: Bool { currentUpdate != nil }

    var nextAutomaticCheckDate: Date? {
        guard automaticallyChecksForUpdates else { return nil }
        if let reminder = defaults.object(forKey: Keys.remindAfter) as? Date { return reminder }
        return (defaults.object(forKey: Keys.lastCheck) as? Date)?
            .addingTimeInterval(Self.checkInterval) ?? now()
    }

    private enum Keys {
        static let automaticallyChecksForUpdates = "appUpdate.automaticallyChecksForUpdates"
        static let skippedVersion = "appUpdate.skippedVersion"
        static let remindAfter = "appUpdate.remindAfter"
        static let lastCheck = "appUpdate.lastCheck"
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
        let directory: URL
    }

    private enum UpdateError: LocalizedError {
        case appIsNotWritable
        case unsupportedLocation
        case downloadFailed
        case archiveMissing
        case invalidBundle
        case invalidVersion
        case invalidSignature
        case releaseUnavailable

        var errorDescription: String? {
            switch self {
            case .appIsNotWritable:
                return "CamiTune cannot replace the copy at its current location. Move it to a folder where your account can install applications, then try again."
            case .unsupportedLocation:
                return "Open the installed CamiTune.app to update it. This copy is not running from an application bundle."
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
            case .releaseUnavailable:
                return "The latest release does not contain a compatible CamiTune update."
            }
        }
    }

    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/Shuail135/CamiTune/releases/latest"
    )!
    private static let reminderDelay: TimeInterval = 24 * 60 * 60
    private static let checkInterval: TimeInterval = 3 * 24 * 60 * 60
    private static let bundleIdentifier = "local.camilla.app"

    private let defaults: UserDefaults
    private let session: URLSession
    private let now: () -> Date
    private var hasStarted = false
    private var checkTask: Task<Void, Never>?
    private var automaticCheckTimer: Timer?
    private var preparedUpdate: PreparedUpdate?
    private var currentUpdate: AvailableAppUpdate?
    private var updateTask: Task<Void, Never>?
    private var downloadID: UUID?
    private var installationStarted = false

    init(defaults: UserDefaults = .standard, session: URLSession = .shared,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.session = session
        self.now = now
        automaticallyChecksForUpdates = defaults.object(forKey: Keys.automaticallyChecksForUpdates) as? Bool ?? true
    }

    deinit {
        checkTask?.cancel()
        automaticCheckTimer?.invalidate()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        if let result = AppUpdateInstaller.consumeResult(for: Bundle.main.bundleURL) {
            updateVersion = result.version
            if result.succeeded, Self.versionsAreEqual(result.version, Self.currentVersion) {
                lastCheckResult = .upToDate
                phase = .completed
            } else {
                failureMessage = result.succeeded
                    ? "The update did not finish. You are still using CamiTune \(Self.currentVersion). Please try the update again."
                    : result.message
                phase = .failed
            }
            return
        }
        scheduleAutomaticCheck(minimumDelay: 2)
    }

    func stop() {
        hasStarted = false
        checkTask?.cancel()
        checkTask = nil
        automaticCheckTimer?.invalidate()
        automaticCheckTimer = nil
        if case .checking = phase { phase = .idle }
    }

    private func scheduleAutomaticCheck(minimumDelay: TimeInterval = 0) {
        automaticCheckTimer?.invalidate()
        automaticCheckTimer = nil
        guard hasStarted, phase == .idle, availableUpdate == nil,
              let date = nextAutomaticCheckDate else { return }
        let fireDate = max(date, now().addingTimeInterval(minimumDelay))
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.hasStarted else { return }
                await self.checkAutomaticallyIfNeeded()
            }
        }
        // A single wall-clock deadline also catches up after sleep, with no polling.
        timer.tolerance = min(5 * 60, max(0, fireDate.timeIntervalSince(now()) * 0.1))
        automaticCheckTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func checkAutomaticallyIfNeeded() async {
        guard phase == .idle, availableUpdate == nil,
              let date = nextAutomaticCheckDate, date <= now() else { return }
        await checkRelease(presentation: .background)
    }

    func checkForUpdates(presentation: AppUpdateCheckPresentation = .sheet) async {
        if var update = availableUpdate {
            update.presentation = presentation
            availableUpdate = update
        } else if case .checking(let currentPresentation) = phase {
            // Share the request, giving an explicitly requested sheet priority.
            if presentation == .sheet || currentPresentation == .background {
                phase = .checking(presentation)
            }
            await checkTask?.value
        } else if phase == .idle {
            await checkRelease(presentation: presentation)
        } else {
            await checkTask?.value
        }
    }

    private func checkRelease(presentation: AppUpdateCheckPresentation) async {
        automaticCheckTimer?.invalidate()
        automaticCheckTimer = nil
        updateVersion = nil
        failureMessage = ""
        phase = .checking(presentation)
        // Record attempts so offline failures cannot cause a tight retry loop.
        defaults.set(now(), forKey: Keys.lastCheck)
        defaults.removeObject(forKey: Keys.remindAfter)
        let task = Task<Void, Never> { [weak self] in await self?.fetchLatestRelease() }
        checkTask = task
        await task.value
    }

    func skipAvailableVersion() {
        guard let update = availableUpdate else { return }
        defaults.set(update.version, forKey: Keys.skippedVersion)
        defaults.removeObject(forKey: Keys.remindAfter)
        availableUpdate = nil
        scheduleAutomaticCheck()
    }

    func remindLater() {
        defaults.set(
            now().addingTimeInterval(Self.reminderDelay),
            forKey: Keys.remindAfter
        )
        availableUpdate = nil
        scheduleAutomaticCheck()
    }

    func beginUpdate() {
        guard let update = availableUpdate, phase == .idle else { return }
        currentUpdate = update
        updateVersion = update.version
        availableUpdate = nil
        download(update)
    }

    private func download(_ update: AvailableAppUpdate) {
        let id = UUID()
        downloadID = id
        downloadProgress = nil
        downloadedBytes = 0
        expectedBytes = 0
        phase = .downloading
        updateTask = Task { [weak self] in
            guard let self else { return }
            await self.downloadAndPrepare(update, id: id)
        }
    }

    func dismissUpdate() {
        if phase == .upToDate || phase == .checkFailed {
            phase = .idle
            scheduleAutomaticCheck()
            return
        }
        guard [.downloading, .ready, .failed, .completed].contains(phase) else { return }
        updateTask?.cancel()
        updateTask = nil
        downloadID = nil
        if let preparedUpdate { try? FileManager.default.removeItem(at: preparedUpdate.directory) }
        preparedUpdate = nil
        currentUpdate = nil
        phase = .idle
        remindLater()
    }

    func retryUpdate() {
        guard phase == .failed, let currentUpdate else { return }
        if preparedUpdate != nil { installAndRestart() }
        else { download(currentUpdate) }
    }

    func installAndRestart() {
        guard [.ready, .failed].contains(phase), preparedUpdate != nil, updateVersion != nil else { return }
        phase = .restarting
    }

    /// Start only after SwiftUI has finished dismissing the update sheet.
    /// Scheduling Quit on the next run-loop turn is not enough: the sheet's
    /// dismissal animation can still be in progress and veto termination.
    func updatePresentationDidDismiss() {
        guard phase == .restarting, !installationStarted,
              let preparedUpdate, let updateVersion else { return }
        installationStarted = true
        updateTask = Task { [weak self] in
            guard let self else { return }
            defer { self.installationStarted = false }
            do {
                // The helper must be visible and ready before this process quits.
                // A normal Quit never installs a merely downloaded update.
                try await AppUpdateInstaller.handoff(appURL: preparedUpdate.appURL,
                    directory: preparedUpdate.directory, version: updateVersion)
            } catch {
                self.failureMessage = error.localizedDescription
                self.phase = .failed
            }
        }
    }

    private func fetchLatestRelease() async {
        defer {
            if !Task.isCancelled {
                checkTask = nil
                scheduleAutomaticCheck()
            }
        }

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
            guard !Task.isCancelled else { return }
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard case .checking(let presentation) = phase else { return }
            let automatic = presentation == .background
            let expectedArchiveName = Self.archiveName(for: release.tagName)

            guard !release.draft, !release.prerelease,
                  !Self.numericVersionParts(release.tagName).isEmpty else {
                throw UpdateError.releaseUnavailable
            }
            guard Self.isVersion(release.tagName, newerThan: Self.currentVersion) else {
                lastCheckResult = .upToDate
                phase = presentation == .sheet ? .upToDate : .idle
                return
            }
            guard let archive = release.assets.first(where: { $0.name == expectedArchiveName }) else {
                throw UpdateError.releaseUnavailable
            }
            lastCheckResult = .updateAvailable
            guard !automatic || defaults.string(forKey: Keys.skippedVersion) != release.tagName else {
                phase = .idle
                return
            }

            if !automatic || automaticallyChecksForUpdates {
                availableUpdate = AvailableAppUpdate(
                    version: release.tagName,
                    archiveURL: archive.browserDownloadURL,
                    presentation: presentation
                )
            }
            phase = .idle
        } catch {
            guard !Task.isCancelled else { return }
            lastCheckResult = .failed
            if phase == .checking(.sheet) {
                failureMessage = "CamiTune could not check for updates. \(error.localizedDescription)"
                phase = .checkFailed
            } else {
                // Background failures stay quiet until the next scheduled or manual check.
                phase = .idle
            }
        }
    }

    private func downloadAndPrepare(_ update: AvailableAppUpdate, id: UUID) async {
        do {
            let currentAppURL = Bundle.main.bundleURL.standardizedFileURL
            guard currentAppURL.pathExtension == "app", Bundle.main.bundleIdentifier == Self.bundleIdentifier else {
                throw UpdateError.unsupportedLocation
            }
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
            let progress = AppUpdateDownloadProgress { [weak self] written, expected in
                Task { @MainActor in
                    guard let self, self.phase == .downloading, self.downloadID == id else { return }
                    self.downloadedBytes = written
                    self.expectedBytes = expected
                    self.downloadProgress = expected > 0 ? min(1, Double(written) / Double(expected)) : nil
                }
            }
            let (temporaryArchive, response) = try await session.download(for: request, delegate: progress)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw UpdateError.downloadFailed
            }

            phase = .verifying
            let directory = CamiTunePaths.supportDirectory
                .appendingPathComponent("PreparedUpdates/\(UUID().uuidString)", isDirectory: true)
            let prepared = try await Task.detached {
                try Self.prepareArchive(
                    temporaryArchive,
                    expectedVersion: update.version,
                    updateRoot: directory
                )
            }.value
            preparedUpdate = PreparedUpdate(
                appURL: prepared, directory: directory
            )
            defaults.removeObject(forKey: Keys.remindAfter)
            phase = .ready
        } catch {
            guard !Task.isCancelled else { return }
            failureMessage = error.localizedDescription
            phase = .failed
        }
    }

    nonisolated private static func prepareArchive(
        _ temporaryArchive: URL,
        expectedVersion: String,
        updateRoot: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        let archiveURL = updateRoot.appendingPathComponent("update.zip")
        let unpackedURL = updateRoot.appendingPathComponent("Unpacked", isDirectory: true)
        let appURL = unpackedURL.appendingPathComponent("CamiTune.app", isDirectory: true)

        var succeeded = false
        defer { if !succeeded { try? fileManager.removeItem(at: updateRoot) } }
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
        succeeded = true
        return appURL
    }

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

private final class AppUpdateDownloadProgress: NSObject, URLSessionDownloadDelegate {
    private let progress: (Int64, Int64) -> Void
    init(progress: @escaping (Int64, Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
