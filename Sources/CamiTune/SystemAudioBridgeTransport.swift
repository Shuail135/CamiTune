import Foundation
import CoreAudio
import SystemAudioBridgeC

final class SystemAudioBridgeTransport: ObservableObject, @unchecked Sendable {
    struct Statistics: Sendable {
        var bufferedFrames: UInt64 = 0
        var droppedFrames: UInt64 = 0
        var consumerOverrunCount: UInt64 = 0
        var starvationCount: UInt64 = 0
        var latestChannels: UInt32 = 0
        var latestChannelLayoutTag: UInt32 = 0
        var latestSampleRate: Double = 0
        var clientRegistryOverflowCount: UInt64 = 0
        var clientUseCountSaturationCount: UInt64 = 0
        var malformedPacketCount: UInt64 = 0
        var masterControlGeneration: UInt64 = 0
        var masterLinearGain: Float = 1
        var masterMuted = false
        var ringCapacityFrames: UInt32 = 0
        var rateAdjustmentPPM: Double = 0
        var rateMatchBufferedFrames: UInt64 = 0
    }

    @Published private(set) var status = "Driver transport idle"
    @Published private(set) var statistics = Statistics()
    @Published private(set) var runtimeError: String?

    private final class WeakOwner: @unchecked Sendable {
        weak var value: SystemAudioBridgeTransport?

        init(_ value: SystemAudioBridgeTransport) {
            self.value = value
        }
    }

    private final class RunContext: @unchecked Sendable {
        let transport: SABRClientTransportRef
        let deviceObjectID: AudioObjectID
        let controlDeviceObjectID: AudioObjectID
        let pcmRouter: PCMRouter
        let perAppAudio: PerAppAudioController
        let masterControlConsumer: @Sendable (Float, Bool) -> Void
        let expectedSampleRate: Double
        let channelCapacity: UInt32
        let generation: UInt64

        private let condition = NSCondition()
        private var stopRequested = false
        private var finished = false
        private var wakeDeadline: Date?
        private var wakeTimerFinished = false
        private var disconnectStatus: OSStatus = noErr

        init(
            transport: SABRClientTransportRef,
            deviceObjectID: AudioObjectID,
            controlDeviceObjectID: AudioObjectID,
            pcmRouter: PCMRouter,
            perAppAudio: PerAppAudioController,
            masterControlConsumer: @escaping @Sendable (Float, Bool) -> Void,
            expectedSampleRate: Double,
            channelCapacity: UInt32,
            generation: UInt64
        ) {
            self.transport = transport
            self.deviceObjectID = deviceObjectID
            self.controlDeviceObjectID = controlDeviceObjectID
            self.pcmRouter = pcmRouter
            self.perAppAudio = perAppAudio
            self.masterControlConsumer = masterControlConsumer
            self.expectedSampleRate = expectedSampleRate
            self.channelCapacity = channelCapacity
            self.generation = generation
        }

        func requestStop() {
            condition.lock()
            stopRequested = true
            condition.broadcast()
            condition.unlock()
            // Wake the packet reader if it is sleeping in sem_wait().
            sabr_client_transport_signal(transport)
        }

        func shouldStop() -> Bool {
            condition.lock()
            defer { condition.unlock() }
            return stopRequested
        }

        func finish(disconnectStatus: OSStatus) {
            condition.lock()
            self.disconnectStatus = disconnectStatus
            finished = true
            condition.broadcast()
            condition.unlock()
        }

        func scheduleWake(at deadline: Date) {
            condition.lock()
            wakeDeadline = deadline
            condition.broadcast()
            condition.unlock()
        }

        func runWakeTimer() {
            condition.lock()
            while !stopRequested {
                guard let deadline = wakeDeadline else {
                    condition.wait()
                    continue
                }
                if deadline <= Date() {
                    wakeDeadline = nil
                    condition.unlock()
                    sabr_client_transport_signal(transport)
                    condition.lock()
                } else {
                    _ = condition.wait(until: deadline)
                }
            }
            wakeTimerFinished = true
            condition.broadcast()
            condition.unlock()
        }

        func waitForWakeTimer() {
            condition.lock()
            while !wakeTimerFinished { condition.wait() }
            condition.unlock()
        }

