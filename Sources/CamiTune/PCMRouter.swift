import Foundation
import Darwin

struct PCMFrame: Sendable {
    var performanceTrace: AudioIntervalTraceContext?
    var writerTrace: PCMWriterTraceContext?
    var interleaved: [Float]
    /// Optional mode buses share this frame's exact format and timeline.
    /// `interleaved` remains the combined signal for observation branches.
    var playbackModeSamples: [PlaybackMode: [Float]] = [:]
    let channelCount: Int
    let sampleRate: Double
    let channelLayout: LPCMChannelLayout
    let sourceBufferedFrames: Int
    let sourceCapacityFrames: Int

    init(
        interleaved: [Float],
        channelCount: Int,
        sampleRate: Double,
        channelLayout: LPCMChannelLayout? = nil,
        sourceBufferedFrames: Int = 0,
        sourceCapacityFrames: Int = 0
    ) {
        self.interleaved = interleaved
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.channelLayout = channelLayout
            ?? LPCMChannelLayout.canonical(forChannelCount: channelCount)
            ?? LPCMChannelLayout(
                coreAudioTag: 0,
                roles: [ChannelRole](repeating: .unknown, count: max(0, channelCount))
            )
        self.sourceBufferedFrames = sourceBufferedFrames
        self.sourceCapacityFrames = sourceCapacityFrames
    }

    var frameCount: Int {
        channelCount > 0 ? interleaved.count / channelCount : 0
    }

    var sourceFormat: SpatialSourceFormat {
        SpatialSourceFormat(layout: channelLayout)
    }
}

private final class SystemMasterGainControl: @unchecked Sendable {
    struct Snapshot {
        let revision: UInt64
        let linearGain: Float
        let muted: Bool
        var effectiveGain: Float { muted ? 0 : linearGain }
    }

    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var linearGain: Float = 1
    private var muted = false

    func set(linearGain: Float, muted: Bool) {
        let clamped = linearGain.isFinite ? min(1, max(0, linearGain)) : 1
        lock.lock()
        if self.linearGain != clamped || self.muted != muted {
            self.linearGain = clamped
            self.muted = muted
            revision &+= 1
        }
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let value = Snapshot(revision: revision, linearGain: linearGain, muted: muted)
        lock.unlock()
        return value
    }
}

final class PCMRouter: @unchecked Sendable {
    typealias AnalyzerConsumer = (PCMFrame) -> Void
    typealias MeterConsumer = (PCMFrame) -> Void

    struct Statistics: Sendable {
        var camillaDroppedFrames: UInt64 = 0
        var camillaQueueRecoveries: UInt64 = 0
        var camillaWriteFailures: UInt64 = 0
        var meterDroppedFrames: UInt64 = 0
        var rateAdjustmentPPM: Double = 0
        var rateMatchBufferedFrames: UInt64 = 0
        var rejectedSourceFrames: UInt64 = 0
        var sourceFormatError: String?
        var camillaQueue = PCMQueueSnapshot()
    }

    let performanceSource = PerformanceTraceSource()
    private let state = NSLock()
    private let systemMaster = SystemMasterGainControl()
    private var camillaBranch: CamillaPCMBranch?
    private var analyzerBranch: AnalyzerPCMBranch?
    private var meterBranch: MeterPCMBranch?
    private var statisticsValue = Statistics()
    private var spatialRenderingMode: SpatialRenderingMode = .standard
    private var activeRoute: ActiveAudioRoute?

    var statistics: Statistics {
        state.lock()
        var value = statisticsValue
        let branch = camillaBranch
        state.unlock()
        if let branch { value.camillaQueue = branch.queueSnapshot }
        return value
    }

    /// Serializes router replacement without making the caller's executor wait
    /// on worker joins. In particular, AppState can await this from MainActor
    /// without freezing SwiftUI for the branch shutdown timeouts below.
    func start(
        camillaSink: FileHandle,
        activeRoute: ActiveAudioRoute? = nil,
        renderConfiguration: RenderConfiguration? = nil,
        configurationObserver: (@Sendable (RenderConfiguration) -> Void)? = nil,
        spatialRenderingMode: SpatialRenderingMode = .standard,
        spatialListenerTuning: SpatialListenerTuning = .neutral,
        spatialContentMode: SpatialContentMode = .automatic,
        spatialSettings: SpatialRenderSettings = SpatialRenderSettings(),
        spatialOutput: SpatialOutputKind = .speakers,
        referenceTopology: SpeakerTopology? = nil,
        playbackMode: PlaybackMode? = nil,
        referenceCorrection: DeviceCorrectionProfile? = nil,
        meterConsumer: MeterConsumer? = nil,
        analyzerConsumer: AnalyzerConsumer? = nil
    ) async {
        await Task.detached(priority: .userInitiated) { [self] in
            startSynchronously(
                camillaSink: camillaSink,
                activeRoute: activeRoute,
                renderConfiguration: renderConfiguration,
                configurationObserver: configurationObserver,
                spatialRenderingMode: spatialRenderingMode,
                spatialListenerTuning: spatialListenerTuning,
                spatialContentMode: spatialContentMode,
                spatialSettings: spatialSettings,
                spatialOutput: spatialOutput,
            referenceTopology: referenceTopology,
            playbackMode: playbackMode, referenceCorrection: referenceCorrection,
                meterConsumer: meterConsumer,
                analyzerConsumer: analyzerConsumer
            )
        }.value
    }

