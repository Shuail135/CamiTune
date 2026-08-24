import Foundation
import CoreAudio
import SystemAudioBridgeC

final class SystemAudioBridgeTransport: ObservableObject, @unchecked Sendable {
    struct Statistics: Sendable {
        var bufferedFrames: UInt64 = 0
        var droppedFrames: UInt64 = 0
        var underrunCount: UInt64 = 0
        var activeChannels: UInt32 = 0
        var channelLayoutTag: UInt32 = 0
        var sampleRate: Double = 0
        var ringCapacityFrames: UInt32 = 0
        var rateAdjustmentPPM: Double = 0
        var rateMatchBufferedFrames: UInt64 = 0
    }

    @Published private(set) var status = "Driver transport idle"
    @Published private(set) var statistics = Statistics()
    @Published private(set) var runtimeError: String?

    private let state = NSCondition()
    private var transport: SABRClientTransportRef?
    private var deviceObjectID: AudioObjectID?
    private var worker: Thread?
    private var stopping = false
    private var workerFinished = true
    private var pcmRouter: PCMRouter?
    private var perAppAudio: PerAppAudioController?
    private var expectedSampleRate = 48_000.0
    private var generation: UInt64 = 0

    deinit { stop() }

    /// Starts a fresh driver transport without performing any lifecycle join,
    /// shared-memory setup, or Core Audio transaction on MainActor. The caller
    /// still awaits completion so route transitions remain serialized, but the
    /// SwiftUI run loop stays free while the blocking work executes.
    @MainActor
    func start(
        deviceObjectID: AudioObjectID,
        expectedSampleRate: Double,
        pcmRouter: PCMRouter,
        perAppAudio: PerAppAudioController
    ) async throws {
        let runGeneration = try await Task.detached(priority: .userInitiated) { [self] in
            try startSynchronously(
                deviceObjectID: deviceObjectID,
                expectedSampleRate: expectedSampleRate,
                pcmRouter: pcmRouter,
                perAppAudio: perAppAudio
            )
        }.value

        guard isCurrentGeneration(runGeneration) else { return }
        runtimeError = nil
        status = "Waiting for System Audio Bridge frames…"
    }

    /// Blocking lifecycle primitive used only from detached work or synchronous
    /// process teardown. Never call this directly from MainActor.
    private func startSynchronously(
        deviceObjectID: AudioObjectID,
        expectedSampleRate: Double,
        pcmRouter: PCMRouter,
        perAppAudio: PerAppAudioController
    ) throws -> UInt64 {
        stop()
        guard let transport = sabr_client_transport_create(
            sabr_client_transport_max_channels(),
            sabr_client_transport_default_frame_capacity()
        ) else {
            throw TransportError.couldNotCreateSharedRegion
        }

        let result = sabr_client_transport_connect(transport, deviceObjectID)
        guard result == noErr else {
            sabr_client_transport_destroy(transport)
            throw TransportError.coreAudio(result)
        }

        state.lock()
        self.transport = transport
        self.deviceObjectID = deviceObjectID
        self.pcmRouter = pcmRouter
        self.perAppAudio = perAppAudio
        self.expectedSampleRate = expectedSampleRate
        stopping = false
        workerFinished = false
        generation &+= 1
        let runGeneration = generation
        let thread = Thread { [weak self] in self?.run(generation: runGeneration) }
        thread.name = "System Audio Bridge Transport"
        thread.qualityOfService = .userInteractive
        worker = thread
        state.unlock()

        thread.start()
        return runGeneration
    }

    func stop() {
        state.lock()
        generation &+= 1
        let stoppedGeneration = generation
        stopping = true
        // Wait for the worker to release the mapped region before destroying
        // that region. The worker may be finishing an in-flight per-app mix, so
        // this blocking primitive must never be invoked directly by MainActor.
        // A timeout here could otherwise turn a slow shutdown into a
        // use-after-unmap crash.
        while !workerFinished { state.wait() }
        let transport = self.transport
        let deviceObjectID = self.deviceObjectID
        self.transport = nil
        self.deviceObjectID = nil
        self.pcmRouter = nil
        self.perAppAudio = nil
        worker = nil
        state.unlock()

        if let transport, let deviceObjectID {
            sabr_client_transport_disconnect(transport, deviceObjectID)
        }
        if let transport { sabr_client_transport_destroy(transport) }
        Task { @MainActor [weak self] in
            guard self?.isCurrentGeneration(stoppedGeneration) == true else { return }
            self?.status = "Driver transport idle"
            self?.statistics = Statistics()
            self?.runtimeError = nil
        }
    }

    /// Route shutdown can wait for an in-flight per-app mix to finish. Never
    /// make that join on MainActor, where it would freeze every SwiftUI window.
    func stopWithoutBlockingUI() async {
        await Task.detached(priority: .userInitiated) { [self] in
            stop()
        }.value
    }

