import Foundation
import CryptoKit

@MainActor
final class DependencyManager: ObservableObject {
    enum Status: Equatable, Sendable {
        case checking
        case missing
        case installed(String?)
        case working(String)
        case failed(String)
    }

    @Published var camillaDSPStatus: Status = .checking
    @Published var audioDriverStatus: Status = .checking
    @Published var setupMessage: String = ""
    @Published var setupInProgress = false
    @Published var setupFailed = false

    private let coreAudio: CoreAudioService
    private let bundledDriverURL: URL?
    private let installedDriverURL: URL
    private let supportRoot: URL
    private var statusRevision: UInt64 = 0
    private static let requiredCamillaCapability = "coreaudio-uid-playback-clock-v1"

    init(coreAudio: CoreAudioService,
         bundledDriverURL: URL? = Bundle.main.url(forResource: "CamillaAudio", withExtension: "driver", subdirectory: "Drivers"),
         installedDriverURL: URL = AudioDriverInstallation.installedURL,
         supportDirectory: URL? = nil) {
        self.coreAudio = coreAudio
        self.bundledDriverURL = bundledDriverURL
        self.installedDriverURL = installedDriverURL
        supportRoot = supportDirectory ?? CamiTunePaths.supportDirectory
    }

    var supportDirectory: URL {
        supportRoot
    }

    var camillaDSPBinary: URL { supportDirectory.appendingPathComponent("bin/camilladsp") }
    private var camillaDSPCapabilityMarker: URL {
        supportDirectory.appendingPathComponent("bin/camilladsp.capabilities")
    }
    private var managedDriverURL: URL {
        supportDirectory
            .appendingPathComponent("Drivers", isDirectory: true)
            .appendingPathComponent("CamillaAudio.driver", isDirectory: true)
    }

    private func createSupportLayout() throws {
        try Self.createSupportLayout(at: supportDirectory)
    }

