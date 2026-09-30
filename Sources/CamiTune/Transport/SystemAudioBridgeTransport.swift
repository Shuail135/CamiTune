import CamiTuneAudio
import CamiTuneDomain
import Foundation
import CoreAudio
import SystemAudioBridgeC

final class SystemAudioBridgeTransport: ObservableObject, @unchecked Sendable {
    static var maximumPacketFrameCapacity: Int { Int(sabr_client_transport_default_frame_capacity()) }

    struct Statistics: Sendable {
        var packetCount: UInt64 = 0
        var latestPacketFrames: UInt32 = 0
        var minimumPacketFrames: UInt32 = 0
        var maximumPacketFrames: UInt32 = 0
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
        var completion = ProducerCompletionStatistics()
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
        private let controlBindingLock = NSLock()
        private var storedControlDeviceObjectID: AudioObjectID
        var controlDeviceObjectID: AudioObjectID {
            controlBindingLock.lock(); defer { controlBindingLock.unlock() }
            return storedControlDeviceObjectID
        }
        func updateControlBinding(_ id: AudioObjectID, consumer: @escaping @Sendable (Float, Bool) -> Void) {
            controlBindingLock.lock(); storedControlDeviceObjectID = id; storedMasterControlConsumer = consumer; controlBindingLock.unlock()
        }
        let pcmRouter: PCMRouter
        let perAppAudio: PerAppAudioController
        private var storedMasterControlConsumer: @Sendable (Float, Bool) -> Void
        func consumeControl(_ control: SABRClientControlState) -> Bool {
            controlBindingLock.lock()
            let consumer = control.deviceObjectID == storedControlDeviceObjectID ? storedMasterControlConsumer : nil
            controlBindingLock.unlock()
            guard let consumer else { return false }
            consumer(control.linearGain, control.muted.boolValue)
            return true
        }
        let expectedSampleRate: Double
        let channelCapacity: UInt32
        let generation: UInt64
        // Reader-owned values; publication happens on this same worker.
        let capturesReservationEvidence = ProcessInfo.processInfo.environment["CAMITUNE_POLICY_TRACE_PATH"] != nil
        var packetCount: UInt64 = 0
        var latestPacketFrames: UInt32 = 0
        var minimumPacketFrames: UInt32 = 0
        var maximumPacketFrames: UInt32 = 0

        private let condition = NSCondition()
        private var stopRequested = false
        private var finished = false
        private var failed = false
        var didFail: Bool { condition.lock(); defer { condition.unlock() }; return failed }
        func markFailed() { condition.lock(); failed = true; condition.unlock() }
        let completion: ProducerCompletionAssembler
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
            self.storedControlDeviceObjectID = controlDeviceObjectID
            self.pcmRouter = pcmRouter
            self.perAppAudio = perAppAudio
            self.storedMasterControlConsumer = masterControlConsumer
            self.expectedSampleRate = expectedSampleRate
            self.channelCapacity = channelCapacity
            self.generation = generation
            self.completion = ProducerCompletionAssembler(generation: generation)
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
    func updateControlDeviceObjectID(_ objectID: AudioObjectID, consumer: @escaping @Sendable (Float, Bool) -> Void) {
        state.lock(); let current = context; state.unlock()
        current?.updateControlBinding(objectID, consumer: consumer)
    }
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
        let failed = state.withLock { context?.didFail ?? false }
        guard !failed else { return }
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
        var lastClientGeneration: UInt64 = .max
        var lastMasterControlGeneration: UInt64 = .max
#if DEBUG
        var loggedPacketIdentities = Set<String>()
#endif

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
            // keeps HAL property reads and physical-device writes off this PCM
            // thread. Hardware mirroring observes the virtual HAL control on
            // its own queue and does not replay this potentially older lane.
            var masterControl = SABRClientControlState()
            if sabr_client_transport_copy_control_state(
                    context.transport,
                    &masterControl
                ),
               masterControl.generation != lastMasterControlGeneration,
               context.consumeControl(masterControl) {
                lastMasterControlGeneration = masterControl.generation
            }

            let clientGeneration = sabr_client_transport_client_generation(transport)
            if clientGeneration != UInt64.max,
               clientGeneration != lastClientGeneration,
               publishClients(transport, perAppAudio: context.perAppAudio) {
                lastClientGeneration = clientGeneration
            }