    private func run(generation runGeneration: UInt64) {
        // Accept every packet size the negotiated shared ring can legally
        // contain. A fixed 8,192-frame read ceiling left the consumer parked on
        // the same unread descriptor forever if HAL selected a larger IO block,
        // making an otherwise valid route produce no audio.
        let maximumFrames = sabr_client_transport_default_frame_capacity()
        let channelCapacity = sabr_client_transport_max_channels()
        var samples = [Float](
            repeating: 0,
            count: Int(maximumFrames * channelCapacity)
        )
        var lastStatisticsUpdate = Date()
        var reportedSourceFormat: SpatialSourceFormat?
        var reportedUnsupportedLayoutTag: UInt32?
        var reportedUnsupportedChannelCount: UInt32?
        var reportedSampleRateMismatch: Double?
        var lastClientGeneration: UInt64 = .max

        while !shouldStop(generation: runGeneration) {
            guard let transport = currentTransport() else { break }
            var occupancy = SABRClientTransportStatistics()
            sabr_client_transport_get_statistics(transport, &occupancy)
            let availableFrames = occupancy.writeFrame >= occupancy.readFrame
                ? occupancy.writeFrame - occupancy.readFrame
                : 0
            let sourceBufferedFrames = Int(min(
                availableFrames,
                UInt64(occupancy.frameCapacity)
            ))
            if occupancy.clientGeneration != lastClientGeneration {
                publishClients(transport)
                lastClientGeneration = occupancy.clientGeneration
            }
            var packet = SABRClientAudioPacketInfo()
            let frames = samples.withUnsafeMutableBufferPointer { buffer in
                sabr_client_transport_read_packet(
                    transport,
                    buffer.baseAddress,
                    channelCapacity,
                    maximumFrames,
                    &packet
                )
            }
            if frames == 0 {
                if let mixed = currentPerAppAudio()?.flushExpiredMix() {
                    currentPCMRouter()?.route(mixed)
                }
                usleep(1_000)
            } else if let channelLayout = LPCMChannelLayout(
                coreAudioTag: packet.channelLayoutTag,
                channelCount: Int(packet.channelCount)
            ) {
                if abs(packet.sampleRate - expectedSampleRate) >= 0.5 {
                    let actualRate = packet.sampleRate
                    let requestedRate = expectedSampleRate
                    if reportedSampleRateMismatch != actualRate {
                        reportedSourceFormat = nil
                        reportedSampleRateMismatch = actualRate
                        let message = "System Audio Bridge is producing \(Self.rateDescription(actualRate)), but CamillaDSP expects \(Self.rateDescription(requestedRate)). Audio was stopped to prevent wrong-speed playback. Choose a rate supported by the physical output."
                        Task { @MainActor [weak self] in
                            guard self?.isCurrentGeneration(runGeneration) == true else { return }
                            self?.status = "Sample-rate mismatch"
                            self?.runtimeError = message
                        }
                    }
                    usleep(1_000)
                } else {
                    let sampleCount = Int(frames * packet.channelCount)
                    let interleaved = Array(samples.prefix(sampleCount))
                    let mixed = currentPerAppAudio()?.ingest(PerAppAudioPacket(
                        clientID: packet.clientID,
                        cycleCounter: packet.cycleCounter,
                        sampleTime: packet.sampleTime,
                        interleaved: interleaved,
                        channelCount: Int(packet.channelCount),
                        sampleRate: packet.sampleRate,
                        channelLayout: channelLayout,
                        sourceBufferedFrames: sourceBufferedFrames,
                        sourceCapacityFrames: Int(occupancy.frameCapacity)
                    ))
                    if let mixed { currentPCMRouter()?.route(mixed) }
                    let sourceFormat = SpatialSourceFormat(layout: channelLayout)
                    if reportedSourceFormat != sourceFormat {
                        reportedSourceFormat = sourceFormat
                        reportedUnsupportedLayoutTag = nil
                        reportedUnsupportedChannelCount = nil
                        reportedSampleRateMismatch = nil
                        let formatName = sourceFormat.displayName
                        Task { @MainActor [weak self] in
                            guard self?.isCurrentGeneration(runGeneration) == true else { return }
                            self?.status = "Streaming \(formatName) LPCM from System Audio Bridge"
                            self?.runtimeError = nil
                        }
                    }
                }
            } else {
                let tag = packet.channelLayoutTag
                let channelCount = packet.channelCount
                if reportedUnsupportedLayoutTag != tag ||
                    reportedUnsupportedChannelCount != channelCount {
                    reportedSourceFormat = nil
                    reportedUnsupportedLayoutTag = tag
                    reportedUnsupportedChannelCount = channelCount
                    Task { @MainActor [weak self] in
                        guard self?.isCurrentGeneration(runGeneration) == true else { return }
                        self?.status = "Unsupported \(channelCount)-channel LPCM layout (tag \(tag))"
                    }
                }
                usleep(1_000)
            }

            if Date().timeIntervalSince(lastStatisticsUpdate) >= 0.5 {
                publishStatistics(transport, generation: runGeneration)
                lastStatisticsUpdate = Date()
            }
        }

        state.lock()
        workerFinished = true
        state.broadcast()
        state.unlock()
    }

