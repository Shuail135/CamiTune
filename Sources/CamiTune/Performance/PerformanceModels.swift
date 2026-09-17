import Foundation

struct AudioTraceIdentity: Sendable, Codable, Equatable {
    let captureID: UInt64
    let runtimeSessionID: UUID
    let transportGeneration: UInt64
    var streamEpoch: UInt64
    let deviceObjectID: UInt32
    var startSampleTime: Int64
    var frameCount: Int
    let sampleRate: Double
    let channelCount: Int
}

struct PacketPerformanceContext: Sendable {
    let capture: AudioLatencyCapture
    var identity: AudioTraceIdentity
    let received: PerformanceTick
    var policyTick: PerformanceTick? = nil
}

struct TraceContribution: Sendable {
    var startSampleTime: Int64
    let endSampleTime: Int64
    let received: PerformanceTick
    let processingCompleted: PerformanceTick
}

struct AudioIntervalTraceContext: Sendable {
    let capture: AudioLatencyCapture
    var identity: AudioTraceIdentity
    let firstPacketReceived: PerformanceTick
    let lastPacketReceived: PerformanceTick
    let firstPacketProcessed: PerformanceTick
    let lastPacketProcessed: PerformanceTick
    let becameEligible: PerformanceTick
    var emitted: PerformanceTick
    let contributingPackets: Int
    let idleDeadline: PerformanceTick?
    let idleFlushStarted: PerformanceTick?
}

struct PCMWriterTraceContext: Sendable {
    let capture: AudioLatencyCapture
    let identity: AudioTraceIdentity
    let interval: AudioIntervalTraceContext?
    let entered: PerformanceTick
    let queueBefore: Int
    let queueAfter: Int
    let capacity: Int
}

struct PacketLatencySample: Sendable, Codable {
    let identity: AudioTraceIdentity
    let received: PerformanceTick
    let processed: PerformanceTick
}

struct AudioLatencySample: Sendable, Codable {
    let identity: AudioTraceIdentity
    let packetReceived: PerformanceTick?
    let lastPacketReceived: PerformanceTick?
    let firstPacketProcessed: PerformanceTick?
    let packetProcessed: PerformanceTick?
    let mixEligible: PerformanceTick?
    let mixEmitted: PerformanceTick?
    let idleDeadline: PerformanceTick?
    let idleFlushStarted: PerformanceTick?
    let queueEntered: PerformanceTick
    let queueLeft: PerformanceTick
    let renderCompleted: PerformanceTick
    let resampleCompleted: PerformanceTick
    let masterCompleted: PerformanceTick
    let pipeWriteStarted: PerformanceTick
    let pipeWriteCompleted: PerformanceTick
    let queueFramesBeforeEntry: Int
    let queueFramesAtEntry: Int
    let queueFramesAfterDequeue: Int
    let queueCapacityFrames: Int
    let blockFrames: Int
    let contributorCount: Int
}

struct QueueTimingSample: Sendable, Codable {
    let identity: AudioTraceIdentity
    let timestamp: PerformanceTick
    let isEntry: Bool
    let queuedFrames: Int
    let capacityFrames: Int
}

struct FrameSizeDistribution: Sendable, Codable {
    let sampleCount: Int
    let minimumFrames: Int
    let medianFrames: Int
    let maximumFrames: Int
    init(_ sizes: [Int]) {
        let sorted = sizes.sorted()
        sampleCount = sorted.count
        minimumFrames = sorted.first ?? 0
        medianFrames = sorted.isEmpty ? 0 : sorted[(sorted.count - 1) / 2]
        maximumFrames = sorted.last ?? 0
    }
}

struct PCMQueueRecoverySample: Sendable, Codable {
    let captureID: UInt64
    let runtimeSessionID: UUID
    let timestamp: PerformanceTick
    let queuedFramesBeforeRecovery: Int
    let incomingFrames: Int
    let droppedFrames: Int
    let sampleRate: Double
    let writerBlockInProgressFrames: Int
}

