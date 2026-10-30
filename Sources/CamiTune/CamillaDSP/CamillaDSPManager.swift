import CamiTuneAudio
import CamiTuneDomain
import Foundation
import Darwin

/// Owns a child before its background launch starts. Launch and retirement share
/// a barrier so synchronous app termination cannot miss a not-yet-published PID.
final class CamillaDSPProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var retired = false

    init(_ process: Process) { self.process = process }
    deinit { stop(graceSteps: 0) }

    var isRunning: Bool { lock.withLock { process.isRunning } }

    func launch() throws {
        try lock.withLock {
            guard !retired else { throw CancellationError() }
            try process.run()
        }
    }

    func stop(graceSteps: Int) {
        lock.withLock {
            guard !retired else { return }
            retired = true
            guard process.isRunning else { return }
            process.terminate()
            for _ in 0..<graceSteps where process.isRunning { usleep(50_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
    }
}

@MainActor
final class CamillaDSPManager: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    // Keep the app's private engine separate from the conventional CamillaGUI
    // port (1234), which may already be occupied by a manual/legacy setup.
    private let controlPort: UInt16
    let rpc: CamillaRPC
    private var process: CamillaDSPProcess?
    private var inputPipe: Pipe?
    private var hasAppliedConfig = false
    private var clockPollingTask: Task<Void, Never>?
    private var clockSession: UUID?
    private(set) var lastPlaybackClock: AudioPlaybackClock?
    init() {
        let port = UInt16.random(in: 20_000...49_999)
        controlPort = port
        rpc = CamillaRPC(port: port)
    }

    func start(binary: URL, shouldContinue: @MainActor () -> Bool = { true }) async throws {
        guard shouldContinue() else { throw CancellationError() }
        if let process, process.isRunning {
            if !isRunning { try await connectWithRetry(shouldContinue: shouldContinue) }
            return
        }

        await Self.terminateStalePrivateEngines(binary: binary)
        guard shouldContinue() else { throw CancellationError() }

        let logDirectory = supportDirectory().appendingPathComponent("logs", isDirectory: true)
        let logURL = logDirectory.appendingPathComponent("camilladsp.log")
        let handle = try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: true
            )
            try Data().write(to: logURL)
            return try FileHandle(forWritingTo: logURL)
        }.value
        guard shouldContinue() else { try? handle.close(); throw CancellationError() }

        let p = Process()
        p.executableURL = binary
        // Rotation gives the engine its own _rCURRENT.log file. Keep only
        // raw startup errors and panics in the separate, per-launch base log.
        p.arguments = [
            "--address", "127.0.0.1", "--port", String(controlPort), "--wait", "--gain=-20",
            "--loglevel", "warn", "--logfile", logURL.path,
            "--log_rotate_size", "1048576", "--log_keep_nbr", "2"
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = handle
        let pipe = Pipe()
        p.standardInput = pipe
        let child = CamillaDSPProcess(p)
        p.terminationHandler = { [weak self, weak child] _ in
            guard let self, let child else { return }
            Task { @MainActor in
                guard self.process === child else { return }
                self.isRunning = false
            }
        }
        inputPipe = pipe
        process = child
        hasAppliedConfig = false
        try await Task.detached(priority: .userInitiated) {
            defer { try? handle.close() }
            try child.launch()
        }.value
        guard process === child, shouldContinue() else { throw CancellationError() }
        try await connectWithRetry(shouldContinue: shouldContinue)
        guard process === child, shouldContinue() else { throw CancellationError() }
        isRunning = true
    }

    func audioInputHandle() throws -> FileHandle {
        guard let handle = inputPipe?.fileHandleForWriting else { throw CamillaError.inputUnavailable }
        return handle
    }

    func observePlaybackClock(session: UUID, consumer: @escaping @Sendable (AudioClockObservation) -> Void) {
        stopClockObservations()
        clockSession = session
        clockPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, clockSession == session else { return }
                do {
                    if let clock = try await rpc.playbackClock(), !Task.isCancelled, clockSession == session {
                        lastPlaybackClock = clock
                        consumer(clock.observation(received: PerformanceClock.now()))
                    }
                } catch {
                    // Missing evidence expires in the writer's clock contract.
                    // A failed RPC cannot make the last sample appear fresh.
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stopClockObservations() {
        clockSession = nil
        lastPlaybackClock = nil
        clockPollingTask?.cancel()
        clockPollingTask = nil
    }

    /// Releases the manager's stdin handle. The PCM worker owns a separate
    /// duplicate; if it is blocked, engine termination closes the read end and
    /// unblocks it. Router shutdown therefore uses a bounded join.
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
            // A previous ambiguous mutation may have retired the socket. A
            // restoring full configuration must establish a fresh connection.
            try await rpc.connect()
            try await rpc.setConfig(yaml: yaml)
            // Startup uses -20 dB as a safety guard. Normalize the Main fader
            // only for the first valid graph. VolumeHandoffService owns the live
            // master afterward; later full graph replacements must not reset a
            // user's keyboard volume or mute state to 0 dB/unmuted.
            if !hasAppliedConfig {
                try await rpc.setVolume(0)
                try await rpc.setMute(false)
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
        stopClockObservations()
        guard let childProcess = process else {
            hasAppliedConfig = false
            isRunning = false
            return
        }

        closeAudioInput()
        childProcess.stop(graceSteps: 10)
        self.process = nil
        hasAppliedConfig = false
        isRunning = false
    }

    func stop() async {
        stopClockObservations()
        let childProcess = process
        await closeAudioInputWithoutBlockingUI()
        // Disconnecting first also aborts a stuck in-flight RPC. Waiting for an
        // "Exit" reply here could otherwise make profile switching hang forever.
        await rpc.disconnect()
        if let childProcess {
            await Task.detached(priority: .utility) {
                childProcess.stop(graceSteps: 8)
            }.value
        }
        guard process === childProcess else { return }
        process = nil
        hasAppliedConfig = false
        isRunning = false
    }

    private func connectWithRetry(shouldContinue: @MainActor () -> Bool = { true }) async throws {
        var finalError: Error?
        for _ in 0..<30 {
            guard !Task.isCancelled, shouldContinue() else { throw CancellationError() }
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
