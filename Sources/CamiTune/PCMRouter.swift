import Foundation
import Darwin

struct PCMFrame: Sendable {
    var interleaved: [Float]
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
    }

    private let state = NSLock()
    private let systemMaster = SystemMasterGainControl()
    private var camillaBranch: CamillaPCMBranch?
    private var analyzerBranch: AnalyzerPCMBranch?
    private var meterBranch: MeterPCMBranch?
    private var statisticsValue = Statistics()
    private var spatialRenderingMode: SpatialRenderingMode = .standard

    var statistics: Statistics {
        state.lock()
        defer { state.unlock() }
        return statisticsValue
    }

    /// Serializes router replacement without making the caller's executor wait
    /// on worker joins. In particular, AppState can await this from MainActor
    /// without freezing SwiftUI for the branch shutdown timeouts below.
    func start(
        camillaSink: FileHandle,
        spatialRenderingMode: SpatialRenderingMode = .standard,
        spatialListenerTuning: SpatialListenerTuning = .neutral,
        spatialContentMode: SpatialContentMode = .automatic,
        spatialSettings: SpatialRenderSettings = SpatialRenderSettings(),
        spatialOutput: SpatialOutputKind = .speakers,
        meterConsumer: MeterConsumer? = nil,
        analyzerConsumer: AnalyzerConsumer? = nil
    ) async {
        await Task.detached(priority: .userInitiated) { [self] in
            startSynchronously(
                camillaSink: camillaSink,
                spatialRenderingMode: spatialRenderingMode,
                spatialListenerTuning: spatialListenerTuning,
                spatialContentMode: spatialContentMode,
                spatialSettings: spatialSettings,
                spatialOutput: spatialOutput,
                meterConsumer: meterConsumer,
                analyzerConsumer: analyzerConsumer
            )
        }.value
    }

    /// Blocking lifecycle primitive. Keep it private so normal runtime code
    /// cannot accidentally join PCM workers on MainActor.
    private func startSynchronously(
        camillaSink: FileHandle,
        spatialRenderingMode: SpatialRenderingMode,
        spatialListenerTuning: SpatialListenerTuning,
        spatialContentMode: SpatialContentMode,
        spatialSettings: SpatialRenderSettings,
        spatialOutput: SpatialOutputKind,
        meterConsumer: MeterConsumer?,
        analyzerConsumer: AnalyzerConsumer?
    ) {
        stop()
        let camillaBranch = CamillaPCMBranch(
            handle: camillaSink,
            systemMaster: systemMaster,
            spatialRenderingMode: spatialRenderingMode,
            spatialListenerTuning: spatialListenerTuning,
            spatialContentMode: spatialContentMode,
            spatialSettings: spatialSettings,
            spatialOutput: spatialOutput,
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
        self.spatialRenderingMode = spatialRenderingMode
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

    var spatialRenderDiagnostics: SpatialRenderDiagnostics? {
        state.lock()
        let branch = camillaBranch
        state.unlock()
        return branch?.renderDiagnostics
    }

    func route(_ frame: PCMFrame) {
        state.lock()
        let camillaBranch = self.camillaBranch
        let meterBranch = self.meterBranch
        let analyzerBranch = self.analyzerBranch
        state.unlock()

        // These are deliberately independent bounded queues. Analyzer or meter
        // stalls can drop observation frames, but never execute on or hold up
        // the CamillaDSP delivery branch.
        camillaBranch?.enqueue(frame)
        meterBranch?.enqueue(frame)
        analyzerBranch?.enqueue(frame)
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
        state.unlock()

        camillaBranch?.stop()
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
        let frame: PCMFrame
    }

    private var buffers: [Buffer] = []
    private(set) var queuedFrames = 0
    private var sampleRate = 0.0
    let maximumDuration: TimeInterval

    init(maximumDuration: TimeInterval = 0.1) {
        self.maximumDuration = maximumDuration
    }

    var isEmpty: Bool { buffers.isEmpty }
    var bufferCount: Int { buffers.count }

    mutating func append(_ frame: PCMFrame) -> Int {
        let frameCount = frame.frameCount
        let sampleRate = frame.sampleRate
        guard frameCount > 0, sampleRate > 0 else { return 0 }
        var droppedFrames = 0
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
        return droppedFrames
    }

    mutating func removeFirst() -> PCMFrame? {
        guard !buffers.isEmpty else { return nil }
        let buffer = buffers.removeFirst()
        queuedFrames -= buffer.frame.frameCount
        return buffer.frame
    }

    @discardableResult
    mutating func clear() -> Int {
        let droppedFrames = queuedFrames
        buffers.removeAll(keepingCapacity: true)
        queuedFrames = 0
        return droppedFrames
    }
}

private final class CamillaPCMBranch: @unchecked Sendable {
    // Own a duplicate of CamillaDSP stdin instead of retaining the manager's
    // FileHandle object. Foundation FileHandle raises NSException (not a Swift
    // Error) if write(contentsOf:) races with close() on that same object.
    // Keeping a separate descriptor gives the writer independent lifetime.
    private let handle: FileHandle?
    private let systemMaster: SystemMasterGainControl
    private let recoveryHandler: (Int) -> Void
    private let failureHandler: () -> Void
    private let adjustmentHandler: (Double, Int) -> Void
    private let condition = NSCondition()
    private var queue = LowLatencyPCMQueue()
    private var stopping = false
    private var workerFinished = true
    private var worker: Thread?
    private var needsRateMatcherReset = false
    private var rateController = AdaptiveRateController()
    private var resampler = AdaptivePCMResampler()
    private let sourceRouter = SpatialSourceRouter()
    private var contentAnalyzer = SpatialContentAnalyzer()
    private var spatialContentMode: SpatialContentMode
    private var publishedContentEstimate = SpatialContentEstimate.unknown
    private var contentEstimateDate = Date.distantPast
    private var needsContentReset = false
    private let spatialEngine = SpatialAudioEngine()
    private var publishedRenderDiagnostics: SpatialRenderDiagnostics?
    private var renderSettings: SpatialRenderSettings
    private var renderOutput: SpatialOutputKind
    private var virtualSurroundLayout = VirtualSurroundLayout.standard
    private var lastSourceFormat: SpatialSourceFormat?
    private var spatialRenderingMode: SpatialRenderingMode
    private var spatialListenerTuning: SpatialListenerTuning
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
        systemMaster: SystemMasterGainControl,
        spatialRenderingMode: SpatialRenderingMode,
        spatialListenerTuning: SpatialListenerTuning,
        spatialContentMode: SpatialContentMode,
        spatialSettings: SpatialRenderSettings,
        spatialOutput: SpatialOutputKind,
        recoveryHandler: @escaping (Int) -> Void,
        failureHandler: @escaping () -> Void,
        adjustmentHandler: @escaping (Double, Int) -> Void
    ) {
        let duplicatedDescriptor = Darwin.dup(handle.fileDescriptor)
        if duplicatedDescriptor >= 0 {
            self.handle = FileHandle(
                fileDescriptor: duplicatedDescriptor,
                closeOnDealloc: true
            )
        } else {
            self.handle = nil
        }
        self.spatialRenderingMode = spatialRenderingMode == .standard ? .standard : .spatialAudio
        self.spatialListenerTuning = spatialListenerTuning.validated
        self.spatialContentMode = spatialContentMode
        self.renderSettings = spatialSettings
        if spatialRenderingMode == .frontStage || spatialRenderingMode == .virtualSurround { self.renderSettings.enabled = true }
        self.renderOutput = spatialOutput
        self.systemMaster = systemMaster
        let initialMaster = systemMaster.snapshot()
        masterRevision = initialMaster.revision
        currentMasterGain = initialMaster.effectiveGain
        targetMasterGain = initialMaster.effectiveGain
        self.recoveryHandler = recoveryHandler
        self.failureHandler = failureHandler
        self.adjustmentHandler = adjustmentHandler
    }

    var renderDiagnostics: SpatialRenderDiagnostics? {
        condition.lock()
        defer { condition.unlock() }
        return publishedRenderDiagnostics
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
        condition.lock()
        guard !stopping, calibrationPlayback == nil, !measurementHold else {
            condition.unlock()
            return
        }
        let droppedFrames = queue.append(frame)
        if droppedFrames > 0 { needsRateMatcherReset = true }
        condition.signal()
        condition.unlock()
        if droppedFrames > 0 { recoveryHandler(droppedFrames) }
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
            let queuedFrames = queue.queuedFrames
            let shouldResetRateMatcher = needsRateMatcherReset
            let shouldResetSpatialRenderer = needsSpatialReset
            // Keep the two physical sweep channels independent. The existing
            // downstream output EQ and system master remain in the path.
            let spatialRenderingMode: SpatialRenderingMode = isAcousticMeasurement ? .standard : self.spatialRenderingMode
            var renderSettings = self.renderSettings
            if isChannelAudition {
                renderSettings.contentSelection = .cinema
                renderSettings.cinema.amount = 1
            }
            let renderOutput = self.renderOutput
            let shouldAnalyzeContent = spatialRenderingMode != .standard && renderSettings.enabled
                && calibrationID == nil && !isCalibrationSample
            let shouldResetContent = needsContentReset || Date().timeIntervalSince(contentEstimateDate) > 1
            needsContentReset = false
            needsRateMatcherReset = false
            needsSpatialReset = false
            condition.unlock()
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
                spatialEngine.reset(); rateController.reset(); resampler.reset()
            }
            if shouldResetSpatialRenderer { spatialEngine.reset() }
            lastSourceFormat = frame.sourceFormat
            // Old mode values remain decodable, but production audio now uses
            // only the two physical-output renderers. Acoustic sweeps bypass them.
            let renderedFrame = spatialRenderingMode == .standard
                ? sourceRouter.stereoFallback(for: frame)
                : spatialEngine.render(frame: frame, settings: renderSettings, detectedOutput: renderOutput)
            condition.lock()
            publishedRenderDiagnostics = spatialRenderingMode == .spatialAudio ? spatialEngine.diagnostics : nil
            condition.unlock()
            guard let renderedFrame else {
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
            applySystemMaster(
                to: &adjustedFrame.interleaved,
                channelCount: adjustedFrame.channelCount,
                sampleRate: adjustedFrame.sampleRate
            )
            do {
                try adjustedFrame.interleaved.withUnsafeBytes { bytes in
                    try handle.write(contentsOf: Data(bytes))
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
