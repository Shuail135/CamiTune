import CamiTuneDomain
import Foundation

// Historical performance-report values. Runtime mixing uses producer completion.

package struct TimelineReorderEvidence: Sendable, Codable, Equatable {
    package init(deviceObjectID: UInt32, streamEpoch: UInt64, sampleRate: Double, packetStartSampleTime: Int64, packetEndSampleTime: Int64, frontierBeforePacket: Int64, packetFrames: Int, largestPacketFrames: Int, reorderDepthFrames: Int, committedEndBeforePacket: Int64? = nil, committedLateFrames: Int, arrivalTick: PerformanceTick, emissionReason: TimelineEmissionReason? = nil, legacyWindowFrames: Int = 0, windowUsedFrames: Int = 0, activeWindowFrames: Int = 0, candidateWindowFrames: Int = 0, shadowLateFrames: Int = 0, predictedLegacyLateFrames: Int = 0, adaptiveLostFrames: Int = 0, adaptivePolicyMiss: Bool = false, shadowAdaptiveMiss: Bool = false, lateAfterIdle: Bool = false, enteredFallback: Bool = false, windowIncreased: Bool = false, windowDecreased: Bool = false, packetSizeReset: Bool = false, fallbackRecovered: Bool = false, runtimeState: TimelineReorderRuntimeState = .warmup) {
        self.deviceObjectID = deviceObjectID
        self.streamEpoch = streamEpoch
        self.sampleRate = sampleRate
        self.packetStartSampleTime = packetStartSampleTime
        self.packetEndSampleTime = packetEndSampleTime
        self.frontierBeforePacket = frontierBeforePacket
        self.packetFrames = packetFrames
        self.largestPacketFrames = largestPacketFrames
        self.reorderDepthFrames = reorderDepthFrames
        self.committedEndBeforePacket = committedEndBeforePacket
        self.committedLateFrames = committedLateFrames
        self.arrivalTick = arrivalTick
        self.emissionReason = emissionReason
        self.legacyWindowFrames = legacyWindowFrames
        self.windowUsedFrames = windowUsedFrames
        self.activeWindowFrames = activeWindowFrames
        self.candidateWindowFrames = candidateWindowFrames
        self.shadowLateFrames = shadowLateFrames
        self.predictedLegacyLateFrames = predictedLegacyLateFrames
        self.adaptiveLostFrames = adaptiveLostFrames
        self.adaptivePolicyMiss = adaptivePolicyMiss
        self.shadowAdaptiveMiss = shadowAdaptiveMiss
        self.lateAfterIdle = lateAfterIdle
        self.enteredFallback = enteredFallback
        self.windowIncreased = windowIncreased
        self.windowDecreased = windowDecreased
        self.packetSizeReset = packetSizeReset
        self.fallbackRecovered = fallbackRecovered
        self.runtimeState = runtimeState
    }

    package let deviceObjectID: UInt32
    package let streamEpoch: UInt64
    package let sampleRate: Double
    package let packetStartSampleTime: Int64
    package let packetEndSampleTime: Int64
    package let frontierBeforePacket: Int64
    package let packetFrames: Int
    package let largestPacketFrames: Int
    package let reorderDepthFrames: Int
    package let committedEndBeforePacket: Int64?
    package let committedLateFrames: Int
    package let arrivalTick: PerformanceTick
    package let emissionReason: TimelineEmissionReason?

    package var legacyWindowFrames = 0
    package var windowUsedFrames = 0
    package var activeWindowFrames = 0
    package var candidateWindowFrames = 0
    package var shadowLateFrames = 0
    package var predictedLegacyLateFrames = 0
    package var adaptiveLostFrames = 0
    package var adaptivePolicyMiss = false
    package var shadowAdaptiveMiss = false
    package var lateAfterIdle = false
    package var enteredFallback = false
    package var windowIncreased = false
    package var windowDecreased = false
    package var packetSizeReset = false
    package var fallbackRecovered = false
    package var runtimeState: TimelineReorderRuntimeState = .warmup
}

package enum TimelineEmissionReason: String, Sendable, Codable { case packetFrontier, idleTail, producerCompletion, formatBoundary, discontinuity, reset }

