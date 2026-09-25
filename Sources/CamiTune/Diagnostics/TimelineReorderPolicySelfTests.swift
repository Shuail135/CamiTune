import CamiTuneAudio
import CamiTuneDomain
import Foundation

/// Manual policy time is independent of telemetry and wall Date. No sleeps.
private final class ReorderPolicyFixture {
    var policy: TimelineReorderPolicy
    var tick = PerformanceTick(rawValue: 1_000_000_000)
    var next: Int64 = 0
    init(_ mode: TimelineReorderPolicyMode = .adaptive, fast: Bool = true) {
        var config = TimelineReorderPolicyConfiguration(mode: mode)
        if fast {
            // Compact fixtures deliberately use a narrow reserve to exercise
            // miss/fallback transitions. RM01 uses reviewed production values.
            config.warmupPackets = 4; config.decayIntervalPackets = 4; config.fallbackPackets = 8
            config.safetyMarginFraction = 0.125
        }
        policy = .init(epoch: 1, sampleRate: 48000, configuration: config)
    }
    @discardableResult func feed(_ start: Int64? = nil, count: Int = 1024, committed: Int64? = nil,
                                reason: TimelineEmissionReason? = nil, cycle: UInt64 = 100) -> TimelineReorderEvidence {
        let position = start ?? next
        let result = policy.observe(Self.packet(position, count: count, cycle: cycle), committedEnd: committed, tick: tick, reason: reason)
        policy.acceptedPendingPacket(largest: max(count, policy.pendingLargestPacketFrames), instant: tick)
        next = max(next, position + Int64(count)); tick = tick.advanced(seconds: 0.001)
        return result
    }
    func settle(_ count: Int = 80, size: Int = 1024) { for _ in 0..<count { feed(count: size) } }
    static func packet(_ start: Int64, count: Int = 1024, device: UInt32 = 100, client: UInt32 = 1,
                       cycle: UInt64 = 100, rate: Double = 48000, mode: PlaybackMode = .direct) -> PerAppTimelinePacket {
        .init(deviceObjectID: device, cycleCounter: cycle,
              startSampleTime: start, frameCount: count, channelCount: 2, sampleRate: rate, channelLayout: .stereo,
              playbackMode: mode)
    }
}

private final class ReorderMixerFixture {
    let mixer: PerAppTimelineMixer
    let trace: TimelinePolicyTrace?
    let config: TimelineReorderPolicyConfiguration
    var tick = PerformanceTick(rawValue: 1_000_000_000)
    var output: [Float] = []
    var buses: [PlaybackMode: [Float]] = [:]
    var segments: [Int] = []
    init(_ mode: TimelineReorderPolicyMode, traceCapacity: Int? = nil, fast: Bool = true) {
        var config = TimelineReorderPolicyConfiguration(mode: mode)
        if fast {
            // Compact fixtures deliberately use a narrow reserve to exercise
            // miss/fallback transitions. RM01 uses reviewed production values.
            config.warmupPackets = 4; config.decayIntervalPackets = 4; config.fallbackPackets = 8
            config.safetyMarginFraction = 0.125
        }
        self.config = config; trace = traceCapacity.map { TimelinePolicyTrace(capacity: $0) }
        mixer = .init(storagePolicy: .init(maximumPacketFrames: 65_536), policyConfiguration: config, policyTrace: trace)
    }
    @discardableResult func feed(_ start: Int64, count: Int = 1024, device: UInt32 = 100, client: UInt32 = 1,
                                cycle: UInt64 = 100, rate: Double = 48000, mode: PlaybackMode = .direct,
                                capture: AudioLatencyCapture? = nil) -> TimelineReorderEvidence? {
        let packet = ReorderPolicyFixture.packet(start, count: count, device: device, client: client, cycle: cycle, rate: rate, mode: mode)
        let prep = mixer.preparePacket(packet)
        let samples = (0..<(count * 2)).map { Float(($0 + Int(client)) % 17) / 64 }
        let context = capture.map { PacketPerformanceContext(capture: $0,
            identity: .init(captureID: $0.id, runtimeSessionID: UUID(), transportGeneration: 1, streamEpoch: prep.streamEpoch,
                deviceObjectID: device, startSampleTime: start, frameCount: count, sampleRate: rate, channelCount: 2), received: tick) }
        let frame = samples.withUnsafeBufferPointer { mixer.mixProcessedPacket(prep, samples: $0, policyNow: tick, performance: context, processingCompleted: tick) }
        if let frame { collect(frame) }
        if let capture { capture.append(.packet(.init(identity: context!.identity, received: tick, processed: tick, reorder: mixer.lastReorderEvidence))) }
        tick = tick.advanced(seconds: 0.001)
        return mixer.lastReorderEvidence
    }
    func collect(_ frame: PCMFrame) {
        output += frame.interleaved; segments.append(frame.frameCount)
        for mode in PlaybackMode.allCases { buses[mode, default: []] += frame.playbackModeSamples[mode] ?? Array(repeating: 0, count: frame.interleaved.count) }
    }
    func finish() {
        tick = tick.advanced(seconds: 1)
        while case .flushed(let frame) = mixer.flushExpired(policyNow: tick) { collect(frame) }
    }
    func document() -> TimelinePolicyTraceDocument { trace!.document(configuration: config, statistics: mixer.statisticsSnapshot()) }
}

