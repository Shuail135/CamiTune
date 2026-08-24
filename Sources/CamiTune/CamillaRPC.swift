import Foundation

private final class CamillaRPCWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func markFired() {
        lock.lock()
        fired = true
        lock.unlock()
    }

    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}

actor CamillaRPC {
    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private let url: URL
    private var requestInProgress = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private let requestTimeout: Duration = .seconds(2.5)

    init(port: UInt16) {
        self.url = URL(string: "ws://127.0.0.1:\(port)")!
    }

    func connect() async throws {
        if task != nil { return }
        let socket = session.webSocketTask(with: url)
        socket.resume()
        task = socket
        do {
            _ = try await request("GetVersion")
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            task = nil
            throw error
        }
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    func request(_ payload: Any) async throws -> [String: Any] {
        // Actor isolation alone is not enough here: actors are reentrant at
        // every await. Keep each WebSocket send/receive pair together so a
        // meter poll cannot consume the response to a state or config command.
        await acquireRequestSlot()
        defer { releaseRequestSlot() }
        try Task.checkCancellation()
        guard let task else { throw RPCError.notConnected }
        // CamillaDSP uses both JSON objects (for commands with values) and
        // top-level JSON strings (for commands such as "GetVersion"). Without
        // fragmentsAllowed Foundation raises an Objective-C exception for the
        // latter, terminating the entire app instead of throwing a Swift error.
        guard JSONSerialization.isValidJSONObject(payload) || payload is String else {
            throw RPCError.invalidRequest
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        let text = String(decoding: data, as: UTF8.self)
        // Once a request is sent its matching reply must always be consumed.
        // UI debounce tasks are routinely cancelled; shield this exchange in
        // an independent task so cancellation cannot leave the next command to
        // consume the previous command's reply.
        let socket = task
        let exchange = Task {
            try await socket.send(.string(text))
            return try await socket.receive()
        }
        let watchdog = CamillaRPCWatchdog()
        let timeout = requestTimeout
        let watchdogTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            watchdog.markFired()
            // Cancelling the socket is intentional: a timed-out receive must
            // finish before the serial request slot is released, otherwise a
            // later command could consume this command's delayed reply.
            socket.cancel(with: .goingAway, reason: nil)
        }

        let message: URLSessionWebSocketTask.Message
        do {
            message = try await exchange.value
            watchdogTask.cancel()
            if watchdog.didFire {
                if self.task === socket { self.task = nil }
                throw RPCError.requestTimedOut
            }
        } catch {
            watchdogTask.cancel()
            if self.task === socket { self.task = nil }
            if watchdog.didFire { throw RPCError.requestTimedOut }
            throw error
        }
        let responseData: Data
        switch message {
        case .string(let value): responseData = Data(value.utf8)
        case .data(let value): responseData = value
        @unknown default: throw RPCError.invalidResponse("unsupported WebSocket message type")
        }
        guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw RPCError.invalidResponse("the reply was not a JSON command object")
        }
        return object
    }

    private func acquireRequestSlot() async {
        if !requestInProgress {
            requestInProgress = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            requestWaiters.append(continuation)
        }
    }

    private func releaseRequestSlot() {
        if requestWaiters.isEmpty {
            requestInProgress = false
        } else {
            requestWaiters.removeFirst().resume()
        }
    }

    func setConfig(yaml: String) async throws {
        let result = try await request(["SetConfig": yaml])
        try ensureOK(result, command: "SetConfig")
    }

    func patchConfig(_ patch: CamillaDSPRuntimePatch) async throws {
        let result = try await request(["PatchConfig": patch.foundationObject])
        try ensureOK(result, command: "PatchConfig")
    }

    func setVolume(_ db: Double) async throws {
        let result = try await request(["SetVolume": db])
        try ensureOK(result, command: "SetVolume")
    }

    func setMute(_ muted: Bool) async throws {
        let result = try await request(["SetMute": muted])
        try ensureOK(result, command: "SetMute")
    }

    func exit() async {
        _ = try? await request("Exit")
        disconnect()
    }

    func signalLevels() async throws -> SignalLevels {
        let response = try await request("GetSignalLevels")
        let command = try successfulBody(response, command: "GetSignalLevels")
        guard let value = command["value"] as? [String: Any] else {
            throw RPCError.invalidResponse("GetSignalLevels had no level data")
        }
        func doubles(_ any: Any?) -> [Double] {
            if let values = any as? [Double] { return values }
            if let values = any as? [NSNumber] { return values.map(\.doubleValue) }
            return []
        }
        return SignalLevels(
            capturePeak: doubles(value["capture_peak"]),
            captureRMS: doubles(value["capture_rms"]),
            playbackPeak: doubles(value["playback_peak"]),
            playbackRMS: doubles(value["playback_rms"])
        )
    }

    func state() async throws -> String {
        try await stringValue(command: "GetState")
    }

    func stopReason() async throws -> String {
        try await stringValue(command: "GetStopReason")
    }

    func processingLoad() async throws -> Double {
        try await doubleValue(command: "GetProcessingLoad")
    }

    func resamplerLoad() async throws -> Double {
        try await doubleValue(command: "GetResamplerLoad")
    }

    func bufferLevel() async throws -> UInt64 {
        try await unsignedIntegerValue(command: "GetBufferLevel")
    }

    func rateAdjust() async throws -> Double {
        try await doubleValue(command: "GetRateAdjust")
    }

    func clippedSamples() async throws -> UInt64 {
        try await unsignedIntegerValue(command: "GetClippedSamples")
    }

    func availablePlaybackDevices(backend: String) async throws -> [(identifier: String, name: String)] {
        let commandName = "GetAvailablePlaybackDevices"
        let response = try await request([commandName: backend])
        let command = try successfulBody(response, command: commandName)
        guard let values = command["value"] as? [[Any]] else {
            throw RPCError.invalidResponse("\(commandName) had no device list")
        }
        return values.compactMap { value in
            guard value.count == 2,
                  let identifier = value[0] as? String,
                  let name = value[1] as? String else { return nil }
            return (identifier, name)
        }
    }

    private func ensureOK(_ response: [String: Any], command: String) throws {
        _ = try successfulBody(response, command: command)
    }

    private func successfulBody(
        _ response: [String: Any],
        command: String
    ) throws -> [String: Any] {
        guard let body = response[command] as? [String: Any] else {
            throw RPCError.invalidResponse("expected a \(command) reply")
        }
        if String(describing: body["result"] ?? "") != "Ok" {
            throw RPCError.commandFailed(String(describing: body["result"] ?? command))
        }
        return body
    }

    private func stringValue(command: String) async throws -> String {
        let response = try await request(command)
        let body = try successfulBody(response, command: command)
        guard let value = body["value"] as? String else {
            throw RPCError.invalidResponse("\(command) had no string value")
        }
        return value
    }

    private func doubleValue(command: String) async throws -> Double {
        let response = try await request(command)
        let body = try successfulBody(response, command: command)
        guard let value = body["value"] as? NSNumber else {
            throw RPCError.invalidResponse("\(command) had no numeric value")
        }
        return value.doubleValue
    }

    private func unsignedIntegerValue(command: String) async throws -> UInt64 {
        let response = try await request(command)
        let body = try successfulBody(response, command: command)
        guard let value = body["value"] as? NSNumber, value.doubleValue >= 0 else {
            throw RPCError.invalidResponse("\(command) had no unsigned integer value")
        }
        return value.uint64Value
    }

    enum RPCError: LocalizedError {
        case notConnected
        case invalidRequest
        case requestTimedOut
        case invalidResponse(String)
        case commandFailed(String)
        var errorDescription: String? {
            switch self {
            case .notConnected: return "CamillaDSP websocket is not connected."
            case .invalidRequest: return "CamiTune attempted to send an invalid command to CamillaDSP."
            case .requestTimedOut: return "CamillaDSP did not answer the control request in time."
            case .invalidResponse(let detail): return "CamillaDSP returned an invalid response: \(detail)."
            case .commandFailed(let value): return "CamillaDSP command failed: \(value)"
            }
        }
    }
}

struct SignalLevels: Equatable, Sendable {
    var capturePeak: [Double]
    var captureRMS: [Double]
    var playbackPeak: [Double]
    var playbackRMS: [Double]

    static let silent = SignalLevels(
        capturePeak: [-150, -150],
        captureRMS: [-150, -150],
        playbackPeak: [-150, -150],
        playbackRMS: [-150, -150]
    )
}
