import CamiTuneAudio
import CamiTuneDomain
import Foundation

/// Adjacent plug-ins with the same architecture share a helper. Crossing an
/// architecture boundary stays in the same audio block and shares one deadline.
final class PluginHostSession: PluginAudioProcessor, @unchecked Sendable {
    static let maximumFrames = PluginHostConnection.maximumFrames
    static let protocolVersion = PluginHostConnection.protocolVersion
    // The delivery worker measures processing load separately. Missing one
    // block's playback budget must not permanently retire a healthy helper:
    // editor activity and OS scheduling can briefly delay its reply. This is
    // a bounded hang watchdog, shared by every helper in the block, not added
    // playback latency; a completed reply returns immediately.
    private static let processingTimeoutNanoseconds: UInt64 = 100_000_000
    let sampleRate: Double
    private let blockFrames: Int
    let channelRoles: [ChannelRole]
    var channelCount: Int { channelRoles.count }
    private var connections: [PluginHostConnection] = []
    private let lock = NSLock()
    private var failure: String?
    private var timings: [Int: (latency: Int, tail: Double)] = [:]
    private let eventHandler: @Sendable ([String: Any]) -> Void
    var errorMessage: String? {
        lock.lock(); let result = failure; lock.unlock()
        return result ?? connections.compactMap(\.errorMessage).first
    }
    var latencyFrames: Int { connections.reduce(0) { $0 + $1.latencyFrames } }
    var tailFrames: Int { min(Int(sampleRate * 10), connections.reduce(0) { $0 + $1.tailFrames }) }
    var requiresContinuousRendering: Bool { errorMessage == nil && connections.contains { $0.requiresContinuousRendering } }
    func bufferChangeTailSeconds(sampleRate: Double) -> Double {
        guard !requiresContinuousRendering else { return .infinity }
        return connections.reduce(0) { $0 + $1.bufferChangeTailSeconds(sampleRate: sampleRate) }
    }

    init(rack: PluginRack, sampleRate: Double, channelRoles: [ChannelRole] = [.left, .right], editorOnly: Bool = false,
         blockFrames: Int = PluginHostConnection.maximumFrames,
         sidechainHub: PluginSidechainHub? = nil, eventHandler: @escaping @Sendable ([String: Any]) -> Void) throws {
        self.sampleRate = sampleRate; self.channelRoles = channelRoles; self.eventHandler = eventHandler
        self.blockFrames = min(Self.maximumFrames, max(32, blockFrames))
        try rack.validate()
        guard sampleRate.isFinite, (8000...384000).contains(sampleRate), (1...32).contains(channelRoles.count) else {
            throw PluginHostError(message: "The plug-in rack needs a supported sample rate and 1–32 channels.")
        }
        for (index, group) in PluginArchitecture.groups(for: rack.activeSlots).enumerated() {
            let connection = try PluginHostConnection(rack: .init(isEnabled: true, slots: group.slots, midi: rack.midi), sampleRate: sampleRate,
                channelRoles: channelRoles, editorOnly: editorOnly, architecture: group.architecture, sidechainHub: sidechainHub) { [weak self] event in
                    self?.receive(event, group: index, architecture: group.architecture)
                }
            connections.append(connection)
        }
    }
    private func receive(_ event: [String: Any], group: Int, architecture: PluginArchitecture) {
        let name = event["event"] as? String
        if name == "ready" || name == "latency" {
            lock.lock()
            timings[group] = (max(0, event["latencyFrames"] as? Int ?? 0), max(0, event["tailSeconds"] as? Double ?? 0))
            let latency = timings.values.reduce(0) { $0 + $1.latency }
            let tail = timings.values.reduce(0) { $0 + $1.tail }
            lock.unlock()
            var aggregate = event; aggregate["latencyFrames"] = latency; aggregate["tailSeconds"] = min(10, tail)
            aggregate["architecture"] = architecture.rawValue
            eventHandler(aggregate); return
        }
        if name == "fault" || name == "error" {
            lock.lock(); failure = failure ?? (event["message"] as? String ?? "A plug-in stopped responding."); lock.unlock()
        }
        eventHandler(event)
    }
    func openEditor(slotID: UUID) { connections.first { $0.slotIDs.contains(slotID) }?.openEditor(slotID: slotID) }
    func closeEditors() { connections.forEach { $0.closeEditors() } }
    func setSidechainsEnabled(_ enabled: Bool) { connections.forEach { $0.setSidechainsEnabled(enabled) } }
    func control(_ command: [String: Any]) {
        if let text = command["slotID"] as? String, let id = UUID(uuidString: text) {
            connections.first { $0.slotIDs.contains(id) }?.control(command)
        } else { connections.forEach { $0.control(command) } }
    }
    func configureMIDI(_ configuration: PluginMIDIConfiguration, enabled: Bool) {
        // Each helper applies mappings only to its own slots. Other instruments
        // still receive the original event, just as in a single native rack.
        connections.forEach { $0.configureMIDI(configuration, enabled: enabled) }
    }
    func snapshot(close: Bool) async -> [UUID: Data] {
        await withTaskGroup(of: [UUID: Data].self) { group in
            for connection in connections { group.addTask { await connection.snapshot(close: close) } }
            var result: [UUID: Data] = [:]
            for await states in group { result.merge(states) { _, new in new } }
            return result
        }
    }
    func process(_ samples: inout [Float], sampleRate: Double, reset: Bool) -> Bool {
        guard errorMessage == nil, sampleRate == self.sampleRate, samples.count.isMultiple(of: channelCount) else { return false }
        return samples.withUnsafeMutableBufferPointer { all in
            var offset = 0
            while offset < all.count {
                let count = min(blockFrames * channelCount, all.count - offset)
                let block = UnsafeMutableBufferPointer(rebasing: all[offset..<(offset + count)])
                let deadline = DispatchTime.now().uptimeNanoseconds + Self.processingTimeoutNanoseconds
                for connection in connections {
                    guard connection.processChunk(block, reset: reset && offset == 0, deadline: deadline) else {
                        connections.forEach { $0.stop() }; return false
                    }
                }
                offset += count
            }
            return true
        }
    }
}
