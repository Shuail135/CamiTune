import CamiTuneAudio
import Combine
import Foundation

struct PCMLevelSnapshot: Equatable, Sendable {
    var peak: [Double]
    var rms: [Double]
    var clippedSamples: UInt64
    var clippedSamplesByChannel: [UInt64]

    static let silent = PCMLevelSnapshot(
        peak: [-150, -150],
        rms: [-150, -150],
        clippedSamples: 0,
        clippedSamplesByChannel: [0, 0]
    )

    static func measure(_ frame: PCMFrame) -> PCMLevelSnapshot {
        guard frame.channelCount > 0, frame.frameCount > 0 else { return .silent }
        var peaks = [Double](repeating: 0, count: frame.channelCount)
        var sums = [Double](repeating: 0, count: frame.channelCount)
        var clipped: UInt64 = 0
        var clippedByChannel = [UInt64](repeating: 0, count: frame.channelCount)

        for (sampleIndex, rawSample) in frame.interleaved.enumerated() {
            let sample = Double(rawSample)
            guard sample.isFinite else { continue }
            let channel = sampleIndex % frame.channelCount
            let magnitude = abs(sample)
            peaks[channel] = max(peaks[channel], magnitude)
            sums[channel] += sample * sample
            if magnitude >= 1 {
                clipped &+= 1
                clippedByChannel[channel] &+= 1
            }
        }

        return PCMLevelSnapshot(
            peak: peaks.map(decibels),
            rms: sums.map { decibels(sqrt($0 / Double(frame.frameCount))) },
            clippedSamples: clipped,
            clippedSamplesByChannel: clippedByChannel
        )
    }

    private static func decibels(_ amplitude: Double) -> Double {
        guard amplitude > 0 else { return -150 }
        return max(-150, 20 * log10(amplitude))
    }
}

struct AudioRouteDiagnostics: Equatable, Sendable {
    var transit: PCMTransitObservation?
    var pcmQueue = PCMQueueSnapshot()
    var bridgePacketCount: UInt64 = 0
    var bridgeLatestPacketFrames: UInt32 = 0
    var bridgeMinimumPacketFrames: UInt32 = 0
    var bridgeMaximumPacketFrames: UInt32 = 0
    var bridgeBufferedFrames: UInt64 = 0
    var bridgeCapacityFrames: UInt64 = 0
    var bridgeDroppedFrames: UInt64 = 0
    var bridgeConsumerOverrunCount: UInt64 = 0
    var bridgeStarvationCount: UInt64 = 0
    var bridgeClientRegistryOverflowCount: UInt64 = 0
    var bridgeClientUseCountSaturationCount: UInt64 = 0
    var bridgeMalformedPacketCount: UInt64 = 0
    var sampleRate: Double = 0
    var activeChannels: UInt32 = 0
    var rateAdjustmentPPM: Double = 0
    var rateMatchBufferedFrames: UInt64 = 0
    var camillaDroppedFrames: UInt64 = 0
    var camillaQueueRecoveries: UInt64 = 0
    var camillaWriteFailures: UInt64 = 0
    var meterDroppedFrames: UInt64 = 0
    var rejectedSourceFrames: UInt64 = 0
    var sourceFormatError: String?
    var deliveryError: String?

    init() {}