            var packet = SABRClientAudioPacketInfo()
            let receivedRecord = samples.withUnsafeMutableBufferPointer { buffer in
                sabr_client_transport_read_event(transport, buffer.baseAddress, channelCapacity,
                    maximumFrames, &packet)
            }
            let tick = PerformanceClock.now()
            do {
                // A missing record cannot be repaired by sequencing later PCM.
                // Check even during continuous playback, before that gap fills
                // the assembler and hides the transport's actual failure.
                if sabr_client_transport_has_record_loss(transport) {
                    try context.completion.fail("the completion transport lost or rejected a record")
                }
                var completed: [ProducerCompletedInterval] = []
                if receivedRecord {
                    guard let kind = ProducerRecordKind(rawValue: packet.eventKind),
                          let layout = LPCMChannelLayout(coreAudioTag: packet.channelLayoutTag,
                            channelCount: Int(packet.channelCount)),
                          packet.sampleTime.isFinite, packet.sampleTime >= Double(Int64.min),
                          packet.sampleTime < Double(Int64.max), packet.sampleTime.rounded() == packet.sampleTime,
                          (kind == .end || kind == .fault || packet.timestampFlags & 1 != 0),
                          abs(packet.sampleRate - context.expectedSampleRate) < 0.5 else {
                        try context.completion.fail("invalid timestamp, format or source sample rate")
                    }
                    let frames = Int(packet.frameCount)
                    let isPCM = kind == .pcm
#if DEBUG
                    if isPCM, loggedPacketIdentities.count < 16 {
                        let signature = "\(packet.deviceObjectID):\(packet.clientID):\(packet.processID)"
                        if loggedPacketIdentities.insert(signature).inserted {
                            NSLog("[SABRIdentity] PCM device=%u client=%u pid=%d frames=%u",
                                packet.deviceObjectID, packet.clientID, packet.processID, packet.frameCount)
                        }
                    }
#endif
                    let sampleCount = isPCM ? frames * Int(packet.channelCount) : 0
                    guard sampleCount <= samples.count else { try context.completion.fail("source packet exceeds the negotiated storage") }
                    let performance = isPCM ? context.pcmRouter.performanceSource.snapshot() : nil
                    let trace = performance.flatMap { binding -> PacketPerformanceContext? in
                        guard let session = binding.sessionID else { return nil }
                        return .init(capture: binding.capture,
                            identity: .init(captureID: binding.capture.id, runtimeSessionID: session,
                                transportGeneration: context.generation, streamEpoch: packet.producerEpoch,
                                deviceObjectID: packet.deviceObjectID, startSampleTime: Int64(packet.sampleTime),
                                frameCount: frames, sampleRate: packet.sampleRate, channelCount: Int(packet.channelCount)),
                            received: tick)
                    }
                    let record = ProducerCompletionRecord(generation: context.generation,
                        sequence: packet.reservationSequence, epoch: packet.producerEpoch, kind: kind,
                        device: packet.deviceObjectID, client: packet.clientID, process: packet.processID,
                        cycle: packet.cycleCounter, start: Int64(packet.sampleTime), frames: frames,
                        channels: Int(packet.channelCount), layout: layout, rate: packet.sampleRate,
                        received: tick, samples: Array(samples.prefix(sampleCount)), performance: trace,
                        hostTime: packet.outputHostTime, timestampFlags: packet.timestampFlags)
                    completed = try context.completion.ingest(record)
                    if isPCM {
                        context.packetCount &+= 1
                        context.latestPacketFrames = packet.frameCount
                        context.minimumPacketFrames = context.minimumPacketFrames == 0 ? packet.frameCount : min(context.minimumPacketFrames, packet.frameCount)
                        context.maximumPacketFrames = max(context.maximumPacketFrames, packet.frameCount)
                    }
                } else {
                    // A missing/unready reservation is never a fence.
                    try context.completion.checkDeadline(at: tick)
                }
                for interval in completed {
                    if let clock = interval.clock { context.pcmRouter.observeSourceClock(clock) }
                    if interval.end > interval.start {
                        let frame = try context.perAppAudio.ingestCompletedInterval(interval)
                        context.pcmRouter.route(frame)
                    }
                    if interval.terminal { context.pcmRouter.finishProducerEpoch() }
                    let sourceFormat = SpatialSourceFormat(layout: interval.layout)
                    if reportedSourceFormat != sourceFormat {
                        reportedSourceFormat = sourceFormat
                        let formatName = sourceFormat.displayName
                        Task { @MainActor [owner] in
                            guard !context.didFail, let target = owner.value,
                                  target.isCurrentGeneration(context.generation) else { return }
                            target.status = "Streaming \(formatName) LPCM from System Audio Bridge"
                            target.runtimeError = nil
                        }
                    }
                }
                let scheduledAt = PerformanceClock.now()
                mixFlushDeadline = context.completion.nextDeadline.map { deadline in
                    Date(timeIntervalSinceNow: max(0, PerformanceClock.milliseconds(scheduledAt, deadline) / 1000))
                }
            } catch {
                context.markFailed()
                let failure = context.completion.latchFailure(error.localizedDescription)
                publishStatistics(context: context, owner: owner)
                let message = failure.localizedDescription
                NSLog("System Audio Bridge completion fault: %@", message)
                var failureStatistics = SABRClientTransportStatistics()
                sabr_client_transport_get_statistics(transport, &failureStatistics)
                NSLog("System Audio Bridge completion details: %@; dropped=%llu malformed=%llu overruns=%llu incoming=%llu kind=%u frames=%u rate=%.0f",
                    context.completion.diagnosticSummary, failureStatistics.droppedPackets,
                    failureStatistics.malformedPacketCount, failureStatistics.consumerOverrunCount,
                    packet.reservationSequence, packet.eventKind, packet.frameCount, packet.sampleRate)
                Task { @MainActor [owner] in
                    guard let target = owner.value, target.isCurrentGeneration(context.generation) else { return }
                    target.status = "Paused: producer completion failed"
                    target.runtimeError = message
                }
                // Reader-owned fault shutdown. The writer's existing bounded
                // stop drops queued PCM and DSP history; the runtime coordinator
                // observes runtimeError and restores the physical route.
                context.pcmRouter.stop()
                context.perAppAudio.resetRuntime()
                return
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
        var value = Statistics(
            packetCount: context.packetCount, latestPacketFrames: context.latestPacketFrames,
            minimumPacketFrames: context.minimumPacketFrames, maximumPacketFrames: context.maximumPacketFrames,
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
        value.completion = context.completion.statistics
        let snapshot = value
        Task { @MainActor [owner] in
            guard let target = owner.value,
                  target.isCurrentGeneration(context.generation) else { return }
            target.statistics = snapshot
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
#if DEBUG
        let roster = clients.map { "\($0.deviceObjectID):\($0.clientID):\($0.processID):\($0.isActive ? 1 : 0)" }
        NSLog("[SABRIdentity] roster generation=%llu count=%u entries=%@",
            sabr_client_transport_client_generation(transport), count, roster.joined(separator: ","))
#endif
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
                return "The live System Audio Bridge driver does not support this SABR transport v6 completion ABI. Use Setup → Install / Repair Everything to install driver 0.9.0, then ensure coreaudiod reloads."
            case .disconnect(let status):
                return "System Audio Bridge did not acknowledge transport disconnect after three attempts (Core Audio \(Self.describe(status))). The worker released its local mapping safely; repair or reload the driver before starting another route."
            case .shutdownTimedOut:
                return "System Audio Bridge shutdown exceeded 2 seconds. Its worker still owns the mapped region and will release it when the in-flight audio operation returns."
            case .coreAudio(let status):
                if status == SABR_TRANSPORT_PRODUCER_ACTIVE_ERROR {
                    return "System Audio Bridge is still processing an earlier audio session. Pause applications using the bridge, then restart CamiTune audio. The connection was refused because earlier contributions could be missing."
                }
                if status == kAudioHardwareUnknownPropertyError ||
                    status == kAudioHardwareBadPropertySizeError {
                    return "The live System Audio Bridge driver is incompatible with this SABR transport v6 completion ABI (Core Audio \(Self.describe(status))). Use Setup → Install / Repair Everything to install driver 0.9.0 and reload coreaudiod."
                }
                if status == kAudioHardwareIllegalOperationError {
                    return "System Audio Bridge rejected transport authorization or shared-region validation (Core Audio \(Self.describe(status))). Install driver 0.9.0 with Setup → Install / Repair Everything and reload coreaudiod."
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
