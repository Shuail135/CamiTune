import Foundation

package enum PCMQueueRecoveryStrategy: String, Codable, Hashable, Sendable {
    case clearAll
    case trimOldestToTarget
}

package enum PCMRateTargetMode: String, Codable, Hashable, Sendable {
    case configured
    case configuredWhenQueued
    case clockTracked
    // Historical comparison policy; persisted performance captures retain its name.
    case legacyBlockTarget
}

/// Frame-domain policy. Slot allocation, mixer holdback and backend buffers are
/// deliberately not part of the writer's controlled backlog.
package struct PCMQueuePolicy: Codable, Hashable, Sendable {
    package init(sampleRate: Double, operatingTargetFrames: Int, recoveryTargetFrames: Int,
                 hardLimitFrames: Int, recoveryStrategy: PCMQueueRecoveryStrategy,
                 rateTargetMode: PCMRateTargetMode = .configured) {
        self.sampleRate = sampleRate
        self.operatingTargetFrames = operatingTargetFrames
        self.recoveryTargetFrames = recoveryTargetFrames
        self.hardLimitFrames = hardLimitFrames
        self.recoveryStrategy = recoveryStrategy
        self.rateTargetMode = rateTargetMode
    }

    package let sampleRate: Double
    package let operatingTargetFrames: Int
    package let recoveryTargetFrames: Int
    package let hardLimitFrames: Int
    package let recoveryStrategy: PCMQueueRecoveryStrategy
    package var rateTargetMode: PCMRateTargetMode

    package func rateTarget(writerBlockFrames: Int) -> Int {
        switch rateTargetMode {
        case .configured, .configuredWhenQueued, .clockTracked: return operatingTargetFrames
        case .legacyBlockTarget: return min(Int(sampleRate * 0.04), writerBlockFrames * 2)
        }
    }

    package var isValid: Bool {
        sampleRate.isFinite && sampleRate > 0 && operatingTargetFrames > 0
            && recoveryTargetFrames >= 0 && recoveryTargetFrames <= operatingTargetFrames
            && operatingTargetFrames < hardLimitFrames
    }

    package func effectiveHardLimit(incomingFrames: Int) -> Int { max(hardLimitFrames, incomingFrames) }
    package func milliseconds(_ frames: Int) -> Double { Double(frames) * 1000 / sampleRate }
}

/// Immutable member of the prepared runtime plan. Chunk size remains graph-owned.
package struct PCMDeliveryConfiguration: Codable, Hashable, Sendable {
    package init(queue: PCMQueuePolicy, camillaQueueLimit: Int) {
        self.queue = queue
        self.camillaQueueLimit = camillaQueueLimit
    }

    package let queue: PCMQueuePolicy
    package let camillaQueueLimit: Int

    /// One plan-owned operating policy. Existing profile chunk sizes stay intact.
    /// Clock evidence remains meaningful when the application queue is empty;
    /// recovery retains the measured clear-all behavior and the 100 ms bound.
    package static func standard(sampleRate: Double, chunkSize: Int) -> Self {
        .init(queue: .init(sampleRate: sampleRate,
            operatingTargetFrames: min(chunkSize, Int(sampleRate * 0.04)),
            recoveryTargetFrames: 0, hardLimitFrames: Int(sampleRate * 0.1),
            recoveryStrategy: .clearAll, rateTargetMode: .clockTracked), camillaQueueLimit: 2)
    }

    package var summary: String {
        "Writer operating target: \(queue.operatingTargetFrames) frames / \(String(format: "%.3f", queue.milliseconds(queue.operatingTargetFrames))) ms\n"
            + "Writer recovery target: \(queue.recoveryTargetFrames) frames\n"
            + "Writer hard limit: \(queue.hardLimitFrames) frames / \(String(format: "%.3f", queue.milliseconds(queue.hardLimitFrames))) ms (at least one incoming block)\n"
            + "Writer recovery: \(queue.recoveryStrategy.rawValue)\nCamilla queue limit: \(camillaQueueLimit) chunks per internal queue"
            + "\nRate target mode: \(queue.rateTargetMode.rawValue)"
    }
}

extension PCMQueuePolicy {
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sampleRate = try values.decode(Double.self, forKey: .sampleRate)
        operatingTargetFrames = try values.decode(Int.self, forKey: .operatingTargetFrames)
        recoveryTargetFrames = try values.decode(Int.self, forKey: .recoveryTargetFrames)
        hardLimitFrames = try values.decode(Int.self, forKey: .hardLimitFrames)
        recoveryStrategy = try values.decode(PCMQueueRecoveryStrategy.self, forKey: .recoveryStrategy)
        // Historical A/B captures used the legacy block target even though the
        // proposed configured target was recorded alongside it.
        rateTargetMode = try values.decodeIfPresent(PCMRateTargetMode.self, forKey: .rateTargetMode) ?? .legacyBlockTarget
    }
}
