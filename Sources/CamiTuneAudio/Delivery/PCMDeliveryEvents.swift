import Foundation
import CamiTuneDomain

package enum PCMQueueRecoveryReason: String, Codable, Sendable {
    case overflow, sampleRateChange, explicitCalibrationReset, runtimeReset
}

package struct PCMQueueRecovery: Sendable, Codable, Equatable {
    package init(reason: PCMQueueRecoveryReason, generation: UInt64, queuedFramesBefore: Int, incomingFrames: Int, droppedFrames: Int, retainedFrames: Int, queuedFramesAfter: Int, operatingTargetFrames: Int, recoveryTargetFrames: Int, hardLimitFrames: Int, sampleRate: Double, timestamp: PerformanceTick) {
        self.reason = reason
        self.generation = generation
        self.queuedFramesBefore = queuedFramesBefore
        self.incomingFrames = incomingFrames
        self.droppedFrames = droppedFrames
        self.retainedFrames = retainedFrames
        self.queuedFramesAfter = queuedFramesAfter
        self.operatingTargetFrames = operatingTargetFrames
        self.recoveryTargetFrames = recoveryTargetFrames
        self.hardLimitFrames = hardLimitFrames
        self.sampleRate = sampleRate
        self.timestamp = timestamp
    }

    package let reason: PCMQueueRecoveryReason
    package let generation: UInt64
    package let queuedFramesBefore: Int
    package let incomingFrames: Int
    package let droppedFrames: Int
    package let retainedFrames: Int
    package let queuedFramesAfter: Int
    package let operatingTargetFrames: Int
    package let recoveryTargetFrames: Int
    package let hardLimitFrames: Int
    package let sampleRate: Double
    package let timestamp: PerformanceTick
}

package enum PCMQueueEnqueueResult: Sendable {
    case accepted, rejected
    case overflowRecovery(PCMQueueRecovery), formatReset(PCMQueueRecovery)
    package var recovery: PCMQueueRecovery? {
        switch self {
        case .overflowRecovery(let value), .formatReset(let value): return value
        case .accepted, .rejected: return nil
        }
    }
}