extension DeveloperSelfTests {
    static func reorderPolicyCases() -> [DiagnosticCase] {
        let names = ["Legacy holdback exactness", "Legacy idle exactness", "In-order depth", "Coincident client depth",
            "Unequal overlap depth", "Future packet depth", "Cycle counters are not ordering", "Client count is not completeness",
            "Format resets evidence", "Restart resets evidence", "Discontinuity resets evidence", "Conservative warm-up",
            "One-packet floor", "Immediate rise", "Cautious decay", "Sustained packet-driven decay", "Packet growth resets caution",
            "Packet shrink retains caution", "Miss enters fallback", "Cooldown blocks decay", "Recovery through warm-up",
            "Separate legacy limit", "Legacy ceiling", "Epoch packet floor", "Idle bounds", "Earlier safe idle tail",
            "Late idle contribution fallback", "Device-local policy", "Tracing independence", "Full telemetry drops only",
            "Shadow PCM identity", "Hypothetical miss detection", "Metadata replay identity", "Mixer owns wake deadline",
            "Injected monotonic clock", "Sparse short-sound tails", "Joining client evidence", "Departing client caution",
            "Mixed packet sizes", "Safe adaptive PCM equality", "Reservation trace does not gate flush",
            "Empty transport is not tail completeness", "Reservation trace backward compatibility"]
        return names.enumerated().map { index, name in
            DiagnosticCase(id: String(format: "RP%02d", index + 1), suite: "Reorder Policy", name: name, safety: .simulated) {
                try runReorderPolicyCase(index + 1)
                return .init(summary: name)
            }
        }
    }