package struct TimelineReorderCounters: Sendable, Codable {
    package init(shadowMisses: UInt64 = 0, shadowLateFrames: UInt64 = 0, adaptiveMisses: UInt64 = 0, adaptiveLostFrames: UInt64 = 0, predictedLegacyLateFrames: UInt64 = 0, fallbackEntries: UInt64 = 0, fallbackRecoveries: UInt64 = 0, windowIncreases: UInt64 = 0, windowDecreases: UInt64 = 0, lateAfterIdle: UInt64 = 0, packetSizeResets: UInt64 = 0, packets: UInt64 = 0, reorderedPackets: UInt64 = 0, maximumDepthFrames: Int = 0, partiallyLatePackets: UInt64 = 0, fullyLatePackets: UInt64 = 0, committedLateFrames: UInt64 = 0, legacyLimitMisses: UInt64 = 0, excludedPackets: UInt64 = 0, idleEmissions: UInt64 = 0, packetEmissions: UInt64 = 0) {
        self.shadowMisses = shadowMisses
        self.shadowLateFrames = shadowLateFrames
        self.adaptiveMisses = adaptiveMisses
        self.adaptiveLostFrames = adaptiveLostFrames
        self.predictedLegacyLateFrames = predictedLegacyLateFrames
        self.fallbackEntries = fallbackEntries
        self.fallbackRecoveries = fallbackRecoveries
        self.windowIncreases = windowIncreases
        self.windowDecreases = windowDecreases
        self.lateAfterIdle = lateAfterIdle
        self.packetSizeResets = packetSizeResets
        self.packets = packets
        self.reorderedPackets = reorderedPackets
        self.maximumDepthFrames = maximumDepthFrames
        self.partiallyLatePackets = partiallyLatePackets
        self.fullyLatePackets = fullyLatePackets
        self.committedLateFrames = committedLateFrames
        self.legacyLimitMisses = legacyLimitMisses
        self.excludedPackets = excludedPackets
        self.idleEmissions = idleEmissions
        self.packetEmissions = packetEmissions
    }

    package var shadowMisses: UInt64 = 0
    package var shadowLateFrames: UInt64 = 0
    package var adaptiveMisses: UInt64 = 0
    package var adaptiveLostFrames: UInt64 = 0
    package var predictedLegacyLateFrames: UInt64 = 0
    package var fallbackEntries: UInt64 = 0
    package var fallbackRecoveries: UInt64 = 0
    package var windowIncreases: UInt64 = 0
    package var windowDecreases: UInt64 = 0
    package var lateAfterIdle: UInt64 = 0
    package var packetSizeResets: UInt64 = 0
    package var packets: UInt64 = 0
    package var reorderedPackets: UInt64 = 0
    package var maximumDepthFrames = 0
    package var partiallyLatePackets: UInt64 = 0
    package var fullyLatePackets: UInt64 = 0
    package var committedLateFrames: UInt64 = 0
    package var legacyLimitMisses: UInt64 = 0
    package var excludedPackets: UInt64 = 0
    package var idleEmissions: UInt64 = 0
    package var packetEmissions: UInt64 = 0
    package var summary: String {
        "Packets: \(packets); reordered: \(reorderedPackets); maximum depth: \(maximumDepthFrames) frames\nPartial/full late: \(partiallyLatePackets)/\(fullyLatePackets); committed-late contribution frames: \(committedLateFrames)\nLegacy-limit events: \(legacyLimitMisses); excluded far-stale packets: \(excludedPackets)\nPacket/idle emissions: \(packetEmissions)/\(idleEmissions)\nAdditional shadow/adaptive misses: \(shadowMisses)/\(adaptiveMisses); adaptive lost frames: \(adaptiveLostFrames)\nShadow/legacy-counterfactual late frames: \(shadowLateFrames)/\(predictedLegacyLateFrames)\nFallback entries/recoveries: \(fallbackEntries)/\(fallbackRecoveries); late after idle: \(lateAfterIdle)\nWindow rises/decays: \(windowIncreases)/\(windowDecreases); packet-size resets: \(packetSizeResets)"
    }
}

package enum TimelineReorderPolicyMode: String, Sendable, Codable { case legacy, shadowAdaptive, adaptive }

package enum TimelineReorderRuntimeState: String, Sendable, Codable { case legacy, warmup, adaptive, fallback }

package struct TimelineReorderPolicyConfiguration: Sendable, Codable, Equatable {
    package init(mode: TimelineReorderPolicyMode, warmupPackets: Int = 128, safetyMarginFraction: Double = 1.0, idleSafetyMarginFraction: Double = 0.25, decayIntervalPackets: Int = 128, decayStepFraction: Double = 0.125, fallbackPackets: Int = 1024) {
        self.mode = mode
        self.warmupPackets = warmupPackets
        self.safetyMarginFraction = safetyMarginFraction
        self.idleSafetyMarginFraction = idleSafetyMarginFraction
        self.decayIntervalPackets = decayIntervalPackets
        self.decayStepFraction = decayStepFraction
        self.fallbackPackets = fallbackPackets
    }

    package let mode: TimelineReorderPolicyMode
    package var warmupPackets = 128
    package var safetyMarginFraction = 1.0
    package var idleSafetyMarginFraction = 0.25
    package var decayIntervalPackets = 128
    package var decayStepFraction = 0.125
    package var fallbackPackets = 1024

}

