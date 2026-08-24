import Foundation
import Darwin

@MainActor
final class CamillaDSPManager: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    // Keep the app's private engine separate from the conventional CamillaGUI
    // port (1234), which may already be occupied by a manual/legacy setup.
    private let controlPort: UInt16
    let rpc: CamillaRPC
    private var process: Process?
    private var inputPipe: Pipe?
    private var hasAppliedConfig = false

    init() {
        let port = UInt16.random(in: 20_000...49_999)
        controlPort = port
        rpc = CamillaRPC(port: port)
    }

    func start(binary: URL) async throws {
        if let process, process.isRunning {
            if !isRunning { try await connectWithRetry() }
            return
        }

        await Self.terminateStalePrivateEngines(binary: binary)

        let logDirectory = supportDirectory().appendingPathComponent("logs", isDirectory: true)
        let logURL = logDirectory.appendingPathComponent("camilladsp.log")
        let handle = try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            return handle
        }.value

        let port = controlPort
        let (p, pipe) = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--address", "127.0.0.1", "--port", String(port), "--wait", "--gain=-20", "--logfile", logURL.path]
            process.standardOutput = handle
            process.standardError = handle
            let pipe = Pipe()
            process.standardInput = pipe
            try process.run()
            return (process, pipe)
        }.value
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.isRunning = false
            }
        }
        inputPipe = pipe
        process = p
        hasAppliedConfig = false
        try await connectWithRetry()
        isRunning = true
    }

    func audioInputHandle() throws -> FileHandle {
        guard let handle = inputPipe?.fileHandleForWriting else { throw CamillaError.inputUnavailable }
        return handle
    }

    /// Closing stdin first unblocks any PCM writer waiting on a full pipe. It
    /// is intentionally separate from process teardown so the router can join
    /// its delivery worker without depending on CamillaDSP's control socket.
    func closeAudioInput() {
        try? inputPipe?.fileHandleForWriting.close()
        inputPipe = nil
    }

    func closeAudioInputWithoutBlockingUI() async {
        let handle = inputPipe?.fileHandleForWriting
        inputPipe = nil
        await Task.detached(priority: .userInitiated) {
            try? handle?.close()
        }.value
    }

    func apply(yaml: String) async throws {
        do {
            let configDirectory = supportDirectory().appendingPathComponent("configs", isDirectory: true)
            let configURL = configDirectory.appendingPathComponent("active.yml")
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(
                    at: configDirectory,
                    withIntermediateDirectories: true
                )
                try yaml.write(to: configURL, atomically: true, encoding: .utf8)
            }.value
            try await rpc.setConfig(yaml: yaml)
            // Startup uses -20 dB as a safety guard. Once a valid graph is active,
            // its derived response-processing headroom replaces that guard.
            // Intentional User-preamp boost is monitored and optionally limited.
            if !hasAppliedConfig {
                try await rpc.setVolume(0)
                hasAppliedConfig = true
            }
            lastError = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func apply(configuration: CamillaDSPConfiguration) async throws {
        try await apply(yaml: configuration.yaml)
    }

    func apply(patch: CamillaDSPRuntimePatch) async throws {
        do {
            try await rpc.patchConfig(patch)
            lastError = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func forceStopAndWait() {
        guard let childProcess = process else {
            hasAppliedConfig = false
            isRunning = false
            return
        }

        closeAudioInput()
        if childProcess.isRunning {
            childProcess.terminate()
            // App termination cannot await an async task. Give only this app's
            // child process a short grace period, then guarantee it cannot be
            // orphaned and keep CoreAudio/control ports open after quit.
            for _ in 0..<10 where childProcess.isRunning {
                usleep(50_000)
            }
            if childProcess.isRunning {
                kill(childProcess.processIdentifier, SIGKILL)
            }
            childProcess.waitUntilExit()
        }
        self.process = nil
        hasAppliedConfig = false
        isRunning = false
    }

    func stop() async {
        await closeAudioInputWithoutBlockingUI()
        // Disconnecting first also aborts a stuck in-flight RPC. Waiting for an
        // "Exit" reply here could otherwise make profile switching hang forever.
        await rpc.disconnect()
        if let childProcess = process {
            if childProcess.isRunning {
                childProcess.terminate()
                for _ in 0..<8 where childProcess.isRunning {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if childProcess.isRunning {
                    kill(childProcess.processIdentifier, SIGKILL)
                }
            }
            await Task.detached(priority: .utility) {
                childProcess.waitUntilExit()
            }.value
        }
        process = nil
        hasAppliedConfig = false
        isRunning = false
    }

    private func connectWithRetry() async throws {
        var finalError: Error?
        for _ in 0..<30 {
            do {
                try await rpc.connect()
                return
            } catch {
                finalError = error
                await rpc.disconnect()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        throw finalError ?? CamillaError.connectionTimeout
    }

    private nonisolated static func terminateStalePrivateEngines(binary: URL) async {
        // Only match CamillaDSP instances launched from this app's private
        // Application Support binary. Do not touch Homebrew or user-managed
        // CamillaDSP installations.
        // Match all historical command-line variants of this exact private
        // executable. Older app builds used port 1234 and did not pass
        // --address, so restricting the argument pattern left orphan engines
        // competing for the routing stream indefinitely.
        await Task.detached(priority: .utility) {
            let pattern = "^\(NSRegularExpression.escapedPattern(for: binary.path))( |$)"
            let killer = Process()
            killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            killer.arguments = ["-TERM", "-f", pattern]
            killer.standardOutput = FileHandle.nullDevice
            killer.standardError = FileHandle.nullDevice
            try? killer.run()
            killer.waitUntilExit()
        }.value
    }

    private func supportDirectory() -> URL {
        // Callers create their concrete log/config directories in detached work.
        // Merely computing the Application Support URL must stay side-effect free
        // so this MainActor-owned manager never performs filesystem I/O here.
        CamiTunePaths.supportDirectory
    }

    enum CamillaError: LocalizedError {
        case connectionTimeout
        case inputUnavailable
        var errorDescription: String? {
            switch self {
            case .connectionTimeout: return "CamillaDSP did not open its local control socket."
            case .inputUnavailable: return "CamillaDSP's audio input pipe is unavailable."
            }
        }
    }
}