        func waitUntilFinished(timeout: TimeInterval) -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeout)
            condition.lock()
            defer { condition.unlock() }
            while !finished {
                guard condition.wait(until: deadline) else { return finished }
            }
            return true
        }

        var completedDisconnectStatus: OSStatus? {
            condition.lock()
            defer { condition.unlock() }
            return finished ? disconnectStatus : nil
        }
    }

    private enum StopOutcome {
        case stopped(OSStatus)
        case timedOut
        case requestedOnWorker
    }

    private static let shutdownTimeout: TimeInterval = 2
    private let state = NSLock()
    private var context: RunContext?
    private var worker: Thread?
    private var generation: UInt64 = 0

    deinit {
        state.lock()
        generation &+= 1
        let context = self.context
        self.context = nil
        worker = nil
        state.unlock()
        // The worker owns and eventually destroys the mapped region. Deinit
        // only requests cancellation and therefore never blocks MainActor.
        context?.requestStop()
    }

    /// Starts a fresh driver transport without performing any lifecycle join,
    /// shared-memory setup, or Core Audio transaction on MainActor. The caller
    /// still awaits completion so route transitions remain serialized, but the
    /// SwiftUI run loop stays free while the blocking work executes.
    @MainActor
    func start(
        deviceObjectID: AudioObjectID,
        controlDeviceObjectID: AudioObjectID,
        expectedSampleRate: Double,
        pcmRouter: PCMRouter,
        perAppAudio: PerAppAudioController,
        masterControlConsumer: @escaping @Sendable (Float, Bool) -> Void
    ) async throws {
        let runGeneration = try await Task.detached(priority: .userInitiated) { [self] in
            try startSynchronously(
                deviceObjectID: deviceObjectID,
                controlDeviceObjectID: controlDeviceObjectID,
                expectedSampleRate: expectedSampleRate,
                pcmRouter: pcmRouter,
                perAppAudio: perAppAudio,
                masterControlConsumer: masterControlConsumer
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
        controlDeviceObjectID: AudioObjectID,
        expectedSampleRate: Double,
        pcmRouter: PCMRouter,
        perAppAudio: PerAppAudioController,
        masterControlConsumer: @escaping @Sendable (Float, Bool) -> Void
    ) throws -> UInt64 {
        switch stopSynchronously(updatePublishedState: false) {
        case .stopped(let status):
            guard status == noErr else { throw TransportError.disconnect(status) }
        case .timedOut, .requestedOnWorker:
            throw TransportError.shutdownTimedOut
        }
        guard sabr_client_transport_is_supported(deviceObjectID) else {
            throw TransportError.incompatibleDriver
        }
        let channelCapacity = sabr_client_transport_channel_count(deviceObjectID)
        guard channelCapacity > 0 else {
            throw TransportError.incompatibleDriver
        }
        guard let transport = sabr_client_transport_create(
            channelCapacity,
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
        generation &+= 1
        let runGeneration = generation
        let context = RunContext(
            transport: transport,
            deviceObjectID: deviceObjectID,
            controlDeviceObjectID: controlDeviceObjectID,
            pcmRouter: pcmRouter,
            perAppAudio: perAppAudio,
            masterControlConsumer: masterControlConsumer,
            expectedSampleRate: expectedSampleRate,
            channelCapacity: channelCapacity,
            generation: runGeneration
        )
        let owner = WeakOwner(self)
        let thread = Thread {
            Self.run(context: context, owner: owner)
        }
        thread.name = "System Audio Bridge Transport"
        thread.qualityOfService = .userInitiated
        self.context = context
        worker = thread
        state.unlock()

        thread.start()
        return runGeneration
    }

    func stop() {
        _ = stopSynchronously(updatePublishedState: true)
    }

    @discardableResult
    private func stopSynchronously(updatePublishedState: Bool) -> StopOutcome {
        state.lock()
        generation &+= 1
        let stoppedGeneration = generation
        let context = self.context
        let worker = self.worker
        state.unlock()

        guard let context else {
            if updatePublishedState { publishStopped(generation: stoppedGeneration) }
            return .stopped(noErr)
        }
        context.requestStop()

        // This is defensive even though the worker currently never calls the
        // lifecycle API. Waiting on itself would otherwise be an instant
        // deadlock if a future callback introduced that path.
        guard worker !== Thread.current else { return .requestedOnWorker }
        guard context.waitUntilFinished(timeout: Self.shutdownTimeout),
              let disconnectStatus = context.completedDisconnectStatus else {
            if updatePublishedState {
                publishShutdownTimeout(generation: stoppedGeneration)
            }
            return .timedOut
        }

        state.lock()
        if self.context === context {
            self.context = nil
            self.worker = nil
        }
        state.unlock()

        if updatePublishedState {
            if disconnectStatus == noErr {
                publishStopped(generation: stoppedGeneration)
            } else {
                publishDisconnectFailure(
                    disconnectStatus,
                    generation: stoppedGeneration
                )
            }
        }
        return .stopped(disconnectStatus)
    }

    /// Route shutdown can wait for an in-flight per-app mix to finish. Never
    /// make that join on MainActor, where it would freeze every SwiftUI window.
    func stopWithoutBlockingUI() async {
        await Task.detached(priority: .userInitiated) { [self] in
            stop()
        }.value
    }

    private static func run(context: RunContext, owner: WeakOwner) {
        let wakeTimer = Thread {
            context.runWakeTimer()
        }
        wakeTimer.name = "System Audio Bridge Deadline Timer"
        wakeTimer.qualityOfService = .utility
        wakeTimer.start()

        defer {
            context.requestStop()
            context.waitForWakeTimer()
            let disconnectStatus = disconnectWithRetry(
                context.transport,
                deviceObjectID: context.deviceObjectID
            )
            if disconnectStatus != noErr {
                NSLog(
                    "System Audio Bridge disconnect failed after three attempts (status %d)",
                    disconnectStatus
                )
            }
            sabr_client_transport_destroy(context.transport)
            context.finish(disconnectStatus: disconnectStatus)
        }

        // Accept every packet size the negotiated shared ring can legally
        // contain. A fixed 8,192-frame read ceiling left the consumer parked on
        // the same unread descriptor forever if HAL selected a larger IO block,
        // making an otherwise valid route produce no audio.
        let maximumFrames = sabr_client_transport_default_frame_capacity()
        let channelCapacity = context.channelCapacity
        var samples = [Float](
            repeating: 0,
            count: Int(maximumFrames * channelCapacity)
        )
        var nextStatisticsUpdate = Date(timeIntervalSinceNow: 0.5)
        var mixFlushDeadline: Date?
        var reportedSourceFormat: SpatialSourceFormat?
        var reportedUnsupportedLayoutTag: UInt32?
        var reportedUnsupportedChannelCount: UInt32?
        var reportedSampleRateMismatch: Double?
        var lastClientGeneration: UInt64 = .max
        var lastMasterControlGeneration: UInt64 = .max

        context.scheduleWake(at: nextStatisticsUpdate)
        while !context.shouldStop() {
            guard sabr_client_transport_wait_for_notification(context.transport) else {
                if context.shouldStop() { break }
                // A broken semaphore should not spin at audio priority. This
                // fallback is used only after the kernel wait itself fails.
                usleep(5_000)
                continue
            }
            if context.shouldStop() { break }
            let transport = context.transport

            // Volume changes do not wake this thread by themselves. During
            // playback the next PCM packet observes the lock-free latest-value
            // lane; while idle the existing maintenance wake catches up. This
            // keeps HAL property reads and physical-device writes completely
            // outside the media-key path.
            var masterControl = SABRClientControlState()
            if sabr_client_transport_copy_control_state(
                    context.transport,
                    &masterControl
                ),
               masterControl.deviceObjectID == context.controlDeviceObjectID,
               masterControl.generation != lastMasterControlGeneration {
                lastMasterControlGeneration = masterControl.generation
                context.masterControlConsumer(
                    masterControl.linearGain,
                    masterControl.muted.boolValue
                )
            }

            let clientGeneration = sabr_client_transport_client_generation(transport)
            if clientGeneration != UInt64.max,
               clientGeneration != lastClientGeneration,
               publishClients(transport, perAppAudio: context.perAppAudio) {
                lastClientGeneration = clientGeneration
            }

            var packet = SABRClientAudioPacketInfo()
            // Always ask the transport reader for the next *committed* packet.
            // `writePacket` is a reservation cursor and may run ahead of packet
            // commits when driver callbacks overlap; using it as a readiness
            // predicate can strand audio forever after one incomplete reservation.
            // The reader already implements the authoritative READY/CONSUMED
            // descriptor scan and safely returns 0 on timer/registry wakes.
            let frames: UInt32 = samples.withUnsafeMutableBufferPointer { buffer in
                sabr_client_transport_read_packet(
                    transport,
                    buffer.baseAddress,
                    channelCapacity,
                    maximumFrames,
                    &packet
                )
            }
            if frames == 0 {
                if let deadline = mixFlushDeadline, deadline <= Date() {
                    // More than one reordered cycle can become eligible on the
                    // same timer wake. Drain every expired cycle now so idle or
                    // short-lived clients cannot leave stale timeline audio
                    // parked until another unrelated packet arrives.
                    while true {
                        switch context.perAppAudio.flushExpiredMix() {
                        case .flushed(let mixed):
                            context.pcmRouter.route(mixed)
                            continue
                        case .retryAfter(let delay):
                            mixFlushDeadline = Date(timeIntervalSinceNow: delay)
                        case .idle:
                            mixFlushDeadline = nil
                        }
                        break
                    }
                }
            } else if let channelLayout = LPCMChannelLayout(
                coreAudioTag: packet.channelLayoutTag,
                channelCount: Int(packet.channelCount)
            ) {
                let hasSampleRateMismatch =
                    abs(packet.sampleRate - context.expectedSampleRate) >= 0.5
                if hasSampleRateMismatch {
                    let actualRate = packet.sampleRate
                    let requestedRate = context.expectedSampleRate
                    if reportedSampleRateMismatch != actualRate {
                        reportedSourceFormat = nil
                        reportedSampleRateMismatch = actualRate
                        let message = "System Audio Bridge is producing \(rateDescription(actualRate)), but CamillaDSP expects \(rateDescription(requestedRate)). Audio remains routed so meters and DSP stay live while the devices converge; a persistent mismatch can cause wrong-speed playback."
                        Task { @MainActor [owner] in
                            guard let target = owner.value,
                                  target.isCurrentGeneration(context.generation) else { return }
                            target.status = "Sample-rate mismatch — audio still routed"
                            target.runtimeError = message
                        }
                    }
                }
                let sampleCount = Int(frames * packet.channelCount)
                let metadata = PerAppAudioPacket(
                    deviceObjectID: packet.deviceObjectID,
                    clientID: packet.clientID,
                    cycleCounter: packet.cycleCounter,
                    sampleTime: packet.sampleTime,
                    interleaved: [],
                    channelCount: Int(packet.channelCount),
                    sampleRate: packet.sampleRate,
                    channelLayout: channelLayout,
                    // SABR per-client occupancy is not timeline latency and
                    // must never feed clock control. Keep these legacy metadata
                    // fields neutral; the writer's post-mix queue owns rate
                    // matching now.
                    sourceBufferedFrames: 0,
                    sourceCapacityFrames: Int(maximumFrames)
                )
                let mixed = samples.withUnsafeBufferPointer { buffer in
                    context.perAppAudio.ingestTransportPacket(
                        metadata,
                        samples: buffer,
                        sampleCount: sampleCount
                    )
                }
                if let mixed { context.pcmRouter.route(mixed) }
                let packetDuration = Double(frames) / packet.sampleRate
                mixFlushDeadline = Date(
                    timeIntervalSinceNow: max(0.003, packetDuration)
                )
                let sourceFormat = SpatialSourceFormat(layout: channelLayout)
                if !hasSampleRateMismatch, reportedSourceFormat != sourceFormat {
                    reportedSourceFormat = sourceFormat
                    reportedUnsupportedLayoutTag = nil
                    reportedUnsupportedChannelCount = nil
                    reportedSampleRateMismatch = nil
                    let formatName = sourceFormat.displayName
                    Task { @MainActor [owner] in
                        guard let target = owner.value,
                              target.isCurrentGeneration(context.generation) else { return }
                        target.status = "Streaming \(formatName) LPCM from System Audio Bridge"
                        target.runtimeError = nil
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
                    Task { @MainActor [owner] in
                        guard let target = owner.value,
                              target.isCurrentGeneration(context.generation) else { return }
                        target.status = "Unsupported \(channelCount)-channel LPCM layout (tag \(tag))"
                    }
                }
            }

            let now = Date()
            if now >= nextStatisticsUpdate {
                publishStatistics(context: context, owner: owner)
                nextStatisticsUpdate = Date(timeIntervalSinceNow: 0.5)
            }
            context.scheduleWake(at: min(mixFlushDeadline ?? .distantFuture, nextStatisticsUpdate))
        }
    }

    private static func disconnectWithRetry(
        _ transport: SABRClientTransportRef,
        deviceObjectID: AudioObjectID
    ) -> OSStatus {
        var status: OSStatus = noErr
        for attempt in 0..<3 {
            status = sabr_client_transport_disconnect(transport, deviceObjectID)
            if status == noErr { return noErr }
            if attempt < 2 { usleep(20_000) }
        }
        return status
    }

    private static func publishStatistics(context: RunContext, owner: WeakOwner) {
        var raw = SABRClientTransportStatistics()
        sabr_client_transport_get_statistics(context.transport, &raw)
        let rateMatching = context.pcmRouter.statistics
        let modularDistance = raw.writeFrame &- raw.readFrame
        let value = Statistics(
            bufferedFrames: modularDistance <= UInt64(raw.frameCapacity) ? modularDistance : 0,
            droppedFrames: raw.droppedFrames,
            consumerOverrunCount: raw.consumerOverrunCount,
            starvationCount: raw.starvationCount,
            latestChannels: raw.latestChannels,
            latestChannelLayoutTag: raw.latestChannelLayoutTag,
            latestSampleRate: raw.latestSampleRate,
            clientRegistryOverflowCount: raw.clientRegistryOverflowCount,
            clientUseCountSaturationCount: raw.clientUseCountSaturationCount,
            malformedPacketCount: raw.malformedPacketCount,
            masterControlGeneration: raw.controlGeneration,
            masterLinearGain: raw.controlLinearGain,
            masterMuted: raw.controlMuted != 0,
            ringCapacityFrames: raw.frameCapacity,
            rateAdjustmentPPM: rateMatching.rateAdjustmentPPM,
            rateMatchBufferedFrames: rateMatching.rateMatchBufferedFrames
        )
        Task { @MainActor [owner] in
            guard let target = owner.value,
                  target.isCurrentGeneration(context.generation) else { return }
            target.statistics = value
        }
    }

    private func isCurrentGeneration(_ candidate: UInt64) -> Bool {
        state.lock()
        defer { state.unlock() }
        return generation == candidate
    }

    @discardableResult
    private static func publishClients(
        _ transport: SABRClientTransportRef,
        perAppAudio: PerAppAudioController
    ) -> Bool {
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
        guard count != UInt32.max else { return false }
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
                deviceObjectID: raw.deviceObjectID,
                clientID: raw.clientID,
                processID: raw.processID,
                bundleID: bundleID,
                isActive: raw.isActive.boolValue,
                generation: raw.generation
            )
        }
        perAppAudio.updateClients(clients)
        return true
    }

    private func publishStopped(generation stoppedGeneration: UInt64) {
        Task { @MainActor [weak self] in
            guard self?.isCurrentGeneration(stoppedGeneration) == true else { return }
            self?.status = "Driver transport idle"
            self?.statistics = Statistics()
            self?.runtimeError = nil
        }
    }

    private func publishShutdownTimeout(generation stoppedGeneration: UInt64) {
        Task { @MainActor [weak self] in
            guard self?.isCurrentGeneration(stoppedGeneration) == true else { return }
            self?.status = "System Audio Bridge shutdown is still pending"
            self?.runtimeError = TransportError.shutdownTimedOut.localizedDescription
        }
    }

    private func publishDisconnectFailure(
        _ status: OSStatus,
        generation stoppedGeneration: UInt64
    ) {
        Task { @MainActor [weak self] in
            guard self?.isCurrentGeneration(stoppedGeneration) == true else { return }
            self?.status = "System Audio Bridge disconnect failed"
            self?.runtimeError = TransportError.disconnect(status).localizedDescription
        }
    }

    private static func rateDescription(_ rate: Double) -> String {
        String(format: "%.1f kHz", rate / 1_000)
    }

    enum TransportError: LocalizedError {
        case couldNotCreateSharedRegion
        case incompatibleDriver
        case coreAudio(OSStatus)
        case disconnect(OSStatus)
        case shutdownTimedOut

        var errorDescription: String? {
            switch self {
            case .couldNotCreateSharedRegion:
                return "CamiTune could not create the private driver audio transport."
            case .incompatibleDriver:
                return "The live System Audio Bridge driver does not support this SABR transport v5 ABI. Use Setup → Install / Repair Everything to install driver 0.7.8, then ensure coreaudiod reloads."
            case .disconnect(let status):
                return "System Audio Bridge did not acknowledge transport disconnect after three attempts (Core Audio \(Self.describe(status))). The worker released its local mapping safely; repair or reload the driver before starting another route."
            case .shutdownTimedOut:
                return "System Audio Bridge shutdown exceeded 2 seconds. Its worker still owns the mapped region and will release it when the in-flight audio operation returns."
            case .coreAudio(let status):
                if status == kAudioHardwareUnknownPropertyError ||
                    status == kAudioHardwareBadPropertySizeError {
                    return "The live System Audio Bridge driver is incompatible with this SABR transport v5 ABI (Core Audio \(Self.describe(status))). Use Setup → Install / Repair Everything to install driver 0.7.8 and reload coreaudiod."
                }
                if status == kAudioHardwareIllegalOperationError {
                    return "System Audio Bridge rejected transport authorization or shared-region validation (Core Audio \(Self.describe(status))). Install driver 0.7.8 with Setup → Install / Repair Everything and reload coreaudiod."
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