    private static func runReorderPolicyCase(_ id: Int) throws {
        let f = ReorderPolicyFixture()
        func require(_ condition: Bool, _ message: String = "Policy invariant failed") throws { try diagnosticRequire(condition, "RP\(id): " + message) }
        switch id {
        case 1: try require(TimelineReorderPolicy.legacyWindow(1024) == 2048)
        case 2: try require(TimelineReorderPolicy.legacyIdleDelay(1024, sampleRate: 48000) == 0.032)
        case 3: f.feed(0); try require(f.feed(1024).reorderDepthFrames == 0)
        case 4: f.feed(0); try require(f.feed(0).reorderDepthFrames == 1024)
        case 5: f.feed(0); try require(f.feed(128, count: 256).reorderDepthFrames == 896)
        case 6: f.feed(0); try require(f.feed(2048).reorderDepthFrames == 0)
        case 7:
            let other = ReorderPolicyFixture()
            for start: Int64 in [0, 0, 1024, 800, 2048] {
                try require(f.feed(start, cycle: 100).reorderDepthFrames == other.feed(start, cycle: 9999).reorderDepthFrames)
                try require(f.policy.currentCommitWindowFrames == other.policy.currentCommitWindowFrames)
            }
        case 8:
            let box = try DiagnosticSandbox(); defer { box.cleanUp() }
            let controllers = [1, 10].map { number in
                let c = PerAppAudioController(settingsURL: box.directory.appendingPathComponent("count\(number).json"), monitorsRunningApplications: false,
                    timelinePolicy: .init(mode: .adaptive))
                c.updateClients((1...number).map { .init(deviceObjectID: 100, clientID: UInt32($0), processID: 0, bundleID: "test.\($0)", isActive: true, generation: 1) })
                return c
            }
            for c in controllers { _ = c.ingest(.init(deviceObjectID: 100, clientID: 1, processID: 0, cycleCounter: 100, sampleTime: 0,
                interleaved: Array(repeating: 0, count: 2048), channelCount: 2, sampleRate: 48000)) }
            try require(controllers[0].timelineStatisticsSnapshot()!.policySnapshots!.first!.activeWindowFrames == controllers[1].timelineStatisticsSnapshot()!.policySnapshots!.first!.activeWindowFrames)
        case 9, 10, 11:
            let m = ReorderMixerFixture(.adaptive)
            for n in 0..<80 { m.feed(Int64(20000 + n * 1024)) }
            let before = m.mixer.lastReorderEvidence!.streamEpoch
            let e = id == 9 ? m.feed(101920, rate: 44100) : id == 10 ? m.feed(0, cycle: 1) : m.feed(200000)
            try require(e!.streamEpoch != before && e!.runtimeState == .warmup && e!.reorderDepthFrames == 0)
            try require(e!.activeWindowFrames == 2048)
        case 12: f.feed(); try require(f.policy.currentCommitWindowFrames == 2048 && f.policy.runtimeState == .warmup)
        case 13: f.settle(); try require(f.policy.currentCommitWindowFrames == 1024)
        case 14:
            f.settle(); let before = f.policy.currentCommitWindowFrames
            let e = f.feed(f.next - 1400, committed: f.next - 1024)
            try require(e.windowIncreased && f.policy.currentCommitWindowFrames > before)
        case 15:
            f.settle(); f.feed(f.next - 1400, committed: f.next - 1024)
            let before = f.policy.currentCommitWindowFrames; f.feed(); try require(f.policy.currentCommitWindowFrames == before)
        case 16:
            f.feed(); f.settle(4); let before = f.policy.currentCommitWindowFrames
            f.feed(); try require(f.policy.currentCommitWindowFrames == before)
            f.settle(3); try require(f.policy.currentCommitWindowFrames == before - 128)
        case 17:
            f.settle(size: 256); let e = f.feed(count: 1024)
            try require(e.packetSizeReset && f.policy.currentCommitWindowFrames == 2048 && f.policy.runtimeState == .warmup)
        case 18:
            f.feed(); let before = f.policy.currentCommitWindowFrames; f.feed(count: 256)
            try require(f.policy.currentCommitWindowFrames == before && f.policy.observation.largestPacketFrames == 1024)
        case 19, 20, 21:
            f.settle(); let e = f.feed(f.next - 1400, committed: f.next - 1024)
            try require(e.adaptivePolicyMiss && e.enteredFallback && f.policy.runtimeState == .fallback && f.policy.currentCommitWindowFrames == 2048)
            if id >= 20 { f.settle(7); try require(f.policy.runtimeState == .fallback && f.policy.currentCommitWindowFrames == 2048) }
            if id == 21 {
                let recovered = f.feed(); try require(recovered.fallbackRecovered && f.policy.runtimeState == .warmup)
                f.settle(4); try require(f.policy.runtimeState == .adaptive && f.policy.currentCommitWindowFrames == 2048)
            }
        case 22:
            f.settle(); let e = f.feed(f.next - 2304, committed: f.next - 2048)
            var c = TimelineReorderCounters(); c.record(e)
            try require(c.legacyLimitMisses == 1 && e.predictedLegacyLateFrames > 0 && !e.adaptivePolicyMiss)
        case 23, 24, 25:
            for i in 0..<200 {
                f.feed(count: [256, 1024, 256, 512, 1024][i % 5])
                try require(f.policy.currentCommitWindowFrames <= f.policy.legacyWindowFrames)
                try require(f.policy.currentCommitWindowFrames >= f.policy.observation.largestPacketFrames)
                try require(f.policy.currentIdleDelay >= 0.004 && f.policy.currentIdleDelay <= TimelineReorderPolicy.legacyIdleDelay(f.policy.observation.largestPacketFrames, sampleRate: 48000))
            }
        case 26:
            let m = ReorderMixerFixture(.adaptive)
            for n in 0..<80 { m.feed(Int64(n * 1024)) }
            let delay = m.mixer.nextWakeDelay(policyNow: m.tick)!
            try require(delay < 0.031)
            if case .flushed = m.mixer.flushExpired(policyNow: m.tick.advanced(seconds: delay - 0.00001)) { try require(false, "Early idle") }
            guard case .flushed = m.mixer.flushExpired(policyNow: m.tick.advanced(seconds: delay + 0.00001)) else { try require(false, "Tail not flushed"); return }
        case 27:
            let m = ReorderMixerFixture(.adaptive)
            for n in 0..<80 { m.feed(Int64(n * 1024)) }
            let last = m.mixer.lastReorderEvidence!.packetStartSampleTime
            m.tick = m.tick.advanced(seconds: 0.028)
            _ = m.mixer.flushExpired(policyNow: m.tick)
            let e = m.feed(last)!
            try require(e.adaptivePolicyMiss && e.lateAfterIdle && e.runtimeState == .fallback)
        case 28:
            let m = ReorderMixerFixture(.adaptive)
            for n in 0..<80 { m.feed(Int64(n * 1024), device: 100); m.feed(Int64(n * 1024), device: 200) }
            m.feed(80 * 1024 - 1400, device: 100)
            let snapshots = m.mixer.statisticsSnapshot().policySnapshots!
            try require(snapshots[0].activeWindowFrames > snapshots[1].activeWindowFrames)
        case 29, 30, 31, 33, 40:
            let left = ReorderMixerFixture(.legacy)
            let mode: TimelineReorderPolicyMode = id == 31 || id == 33 ? .shadowAdaptive : .adaptive
            let right = ReorderMixerFixture(mode, traceCapacity: id == 30 ? 1 : 10000)
            let control = ReorderMixerFixture(mode)
            let capture = id == 30 ? AudioLatencyCapture(id: 10, start: right.tick, deadline: right.tick.advanced(seconds: 10), capacity: 1) : nil
            for n in 0..<100 {
                for client: UInt32 in [1, 2] {
                    left.feed(Int64(n * 1024), client: client)
                    right.feed(Int64(n * 1024), client: client, capture: capture)
                    control.feed(Int64(n * 1024), client: client)
                    try require(right.mixer.lastReorderEvidence == control.mixer.lastReorderEvidence)
                }
            }
            for m in [left, right, control] { m.finish() }
            try require(left.output == right.output && right.output == control.output && left.buses == right.buses && right.buses == control.buses, "PCM/buses changed")
            try require(right.mixer.statistics.reorder.adaptiveMisses == 0 && right.mixer.statistics.reorder.shadowMisses == 0)
            if id == 31 { try require(left.segments == right.segments) }
            if id == 30 { try require(right.trace!.droppedEvents > 0 && capture!.telemetryDrops > 0) }
            if id == 33 {
                try require(right.document().replay().decisionMismatches == 0)
                right.mixer.reset(); right.feed(0); right.feed(1024, rate: 44100); right.feed(20000, rate: 44100)
                let document = right.document()
                try require(document.replay().decisionMismatches == 0)
                try require(document.events.contains { $0.boundaryReason == .format }
                    && document.events.contains { $0.boundaryReason == .discontinuity })
            }
        case 32:
            let m = ReorderMixerFixture(.shadowAdaptive, traceCapacity: 1000)
            for n in 0..<80 { m.feed(Int64(n * 1024)) }
            let e = m.feed(80 * 1024 - 1400)!
            try require(e.shadowAdaptiveMiss && e.committedLateFrames == 0 && e.runtimeState == .fallback)
            try require(m.document().replay().decisionMismatches == 0)
        case 34:
            let m = ReorderMixerFixture(.legacy); m.feed(0)
            let delay = m.mixer.nextWakeDelay(policyNow: m.tick)!
            guard case .retryAfter(let retry) = m.mixer.flushExpired(policyNow: m.tick) else { try require(false); return }
            try require(delay == retry && abs(delay - 0.031) < 0.000001)
        case 35:
            let origin = PerformanceTick(rawValue: 1_000_000_000)
            let mixer = PerAppTimelineMixer(storagePolicy: .init(maximumPacketFrames: 65_536),
                policyConfiguration: .init(mode: .legacy), clock: .init(now: { origin }))
            let packet = ReorderPolicyFixture.packet(0)
            let preparation = mixer.preparePacket(packet)
            _ = [Float](repeating: 1, count: 2048).withUnsafeBufferPointer {
                mixer.mixProcessedPacket(preparation, samples: $0)
            }
            guard case .retryAfter(let delay) = mixer.flushExpired() else {
                try require(false, "Injected clock did not control eligibility"); return
            }
            try require(abs(delay - 0.032) < 0.000001)
            guard case .flushed(let frame) = mixer.flushExpired(policyNow: origin.advanced(seconds: delay)) else {
                try require(false, "Monotonic deadline did not release tail"); return
            }
            try require(frame.frameCount == 1024)
        case 36:
            let m = ReorderMixerFixture(.adaptive)
            for n in 0..<20 {
                m.feed(Int64(n * 1024)); let delay = m.mixer.nextWakeDelay(policyNow: m.tick)!
                guard case .retryAfter = m.mixer.flushExpired(policyNow: m.tick.advanced(seconds: delay / 2)) else { try require(false); return }
                m.tick = m.tick.advanced(seconds: delay + 0.00001)
                guard case .flushed(let frame) = m.mixer.flushExpired(policyNow: m.tick) else { try require(false); return }
                try require(frame.frameCount == 1024)
                guard case .idle = m.mixer.flushExpired(policyNow: m.tick) else { try require(false); return }
            }
        case 37:
            let m = ReorderMixerFixture(.adaptive)
            for n in 0..<80 { m.feed(Int64(n * 1024)) }
            let e = m.feed(79 * 1024, client: 99)!
            try require(e.reorderDepthFrames == 1024 && e.committedLateFrames == 0 && e.activeWindowFrames == 1152)
        case 38:
            for n in 0..<80 { f.feed(Int64(n * 1024)); f.feed(Int64(n * 1024)) }
            let before = f.policy.currentCommitWindowFrames; f.feed()
            try require(f.policy.currentCommitWindowFrames == before)
        case 39:
            let m = ReorderMixerFixture(.adaptive)
            var start: Int64 = 0
            for size in [256, 1024, 256, 512, 1024] {
                m.feed(start, count: size); let e = m.feed(start, count: size, client: 2)!
                try require(e.activeWindowFrames >= e.largestPacketFrames && e.activeWindowFrames <= 2 * e.largestPacketFrames && e.committedLateFrames == 0)
                start += Int64(size)
            }
        case 41:
            let traced = ReorderMixerFixture(.adaptive, traceCapacity: 100)
            let control = ReorderMixerFixture(.adaptive)
            for m in [traced, control] { m.feed(0, count: 512); m.tick = m.tick.advanced(seconds: 0.016) }
            let observation = TimelineTransportReadObservation(sampledAt: traced.tick, transportGeneration: 7,
                valid: true, readPacket: UInt64.max, reservedWritePacket: 0, readFrame: 0, reservedWriteFrame: 512)
            try require(observation.outstandingReservations == 1 && observation.reservedFrames == 512)
            guard case .flushed(let actual) = traced.mixer.flushExpired(policyNow: traced.tick, transportRead: observation),
                  case .flushed(let expected) = control.mixer.flushExpired(policyNow: control.tick) else {
                try require(false, "Diagnostic observation changed deadline"); return
            }
            try require(actual.interleaved == expected.interleaved && actual.playbackModeSamples == expected.playbackModeSamples)
            let document = traced.document()
            try require(document.events.last?.transportRead == observation && document.replay().decisionMismatches == 0)
        case 42:
            // Captured stop-tail order. Keep this known limit visible: even zero
            // reservations at the idle read cannot close future producer work.
            for mode: TimelineReorderPolicyMode in [.legacy, .shadowAdaptive, .adaptive] {
                let m = ReorderMixerFixture(mode, traceCapacity: 100, fast: false)
                let origin = m.tick
                for (time, start) in [(0.0, 696204), (0.008899, 696636), (0.010545, 696716)] {
                    m.tick = origin.advanced(seconds: time); m.feed(Int64(start), count: 512)
                }
                m.tick = origin.advanced(seconds: 0.033963)
                let empty = TimelineTransportReadObservation(sampledAt: m.tick, transportGeneration: 1,
                    valid: true, readPacket: 3, reservedWritePacket: 3, readFrame: 1536, reservedWriteFrame: 1536)
                guard case .flushed(let tail) = m.mixer.flushExpired(policyNow: m.tick, transportRead: empty) else {
                    try require(false, "Legacy deadline unexpectedly changed"); return
                }
                m.collect(tail)
                m.tick = origin.advanced(seconds: 0.035711); m.feed(697228, count: 512)
                m.tick = origin.advanced(seconds: 0.049187)
                let late = m.feed(697148, count: 512)!
                try require(late.committedLateFrames == 80 && late.adaptiveLostFrames == 0)
                if mode == .adaptive { try require(late.enteredFallback && late.runtimeState == .fallback) }
                try require(m.document().replay().decisionMismatches == 0)
            }
        case 43:
            let json = #"{"kind":"idleWake","tick":{"rawValue":1000}}"#.data(using: .utf8)!
            let old = try JSONDecoder().decode(TimelinePolicyTraceEvent.self, from: json)
            try require(old.transportRead == nil)
            let m = ReorderMixerFixture(.legacy, traceCapacity: 100); m.feed(0); m.finish()
            let document = try JSONDecoder().decode(TimelinePolicyTraceDocument.self, from: JSONEncoder().encode(m.document()))
            try require(document.replay().decisionMismatches == 0)
        default: throw DiagnosticFailure(message: "Missing reorder test")
        }
    }
}

