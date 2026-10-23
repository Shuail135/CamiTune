import CamiTuneAudio
import CamiTuneDomain
import Foundation
import Darwin

/// One prepared helper owns a rack. Audio uses a single shared buffer, with an
/// explicit request/reply ownership handoff. A timeout poisons the session;
/// its memory is never reused while a late plug-in might still be writing.
final class PluginHostConnection: @unchecked Sendable {
    static let maximumFrames = 2048
    static let protocolVersion: UInt32 = 3
    let sampleRate: Double
    let channelRoles: [ChannelRole]
    var channelCount: Int { channelRoles.count }
    private var sharedBytes: Int { Self.maximumFrames * (channelCount + sidechains.count * 2) * MemoryLayout<Float>.size }
    let slotIDs: Set<UUID>
    private let sidechains: [PluginSidechainBuffer?]
    private let directory: URL
    private var memory: UnsafeMutableRawPointer?
    private var socketFD: Int32 = -1
    private var listener: Int32 = -1
    private var host: PluginHostProcess?
    private var sequence: UInt32 = 0
    private let state = NSLock()
    private var failure: String?
    private var reportedLatency = 0
    private var reportedTail = 0
    private var reportedQuietHorizon: Double?
    private var generatesAudio = false
    var requiresContinuousRendering: Bool { state.lock(); defer { state.unlock() }; return generatesAudio && failure == nil }
    private var savedStates: [UUID: Data] = [:]
    private let eventHandler: @Sendable ([String: Any]) -> Void

    var latencyFrames: Int { state.lock(); defer { state.unlock() }; return reportedLatency }
    var tailFrames: Int { state.lock(); defer { state.unlock() }; return failure == nil ? min(Int(sampleRate * 10), reportedTail + reportedLatency) : 0 }
    func bufferChangeTailSeconds(sampleRate: Double) -> Double {
        state.lock(); defer { state.unlock() }
        guard failure == nil, let reportedQuietHorizon else { return .infinity }
        return reportedQuietHorizon
    }
    var errorMessage: String? { state.lock(); defer { state.unlock() }; return failure }

