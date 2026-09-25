import CamiTuneDomain
import Foundation

/// Owns one sink, ordered queue, writer, clock evidence, and delivery statistics.
/// Retired workers retain their own state until their sink write exits.
package final class CamillaDeliveryPipeline: @unchecked Sendable {
    // The writer owns the duplicate through CamillaPCMSink. Control threads
    // request stop and join; they never close a descriptor beneath a write.
    private let sink: CamillaPCMSink?
    private let performanceSource: PerformanceTraceSource
    private var writerBlockInProgressFrames = 0
    /// Fixed for the engine session; derived from the acknowledged graph.
    private let backendChunkFrames: Int
    private let backendSampleRate: Double
    // Writer-owned byte-stream phase; queue recovery must not reset it.
    private var backendRemainderFrames = 0
    private var deliveryStatistics = PCMDeliveryStatistics()
    private let condition = NSCondition()
    private var renderConfiguration: RenderConfiguration
    private let configurationObserver: (@Sendable (RenderConfiguration) -> Void)?
    private var queue = LowLatencyPCMQueue()
    private var stopping = false
    private var workerFinished = true
    private var worker: Thread?
    private var needsPCMDiscontinuityReset = false
    private var rateStage = RateMatchedPCMStage()
    private var clockDrift = AudioClockDrift(started: PerformanceClock.now())
    private var publishedContentEstimate = SpatialContentEstimate.unknown
    private var contentEstimateDate = Date.distantPast
    private var needsContentReset = false
    private let expectedOutputChannelCount: Int
    private let routeRenderer: RouteRenderer
    private var publishedReferenceDiagnostics: ReferenceSpeakerDiagnostics?
    private var publishedRenderDiagnostics: SpatialRenderDiagnostics?
    private var renderSettings: SpatialRenderSettings {
        get { renderConfiguration.spatialSettings }
        set { renderConfiguration.spatialSettings = newValue }
    }
    private var renderOutput: SpatialOutputKind {
        get { renderConfiguration.spatialOutput }
        set { renderConfiguration.spatialOutput = newValue }
    }

    private var spatialRenderingMode: SpatialRenderingMode {
        get { renderConfiguration.spatialRenderingMode }
        set { renderConfiguration.spatialRenderingMode = newValue }
    }
    private var calibrationID: UUID?
    private var calibrationPlayback: SpatialCalibrationPlayback?
    private var measurementHold = false
    private var nextCalibrationFrameDate = Date()
    private var needsSpatialReset = false
    private let masterStage: SystemMasterStage

    package init(
        sink: CamillaPCMSink?,
        hrtfDatabase: (any HRTFDatabase)?,
        performanceSource: PerformanceTraceSource,
        activeRoute: ActiveAudioRoute?,
        renderConfiguration: RenderConfiguration,
        deliveryConfiguration: PCMDeliveryConfiguration,
        backendChunkFrames: Int,
        configurationObserver: (@Sendable (RenderConfiguration) -> Void)?,
        systemMaster: SystemMasterGainControl,
        referenceTopology: SpeakerTopology?
    ) {
        self.performanceSource = performanceSource
        self.backendChunkFrames = backendChunkFrames
        self.backendSampleRate = deliveryConfiguration.queue.sampleRate
        queue.configure(deliveryConfiguration.queue)
        self.sink = sink
        self.renderConfiguration = renderConfiguration
        self.configurationObserver = configurationObserver
        routeRenderer = RouteRenderer(activeRoute: activeRoute, referenceTopology: referenceTopology,
            hrtfDatabase: hrtfDatabase)
        self.expectedOutputChannelCount = routeRenderer.expectedOutputChannelCount
        masterStage = SystemMasterStage(control: systemMaster)
    }

    package func statisticsSnapshot() -> (delivery: PCMDeliveryStatistics, queue: PCMQueueSnapshot) {
        condition.lock(); defer { condition.unlock() }
        return (deliveryStatistics, queue.snapshot)
    }

    package func setDeliveryConfiguration(_ configuration: PCMDeliveryConfiguration) {
        condition.lock(); defer { condition.unlock() }
        if queue.policy?.rateTargetMode != configuration.queue.rateTargetMode {
            clockDrift = AudioClockDrift(started: PerformanceClock.now())
        }
        queue.configure(configuration.queue)
    }

    package func observeClock(_ observation: AudioClockObservation, source: Bool) {
        condition.lock(); defer { condition.unlock() }
        guard !stopping, queue.policy?.rateTargetMode == .clockTracked else { return }
        if source { clockDrift.observeSource(observation) }
        else { clockDrift.observeOutput(observation) }
    }

    package var referenceDiagnostics: ReferenceSpeakerDiagnostics? {
        condition.lock(); defer { condition.unlock() }
        return publishedReferenceDiagnostics
    }

    package var renderDiagnostics: SpatialRenderDiagnostics? {
        condition.lock()
        defer { condition.unlock() }
        return publishedRenderDiagnostics
    }

    package func setRenderConfiguration(_ configuration: RenderConfiguration) {
        condition.lock(); defer { condition.unlock() }
        let old = renderConfiguration
        // Preserve the existing reset policy. Renderer-local settings changes
        // continue through the long-lived engine's own update path.
        if old.spatialRenderingMode != configuration.spatialRenderingMode {
            needsSpatialReset = true
        }
        if old.spatialContentMode != configuration.spatialContentMode { needsContentReset = true }
        renderConfiguration = configuration
        // Correction history is compared with this block's immutable value on the writer.
    }

    package func setSpatialSettings(_ settings: SpatialRenderSettings, output: SpatialOutputKind) {
        condition.lock()
        renderSettings = settings
        renderOutput = output
        condition.unlock()
    }

    package func setSpatialRenderingMode(_ mode: SpatialRenderingMode) {
        condition.lock()
        let normalized: SpatialRenderingMode = mode == .standard ? .standard : .spatialAudio
        if mode == .frontStage || mode == .virtualSurround { renderSettings.enabled = true }
        if spatialRenderingMode != normalized {
            spatialRenderingMode = normalized
            needsSpatialReset = true
        }
        condition.unlock()
    }

    package func start() {
        condition.lock()
        stopping = false
        let validChunk = backendChunkFrames > 0 && backendChunkFrames <= Int.max / 2
        workerFinished = sink == nil || !validChunk
        condition.unlock()

        guard validChunk else {
            recordDeliveryFailure("Audio paused: invalid prepared backend chunk size.")
            return
        }
        guard sink != nil else {
            recordWriteFailure()
            return
        }

        let thread = Thread { [weak self] in self?.run() }
        thread.name = "CamiTune CamillaDSP PCM Writer"
        thread.qualityOfService = .userInteractive
        worker = thread
        thread.start()
    }

    package func beginSpatialCalibration(id: UUID) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !stopping, !workerFinished, calibrationID == nil else { return false }
        calibrationID = id
        needsContentReset = true
        return true
    }

    package var contentEstimate: SpatialContentEstimate {
        condition.lock()
        defer { condition.unlock() }
        return Date().timeIntervalSince(contentEstimateDate) < 1 ? publishedContentEstimate : .unknown
    }



    package func playSpatialCalibration(
        id: UUID, clip: SpatialCalibrationClip,
        completion: @escaping @Sendable () -> Void
    ) -> Bool {
        let performance = performanceSource.snapshot()
        condition.lock()
        defer { condition.unlock() }
        guard calibrationID == id, !stopping, !workerFinished else { return false }
        guard routeRenderer.acceptsCalibrationClip(clip) else { return false }
        calibrationPlayback = SpatialCalibrationPlayback(clip: clip, completion: completion)
        nextCalibrationFrameDate = Date()
        resetQueue(reason: .explicitCalibrationReset, performance: performance)
        needsPCMDiscontinuityReset = true
        condition.signal()
        return true
    }

    package func stopSpatialCalibrationSample(id: UUID) {
        condition.lock()
        defer { condition.unlock() }
        guard calibrationID == id else { return }
        calibrationPlayback?.requestStop()
        condition.signal()
    }

    package func endSpatialCalibration(id: UUID) {
        condition.lock()
        defer { condition.unlock() }
        guard calibrationID == id else { return }
        calibrationID = nil
        measurementHold = false
        calibrationPlayback?.requestStop()
        condition.signal()
    }

    package func enqueue(_ frame: PCMFrame) {
        let performance = performanceSource.snapshot()
        condition.lock()
        guard !stopping, calibrationPlayback == nil, !measurementHold else {
            condition.unlock()
            return
        }
        let result = queue.enqueue(frame, performance: performance)
        if case .rejected = result { condition.unlock(); return }
        let recovery = result.recovery
        let entry = queue.lastEnqueuedTrace
        let writerFrames = writerBlockInProgressFrames
        if recovery != nil { needsPCMDiscontinuityReset = true }
        // Publish enqueue evidence before the writer can publish its dequeue.
        // Capture append is bounded and never waits for its own recorder lock.
        if let entry {
            entry.capture.append(.queue(.init(identity: entry.identity, timestamp: entry.entered, isEntry: true,
                queuedFrames: entry.queueAfter, capacityFrames: entry.capacity)))
        }
        if let recovery {
            if let performance, let session = performance.sessionID {
                performance.capture.append(.recovery(.init(captureID: performance.capture.id, runtimeSessionID: session,
                    timestamp: recovery.timestamp, queuedFramesBeforeRecovery: recovery.queuedFramesBefore,
                    incomingFrames: recovery.incomingFrames, droppedFrames: recovery.droppedFrames,
                    sampleRate: recovery.sampleRate, writerBlockInProgressFrames: writerFrames, recovery: recovery)))
            }
        }
        condition.signal()
        condition.unlock()
        if let recovery, recovery.reason == .overflow { recordRecovery(recovery.droppedFrames) }
    }

    package func enqueueProducerEnd() {
        condition.lock()
        guard !stopping, calibrationPlayback == nil, !measurementHold else { condition.unlock(); return }
        let accepted = queue.enqueueProducerEnd()
        if !accepted { stopping = true; resetQueue(reason: .runtimeReset, performance: performanceSource.snapshot()) }
        condition.signal()
        condition.unlock()
        if !accepted { recordDeliveryFailure("Audio paused: producer completion exceeded the delivery queue bound.") }
    }

    package func holdSpatialMeasurement(id: UUID, enabled: Bool) {
        let performance = performanceSource.snapshot()
        condition.lock()
        defer { condition.unlock() }
        guard calibrationID == id else { return }
        measurementHold = enabled
        if enabled {
            resetQueue(reason: .explicitCalibrationReset, performance: performance)
            needsPCMDiscontinuityReset = true
        }
    }

    package func stop() {
        let performance = performanceSource.snapshot()
        condition.lock()
        stopping = true
        calibrationID = nil
        calibrationPlayback = nil
        resetQueue(reason: .runtimeReset, performance: performance)
        condition.broadcast()
        let deadline = Date().addingTimeInterval(0.5)
        while !workerFinished, condition.wait(until: deadline) {}
        // A timed-out writer retains its sink until the write finishes or
        // the engine closes the pipe. Only that worker releases the duplicate.
        worker = nil
        condition.unlock()
    }

    /// Caller holds condition. Explicit resets are observable discontinuities,
    /// not overflow health faults. Capture append is bounded and nonblocking.
    private func resetQueue(reason: PCMQueueRecoveryReason, performance: PerformanceCaptureBinding?) {
        let recovery = queue.reset(reason: reason)
        guard let performance, let session = performance.sessionID else { return }
        performance.capture.append(.recovery(.init(captureID: performance.capture.id, runtimeSessionID: session,
            timestamp: recovery.timestamp, queuedFramesBeforeRecovery: recovery.queuedFramesBefore,
            incomingFrames: 0, droppedFrames: recovery.droppedFrames, sampleRate: recovery.sampleRate,
            writerBlockInProgressFrames: writerBlockInProgressFrames, recovery: recovery)))
    }



    private func run() {
        guard let sink else { return }
        defer {
            sink.finish()
            condition.lock()
            workerFinished = true
            condition.broadcast()
            condition.unlock()
        }

        while true {
            condition.lock()
            writerBlockInProgressFrames = 0
            while queue.isEmpty && calibrationPlayback == nil && !stopping { condition.wait() }
            if stopping {
                condition.unlock()
                return
            }
            if calibrationPlayback != nil, Date() < nextCalibrationFrameDate {
                condition.wait(until: nextCalibrationFrameDate)
                condition.unlock()
                continue
            }
            let isCalibrationSample = calibrationPlayback != nil
            let isAcousticMeasurement = calibrationPlayback?.clip.isAcousticMeasurement ?? false
            let physicalOutput = calibrationPlayback?.clip.physicalOutput
            let isChannelAudition = calibrationPlayback?.clip.isVirtualAudition ?? false
            var calibrationCompletion: (@Sendable () -> Void)?
            let nextFrame: PCMFrame?
            if var playback = calibrationPlayback {
                nextFrame = playback.nextFrame()
                if playback.isFinished {
                    calibrationCompletion = playback.completion
                    calibrationPlayback = nil
                } else {
                    calibrationPlayback = playback
                }
                let duration = Double(nextFrame?.frameCount ?? 0) / playback.clip.sampleRate
                nextCalibrationFrameDate = max(nextCalibrationFrameDate, Date().addingTimeInterval(-0.05))
                    .addingTimeInterval(duration)
            } else {
                let entry = queue.removeNext()
                if case .producerEnd? = entry {
                    let discard = needsPCMDiscontinuityReset
                    condition.unlock()
                    var tailFrames = 0
                    if var tail = rateStage.finish(discard: discard), !tail.interleaved.isEmpty {
                        masterStage.process(to: &tail.interleaved, channelCount: tail.channelCount, sampleRate: tail.sampleRate)
                        do {
                            try sink.write(tail.interleaved.withUnsafeBytes { Data($0) })
                            recordBackendWrite(frames: tail.frameCount)
                            tailFrames = tail.frameCount
                        }
                        catch { failWrite(); return }
                    }
                    // Stdin has no END framing. On macOS Camilla's reader waits
                    // for a full chunk, so complete only the final known chunk.
                    // Padding follows the authoritative END immediately; no
                    // idle timer authorizes it or extends the source deadline.
                    let paddingFrames = backendRemainderFrames == 0 ? 0 : backendChunkFrames - backendRemainderFrames
                    var remaining = paddingFrames
                    while remaining > 0 {
                        condition.lock(); let cancelled = stopping; condition.unlock()
                        if cancelled { return }
                        let frames = min(remaining, 1024)
                        var silence = Array<Float>(repeating: 0, count: frames * expectedOutputChannelCount)
                        masterStage.process(to: &silence, channelCount: expectedOutputChannelCount, sampleRate: backendSampleRate)
                        do {
                            try sink.write(silence.withUnsafeBytes { Data($0) })
                            recordBackendWrite(frames: frames)
                        } catch { failWrite(); return }
                        remaining -= frames
                    }
                    // END seals resampler lookahead, not the running renderer.
                    // Filter/delay history belongs to this delivery session and
                    // is reset only by a real discontinuity or configuration change.
                    condition.lock()
                    deliveryStatistics.drains.completedDrains &+= 1
                    deliveryStatistics.drains.resamplerTailFrames &+= UInt64(tailFrames)
                    deliveryStatistics.drains.backendPaddingFrames &+= UInt64(paddingFrames)
                    condition.unlock()
                    continue
                }
                nextFrame = entry?.frame
            }
            guard let frame = nextFrame else {
                condition.unlock()
                continue
            }
            let trace = frame.writerTrace.flatMap { $0.capture.accepts(PerformanceClock.now()) ? $0 : nil }
            let queueLeft = trace.map { _ in PerformanceClock.now() }
            writerBlockInProgressFrames = frame.frameCount
            let queuedFrames = queue.queuedFrames
            guard let ratePolicy = queue.policy, ratePolicy.isValid,
                  isCalibrationSample || ratePolicy.sampleRate == frame.sampleRate else {
                stopping = true
                resetQueue(reason: .runtimeReset, performance: performanceSource.snapshot())
                condition.unlock()
                recordDeliveryFailure("Audio paused: PCM format does not match its prepared delivery policy. Restart the audio session to recover.")
                return
            }
            let recoveryGeneration = queue.recoveryGeneration
            var clockAdjustment: Double?
            if ratePolicy.rateTargetMode == .clockTracked && !isCalibrationSample {
                switch clockDrift.state(at: PerformanceClock.now()) {
                case .tracking(let ppm): clockAdjustment = ppm
                case .warming: clockAdjustment = 0
                case .unavailable(let reason):
                    stopping = true
                    resetQueue(reason: .runtimeReset, performance: performanceSource.snapshot())
                    condition.unlock()
                    recordDeliveryFailure("Audio paused: \(reason). Restart the audio session to recover.")
                    return
                }
            }
            let shouldResetPCMDiscontinuity = needsPCMDiscontinuityReset
            let shouldResetSpatialRenderer = needsSpatialReset
            let configuration = renderConfiguration
            // Keep the two physical sweep channels independent. The existing
            // downstream output EQ and system master remain in the path.
            let spatialRenderingMode: SpatialRenderingMode = isAcousticMeasurement ? .standard : configuration.spatialRenderingMode
            var renderSettings = configuration.spatialSettings
            if isChannelAudition {
                renderSettings.contentSelection = .cinema
                renderSettings.cinema.amount = 1
            }
            let renderOutput = configuration.spatialOutput
            let currentMode = configuration.playbackMode
            let correction = configuration.referenceCorrection
            let hasSpatialBus = frame.playbackModeSamples[.spatialRender] != nil
            let shouldAnalyzeContent = ((spatialRenderingMode != .standard && renderSettings.enabled) || hasSpatialBus)
                && calibrationID == nil && !isCalibrationSample
            let shouldResetContent = needsContentReset || Date().timeIntervalSince(contentEstimateDate) > 1
            needsContentReset = false
            needsPCMDiscontinuityReset = false
            needsSpatialReset = false
            condition.unlock()
            configurationObserver?(configuration)
            if let trace, let queueLeft {
                trace.capture.append(.queue(.init(identity: trace.identity, timestamp: queueLeft, isEntry: false,
                    queuedFrames: queuedFrames, capacityFrames: trace.capacity)))
            }
            if shouldResetPCMDiscontinuity { rateStage.reset() }
            let renderedFrame = routeRenderer.render(frame, mode: isAcousticMeasurement ? .direct : currentMode,
                settings: renderSettings, output: renderOutput, correction: correction,
                physicalOutput: physicalOutput, analyzeContent: shouldAnalyzeContent,
                resetContent: shouldResetContent, resetPCM: shouldResetPCMDiscontinuity,
                resetSpatial: shouldResetSpatialRenderer)
            condition.lock()
            publishedContentEstimate = routeRenderer.contentEstimate
            contentEstimateDate = Date()
            publishedReferenceDiagnostics = routeRenderer.referenceDiagnostics
            publishedRenderDiagnostics = spatialRenderingMode == .spatialAudio || hasSpatialBus ? routeRenderer.renderDiagnostics : nil
            condition.unlock()
            guard let renderedFrame else {
                recordRecovery(frame.frameCount)
                continue
            }
            // Rate-match only the post-mix writer queue. The SABR frame ring
            // stores one block per Core Audio client, so its raw frame occupancy
            // is a storage metric, not timeline latency. A transient system
            // client (for example volume-feedback audio) can multiply that raw
            // count and previously drove a false resampling correction for
            // seconds. The local mixed queue is already in timeline frames and
            // is the correct clock-boundary backlog to control.
            let renderCompleted = trace.map { _ in PerformanceClock.now() }
            let bufferedFrames = frame.frameCount + queuedFrames
            let matched = rateStage.process(renderedFrame, inputFrames: frame.frameCount,
                queuedFrames: queuedFrames, policy: ratePolicy, recoveryGeneration: recoveryGeneration,
                clockAdjustmentPPM: clockAdjustment, isCalibrationSample: isCalibrationSample,
                recordObservation: trace != nil)
            recordAdjustment(matched.adjustmentPPM, bufferedFrames)
            let rateObservation = matched.observation
            var adjustedFrame = matched.frame
            guard !adjustedFrame.interleaved.isEmpty else { continue }
            let resampleCompleted = trace.map { _ in PerformanceClock.now() }
            masterStage.process(
                to: &adjustedFrame.interleaved,
                channelCount: adjustedFrame.channelCount,
                sampleRate: adjustedFrame.sampleRate
            )
            let masterCompleted = trace.map { _ in PerformanceClock.now() }
            do {
                let payload = adjustedFrame.interleaved.withUnsafeBytes { Data($0) }
                let pipeWriteStarted = trace.map { _ in PerformanceClock.now() }
                try sink.write(payload)
                recordBackendWrite(frames: adjustedFrame.frameCount)
                if let trace, let queueLeft, let renderCompleted, let resampleCompleted, let masterCompleted, let pipeWriteStarted {
                    let interval = trace.interval
                    trace.capture.append(.audio(.init(identity: trace.identity,
                        packetReceived: interval?.firstPacketReceived, lastPacketReceived: interval?.lastPacketReceived,
                        firstPacketProcessed: interval?.firstPacketProcessed, packetProcessed: interval?.lastPacketProcessed, mixEligible: interval?.becameEligible,
                        mixEmitted: interval?.emitted, idleDeadline: interval?.idleDeadline, idleFlushStarted: interval?.idleFlushStarted,
                        queueEntered: trace.entered, queueLeft: queueLeft, renderCompleted: renderCompleted,
                        resampleCompleted: resampleCompleted, masterCompleted: masterCompleted,
                        pipeWriteStarted: pipeWriteStarted, pipeWriteCompleted: PerformanceClock.now(),
                        queueFramesBeforeEntry: trace.queueBefore, queueFramesAtEntry: trace.queueAfter,
                        queueFramesAfterDequeue: queuedFrames, queueCapacityFrames: trace.capacity,
                        blockFrames: adjustedFrame.frameCount, contributorCount: interval?.contributingPackets ?? 0,
                        rateMatch: rateObservation)))
                }
                calibrationCompletion?()
            } catch {
                failWrite()
                return
            }
        }
    }

    private func recordBackendWrite(frames: Int) {
        backendRemainderFrames = (backendRemainderFrames + frames) % backendChunkFrames
    }

    private func recordRecovery(_ droppedFrames: Int) {
        condition.lock()
        deliveryStatistics.droppedFrames &+= UInt64(max(0, droppedFrames))
        deliveryStatistics.recoveries &+= 1
        condition.unlock()
    }

    private func recordWriteFailure() {
        condition.lock()
        deliveryStatistics.writeFailures &+= 1
        condition.unlock()
        recordDeliveryFailure("Audio paused: the CamillaDSP input pipe failed. Restart the audio session to recover.")
    }

    private func recordDeliveryFailure(_ message: String) {
        condition.lock()
        let first = deliveryStatistics.error == nil
        if first { deliveryStatistics.error = message }
        condition.unlock()
        if first { NSLog("PCM delivery fault: %@", message) }
    }

    private func recordAdjustment(_ ppm: Double, _ bufferedFrames: Int) {
        condition.lock()
        deliveryStatistics.adjustmentPPM = ppm
        deliveryStatistics.bufferedFrames = UInt64(max(0, bufferedFrames))
        condition.unlock()
    }

    private func failWrite() {
        let performance = performanceSource.snapshot()
        condition.lock()
        stopping = true
        resetQueue(reason: .runtimeReset, performance: performance)
        condition.unlock()
        recordWriteFailure()
    }


}