    init(
        transport: SystemAudioBridgeTransport.Statistics,
        router: PCMRouter.Statistics
    ) {
        transit = router.transit
        pcmQueue = router.camillaQueue
        bridgePacketCount = transport.packetCount
        bridgeLatestPacketFrames = transport.latestPacketFrames
        bridgeMinimumPacketFrames = transport.minimumPacketFrames
        bridgeMaximumPacketFrames = transport.maximumPacketFrames
        bridgeBufferedFrames = transport.bufferedFrames
        bridgeCapacityFrames = UInt64(transport.ringCapacityFrames)
        bridgeDroppedFrames = transport.droppedFrames
        bridgeConsumerOverrunCount = transport.consumerOverrunCount
        bridgeStarvationCount = transport.starvationCount
        bridgeClientRegistryOverflowCount = transport.clientRegistryOverflowCount
        bridgeClientUseCountSaturationCount = transport.clientUseCountSaturationCount
        bridgeMalformedPacketCount = transport.malformedPacketCount
        sampleRate = transport.latestSampleRate
        activeChannels = transport.latestChannels
        rateAdjustmentPPM = transport.rateAdjustmentPPM
        rateMatchBufferedFrames = transport.rateMatchBufferedFrames
        camillaDroppedFrames = router.camillaDroppedFrames
        camillaQueueRecoveries = router.camillaQueueRecoveries
        camillaWriteFailures = router.camillaWriteFailures
        meterDroppedFrames = router.meterDroppedFrames
        rejectedSourceFrames = router.rejectedSourceFrames
        sourceFormatError = router.sourceFormatError
        deliveryError = router.deliveryError
    }

    var bridgeFillRatio: Double? {
        guard bridgeCapacityFrames > 0 else { return nil }
        return min(1, max(0, Double(bridgeBufferedFrames) / Double(bridgeCapacityFrames)))
    }
}

enum AudioRuntimeHealth: Equatable, Sendable {
    case inactive
    case healthy
    case warning
    case fault
}

/// Stable, typed causes retain their observed values for UI and report consumers.
enum AudioRuntimeHealthReason: Sendable, Equatable {
    case runtimeInactive, engineUnavailable, engineStalled
    case engineStopped(String), transportFailure(String), sourceFormatError(String)
    case pcmDeliveryFailure(String)
    case recentClipping, processingOverload(Double)
    case bridgeDroppedFrames(UInt64), bridgeOverruns(UInt64)
    case clientRegistryOverflows(UInt64), clientUseCountSaturations(UInt64)
    case malformedPackets(UInt64), pcmDroppedFrames(UInt64)
    case pcmQueueRecoveries(UInt64), pcmWriteFailures(UInt64), rejectedSourceFrames(UInt64)
    case telemetryPaused, telemetryPending, telemetryStale, telemetryUnavailable
    case telemetryRPCFailed(String)

    var health: AudioRuntimeHealth {
        switch self {
        case .runtimeInactive, .telemetryPaused: return .inactive
        case .engineUnavailable, .engineStalled, .engineStopped, .transportFailure,
             .sourceFormatError, .pcmWriteFailures, .pcmDeliveryFailure: return .fault
        default: return .warning
        }
    }

    var summary: String {
        switch self {
        case .runtimeInactive: return "Audio processing is inactive."
        case .engineUnavailable: return "The audio output engine is not running."
        case .engineStalled: return "The audio output engine has stalled."
        case .engineStopped(let reason): return "Audio output stopped: \(reason)."
        case .transportFailure(let error): return "Driver transport error: \(error)"
        case .sourceFormatError(let error): return "Source format error: \(error)"
        case .recentClipping: return "Final output clipping was detected recently."
        case .processingOverload(let percent): return String(format: "Audio processing load is %.1f%% (warning threshold: 85%%).", percent)
        case .bridgeDroppedFrames(let count): return "Bridge dropped frames: \(count)."
        case .bridgeOverruns(let count): return "Bridge consumer overruns: \(count)."
        case .clientRegistryOverflows(let count): return "Bridge client registry overflows: \(count)."
        case .clientUseCountSaturations(let count): return "Bridge client use-count saturations: \(count)."
        case .malformedPackets(let count): return "Malformed bridge packets: \(count)."
        case .pcmDroppedFrames(let count): return "PCM writer dropped frames: \(count)."
        case .pcmQueueRecoveries(let count): return "PCM queue recoveries: \(count)."
        case .pcmWriteFailures(let count): return "PCM write failures: \(count)."
        case .pcmDeliveryFailure(let error): return error
        case .rejectedSourceFrames(let count): return "Rejected source frames: \(count)."
        case .telemetryPaused: return "Audio telemetry polling is paused while the profile monitor is not visible."
        case .telemetryPending: return "Waiting for the first output status update."
        case .telemetryStale: return "The last output status update is more than 2.5 seconds old."
        case .telemetryUnavailable: return "Output status is unavailable."
        case .telemetryRPCFailed(let error): return "Output status update failed: \(error)"
        }
    }
}

