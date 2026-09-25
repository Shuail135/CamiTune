import Foundation

/// Packet timestamps locate contributions; they never establish completeness.






/// Per-epoch measurement owner. Frontier/evidence survive a drained pending window,
/// but never a stream epoch. The mixer classifies discontinuities before observation.










/// Metadata-only counterfactual. This holds no PCM and never accesses the ring.
package struct TimelineVirtualCommitState: Sendable {
    package init(pendingStart: Int64? = nil, pendingEnd: Int64? = nil, committedEnd: Int64? = nil, largestPendingPacket: Int = 0, lastArrival: PerformanceTick? = nil, lastEmission: TimelineEmissionReason? = nil) {
        self.pendingStart = pendingStart
        self.pendingEnd = pendingEnd
        self.committedEnd = committedEnd
        self.largestPendingPacket = largestPendingPacket
        self.lastArrival = lastArrival
        self.lastEmission = lastEmission
    }

    package var pendingStart: Int64?
    package var pendingEnd: Int64?
    package var committedEnd: Int64?
    package var largestPendingPacket = 0
    package var lastArrival: PerformanceTick?
    package var lastEmission: TimelineEmissionReason?

    package mutating func expire(at tick: PerformanceTick, delay: Double) {
        guard let arrival = lastArrival, let end = pendingEnd,
              tick >= arrival.advanced(seconds: delay) else { return }
        committedEnd = max(committedEnd ?? end, end)
        pendingStart = nil; pendingEnd = nil; largestPendingPacket = 0
        lastArrival = nil; lastEmission = .idleTail
    }
    package func lostFrames(start: Int64, count: Int) -> Int {
        min(count, committedEnd.map { TimelineReorderObservation.positiveDistance($0, start) } ?? 0)
    }
    package mutating func insert(start: Int64, count: Int, tick: PerformanceTick, window: Int?) {
        let end = start + Int64(count)
        guard end > (committedEnd ?? Int64.min) else { return }
        let survivingStart = max(start, committedEnd ?? start)
        pendingStart = min(pendingStart ?? survivingStart, survivingStart)
        pendingEnd = max(pendingEnd ?? end, end)
        largestPendingPacket = max(largestPendingPacket, Int(end - survivingStart))
        lastArrival = tick
        let appliedWindow = window ?? TimelineReorderPolicy.legacyWindow(largestPendingPacket)
        let safe = pendingEnd!.subtractingReportingOverflow(Int64(appliedWindow))
        if !safe.overflow, safe.partialValue > pendingStart! {
            pendingStart = safe.partialValue
            committedEnd = max(committedEnd ?? safe.partialValue, safe.partialValue)
            lastEmission = .packetFrontier
        }
    }
}



