import CamiTuneDomain
import Foundation

/// Owns one sink, ordered queue, writer, clock evidence, and delivery statistics.
/// Retired workers retain their own state until their sink write exits.
package final class CamillaDeliveryPipeline: @unchecked Sendable {
    // The writer owns the duplicate through CamillaPCMSink. Control threads
    // request stop and join; they never close a descriptor beneath a write.
    private var sink: CamillaPCMSink?
    private let pipelineID = UUID()
    private var activityGeneration: UInt64 = 0
    private var backendGeneration: UInt64 = 0
    private let performanceSource: PerformanceTraceSource
    private var writerBlockInProgressFrames = 0
    /// Fixed for the engine session; derived from the acknowledged graph.
    private var backendChunkFrames: Int
    private let backendSampleRate: Double
    // Writer-owned byte-stream phase; queue recovery must not reset it.
    private var backendRemainderFrames = 0
    private var deliveryStatistics = PCMDeliveryStatistics()
    private var bufferWork = AudioBufferWorkObservation()
    private var bufferWorkGeneration: UInt64 = 0
    private var quietSince = PerformanceClock.now()
    private var inputQuietSince = PerformanceClock.now()
    private var writerBusy = false
    private var pluginSilentInputSeconds = 0.0
    private var silentOutputSeconds = 0.0
    private var lastPluginLoad = 0.0
    private var lastPluginFailed = false
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
    private var pluginProcessor: (any PluginAudioProcessor)?
    private var pluginResetNeeded = true
    private var pluginTailFrames = 0
    private var pluginProtection = PluginOutputProtection()
    private var pluginWasFailing = false
    private var pluginWasActive = false
    private var pluginWasBypassed = false
    // Only an authoritative producer END (or a fresh session) permits the
    // instrument clock. Temporary source starvation must not invent PCM time.
    private var producerEnded = true
    private var nextInstrumentTick: UInt64 = 0
    private var wasGeneratingInstrument = false
    private var instrumentStopPadding = false

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
        referenceTopology: SpeakerTopology?,
        pluginProcessor: (any PluginAudioProcessor)? = nil
    ) {
        self.performanceSource = performanceSource
        self.pluginProcessor = pluginProcessor
        self.pluginResetNeeded = pluginProcessor != nil
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

    package func takeAudioBufferWork() -> AudioBufferWorkObservation {
        condition.lock(); defer { condition.unlock() }
        let result = bufferWork
        bufferWork = .init()
        return result
    }

    /// Exact PCM silence, before system mute/gain, with no queued work or tail.
    /// An idle/failed writer alone is never evidence of silence.
    package func isQuietForBufferChange(seconds: Double, now: PerformanceTick = PerformanceClock.now()) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return isQuietForBufferChangeLocked(seconds: seconds, now: now)
    }

    private func isQuietForBufferChangeLocked(seconds: Double, now: PerformanceTick) -> Bool {
        guard seconds.isFinite, seconds >= 3, !stopping, !workerFinished,
              !writerBusy, queue.isEmpty, pluginTailFrames == 0, backendRemainderFrames == 0,
              calibrationID == nil, !measurementHold, !needsPCMDiscontinuityReset,
              deliveryStatistics.error == nil else { return false }
        let tail = pluginProcessor?.bufferChangeTailSeconds(sampleRate: backendSampleRate) ?? 0
        return tail.isFinite && tail >= 0
            && PerformanceClock.milliseconds(quietSince, now) >= seconds * 1000
            && PerformanceClock.milliseconds(inputQuietSince, now) >= (seconds + tail) * 1000
            // Wall time does not drain a delay line when its producer pauses.
            && pluginSilentInputSeconds >= tail && silentOutputSeconds >= seconds - 3
    }

    package func bufferHandoffToken(seconds: Double, now: PerformanceTick = PerformanceClock.now()) -> AudioBufferHandoffToken? {
        condition.lock(); defer { condition.unlock() }
        guard isQuietForBufferChangeLocked(seconds: seconds, now: now) else { return nil }
        return .init(pipelineID: pipelineID, activity: activityGeneration)
    }

    package func acceptsBufferHandoff(_ token: AudioBufferHandoffToken) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return token.pipelineID == pipelineID && token.activity == activityGeneration
            && !stopping && !workerFinished && calibrationID == nil && deliveryStatistics.error == nil
    }

    /// No writer is in flight while this lock is held. An arriving block either
    /// invalidates the token before commit, or is delivered wholly to the ready
    /// replacement. Neither path drops, fades, duplicates or holds source audio.
    package func replaceBackendIfQuiet(_ replacement: CamillaPCMSink, token: AudioBufferHandoffToken,
        chunkFrames: Int, configuration: PCMDeliveryConfiguration, clocks: [AudioClockObservation],
        quietSeconds: Double, now: PerformanceTick = PerformanceClock.now()) -> CamillaPCMSink? {
        condition.lock(); defer { condition.unlock() }
        guard token.pipelineID == pipelineID, token.activity == activityGeneration,
              isQuietForBufferChangeLocked(seconds: quietSeconds, now: now),
              let retired = sink, replacement !== retired,
              chunkFrames > 0, chunkFrames <= 8192, configuration.queue.isValid,
              configuration.queue.sampleRate == backendSampleRate,
              configuration.queue.rateTargetMode == queue.policy?.rateTargetMode else { return nil }
        var nextClock = clockDrift
        if configuration.queue.rateTargetMode == .clockTracked,
           !nextClock.replaceOutput(with: clocks, now: now) { return nil }
        sink = replacement
        backendChunkFrames = chunkFrames
        queue.configure(configuration.queue)
        clockDrift = nextClock
        backendGeneration &+= 1
        activityGeneration &+= 1
        bufferWorkGeneration &+= 1; bufferWork = .init()
        return retired
    }

    package func playbackClockConsumer() -> @Sendable (AudioClockObservation) -> Void {
        condition.lock(); let generation = backendGeneration; condition.unlock()
        return { [weak self] observation in
            guard let self else { return }
            self.condition.lock(); defer { self.condition.unlock() }
            guard !self.stopping, generation == self.backendGeneration,
                  self.queue.policy?.rateTargetMode == .clockTracked else { return }
            self.clockDrift.observeOutput(observation)
        }
    }

    /// Returns true for exact silence, without changing the samples.
    private func observeBufferSignal(_ samples: [Float]) -> Bool {
        guard samples.contains(where: { $0 != 0 }) else { return true }
        condition.lock(); quietSince = PerformanceClock.now(); activityGeneration &+= 1; condition.unlock()
        return false
    }

    package func statisticsSnapshot() -> (delivery: PCMDeliveryStatistics, queue: PCMQueueSnapshot) {
        condition.lock(); defer { condition.unlock() }
        return (deliveryStatistics, queue.snapshot)
    }

    package func setDeliveryConfiguration(_ configuration: PCMDeliveryConfiguration) {
        condition.lock(); defer { condition.unlock() }
        activityGeneration &+= 1
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
        bufferWorkGeneration &+= 1; bufferWork = .init()
        quietSince = PerformanceClock.now(); inputQuietSince = quietSince
        activityGeneration &+= 1
        pluginSilentInputSeconds = 0; silentOutputSeconds = 0
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

    package func setPluginProcessor(_ processor: (any PluginAudioProcessor)?) {
        condition.lock(); defer { condition.unlock() }
        if pluginProcessor === processor { return }
        bufferWorkGeneration &+= 1; bufferWork = .init()
        quietSince = PerformanceClock.now(); inputQuietSince = quietSince
        activityGeneration &+= 1
        pluginSilentInputSeconds = 0; silentOutputSeconds = 0
        pluginProcessor = processor
        pluginResetNeeded = true
        condition.signal()
    }

    /// Called only by the writer. The helper enforces a deadline; failures fade
    /// to silence until the user bypasses or reloads the rack.
    private func processPlugins(_ samples: inout [Float], sampleRate: Double, reset: Bool = false, bypass: Bool = false) {
        let inputSilent = observeBufferSignal(samples)
        let seconds = Double(samples.count / expectedOutputChannelCount) / sampleRate
        condition.lock()
        let generation = bufferWorkGeneration
        condition.unlock()
        defer {
            let outputSilent = observeBufferSignal(samples)
            condition.lock()
            if generation == bufferWorkGeneration {
                pluginSilentInputSeconds = inputSilent ? pluginSilentInputSeconds + seconds : 0
                silentOutputSeconds = outputSilent ? silentOutputSeconds + seconds : 0
            }
            condition.unlock()
        }
        condition.lock()
        let processor = pluginProcessor
        let changed = pluginResetNeeded
        pluginResetNeeded = false
        condition.unlock()
        lastPluginLoad = 0; lastPluginFailed = false
        if processor == nil && !changed && !pluginWasActive && !pluginProtection.isTransitioning { return }
        pluginWasActive = processor != nil
        if changed { pluginProtection.beginTransition(); if !instrumentStopPadding { pluginTailFrames = 0 } }
        let pluginStarted = PerformanceClock.now()
        let failed = !bypass && processor.map { $0.channelCount != expectedOutputChannelCount || !$0.process(&samples, sampleRate: sampleRate, reset: changed || reset || pluginWasBypassed) } == true
        if processor != nil && !bypass && !samples.isEmpty {
            let audioSeconds = Double(samples.count / expectedOutputChannelCount) / sampleRate
            lastPluginLoad = PerformanceClock.milliseconds(pluginStarted, PerformanceClock.now()) / (1000 * audioSeconds)
            lastPluginFailed = failed
        }
        pluginWasBypassed = bypass
        if failed {
            if !pluginWasFailing { pluginProtection.beginTransition() }
            for index in samples.indices { samples[index] = 0 }
        }
        pluginWasFailing = failed
        pluginProtection.process(&samples, sampleRate: sampleRate, enabled: processor != nil && !bypass, channelCount: expectedOutputChannelCount)
    }

    package func setSpatialSettings(_ settings: SpatialRenderSettings, output: SpatialOutputKind) {
        condition.lock()
        activityGeneration &+= 1
        renderSettings = settings
        renderOutput = output
        condition.unlock()
    }

    package func setSpatialRenderingMode(_ mode: SpatialRenderingMode) {
        condition.lock()
        activityGeneration &+= 1
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
        activityGeneration &+= 1
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
        id: UUID, clip: SpatialCalibrationClip, levelCheckGain: Float = 1,
        started: (@Sendable (TimeInterval) -> Void)? = nil,
        completion: @escaping @Sendable () -> Void
    ) -> Bool {
        let performance = performanceSource.snapshot()
        condition.lock()
        defer { condition.unlock() }
        guard calibrationID == id, !stopping, !workerFinished else { return false }
        guard routeRenderer.acceptsCalibrationClip(clip) else { return false }
        calibrationPlayback = SpatialCalibrationPlayback(clip: clip, levelCheckGain: levelCheckGain, started: started, completion: completion)
        nextCalibrationFrameDate = Date()
        resetQueue(reason: .explicitCalibrationReset, performance: performance)
        needsPCMDiscontinuityReset = true
        condition.signal()
        return true
    }

    package func setLevelCheckGain(id: UUID, gain: Float) {
        condition.lock()
        defer { condition.unlock() }
        guard calibrationID == id, !stopping else { return }
        calibrationPlayback?.setLevelCheckGain(gain)
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
        let hasSignal = frame.interleaved.contains { $0 != 0 }
            || frame.playbackModeSamples.values.contains { $0.contains { $0 != 0 } }
        condition.lock()
        if hasSignal { quietSince = PerformanceClock.now(); inputQuietSince = quietSince; activityGeneration &+= 1 }
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
        defer {
            condition.lock()
            let retired = sink; sink = nil
            condition.unlock()
            retired?.finish()
            condition.lock()
            workerFinished = true
            condition.broadcast()
            condition.unlock()
        }

        while true {
            condition.lock()
            writerBusy = false
            writerBlockInProgressFrames = 0
            func instrumentClockNeeded() -> Bool {
                producerEnded && calibrationID == nil && !measurementHold
                    && pluginProcessor?.requiresContinuousRendering == true
            }
            while queue.isEmpty && calibrationPlayback == nil && pluginTailFrames == 0 && !stopping && !instrumentClockNeeded() && !wasGeneratingInstrument {
                condition.wait()
            }
            if wasGeneratingInstrument && !instrumentClockNeeded() {
                wasGeneratingInstrument = false
                if producerEnded && queue.isEmpty && calibrationID == nil && !measurementHold {
                    // Finish the fade and the backend's partial block when an
                    // idle instrument is bypassed, removed or fails.
                    let fadeFrames = max(128, Int(backendSampleRate * 0.005))
                    pluginTailFrames = ((fadeFrames + backendRemainderFrames + backendChunkFrames - 1) / backendChunkFrames) * backendChunkFrames - backendRemainderFrames
                    instrumentStopPadding = true
                }
            }
            guard !stopping, let sink else {
                condition.unlock()
                return
            }
            writerBusy = true
            if queue.isEmpty, calibrationPlayback == nil, instrumentClockNeeded() {
                let now = DispatchTime.now().uptimeNanoseconds
                if nextInstrumentTick > now {
                    writerBusy = false
                    condition.wait(until: Date().addingTimeInterval(Double(nextInstrumentTick - now) / 1_000_000_000))
                    condition.unlock()
                    continue
                }
                let frames = min(256, backendChunkFrames)
                wasGeneratingInstrument = true
                instrumentStopPadding = false
                let duration = UInt64(Double(frames) / backendSampleRate * 1_000_000_000)
                nextInstrumentTick = max(nextInstrumentTick, now > 2_000_000 ? now - 2_000_000 : 0) + duration
                writerBlockInProgressFrames = frames
                pluginTailFrames = 0
                let workGeneration = bufferWorkGeneration
                condition.unlock()
                let started = PerformanceClock.now()
                var generated = [Float](repeating: 0, count: frames * expectedOutputChannelCount)
                processPlugins(&generated, sampleRate: backendSampleRate)
                masterStage.process(to: &generated, channelCount: expectedOutputChannelCount, sampleRate: backendSampleRate)
                condition.lock()
                if workGeneration == bufferWorkGeneration {
                    let seconds = Double(frames) / backendSampleRate
                    bufferWork.audioSeconds += seconds
                    bufferWork.writerLoad = max(bufferWork.writerLoad, PerformanceClock.milliseconds(started, PerformanceClock.now()) / (1000 * seconds))
                    bufferWork.pluginLoad = max(bufferWork.pluginLoad, lastPluginLoad)
                    bufferWork.pluginFailed = bufferWork.pluginFailed || lastPluginFailed
                }
                condition.unlock()
                do {
                    try sink.write(generated.withUnsafeBytes { Data($0) })
                    backendRemainderFrames = (backendRemainderFrames + frames) % backendChunkFrames
                } catch { failWrite(); return }
                continue
            }
            if queue.isEmpty, calibrationPlayback == nil, pluginTailFrames > 0 {
                let frames = min(256, pluginTailFrames)
                pluginTailFrames -= frames
                condition.unlock()
                var silence = [Float](repeating: 0, count: frames * expectedOutputChannelCount)
                processPlugins(&silence, sampleRate: backendSampleRate)
                if pluginTailFrames == 0 { instrumentStopPadding = false }
                masterStage.process(to: &silence, channelCount: expectedOutputChannelCount, sampleRate: backendSampleRate)
                do {
                    try sink.write(silence.withUnsafeBytes { Data($0) })
                    recordBackendWrite(frames: frames)
                } catch { failWrite(); return }
                continue
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
                    producerEnded = true
                    let discard = needsPCMDiscontinuityReset
                    condition.unlock()
                    do {
                        try routeRenderer.finishProducer(discard: discard) { rendered in
                            condition.lock(); let cancelled = stopping; condition.unlock()
                            if cancelled { throw CancellationError() }
                            var tail = rateStage.processTail(rendered)
                            guard !tail.interleaved.isEmpty else { return }
                            processPlugins(&tail.interleaved, sampleRate: tail.sampleRate)
                            masterStage.process(to: &tail.interleaved, channelCount: tail.channelCount, sampleRate: tail.sampleRate)
                            try sink.write(tail.interleaved.withUnsafeBytes { Data($0) })
                            recordBackendWrite(frames: tail.frameCount)
                        }
                    } catch is CancellationError { return }
                    catch { failWrite(); return }
                    var tailFrames = 0
                    if var tail = rateStage.finish(discard: discard), !tail.interleaved.isEmpty {
                        processPlugins(&tail.interleaved, sampleRate: tail.sampleRate, reset: discard)
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
                    condition.lock()
                    let continuous = instrumentClockNeeded()
                    let requestedTail = discard || continuous ? 0 : min(Int(backendSampleRate * 10), pluginProcessor?.tailFrames ?? 0)
                    condition.unlock()
                    if requestedTail > 0 {
                        pluginTailFrames = ((requestedTail + backendRemainderFrames + backendChunkFrames - 1) / backendChunkFrames) * backendChunkFrames - backendRemainderFrames
                    }
                    let paddingFrames = continuous || pluginTailFrames > 0 || backendRemainderFrames == 0 ? 0 : backendChunkFrames - backendRemainderFrames
                    var remaining = paddingFrames
                    while remaining > 0 {
                        condition.lock(); let cancelled = stopping; condition.unlock()
                        if cancelled { return }
                        let frames = min(remaining, 1024)
                        var silence = Array<Float>(repeating: 0, count: frames * expectedOutputChannelCount)
                        processPlugins(&silence, sampleRate: backendSampleRate)
                        masterStage.process(to: &silence, channelCount: expectedOutputChannelCount, sampleRate: backendSampleRate)
                        do {
                            try sink.write(silence.withUnsafeBytes { Data($0) })
                            recordBackendWrite(frames: frames)
                        } catch { failWrite(); return }
                        remaining -= frames
                    }
                    // Renderer history has drained and retired before resampler
                    // completion and backend padding seal this producer epoch.
                    condition.lock()
                    deliveryStatistics.drains.completedDrains &+= 1
                    deliveryStatistics.drains.resamplerTailFrames &+= UInt64(tailFrames)
                    deliveryStatistics.drains.backendPaddingFrames &+= UInt64(paddingFrames)
                    condition.unlock()
                    continue
                }
                nextFrame = entry?.frame
                if nextFrame != nil {
                    pluginTailFrames = 0; producerEnded = false
                    wasGeneratingInstrument = false; instrumentStopPadding = false
                }
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
            let workGeneration = bufferWorkGeneration
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
            let workStarted = PerformanceClock.now()
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
                resetSpatial: shouldResetSpatialRenderer,
                crossfeed: configuration.crossfeed, bypassCrossfeed: isCalibrationSample)
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
            processPlugins(&adjustedFrame.interleaved, sampleRate: adjustedFrame.sampleRate,
                reset: shouldResetPCMDiscontinuity, bypass: isCalibrationSample)
            masterStage.process(
                to: &adjustedFrame.interleaved,
                channelCount: adjustedFrame.channelCount,
                sampleRate: adjustedFrame.sampleRate
            )
            let workFinished = PerformanceClock.now()
            if !isCalibrationSample, frame.interleaved.contains(where: { $0 != 0 }) {
                let seconds = Double(frame.frameCount) / frame.sampleRate
                condition.lock()
                if workGeneration == bufferWorkGeneration, seconds > 0 {
                    bufferWork.audioSeconds += seconds
                    bufferWork.writerLoad = max(bufferWork.writerLoad,
                        PerformanceClock.milliseconds(workStarted, workFinished) / (1000 * seconds))
                    bufferWork.pluginLoad = max(bufferWork.pluginLoad, lastPluginLoad)
                    bufferWork.pluginFailed = bufferWork.pluginFailed || lastPluginFailed
                }
                condition.unlock()
            }
            let masterCompleted = trace.map { _ in workFinished }
            do {
                let payload = adjustedFrame.interleaved.withUnsafeBytes { Data($0) }
                let pipeWriteStarted = trace.map { _ in PerformanceClock.now() }
                try sink.write(payload)
                recordBackendWrite(frames: adjustedFrame.frameCount)
                if let received = frame.sourceReceivedAt {
                    let completed = PerformanceClock.now()
                    condition.lock()
                    deliveryStatistics.transit = .init(receivedAt: received, completedAt: completed)
                    condition.unlock()
                }
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
        nextInstrumentTick = DispatchTime.now().uptimeNanoseconds + UInt64(Double(frames) / backendSampleRate * 1_000_000_000)
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
