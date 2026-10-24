import CamiTuneAudio
import CamiTuneDomain
import Foundation
import Darwin

/// App-side composition of delivery, bounded analysis, and meter observation.

final class PCMRouter: @unchecked Sendable {
    typealias AnalyzerConsumer = (PCMFrame) -> Void
    typealias MeterConsumer = (PCMFrame) -> Void

    struct Statistics: Sendable {
        var transit: PCMTransitObservation?
        var camillaDroppedFrames: UInt64 = 0
        var camillaQueueRecoveries: UInt64 = 0
        var camillaWriteFailures: UInt64 = 0
        var meterDroppedFrames: UInt64 = 0
        var rateAdjustmentPPM: Double = 0
        var rateMatchBufferedFrames: UInt64 = 0
        var rejectedSourceFrames: UInt64 = 0
        var sourceFormatError: String?
        var deliveryError: String?
        var producerDrains = PCMProducerDrainStatistics()
        var camillaQueue = PCMQueueSnapshot()
    }

    let performanceSource = PerformanceTraceSource()
    private let state = NSLock()
    private let systemMaster = SystemMasterGainControl()
    private var camillaBranch: CamillaDeliveryPipeline?
    private var analyzerBranch: AnalyzerPCMBranch?
    private var meterBranch: MeterPCMBranch?
    private var statisticsValue = Statistics()
    private var activeRoute: ActiveAudioRoute?

    func takeAudioBufferWork() -> AudioBufferWorkObservation {
        state.lock(); let branch = camillaBranch; state.unlock()
        return branch?.takeAudioBufferWork() ?? .init()
    }

    func isQuietForBufferChange(seconds: Double = 3, now: PerformanceTick = PerformanceClock.now()) -> Bool {
        state.lock(); let branch = camillaBranch; let error = statisticsValue.sourceFormatError; state.unlock()
        return error == nil && branch?.isQuietForBufferChange(seconds: seconds, now: now) == true
    }

    func bufferHandoffToken(seconds: Double, now: PerformanceTick = PerformanceClock.now()) -> AudioBufferHandoffToken? {
        state.lock(); let branch = camillaBranch; let error = statisticsValue.sourceFormatError; state.unlock()
        return error == nil ? branch?.bufferHandoffToken(seconds: seconds, now: now) : nil
    }

    func acceptsBufferHandoff(_ token: AudioBufferHandoffToken) -> Bool {
        state.lock(); let branch = camillaBranch; state.unlock()
        return branch?.acceptsBufferHandoff(token) == true
    }

    func replaceBackendIfQuiet(_ replacement: CamillaPCMSink, token: AudioBufferHandoffToken,
        plan: AudioRuntimePlan, clocks: [AudioClockObservation], quietSeconds: Double,
        now: PerformanceTick = PerformanceClock.now()) -> CamillaPCMSink? {
        state.lock(); defer { state.unlock() }
        guard statisticsValue.sourceFormatError == nil else { return nil }
        return camillaBranch?.replaceBackendIfQuiet(replacement, token: token,
            chunkFrames: plan.processingGraph.chunkSize, configuration: plan.deliveryConfiguration,
            clocks: clocks, quietSeconds: quietSeconds, now: now)
    }

    var statistics: Statistics {
        state.lock()
        var value = statisticsValue
        let branch = camillaBranch
        state.unlock()
        if let branch {
            let snapshot = branch.statisticsSnapshot()
            snapshot.delivery.project(into: &value)
            value.camillaQueue = snapshot.queue
        }
        return value
    }

