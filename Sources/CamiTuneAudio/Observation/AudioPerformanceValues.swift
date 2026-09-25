import CamiTuneDomain
import Foundation

package struct AudioTraceIdentity: Sendable, Codable, Equatable {
    package init(captureID: UInt64, runtimeSessionID: UUID, transportGeneration: UInt64, streamEpoch: UInt64, deviceObjectID: UInt32, startSampleTime: Int64, frameCount: Int, sampleRate: Double, channelCount: Int) {
        self.captureID = captureID
        self.runtimeSessionID = runtimeSessionID
        self.transportGeneration = transportGeneration
        self.streamEpoch = streamEpoch
        self.deviceObjectID = deviceObjectID
        self.startSampleTime = startSampleTime
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    package let captureID: UInt64
    package let runtimeSessionID: UUID
    package let transportGeneration: UInt64
    package var streamEpoch: UInt64
    package let deviceObjectID: UInt32
    package var startSampleTime: Int64
    package var frameCount: Int
    package let sampleRate: Double
    package let channelCount: Int
}

package struct PacketPerformanceContext: Sendable {
    package init(capture: AudioLatencyCapture, identity: AudioTraceIdentity, received: PerformanceTick, policyTick: PerformanceTick? = nil) {
        self.capture = capture
        self.identity = identity
        self.received = received
        self.policyTick = policyTick
    }

    package let capture: AudioLatencyCapture
    package var identity: AudioTraceIdentity
    package let received: PerformanceTick
    package var policyTick: PerformanceTick? = nil
}

package struct TraceContribution: Sendable {
    package init(startSampleTime: Int64, endSampleTime: Int64, received: PerformanceTick, processingCompleted: PerformanceTick) {
        self.startSampleTime = startSampleTime
        self.endSampleTime = endSampleTime
        self.received = received
        self.processingCompleted = processingCompleted
    }

    package var startSampleTime: Int64
    package let endSampleTime: Int64
    package let received: PerformanceTick
    package let processingCompleted: PerformanceTick
}

package struct AudioIntervalTraceContext: Sendable {
    package init(capture: AudioLatencyCapture, identity: AudioTraceIdentity, firstPacketReceived: PerformanceTick, lastPacketReceived: PerformanceTick, firstPacketProcessed: PerformanceTick, lastPacketProcessed: PerformanceTick, becameEligible: PerformanceTick, emitted: PerformanceTick, contributingPackets: Int, idleDeadline: PerformanceTick? = nil, idleFlushStarted: PerformanceTick? = nil) {
        self.capture = capture
        self.identity = identity
        self.firstPacketReceived = firstPacketReceived
        self.lastPacketReceived = lastPacketReceived
        self.firstPacketProcessed = firstPacketProcessed
        self.lastPacketProcessed = lastPacketProcessed
        self.becameEligible = becameEligible
        self.emitted = emitted
        self.contributingPackets = contributingPackets
        self.idleDeadline = idleDeadline
        self.idleFlushStarted = idleFlushStarted
    }

    package let capture: AudioLatencyCapture
    package var identity: AudioTraceIdentity
    package let firstPacketReceived: PerformanceTick
    package let lastPacketReceived: PerformanceTick
    package let firstPacketProcessed: PerformanceTick
    package let lastPacketProcessed: PerformanceTick
    package let becameEligible: PerformanceTick
    package var emitted: PerformanceTick
    package let contributingPackets: Int
    package let idleDeadline: PerformanceTick?
    package let idleFlushStarted: PerformanceTick?
}

package struct PCMWriterTraceContext: Sendable {
    package init(capture: AudioLatencyCapture, identity: AudioTraceIdentity, interval: AudioIntervalTraceContext? = nil, entered: PerformanceTick, queueBefore: Int, queueAfter: Int, capacity: Int) {
        self.capture = capture
        self.identity = identity
        self.interval = interval
        self.entered = entered
        self.queueBefore = queueBefore
        self.queueAfter = queueAfter
        self.capacity = capacity
    }

    package let capture: AudioLatencyCapture
    package let identity: AudioTraceIdentity
    package let interval: AudioIntervalTraceContext?
    package let entered: PerformanceTick
    package let queueBefore: Int
    package let queueAfter: Int
    package let capacity: Int
}

package struct TimelineWorkSample: Sendable, Codable {
    package init(placementMilliseconds: Double, materializationMilliseconds: Double, growthMilliseconds: Double, insertedFrames: Int, emittedFrames: Int, prependedFrames: UInt64, pendingBefore: Int, pendingAfter: Int, capacityFrames: Int, wrappedRead: Bool, wrappedWrite: Bool, policyMilliseconds: Double? = nil) {
        self.placementMilliseconds = placementMilliseconds
        self.materializationMilliseconds = materializationMilliseconds
        self.growthMilliseconds = growthMilliseconds
        self.insertedFrames = insertedFrames
        self.emittedFrames = emittedFrames
        self.prependedFrames = prependedFrames
        self.pendingBefore = pendingBefore
        self.pendingAfter = pendingAfter
        self.capacityFrames = capacityFrames
        self.wrappedRead = wrappedRead
        self.wrappedWrite = wrappedWrite
        self.policyMilliseconds = policyMilliseconds
    }

    package let placementMilliseconds: Double
    package let materializationMilliseconds: Double
    package let growthMilliseconds: Double
    package let insertedFrames: Int
    package let emittedFrames: Int
    package let prependedFrames: UInt64
    package let pendingBefore: Int
    package let pendingAfter: Int
    package let capacityFrames: Int
    package let wrappedRead: Bool
    package let wrappedWrite: Bool
    package var policyMilliseconds: Double? = nil
}

package struct PacketLatencySample: Sendable, Codable {
    package init(identity: AudioTraceIdentity, received: PerformanceTick, processed: PerformanceTick, timeline: TimelineWorkSample? = nil, reorder: TimelineReorderEvidence? = nil) {
        self.identity = identity
        self.received = received
        self.processed = processed
        self.timeline = timeline
        self.reorder = reorder
    }

    package let identity: AudioTraceIdentity
    package let received: PerformanceTick
    package let processed: PerformanceTick
    package var timeline: TimelineWorkSample? = nil
    package var reorder: TimelineReorderEvidence? = nil
}

package struct AudioLatencySample: Sendable, Codable {
    package init(identity: AudioTraceIdentity, packetReceived: PerformanceTick? = nil, lastPacketReceived: PerformanceTick? = nil, firstPacketProcessed: PerformanceTick? = nil, packetProcessed: PerformanceTick? = nil, mixEligible: PerformanceTick? = nil, mixEmitted: PerformanceTick? = nil, idleDeadline: PerformanceTick? = nil, idleFlushStarted: PerformanceTick? = nil, queueEntered: PerformanceTick, queueLeft: PerformanceTick, renderCompleted: PerformanceTick, resampleCompleted: PerformanceTick, masterCompleted: PerformanceTick, pipeWriteStarted: PerformanceTick, pipeWriteCompleted: PerformanceTick, queueFramesBeforeEntry: Int, queueFramesAtEntry: Int, queueFramesAfterDequeue: Int, queueCapacityFrames: Int, blockFrames: Int, contributorCount: Int, rateMatch: RateMatchMeasurement? = nil) {
        self.identity = identity
        self.packetReceived = packetReceived
        self.lastPacketReceived = lastPacketReceived
        self.firstPacketProcessed = firstPacketProcessed
        self.packetProcessed = packetProcessed
        self.mixEligible = mixEligible
        self.mixEmitted = mixEmitted
        self.idleDeadline = idleDeadline
        self.idleFlushStarted = idleFlushStarted
        self.queueEntered = queueEntered
        self.queueLeft = queueLeft
        self.renderCompleted = renderCompleted
        self.resampleCompleted = resampleCompleted
        self.masterCompleted = masterCompleted
        self.pipeWriteStarted = pipeWriteStarted
        self.pipeWriteCompleted = pipeWriteCompleted
        self.queueFramesBeforeEntry = queueFramesBeforeEntry
        self.queueFramesAtEntry = queueFramesAtEntry
        self.queueFramesAfterDequeue = queueFramesAfterDequeue
        self.queueCapacityFrames = queueCapacityFrames
        self.blockFrames = blockFrames
        self.contributorCount = contributorCount
        self.rateMatch = rateMatch
    }

    package let identity: AudioTraceIdentity
    package let packetReceived: PerformanceTick?
    package let lastPacketReceived: PerformanceTick?
    package let firstPacketProcessed: PerformanceTick?
    package let packetProcessed: PerformanceTick?
    package let mixEligible: PerformanceTick?
    package let mixEmitted: PerformanceTick?
    package let idleDeadline: PerformanceTick?
    package let idleFlushStarted: PerformanceTick?
    package let queueEntered: PerformanceTick
    package let queueLeft: PerformanceTick
    package let renderCompleted: PerformanceTick
    package let resampleCompleted: PerformanceTick
    package let masterCompleted: PerformanceTick
    package let pipeWriteStarted: PerformanceTick
    package let pipeWriteCompleted: PerformanceTick
    package let queueFramesBeforeEntry: Int
    package let queueFramesAtEntry: Int
    package let queueFramesAfterDequeue: Int
    package let queueCapacityFrames: Int
    package let blockFrames: Int
    package let contributorCount: Int
    package var rateMatch: RateMatchMeasurement? = nil
}

package struct RateMatchMeasurement: Sendable, Codable, Equatable {
    package init(bufferedFrames: Int, targetFrames: Double, filteredBufferedFrames: Double, normalizedError: Double, adjustmentPPM: Double, elapsedFrames: Int, sampleRate: Double, targetSource: String, controlState: String? = nil) {
        self.bufferedFrames = bufferedFrames
        self.targetFrames = targetFrames
        self.filteredBufferedFrames = filteredBufferedFrames
        self.normalizedError = normalizedError
        self.adjustmentPPM = adjustmentPPM
        self.elapsedFrames = elapsedFrames
        self.sampleRate = sampleRate
        self.targetSource = targetSource
        self.controlState = controlState
    }

    package let bufferedFrames: Int
    package let targetFrames: Double
    package let filteredBufferedFrames: Double
    package let normalizedError: Double
    package let adjustmentPPM: Double
    package let elapsedFrames: Int
    package let sampleRate: Double
    package let targetSource: String
    package var controlState: String? = nil
}

package struct QueueTimingSample: Sendable, Codable {
    package init(identity: AudioTraceIdentity, timestamp: PerformanceTick, isEntry: Bool, queuedFrames: Int, capacityFrames: Int) {
        self.identity = identity
        self.timestamp = timestamp
        self.isEntry = isEntry
        self.queuedFrames = queuedFrames
        self.capacityFrames = capacityFrames
    }

    package let identity: AudioTraceIdentity
    package let timestamp: PerformanceTick
    package let isEntry: Bool
    package let queuedFrames: Int
    package let capacityFrames: Int
}

package struct PCMQueueRecoverySample: Sendable, Codable {
    package init(captureID: UInt64, runtimeSessionID: UUID, timestamp: PerformanceTick, queuedFramesBeforeRecovery: Int, incomingFrames: Int, droppedFrames: Int, sampleRate: Double, writerBlockInProgressFrames: Int, recovery: PCMQueueRecovery? = nil) {
        self.captureID = captureID
        self.runtimeSessionID = runtimeSessionID
        self.timestamp = timestamp
        self.queuedFramesBeforeRecovery = queuedFramesBeforeRecovery
        self.incomingFrames = incomingFrames
        self.droppedFrames = droppedFrames
        self.sampleRate = sampleRate
        self.writerBlockInProgressFrames = writerBlockInProgressFrames
        self.recovery = recovery
    }

    package let captureID: UInt64
    package let runtimeSessionID: UUID
    package let timestamp: PerformanceTick
    package let queuedFramesBeforeRecovery: Int
    package let incomingFrames: Int
    package let droppedFrames: Int
    package let sampleRate: Double
    package let writerBlockInProgressFrames: Int
    package var recovery: PCMQueueRecovery? = nil
}

package struct PCMQueueSnapshot: Sendable, Codable, Equatable {
    package init(queuedFrames: Int = 0, peakQueuedFrames: Int = 0, capacityFrames: Int = 0, sampleRate: Double = 0.0, peakDurationMilliseconds: Double = 0.0, latestBlockFrames: Int = 0, operatingTargetFrames: Int? = nil, rateTargetMode: PCMRateTargetMode? = nil, recoveryTargetFrames: Int? = nil, hardLimitFrames: Int? = nil, recoveryGeneration: UInt64? = nil, lastRecovery: PCMQueueRecovery? = nil, lastRecoveryUptime: UInt64? = nil, lastRecoveryDroppedFrames: Int = 0, lastRecoveryQueuedFrames: Int = 0, lastRecoveryIncomingFrames: Int = 0, lastRecoverySampleRate: Double = 0.0) {
        self.queuedFrames = queuedFrames
        self.peakQueuedFrames = peakQueuedFrames
        self.capacityFrames = capacityFrames
        self.sampleRate = sampleRate
        self.peakDurationMilliseconds = peakDurationMilliseconds
        self.latestBlockFrames = latestBlockFrames
        self.operatingTargetFrames = operatingTargetFrames
        self.rateTargetMode = rateTargetMode
        self.recoveryTargetFrames = recoveryTargetFrames
        self.hardLimitFrames = hardLimitFrames
        self.recoveryGeneration = recoveryGeneration
        self.lastRecovery = lastRecovery
        self.lastRecoveryUptime = lastRecoveryUptime
        self.lastRecoveryDroppedFrames = lastRecoveryDroppedFrames
        self.lastRecoveryQueuedFrames = lastRecoveryQueuedFrames
        self.lastRecoveryIncomingFrames = lastRecoveryIncomingFrames
        self.lastRecoverySampleRate = lastRecoverySampleRate
    }

    package var queuedFrames = 0
    package var peakQueuedFrames = 0
    package var capacityFrames = 0
    package var sampleRate = 0.0
    package var peakDurationMilliseconds = 0.0
    package var latestBlockFrames = 0
    // Optional for historical Stage 2–10 baseline decoding.
    package var operatingTargetFrames: Int? = nil
    package var rateTargetMode: PCMRateTargetMode? = nil
    package var recoveryTargetFrames: Int? = nil
    package var hardLimitFrames: Int? = nil
    package var recoveryGeneration: UInt64? = nil
    package var lastRecovery: PCMQueueRecovery? = nil
    package var lastRecoveryUptime: UInt64?
    package var lastRecoveryDroppedFrames = 0
    package var lastRecoveryQueuedFrames = 0
    package var lastRecoveryIncomingFrames = 0
    package var lastRecoverySampleRate = 0.0
    package var durationMilliseconds: Double { sampleRate > 0 ? Double(queuedFrames) * 1000 / sampleRate : 0 }
    package var capacityMilliseconds: Double { sampleRate > 0 ? Double(capacityFrames) * 1000 / sampleRate : 0 }
}

package enum PerformanceEvent: Sendable {
    case packet(PacketLatencySample)
    case audio(AudioLatencySample)
    case recovery(PCMQueueRecoverySample)
    case queue(QueueTimingSample)
    case presentation(PresentationPerformanceSample)
    package var timestamp: PerformanceTick {
        switch self {
        case .packet(let sample): return sample.received
        case .audio(let sample): return sample.packetReceived ?? sample.queueEntered
        case .recovery(let sample): return sample.timestamp
        case .queue(let sample): return sample.timestamp
        case .presentation(let sample): return sample.started
        }
    }
}

package struct PresentationPerformanceSample: Sendable, Codable {
    package init(phase: String, started: PerformanceTick, ended: PerformanceTick, revision: UInt64, builtOnPublicationWorker: Bool? = nil) {
        self.phase = phase
        self.started = started
        self.ended = ended
        self.revision = revision
        self.builtOnPublicationWorker = builtOnPublicationWorker
    }

    package let phase: String
    package let started: PerformanceTick
    package let ended: PerformanceTick
    package let revision: UInt64
    package var builtOnPublicationWorker: Bool? = nil
}