    /// Blocking lifecycle primitive. Keep it private so normal runtime code
    /// cannot accidentally join PCM workers on MainActor.
    private func startSynchronously(
        camillaSink: FileHandle,
        activeRoute: ActiveAudioRoute?,
        renderConfiguration: RenderConfiguration?,
        configurationObserver: (@Sendable (RenderConfiguration) -> Void)?,
        spatialRenderingMode: SpatialRenderingMode,
        spatialListenerTuning: SpatialListenerTuning,
        spatialContentMode: SpatialContentMode,
        spatialSettings: SpatialRenderSettings,
        spatialOutput: SpatialOutputKind,
        referenceTopology: SpeakerTopology?,
        playbackMode: PlaybackMode?,
        referenceCorrection: DeviceCorrectionProfile?,
        meterConsumer: MeterConsumer?,
        analyzerConsumer: AnalyzerConsumer?
    ) {
        stop()
        let camillaBranch = CamillaPCMBranch(
            handle: camillaSink,
            performanceSource: performanceSource,
            activeRoute: activeRoute,
            renderConfiguration: renderConfiguration,
            configurationObserver: configurationObserver,
            systemMaster: systemMaster,
            spatialRenderingMode: spatialRenderingMode,
            spatialListenerTuning: spatialListenerTuning,
            spatialContentMode: spatialContentMode,
            spatialSettings: spatialSettings,
            spatialOutput: spatialOutput,
            referenceTopology: referenceTopology,
            playbackMode: playbackMode, referenceCorrection: referenceCorrection,
            recoveryHandler: { [weak self] droppedFrames in
                self?.recordCamillaRecovery(droppedFrames: droppedFrames)
            },
            failureHandler: { [weak self] in
                self?.recordCamillaWriteFailure()
            },
            adjustmentHandler: { [weak self] adjustmentPPM, bufferedFrames in
                self?.recordRateAdjustment(
                    adjustmentPPM: adjustmentPPM,
                    bufferedFrames: bufferedFrames
                )
            }
        )
        let meterBranch = meterConsumer.map { consumer in
            MeterPCMBranch(
                consumer: consumer,
                dropHandler: { [weak self] droppedFrames in
                    self?.recordMeterDrop(droppedFrames: droppedFrames)
                }
            )
        }
        let analyzerBranch = analyzerConsumer.map(AnalyzerPCMBranch.init(consumer:))
        camillaBranch.start()
        meterBranch?.start()
        analyzerBranch?.start()

        state.lock()
        statisticsValue = Statistics()
        self.activeRoute = activeRoute
        self.spatialRenderingMode = renderConfiguration?.spatialRenderingMode ?? spatialRenderingMode
        self.camillaBranch = camillaBranch
        self.meterBranch = meterBranch
        self.analyzerBranch = analyzerBranch
        state.unlock()
    }

    /// Update the system master without touching CamillaDSP's control socket or
    /// CoreAudio's active physical endpoint. The PCM writer reads this target
    /// once per block and ramps sample-continuously.
    func setSystemMaster(linearGain: Float, muted: Bool) {
        systemMaster.set(linearGain: linearGain, muted: muted)
    }

    func setRenderConfiguration(_ configuration: RenderConfiguration) {
        state.lock()
        spatialRenderingMode = configuration.spatialRenderingMode
        let branch = camillaBranch
        state.unlock()
        branch?.setRenderConfiguration(configuration)
    }

    func setPlaybackMode(_ mode: PlaybackMode, correction: DeviceCorrectionProfile?) {
        state.lock(); defer { state.unlock() }
        camillaBranch?.setPlaybackMode(mode, correction: correction)
    }