    /// Serializes router replacement without making the caller's executor wait
    /// on worker joins. In particular, AppState can await this from MainActor
    /// without freezing SwiftUI for the branch shutdown timeouts below.
    func start(
        camillaSink: FileHandle? = nil,
        outputSink: (any PCMOutputSink)? = nil,
        activeRoute: ActiveAudioRoute? = nil,
        renderConfiguration: RenderConfiguration,
        deliveryConfiguration: PCMDeliveryConfiguration,
        backendChunkFrames: Int,
        configurationObserver: (@Sendable (RenderConfiguration) -> Void)? = nil,
        referenceTopology: SpeakerTopology? = nil,
        pluginProcessor: (any PluginAudioProcessor)? = nil,
        meterConsumer: MeterConsumer? = nil,
        meterAdmission: (() -> Bool)? = nil,
        analyzerConsumer: AnalyzerConsumer? = nil,
        analyzerAdmission: (() -> UInt64?)? = nil,
        analyzerBatchFrames: Int = 1
    ) async {
        await Task.detached(priority: .userInitiated) { [self] in
            startSynchronously(camillaSink: camillaSink, outputSink: outputSink, activeRoute: activeRoute,
                renderConfiguration: renderConfiguration, deliveryConfiguration: deliveryConfiguration,
                backendChunkFrames: backendChunkFrames,
                configurationObserver: configurationObserver, referenceTopology: referenceTopology, pluginProcessor: pluginProcessor,
                meterConsumer: meterConsumer, meterAdmission: meterAdmission,
                analyzerConsumer: analyzerConsumer, analyzerAdmission: analyzerAdmission,
                analyzerBatchFrames: analyzerBatchFrames)
        }.value
    }

    /// Only prepared configuration enters the production writer. Fixture defaults
    /// live with diagnostics, rather than providing a second runtime plan path.
    private func startSynchronously(
        camillaSink: FileHandle?,
        outputSink: (any PCMOutputSink)?,
        activeRoute: ActiveAudioRoute?,
        renderConfiguration: RenderConfiguration,
        deliveryConfiguration: PCMDeliveryConfiguration,
        backendChunkFrames: Int,
        configurationObserver: (@Sendable (RenderConfiguration) -> Void)?,
        referenceTopology: SpeakerTopology?,
        pluginProcessor: (any PluginAudioProcessor)?,
        meterConsumer: MeterConsumer?,
        meterAdmission: (() -> Bool)?,
        analyzerConsumer: AnalyzerConsumer?,
        analyzerAdmission: (() -> UInt64?)?,
        analyzerBatchFrames: Int
    ) {
        stop()
        let camillaBranch = CamillaDeliveryPipeline(
            sink: outputSink ?? camillaSink.flatMap { try? CamillaPCMSink(duplicating: $0.fileDescriptor) },
            hrtfDatabase: BundledHRTFDatabase.shared, performanceSource: performanceSource, activeRoute: activeRoute,
            renderConfiguration: renderConfiguration, deliveryConfiguration: deliveryConfiguration,
            backendChunkFrames: backendChunkFrames,
            configurationObserver: configurationObserver, systemMaster: systemMaster,
            referenceTopology: referenceTopology, pluginProcessor: pluginProcessor
        )
        let meterBranch = meterConsumer.map { consumer in
            MeterPCMBranch(
                consumer: consumer,
                admission: meterAdmission,
                dropHandler: { [weak self] droppedFrames in
                    self?.recordMeterDrop(droppedFrames: droppedFrames)
                }
            )
        }
        let analyzerBranch = analyzerConsumer.map {
            AnalyzerPCMBranch(consumer: $0, admission: analyzerAdmission, minimumBatchFrames: analyzerBatchFrames)
        }
        state.lock()
        statisticsValue = Statistics()
        self.activeRoute = activeRoute
        self.camillaBranch = camillaBranch
        self.meterBranch = meterBranch
        self.analyzerBranch = analyzerBranch
        state.unlock()

        // Publish/reset before starting workers so an immediate sink failure is
        // observable rather than erased by startup's statistics reset.
        camillaBranch.start()
        meterBranch?.start()
        analyzerBranch?.start()
    }

    /// Update the system master without touching CamillaDSP's control socket or
    /// CoreAudio's active physical endpoint. The PCM writer reads this target
    /// once per block and ramps sample-continuously.
    func setSystemMaster(linearGain: Float, muted: Bool) {
        systemMaster.set(linearGain: linearGain, muted: muted)
    }