struct PCMQueueSnapshot: Sendable, Codable, Equatable {
    var queuedFrames = 0
    var peakQueuedFrames = 0
    var capacityFrames = 0
    var sampleRate = 0.0
    var peakDurationMilliseconds = 0.0
    var latestBlockFrames = 0
    var lastRecoveryUptime: UInt64?
    var lastRecoveryDroppedFrames = 0
    var lastRecoveryQueuedFrames = 0
    var lastRecoveryIncomingFrames = 0
    var lastRecoverySampleRate = 0.0
    var durationMilliseconds: Double { sampleRate > 0 ? Double(queuedFrames) * 1000 / sampleRate : 0 }
    var capacityMilliseconds: Double { sampleRate > 0 ? Double(capacityFrames) * 1000 / sampleRate : 0 }
}

enum PerformanceEvent: Sendable {
    case packet(PacketLatencySample)
    case audio(AudioLatencySample)
    case recovery(PCMQueueRecoverySample)
    case queue(QueueTimingSample)
    case presentation(PresentationPerformanceSample)
    var timestamp: PerformanceTick {
        switch self {
        case .packet(let sample): return sample.received
        case .audio(let sample): return sample.packetReceived ?? sample.queueEntered
        case .recovery(let sample): return sample.timestamp
        case .queue(let sample): return sample.timestamp
        case .presentation(let sample): return sample.started
        }
    }
}

struct PerformanceOperationID: Sendable, Codable, Equatable { let rawValue: UInt64 }
struct PerformancePhase: Sendable, Codable { let name: String; let timestamp: PerformanceTick }
struct PerformanceOperationMeasurement: Sendable, Codable {
    let id: PerformanceOperationID
    let parentID: PerformanceOperationID?
    let kind: String
    let reason: String
    let revision: UInt64?
    let started: PerformanceTick
    var phases: [PerformancePhase] = []
    var result = "incomplete"
    var ended: PerformanceTick?
}

struct PerformanceEnvironment: Sendable, Codable {
    var version: String
    var build: String
    var configuration: String
    var gitCommit: String?
    var macOS: String
    var architecture: String
    var outputName: String?
    var outputUID: String?
    var sessionID: UUID?
    var sampleRate: Int?
    var channelCount: Int?
    var playbackMode: String?
    var spatialMode: String?
    var processingStages: Int?
    var chunkSize: Int?
    var activeApplications: Int
    var windowVisible: Bool
    var profileVisible: Bool
    var telemetryHealth: String
    var dspLoad: Double?
    var dspBufferFrames: UInt64?
    var dspResamplerLoad: Double?
    var queue: PCMQueueSnapshot
    var recoveries: UInt64
    var droppedFrames: UInt64
    var transportDroppedFrames: UInt64
    var processCPUSeconds: Double
    var presentationStatistics: PresentationPublicationStatistics? = nil
}

struct PerformanceScenario: Sendable, Codable {
    var label = ""
    var expectedApplications: Int? = nil
    var expectedSampleRate: Int? = nil
    var expectedPlaybackMode: String? = nil
    var expectedProfileVisible: Bool? = nil
    var expectedWindowVisible: Bool? = nil
    var minimumApplications: Int? = nil
    var requiresMixedPacketSizes = false
    var requiresNonDirectMode = false
    var requiresOtherSampleRate = false
}

struct PerformanceCaptureOptions: Sendable, Codable {
    var duration: Double = 30
    var warmUp: Double = 5
    var scenario = PerformanceScenario()
    var redactNames = true
    var detailedAudioTracing = true
}

struct PerformanceEnvironmentObservation: Sendable, Codable {
    let timestamp: PerformanceTick
    let environment: PerformanceEnvironment
}

struct LatencyDistribution: Sendable, Codable {
    let sampleCount: Int
    let minimumMilliseconds: Double
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let p99Milliseconds: Double
    let maximumMilliseconds: Double
    let meanMilliseconds: Double

    init(_ values: [Double]) {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        sampleCount = sorted.count
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
        }
        minimumMilliseconds = sorted.first ?? 0
        medianMilliseconds = percentile(0.5); p95Milliseconds = percentile(0.95); p99Milliseconds = percentile(0.99)
        maximumMilliseconds = sorted.last ?? 0
        meanMilliseconds = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
    }
}