struct AudioRuntimeHealthAssessment: Sendable, Equatable {
    let health: AudioRuntimeHealth
    let reasons: [AudioRuntimeHealthReason]

    init(reasons: [AudioRuntimeHealthReason]) {
        self.reasons = reasons
        if reasons.contains(where: { $0.health == .fault }) { health = .fault }
        else if reasons.contains(where: { $0.health == .warning }) { health = .warning }
        else if reasons.contains(where: { $0.health == .inactive }) { health = .inactive }
        else { health = .healthy }
    }

    var explanation: String { reasons.map(\.summary).joined(separator: " ") }
}

private final class RuntimePresentationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var profileID: UUID?
    private var nextSampleUptime = 0.0
    private var pendingSnapshot: PCMLevelSnapshot?
    private var deliveryScheduled = false
    private var generation: UInt64 = 0

    /// PCM meters are presentation data, not part of the audio route. Sampling
    /// them at display cadence avoids scanning every audio packet and, more
    /// importantly, prevents audio-rate work from being queued on MainActor.
    private let sampleInterval = 0.1

    func setProfileID(_ profileID: UUID?) {
        lock.lock()
        self.profileID = profileID
        nextSampleUptime = 0
        pendingSnapshot = nil
        deliveryScheduled = false
        generation &+= 1
        lock.unlock()
    }

    func isPresented(profileID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.profileID == profileID
    }

    func beginSample(profileID: UUID, uptime: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.profileID == profileID, uptime >= nextSampleUptime else {
            return false
        }
        nextSampleUptime = uptime + sampleInterval
        return true
    }

    func submit(
        _ snapshot: PCMLevelSnapshot,
        profileID: UUID,
        deliver: @escaping @MainActor (PCMLevelSnapshot) -> Void
    ) {
        lock.lock()
        guard self.profileID == profileID else {
            lock.unlock()
            return
        }
        pendingSnapshot = snapshot
        guard !deliveryScheduled else {
            lock.unlock()
            return
        }
        deliveryScheduled = true
        let deliveryGeneration = generation
        lock.unlock()

        // Keep at most one delivery in the main queue. If AppKit is busy with
        // scrolling or layout, newer audio replaces the stale observation.
        Task { @MainActor [weak self] in
            guard let snapshot = self?.takePending(
                profileID: profileID,
                generation: deliveryGeneration
            ) else { return }
            deliver(snapshot)
        }
    }

    private func takePending(
        profileID: UUID,
        generation: UInt64
    ) -> PCMLevelSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation, self.profileID == profileID else {
            return nil
        }
        let snapshot = pendingSnapshot
        pendingSnapshot = nil
        deliveryScheduled = false
        return snapshot
    }
}

struct AudioAddedDelayEstimate: Equatable, Sendable {
    let appMilliseconds: Double
    let processingMilliseconds: Double
    let playbackMilliseconds: Double

    var milliseconds: Double {
        appMilliseconds + processingMilliseconds + playbackMilliseconds
    }
}

/// Shared output observations. Backend adapters supply measurements without
/// making the monitor depend on their RPC or hardware diagnostic formats.
struct AudioOutputTelemetry: Sendable {
    var backend: String
    var engineState: String
    var stopReason: String = "None"
    var processingLoadPercent: Double? = nil
    var resamplerLoadPercent: Double? = nil
    var bufferLevelFrames: UInt64
    var rateAdjustment: Double = 1
    var clippedSamples: UInt64
    var sampleRate: Double?
    var blockFrames: Int?
    var processingBufferFrames: Int?
    var underrunFrames: UInt64? = nil
}

struct AudioLatencyComponents: Equatable {
    var appMilliseconds: Double?
    var processingMilliseconds: Double?
    var playbackMilliseconds: Double?