    func setSpatialRenderingMode(_ mode: SpatialRenderingMode) {
        state.lock()
        spatialRenderingMode = mode
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

    func setSpatialListenerTuning(_ tuning: SpatialListenerTuning) {
        state.lock()
        defer { state.unlock() }
        camillaBranch?.setSpatialListenerTuning(tuning)
    }

    func setSpatialContentMode(_ mode: SpatialContentMode) {
        state.lock()
        defer { state.unlock() }
        camillaBranch?.setSpatialContentMode(mode)
    }

    func setVirtualSurroundLayout(_ layout: VirtualSurroundLayout) {
        state.lock()
        defer { state.unlock() }
        camillaBranch?.setVirtualSurroundLayout(layout)
    }

    var spatialContentEstimate: SpatialContentEstimate {
        state.lock()
        defer { state.unlock() }
        return camillaBranch?.contentEstimate ?? .unknown
    }

    func beginSpatialCalibration(id: UUID, tuning: SpatialListenerTuning) -> Bool {
        state.lock()
        defer { state.unlock() }
        return camillaBranch?.beginSpatialCalibration(id: id, tuning: tuning) ?? false
    }

    func playSpatialCalibration(
        id: UUID, clip: SpatialCalibrationClip, tuning: SpatialListenerTuning,
        completion: @escaping @Sendable () -> Void
    ) -> Bool {
        state.lock()
        defer { state.unlock() }
        return camillaBranch?.playSpatialCalibration(
            id: id, clip: clip, tuning: tuning, completion: completion
        ) ?? false
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
        if let snapshot = camillaBranch?.queueSnapshot {
            state.lock()
            if self.camillaBranch == nil { statisticsValue.camillaQueue = snapshot }
            state.unlock()
        }
        meterBranch?.stop()
        analyzerBranch?.stop()
    }

    private func recordCamillaRecovery(droppedFrames: Int) {
        state.lock()
        statisticsValue.camillaDroppedFrames += UInt64(max(0, droppedFrames))
        statisticsValue.camillaQueueRecoveries += 1
        state.unlock()
    }

    private func recordCamillaWriteFailure() {
        state.lock()
        statisticsValue.camillaWriteFailures += 1
        state.unlock()
    }

    private func recordMeterDrop(droppedFrames: Int) {
        state.lock()
        statisticsValue.meterDroppedFrames &+= UInt64(max(0, droppedFrames))
        state.unlock()
    }

    private func recordRateAdjustment(adjustmentPPM: Double, bufferedFrames: Int) {
        state.lock()
        statisticsValue.rateAdjustmentPPM = adjustmentPPM
        statisticsValue.rateMatchBufferedFrames = UInt64(max(0, bufferedFrames))
        state.unlock()
    }
}

/// A latest-value PCM branch for metering. If UI work falls behind it replaces
/// stale observations instead of applying backpressure to the audio writer.
private final class MeterPCMBranch: @unchecked Sendable {
    private let consumer: PCMRouter.MeterConsumer
    private let dropHandler: (Int) -> Void
    private let condition = NSCondition()
    private var buffers: [PCMFrame] = []
    private var stopping = false
    private var workerFinished = true
    private var worker: Thread?
    private let maximumQueuedBuffers = 2

