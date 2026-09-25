import CamiTuneAudio
import CamiTuneDomain
import Foundation





















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
    var timelineMixerStatistics: PerAppTimelineMixerStatistics? = nil
    var writerRateAdjustmentPPM: Double? = nil
    var writerRateBufferedFrames: UInt64? = nil
    var deliveryConfiguration: PCMDeliveryConfiguration? = nil
    var producerCompletion: ProducerCompletionStatistics? = nil
    var playbackClock: CamillaPlaybackClock? = nil
    var deliveryError: String? = nil
    var producerDrains: PCMProducerDrainStatistics? = nil
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
    // Keep long coarse soaks below the existing 1,024-observation bound.
    // Short captures retain their original half-second sampling cadence.
    var observationInterval: Double { max(0.5, duration / 900) }
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