    var estimate: AudioAddedDelayEstimate? {
        guard let appMilliseconds, let processingMilliseconds, let playbackMilliseconds else { return nil }
        return .init(appMilliseconds: appMilliseconds, processingMilliseconds: processingMilliseconds,
            playbackMilliseconds: playbackMilliseconds)
    }
}

struct AudioRuntimeStatus: Equatable, Sendable {
    var outputBackend = "—"
    var outputUnderrunFrames: UInt64?
    var isActive = false
    var engineIsRunning: Bool?
    var transportError: String?
    var engineState = "Inactive"
    var stopReason = "None"
    var processingLoadPercent: Double?
    var resamplerLoadPercent: Double?
    var outputBufferedFrames: UInt64 = 0
    var outputSampleRate: Double?
    var outputBlockFrames: Int?
    var processingBufferFrames: Int?
    var outputRateAdjustment = 1.0
    var outputClippedSamples: UInt64 = 0
    /// Source samples at or above full scale; this does not prove output clipping.
    var sourceClippedSamples: UInt64 = 0
    /// Final playback peaks and the backend clip counter only, never source peaks.
    var clippingIsRecent = false
    var telemetryAvailable = false
    var telemetryPollingActive = false
    var lastTelemetryUpdatedAt: Date?
    var lastTelemetryError: String?
    var route = AudioRouteDiagnostics()
    var lastUpdated: Date?

    static let inactive = AudioRuntimeStatus()

    /// Estimated extra transit and buffering versus direct playback through the
    /// same output device at the same rate and I/O buffer size. Shared device,
    /// stream, safety and hardware-buffer delay cancels out of that comparison.
    /// This is not a measured bypass comparison and does not account for every
    /// effect's algorithmic delay. Transit already includes
    /// producer completion, per-app processing, the writer queue and rendering:
    /// adding queue occupancy here would count those stages twice. The raw
    /// bridge ring stores overlapping client blocks and is not timeline delay.
    func addedDelayEstimate(at now: Date = Date(), tick: PerformanceTick = PerformanceClock.now()) -> AudioAddedDelayEstimate? {
        latencyComponents(at: now, tick: tick).estimate
    }

    func latencyComponents(at now: Date = Date(), tick: PerformanceTick = PerformanceClock.now()) -> AudioLatencyComponents {
        var result = AudioLatencyComponents()
        guard isActive, hasFreshTelemetry(at: now), engineState == "Running",
              engineIsRunning != false, transportError == nil,
              route.deliveryError == nil, route.sourceFormatError == nil,
              let rate = outputSampleRate, rate.isFinite, rate > 0,
              let block = outputBlockFrames, block > 0 else { return result }
        if let frames = processingBufferFrames, frames >= 0 {
            result.processingMilliseconds = Double(frames) * 1_000 / rate
        }
        result.playbackMilliseconds = Double(outputBufferedFrames) * 1_000 / rate
        // Transit is wall-clock time, independent of input/output sample rates.
        // It also exists for locally generated instrument audio with no bridge.
        if let transit = route.transit, tick >= transit.completedAt,
           PerformanceClock.milliseconds(transit.completedAt, tick) <= 2_500,
           transit.milliseconds.isFinite, transit.milliseconds >= 0 {
            result.appMilliseconds = transit.milliseconds
        }
        return result
    }

    var effectiveRateAdjustmentPPM: Double {
        if abs(route.rateAdjustmentPPM) >= 0.005 { return route.rateAdjustmentPPM }
        // CamillaDSP reports an adjustment ratio (1.0 means unchanged).
        guard hasFreshTelemetry(), outputRateAdjustment.isFinite, outputRateAdjustment > 0 else { return 0 }
        return (outputRateAdjustment - 1) * 1_000_000
    }

    /// Audio delivery and telemetry observability are independent assessments.
    var health: AudioRuntimeHealth { pipelineAssessment().health }