    private func publishStatistics(
        _ transport: SABRClientTransportRef,
        generation runGeneration: UInt64
    ) {
        var raw = SABRClientTransportStatistics()
        sabr_client_transport_get_statistics(transport, &raw)
        let rateMatching = currentPCMRouter()?.statistics
        let value = Statistics(
            bufferedFrames: raw.writeFrame >= raw.readFrame ? raw.writeFrame - raw.readFrame : 0,
            droppedFrames: raw.droppedFrames,
            underrunCount: raw.underrunCount,
            activeChannels: raw.activeChannels,
            channelLayoutTag: raw.activeChannelLayoutTag,
            sampleRate: raw.sampleRate,
            ringCapacityFrames: raw.frameCapacity,
            rateAdjustmentPPM: rateMatching?.rateAdjustmentPPM ?? 0,
            rateMatchBufferedFrames: rateMatching?.rateMatchBufferedFrames ?? 0
        )
        Task { @MainActor [weak self] in
            guard self?.isCurrentGeneration(runGeneration) == true else { return }
            self?.statistics = value
        }
    }

    private func shouldStop(generation runGeneration: UInt64) -> Bool {
        state.lock()
        defer { state.unlock() }
        return stopping || generation != runGeneration
    }

    private func isCurrentGeneration(_ candidate: UInt64) -> Bool {
        state.lock()
        defer { state.unlock() }
        return generation == candidate
    }

    private func currentTransport() -> SABRClientTransportRef? {
        state.lock()
        defer { state.unlock() }
        return transport
    }

    private func currentPCMRouter() -> PCMRouter? {
        state.lock()
        defer { state.unlock() }
        return pcmRouter
    }

    private func currentPerAppAudio() -> PerAppAudioController? {
        state.lock()
        defer { state.unlock() }
        return perAppAudio
    }

    private func publishClients(_ transport: SABRClientTransportRef) {
        let capacity = Int(sabr_client_transport_max_clients())
        var rawClients = [SABRClientIdentity](
            repeating: SABRClientIdentity(),
            count: capacity
        )
        let count = rawClients.withUnsafeMutableBufferPointer { buffer in
            sabr_client_transport_copy_clients(
                transport,
                buffer.baseAddress,
                UInt32(buffer.count)
            )
        }
        guard count != UInt32.max else { return }
        let clients = rawClients.prefix(Int(count)).map { raw -> PerAppDriverClient in
            var raw = raw
            let bundleID = withUnsafePointer(to: &raw.bundleID) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(SABR_CLIENT_BUNDLE_ID_CAPACITY)
                ) { characters -> String? in
                    let value = String(cString: characters)
                    return value.isEmpty ? nil : value
                }
            }
            return PerAppDriverClient(
                clientID: raw.clientID,
                processID: raw.processID,
                bundleID: bundleID,
                isActive: raw.isActive.boolValue,
                generation: raw.generation
            )
        }
        currentPerAppAudio()?.updateClients(clients)
    }

    private static func rateDescription(_ rate: Double) -> String {
        String(format: "%.1f kHz", rate / 1_000)
    }

    enum TransportError: LocalizedError {
        case couldNotCreateSharedRegion
        case coreAudio(OSStatus)

        var errorDescription: String? {
            switch self {
            case .couldNotCreateSharedRegion:
                return "CamiTune could not create the private driver audio transport."
            case .coreAudio(let status):
                if status == kAudioHardwareUnknownPropertyError {
                    return "The installed System Audio Bridge does not support this app's transport protocol (Core Audio \(Self.describe(status))). Use Setup → Install / Repair Everything to replace the driver."
                }
                return "System Audio Bridge rejected the transport connection (Core Audio \(Self.describe(status)))."
            }
        }

        private static func describe(_ status: OSStatus) -> String {
            let value = UInt32(bitPattern: status)
            let bytes = [
                UInt8((value >> 24) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8(value & 0xff)
            ]
            let printable = bytes.allSatisfy { (32...126).contains($0) }
            let fourCC = printable ? ", '\(String(decoding: bytes, as: UTF8.self))'" : ""
            return "\(status), 0x\(String(value, radix: 16, uppercase: true))\(fourCC)"
        }
    }
}