/// A bounded envelope, not a percentile or a completeness claim. The state is
/// driven only by admissible same-epoch packet evidence; silence cannot decay it.
package struct TimelineReorderPolicy {
    package let configuration: TimelineReorderPolicyConfiguration
    package var observation: TimelineReorderObservation
    package let sampleRate: Double
    package var lastArrival: PerformanceTick?
    package var pendingLargestPacketFrames = 0
    package private(set) var runtimeState: TimelineReorderRuntimeState = .warmup
    package private(set) var candidateWindowFrames = 0
    package private(set) var envelopeFrames = 0
    package private(set) var warmupRemaining: Int
    package private(set) var fallbackRemaining = 0
    private var safePackets = 0
    private var blockPeak = 0
    private var legacyVirtual = TimelineVirtualCommitState()
    private var candidateVirtual = TimelineVirtualCommitState()

    package init(epoch: UInt64, sampleRate: Double, configuration: TimelineReorderPolicyConfiguration) {
        precondition(configuration.warmupPackets > 0 && configuration.decayIntervalPackets > 0 && configuration.fallbackPackets > 0)
        precondition(configuration.safetyMarginFraction.isFinite && (0...1).contains(configuration.safetyMarginFraction))
        precondition(configuration.idleSafetyMarginFraction.isFinite && (0...1).contains(configuration.idleSafetyMarginFraction))
        precondition(configuration.decayStepFraction.isFinite && configuration.decayStepFraction > 0 && configuration.decayStepFraction <= 1)
        self.configuration = configuration; self.sampleRate = sampleRate
        observation = .init(epoch: epoch); warmupRemaining = configuration.mode == .legacy ? 0 : configuration.warmupPackets
        runtimeState = configuration.mode == .legacy ? .legacy : .warmup
    }
    package static func legacyWindow(_ packetFrames: Int) -> Int { max(1, packetFrames * 2) }
    package static func legacyIdleDelay(_ packetFrames: Int, sampleRate: Double) -> Double {
        max(0.004, 1.5 * Double(max(1, packetFrames)) / sampleRate)
    }
    package var legacyWindowFrames: Int { Self.legacyWindow(observation.largestPacketFrames) }
    package var currentCommitWindowFrames: Int {
        configuration.mode == .adaptive ? max(1, candidateWindowFrames) : Self.legacyWindow(pendingLargestPacketFrames)
    }
    package var candidateIdleDelay: Double {
        let legacy = Self.legacyIdleDelay(observation.largestPacketFrames, sampleRate: sampleRate)
        guard runtimeState == .adaptive else { return legacy }
        // A one-packet window is not a timer safety margin: independent client
        // callbacks can arrive slightly later than one period. The measured
        // normal trace needed 2.23 ms additional idle slack at 512/48k; 0.25P
        // provides 2.67 ms, still bounded by the original legacy deadline.
        let idleGuard = Int(ceil(Double(observation.largestPacketFrames) * configuration.idleSafetyMarginFraction))
        return min(legacy, max(0.004, Double(candidateWindowFrames + idleGuard) / sampleRate))
    }
    package var currentIdleDelay: Double {
        configuration.mode == .adaptive ? candidateIdleDelay : Self.legacyIdleDelay(pendingLargestPacketFrames, sampleRate: sampleRate)
    }
    package var idleDeadline: PerformanceTick? { lastArrival.map { $0.advanced(seconds: currentIdleDelay) } }
    package var shadowIdleDeadline: PerformanceTick? {
        guard configuration.mode == .shadowAdaptive, candidateVirtual.pendingEnd != nil else { return nil }
        return candidateVirtual.lastArrival.map { $0.advanced(seconds: candidateIdleDelay) }
    }
    package var snapshot: TimelineReorderPolicySnapshot {
        .init(configuration: configuration, epoch: observation.epoch, sampleRate: sampleRate,
            runtimeState: runtimeState, largestPacketFrames: observation.largestPacketFrames,
            legacyWindowFrames: legacyWindowFrames, activeWindowFrames: currentCommitWindowFrames,
            candidateWindowFrames: candidateWindowFrames, envelopeFrames: envelopeFrames,
            legacyIdleMilliseconds: Self.legacyIdleDelay(pendingLargestPacketFrames, sampleRate: sampleRate) * 1000,
            activeIdleMilliseconds: currentIdleDelay * 1000, candidateIdleMilliseconds: candidateIdleDelay * 1000,
            warmupRemaining: warmupRemaining, fallbackRemaining: fallbackRemaining)
    }
    package mutating func acceptedPendingPacket(largest: Int, instant: PerformanceTick) {
        pendingLargestPacketFrames = largest; lastArrival = instant
    }
    package mutating func advanceIdle(at tick: PerformanceTick) {
        guard configuration.mode != .legacy else { return }
        legacyVirtual.expire(at: tick, delay: Self.legacyIdleDelay(legacyVirtual.largestPendingPacket, sampleRate: sampleRate))
        candidateVirtual.expire(at: tick, delay: candidateIdleDelay)
    }
    package mutating func observe(_ packet: PerAppTimelinePacket, committedEnd: Int64?, tick: PerformanceTick,
                          reason: TimelineEmissionReason?) -> TimelineReorderEvidence {
        // Counterfactual timers fire before a packet at/after their deadline.
        // A late real wake may be more conservative; shadow predictions never
        // assume that scheduler delay is a safety guarantee.
        advanceIdle(at: tick)
        let priorLargest = observation.largestPacketFrames
        var evidence = observation.observe(packet, committedEnd: committedEnd, tick: tick, reason: reason)
        let largest = observation.largestPacketFrames
        let previousWindow = candidateWindowFrames
        let previousState = runtimeState
        let legacyLost = legacyVirtual.lostFrames(start: packet.startSampleTime, count: packet.frameCount)
        let candidateLost = candidateVirtual.lostFrames(start: packet.startSampleTime, count: packet.frameCount)
        evidence.legacyWindowFrames = legacyWindowFrames
        evidence.windowUsedFrames = configuration.mode == .adaptive ? previousWindow : Self.legacyWindow(pendingLargestPacketFrames == 0 ? largest : pendingLargestPacketFrames)
        if configuration.mode == .legacy {
            candidateWindowFrames = legacyWindowFrames
            evidence.candidateWindowFrames = candidateWindowFrames
            evidence.runtimeState = .legacy
            envelopeFrames = max(envelopeFrames, evidence.reorderDepthFrames)
            evidence.activeWindowFrames = Self.legacyWindow(max(pendingLargestPacketFrames, packet.frameCount))
            return evidence
        }
        evidence.shadowLateFrames = configuration.mode == .shadowAdaptive ? candidateLost : 0
        evidence.predictedLegacyLateFrames = legacyLost
        let actualCaused = max(0, evidence.committedLateFrames - legacyLost)
        evidence.adaptiveLostFrames = configuration.mode == .adaptive ? actualCaused : 0
        evidence.adaptivePolicyMiss = evidence.adaptiveLostFrames > 0
        evidence.shadowAdaptiveMiss = configuration.mode == .shadowAdaptive && candidateLost > legacyLost
        evidence.lateAfterIdle = (configuration.mode == .adaptive ? reason : candidateVirtual.lastEmission) == .idleTail
            && (configuration.mode == .adaptive ? evidence.committedLateFrames : candidateLost) > 0
        let miss = configuration.mode == .adaptive ? evidence.committedLateFrames > 0 : candidateLost > 0
        let grew = largest > priorLargest
        if grew {
            candidateWindowFrames = legacyWindowFrames
            warmupRemaining = configuration.warmupPackets; safePackets = 0
            if runtimeState != .fallback { runtimeState = .warmup }
        }
        envelopeFrames = min(legacyWindowFrames, max(envelopeFrames, evidence.reorderDepthFrames))
        blockPeak = max(blockPeak, min(legacyWindowFrames, evidence.reorderDepthFrames))
        if miss {
            evidence.enteredFallback = runtimeState != .fallback
            runtimeState = .fallback; candidateWindowFrames = legacyWindowFrames
            fallbackRemaining = configuration.fallbackPackets; safePackets = 0
        } else if runtimeState == .fallback {
            candidateWindowFrames = legacyWindowFrames
            fallbackRemaining = max(0, fallbackRemaining - 1)
            if fallbackRemaining == 0 {
                runtimeState = .warmup; warmupRemaining = configuration.warmupPackets
                safePackets = 0; blockPeak = 0
            }
        } else if runtimeState == .warmup {
            candidateWindowFrames = legacyWindowFrames
            if !grew { warmupRemaining = max(0, warmupRemaining - 1) }
            if warmupRemaining == 0 { runtimeState = .adaptive; safePackets = 0; blockPeak = 0 }
        } else {
            let margin = Int(ceil(Double(largest) * configuration.safetyMarginFraction))
            let step = max(1, Int(ceil(Double(largest) * configuration.decayStepFraction)))
            let target = min(legacyWindowFrames, max(largest, envelopeFrames + margin))
            if target > candidateWindowFrames {
                candidateWindowFrames = target; safePackets = 0
            } else {
                safePackets += 1
                if safePackets >= configuration.decayIntervalPackets {
                    envelopeFrames = max(blockPeak, max(0, envelopeFrames - step))
                    let decayedTarget = min(legacyWindowFrames, max(largest, envelopeFrames + margin))
                    candidateWindowFrames = max(decayedTarget, candidateWindowFrames - step)
                    safePackets = 0; blockPeak = 0
                }
            }
        }
        candidateWindowFrames = min(legacyWindowFrames, max(largest, candidateWindowFrames))
        evidence.windowIncreased = candidateWindowFrames > previousWindow && previousWindow > 0
        evidence.windowDecreased = candidateWindowFrames < previousWindow
        evidence.activeWindowFrames = configuration.mode == .adaptive ? candidateWindowFrames : Self.legacyWindow(max(pendingLargestPacketFrames, packet.frameCount))
        evidence.candidateWindowFrames = candidateWindowFrames
        evidence.runtimeState = runtimeState
        evidence.packetSizeReset = grew && priorLargest > 0
        evidence.fallbackRecovered = previousState == .fallback && runtimeState == .warmup
        // Counterfactual packet commits use updated protection, just like real
        // mixing. The two scalar windows share no PCM or transport behavior.
        legacyVirtual.insert(start: packet.startSampleTime, count: packet.frameCount, tick: tick,
            window: nil)
        candidateVirtual.insert(start: packet.startSampleTime, count: packet.frameCount, tick: tick, window: candidateWindowFrames)
        return evidence
    }
}

// Old trace configurations predate the extra idle guard. Decode their actual
// formula (zero guard), rather than silently changing historical replay results.