    func hasFreshTelemetry(at now: Date = Date()) -> Bool {
        guard telemetryPollingActive, telemetryAvailable, let lastTelemetryUpdatedAt else { return false }
        return now.timeIntervalSince(lastTelemetryUpdatedAt) <= 2.5
    }

    func pipelineAssessment(at now: Date = Date()) -> AudioRuntimeHealthAssessment {
        guard isActive else { return .init(reasons: [.runtimeInactive]) }
        var reasons: [AudioRuntimeHealthReason] = []
        if engineIsRunning == false { reasons.append(.engineUnavailable) }
        if let transportError { reasons.append(.transportFailure(transportError)) }
        if let error = route.sourceFormatError { reasons.append(.sourceFormatError(error)) }
        // Cached output state/load must not masquerade as a current pipeline fault.
        if hasFreshTelemetry(at: now) {
            if engineState.lowercased() == "stalled" { reasons.append(.engineStalled) }
            if !["none", "done"].contains(stopReason.lowercased()) { reasons.append(.engineStopped(stopReason)) }
            if let load = processingLoadPercent, load >= 85 { reasons.append(.processingOverload(load)) }
        }
        if clippingIsRecent { reasons.append(.recentClipping) }
        if route.bridgeDroppedFrames > 0 { reasons.append(.bridgeDroppedFrames(route.bridgeDroppedFrames)) }
        if route.bridgeConsumerOverrunCount > 0 { reasons.append(.bridgeOverruns(route.bridgeConsumerOverrunCount)) }
        if route.bridgeClientRegistryOverflowCount > 0 { reasons.append(.clientRegistryOverflows(route.bridgeClientRegistryOverflowCount)) }
        if route.bridgeClientUseCountSaturationCount > 0 { reasons.append(.clientUseCountSaturations(route.bridgeClientUseCountSaturationCount)) }
        if route.bridgeMalformedPacketCount > 0 { reasons.append(.malformedPackets(route.bridgeMalformedPacketCount)) }
        if route.camillaDroppedFrames > 0 { reasons.append(.pcmDroppedFrames(route.camillaDroppedFrames)) }
        if route.camillaQueueRecoveries > 0 { reasons.append(.pcmQueueRecoveries(route.camillaQueueRecoveries)) }
        if route.camillaWriteFailures > 0 { reasons.append(.pcmWriteFailures(route.camillaWriteFailures)) }
        if let error = route.deliveryError { reasons.append(.pcmDeliveryFailure(error)) }
        if route.rejectedSourceFrames > 0 { reasons.append(.rejectedSourceFrames(route.rejectedSourceFrames)) }
        return .init(reasons: reasons)
    }

    func telemetryAssessment(at now: Date = Date()) -> AudioRuntimeHealthAssessment {
        guard isActive else { return .init(reasons: [.runtimeInactive]) }
        guard telemetryPollingActive else { return .init(reasons: [.telemetryPaused]) }
        var reasons: [AudioRuntimeHealthReason] = []
        if let lastTelemetryError { reasons.append(.telemetryRPCFailed(lastTelemetryError)) }
        if let lastTelemetryUpdatedAt, now.timeIntervalSince(lastTelemetryUpdatedAt) > 2.5 {
            reasons.append(.telemetryStale)
        } else if !telemetryAvailable {
            if lastTelemetryError == nil {
                reasons.append(lastTelemetryUpdatedAt == nil ? .telemetryPending : .telemetryUnavailable)
            }
        } else if lastTelemetryUpdatedAt == nil {
            reasons.append(.telemetryUnavailable)
        }
        return .init(reasons: reasons)
    }

    mutating func recordTelemetryFailure(_ message: String, at now: Date) {
        lastTelemetryError = message
        if lastTelemetryUpdatedAt.map({ now.timeIntervalSince($0) > 2.5 }) ?? true {
            telemetryAvailable = false
        }
    }