    init(rack: PluginRack, sampleRate: Double, channelRoles: [ChannelRole] = [.left, .right], editorOnly: Bool = false,
         architecture: PluginArchitecture = .native, sidechainHub: PluginSidechainHub? = nil,
         eventHandler: @escaping @Sendable ([String: Any]) -> Void) throws {
        self.sampleRate = sampleRate
        self.channelRoles = channelRoles
        self.eventHandler = eventHandler
        slotIDs = Set(rack.activeSlots.map(\.id))
        sidechains = rack.activeSlots.map { slot in
            guard !editorOnly, let source = slot.sidechain else { return nil }
            return sidechainHub?.subscribe(source, sampleRate: sampleRate)
        }
        // A short private path fits Darwin's sockaddr_un even when TMPDIR is long.
        directory = URL(fileURLWithPath: "/tmp/ctplug-\(UUID().uuidString)", isDirectory: true)
        do {
            try rack.validate()
            guard (1...SpeakerTopology.maximumOutputChannels).contains(channelCount) else {
                throw PluginHostError(message: "The plug-in audio layout is invalid.")
            }
            // The helper only emits changed states. An unchanged restored
            // preset must still be present in an explicit snapshot result.
            savedStates = Dictionary(uniqueKeysWithValues: rack.activeSlots.compactMap { slot in
                slot.state.map { (slot.id, $0) }
            })
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let fileURL = directory.appendingPathComponent("audio")
            let file = Darwin.open(fileURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard file >= 0 else { throw PluginHostError(message: "Could not create the plug-in audio buffer.") }
            defer { Darwin.close(file) }
            guard ftruncate(file, off_t(sharedBytes)) == 0 else { throw PluginHostError(message: "Could not allocate the plug-in audio buffer.") }
            let mapped = mmap(nil, sharedBytes, PROT_READ | PROT_WRITE, MAP_SHARED, file, 0)
            guard mapped != MAP_FAILED, let mapped else { throw PluginHostError(message: "Could not map the plug-in audio buffer.") }
            memory = mapped
            listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { throw PluginHostError(message: "Could not create the plug-in audio connection.") }
            _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let socketURL = directory.appendingPathComponent("socket")
            let pathBytes = socketURL.path.utf8CString
            guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw PluginHostError(message: "The plug-in audio connection path is too long.") }
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                pathBytes.withUnsafeBytes { destination.copyBytes(from: $0) }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, Darwin.listen(listener, 1) == 0 else { throw PluginHostError(message: "Could not listen for the plug-in host.") }
            struct Configuration: Encodable { let sampleRate: Double; let slots: [AudioPluginSlot]; let channelRoles: [ChannelRole]; let editorOnly: Bool }
            let configURL = directory.appendingPathComponent("rack.json")
            try JSONEncoder().encode(Configuration(sampleRate: sampleRate, slots: rack.activeSlots, channelRoles: channelRoles, editorOnly: editorOnly)).write(to: configURL, options: .atomic)
            let process = try PluginHostProcess(arguments: ["--rack", configURL.path, fileURL.path, socketURL.path], architecture: architecture) { [weak self] event in
                self?.receive(event)
            }
            host = process
            let ready = try process.wait(for: "ready", timeout: 30)
            guard ready["version"] as? Int == Int(Self.protocolVersion), ready["channels"] as? Int == channelCount else { throw PluginHostError(message: "The plug-in host audio format does not match CamiTune.") }
            var pollFD = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&pollFD, 1, 1000) > 0 else { throw PluginHostError(message: "The plug-in audio connection timed out.") }
            socketFD = Darwin.accept(listener, nil, nil)
            guard socketFD >= 0 else { throw PluginHostError(message: "The plug-in audio connection failed.") }
            Darwin.close(listener); listener = -1
            _ = fcntl(socketFD, F_SETFD, FD_CLOEXEC)
            _ = fcntl(socketFD, F_SETFL, O_NONBLOCK)
            var noSignal: Int32 = 1
            _ = setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            // Force lazy plug-in setup before publishing this processor to audio.
            var silence = [Float](repeating: 0, count: 128 * channelCount)
            guard silence.withUnsafeMutableBufferPointer({ processChunk($0, reset: true, deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000) }) else {
                throw PluginHostError(message: errorMessage ?? "The plug-in could not process audio.")
            }
            host?.send(["command": "snapshot"])
        } catch { retire(); throw error }
    }

    private func receive(_ event: [String: Any]) {
        switch event["event"] as? String {
        case "ready", "latency":
            state.lock()
            if let capabilities = event["capabilities"] as? [[String: Any]] { generatesAudio = capabilities.contains { $0["instrument"] as? Bool == true } }
            reportedLatency = min(Int(sampleRate * 10), max(0, event["latencyFrames"] as? Int ?? 0))
            if let seconds = event["tailSeconds"] as? Double, seconds.isFinite { reportedTail = Int(min(10, max(0, seconds)) * sampleRate) }
            // Helpers cap/represent unknown tails at ten seconds. That bounded
            // drain estimate must never authorize discarding a longer history.
            if let tail = event["tailSeconds"] as? Double, tail.isFinite, tail >= 0, tail < 10,
               let latency = event["latencyFrames"] as? Int, latency >= 0, Double(latency) < sampleRate * 10 {
                reportedQuietHorizon = tail + Double(latency) / sampleRate
            } else { reportedQuietHorizon = nil }
            state.unlock()
        case "error": fail(event["message"] as? String ?? "The plug-in stopped responding.")
        case "closed": fail("The plug-in host closed unexpectedly. Bypass the rack or reload it to continue.")
        case "state":
            if let id = (event["slotID"] as? String).flatMap(UUID.init(uuidString:)),
               let data = (event["state"] as? String).flatMap({ Data(base64Encoded: $0) }), data.count <= PluginRack.maximumStateBytes {
                state.lock(); savedStates[id] = data; state.unlock()
            }
        default: break
        }
        eventHandler(event)
    }

    func openEditor(slotID: UUID) { host?.send(["command": "editor", "slotID": slotID.uuidString]) }
    func closeEditors() { host?.send(["command": "closeEditors"]) }
    func control(_ command: [String: Any]) { host?.send(command) }
    func configureMIDI(_ configuration: PluginMIDIConfiguration, enabled: Bool) {
        var value = configuration; value.isEnabled = value.isEnabled && enabled
        // A saved destination may have been removed, bypassed, or belong to
        // another helper. Never substitute another slot or restrict mappings.
        if let destination = value.programChangeSlotID, !slotIDs.contains(destination) {
            value.programChangeSlotID = nil
        }
        guard let data = try? JSONEncoder().encode(value), let json = try? JSONSerialization.jsonObject(with: data) else { return }
        host?.send(["command": "configureMIDI", "configuration": json])
    }

    func snapshot(close: Bool) async -> [UUID: Data] {
        guard let host, errorMessage == nil else { return [:] }
        let response = "snapshot-\(UUID().uuidString)"
        host.send(["command": close ? "closeEditors" : "snapshot", "response": response])
        do { _ = try await Task.detached(priority: .userInitiated) { try host.wait(for: response, timeout: 1.5) }.value }
        catch { eventHandler(["event": "snapshotError", "message": error.localizedDescription]) }
        return currentStates()
    }
    private func currentStates() -> [UUID: Data] { state.lock(); defer { state.unlock() }; return savedStates }

    func processChunk(_ buffer: UnsafeMutableBufferPointer<Float>, reset: Bool, deadline: UInt64) -> Bool {
        guard errorMessage == nil, let memory, socketFD >= 0, !buffer.isEmpty,
              buffer.count <= Self.maximumFrames * channelCount, buffer.count.isMultiple(of: channelCount) else { return false }
        let count = buffer.count, frames = count / channelCount
        memory.copyMemory(from: buffer.baseAddress!, byteCount: count * 4)
        for (index, sidechain) in sidechains.enumerated() {
            let target = memory.assumingMemoryBound(to: Float.self).advanced(by: Self.maximumFrames * (channelCount + index * 2))
            let external = UnsafeMutableBufferPointer(start: target, count: frames * 2)
            if let sidechain { sidechain.read(into: external, frames: frames) }
            else { target.update(repeating: 0, count: frames * 2) }
        }
        sequence &+= 1
        var request = (Self.protocolVersion, UInt32(frames), sequence, UInt32(reset ? 1 : 0))
        let sent = withUnsafeBytes(of: &request) { transfer(UnsafeMutableRawBufferPointer(mutating: $0), writing: true, deadline: deadline) }
        var reply = (UInt32(0), UInt32(0), UInt32(0), UInt32(0))
        let received = sent && withUnsafeMutableBytes(of: &reply) { transfer($0, writing: false, deadline: deadline) }
        guard received, reply.0 == Self.protocolVersion, reply.1 == 0, reply.2 == sequence else {
            fail(reply.1 == 3 ? "A plug-in produced invalid audio. Bypass the rack to continue safely." : "A plug-in crashed, stalled, or could not process audio. Bypass the rack to continue.")
            return false
        }
        buffer.baseAddress!.update(from: memory.assumingMemoryBound(to: Float.self), count: count)
        return true
    }

    func stop() { host?.stop() }
    func setSidechainsEnabled(_ enabled: Bool) { sidechains.forEach { $0?.setEnabled(enabled) } }

    private func transfer(_ buffer: UnsafeMutableRawBufferPointer, writing: Bool, deadline: UInt64) -> Bool {
        var offset = 0
        while offset < buffer.count {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            var descriptor = pollfd(fd: socketFD, events: Int16(writing ? POLLOUT : POLLIN), revents: 0)
            let remaining = Int32(max(1, (deadline - now + 999_999) / 1_000_000))
            let polled = Darwin.poll(&descriptor, 1, remaining)
            if polled < 0 && errno == EINTR { continue }
            guard polled > 0, descriptor.revents & Int16(POLLERR | POLLNVAL) == 0 else { return false }
            let pointer = buffer.baseAddress!.advanced(by: offset)
            let count = writing ? Darwin.write(socketFD, pointer, buffer.count - offset) : Darwin.read(socketFD, pointer, buffer.count - offset)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { return false }; offset += count
        }
        return true
    }

    private func fail(_ message: String) {
        state.lock(); let first = failure == nil; failure = failure ?? message; state.unlock()
        if first {
            host?.stop()
            eventHandler(["event": "fault", "message": message])
        }
    }
    private func retire() {
        host?.stop()
        if socketFD >= 0 { Darwin.shutdown(socketFD, SHUT_RDWR); Darwin.close(socketFD); socketFD = -1 }
        if listener >= 0 { Darwin.close(listener); listener = -1 }
        if let memory { munmap(memory, sharedBytes); self.memory = nil }
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { retire() }
}