    nonisolated private static func createSupportLayout(at base: URL) throws {
        for directory in ["bin", "configs", "coeffs", "logs"] {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    func refresh() {
        guard !setupInProgress else { return }
        statusRevision &+= 1
        try? createSupportLayout()
        refreshCamillaDSPStatus()
        let bridgePresent = coreAudio.systemAudioBridge != nil
        applyAudioDriverStatus(
            supported: coreAudio.isSystemAudioBridgePresentationSupported,
            bridgePresent: bridgePresent,
            installation: AudioDriverInstallation.inspect(bundled: bundledDriverURL, installed: installedDriverURL)
        )
        finishRefreshMessage()
    }

    func refreshWithoutBlockingUI() async {
        guard !setupInProgress else { return }
        await refreshStatuses()
    }

    private func refreshStatuses() async {
        statusRevision &+= 1
        let revision = statusRevision
        let base = supportDirectory
        let binary = camillaDSPBinary
        let capabilityMarker = camillaDSPCapabilityMarker
        let camillaStatus = await Task.detached(priority: .utility) {
            try? Self.createSupportLayout(at: base)
            return Self.camillaDSPStatus(
                binary: binary,
                capabilityMarker: capabilityMarker
            )
        }.value
        let bundled = bundledDriverURL, installed = installedDriverURL
        let installation = await Task.detached(priority: .utility) {
            AudioDriverInstallation.inspect(bundled: bundled, installed: installed)
        }.value
        let supported = await coreAudio
            .systemAudioBridgePresentationIsSupportedWithoutBlockingUI()
        let bridgePresent: Bool
        if supported {
            bridgePresent = true
        } else {
            bridgePresent = await coreAudio.resolveSystemAudioBridgeWithoutBlockingUI() != nil
        }
        // A startup probe can finish after repair starts or after a newer
        // recheck. Only the latest operation may publish component status.
        // The result remains useful if its originating view has disappeared.
        // Setup/newer probes, not view-task cancellation, invalidate it.
        guard revision == statusRevision else { return }
        if camillaDSPStatus != camillaStatus { camillaDSPStatus = camillaStatus }
        applyAudioDriverStatus(supported: supported, bridgePresent: bridgePresent, installation: installation)
        finishRefreshMessage()
    }

    /// Inspect installation files only. Unlike refresh, this neither creates the
    /// support layout nor executes the binary to obtain a version.
    func diagnosticCamillaDSPStatus() async -> Status {
        let binary = camillaDSPBinary
        let marker = camillaDSPCapabilityMarker
        let version: String?
        switch camillaDSPStatus {
        case .installed(let observed): version = observed
        case .working(let observed): version = observed
        default: version = nil
        }
        return await Task.detached(priority: .utility) {
            guard FileManager.default.isExecutableFile(atPath: binary.path) else { return Status.missing }
            guard (try? String(contentsOf: marker, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) == Self.requiredCamillaCapability else {
                return Status.failed("Required audio-engine capability marker is missing.")
            }
            return Status.installed(version)
        }.value
    }

    private func refreshCamillaDSPStatus() {
        camillaDSPStatus = Self.camillaDSPStatus(
            binary: camillaDSPBinary,
            capabilityMarker: camillaDSPCapabilityMarker
        )
    }

    nonisolated private static func camillaDSPStatus(
        binary: URL,
        capabilityMarker: URL
    ) -> Status {
        if FileManager.default.isExecutableFile(atPath: binary.path),
           (try? String(contentsOf: capabilityMarker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == Self.requiredCamillaCapability {
            let version = (try? Self.runBlocking(binary.path, ["--version"]))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .installed(version)
        } else if FileManager.default.isExecutableFile(atPath: binary.path) {
            return .failed(
                "Installed engine lacks the required CamiTune audio capabilities. Select Install / Repair Everything."
            )
        } else {
            return .missing
        }
    }

    private func applyAudioDriverStatus(supported: Bool, bridgePresent: Bool,
                                       installation: AudioDriverInstallation.Inspection) {
        audioDriverStatus = Self.driverStatus(supported: supported, bridgePresent: bridgePresent, installation: installation)
    }

    nonisolated static func driverStatus(supported: Bool, bridgePresent: Bool,
                                        installation: AudioDriverInstallation.Inspection) -> Status {
        if let problem = installation.problem {
            return .failed(problem)
        } else if !installation.isInstalled {
            return .missing
        } else if supported {
            return .installed("System Audio Bridge \(installation.version ?? "unknown")")
        } else if bridgePresent {
            return .failed("Driver \(installation.version ?? "unknown") is outdated; select Install / Repair Everything.")
        } else {
            return .failed("The installed audio driver is not loaded. Select Recheck, or Install / Repair Everything.")
        }
    }

    private func beginSetup() -> Bool {
        guard !setupInProgress else { return false }
        statusRevision &+= 1
        setupInProgress = true
        return true
    }

    private func finishRefreshMessage() {
        if case .installed = camillaDSPStatus, case .installed = audioDriverStatus, setupMessage.isEmpty {
            setupMessage = "Dependencies are ready."
        }
    }

    func recheck() async {
        guard beginSetup() else { return }
        setupFailed = false
        setupMessage = "Checking CamillaDSP and the system-audio routing driver…"
        camillaDSPStatus = .checking
        audioDriverStatus = .checking
        defer { setupInProgress = false }

        for attempt in 0..<8 {
            await coreAudio.refreshWithoutBlockingUI()
            await refreshStatuses()
            if case .installed = audioDriverStatus { break }
            if attempt < 7 { try? await Task.sleep(for: .milliseconds(500)) }
        }

        var missing: [String] = []
        if case .installed = camillaDSPStatus {} else { missing.append("CamillaDSP") }
        if case .installed = audioDriverStatus {} else { missing.append("System Audio Bridge") }

        if missing.isEmpty {
            setupFailed = false
            setupMessage = "Setup complete. CamillaDSP and the audio routing driver are ready."
        } else {
            setupFailed = true
            setupMessage = "Recheck complete. Not detected: " + missing.joined(separator: ", ") + "."
        }
    }

    func installCamillaDSP(preparing: () async -> Bool = { true }) async {
        guard beginSetup() else { return }
        defer { setupInProgress = false }
        guard await preparing() else { return }
        await performCamillaDSPInstall()
    }

    private func performCamillaDSPInstall() async {
        setupFailed = false
        setupMessage = "Installing the bundled CamillaDSP build…"
        camillaDSPStatus = .working("Installing CamiTune's CamillaDSP build…")
        do {
            try createSupportLayout()
            guard let binary = Bundle.main.url(
                forResource: "camilladsp",
                withExtension: nil,
                subdirectory: "CamillaDSP"
            ) else { throw SetupError.bundledCamillaDSPMissing }
            let binDir = camillaDSPBinary.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            let stagedBinary = binDir.appendingPathComponent(
                "camilladsp.installing-\(UUID().uuidString)"
            )
            defer { try? FileManager.default.removeItem(at: stagedBinary) }
            try FileManager.default.copyItem(at: binary, to: stagedBinary)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: stagedBinary.path
            )
            _ = try? await run(
                "/usr/bin/xattr",
                ["-d", "com.apple.quarantine", stagedBinary.path]
            )
            _ = try await run(stagedBinary.path, ["--version"])
            let capability: String
            do {
                capability = try await run(stagedBinary.path, ["--cami-tune-capabilities"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch { throw SetupError.bundledCamillaDSPIncompatible }
            guard capability == Self.requiredCamillaCapability else {
                throw SetupError.bundledCamillaDSPIncompatible
            }
            if FileManager.default.fileExists(atPath: camillaDSPBinary.path) {
                _ = try FileManager.default.replaceItemAt(
                    camillaDSPBinary,
                    withItemAt: stagedBinary,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try FileManager.default.moveItem(at: stagedBinary, to: camillaDSPBinary)
            }
            try Self.requiredCamillaCapability.write(
                to: camillaDSPCapabilityMarker,
                atomically: true,
                encoding: .utf8
            )
            setupMessage = "CamillaDSP is installed and verified."
            await refreshStatuses()
        } catch {
            setupFailed = true
            camillaDSPStatus = .failed(error.localizedDescription)
            setupMessage = "CamillaDSP installation failed: \(error.localizedDescription)"
        }
    }

    func uninstallCamillaDSP(preparing: () async -> Bool = { true }) async {
        guard beginSetup() else { return }
        defer { setupInProgress = false }
        guard await preparing() else { return }
        setupFailed = false
        setupMessage = "Removing CamillaDSP…"
        camillaDSPStatus = .working("Removing CamillaDSP…")
        let targets = [camillaDSPBinary, camillaDSPCapabilityMarker]
        do {
            try await Task.detached(priority: .utility) {
                for target in targets {
                    do { try FileManager.default.removeItem(at: target) }
                    catch CocoaError.fileNoSuchFile { continue }
                }
            }.value
            camillaDSPStatus = .missing
            setupMessage = "CamillaDSP uninstalled. Your profiles and System Audio Bridge driver are kept."
        } catch {
            setupFailed = true
            camillaDSPStatus = .failed(error.localizedDescription)
            setupMessage = "CamillaDSP removal did not complete: \(error.localizedDescription)"
        }
    }

    func installAudioDriver(preparing: () async -> Bool = { true }) async {
        guard beginSetup() else { return }
        defer { setupInProgress = false }
        guard await preparing() else { return }
        await performAudioDriverInstall()
    }

    private func performAudioDriverInstall() async {
        setupFailed = false
        setupMessage = "Installing the bundled System Audio Bridge driver…"
        audioDriverStatus = .working("Waiting for macOS administrator approval…")
        do {
            guard let bundledDriver = bundledDriverURL else {
                throw SetupError.bundledDriverMissing
            }
            _ = try await run(
                "/usr/bin/codesign",
                ["--verify", "--strict", bundledDriver.path]
            )

            // Keep CamiTune's own copy of the driver with the rest of its
            // managed dependencies. macOS loads HAL drivers from /Library, so
            // the privileged install below remains necessary, but this copy
            // gives the app a single owned location for future cleanup.
            try FileManager.default.createDirectory(
                at: managedDriverURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let stagedDriver = managedDriverURL.deletingLastPathComponent()
                .appendingPathComponent("CamillaAudio.installing-\(UUID().uuidString).driver")
            defer { try? FileManager.default.removeItem(at: stagedDriver) }
            try FileManager.default.copyItem(at: bundledDriver, to: stagedDriver)
            _ = try await run(
                "/usr/bin/codesign",
                ["--verify", "--strict", stagedDriver.path]
            )
            if FileManager.default.fileExists(atPath: managedDriverURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    managedDriverURL,
                    withItemAt: stagedDriver,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try FileManager.default.moveItem(at: stagedDriver, to: managedDriverURL)
            }

            await coreAudio.destroyAllProfileRoutingDevicesWithoutBlockingUI()
            let command = AudioDriverInstallation.replacementCommand(source: managedDriverURL,
                destination: installedDriverURL, legacyDestinations: AudioDriverInstallation.legacyURLs)
            let script = "do shell script \(appleScriptQuote(command)) with administrator privileges"
            _ = try await run("/usr/bin/osascript", ["-e", script])

            // The copy can finish before CoreAudio publishes the new device.
            // Poll the live device list so setup completes without relaunching the app.
            if await waitForAudioDriver() {
                let version = coreAudio.installedSystemAudioBridgeVersion ?? "unknown"
                audioDriverStatus = .installed("System Audio Bridge \(version)")
                setupMessage = "Dependencies are ready."
            } else {
                setupFailed = true
                setupMessage = "System Audio Bridge was installed, but CoreAudio has not exposed it yet. Restart the Mac, then select Recheck."
                audioDriverStatus = .failed("Installed; restart macOS, then select Recheck.")
            }
        } catch {
            setupFailed = true
            audioDriverStatus = .failed(error.localizedDescription)
            setupMessage = "System Audio Bridge installation failed: \(error.localizedDescription)"
        }
    }

    func uninstallAudioDriver(preparing: () async -> Bool = { true }) async {
        guard beginSetup() else { return }
        defer { setupInProgress = false }
        guard await preparing() else { return }
        setupFailed = false
        setupMessage = "Removing the System Audio Bridge driver…"
        audioDriverStatus = .working("Waiting for macOS administrator approval…")
        do {
            await coreAudio.destroyAllProfileRoutingDevicesWithoutBlockingUI()
            let targets = ([installedDriverURL] + AudioDriverInstallation.legacyURLs).map(\.path)
            let command = [
                "/bin/rm -rf \(targets.map(shellQuote).joined(separator: " "))",
                "(/bin/launchctl kickstart -k system/com.apple.audio.coreaudiod || /usr/bin/killall coreaudiod)"
            ].joined(separator: " && ")
            let script = "do shell script \(appleScriptQuote(command)) with administrator privileges"
            _ = try await run("/usr/bin/osascript", ["-e", script])
            if FileManager.default.fileExists(atPath: managedDriverURL.path) {
                try FileManager.default.removeItem(at: managedDriverURL)
            }
            await coreAudio.refreshWithoutBlockingUI()
            await refreshStatuses()
            audioDriverStatus = .missing
            setupMessage = "System Audio Bridge driver uninstalled. Your profiles and CamillaDSP are kept. Restart the Mac if its audio devices still appear."
        } catch {
            await coreAudio.refreshWithoutBlockingUI()
            await refreshStatuses()
            setupFailed = true
            setupMessage = "Driver removal did not complete: \(error.localizedDescription)"
        }
    }

    func installEverything(preparing: () async -> Bool = { true }) async {
        guard beginSetup() else { return }
        defer { setupInProgress = false }
        guard await preparing() else { return }
        setupMessage = "Setting up CamiTune dependencies…"

        await performCamillaDSPInstall()

        await performAudioDriverInstall()

        await refreshStatuses()
        if case .installed = camillaDSPStatus, case .installed = audioDriverStatus {
            setupFailed = false
            setupMessage = "Setup complete. CamillaDSP and System Audio Bridge are ready."
        } else {
            setupFailed = true
        }
    }

    func validateConfiguration(_ yaml: String) async throws {
        guard FileManager.default.isExecutableFile(atPath: camillaDSPBinary.path) else {
            throw SetupError.binaryMissing
        }
        try createSupportLayout()
        let validationURL = supportDirectory.appendingPathComponent("configs/validation.yml")
        try yaml.write(to: validationURL, atomically: true, encoding: .utf8)
        _ = try await run(camillaDSPBinary.path, ["--check", validationURL.path])
    }

    private func waitForAudioDriver() async -> Bool {
        for attempt in 0..<30 {
            await coreAudio.refreshWithoutBlockingUI()
            if await coreAudio.systemAudioBridgePresentationIsSupportedWithoutBlockingUI() {
                let bundled = bundledDriverURL, installed = installedDriverURL
                let inspection = await Task.detached(priority: .utility) {
                    AudioDriverInstallation.inspect(bundled: bundled, installed: installed)
                }.value
                return inspection.isInstalled && inspection.problem == nil
            }
            if attempt < 29 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        return false
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try Self.runBlocking(path, arguments)
        }.value
    }

    private nonisolated static func runBlocking(
        _ path: String,
        _ arguments: [String]
    ) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        // Drain while the child is running. Waiting first can deadlock once a
        // verbose validation/install command fills the pipe's kernel buffer.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw SetupError.commandFailed(output) }
        return output
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func appleScriptQuote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    enum SetupError: LocalizedError {
        case binaryMissing
        case bundledCamillaDSPMissing
        case bundledCamillaDSPIncompatible
        case bundledDriverMissing
        case commandFailed(String)
        var errorDescription: String? {
            switch self {
            case .binaryMissing: return "The UID-capable CamillaDSP executable is not installed."
            case .bundledCamillaDSPMissing:
                return "This CamiTune build does not contain the required UID-capable CamillaDSP executable. Rebuild CamiTune with build-app.sh."
            case .bundledCamillaDSPIncompatible:
                return "This app contains an incompatible audio engine. Reinstall or rebuild CamiTune."
            case .bundledDriverMissing: return "This app bundle does not contain CamillaAudio.driver. Reinstall CamiTune."
            case .commandFailed(let output): return output.isEmpty ? "Installer command failed." : output
            }
        }
    }
}

/// Installation identity is separate from the minimum supported transport ABI.
/// Read the plist directly: Bundle caches can retain metadata across replacement.
enum AudioDriverInstallation {
    static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/CamillaAudio.driver", isDirectory: true)
    static let legacyURLs = ["CamillaEQAudio", "CamillaAudioBridge", "SystemAudioBridge"].map {
        installedURL.deletingLastPathComponent().appendingPathComponent($0 + ".driver", isDirectory: true)
    }

    struct Inspection: Equatable, Sendable {
        let isInstalled: Bool
        let version: String?
        let problem: String?
    }

    private struct Identity: Equatable {
        let version: String
        let build: String
        let identifier: String
        let channels: Int?
        let layout: UInt32?
        let executableHash: Data

        init(_ url: URL) throws {
            let info = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            guard let plist = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
                  let version = plist["CFBundleShortVersionString"] as? String, !version.isEmpty,
                  let identifier = plist["CFBundleIdentifier"] as? String,
                  let executable = plist["CFBundleExecutable"] as? String,
                  !executable.isEmpty, executable == (executable as NSString).lastPathComponent else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.version = version; self.identifier = identifier
            build = plist["CFBundleVersion"] as? String ?? ""
            channels = plist["SystemAudioBridgeChannelCount"] as? Int
            layout = plist["SystemAudioBridgeChannelLayoutTag"] as? UInt32
            let bytes = try Data(contentsOf: url.appendingPathComponent("Contents/MacOS/" + executable), options: .mappedIfSafe)
            executableHash = Data(SHA256.hash(data: bytes))
        }
    }

    static func inspect(bundled: URL?, installed: URL) -> Inspection {
        guard FileManager.default.fileExists(atPath: installed.path) else {
            return .init(isInstalled: false, version: nil, problem: nil)
        }
        let current: Identity
        do { current = try Identity(installed) }
        catch {
            return .init(isInstalled: true, version: nil,
                problem: "The installed audio driver is incomplete. Select Install / Repair Everything.")
        }
        if let bundled {
            do {
                let expected = try Identity(bundled)
                if current != expected {
                    return .init(isInstalled: true, version: current.version,
                        problem: "Installed driver \(current.version) differs from this app's bundled driver \(expected.version). Select Install / Repair Everything.")
                }
            } catch {
                return .init(isInstalled: true, version: current.version,
                    problem: "This app's bundled audio driver is incomplete. Reinstall CamiTune.")
            }
        }
        return .init(isInstalled: true, version: current.version, problem: nil)
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Copy and validate before retiring the old bundle. A failed swap restores
    /// it in the same invocation, so repair never means uninstall on click one.
    static func replacementCommand(source: URL, destination: URL, legacyDestinations: [URL],
                                   prepareStaged: String = """
                                   /usr/bin/codesign --verify --strict "$staged"
                                   /usr/sbin/chown -R root:wheel "$staged"
                                   /bin/chmod -R go-w "$staged"
                                   /usr/bin/xattr -dr com.apple.quarantine "$staged" 2>/dev/null || true
                                   """,
                                   restart: String = "(/bin/launchctl kickstart -k system/com.apple.audio.coreaudiod || /usr/bin/killall coreaudiod || true)") -> String {
        let legacyRemoval = legacyDestinations.isEmpty ? ":" : "/bin/rm -rf " + legacyDestinations.map { shellQuote($0.path) }.joined(separator: " ")
        return """
        set -eu
        destination=\(shellQuote(destination.path))
        /bin/mkdir -p \(shellQuote(destination.deletingLastPathComponent().path))
        workspace=$(/usr/bin/mktemp -d \(shellQuote(destination.deletingLastPathComponent().appendingPathComponent(".CamiTune-install.XXXXXX").path)))
        staged="$workspace/CamillaAudio.driver"
        backup="$workspace/previous.driver"
        had_previous=0
        published=0
        committed=0
        cleanup() {
            result=$?
            trap - EXIT HUP INT TERM
            if [ "$committed" -eq 0 ]; then
                if [ "$published" -eq 1 ]; then /bin/rm -rf "$destination"; fi
                if [ "$had_previous" -eq 1 ]; then /bin/mv "$backup" "$destination" || exit 1; fi
            fi
            /bin/rm -rf "$workspace"
            exit "$result"
        }
        trap cleanup EXIT
        trap 'exit 1' HUP INT TERM
        /usr/bin/ditto \(shellQuote(source.path)) "$staged"
        \(prepareStaged)
        if [ -e "$destination" ]; then
            /bin/mv "$destination" "$backup"
            had_previous=1
        fi
        /bin/mv "$staged" "$destination"
        published=1
        \(legacyRemoval)
        committed=1
        \(restart)
        """
    }
}