    mutating func recordTelemetry(_ diagnostics: AudioOutputTelemetry, at now: Date) {
        outputBackend = diagnostics.backend
        engineState = diagnostics.engineState
        stopReason = diagnostics.stopReason
        processingLoadPercent = diagnostics.processingLoadPercent
        resamplerLoadPercent = diagnostics.resamplerLoadPercent
        outputBufferedFrames = diagnostics.bufferLevelFrames
        outputSampleRate = diagnostics.sampleRate
        outputBlockFrames = diagnostics.blockFrames
        processingBufferFrames = diagnostics.processingBufferFrames
        outputUnderrunFrames = diagnostics.underrunFrames
        outputRateAdjustment = diagnostics.rateAdjustment
        outputClippedSamples = diagnostics.clippedSamples
        telemetryAvailable = true
        lastTelemetryUpdatedAt = now
        lastTelemetryError = nil
    }

}

/// Owns read-only runtime observations. It deliberately does not mutate the
/// processing graph, reset clipping counters, or control transport lifetime.
@MainActor
final class AudioRuntimeMonitor: ObservableObject {
    typealias RouteDiagnosticsProvider = @MainActor () -> AudioRouteDiagnostics

    @Published private(set) var activeSession: AudioRuntimeSession?
    @Published private(set) var levels = SignalLevels.silent
    @Published private(set) var status = AudioRuntimeStatus.inactive

    var capturePeak: [Double] { levels.capturePeak }
    var captureRMS: [Double] { levels.captureRMS }
    var playbackPeak: [Double] { levels.playbackPeak }
    var playbackRMS: [Double] { levels.playbackRMS }

#if DEBUG
    /// Silent setup preview only: no polling tasks or audio device lifecycle.
    func setPreviewLevels(_ levels: SignalLevels, profileID: UUID) {
        if activeSession?.profileID != profileID { activeSession = AudioRuntimeSession(profileID: profileID) }
        self.levels = levels
    }
#endif

    private var meterPollingTask: Task<Void, Never>?
    private var diagnosticsPollingTask: Task<Void, Never>?
    private var controller: CamillaDSPController?
    private var directOutput: DirectCoreAudioOutput?
    private var routeDiagnosticsProvider: RouteDiagnosticsProvider?
    private var presentedProfileID: UUID?
    private let presentationGate = RuntimePresentationGate()
    private var hasReceivedOutputLevels = false
    private var lastInputLevelsAt: Date?
    private var lastOutputClippedSamples: UInt64 = 0
    private var lastClipAt: Date?
    private var lastChannelClipAt: [Int: Date] = [:]

    func channelClippingIsRecent(_ channelIndex: Int, now: Date = Date()) -> Bool {
        lastChannelClipAt[channelIndex].map { now.timeIntervalSince($0) < 2 } ?? false
    }

    func start(
        controller: CamillaDSPController?,
        session: AudioRuntimeSession,
        directOutput: DirectCoreAudioOutput? = nil,
        routeDiagnosticsProvider: @escaping RouteDiagnosticsProvider
    ) {
        stop()
        activeSession = session
        self.controller = controller
        self.directOutput = directOutput
        self.routeDiagnosticsProvider = routeDiagnosticsProvider
        status.isActive = true
        status.engineState = "Starting"
        presentationGate.setProfileID(presentedProfileID)
        updatePolling()
    }

    func setPresentationActive(_ active: Bool, profileID: UUID) {
        let previous = presentedProfileID
        if active {
            presentedProfileID = profileID
        } else if presentedProfileID == profileID {
            presentedProfileID = nil
        }
        guard previous != presentedProfileID else { return }
        presentationGate.setProfileID(presentedProfileID)
        resetObservationState()
        updatePolling()
    }

