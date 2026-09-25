import CamiTuneAudio
import Foundation

/// Bounded developer-only metadata. The mixer owns mutation under audioLock;
/// callers export only after transport shutdown. No samples or application IDs.


/// Sampled by the sole transport reader after a zero-frame read. These raw
/// reservation cursors include unfinished publications, unlike public occupancy.
/// They never gate a flush: even an empty ring is not producer completeness.






struct TimelinePolicyReplayResult: Sendable, Codable {
    var evaluatedConfiguration: TimelineReorderPolicyConfiguration?
    var candidateWindowMilliseconds: LatencyDistribution?
    var counters = TimelineReorderCounters()
    var decisionMismatches = 0
    var minimumCandidateFrames: Int?
    var maximumCandidateFrames = 0
}



extension TimelinePolicyTraceDocument {
    func replay(configuration override: TimelineReorderPolicyConfiguration? = nil) -> TimelinePolicyReplayResult {
        var config = override ?? configuration
        // Alternate candidates are counterfactual: historical real commits cannot
        // be reused as if an alternative adaptive policy had produced them.
        if let alternate = override, alternate.mode == .adaptive {
            config = .init(mode: .shadowAdaptive)
            config.warmupPackets = alternate.warmupPackets
            config.safetyMarginFraction = alternate.safetyMarginFraction
            config.idleSafetyMarginFraction = alternate.idleSafetyMarginFraction
            config.decayIntervalPackets = alternate.decayIntervalPackets
            config.decayStepFraction = alternate.decayStepFraction
            config.fallbackPackets = alternate.fallbackPackets
        }
        var policies: [UInt32: TimelineReorderPolicy] = [:]
        var result = TimelinePolicyReplayResult()
        result.evaluatedConfiguration = config
        var windows: [Double] = []; windows.reserveCapacity(events.count)
        for event in events {
            switch event.kind {
            case .reset: policies.removeAll(keepingCapacity: true)
            case .boundary:
                if let device = event.deviceObjectID { policies.removeValue(forKey: device) }
            case .idleWake:
                for device in policies.keys { policies[device]?.advanceIdle(at: event.tick) }
            case .packet:
                guard let expected = event.evidence else { continue }
                let device = expected.deviceObjectID
                var policy = policies[device].flatMap { $0.observation.epoch == expected.streamEpoch ? $0 : nil }
                    ?? TimelineReorderPolicy(epoch: expected.streamEpoch, sampleRate: expected.sampleRate, configuration: config)
                let packet = PerAppTimelinePacket(deviceObjectID: device, cycleCounter: 0,
                    startSampleTime: expected.packetStartSampleTime, frameCount: expected.packetFrames,
                    channelCount: 2, sampleRate: expected.sampleRate, channelLayout: .stereo,
                    playbackMode: .direct)
                let observed = policy.observe(packet, committedEnd: expected.committedEndBeforePacket,
                    tick: event.tick, reason: expected.emissionReason)
                policies[device] = policy
                result.counters.record(observed)
                windows.append(Double(observed.candidateWindowFrames) * 1000 / expected.sampleRate)
                result.minimumCandidateFrames = min(result.minimumCandidateFrames ?? observed.candidateWindowFrames, observed.candidateWindowFrames)
                result.maximumCandidateFrames = max(result.maximumCandidateFrames, observed.candidateWindowFrames)
                if override == nil && (observed.candidateWindowFrames != expected.candidateWindowFrames
                    || observed.runtimeState != expected.runtimeState || observed.shadowLateFrames != expected.shadowLateFrames
                    || observed.shadowAdaptiveMiss != expected.shadowAdaptiveMiss
                    || observed.adaptiveLostFrames != expected.adaptiveLostFrames
                    || observed.enteredFallback != expected.enteredFallback
                    || observed.windowDecreased != expected.windowDecreased) { result.decisionMismatches += 1 }
            }
        }
        result.candidateWindowMilliseconds = .init(windows)
        return result
    }
}

extension TimelinePolicyTrace {
    static func developerEnvironment() -> TimelinePolicyTrace? {
        ProcessInfo.processInfo.environment["CAMITUNE_POLICY_TRACE_PATH"] == nil ? nil : .init()
    }


}

extension TimelinePolicyTraceDocument {
    func export(to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try encoder.encode(replay()).write(to: url.appendingPathExtension("replay.json"), options: .atomic)
    }
}

extension TimelineReorderPolicyConfiguration {
    static func developerEnvironment() -> Self {
        // Internal launch-only configuration; immutable for the controller lifetime.
        guard let raw = ProcessInfo.processInfo.environment["CAMITUNE_REORDER_MODE"],
              let mode = TimelineReorderPolicyMode(rawValue: raw) else { return .production }
        return .init(mode: mode)
    }
}
