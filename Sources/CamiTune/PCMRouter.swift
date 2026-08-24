import Foundation
import Darwin

struct PCMFrame: Sendable {
    let interleaved: [Float]
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
        meterConsumer: MeterConsumer? = nil,
        analyzerConsumer: AnalyzerConsumer? = nil
    ) async {
        await Task.detached(priority: .userInitiated) { [self] in
            startSynchronously(
                camillaSink: camillaSink,
                spatialRenderingMode: spatialRenderingMode,
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
        meterConsumer: MeterConsumer?,
        analyzerConsumer: AnalyzerConsumer?
    ) {
        stop()
        let camillaBranch = CamillaPCMBranch(
            handle: camillaSink,
            spatialRenderingMode: spatialRenderingMode,
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

    func setSpatialRenderingMode(_ mode: SpatialRenderingMode) {
        state.lock()
        spatialRenderingMode = mode
        let camillaBranch = self.camillaBranch
        state.unlock()
        camillaBranch?.setSpatialRenderingMode(mode)
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
    private enum SpatialPath: Equatable {
        case standard
        case stereo
        case multichannelMovie
    }

    // Own a duplicate of CamillaDSP stdin instead of retaining the manager's
    // FileHandle object. Foundation FileHandle raises NSException (not a Swift
    // Error) if write(contentsOf:) races with close() on that same object.
    // Keeping a separate descriptor gives the writer independent lifetime.
    private let handle: FileHandle?
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
    private let spatialPolicy = SpatialPolicy()
    private let frontStageRenderer = FrontStageRenderer()
    private let multichannelMovieRenderer = MultichannelMovieRenderer()
    private var lastSourceFormat: SpatialSourceFormat?
    private var lastSpatialPath: SpatialPath?
    private var spatialRenderingMode: SpatialRenderingMode
    private var needsSpatialReset = false

    init(
        handle: FileHandle,
        spatialRenderingMode: SpatialRenderingMode,
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
        self.spatialRenderingMode = spatialRenderingMode
        self.recoveryHandler = recoveryHandler
        self.failureHandler = failureHandler
        self.adjustmentHandler = adjustmentHandler
    }

    func setSpatialRenderingMode(_ mode: SpatialRenderingMode) {
        condition.lock()
        if spatialRenderingMode != mode {
            spatialRenderingMode = mode
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

    func enqueue(_ frame: PCMFrame) {
        condition.lock()
        guard !stopping else {
            condition.unlock()
            return
        }
        let droppedFrames = queue.append(frame)
        if droppedFrames > 0 { needsRateMatcherReset = true }
        condition.signal()
        condition.unlock()
        if droppedFrames > 0 { recoveryHandler(droppedFrames) }
    }

    func stop() {
        condition.lock()
        stopping = true
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
            while queue.isEmpty && !stopping { condition.wait() }
            if stopping {
                workerFinished = true
                condition.broadcast()
                condition.unlock()
                return
            }
            guard let frame = queue.removeFirst() else {
                condition.unlock()
                continue
            }
            let queuedFrames = queue.queuedFrames
            let shouldResetRateMatcher = needsRateMatcherReset
            let shouldResetSpatialRenderer = needsSpatialReset
            let spatialRenderingMode = self.spatialRenderingMode
            needsRateMatcherReset = false
            needsSpatialReset = false
            condition.unlock()
            if shouldResetRateMatcher {
                rateController.reset()
                resampler.reset()
                frontStageRenderer.reset()
                multichannelMovieRenderer.reset()
            }
            if shouldResetSpatialRenderer {
                frontStageRenderer.reset()
                multichannelMovieRenderer.reset()
                lastSpatialPath = nil
            }
            let sourceFormat = frame.sourceFormat
            if lastSourceFormat != sourceFormat {
                lastSourceFormat = sourceFormat
                frontStageRenderer.reset()
                multichannelMovieRenderer.reset()
                lastSpatialPath = nil
            }
            let decision = spatialPolicy.decision(
                for: frame,
                mode: spatialRenderingMode
            )
            let spatialPath: SpatialPath
            switch decision {
            case .standard: spatialPath = .standard
            case .stereo: spatialPath = .stereo
            case .multichannelMovie: spatialPath = .multichannelMovie
            }
            if lastSpatialPath != spatialPath {
                // A fixed 7.1 endpoint can alternate between stereo-only and
                // discrete payloads. Clear delayed surround/reflection state
                // so no samples from the previous semantic path reappear.
                frontStageRenderer.reset()
                multichannelMovieRenderer.reset()
                lastSpatialPath = spatialPath
            }
            let renderedFrame: PCMFrame?
            switch decision {
            case .standard:
                renderedFrame = sourceRouter.stereoFallback(for: frame)
            case .stereo(let intent):
                renderedFrame = sourceRouter.stereoFallback(for: frame).flatMap {
                    frontStageRenderer.render(frame: $0, intent: intent)
                }
            case .multichannelMovie(let intent):
                renderedFrame = multichannelMovieRenderer.render(
                    frame: frame,
                    intent: intent
                ).flatMap {
                    frontStageRenderer.render(frame: $0, intent: intent)
                } ?? sourceRouter.stereoFallback(for: frame)
            }
            guard let renderedFrame else {
                recoveryHandler(frame.frameCount)
                continue
            }
            let bufferedFrames = frame.sourceBufferedFrames + queuedFrames
            let adjustmentPPM = rateController.update(
                bufferedFrames: bufferedFrames,
                sourceCapacityFrames: frame.sourceCapacityFrames,
                sampleRate: frame.sampleRate,
                elapsedFrames: frame.frameCount
            )
            adjustmentHandler(adjustmentPPM, bufferedFrames)
            let adjustedFrame = resampler.process(renderedFrame, adjustmentPPM: adjustmentPPM)
            guard !adjustedFrame.interleaved.isEmpty else { continue }
            do {
                try adjustedFrame.interleaved.withUnsafeBytes { bytes in
                    try handle.write(contentsOf: Data(bytes))
                }
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
}