struct PerformanceOverheadComparison: Sendable, Codable {
    let workload: String
    let identicalPCM: Bool
    let offRecoveries: UInt64
    let onRecoveries: UInt64
    let offQueuePeakFrames: Int
    let onQueuePeakFrames: Int
    let offDroppedFrames: UInt64
    let onDroppedFrames: UInt64
    let offCPUSeconds: Double
    let onCPUSeconds: Double
    let offDurationSeconds: Double
    let onDurationSeconds: Double
    let onWriterP99Milliseconds: Double
}

struct PerformanceBaseline: Sendable, Codable {
    var schemaVersion = 1
    let captureID: UInt64
    let startedAt: Date
    let measurementStart: PerformanceTick
    let ended: PerformanceTick
    let options: PerformanceCaptureOptions
    var environment: PerformanceEnvironment
    var observations: [PerformanceEnvironmentObservation]
    let audio: [String: LatencyDistribution]
    let interactions: [String: LatencyDistribution]
    let transitions: [String: LatencyDistribution]
    let packetSizes: [Int: Int]
    let emittedSizes: [Int: Int]
    let packetFrameDistribution: FrameSizeDistribution
    let emittedFrameDistribution: FrameSizeDistribution
    let queueOccupancy: LatencyDistribution
    let samples: [AudioLatencySample]
    let packets: [PacketLatencySample]
    let queueEvents: [QueueTimingSample]
    let recoveries: [PCMQueueRecoverySample]
    let operations: [PerformanceOperationMeasurement]
    let telemetryDrops: UInt64
    let scenarioMismatches: [String]
    let recoveriesDuringCapture: UInt64
    let droppedFramesDuringCapture: UInt64
    let transportDroppedFramesDuringCapture: UInt64
    let processCPUPercent: Double?
    let stopReason: String
    var overheadComparison: PerformanceOverheadComparison? = nil
    var presentation: PresentationPerformanceSummary? = nil
}

struct PresentationPublicationStatistics: Sendable, Codable, Equatable {
    var requests: UInt64 = 0
    var meterRequests: UInt64 = 0
    var immediateRequests: UInt64 = 0
    var coalescedRequests: UInt64 = 0
    var workerDrains: UInt64 = 0
    var snapshotsBuilt: UInt64 = 0
    var trailingBuilds: UInt64 = 0
    var mainDeliveries: UInt64 = 0
    var maximumPendingDrains: UInt64 = 0

    func delta(since old: Self) -> Self {
        func difference(_ a: UInt64, _ b: UInt64) -> UInt64 { a >= b ? a - b : a }
        return .init(requests: difference(requests, old.requests), meterRequests: difference(meterRequests, old.meterRequests),
            immediateRequests: difference(immediateRequests, old.immediateRequests), coalescedRequests: difference(coalescedRequests, old.coalescedRequests),
            workerDrains: difference(workerDrains, old.workerDrains), snapshotsBuilt: difference(snapshotsBuilt, old.snapshotsBuilt),
            trailingBuilds: difference(trailingBuilds, old.trailingBuilds), mainDeliveries: difference(mainDeliveries, old.mainDeliveries),
            maximumPendingDrains: maximumPendingDrains)
    }
}

struct PresentationPerformanceSample: Sendable, Codable {
    let phase: String
    let started: PerformanceTick
    let ended: PerformanceTick
    let revision: UInt64
    var builtOnPublicationWorker: Bool? = nil
}

struct PresentationPerformanceSummary: Sendable, Codable {
    let statistics: PresentationPublicationStatistics?
    let durations: [String: LatencyDistribution]
    let samples: [PresentationPerformanceSample]
}

extension AudioLatencyCapture {
    func recordPresentation(_ phase: String, from start: PerformanceTick?, revision: UInt64 = 0, onWorker: Bool? = nil) {
        guard let start else { return }
        append(.presentation(.init(phase: phase, started: start, ended: PerformanceClock.now(), revision: revision, builtOnPublicationWorker: onWorker)))
    }
}