    init(
        consumer: @escaping PCMRouter.MeterConsumer,
        dropHandler: @escaping (Int) -> Void
    ) {
        self.consumer = consumer
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
    private let condition = NSCondition()
    private var buffers: [PCMFrame] = []
    private var stopping = false
    private var workerFinished = true
    private var worker: Thread?
    private let maximumQueuedBuffers = 4

    init(consumer: @escaping PCMRouter.AnalyzerConsumer) {
        self.consumer = consumer
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
        condition.lock()
        defer { condition.unlock() }
        guard !stopping, buffers.count < maximumQueuedBuffers else { return }
        buffers.append(frame)
        condition.signal()
    }

    func stop() {
        condition.lock()
        stopping = true
        buffers.removeAll()
        condition.broadcast()
        let deadline = Date().addingTimeInterval(0.25)
        while !workerFinished, condition.wait(until: deadline) {}
        // A failed analyzer must not hold pipeline shutdown indefinitely. If
        // its consumer is stuck, the detached branch exits after that call
        // eventually returns; the router has already released it.
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

struct LowLatencyPCMQueue {
    private struct Buffer {
        var frame: PCMFrame
    }

    private var buffers: [Buffer] = []
    private(set) var queuedFrames = 0
    private var sampleRate = 0.0
    private(set) var snapshot = PCMQueueSnapshot()
    let maximumDuration: TimeInterval

    init(maximumDuration: TimeInterval = 0.1) {
        self.maximumDuration = maximumDuration
    }

    var isEmpty: Bool { buffers.isEmpty }
    var bufferCount: Int { buffers.count }
    var lastEnqueuedTrace: PCMWriterTraceContext? { buffers.last?.frame.writerTrace }

    mutating func append(_ frame: PCMFrame, performance: PerformanceCaptureBinding? = nil) -> Int {
        let frameCount = frame.frameCount
        let sampleRate = frame.sampleRate
        guard frameCount > 0, sampleRate > 0 else { return 0 }
        var droppedFrames = 0
        let before = queuedFrames
        let previousRate = self.sampleRate
        if self.sampleRate != 0, self.sampleRate != sampleRate {
            droppedFrames += clear()
        }
        self.sampleRate = sampleRate

        let maximumFrames = max(frameCount, Int(sampleRate * maximumDuration))
        if queuedFrames + frameCount > maximumFrames {
            droppedFrames += clear()
        }
        buffers.append(Buffer(frame: frame))
        queuedFrames += frameCount
        snapshot.queuedFrames = queuedFrames
        snapshot.capacityFrames = maximumFrames
        snapshot.sampleRate = sampleRate
        snapshot.peakQueuedFrames = max(snapshot.peakQueuedFrames, queuedFrames)
        snapshot.peakDurationMilliseconds = max(snapshot.peakDurationMilliseconds, Double(queuedFrames) * 1000 / sampleRate)
        if droppedFrames > 0 {
            snapshot.lastRecoveryUptime = PerformanceClock.now().rawValue
            snapshot.lastRecoveryDroppedFrames = droppedFrames
            snapshot.lastRecoveryQueuedFrames = before
            snapshot.lastRecoveryIncomingFrames = frameCount
            snapshot.lastRecoverySampleRate = previousRate > 0 ? previousRate : sampleRate
        }
        let interval = frame.performanceTrace
        if let capture = interval?.capture ?? performance?.capture,
           let session = interval?.identity.runtimeSessionID ?? performance?.sessionID {
            let identity = interval?.identity ?? AudioTraceIdentity(captureID: capture.id, runtimeSessionID: session,
                transportGeneration: 0, streamEpoch: 0, deviceObjectID: 0, startSampleTime: 0,
                frameCount: frameCount, sampleRate: sampleRate, channelCount: frame.channelCount)
            buffers[buffers.count - 1].frame.writerTrace = PCMWriterTraceContext(capture: capture, identity: identity,
                interval: interval, entered: PerformanceClock.now(), queueBefore: before, queueAfter: queuedFrames, capacity: maximumFrames)
        }
        return droppedFrames
    }

    mutating func removeFirst() -> PCMFrame? {
        guard !buffers.isEmpty else { return nil }
        let buffer = buffers.removeFirst()
        queuedFrames -= buffer.frame.frameCount
        snapshot.latestBlockFrames = buffer.frame.frameCount
        snapshot.queuedFrames = queuedFrames
        return buffer.frame
    }

    @discardableResult
    mutating func clear() -> Int {
        let droppedFrames = queuedFrames
        buffers.removeAll(keepingCapacity: true)
        queuedFrames = 0
        snapshot.queuedFrames = 0
        return droppedFrames
    }
}

private final class CamillaPCMBranch: @unchecked Sendable {
    // Own a duplicate of CamillaDSP stdin instead of retaining the manager's
    // FileHandle object. Foundation FileHandle raises NSException (not a Swift
    // Error) if write(contentsOf:) races with close() on that same object.
    // Keeping a separate descriptor gives the writer independent lifetime.
    private let handle: FileHandle?
    private let performanceSource: PerformanceTraceSource
    private var writerBlockInProgressFrames = 0
    private let systemMaster: SystemMasterGainControl
    private let activeRoute: ActiveAudioRoute?
    private var directMapper: DirectChannelMapper?
    private let recoveryHandler: (Int) -> Void
    private let failureHandler: () -> Void
    private let adjustmentHandler: (Double, Int) -> Void
    private let condition = NSCondition()
    private var renderConfiguration: RenderConfiguration
    private let configurationObserver: (@Sendable (RenderConfiguration) -> Void)?
    private var queue = LowLatencyPCMQueue()
    private var stopping = false
    private var workerFinished = true
    private var worker: Thread?
    private var needsRateMatcherReset = false
    private var rateController = AdaptiveRateController()
    private var resampler = AdaptivePCMResampler()
    private let sourceRouter = SpatialSourceRouter()
    private var contentAnalyzer = SpatialContentAnalyzer()
    private var spatialContentMode: SpatialContentMode {
        get { renderConfiguration.spatialContentMode }
        set { renderConfiguration.spatialContentMode = newValue }
    }
    private var publishedContentEstimate = SpatialContentEstimate.unknown
    private var contentEstimateDate = Date.distantPast
    private var needsContentReset = false
    private let spatialEngine = SpatialAudioEngine()
    private var referenceRenderer: ReferenceSpeakerRenderer?
    private var physicalModeRenderer: PhysicalSpeakerModeRenderer?
    private var playbackMode: PlaybackMode {
        get { renderConfiguration.playbackMode }
        set { renderConfiguration.playbackMode = newValue }
    }
    private var referenceCorrection: DeviceCorrectionProfile? {
        get { renderConfiguration.referenceCorrection }
        set { renderConfiguration.referenceCorrection = newValue }
    }
    private var correctionBank = PerAppFilterBank()
    private var correctionSignature: DeviceCorrectionProfile?
    private var correctionGain: Float = 1
    private var busSafetyGain: Float = 1
    private let referenceTopology: SpeakerTopology?
    private let expectedOutputChannelCount: Int
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
    private var virtualSurroundLayout: VirtualSurroundLayout {
        get { renderConfiguration.virtualSurroundLayout }
        set { renderConfiguration.virtualSurroundLayout = newValue }
    }
    private var lastSourceFormat: SpatialSourceFormat?
    private var renderedModeBuses: Set<PlaybackMode> = []
    private var spatialRenderingMode: SpatialRenderingMode {
        get { renderConfiguration.spatialRenderingMode }
        set { renderConfiguration.spatialRenderingMode = newValue }
    }
    private var spatialListenerTuning: SpatialListenerTuning {
        get { renderConfiguration.spatialListenerTuning }
        set { renderConfiguration.spatialListenerTuning = newValue }
    }
    private var calibrationID: UUID?
    private var calibrationTuning: SpatialListenerTuning?
    private var calibrationPlayback: SpatialCalibrationPlayback?
    private var measurementHold = false
    private var nextCalibrationFrameDate = Date()
    private var needsSpatialReset = false
    private var masterRevision: UInt64 = UInt64.max
    private var currentMasterGain: Float = 1
    private var targetMasterGain: Float = 1
    private var masterRampFramesRemaining = 0
    private var masterRampStep: Float = 0

    init(
        handle: FileHandle,
        performanceSource: PerformanceTraceSource,
        activeRoute: ActiveAudioRoute?,
        renderConfiguration: RenderConfiguration?,
        configurationObserver: (@Sendable (RenderConfiguration) -> Void)?,
        systemMaster: SystemMasterGainControl,
        spatialRenderingMode: SpatialRenderingMode,
        spatialListenerTuning: SpatialListenerTuning,
        spatialContentMode: SpatialContentMode,
        spatialSettings: SpatialRenderSettings,
        spatialOutput: SpatialOutputKind,
        referenceTopology: SpeakerTopology?,
        playbackMode: PlaybackMode?,
        referenceCorrection: DeviceCorrectionProfile?,
        recoveryHandler: @escaping (Int) -> Void,
        failureHandler: @escaping () -> Void,
        adjustmentHandler: @escaping (Double, Int) -> Void
    ) {
        self.performanceSource = performanceSource
        let duplicatedDescriptor = Darwin.dup(handle.fileDescriptor)
        if duplicatedDescriptor >= 0 {
            self.handle = FileHandle(
                fileDescriptor: duplicatedDescriptor,
                closeOnDealloc: true
            )
        } else {
            self.handle = nil
        }
        self.renderConfiguration = renderConfiguration ?? .init(mode: spatialRenderingMode, tuning: spatialListenerTuning,
            content: spatialContentMode, settings: spatialSettings, output: spatialOutput,
            playback: playbackMode ?? (referenceTopology != nil ? .referencePlayback : spatialRenderingMode == .standard ? .direct : .spatialRender),
            correction: referenceCorrection)
        self.configurationObserver = configurationObserver
        self.physicalModeRenderer = referenceTopology.flatMap { try? PhysicalSpeakerModeRenderer(topology: $0) }
        self.referenceTopology = referenceTopology
        self.activeRoute = activeRoute
        self.expectedOutputChannelCount = activeRoute?.dspInputFormat.channelCount ?? referenceTopology?.declaredChannelCount ?? 2
        self.referenceRenderer = referenceTopology.flatMap { try? ReferenceSpeakerRenderer(topology: $0) }
        self.systemMaster = systemMaster
        let initialMaster = systemMaster.snapshot()
        masterRevision = initialMaster.revision
        currentMasterGain = initialMaster.effectiveGain
        targetMasterGain = initialMaster.effectiveGain
        self.recoveryHandler = recoveryHandler
        self.failureHandler = failureHandler
        self.adjustmentHandler = adjustmentHandler
    }

    var queueSnapshot: PCMQueueSnapshot {
        condition.lock(); defer { condition.unlock() }; return queue.snapshot
    }

    var referenceDiagnostics: ReferenceSpeakerDiagnostics? {
        condition.lock(); defer { condition.unlock() }
        return publishedReferenceDiagnostics
    }

    var renderDiagnostics: SpatialRenderDiagnostics? {
        condition.lock()
        defer { condition.unlock() }
        return publishedRenderDiagnostics
    }

    func setRenderConfiguration(_ configuration: RenderConfiguration) {
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

    func setPlaybackMode(_ mode: PlaybackMode, correction: DeviceCorrectionProfile?) {
        condition.lock(); defer { condition.unlock() }
        playbackMode = mode
        referenceCorrection = correction
    }

    func setSpatialSettings(_ settings: SpatialRenderSettings, output: SpatialOutputKind) {
        condition.lock()
        renderSettings = settings
        renderOutput = output
        condition.unlock()
    }

    func setSpatialRenderingMode(_ mode: SpatialRenderingMode) {
        condition.lock()
        let normalized: SpatialRenderingMode = mode == .standard ? .standard : .spatialAudio
        if mode == .frontStage || mode == .virtualSurround { renderSettings.enabled = true }
        if spatialRenderingMode != normalized {
            spatialRenderingMode = normalized
            needsSpatialReset = true
        }
        condition.unlock()
    }

    func start() {
        condition.lock()
        stopping = false
        workerFinished = handle == nil
        condition.unlock()

        guard handle != nil else {
            failureHandler()
            return
        }

        let thread = Thread { [weak self] in self?.run() }
        thread.name = "CamiTune CamillaDSP PCM Writer"
        thread.qualityOfService = .userInteractive
        worker = thread
        thread.start()
    }

    func setSpatialListenerTuning(_ tuning: SpatialListenerTuning) {
        condition.lock()
        spatialListenerTuning = tuning.validated
        condition.unlock()
    }

    func beginSpatialCalibration(id: UUID, tuning: SpatialListenerTuning) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !stopping, !workerFinished, calibrationID == nil else { return false }
        calibrationID = id
        needsContentReset = true
        calibrationTuning = tuning.validated
        return true
    }

    var contentEstimate: SpatialContentEstimate {
        condition.lock()
        defer { condition.unlock() }
        return Date().timeIntervalSince(contentEstimateDate) < 1 ? publishedContentEstimate : .unknown
    }

    func setSpatialContentMode(_ mode: SpatialContentMode) {
        condition.lock()
        defer { condition.unlock() }
        guard spatialContentMode != mode else { return }
        spatialContentMode = mode
        needsContentReset = true
    }

    func setVirtualSurroundLayout(_ layout: VirtualSurroundLayout) {
        condition.lock()
        defer { condition.unlock() }
        virtualSurroundLayout = layout
    }

    func playSpatialCalibration(
        id: UUID, clip: SpatialCalibrationClip, tuning: SpatialListenerTuning,
        completion: @escaping @Sendable () -> Void
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard calibrationID == id, !stopping, !workerFinished else { return false }
        if let activeRoute, clip.sampleRate != Double(activeRoute.dspInputFormat.sampleRate) { return false }
        if let physical = clip.physicalOutput {
            guard physical.deviceUID == referenceTopology?.deviceUID,
                  clip.sampleRate == referenceTopology?.sampleRate,
                  clip.channelCount == referenceTopology?.declaredChannelCount,
                  activeRoute.map({ route in route.dspInputFormat.channels.contains { $0.physicalOutputID == physical } }) ?? true,
                  referenceTopology?.endpoints.contains(where: { $0.id == physical && $0.connectionState != .disabledByUser }) == true else { return false }
        } else if referenceTopology != nil && clip.isAcousticMeasurement {
            return false
        }
        calibrationTuning = tuning.validated
        calibrationPlayback = SpatialCalibrationPlayback(clip: clip, completion: completion)
        nextCalibrationFrameDate = Date()
        queue.clear()
        needsRateMatcherReset = true
        condition.signal()
        return true
    }

    func stopSpatialCalibrationSample(id: UUID) {
        condition.lock()
        defer { condition.unlock() }
        guard calibrationID == id else { return }
        calibrationPlayback?.requestStop()
        condition.signal()
    }

    func endSpatialCalibration(id: UUID) {
        condition.lock()
        defer { condition.unlock() }
        guard calibrationID == id else { return }
        calibrationID = nil
        measurementHold = false
        calibrationTuning = nil
        calibrationPlayback?.requestStop()
        condition.signal()
    }

    func enqueue(_ frame: PCMFrame) {
        let performance = performanceSource.snapshot()
        condition.lock()
        guard !stopping, calibrationPlayback == nil, !measurementHold else {
            condition.unlock()
            return
        }
        let droppedFrames = queue.append(frame, performance: performance)
        let recovery = queue.snapshot
        let entry = queue.lastEnqueuedTrace
        let writerFrames = writerBlockInProgressFrames
        if droppedFrames > 0 { needsRateMatcherReset = true }
        condition.signal()
        condition.unlock()
        if let entry {
            entry.capture.append(.queue(.init(identity: entry.identity, timestamp: entry.entered, isEntry: true,
                queuedFrames: entry.queueAfter, capacityFrames: entry.capacity)))
        }
        if droppedFrames > 0 {
            recoveryHandler(droppedFrames)
            if let performance, let session = performance.sessionID, let timestamp = recovery.lastRecoveryUptime {
                performance.capture.append(.recovery(.init(captureID: performance.capture.id, runtimeSessionID: session,
                    timestamp: .init(rawValue: timestamp), queuedFramesBeforeRecovery: recovery.lastRecoveryQueuedFrames,
                    incomingFrames: recovery.lastRecoveryIncomingFrames, droppedFrames: droppedFrames,
                    sampleRate: recovery.lastRecoverySampleRate, writerBlockInProgressFrames: writerFrames)))
            }
        }
    }

    func holdSpatialMeasurement(id: UUID, enabled: Bool) {
        condition.lock()
        defer { condition.unlock() }
        guard calibrationID == id else { return }
        measurementHold = enabled
        if enabled { queue.clear(); needsRateMatcherReset = true }
    }

    func stop() {
        condition.lock()
        stopping = true
        calibrationID = nil
        calibrationTuning = nil
        calibrationPlayback = nil
        queue.clear()
        condition.broadcast()
        let deadline = Date().addingTimeInterval(0.5)
        while !workerFinished, condition.wait(until: deadline) {}
        // Keep the join finite. The branch owns a duplicated descriptor, so
        // CamillaDSPManager can close its stdin handle independently without
        // invalidating an in-flight Foundation write on this worker.
        let canCloseHandle = workerFinished
        worker = nil
        condition.unlock()

        // Never close this FileHandle while its worker may still be inside
        // write(contentsOf:); doing so recreates the NSConcreteFileHandle race
        // this ownership split is intended to eliminate.
        if canCloseHandle { try? handle?.close() }
    }

    private func renderModeBuses(_ frame: PCMFrame, mode: PlaybackMode, settings: SpatialRenderSettings,
                                 output: SpatialOutputKind, correction: DeviceCorrectionProfile?) -> PCMFrame? {
        let modes: [PlaybackMode]
        if frame.playbackModeSamples.isEmpty {
            modes = [mode]
        } else {
            // Continue previously used buses for filter/reverb tails, but do
            // not run unused Reference/Spatial renderers for Direct playback.
            renderedModeBuses.formUnion(frame.playbackModeSamples.keys)
            modes = PlaybackMode.allCases.filter { renderedModeBuses.contains($0) }
        }
        var sum: PCMFrame?
        for busMode in modes {
            var bus = frame
            bus.playbackModeSamples = [:]
            if !frame.playbackModeSamples.isEmpty {
                bus.interleaved = frame.playbackModeSamples[busMode] ?? [Float](repeating: 0, count: frame.interleaved.count)
            }
            let rendered: PCMFrame?
            if activeRoute?.usesSourceProcessingBus == true && busMode != .direct { return nil }
            if let route = activeRoute, route.usesPhysicalSpeakerBus, busMode == .direct {
                if directMapper?.sourceLayout != bus.channelLayout {
                    directMapper = try? route.directMapper(for: bus.channelLayout)
                }
                rendered = try? directMapper?.prepare(bus)
            } else if let renderer = physicalModeRenderer {
                let physical = try? renderer.render(bus, mode: busMode, settings: settings)
                if let route = activeRoute, let physical {
                    rendered = try? route.preparePhysicalCompatibilityFrame(physical)
                } else { rendered = physical }
            } else if busMode == .spatialRender {
                var enabled = settings; enabled.enabled = true
                rendered = spatialEngine.render(frame: bus, settings: enabled, detectedOutput: output)
            } else {
                rendered = sourceRouter.stereoFallback(for: bus)
            }
            guard var rendered else { return nil }
            if busMode == .referencePlayback, physicalModeRenderer == nil {
                if correctionSignature != correction {
                    correctionSignature = correction
                    correctionGain = Float(pow(10, ReferenceCorrection.headroomDB(correction, sampleRate: frame.sampleRate) / 20))
                    correctionBank = PerAppFilterBank()
                }
                if let correction, correction.isEnabled {
                    correctionBank.process(&rendered.interleaved, channelCount: rendered.channelCount,
                        sampleRate: rendered.sampleRate, bands: correction.filters, settingsRevision: 0)
                    for i in rendered.interleaved.indices { rendered.interleaved[i] *= correctionGain }
                }
            }
            if sum == nil { sum = rendered }
            else {
                guard sum!.interleaved.count == rendered.interleaved.count else { return nil }
                for i in rendered.interleaved.indices { sum!.interleaved[i] += rendered.interleaved[i] }
            }
        }
        guard var result = sum else { return nil }
        // Linked sample-wise safety after summing buses, with release independent of block size.
        let release = Float(1 - exp(-1 / (frame.sampleRate * 0.2)))
        for f in 0..<result.frameCount {
            let offset = f * result.channelCount
            var peak: Float = 1
            for c in 0..<result.channelCount { peak = max(peak, abs(SpatialSafety.sample(result.interleaved[offset + c]))) }
            let target = 1 / peak
            busSafetyGain = target < busSafetyGain ? target : busSafetyGain + release * (target - busSafetyGain)
            for c in 0..<result.channelCount { result.interleaved[offset + c] = SpatialSafety.sample(result.interleaved[offset + c]) * busSafetyGain }
        }
        return result
    }

    private func run() {
        guard let handle else {
            condition.lock()
            workerFinished = true
            condition.broadcast()
            condition.unlock()
            return
        }

        while true {
            condition.lock()
            writerBlockInProgressFrames = 0
            while queue.isEmpty && calibrationPlayback == nil && !stopping { condition.wait() }
            if stopping {
                workerFinished = true
                condition.broadcast()
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
                nextFrame = queue.removeFirst()
            }
            guard let frame = nextFrame else {
                condition.unlock()
                continue
            }
            let trace = frame.writerTrace.flatMap { $0.capture.accepts(PerformanceClock.now()) ? $0 : nil }
            let queueLeft = trace.map { _ in PerformanceClock.now() }
            writerBlockInProgressFrames = frame.frameCount
            let queuedFrames = queue.queuedFrames
            let shouldResetRateMatcher = needsRateMatcherReset
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
            needsRateMatcherReset = false
            needsSpatialReset = false
            condition.unlock()
            configurationObserver?(configuration)
            if let trace, let queueLeft {
                trace.capture.append(.queue(.init(identity: trace.identity, timestamp: queueLeft, isEntry: false,
                    queuedFrames: queuedFrames, capacityFrames: trace.capacity)))
            }
            if shouldResetContent || shouldResetRateMatcher || shouldResetSpatialRenderer || lastSourceFormat != frame.sourceFormat {
                contentAnalyzer.reset()
            }
            if shouldAnalyzeContent { contentAnalyzer.ingest(frame) }
            else { contentAnalyzer.reset() }
            condition.lock()
            publishedContentEstimate = contentAnalyzer.estimate
            contentEstimateDate = Date()
            condition.unlock()
            if shouldResetRateMatcher {
                spatialEngine.reset(); referenceRenderer?.reset(); physicalModeRenderer?.reset(); correctionBank = PerAppFilterBank(); rateController.reset(); resampler.reset()
                renderedModeBuses.removeAll()
            }
            if shouldResetSpatialRenderer {
                spatialEngine.reset(); referenceRenderer?.reset(); physicalModeRenderer?.reset()
                renderedModeBuses.removeAll()
            }
            lastSourceFormat = frame.sourceFormat
            // All modes and calibration converge on the active DSP input bus.
            // Expansion to the full hardware width happens in the graph.
            let renderedFrame: PCMFrame?
            if let physicalOutput {
                // Physical audition/measurement is already mapped. Never feed it
                // through the scene renderer or stereo downmixer.
                if physicalOutput.deviceUID == referenceTopology?.deviceUID,
                   frame.channelCount == referenceTopology?.declaredChannelCount {
                    if let activeRoute { renderedFrame = try? activeRoute.preparePhysicalCompatibilityFrame(frame) }
                    else { renderedFrame = frame }
                } else { renderedFrame = nil }
            } else {
                renderedFrame = renderModeBuses(frame, mode: isAcousticMeasurement ? .direct : currentMode,
                    settings: renderSettings, output: renderOutput, correction: correction)
            }
            condition.lock()
            publishedReferenceDiagnostics = physicalModeRenderer?.diagnostics ?? referenceRenderer?.diagnostics
            publishedRenderDiagnostics = spatialRenderingMode == .spatialAudio || hasSpatialBus ? (physicalModeRenderer?.spatialDiagnostics ?? spatialEngine.diagnostics) : nil
            condition.unlock()
            guard let renderedFrame, renderedFrame.channelCount == expectedOutputChannelCount else {
                recoveryHandler(frame.frameCount)
                continue
            }
            if let activeRoute, (try? activeRoute.validateDSPFrame(renderedFrame)) == nil {
                recoveryHandler(frame.frameCount)
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
            let localQueueCapacityFrames = max(frame.frameCount * 8, frame.frameCount)
            let adjustmentPPM = isCalibrationSample ? 0 : rateController.update(
                bufferedFrames: bufferedFrames,
                sourceCapacityFrames: localQueueCapacityFrames,
                sampleRate: frame.sampleRate,
                elapsedFrames: frame.frameCount
            )
            adjustmentHandler(adjustmentPPM, bufferedFrames)
            var adjustedFrame = isCalibrationSample
                ? renderedFrame : resampler.process(renderedFrame, adjustmentPPM: adjustmentPPM)
            guard !adjustedFrame.interleaved.isEmpty else { continue }
            let resampleCompleted = trace.map { _ in PerformanceClock.now() }
            applySystemMaster(
                to: &adjustedFrame.interleaved,
                channelCount: adjustedFrame.channelCount,
                sampleRate: adjustedFrame.sampleRate
            )
            let masterCompleted = trace.map { _ in PerformanceClock.now() }
            do {
                let payload = adjustedFrame.interleaved.withUnsafeBytes { Data($0) }
                let pipeWriteStarted = trace.map { _ in PerformanceClock.now() }
                try handle.write(contentsOf: payload)
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
                        blockFrames: adjustedFrame.frameCount, contributorCount: interval?.contributingPackets ?? 0)))
                }
                calibrationCompletion?()
            } catch {
                condition.lock()
                stopping = true
                queue.clear()
                workerFinished = true
                condition.broadcast()
                condition.unlock()
                failureHandler()
                return
            }
        }
    }

