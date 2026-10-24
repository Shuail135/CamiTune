import Foundation
import Darwin

struct PluginHostError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Control traffic is read independently of audio. Plug-in stdout is redirected
/// by the helper before loading any vendor code.
final class PluginHostProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let condition = NSCondition()
    private var events: [[String: Any]] = []
    private var finished = false
    private var receivedEvent = false
    private var translatedIntel = false
    private var observer: (@Sendable ([String: Any]) -> Void)?
    private let commands = DispatchQueue(label: "CamiTune plug-in control")

    static func executable() throws -> URL {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Helpers/camitune-plugin-host"),
           FileManager.default.isExecutableFile(atPath: url.path) { return url }
#if DEBUG
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let local = root.appendingPathComponent("build/plugin-host/camitune-plugin-host")
        if FileManager.default.isExecutableFile(atPath: local.path) { return local }
#endif
        throw PluginHostError(message: "The plug-in host is missing. Reinstall CamiTune to restore plug-in support.")
    }

    init(arguments: [String], architecture: PluginArchitecture? = nil, observer: (@Sendable ([String: Any]) -> Void)? = nil) throws {
        self.observer = observer
        let executable = try Self.executable()
        let selected = architecture ?? (arguments.first == "--scan-vst3" && arguments.count == 2
            ? PluginArchitecture.preferred(forVST3: URL(fileURLWithPath: arguments[1])) : .native)
        translatedIntel = selected == .x86_64 && PluginArchitecture.native == .arm64
        guard PluginArchitecture.available(in: executable).contains(selected) else {
            throw PluginHostError(message: "CamiTune’s plug-in helper is missing its \(selected.rawValue) build. Reinstall the universal version of CamiTune.")
        }
        if selected != .native {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
            process.arguments = ["-\(selected.rawValue)", executable.path] + arguments
        } else { process.executableURL = executable; process.arguments = arguments }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A helper may exit between queuing a command and writing it. Protect
        // this descriptor rather than changing SIGPIPE for the whole app.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw PluginHostError(message: "Could not prepare the plug-in control connection.")
        }
        do { try process.run() }
        catch {
            if selected == .x86_64 && PluginArchitecture.native == .arm64 {
                throw PluginHostError(message: "The Intel plug-in helper could not start. Install Apple’s Rosetta support, then add the plug-in again.")
            }
            throw error
        }
        let handle = output.fileHandleForReading
        // The reader owns its handle until EOF. Termination never closes a
        // descriptor underneath a blocked read.
        Thread.detachNewThread { [weak self] in
            var pending = Data()
            while true {
                let bytes = handle.availableData
                if bytes.isEmpty { break }
                pending.append(bytes)
                if pending.count > 8 * 1024 * 1024 { self?.stop(); break }
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending.prefix(upTo: newline)
                    if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { self?.receive(event) }
                    pending.removeSubrange(...newline)
                }
            }
            if let owner = self {
                owner.condition.lock(); owner.finished = true; owner.condition.broadcast(); owner.condition.unlock()
                owner.observer?(["event": "closed"])
            }
        }
    }

    private func receive(_ event: [String: Any]) {
        condition.lock()
        receivedEvent = true
        let name = event["event"] as? String ?? ""
        if (["ready", "scan", "error"].contains(name) || name.hasPrefix("snapshot-")), events.count < 32 { events.append(event) }
        let observer = self.observer
        condition.broadcast(); condition.unlock()
        observer?(event)
    }

    func wait(for name: String, timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while true {
            if let error = events.first(where: { $0["event"] as? String == "error" }) {
                throw PluginHostError(message: error["message"] as? String ?? "The plug-in could not be loaded.")
            }
            if let index = events.firstIndex(where: { $0["event"] as? String == name }) { return events.remove(at: index) }
            if finished {
                throw PluginHostError(message: translatedIntel && !receivedEvent
                    ? "The Intel plug-in helper could not start. Check that Apple’s Rosetta support is installed, then try again."
                    : "The plug-in host closed unexpectedly. Try loading the plug-in again.")
            }
            if !condition.wait(until: deadline) { throw PluginHostError(message: "The plug-in took too long to respond. It has been stopped.") }
        }
    }

    func send(_ command: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: command) else { return }
        data.append(10)
        let payload = data
        commands.async { [input] in try? input.fileHandleForWriting.write(contentsOf: payload) }
    }

    func stop() {
        let process = self.process
        DispatchQueue.global(qos: .utility).async {
            if process.isRunning { process.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
    deinit { stop() }
}