package struct TimelineReorderPolicySnapshot: Sendable, Codable {
    package init(deviceObjectID: UInt32? = nil, configuration: TimelineReorderPolicyConfiguration, epoch: UInt64, sampleRate: Double, runtimeState: TimelineReorderRuntimeState, largestPacketFrames: Int, legacyWindowFrames: Int, activeWindowFrames: Int, candidateWindowFrames: Int, envelopeFrames: Int, legacyIdleMilliseconds: Double, activeIdleMilliseconds: Double, candidateIdleMilliseconds: Double, warmupRemaining: Int, fallbackRemaining: Int) {
        self.deviceObjectID = deviceObjectID
        self.configuration = configuration
        self.epoch = epoch
        self.sampleRate = sampleRate
        self.runtimeState = runtimeState
        self.largestPacketFrames = largestPacketFrames
        self.legacyWindowFrames = legacyWindowFrames
        self.activeWindowFrames = activeWindowFrames
        self.candidateWindowFrames = candidateWindowFrames
        self.envelopeFrames = envelopeFrames
        self.legacyIdleMilliseconds = legacyIdleMilliseconds
        self.activeIdleMilliseconds = activeIdleMilliseconds
        self.candidateIdleMilliseconds = candidateIdleMilliseconds
        self.warmupRemaining = warmupRemaining
        self.fallbackRemaining = fallbackRemaining
    }

    package var deviceObjectID: UInt32? = nil
    package let configuration: TimelineReorderPolicyConfiguration
    package let epoch: UInt64
    package let sampleRate: Double
    package let runtimeState: TimelineReorderRuntimeState
    package let largestPacketFrames: Int
    package let legacyWindowFrames: Int
    package let activeWindowFrames: Int
    package let candidateWindowFrames: Int
    package let envelopeFrames: Int
    package let legacyIdleMilliseconds: Double
    package let activeIdleMilliseconds: Double
    package let candidateIdleMilliseconds: Double
    package let warmupRemaining: Int
    package let fallbackRemaining: Int
    package var summary: String {
        """
        Device \(deviceObjectID.map(String.init) ?? "unspecified"), epoch \(epoch), \(Int(sampleRate)) Hz — \(configuration.mode.rawValue) / \(runtimeState.rawValue)
        Packet floor: \(largestPacketFrames) frames
        Window active/candidate/legacy: \(activeWindowFrames)/\(candidateWindowFrames)/\(legacyWindowFrames) frames
        Window active/candidate/legacy: \(String(format: "%.2f / %.2f / %.2f", Double(activeWindowFrames) * 1000 / sampleRate, Double(candidateWindowFrames) * 1000 / sampleRate, Double(legacyWindowFrames) * 1000 / sampleRate)) ms; envelope: \(envelopeFrames) frames
        Idle active/candidate/legacy: \(String(format: "%.2f", activeIdleMilliseconds))/\(String(format: "%.2f", candidateIdleMilliseconds))/\(String(format: "%.2f", legacyIdleMilliseconds)) ms
        Warm-up/cooldown remaining: \(warmupRemaining)/\(fallbackRemaining) accepted packets
        """
    }
}

// Preserve historical trace defaults when decoding older recordings.
extension TimelineReorderPolicyConfiguration {
    private enum TraceKeys: String, CodingKey {
        case mode, warmupPackets, safetyMarginFraction, idleSafetyMarginFraction
        case decayIntervalPackets, decayStepFraction, fallbackPackets
    }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: TraceKeys.self)
        self.init(mode: try values.decode(TimelineReorderPolicyMode.self, forKey: .mode))
        warmupPackets = try values.decodeIfPresent(Int.self, forKey: .warmupPackets) ?? 128
        safetyMarginFraction = try values.decodeIfPresent(Double.self, forKey: .safetyMarginFraction) ?? 0.125
        idleSafetyMarginFraction = try values.decodeIfPresent(Double.self, forKey: .idleSafetyMarginFraction) ?? 0
        decayIntervalPackets = try values.decodeIfPresent(Int.self, forKey: .decayIntervalPackets) ?? 128
        decayStepFraction = try values.decodeIfPresent(Double.self, forKey: .decayStepFraction) ?? 0.125
        fallbackPackets = try values.decodeIfPresent(Int.self, forKey: .fallbackPackets) ?? 1024
    }
}