    func setRenderConfiguration(_ configuration: RenderConfiguration) {
        state.lock()
        let branch = camillaBranch
        state.unlock()
        branch?.setRenderConfiguration(configuration)
    }

    func setPluginProcessor(_ processor: (any PluginAudioProcessor)?) {
        state.lock(); let branch = camillaBranch; state.unlock()
        branch?.setPluginProcessor(processor)
    }

    func setDeliveryConfiguration(_ configuration: PCMDeliveryConfiguration) {
        state.lock(); let branch = camillaBranch; state.unlock()
        branch?.setDeliveryConfiguration(configuration)
    }

    func observeSourceClock(_ observation: AudioClockObservation) {
        state.lock(); let branch = camillaBranch; state.unlock()
        branch?.observeClock(observation, source: true)
    }

    /// Captures this exact branch. A delayed engine reply can never feed a
    /// replacement session through the router's mutable current-branch pointer.
    func playbackClockConsumer() -> @Sendable (AudioClockObservation) -> Void {
        state.lock(); let branch = camillaBranch; state.unlock()
        if let branch { return branch.playbackClockConsumer() }
        return { _ in }
    }

    /// Called by the single transport reader after routing all PCM authorized
    /// by END. This control shares the writer queue with that PCM.
    func finishProducerEpoch() {
        state.lock(); let branch = camillaBranch; state.unlock()
        branch?.enqueueProducerEnd()
    }

    func setSpatialRenderingMode(_ mode: SpatialRenderingMode) {
        state.lock()
        let camillaBranch = self.camillaBranch
        state.unlock()
        camillaBranch?.setSpatialRenderingMode(mode)
    }

    func setSpatialSettings(_ settings: SpatialRenderSettings, output: SpatialOutputKind) {
        state.lock()
        let branch = camillaBranch
        state.unlock()
        branch?.setSpatialSettings(settings, output: output)
    }

    var referenceSpeakerDiagnostics: ReferenceSpeakerDiagnostics? {
        state.lock(); let branch = camillaBranch; state.unlock()
        return branch?.referenceDiagnostics
    }

    var spatialRenderDiagnostics: SpatialRenderDiagnostics? {
        state.lock()
        let branch = camillaBranch
        state.unlock()
        return branch?.renderDiagnostics
    }

    func route(_ frame: PCMFrame) {
        state.lock()
        do {
            if let activeRoute { try activeRoute.validateSource(frame) }
            else { try ActiveAudioRoute.validateFrame(frame) }
            statisticsValue.sourceFormatError = nil
        } catch {
            statisticsValue.rejectedSourceFrames &+= UInt64(max(0, frame.frameCount))
            statisticsValue.sourceFormatError = error.localizedDescription
            state.unlock()
            return
        }
        let camillaBranch = self.camillaBranch
        let meterBranch = self.meterBranch
        let analyzerBranch = self.analyzerBranch
        state.unlock()

        // These are deliberately independent bounded queues. Analyzer or meter
        // stalls can drop observation frames, but never execute on or hold up
        // the CamillaDSP delivery branch.
        camillaBranch?.enqueue(frame)
        var observation = frame
        observation.playbackModeSamples = [:]
        observation.performanceTrace = nil
        observation.writerTrace = nil
        meterBranch?.enqueue(observation)
        analyzerBranch?.enqueue(observation)
    }



    var spatialContentEstimate: SpatialContentEstimate {
        state.lock()
        defer { state.unlock() }
        return camillaBranch?.contentEstimate ?? .unknown
    }

    func beginSpatialCalibration(id: UUID) -> Bool {
        state.lock()
        defer { state.unlock() }
        return camillaBranch?.beginSpatialCalibration(id: id) ?? false
    }

