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

    init() {}

    init(
        transport: SystemAudioBridgeTransport.Statistics,
        router: PCMRouter.Statistics
    ) {
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

struct AudioRuntimeStatus: Equatable, Sendable {
    var engineState = "Inactive"
    var stopReason = "None"
    var processingLoadPercent = 0.0
    var resamplerLoadPercent = 0.0
    var dspBufferLevelFrames: UInt64 = 0
    var camillaRateAdjustment = 1.0
    var dspClippedSamples: UInt64 = 0
    var sourceClippedSamples: UInt64 = 0
    var clippingIsRecent = false
    var telemetryAvailable = false
    var route = AudioRouteDiagnostics()
    var lastUpdated: Date?

    static let inactive = AudioRuntimeStatus()

    var effectiveRateAdjustmentPPM: Double {
        if abs(route.rateAdjustmentPPM) >= 0.005 { return route.rateAdjustmentPPM }
        // CamillaDSP reports an adjustment ratio (1.0 means unchanged).
        guard camillaRateAdjustment.isFinite, camillaRateAdjustment > 0 else { return 0 }
        return (camillaRateAdjustment - 1) * 1_000_000
    }

    var health: AudioRuntimeHealth {
        guard engineState != "Inactive" || telemetryAvailable else { return .inactive }
        let normalizedState = engineState.lowercased()
        let stoppedWithError = !["none", "done"].contains(stopReason.lowercased())
        if normalizedState == "stalled" || stoppedWithError || route.camillaWriteFailures > 0 {
            return .fault
        }
        if !telemetryAvailable || clippingIsRecent || processingLoadPercent >= 85
            || route.bridgeDroppedFrames > 0 || route.bridgeConsumerOverrunCount > 0
            || route.bridgeClientRegistryOverflowCount > 0
            || route.bridgeClientUseCountSaturationCount > 0
            || route.bridgeMalformedPacketCount > 0
            || route.camillaQueueRecoveries > 0 {
            return .warning
        }
        return .healthy
    }
}

/// Owns read-only runtime observations. It deliberately does not mutate the
/// processing graph, reset clipping counters, or control transport lifetime.
@MainActor
final class AudioRuntimeMonitor: ObservableObject {
    typealias RouteDiagnosticsProvider = @MainActor () -> AudioRouteDiagnostics

    @Published private(set) var activeSession: AudioRuntimeSession?
    @Published private(set) var levels = SignalLevels.silent
    @Published private(set) var captureUsesDSPBus = false
    @Published private(set) var status = AudioRuntimeStatus.inactive

    var capturePeak: [Double] { levels.capturePeak }
    var captureRMS: [Double] { levels.captureRMS }
    var playbackPeak: [Double] { levels.playbackPeak }
    var playbackRMS: [Double] { levels.playbackRMS }

#if DEBUG
    /// Silent setup preview only: no polling tasks or audio device lifecycle.
    func setPreviewLevels(_ levels: SignalLevels, profileID: UUID) {
        activeSession = AudioRuntimeSession(profileID: profileID)
        self.levels = levels
        captureUsesDSPBus = true
    }
#endif

    private var meterPollingTask: Task<Void, Never>?
    private var diagnosticsPollingTask: Task<Void, Never>?
    private var controller: CamillaDSPController?
    private var routeDiagnosticsProvider: RouteDiagnosticsProvider?
    private var presentedProfileID: UUID?
    private let presentationGate = RuntimePresentationGate()
    private var hasReceivedDSPLevels = false
    private var lastDSPLevelsAt: Date?
    private var lastTelemetryAt: Date?
    private var lastDSPClippedSamples: UInt64 = 0
    private var lastClipAt: Date?
    private var lastChannelClipAt: [Int: Date] = [:]

    func channelClippingIsRecent(_ channelIndex: Int, now: Date = Date()) -> Bool {
        lastChannelClipAt[channelIndex].map { now.timeIntervalSince($0) < 2 } ?? false
    }

    func start(
        controller: CamillaDSPController,
        session: AudioRuntimeSession,
        routeDiagnosticsProvider: @escaping RouteDiagnosticsProvider
    ) {
        stop()
        activeSession = session
        self.controller = controller
        self.routeDiagnosticsProvider = routeDiagnosticsProvider
        status.engineState = "Starting"
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
        guard let controller,
              let session = activeSession,
              presentedProfileID == session.profileID else { return }

        meterPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let incoming = try await controller.fetchMeters()
                    guard let self, self.isPresented(session) else { return }
                    self.publishDSPLevels(incoming)
                } catch {
                    // A transient WebSocket miss should not tear down audio.
                }
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
                    self.publish(diagnostics, now: Date())
                } catch {
                    guard self.isPresented(session) else { return }
                    let now = Date()
                    if self.lastTelemetryAt.map({ now.timeIntervalSince($0) > 2.5 }) ?? true {
                        self.status.telemetryAvailable = false
                    }
                    self.publishRouteDiagnostics(now: now)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Returns the independent PCM-router consumer used for source metering.
    /// Level calculation happens on the meter branch, never on the audio route.
    func pcmConsumer(for session: AudioRuntimeSession) -> PCMRouter.MeterConsumer {
        { [weak self, presentationGate] frame in
            guard presentationGate.beginSample(
                profileID: session.profileID,
                uptime: ProcessInfo.processInfo.systemUptime
            ) else { return }
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
        routeDiagnosticsProvider = nil
        activeSession = nil
        resetObservationState()
    }

    private func resetObservationState() {
        levels = .silent
        captureUsesDSPBus = false
        status = .inactive
        if let session = activeSession, presentedProfileID == session.profileID {
            status.engineState = "Starting"
        }
        hasReceivedDSPLevels = false
        lastDSPLevelsAt = nil
        lastTelemetryAt = nil
        lastDSPClippedSamples = 0
        lastClipAt = nil
        lastChannelClipAt.removeAll()
    }

    private func isPresented(_ session: AudioRuntimeSession) -> Bool {
        activeSession == session && presentedProfileID == session.profileID
    }

    private func ingest(_ snapshot: PCMLevelSnapshot, session: AudioRuntimeSession) {
        guard isPresented(session) else { return }
        if snapshot.clippedSamples > 0 {
            status.sourceClippedSamples &+= snapshot.clippedSamples
            lastClipAt = Date()
        }
        // This tap uses source-channel order, not physical output indices.
        // Only DSP playback peaks may flag a particular speaker as clipping.

        // CamillaDSP levels include the real DSP capture/playback boundary. The
        // direct router tap is a fallback when WebSocket metering becomes stale.
        let dspLevelsAreFresh = lastDSPLevelsAt.map {
            Date().timeIntervalSince($0) < 0.5
        } ?? false
        if !dspLevelsAreFresh {
            if captureUsesDSPBus { captureUsesDSPBus = false }
            levels.capturePeak = smooth(
                current: levels.capturePeak,
                target: snapshot.peak,
                attack: 0.72,
                release: 0.16
            )
            levels.captureRMS = smooth(
                current: levels.captureRMS,
                target: snapshot.rms,
                attack: 0.42,
                release: 0.20
            )
        }
        refreshRecentClipping(now: Date())
    }

    private func publishDSPLevels(_ incoming: SignalLevels) {
        if !captureUsesDSPBus { captureUsesDSPBus = true }
        // The playback peak is updated much more frequently than the cumulative
        // clipped-sample counter. Use it as the immediate overload signal so a
        // short peak above full scale is not missed between diagnostic polls.
        let now = Date()
        if incoming.playbackExceedsFullScale {
            lastClipAt = now
        }
        for (channelIndex, peak) in incoming.playbackPeak.enumerated()
            where peak.isFinite && peak >= 0 {
            lastChannelClipAt[channelIndex] = now
        }
        if hasReceivedDSPLevels {
            levels = SignalLevels(
                capturePeak: smooth(current: capturePeak, target: incoming.capturePeak, attack: 0.72, release: 0.16),
                captureRMS: smooth(current: captureRMS, target: incoming.captureRMS, attack: 0.42, release: 0.20),
                playbackPeak: smooth(current: playbackPeak, target: incoming.playbackPeak, attack: 0.72, release: 0.16),
                playbackRMS: smooth(current: playbackRMS, target: incoming.playbackRMS, attack: 0.42, release: 0.20)
            )
        } else {
            levels = incoming
            hasReceivedDSPLevels = true
        }
        lastDSPLevelsAt = now
        refreshRecentClipping(now: now)
    }

    private func publish(_ diagnostics: CamillaDSPDiagnostics, now: Date) {
        if diagnostics.clippedSamples > lastDSPClippedSamples {
            lastClipAt = now
        }
        lastDSPClippedSamples = diagnostics.clippedSamples
        status.engineState = diagnostics.engineState
        status.stopReason = diagnostics.stopReason
        status.processingLoadPercent = diagnostics.processingLoadPercent
        status.resamplerLoadPercent = diagnostics.resamplerLoadPercent
        status.dspBufferLevelFrames = diagnostics.bufferLevelFrames
        status.camillaRateAdjustment = diagnostics.rateAdjustment
        status.dspClippedSamples = diagnostics.clippedSamples
        status.telemetryAvailable = true
        status.lastUpdated = now
        lastTelemetryAt = now
        publishRouteDiagnostics(now: now)
    }

    private func publishRouteDiagnostics(now: Date) {
        guard let routeDiagnosticsProvider else { return }
        let route = routeDiagnosticsProvider()
        status.route = route
        status.lastUpdated = now
        refreshRecentClipping(now: now)
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
        let channelCount = max(current.count, target.count)
        return (0..<channelCount).map { channel in
            let previous = channel < current.count ? current[channel] : -150
            let next = channel < target.count ? target[channel] : -150
            let amount = next > previous ? attack : release
            return previous + (next - previous) * amount
        }
    }
}

extension SignalLevels {
    var playbackExceedsFullScale: Bool {
        playbackPeak.contains { $0.isFinite && $0 >= 0 }
    }
}