    private func updatePolling() {
        meterPollingTask?.cancel()
        diagnosticsPollingTask?.cancel()
        meterPollingTask = nil
        diagnosticsPollingTask = nil
        status.telemetryPollingActive = false
        guard let session = activeSession,
              presentedProfileID == session.profileID else { return }
        if let output = directOutput {
            status.telemetryPollingActive = true
            status.outputBackend = "Direct Core Audio"
            meterPollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.isPresented(session) else { return }
                    let snapshot = output.snapshot(readMeters: true)
                    self.decayIdleInputLevels()
                    self.publishOutputLevels(peak: snapshot.peak, rms: snapshot.rms)
                    if self.status.transportError != snapshot.error { self.status.transportError = snapshot.error }
                    if self.status.engineIsRunning != (snapshot.error == nil) { self.status.engineIsRunning = snapshot.error == nil }
                    self.publish(.init(backend: "Direct Core Audio", engineState: snapshot.error == nil ? "Running" : "Stopped",
                        stopReason: snapshot.error ?? "None", bufferLevelFrames: snapshot.bufferedFrames,
                        clippedSamples: snapshot.clippedSamples, sampleRate: output.sampleRate,
                        blockFrames: snapshot.callbackFrames, processingBufferFrames: 0,
                        underrunFrames: snapshot.underrunFrames), now: Date())
                    do { try await Task.sleep(for: .milliseconds(UIRenderPerformance.meterPollMilliseconds)) } catch { return }
                }
            }
            return
        }
        guard let controller else { return }
        status.telemetryPollingActive = true

        meterPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let incoming = try await controller.fetchMeters()
                    guard let self, self.isPresented(session) else { return }
                    self.publishOutputLevels(peak: incoming.playbackPeak, rms: incoming.playbackRMS)
                } catch {
                    // A transient WebSocket miss should not tear down audio.
                }
                self?.decayIdleInputLevels()
                try? await Task.sleep(
                    for: .milliseconds(UIRenderPerformance.meterPollMilliseconds)
                )
            }
        }

        diagnosticsPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPresented(session) else { return }
                self.publishRouteDiagnostics(now: Date())
                do {
                    let diagnostics = try await controller.fetchDiagnostics()
                    guard self.isPresented(session) else { return }
                    self.publish(.init(camilla: diagnostics), now: Date())
                } catch {
                    guard self.isPresented(session) else { return }
                    let now = Date()
                    self.status.recordTelemetryFailure(error.localizedDescription, at: now)
                    self.publishRouteDiagnostics(now: now)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Evaluate before queuing PCM so hidden views and packets between meter
    /// samples do not wake the observation worker at the audio callback rate.
    func pcmAdmission(for session: AudioRuntimeSession) -> () -> Bool {
        { [presentationGate] in
            presentationGate.beginSample(profileID: session.profileID,
                uptime: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// Returns the independent PCM-router consumer used for source metering.
    /// Level calculation happens on the meter branch, never on the audio route.
    func pcmConsumer(for session: AudioRuntimeSession) -> PCMRouter.MeterConsumer {
        { [weak self, presentationGate] frame in
            guard presentationGate.isPresented(profileID: session.profileID) else { return }
            let snapshot = PCMLevelSnapshot.measure(frame)
            presentationGate.submit(snapshot, profileID: session.profileID) { [weak self] snapshot in
                self?.ingest(snapshot, session: session)
            }
        }
    }

    func stop() {
        meterPollingTask?.cancel()
        diagnosticsPollingTask?.cancel()
        meterPollingTask = nil
        diagnosticsPollingTask = nil
        controller = nil
        directOutput = nil
        routeDiagnosticsProvider = nil
        activeSession = nil
        presentationGate.setProfileID(nil)
        resetObservationState()
    }

    private func resetObservationState() {
        levels = .silent
        status = .inactive
        if activeSession != nil {
            status.isActive = true
            status.engineState = "Starting"
        }
        hasReceivedOutputLevels = false
        lastInputLevelsAt = nil
        lastOutputClippedSamples = 0
        lastClipAt = nil
        lastChannelClipAt.removeAll()
    }

    private func isPresented(_ session: AudioRuntimeSession) -> Bool {
        activeSession == session && presentedProfileID == session.profileID
    }

    func ingest(_ snapshot: PCMLevelSnapshot, session: AudioRuntimeSession) {
        guard isPresented(session) else { return }
        lastInputLevelsAt = Date()
        if snapshot.clippedSamples > 0 {
            status.sourceClippedSamples &+= snapshot.clippedSamples
        }
        // Audio In always describes the shared source boundary, in source order.
        // Output backends cannot replace these values with their own input bus.
        var next = levels
        next.capturePeak = smooth(
                current: levels.capturePeak,
                target: snapshot.peak,
                attack: 0.72,
                release: 0.16
            )
        next.captureRMS = smooth(
                current: levels.captureRMS,
                target: snapshot.rms,
                attack: 0.42,
                release: 0.20
            )
        if levels != next { levels = next }
        refreshRecentClipping(now: Date())
    }

    func decayIdleInputLevels(now: Date = Date()) {
        guard let lastInputLevelsAt, now.timeIntervalSince(lastInputLevelsAt) > 0.3 else { return }
        var next = levels
        next.capturePeak = smooth(current: capturePeak, target: .init(repeating: -150, count: capturePeak.count), attack: 0.72, release: 0.16)
        next.captureRMS = smooth(current: captureRMS, target: .init(repeating: -150, count: captureRMS.count), attack: 0.42, release: 0.20)
        if levels != next { levels = next }
    }

    func publishOutputLevels(peak: [Double], rms: [Double]) {
        // The playback peak is updated much more frequently than the cumulative
        // clipped-sample counter. Use it as the immediate overload signal so a
        // short peak above full scale is not missed between diagnostic polls.
        let now = Date()
        if peak.contains(where: { $0.isFinite && $0 > 0 }) {
            lastClipAt = now
        }
        for (channelIndex, peak) in peak.enumerated()
            where peak.isFinite && peak > 0 {
            lastChannelClipAt[channelIndex] = now
        }
        var next = levels
        if hasReceivedOutputLevels {
            next.playbackPeak = smooth(current: playbackPeak, target: peak, attack: 0.72, release: 0.16)
            next.playbackRMS = smooth(current: playbackRMS, target: rms, attack: 0.42, release: 0.20)
        } else {
            next.playbackPeak = peak
            next.playbackRMS = rms
            hasReceivedOutputLevels = true
        }
        if levels != next { levels = next }
        refreshRecentClipping(now: now)
    }

    func publish(_ diagnostics: AudioOutputTelemetry, now: Date) {
        if diagnostics.clippedSamples > lastOutputClippedSamples {
            lastClipAt = now
        }
        lastOutputClippedSamples = diagnostics.clippedSamples
        var next = status
        next.recordTelemetry(diagnostics, at: now)
        if let routeDiagnosticsProvider { next.route = routeDiagnosticsProvider() }
        next.lastUpdated = now
        next.clippingIsRecent = lastClipAt.map { now.timeIntervalSince($0) < 2 } ?? false
        if status != next { status = next }
    }

    private func publishRouteDiagnostics(now: Date) {
        guard let routeDiagnosticsProvider else { return }
        var next = status
        next.route = routeDiagnosticsProvider()
        next.lastUpdated = now
        next.clippingIsRecent = lastClipAt.map { now.timeIntervalSince($0) < 2 } ?? false
        if status != next { status = next }
    }

    private func refreshRecentClipping(now: Date) {
        let isRecent = lastClipAt.map { now.timeIntervalSince($0) < 2 } ?? false
        guard status.clippingIsRecent != isRecent else { return }
        status.clippingIsRecent = isRecent
    }

    private func smooth(
        current: [Double],
        target: [Double],
        attack: Double,
        release: Double
    ) -> [Double] {
        let channelCount = target.count
        return (0..<channelCount).map { channel in
            let previous = channel < current.count ? current[channel] : -150
            let next = channel < target.count ? target[channel] : -150
            // Below one thousandth of a dB the remaining motion is invisible.
            // Settle instead of invalidating idle views for an asymptotic tail.
            if abs(next - previous) < 0.001 { return next }
            let amount = next > previous ? attack : release
            return previous + (next - previous) * amount
        }
    }
}

extension SignalLevels {
    var playbackExceedsFullScale: Bool {
        playbackPeak.contains { $0.isFinite && $0 > 0 }
    }
}
