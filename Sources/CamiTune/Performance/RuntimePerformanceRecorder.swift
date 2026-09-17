import Foundation
import Darwin

@MainActor
final class PerformanceOperation {
    private weak var recorder: RuntimePerformanceRecorder?
    fileprivate let captureID: UInt64
    fileprivate var value: PerformanceOperationMeasurement
    init(recorder: RuntimePerformanceRecorder, captureID: UInt64, value: PerformanceOperationMeasurement) {
        self.recorder = recorder; self.captureID = captureID; self.value = value
    }
    var id: PerformanceOperationID { value.id }
    func mark(_ phase: String) {
        guard value.ended == nil, value.phases.count < 64 else { return }
        value.phases.append(.init(name: phase, timestamp: PerformanceClock.now()))
    }
    func finish(_ result: String) {
        guard value.ended == nil else { return }
        value.result = result; value.ended = PerformanceClock.now()
        recorder?.finish(self)
    }
}

@MainActor
final class RuntimePerformanceRecorder: ObservableObject {
    let source: PerformanceTraceSource
    private let presentationSource: PerformanceTraceSource?
    private var sourceDrops: UInt64 { source.contentionDrops + (presentationSource?.contentionDrops ?? 0) }
    @Published private(set) var isCapturing = false
    @Published private(set) var isAggregating = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var packetCount = 0
    @Published private(set) var audioCount = 0
    @Published private(set) var telemetryDrops: UInt64 = 0
    @Published private(set) var currentEnvironment: PerformanceEnvironment?
    @Published private(set) var baseline: PerformanceBaseline?
    @Published private(set) var options = PerformanceCaptureOptions()
    private var capture: AudioLatencyCapture?
    private var timer: Task<Void, Never>?
    private var startedAt = Date()
    private var sourceDropsAtStart: UInt64 = 0
    private var observations: [PerformanceEnvironmentObservation] = []
    private var operations: [PerformanceOperationMeasurement] = []
    private var activeOperations: [UInt64: PerformanceOperation] = [:]
    private var nextOperation: UInt64 = 0
    private var environmentProvider: (() -> PerformanceEnvironment)?
    private var initialEnvironment: PerformanceEnvironment?
    private var extraDrops: UInt64 = 0

    init(source: PerformanceTraceSource, presentationSource: PerformanceTraceSource? = nil) {
        self.source = source; self.presentationSource = presentationSource
    }

    func start(options requested: PerformanceCaptureOptions, environment: @escaping () -> PerformanceEnvironment) {
        guard !isCapturing, !isAggregating else { return }
        options = requested
        options.duration = min(300, max(1, requested.duration))
        options.warmUp = min(30, max(0, requested.warmUp))
        let now = PerformanceClock.now()
        let measurementStart = now.advanced(seconds: options.warmUp)
        capture = AudioLatencyCapture(id: now.rawValue, start: measurementStart, deadline: measurementStart.advanced(seconds: options.duration))
        startedAt = Date(); environmentProvider = environment
        initialEnvironment = environment(); currentEnvironment = initialEnvironment
        observations = []; operations = []; activeOperations = [:]; extraDrops = 0
        sourceDropsAtStart = sourceDrops
        packetCount = 0; audioCount = 0; telemetryDrops = 0; elapsed = -options.warmUp
        isCapturing = true; source.setCapture(options.detailedAudioTracing ? capture : nil)
        presentationSource?.setCapture(options.detailedAudioTracing ? capture : nil)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let capture, isCapturing else { return }
                let now = PerformanceClock.now()
                elapsed = now < capture.start ? -Double(capture.start.rawValue - now.rawValue) / 1e9 : Double(now.rawValue - capture.start.rawValue) / 1e9
                if let environment = environmentProvider?() {
                    currentEnvironment = environment
                    if now >= capture.start {
                        if observations.count < 1_024 { observations.append(.init(timestamp: now, environment: environment)) }
                        else { extraDrops &+= 1 }
                    } else { initialEnvironment = environment }
                }
                let counts = capture.counts(); packetCount = counts.packets; audioCount = counts.audio
                telemetryDrops = capture.telemetryDrops + sourceDrops - sourceDropsAtStart + extraDrops
                if now >= capture.deadline { await stop(reason: "Duration complete"); return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func begin(_ kind: String, reason: String = "user", revision: UInt64? = nil,
               parent: PerformanceOperationID? = nil, started: PerformanceTick? = nil) -> PerformanceOperation? {
        guard let capture, isCapturing, capture.accepts(PerformanceClock.now()) else { return nil }
        guard operations.count + activeOperations.count < 2_048 else { extraDrops &+= 1; return nil }
        nextOperation &+= 1
        let operation = PerformanceOperation(recorder: self, captureID: capture.id,
            value: .init(id: .init(rawValue: nextOperation), parentID: parent, kind: kind, reason: reason,
                         revision: revision, started: max(started ?? PerformanceClock.now(), capture.start)))
        activeOperations[nextOperation] = operation
        return operation
    }
    fileprivate func finish(_ operation: PerformanceOperation) {
        guard operation.captureID == capture?.id, activeOperations.removeValue(forKey: operation.id.rawValue) != nil else { return }
        var value = operation.value
        if let deadline = capture?.deadline, let ended = value.ended, ended > deadline {
            value.ended = deadline; value.result = "incomplete at capture end"
            value.phases.removeAll { $0.timestamp > deadline }
        }
        operations.append(value)
    }

    func stop(reason: String = "Stopped by user") async {
        guard let capture, let initialEnvironment, isCapturing else { return }
        timer?.cancel(); timer = nil
        source.setCapture(nil); presentationSource?.setCapture(nil); capture.stop()
        let end = min(PerformanceClock.now(), capture.deadline)
        if let final = environmentProvider?() { observations.append(.init(timestamp: end, environment: final)); currentEnvironment = final }
        for operation in Array(activeOperations.values) { operation.finish("incomplete at capture end") }
        isCapturing = false; isAggregating = true
        let observationValues = observations; let operationValues = operations
        let options = options; let startedAt = startedAt
        let drops = capture.telemetryDrops + sourceDrops - sourceDropsAtStart + extraDrops
        baseline = await Task.detached(priority: .utility) {
            PerformanceAggregator.build(capture: capture, startedAt: startedAt, end: end, options: options,
                environment: initialEnvironment, observations: observationValues, operations: operationValues,
                drops: drops, stopReason: reason)
        }.value
        self.capture = nil; environmentProvider = nil; isAggregating = false
        telemetryDrops = drops
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}