private struct ReorderMatrixResult: Codable {
    let scenario: String
    let mode: TimelineReorderPolicyMode
    let packets: UInt64
    let pcmSamples: Int
    let exactLegacyPCM: Bool
    let exactLegacySegmentation: Bool
    let replayMismatches: Int
    let counters: TimelineReorderCounters
    let finalPolicies: [TimelineReorderPolicySnapshot]
    let meanWindowMilliseconds: Double
    let minimumWindowFrames: Int
}

extension DeveloperSelfTests {
    static func reorderMatrixCases() -> [DiagnosticCase] {
        [DiagnosticCase(id: "RM01", suite: "Reorder Policy", name: "Normal policy matrix", safety: .simulated) {
            guard let path = ProcessInfo.processInfo.environment["CAMITUNE_STAGE10_MATRIX_PATH"] else {
                return .init(summary: "Set CAMITUNE_STAGE10_MATRIX_PATH for the production-parameter normal matrix")
            }
            var results: [ReorderMatrixResult] = []
            for scenario in ["R1 single 1024", "R2 coincident clients 1024", "R3 mixed 256/1024", "R4 client join/stop", "R5 sparse short sounds", "R6 playback modes"] {
                var referencePCM: [Float] = [], referenceBuses: [PlaybackMode: [Float]] = [:], referenceSegments: [Int] = []
                for mode in [TimelineReorderPolicyMode.legacy, .shadowAdaptive, .adaptive] {
                    let f = ReorderMixerFixture(mode, traceCapacity: 20000, fast: false)
                    for cycle in 0..<1400 {
                        let start = Int64(cycle * 1024)
                        let bus: PlaybackMode = scenario.hasPrefix("R6") ? PlaybackMode.allCases[cycle % 3] : .direct
                        f.feed(start, mode: bus)
                        if scenario.hasPrefix("R2") || scenario.hasPrefix("R6") || (scenario.hasPrefix("R4") && cycle % 400 < 200) {
                            f.feed(start, client: 2, mode: bus)
                        } else if scenario.hasPrefix("R3") {
                            for offset in stride(from: 0, to: 1024, by: 256) { f.feed(start + Int64(offset), count: 256, client: 2) }
                        }
                        if scenario.hasPrefix("R5") && cycle % 3 == 2 { f.finish() }
                    }
                    f.finish()
                    if mode == .legacy { referencePCM = f.output; referenceBuses = f.buses; referenceSegments = f.segments }
                    let exact = f.output == referencePCM && f.buses == referenceBuses
                    let document = f.document(), replay = document.replay()
                    let counters = f.mixer.statistics.reorder
                    try diagnosticRequire(exact && replay.decisionMismatches == 0 && document.droppedEvents == 0,
                        "\(scenario)/\(mode): PCM or replay mismatch")
                    try diagnosticRequire(counters.committedLateFrames == 0 && counters.shadowMisses == 0 && counters.adaptiveMisses == 0 && counters.legacyLimitMisses == 0,
                        "\(scenario)/\(mode): normal workload miss")
                    if mode == .shadowAdaptive { try diagnosticRequire(f.segments == referenceSegments, "Shadow changed PCM segmentation") }
                    let evidence = document.events.compactMap(\.evidence)
                    let windows = evidence.map { mode == .shadowAdaptive ? $0.candidateWindowFrames : $0.activeWindowFrames }
                    results.append(.init(scenario: scenario, mode: mode, packets: counters.packets, pcmSamples: f.output.count,
                        exactLegacyPCM: exact, exactLegacySegmentation: f.segments == referenceSegments,
                        replayMismatches: replay.decisionMismatches, counters: counters,
                        finalPolicies: f.mixer.statisticsSnapshot().policySnapshots ?? [],
                        meanWindowMilliseconds: Double(windows.reduce(0, +)) / Double(windows.count) / 48,
                        minimumWindowFrames: windows.min() ?? 0))
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: URL(fileURLWithPath: path), options: .atomic)
            return .init(summary: "18 normal workload/mode combinations: exact combined and mode-bus PCM; zero misses; exact replay")
        }, DiagnosticCase(id: "RM02", suite: "Reorder Policy", name: "Fixed-seed adversarial depths and idle gaps", safety: .simulated) {
            var seed: UInt64 = 1009
            for trial in 0..<36 {
                let f = ReorderMixerFixture(.shadowAdaptive, traceCapacity: 2000)
                for cycle in 0..<80 { f.feed(Int64(cycle * 1024)) }
                seed = seed &* 6364136223846793005 &+ 1
                let depth = [1536, 1946, 2151][trial % 3] + Int(seed % 16)
                let e = f.feed(Int64(80 * 1024 - depth))!
                try diagnosticRequire(e.shadowAdaptiveMiss && e.runtimeState == .fallback, "Adversarial miss did not fall back")
                try diagnosticRequire((f.mixer.statistics.reorder.legacyLimitMisses > 0) == (depth > 2048), "Legacy limit misclassified")
                if trial % 2 == 0 { f.finish(); f.feed(80 * 1024 - 100) }
                try diagnosticRequire(f.document().replay().decisionMismatches == 0, "Adversarial replay mismatch")
            }
            return .init(summary: "36 fixed-seed 1.5P/1.9P/>2P traces, fallback and idle replay")
        }, DiagnosticCase(id: "RM03", suite: "Reorder Policy", name: "Counterfactual legacy frontier equals real mixer", safety: .simulated) {
            let f = ReorderMixerFixture(.legacy)
            var virtual = TimelineVirtualCommitState()
            func feed(_ start: Int64, _ count: Int) throws {
                let tick = f.tick
                virtual.expire(at: tick, delay: TimelineReorderPolicy.legacyIdleDelay(virtual.largestPendingPacket, sampleRate: 48000))
                let evidence = f.feed(start, count: count)!
                try diagnosticRequire(evidence.activeWindowFrames == f.mixer.statisticsSnapshot().policySnapshots!.first!.activeWindowFrames, "Reported window differs from applied window after trimming")
                try diagnosticRequire(evidence.committedEndBeforePacket == virtual.committedEnd
                    && evidence.committedLateFrames == virtual.lostFrames(start: start, count: count), "Counterfactual legacy frontier diverged")
                virtual.insert(start: start, count: count, tick: tick, window: nil)
            }
            for (start, count) in [(0, 256), (256, 256), (1024, 1024), (2048, 256), (0, 384)] { try feed(Int64(start), count) }
            f.finish(); virtual.expire(at: f.tick, delay: TimelineReorderPolicy.legacyIdleDelay(virtual.largestPendingPacket, sampleRate: 48000))
            for (start, count) in [(2176, 256), (2432, 64), (2560, 64), (2624, 64), (2688, 128)] { try feed(Int64(start), count) }
            return .init(summary: "Mixed sizes, gaps, partial stale prefixes, idle drain, and regrowth share the real legacy frontier")
        }]
    }
}
