import Foundation

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

    private let coreAudio: CoreAudioManager
    private static let coreAudioUIDCapability = "coreaudio-uid-v1"

    init(coreAudio: CoreAudioManager) {
        self.coreAudio = coreAudio
    }

    var supportDirectory: URL {
        CamiTunePaths.supportDirectory
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
        try? createSupportLayout()
        refreshCamillaDSPStatus()
        let bridgePresent = coreAudio.systemAudioBridge != nil
        applyAudioDriverStatus(
            supported: coreAudio.isSystemAudioBridgePresentationSupported,
            bridgePresent: bridgePresent
        )
        finishRefreshMessage()
    }

    func refreshWithoutBlockingUI() async {
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
        if camillaDSPStatus != camillaStatus {
            camillaDSPStatus = camillaStatus
        }
        let supported = await coreAudio
            .systemAudioBridgePresentationIsSupportedWithoutBlockingUI()
        let bridgePresent: Bool
        if supported {
            bridgePresent = true
        } else {
            bridgePresent = await coreAudio.resolveSystemAudioBridgeWithoutBlockingUI() != nil
        }
        applyAudioDriverStatus(supported: supported, bridgePresent: bridgePresent)
        finishRefreshMessage()
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
            .trimmingCharacters(in: .whitespacesAndNewlines) == Self.coreAudioUIDCapability {
            let version = (try? Self.runBlocking(binary.path, ["--version"]))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .installed(version)
        } else if FileManager.default.isExecutableFile(atPath: binary.path) {
            return .failed(
                "Installed build lacks required Core Audio UID support. Select Install / Repair Everything."
            )
        } else {
            return .missing
        }
    }

    private func applyAudioDriverStatus(supported: Bool, bridgePresent: Bool) {
        if supported {
            let version = coreAudio.installedSystemAudioBridgeVersion ?? "unknown"
            audioDriverStatus = .installed("System Audio Bridge \(version)")
        } else if bridgePresent {
            let version = coreAudio.installedSystemAudioBridgeVersion ?? "unknown"
            audioDriverStatus = .failed("Driver \(version) is outdated; select Install / Repair Everything.")
        } else {
            audioDriverStatus = .missing
        }
    }

    private func finishRefreshMessage() {
        if case .installed = camillaDSPStatus, case .installed = audioDriverStatus, setupMessage.isEmpty {
            setupMessage = "Dependencies are ready."
        }
    }

    func recheck() async {
        guard !setupInProgress else { return }
        setupFailed = false
        setupInProgress = true
        setupMessage = "Checking CamillaDSP and the system-audio routing driver…"
        camillaDSPStatus = .checking
        audioDriverStatus = .checking
        defer { setupInProgress = false }

        for attempt in 0..<8 {
            await coreAudio.refreshWithoutBlockingUI()
            await refreshWithoutBlockingUI()
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

    func installCamillaDSP() async {
        guard !setupInProgress else { return }
        setupInProgress = true
        defer { setupInProgress = false }
        await performCamillaDSPInstall()
    }

    private func performCamillaDSPInstall() async {
        setupFailed = false
        setupMessage = "Installing the bundled UID-capable CamillaDSP build…"
        camillaDSPStatus = .working("Installing CamiTune's UID-capable CamillaDSP build…")
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
            try Self.coreAudioUIDCapability.write(
                to: camillaDSPCapabilityMarker,
                atomically: true,
                encoding: .utf8
            )
            setupMessage = "UID-capable CamillaDSP is installed and verified."
            await refreshWithoutBlockingUI()
        } catch {
            setupFailed = true
            camillaDSPStatus = .failed(error.localizedDescription)
            setupMessage = "CamillaDSP installation failed: \(error.localizedDescription)"
        }
    }

    func installAudioDriver() async {
        guard !setupInProgress else { return }
        setupInProgress = true
        defer { setupInProgress = false }
        await performAudioDriverInstall()
    }

    private func performAudioDriverInstall() async {
        setupFailed = false
        setupMessage = "Installing the bundled System Audio Bridge driver…"
        audioDriverStatus = .working("Waiting for macOS administrator approval…")
        do {
            guard let bundledDriver = Bundle.main.url(
                forResource: "CamillaAudio",
                withExtension: "driver",
                subdirectory: "Drivers"
            ) else {
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

            coreAudio.destroyAllProfileRoutingDevices()
            let destination = "/Library/Audio/Plug-Ins/HAL/CamillaAudio.driver"
            let legacyDestinations = [
                "/Library/Audio/Plug-Ins/HAL/CamillaEQAudio.driver",
                "/Library/Audio/Plug-Ins/HAL/CamillaAudioBridge.driver",
                "/Library/Audio/Plug-Ins/HAL/SystemAudioBridge.driver"
            ]
            let removalTargets = ([destination] + legacyDestinations)
                .map(shellQuote)
                .joined(separator: " ")
            let command = [
                "/bin/rm -rf \(removalTargets)",
                "/usr/bin/ditto \(shellQuote(managedDriverURL.path)) \(shellQuote(destination))",
                "/usr/sbin/chown -R root:wheel \(shellQuote(destination))",
                "/bin/chmod -R go-w \(shellQuote(destination))",
                "(/usr/bin/xattr -dr com.apple.quarantine \(shellQuote(destination)) || true)",
                "(/bin/launchctl kickstart -k system/com.apple.audio.coreaudiod || /usr/bin/killall coreaudiod)"
            ].joined(separator: " && ")
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

    func installEverything() async {
        guard !setupInProgress else { return }
        setupInProgress = true
        defer { setupInProgress = false }
        setupMessage = "Setting up CamiTune dependencies…"
        await performCamillaDSPInstall()
        if case .installed = audioDriverStatus {} else {
            await performAudioDriverInstall()
        }
        await refreshWithoutBlockingUI()
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
                return true
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
        case bundledDriverMissing
        case commandFailed(String)
        var errorDescription: String? {
            switch self {
            case .binaryMissing: return "The UID-capable CamillaDSP executable is not installed."
            case .bundledCamillaDSPMissing:
                return "This CamiTune build does not contain the required UID-capable CamillaDSP executable. Rebuild CamiTune with build-app.sh."
            case .bundledDriverMissing: return "This app bundle does not contain CamillaAudio.driver. Reinstall CamiTune."
            case .commandFailed(let output): return output.isEmpty ? "Installer command failed." : output
            }
        }
    }
}