    private func applySystemMaster(
        to samples: inout [Float],
        channelCount: Int,
        sampleRate: Double
    ) {
        guard channelCount > 0, sampleRate > 0, !samples.isEmpty else { return }
        let snapshot = systemMaster.snapshot()
        if snapshot.revision != masterRevision {
            masterRevision = snapshot.revision
            targetMasterGain = snapshot.effectiveGain
            // 8 ms is fast enough for a single keyboard tap to feel immediate,
            // but still prevents a discontinuity at a PCM block boundary.
            masterRampFramesRemaining = max(1, Int(sampleRate * 0.008))
            masterRampStep = (targetMasterGain - currentMasterGain)
                / Float(masterRampFramesRemaining)
        }

        let frameCount = samples.count / channelCount
        guard frameCount > 0 else { return }
        if masterRampFramesRemaining == 0 {
            currentMasterGain = targetMasterGain
            if currentMasterGain == 1 { return }
            for index in samples.indices { samples[index] *= currentMasterGain }
            return
        }

        for frame in 0..<frameCount {
            if masterRampFramesRemaining > 0 {
                currentMasterGain += masterRampStep
                masterRampFramesRemaining -= 1
                if masterRampFramesRemaining == 0 {
                    currentMasterGain = targetMasterGain
                }
            }
            let base = frame * channelCount
            for channel in 0..<channelCount {
                samples[base + channel] *= currentMasterGain
            }
        }
    }


}