    func playSpatialCalibration(
        id: UUID, clip: SpatialCalibrationClip, levelCheckGain: Float = 1,
        started: (@Sendable (TimeInterval) -> Void)? = nil,
        completion: @escaping @Sendable () -> Void
    ) -> Bool {
        state.lock()
        defer { state.unlock() }
        return camillaBranch?.playSpatialCalibration(
            id: id, clip: clip, levelCheckGain: levelCheckGain, started: started, completion: completion
        ) ?? false
    }

    func setLevelCheckGain(id: UUID, gain: Float) {
        state.lock()
        defer { state.unlock() }
        camillaBranch?.setLevelCheckGain(id: id, gain: gain)
    }

    func stopSpatialCalibrationSample(id: UUID) {
        state.lock()
        defer { state.unlock() }
        camillaBranch?.stopSpatialCalibrationSample(id: id)
    }

    func holdSpatialMeasurement(id: UUID, enabled: Bool) {
        state.lock()
        defer { state.unlock() }
        camillaBranch?.holdSpatialMeasurement(id: id, enabled: enabled)
    }

    func endSpatialCalibration(id: UUID) {
        state.lock()
        defer { state.unlock() }
        camillaBranch?.endSpatialCalibration(id: id)
    }

    /// Normal runtime shutdown path. The synchronous stop remains available for
    /// process teardown and tests, but AppState should await this method.
    func stopWithoutBlockingUI() async {
        await Task.detached(priority: .userInitiated) { [self] in
            stop()
        }.value
    }

    func stop() {
        state.lock()
        let camillaBranch = self.camillaBranch
        let meterBranch = self.meterBranch
        let analyzerBranch = self.analyzerBranch
        self.camillaBranch = nil
        self.meterBranch = nil
        self.analyzerBranch = nil
        self.activeRoute = nil
        state.unlock()

        camillaBranch?.stop()
        state.lock()
        if self.camillaBranch == nil, let snapshot = camillaBranch?.statisticsSnapshot() {
            snapshot.delivery.project(into: &statisticsValue)
            statisticsValue.camillaQueue = snapshot.queue
        }
        state.unlock()
        meterBranch?.stop()
        analyzerBranch?.stop()
    }

    private func recordMeterDrop(droppedFrames: Int) {
        state.lock()
        statisticsValue.meterDroppedFrames &+= UInt64(max(0, droppedFrames))
        state.unlock()
    }
}

/// A latest-value PCM branch for metering. If UI work falls behind it replaces
/// stale observations instead of applying backpressure to the audio writer.
private final class MeterPCMBranch: @unchecked Sendable {
    private let consumer: PCMRouter.MeterConsumer
    private let admission: (() -> Bool)?
    private let dropHandler: (Int) -> Void
    private let condition = NSCondition()
    private var buffers: [PCMFrame] = []
    private var stopping = false
    private var workerFinished = true
    private var worker: Thread?
    private let maximumQueuedBuffers = 2

    init(
        consumer: @escaping PCMRouter.MeterConsumer,
        admission: (() -> Bool)?,
        dropHandler: @escaping (Int) -> Void
    ) {
        self.consumer = consumer
        self.admission = admission
        self.dropHandler = dropHandler
    }

    func start() {
        condition.lock()
        stopping = false
        workerFinished = false
        condition.unlock()

        let thread = Thread { [weak self] in self?.run() }
        thread.name = "CamiTune Meter PCM Delivery"
        thread.qualityOfService = .userInitiated
        worker = thread
        thread.start()
    }

    func enqueue(_ frame: PCMFrame) {
        // Admission is a cheap presentation/cadence check on the producer.
        // Hidden meters must not wake a worker merely to discard this frame.
        guard admission?() ?? true else { return }
        var droppedFrames = 0
        condition.lock()
        guard !stopping else {
            condition.unlock()
            return
        }
        if buffers.count >= maximumQueuedBuffers {
            droppedFrames = buffers.reduce(0) { $0 + $1.frameCount }
            buffers.removeAll(keepingCapacity: true)
        }
        buffers.append(frame)
        condition.signal()
        condition.unlock()
        if droppedFrames > 0 { dropHandler(droppedFrames) }
    }

    func stop() {
        condition.lock()
        stopping = true
        buffers.removeAll()
        condition.broadcast()
        let deadline = Date().addingTimeInterval(0.25)
        while !workerFinished, condition.wait(until: deadline) {}
        worker = nil
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            while buffers.isEmpty && !stopping { condition.wait() }
            if stopping {
                workerFinished = true
                condition.broadcast()
                condition.unlock()
                return
            }
            let buffer = buffers.removeFirst()
            condition.unlock()
            consumer(buffer)
        }
    }
}

private final class AnalyzerPCMBranch: @unchecked Sendable {
    private let consumer: PCMRouter.AnalyzerConsumer
    private let admission: (() -> UInt64?)?
    private let minimumBatchFrames: Int
    private let condition = NSCondition()
    private var buffers: [PCMFrame] = []
    private var queuedFrames = 0
    private var admissionGeneration: UInt64?
    private var stopping = false
    private var workerFinished = true
    private var worker: Thread?

    init(consumer: @escaping PCMRouter.AnalyzerConsumer, admission: (() -> UInt64?)?, minimumBatchFrames: Int) {
        self.consumer = consumer
        self.admission = admission
        self.minimumBatchFrames = max(1, minimumBatchFrames)
    }

    func start() {
        condition.lock()
        stopping = false
        workerFinished = false
        condition.unlock()

        let thread = Thread { [weak self] in self?.run() }
        thread.name = "CamiTune Analyzer PCM Delivery"
        thread.qualityOfService = .userInitiated
        worker = thread
        thread.start()
    }

    func enqueue(_ frame: PCMFrame) {
        // A token identifies the presentation interval, including a hide/show
        // with no intervening audio packets. Never mix those partial windows.
        let generation: UInt64?
        if let admission { generation = admission() } else { generation = 0 }
        condition.lock()
        defer { condition.unlock() }
        guard !stopping else { return }
        guard let generation else {
            // Do not carry a partial window across a hidden interval.
            buffers.removeAll(keepingCapacity: true)
            queuedFrames = 0
            admissionGeneration = nil
            return
        }
        if admissionGeneration != generation {
            buffers.removeAll(keepingCapacity: true)
            queuedFrames = 0
            admissionGeneration = generation
        }
        // Bound both storage and tiny-packet overhead. An FFT cannot use a new
        // result before a hop's worth of samples arrives, so wake once per hop
        // while retaining every admitted sample in source order.
        guard buffers.count < max(4, minimumBatchFrames),
              queuedFrames < max(frame.frameCount * 4, minimumBatchFrames * 2) else { return }
        let wasReady = queuedFrames >= minimumBatchFrames
        buffers.append(frame)
        queuedFrames += frame.frameCount
        if !wasReady && queuedFrames >= minimumBatchFrames { condition.signal() }
    }

    func stop() {
        condition.lock()
        stopping = true
        buffers.removeAll()
        queuedFrames = 0
        condition.broadcast()
        let deadline = Date().addingTimeInterval(0.25)
        while !workerFinished, condition.wait(until: deadline) {}
        // A failed analyzer must not hold pipeline shutdown indefinitely.
        worker = nil
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            while queuedFrames < minimumBatchFrames && !stopping { condition.wait() }
            if stopping {
                workerFinished = true
                condition.broadcast()
                condition.unlock()
                return
            }
            let batch = buffers
            buffers.removeAll(keepingCapacity: true)
            queuedFrames = 0
            condition.unlock()
            for buffer in batch { consumer(buffer) }
        }
    }
}

private extension PCMDeliveryStatistics {
    func project(into result: inout PCMRouter.Statistics) {
        result.transit = transit
        result.camillaDroppedFrames = droppedFrames
        result.camillaQueueRecoveries = recoveries
        result.camillaWriteFailures = writeFailures
        result.rateAdjustmentPPM = adjustmentPPM
        result.rateMatchBufferedFrames = bufferedFrames
        result.deliveryError = error
        result.producerDrains = drains
    }
}
