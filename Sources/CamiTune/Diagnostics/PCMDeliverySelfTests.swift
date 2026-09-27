import CamiTuneAudio
import CamiTuneDomain
import Foundation

extension DeveloperSelfTests {
    // PD uses the Stage 11 W-number mapping; W01... already identifies the
    // Stage 3 presentation suite in exported reports.
    static func pcmDeliveryCases() -> [DiagnosticCase] {
        func check(_ id: String, _ name: String, _ body: @escaping @MainActor () throws -> Void) -> DiagnosticCase {
            .init(id: id, suite: "PCM Delivery & Rate Matching", name: name, safety: .simulated) {
                try body(); return .init(summary: name)
            }
        }
        func candidate(_ base: AudioRuntimePlan, _ delivery: PCMDeliveryConfiguration) throws -> AudioRuntimePlan {
            try AudioRuntimePlanCompiler().compile(.init(
                revision: .init(profileID: base.intent.id, generation: base.revision.generation + 1),
                preparedAt: base.preparedAt, profile: base.intent, hardware: base.hardwareEvidence,
                assets: base.assets, deliveryConfiguration: delivery))
        }
        return [
            check("PD01", "Configured target is explicit; legacy block target remains separately observable") {
                let config = PCMDeliveryConfiguration.legacy(sampleRate: 48_000, chunkSize: 1024)
                try diagnosticRequire(config.queue.operatingTargetFrames == 1920 && config.queue.isValid, "Incorrect 40 ms cap")
                try diagnosticRequire(config.queue.rateTarget(writerBlockFrames: 1024) == 1920
                    && config.queue.rateTarget(writerBlockFrames: 512) == 1024,
                    "Retained legacy comparison policy changed")
            },
            check("PD02", "Legacy hard limit accommodates one oversized incoming block") {
                let policy = PCMQueuePolicy.legacy(sampleRate: 48_000, chunkSize: 1024)
                try diagnosticRequire(policy.hardLimitFrames == 4800 && policy.effectiveHardLimit(incomingFrames: 8192) == 8192
                    && policy.recoveryStrategy == .clearAll && policy.recoveryTargetFrames == 0, "Legacy bounds changed")
            },
            check("PD08", "Writer snapshot separates configured target, recovery and hard limit") {
                var queue = LowLatencyPCMQueue()
                queue.configure(.legacy(sampleRate: 48_000, chunkSize: 1024))
                let frame = PCMFrame(interleaved: Array(repeating: 0.1, count: 1024), channelCount: 2, sampleRate: 48_000)
                try diagnosticRequire(queue.append(frame) == 0 && queue.snapshot.operatingTargetFrames == 1920
                    && queue.snapshot.recoveryTargetFrames == 0 && queue.snapshot.hardLimitFrames == 4800
                    && queue.removeFirst()?.interleaved == frame.interleaved, "Snapshot or PCM changed")
            },
            check("PD33", "Compiler emits the prepared backend queue and disables the second rate loop") {
                let plan = try diffPlan(diffProfile())
                let yaml = CamillaDSPCompiler().compile(plan.processingGraph).yaml
                try diagnosticRequire(yaml.contains("  queuelimit: 2\n") && yaml.contains("  enable_rate_adjust: false\n")
                    && plan.deliveryConfiguration.queue.rateTargetMode == .clockTracked,
                    "Missing explicit backend or clock policy")
                let export = try AudioRuntimePlanDiagnostic(plan: plan)
                try diagnosticRequire(export.deliveryConfiguration == plan.deliveryConfiguration, "Export diverged from plan")
            },
            check("PD34", "Graph chunk size remains authoritative") {
                var profile = diffProfile(); profile.chunkSize = 512
                let plan = try diffPlan(profile)
                try diagnosticRequire(plan.processingGraph.chunkSize == 512
                    && plan.deliveryConfiguration.queue.operatingTargetFrames == 512
                    && CamillaDSPCompiler().compile(plan.processingGraph).yaml.contains("  chunksize: 512\n"), "Duplicated chunk authority")
            },
            check("PD35", "Backend queue-limit change requires configuration and engine quiescence") {
                let base = try diffPlan(diffProfile())
                let next = try candidate(base, .init(queue: base.deliveryConfiguration.queue,
                    camillaQueueLimit: base.deliveryConfiguration.camillaQueueLimit + 1))
                let delta = RuntimePlanDiffer().delta(from: base, to: next)
                try diagnosticRequire(delta.engine.queueLimitChanged && delta.graph == .replaceConfiguration
                    && delta.requirements.requiresEngineQuiescence && !delta.requirements.requiresVolumeSafeHandoff
                    && !delta.requirements.requiresFullRuntimeRestart, delta.summary)
            },
            check("PD36", "Chunk changes retain engine-quiescence classification") {
                let profile = diffProfile(); var changed = profile; changed.chunkSize = 512
                let delta = RuntimePlanDiffer().delta(from: try diffPlan(profile), to: try diffPlan(changed, generation: 2))
                try diagnosticRequire(delta.engine.chunkSizeChanged && delta.requirements.requiresEngineQuiescence
                    && !delta.requirements.requiresVolumeSafeHandoff, delta.summary)
            },
            check("PD37", "Queue-only changes are explicit and do not mutate backend or profile") {
                let base = try diffPlan(diffProfile())
                let policy = PCMQueuePolicy(sampleRate: 48_000, operatingTargetFrames: 768,
                    recoveryTargetFrames: 0, hardLimitFrames: 4800, recoveryStrategy: .clearAll)
                let next = try candidate(base, .init(queue: policy, camillaQueueLimit: base.deliveryConfiguration.camillaQueueLimit))
                let delta = RuntimePlanDiffer().delta(from: base, to: next)
                try diagnosticRequire(delta.pcmDeliveryChanged && delta.requirements.requiresPCMDeliveryUpdate
                    && !delta.requirements.usesExistingRestartPath && delta.graph == .unchanged
                    && !delta.isNoOp && next.intent == base.intent, delta.summary)
                let trim = PCMQueuePolicy(sampleRate: 48_000, operatingTargetFrames: 768,
                    recoveryTargetFrames: 512, hardLimitFrames: 4800, recoveryStrategy: .trimOldestToTarget)
                let trimPlan = try candidate(base, .init(queue: trim, camillaQueueLimit: base.deliveryConfiguration.camillaQueueLimit))
                try diagnosticRequire(RuntimePlanDiffer().delta(from: base, to: trimPlan).requirements.requiresPCMDeliveryUpdate,
                    "Recovery-only policy was not applied")
            }
        ] + pcmQueueCases() + pcmRateCases() + pcmRecoveryCases() + pcmBacklogGuardCases() + pcmBoundaryCases()
    }

    static func pcmQueueCases() -> [DiagnosticCase] {
        func check(_ id: String, _ name: String, _ body: @escaping @MainActor () throws -> Void) -> DiagnosticCase {
            .init(id: id, suite: "PCM Delivery & Rate Matching", name: name, safety: .simulated) {
                try body(); return .init(summary: name)
            }
        }
        func frame(_ count: Int, _ value: Float = 0.25, rate: Double = 48_000) -> PCMFrame {
            var f = PCMFrame(interleaved: Array(repeating: value, count: count * 2), channelCount: 2,
                sampleRate: rate)
            f.playbackModeSamples = [.direct: f.interleaved]
            return f
        }
        func same(_ a: PCMFrame?, _ b: PCMFrame?) -> Bool {
            a?.interleaved == b?.interleaved && a?.playbackModeSamples == b?.playbackModeSamples
                && a?.sampleRate == b?.sampleRate && a?.channelLayout == b?.channelLayout
        }
        return [
            check("PD03", "Queue owns FIFO blocks through wrap, growth and caller mutation") {
                var queue = LowLatencyPCMQueue()
                var original = frame(8, 0.125)
                _ = queue.append(original); original.interleaved[0] = 1
                let held = queue.removeFirst()!
                for cycle in 0..<100 {
                    for index in 0..<40 { _ = queue.append(frame(8, Float(index + cycle))) }
                    for index in 0..<40 {
                        try diagnosticRequire(queue.removeFirst()?.interleaved.first == Float(index + cycle), "FIFO changed on wrap")
                    }
                }
                try diagnosticRequire(held.interleaved.allSatisfy { $0 == 0.125 }
                    && held.playbackModeSamples[.direct]?.first == 0.125, "Emitted frame aliased reused storage")
            },
            check("PD04", "Repeated dequeue/reuse performs no retained-buffer growth copies") {
                var queue = LowLatencyPCMQueue()
                for _ in 0..<64 { _ = queue.append(frame(1)) }
                let moves = queue.growthMovedBuffers, growths = queue.slotGrowthCount
                for _ in 0..<20_000 { _ = queue.removeFirst(); _ = queue.append(frame(1)) }
                try diagnosticRequire(queue.growthMovedBuffers == moves && queue.slotGrowthCount == growths
                    && queue.bufferCount == 64 && queue.queuedFrames == 64, "Steady storage moved or lost blocks")
            },
            check("PD05", "Variable blocks retain exact frame accounting") {
                var queue = LowLatencyPCMQueue()
                for size in [256, 1024, 512] { _ = queue.append(frame(size)) }
                try diagnosticRequire(queue.queuedFrames == 1792, "Incorrect enqueue accounting")
                for remaining in [1536, 512, 0] {
                    _ = queue.removeFirst()
                    try diagnosticRequire(queue.queuedFrames == remaining && queue.snapshot.queuedFrames == remaining, "Incorrect dequeue accounting")
                }
            },
            check("PD06", "Sample-rate boundary is a typed discontinuity, including an empty old queue") {
                var queue = LowLatencyPCMQueue()
                _ = queue.append(frame(512))
                guard case .formatReset(let reset) = queue.enqueue(frame(256, rate: 96_000)) else {
                    throw DiagnosticFailure(message: "Rate boundary misclassified as overflow")
                }
                try diagnosticRequire(reset.droppedFrames == 512 && reset.queuedFramesAfter == 256 && reset.generation == 1,
                    "Rate-reset accounting incorrect")
                _ = queue.removeFirst()
                guard case .formatReset(let empty) = queue.enqueue(frame(128)) else { throw DiagnosticFailure(message: "Empty format transition missed") }
                try diagnosticRequire(empty.droppedFrames == 0 && empty.generation == 2, "Old controller continuity retained across format")
            },
            check("PD07", "6,000 fixed-seed queue mutations exactly match frozen clear-all reference") {
                var ring = LowLatencyPCMQueue(), reference = ReferencePCMQueue(), seed: UInt64 = 0xCA_11_B
                for index in 0..<6_000 {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    switch (seed >> 32) % 10 {
                    case 0:
                        try diagnosticRequire(ring.clear() == reference.clear(), "Clear mismatch")
                    case 1...3:
                        try diagnosticRequire(same(ring.removeFirst(), reference.removeFirst()), "Dequeue mismatch at \(index)")
                    default:
                        let sizes = [1, 8, 128, 256, 512, 1024, 8192]
                        let f = frame(sizes[Int(seed % UInt64(sizes.count))], Float(index % 31) / 32,
                                      rate: seed % 17 == 0 ? 96_000 : 48_000)
                        try diagnosticRequire(ring.append(f) == reference.append(f), "Recovery mismatch at \(index)")
                    }
                    try diagnosticRequire(ring.queuedFrames == reference.queuedFrames && ring.bufferCount == reference.bufferCount,
                        "Accounting mismatch at \(index)")
                }
                while !reference.isEmpty { try diagnosticRequire(same(ring.removeFirst(), reference.removeFirst()), "Final PCM mismatch") }
            },
            check("PD49", "Explicit resets retain reason, generation and drop accounting") {
                var queue = LowLatencyPCMQueue()
                _ = queue.append(frame(128))
                let calibration = queue.reset(reason: .explicitCalibrationReset)
                try diagnosticRequire(calibration.reason == .explicitCalibrationReset && calibration.droppedFrames == 128
                    && calibration.incomingFrames == 0 && calibration.queuedFramesAfter == 0
                    && queue.snapshot.lastRecovery == calibration, "Calibration reset lost provenance")
                let runtime = queue.reset(reason: .runtimeReset)
                try diagnosticRequire(runtime.reason == .runtimeReset && runtime.droppedFrames == 0
                    && runtime.generation == calibration.generation + 1, "Empty runtime reset lost generation")
            },
            check("PD50", "Writer trace identity and interval survive ring growth and wrap") {
                let now = PerformanceClock.now()
                let capture = AudioLatencyCapture(id: 1150, start: now, deadline: now.advanced(seconds: 10), capacity: 8)
                let session = UUID()
                var queue = LowLatencyPCMQueue()
                for cycle in 0..<3 {
                    for index in 0..<40 {
                        var input = frame(8)
                        let identity = AudioTraceIdentity(captureID: capture.id, runtimeSessionID: session,
                            transportGeneration: 7, streamEpoch: UInt64(cycle), deviceObjectID: 42,
                            startSampleTime: Int64(index * 8), frameCount: 8, sampleRate: 48_000, channelCount: 2)
                        input.performanceTrace = .init(capture: capture, identity: identity,
                            firstPacketReceived: now, lastPacketReceived: now, firstPacketProcessed: now,
                            lastPacketProcessed: now, becameEligible: now, emitted: now,
                            contributingPackets: 2, idleDeadline: nil, idleFlushStarted: nil)
                        _ = queue.enqueue(input)
                    }
                    for index in 0..<40 {
                        let output = queue.removeFirst()!
                        try diagnosticRequire(output.writerTrace?.capture === capture
                            && output.performanceTrace?.capture === capture
                            && output.writerTrace?.identity == output.performanceTrace?.identity
                            && output.writerTrace?.identity.startSampleTime == Int64(index * 8)
                            && output.writerTrace?.identity.streamEpoch == UInt64(cycle)
                            && output.writerTrace?.interval?.contributingPackets == 2,
                            "Trace was replaced, reordered or detached")
                    }
                }
            },
            check("PD51", "Queue storage comparison records alternating reference/ring timings") {
                guard let path = ProcessInfo.processInfo.environment["CAMITUNE_PCM_QUEUE_BENCHMARK"] else { return }
                struct Measurement: Codable {
                    let depth: Int, round: Int, mutations: Int
                    let referenceNanoseconds: UInt64, ringNanoseconds: UInt64
                }
                var measurements: [Measurement] = []
                let input = frame(1), mutations = 20_000
                for depth in [1, 16, 64, 256, 1024] {
                    for round in 0..<4 {
                        var ring = LowLatencyPCMQueue(), reference = ReferencePCMQueue()
                        for _ in 0..<depth { _ = ring.append(input); _ = reference.append(input) }
                        func measureReference() -> UInt64 {
                            let start = PerformanceClock.now()
                            for _ in 0..<mutations { _ = reference.removeFirst(); _ = reference.append(input) }
                            return PerformanceClock.duration(from: start, to: PerformanceClock.now())
                        }
                        func measureRing() -> UInt64 {
                            let start = PerformanceClock.now()
                            for _ in 0..<mutations { _ = ring.removeFirst(); _ = ring.append(input) }
                            return PerformanceClock.duration(from: start, to: PerformanceClock.now())
                        }
                        let old: UInt64, new: UInt64
                        if round.isMultiple(of: 2) { old = measureReference(); new = measureRing() }
                        else { new = measureRing(); old = measureReference() }
                        try diagnosticRequire(ring.queuedFrames == depth && reference.queuedFrames == depth
                            && same(ring.removeFirst(), reference.removeFirst()), "Timed mutations changed output")
                        measurements.append(.init(depth: depth, round: round, mutations: mutations,
                            referenceNanoseconds: old, ringNanoseconds: new))
                    }
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(measurements).write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        ]
    }
}

extension DeveloperSelfTests {
    static func pcmRateCases() -> [DiagnosticCase] {
        func check(_ id: String, _ name: String, _ body: @escaping @MainActor () throws -> Void) -> DiagnosticCase {
            .init(id: id, suite: "PCM Delivery & Rate Matching", name: name, safety: .simulated) {
                try body(); return .init(summary: name)
            }
        }
        func observation(_ buffered: Int, target: Int = 1024, frames: Int = 512,
                         rate: Double = 48_000, generation: UInt64 = 0) -> RateMatchObservation {
            .init(bufferedFrames: buffered, targetFrames: target, sampleRate: rate,
                  elapsedFrames: frames, recoveryGeneration: generation)
        }
        func pcm(_ count: Int, channels: Int, rate: Double, offset: Int) -> PCMFrame {
            .init(interleaved: (0..<(count * channels)).map { Float(sin(Double($0 + offset) * 0.117)) * 0.25 },
                  channelCount: channels, sampleRate: rate)
        }
        return [
            check("PD09", "Configured target is stable across short tails and variable blocks") {
                let policy = PCMQueuePolicy(sampleRate: 48_000, operatingTargetFrames: 1024,
                    recoveryTargetFrames: 0, hardLimitFrames: 4800, recoveryStrategy: .clearAll)
                var controller = AdaptiveRateController()
                for size in [256, 1024, 384, 1, 768] {
                    let input = observation(size, target: policy.rateTarget(writerBlockFrames: size), frames: size)
                    _ = controller.update(input)
                    try diagnosticRequire(controller.diagnosticObservation(input, targetSource: "configured").targetFrames == 1024,
                        "Current block changed target")
                }
                var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as! [String: Any]
                json.removeValue(forKey: "rateTargetMode")
                let old = try JSONDecoder().decode(PCMQueuePolicy.self, from: JSONSerialization.data(withJSONObject: json))
                try diagnosticRequire(old.rateTargetMode == .legacyBlockTarget, "Historical capture reinterpreted as fixed-target")
            },
            check("PD10", "Positive writer backlog speeds consumption") {
                var c = AdaptiveRateController()
                for _ in 0..<200 { _ = c.update(observation(2048)) }
                try diagnosticRequire(c.adjustmentPPM > 0, "Incorrect consumption direction")
            },
            check("PD11", "Negative writer backlog slows consumption") {
                var c = AdaptiveRateController()
                for _ in 0..<200 { _ = c.update(observation(512)) }
                try diagnosticRequire(c.adjustmentPPM < 0, "Incorrect consumption direction")
            },
            check("PD12", "Extreme sustained backlog stays within 500 ppm") {
                var c = AdaptiveRateController()
                for i in 0..<10_000 {
                    let ppm = c.update(observation(i < 5000 ? 1_000_000 : 0))
                    try diagnosticRequire(ppm.isFinite && abs(ppm) <= 500, "Unbounded correction")
                }
            },
            check("PD13", "Variable elapsed time preserves the existing slew limit") {
                var c = AdaptiveRateController(), prior = 0.0
                for i in 0..<1000 {
                    let size = [1, 128, 512, 1024][i % 4]
                    let ppm = c.update(observation(i % 2 == 0 ? 99_999 : 0, frames: size))
                    try diagnosticRequire(abs(ppm - prior) <= max(0.25, 240 * Double(size) / 48_000) + 1e-10,
                        "Slew limit changed")
                    prior = ppm
                }
            },
            check("PD14", "Deadband remains neutral for small target errors") {
                var c = AdaptiveRateController()
                for i in 0..<2000 { _ = c.update(observation(i % 2 == 0 ? 1010 : 1038)) }
                try diagnosticRequire(c.adjustmentPPM == 0, "Deadband changed")
            },
            check("PD15", "Burst convergence matches the inherited PI/deadband envelope") {
                var c = AdaptiveRateController(), reference = ReferenceRateController(), backlog = 1024.0
                var lateMaximumError = 0.0, lateMaximumPPM = 0.0
                for i in 0..<100_000 {
                    if i == 1000 { backlog += 512 }
                    let observed = Int(backlog.rounded())
                    let ppm = c.update(observation(observed))
                    let old = reference.update(bufferedFrames: observed, sourceCapacityFrames: 4096,
                        sampleRate: 48_000, elapsedFrames: 512)
                    try diagnosticRequire(ppm == old, "Burst response diverged from reference PI")
                    backlog -= 512 * ppm / 1_000_000
                    if i >= 90_000 {
                        lateMaximumError = max(lateMaximumError, abs(backlog - 1024))
                        lateMaximumPPM = max(lateMaximumPPM, abs(ppm))
                    }
                }
                // The inherited 2% deadband yields a small residual cycle; exact
                // zero would require changing PI policy, not its input API.
                try diagnosticRequire(lateMaximumError < 30 && lateMaximumPPM < 8,
                    "Burst envelope: error \(lateMaximumError), ppm \(lateMaximumPPM)")
            },
            check("PD16", "Recovery generation resets PI state once") {
                var c = AdaptiveRateController(), fresh = AdaptiveRateController()
                for _ in 0..<2000 { _ = c.update(observation(4096)) }
                let reset = observation(1024, generation: 1)
                try diagnosticRequire(c.update(reset) == fresh.update(reset), "Recovery retained old controller state")
                let next = observation(2048, generation: 1)
                try diagnosticRequire(c.update(next) == fresh.update(next), "Generation reset repeated or differed")
                var changedRate = AdaptiveRateController()
                let changed = observation(2048, target: 2048, frames: 1024, rate: 96_000, generation: 1)
                try diagnosticRequire(c.update(changed) == changedRate.update(changed), "Rate boundary retained PI state")
            },
            check("PD17", "Controller equals frozen PI reference when given the same target") {
                var c = AdaptiveRateController(), reference = ReferenceRateController()
                for i in 0..<5000 {
                    let size = [128, 512, 1024, 384][i % 4], buffered = (i * 37) % 4096
                    let a = c.update(observation(buffered, frames: size))
                    let b = reference.update(bufferedFrames: buffered, sourceCapacityFrames: 4096,
                                             sampleRate: 48_000, elapsedFrames: size)
                    try diagnosticRequire(a == b, "PI gains or arithmetic changed at \(i)")
                }
            },
            check("PD18", "Rate input excludes transport/mixer metadata and scales with sample time") {
                var a = AdaptiveRateController(), b = AdaptiveRateController()
                for i in 0..<1000 {
                    let buffered = 512 + i % 2000
                    let x = a.update(observation(buffered))
                    let y = b.update(observation(buffered * 2, target: 2048, frames: 1024, rate: 96_000))
                    try diagnosticRequire(x == y, "Equivalent queue duration changed controller meaning")
                }
                // RateMatchObservation has only writer backlog, policy target,
                // format/time and writer recovery generation. Source-ring and
                // mixer holdback metadata cannot enter this API.
            },
            check("PD19", "Head-based cubic history exactly matches frozen PCM across layouts and PPM") {
                for channels in [1, 2, 6, 8] {
                    var ring = AdaptivePCMResampler(), reference = ReferencePCMResampler()
                    for i in 0..<700 {
                        let input = pcm([1, 2, 128, 512, 1024, 384][i % 6], channels: channels,
                                        rate: 48_000, offset: i * 17)
                        let ppm = [0.0, -500, 500, -127.25, 213.5][i % 5]
                        let a = ring.process(input, adjustmentPPM: ppm), b = reference.process(input, adjustmentPPM: ppm)
                        try diagnosticRequire(a.interleaved == b.interleaved && a.frameCount == b.frameCount
                            && a.channelLayout == b.channelLayout, "Cubic PCM mismatch: \(channels) channels, block \(i)")
                    }
                }
            },
            check("PD60", "Synthetic 16/32-channel cubic history preserves every output sample") {
                for channels in [16, 32] {
                    var candidate = AdaptivePCMResampler(), reference = ReferencePCMResampler()
                    for i in 0..<120 {
                        let input = pcm([1, 128, 512, 1024][i % 4], channels: channels,
                                        rate: 48_000, offset: i * 31)
                        let ppm = [0.0, -500, 500][i % 3]
                        try diagnosticRequire(candidate.process(input, adjustmentPPM: ppm).interleaved
                            == reference.process(input, adjustmentPPM: ppm).interleaved,
                            "High-channel cubic mismatch: \(channels), block \(i)")
                    }
                }
            },
            check("PD20", "Long resampling reuses bounded history without front shifting") {
                var r = AdaptivePCMResampler()
                let input = pcm(512, channels: 8, rate: 48_000, offset: 0)
                for _ in 0..<10 { _ = r.process(input, adjustmentPPM: -500) }
                let growths = r.historyGrowths, capacity = r.historyCapacity
                #if DEBUG
                let iterations = 2000 // Stay within the interactive diagnostic's 15-second deadline.
                #else
                let iterations = 10_000
                #endif
                for i in 0..<iterations {
                    _ = r.process(input, adjustmentPPM: i % 2 == 0 ? -500 : 500)
                    try diagnosticRequire(r.retainedSampleCount <= 4 * 8, "History grew with run length")
                }
                try diagnosticRequire(r.historyGrowths == growths && r.historyCapacity == capacity && r.historyRebases < iterations / 2,
                    "Steady resampling reallocated history")
            },
            check("PD21", "Reset prevents old interpolation samples reaching a new stream") {
                var used = AdaptivePCMResampler(), fresh = AdaptivePCMResampler()
                _ = used.process(pcm(1024, channels: 2, rate: 48_000, offset: 30), adjustmentPPM: 500)
                used.reset()
                let input = pcm(128, channels: 2, rate: 48_000, offset: 0)
                try diagnosticRequire(used.process(input, adjustmentPPM: 0).interleaved
                    == fresh.process(input, adjustmentPPM: 0).interleaved, "Old history leaked after reset")
            },
            check("PD22", "Rate and channel format boundaries preserve reference reset behavior") {
                var r = AdaptivePCMResampler(), old = ReferencePCMResampler()
                for i in 0..<60 {
                    let input = pcm(128, channels: [2, 8, 6, 1][i % 4], rate: i % 2 == 0 ? 48_000 : 96_000, offset: i)
                    try diagnosticRequire(r.process(input, adjustmentPPM: 123).interleaved
                        == old.process(input, adjustmentPPM: 123).interleaved, "Format boundary differed")
                }
            },
            check("PD52", "Both clock drift directions converge with unchanged PI gains") {
                struct Result: Codable { let sourceDriftPPM: Double, finalBacklog: Double, finalPPM: Double, recoveries: Int }
                var results: [Result] = []
                for drift in [-200.0, -50, 0, 50, 200] {
                    var controller = AdaptiveRateController(), backlog = 1024.0, recoveries = 0
                    for _ in 0..<100_000 {
                        let ppm = controller.update(observation(Int(backlog.rounded())))
                        backlog += 512 * (drift - ppm) / 1_000_000
                        if backlog < 0 || backlog > 4800 { recoveries += 1; break }
                    }
                    results.append(.init(sourceDriftPPM: drift, finalBacklog: backlog,
                        finalPPM: controller.adjustmentPPM, recoveries: recoveries))
                    try diagnosticRequire(recoveries == 0 && abs(backlog - 1024) < 35
                        && abs(controller.adjustmentPPM - drift) < 8, "Drift \(drift) failed: \(backlog), \(controller.adjustmentPPM)")
                }
                if let path = ProcessInfo.processInfo.environment["CAMITUNE_PCM_DRIFT_RESULTS"] {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(results).write(to: URL(fileURLWithPath: path), options: .atomic)
                }
            },
            check("PD55", "Optional alternating resampler storage benchmark") {
                guard let path = ProcessInfo.processInfo.environment["CAMITUNE_PCM_RESAMPLER_BENCHMARK"] else { return }
                struct Row: Codable {
                    let channels: Int, blockFrames: Int, round: Int, blocks: Int
                    let referenceNanoseconds: UInt64, candidateNanoseconds: UInt64
                }
                var rows: [Row] = []
                for channels in [2, 8, 16, 32] {
                    for size in [128, 512, 1024] {
                        let input = pcm(size, channels: channels, rate: 48_000, offset: 0)
                        for round in 0..<4 {
                            var old = ReferencePCMResampler(), new = AdaptivePCMResampler()
                            for _ in 0..<10 { _ = old.process(input, adjustmentPPM: 127); _ = new.process(input, adjustmentPPM: 127) }
                            var oldSum: Float = 0, newSum: Float = 0
                            func reference() -> UInt64 {
                                let start = PerformanceClock.now()
                                for _ in 0..<256 {
                                    let output = old.process(input, adjustmentPPM: 127)
                                    oldSum += output.interleaved.first! + output.interleaved.last!
                                }
                                return PerformanceClock.duration(from: start, to: PerformanceClock.now())
                            }
                            func candidate() -> UInt64 {
                                let start = PerformanceClock.now()
                                for _ in 0..<256 {
                                    let output = new.process(input, adjustmentPPM: 127)
                                    newSum += output.interleaved.first! + output.interleaved.last!
                                }
                                return PerformanceClock.duration(from: start, to: PerformanceClock.now())
                            }
                            let a: UInt64, b: UInt64
                            if round.isMultiple(of: 2) { a = reference(); b = candidate() } else { b = candidate(); a = reference() }
                            try diagnosticRequire(oldSum == newSum, "Timed resamplers changed PCM")
                            rows.append(.init(channels: channels, blockFrames: size, round: round, blocks: 256,
                                referenceNanoseconds: a, candidateNanoseconds: b))
                        }
                    }
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(rows).write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        ]
    }
}

extension DeveloperSelfTests {
    static func pcmRecoveryCases() -> [DiagnosticCase] {
        func check(_ id: String, _ name: String, _ body: @escaping @MainActor () throws -> Void) -> DiagnosticCase {
            .init(id: id, suite: "PCM Delivery & Rate Matching", name: name, safety: .simulated) {
                try body(); return .init(summary: name)
            }
        }
        func policy(_ strategy: PCMQueueRecoveryStrategy = .trimOldestToTarget) -> PCMQueuePolicy {
            .init(sampleRate: 48_000, operatingTargetFrames: 32, recoveryTargetFrames: 32,
                  hardLimitFrames: 64, recoveryStrategy: strategy)
        }
        func frame(_ value: Float, count: Int = 16, rate: Double = 48_000) -> PCMFrame {
            var frame = PCMFrame(interleaved: Array(repeating: value, count: count * 2), channelCount: 2, sampleRate: rate)
            frame.playbackModeSamples = [.direct: frame.interleaved]
            return frame
        }
        return [
            check("PD23", "Trim recovery preserves the newest whole blocks") {
                var queue = LowLatencyPCMQueue(); queue.configure(policy())
                for value in 1...4 { _ = queue.enqueue(frame(Float(value))) }
                guard case .overflowRecovery(let recovery) = queue.enqueue(frame(5)) else { throw DiagnosticFailure(message: "No overflow") }
                try diagnosticRequire(recovery.droppedFrames == 48 && recovery.retainedFrames == 16
                    && queue.removeFirst()?.interleaved.first == 4 && queue.removeFirst()?.interleaved.first == 5
                    && queue.isEmpty, "Trim discarded recent PCM or sliced/reordered a block")
            },
            check("PD24", "Whole-block recovery bounds variable incoming frames") {
                for size in [1, 7, 16, 31, 32, 40, 64, 128] {
                    var queue = LowLatencyPCMQueue(); queue.configure(policy())
                    for value in 1...4 { _ = queue.enqueue(frame(Float(value))) }
                    let result = queue.enqueue(frame(5, count: size))
                    try diagnosticRequire(result.recovery != nil && queue.queuedFrames <= max(32, size)
                        && queue.queuedFrames >= size, "Recovery target bound failed at \(size)")
                }
            },
            check("PD25", "Retained mode buses and FIFO order survive repeated wrap/recovery") {
                var queue = LowLatencyPCMQueue(); queue.configure(policy())
                var last = Float(-1)
                for i in 0..<1000 {
                    _ = queue.enqueue(frame(Float(i), count: 1))
                    if i % 7 == 0, let next = queue.removeFirst() {
                        try diagnosticRequire(next.interleaved[0] > last && next.playbackModeSamples[.direct] == next.interleaved,
                            "Recovery corrupted order or bus ownership")
                        last = next.interleaved[0]
                    }
                }
                while let next = queue.removeFirst() {
                    try diagnosticRequire(next.interleaved[0] > last, "Retained tail reordered"); last = next.interleaved[0]
                }
            },
            check("PD26", "Oversized input replaces old backlog and restores the nominal bound afterward") {
                var queue = LowLatencyPCMQueue(); queue.configure(policy())
                _ = queue.enqueue(frame(1))
                let big = queue.enqueue(frame(2, count: 128)).recovery
                try diagnosticRequire(big?.droppedFrames == 16 && queue.queuedFrames == 128
                    && queue.snapshot.hardLimitFrames == 128, "Oversized block was split or rejected")
                let next = queue.enqueue(frame(3, count: 8)).recovery
                try diagnosticRequire(next?.droppedFrames == 128 && queue.queuedFrames == 8
                    && queue.snapshot.hardLimitFrames == 64, "Oversized allowance became standing capacity")
            },
            check("PD27", "Every recovery advances writer generation once") {
                var queue = LowLatencyPCMQueue(); queue.configure(policy())
                for _ in 0..<5 { _ = queue.enqueue(frame(1)) }
                try diagnosticRequire(queue.recoveryGeneration == 1, "Overflow generation wrong")
                _ = queue.reset(reason: .explicitCalibrationReset)
                try diagnosticRequire(queue.recoveryGeneration == 2, "Calibration generation wrong")
                _ = queue.enqueue(frame(2, rate: 96_000))
                try diagnosticRequire(queue.recoveryGeneration == 3 && queue.snapshot.lastRecovery?.reason == .sampleRateChange,
                    "Format generation wrong")
            },
            check("PD32", "Typed trim telemetry records exact accounting without counting discards as delivery") {
                var queue = LowLatencyPCMQueue(); queue.configure(policy())
                for value in 1...4 { _ = queue.enqueue(frame(Float(value))) }
                guard let r = queue.enqueue(frame(5)).recovery else { throw DiagnosticFailure(message: "No recovery") }
                try diagnosticRequire(r.reason == .overflow && r.generation == 1 && r.queuedFramesBefore == 64
                    && r.incomingFrames == 16 && r.droppedFrames == 48 && r.retainedFrames == 16
                    && r.queuedFramesAfter == 32 && r.operatingTargetFrames == 32 && r.recoveryTargetFrames == 32
                    && r.hardLimitFrames == 64 && r.sampleRate == 48_000 && r.timestamp.rawValue > 0
                    && queue.snapshot.latestBlockFrames == 0, "Recovery telemetry does not describe the mutation")
            }
        ] + pcmWriterRecoveryCases()
    }
}

/// Blocks only the isolated fixture writer. MainActor remains free to enqueue
/// enough owned frames for a deterministic overflow; no scheduler race is needed.
private final class PCMWriterFixtureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enteredValue = false
    private var timeoutValue = false
    private let semaphore = DispatchSemaphore(value: 0)
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return enteredValue }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timeoutValue }
    func waitOnce() {
        lock.lock()
        if enteredValue { lock.unlock(); return }
        enteredValue = true; lock.unlock()
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            lock.lock(); timeoutValue = true; lock.unlock()
        }
    }
    func release() { semaphore.signal() }
}

extension DeveloperSelfTests {
    private struct PCMWriterRecoveryResult {
        let samples: [Float]
        let statistics: PCMRouter.Statistics
        let writes: [AudioLatencySample]
        let recovery: PCMQueueRecovery
    }

    @MainActor
    private static func runPCMWriterRecovery(strategy: PCMQueueRecoveryStrategy,
        gain: Float = 0.25, muted: Bool = false, ramp: Bool = false,
        signal: String = "constant") async throws -> PCMWriterRecoveryResult {
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        let path = box.directory.appendingPathComponent("recovery.pcm")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let file = try FileHandle(forWritingTo: path); defer { try? file.close() }
        let router = PCMRouter(), gate = PCMWriterFixtureGate()
        router.setSystemMaster(linearGain: gain, muted: muted)
        let now = PerformanceClock.now()
        let capture = AudioLatencyCapture(id: 1128, start: now, deadline: now.advanced(seconds: 20), capacity: 100)
        router.performanceSource.setSession(UUID()); router.performanceSource.setCapture(capture)
        let configuration = PCMDeliveryConfiguration(queue: .init(sampleRate: 48_000, operatingTargetFrames: 32,
            recoveryTargetFrames: strategy == .clearAll ? 0 : 32, hardLimitFrames: 64, recoveryStrategy: strategy), camillaQueueLimit: 4)
        await router.startFixture(camillaSink: file, deliveryConfiguration: configuration, configurationObserver: { _ in gate.waitOnce() })
        var sourceFrame = 0
        func frame() -> PCMFrame {
            defer { sourceFrame += 16 }
            let samples = (0..<32).map { index -> Float in
                let position = sourceFrame + index / 2
                if signal == "impulse" { return position == 64 ? 1 : 0 }
                if let frequency = Double(signal) { return Float(sin(2 * .pi * frequency * Double(position) / 48_000)) }
                return 1
            }
            return PCMFrame(interleaved: samples, channelCount: 2, sampleRate: 48_000)
        }
        do {
            router.route(frame())
            let deadline = PerformanceClock.now().advanced(seconds: 5)
            while !gate.entered && PerformanceClock.now() < deadline { try await Task.sleep(for: .milliseconds(1)) }
            try diagnosticRequire(gate.entered, "Fixture writer did not reach the gate")
            if ramp { router.setSystemMaster(linearGain: 0.75, muted: false) }
            for _ in 0..<5 { router.route(frame()) }
            guard let recovery = router.statistics.camillaQueue.lastRecovery else { throw DiagnosticFailure(message: "Fixture did not overflow") }
            let expectedWrites = strategy == .clearAll ? 2 : 3
            gate.release()
            while capture.counts().audio < expectedWrites && PerformanceClock.now() < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            try diagnosticRequire(!gate.timedOut && capture.counts().audio == expectedWrites, "Recovery writer failed to drain")
            let statistics = router.statistics
            router.stop()
            let writes = capture.events().compactMap { event -> AudioLatencySample? in
                if case .audio(let value) = event { return value }; return nil
            }
            let bytes = try Data(contentsOf: path)
            let samples = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            try diagnosticRequire(!samples.isEmpty && capture.telemetryDrops == 0, "Missing fixture PCM or trace events")
            return .init(samples: samples, statistics: statistics, writes: writes, recovery: recovery)
        } catch {
            gate.release(); router.stop(); throw error
        }
    }

    static func pcmWriterRecoveryCases() -> [DiagnosticCase] {
        func check(_ id: String, _ name: String,
                   _ body: @escaping @MainActor () async throws -> Void) -> DiagnosticCase {
            .init(id: id, suite: "PCM Delivery & Rate Matching", name: name, safety: .simulated) {
                try await body(); return .init(summary: name)
            }
        }
        return [
            check("PD28", "Actual writer resets interpolation and PI across a queued discontinuity") {
                let r = try await runPCMWriterRecovery(strategy: .trimOldestToTarget)
                try diagnosticRequire(r.writes.count == 3 && r.writes[0].blockFrames == r.writes[1].blockFrames
                    && r.writes[1].blockFrames < r.writes[2].blockFrames,
                    "Writer did not restart cubic history after the skipped interval")
                try diagnosticRequire(r.recovery.generation == 1 && r.writes.allSatisfy { abs($0.rateMatch?.adjustmentPPM ?? 999) < 1 },
                    "Recovery retained a large rate-controller error")
            },
            check("PD29", "Actual overflow preserves system master gain") {
                for strategy in [PCMQueueRecoveryStrategy.clearAll, .trimOldestToTarget] {
                    let r = try await runPCMWriterRecovery(strategy: strategy)
                    try diagnosticRequire(r.samples.allSatisfy { abs($0 - 0.25) < 1e-6 }, "Recovery changed master gain")
                }
            },
            check("PD30", "Actual overflow preserves user mute") {
                let r = try await runPCMWriterRecovery(strategy: .trimOldestToTarget, muted: true)
                try diagnosticRequire(r.samples.allSatisfy { $0 == 0 }, "Queue recovery unmuted PCM")
            },
            check("PD31", "Overflow remains local and writes continue through the same sink") {
                let r = try await runPCMWriterRecovery(strategy: .trimOldestToTarget)
                try diagnosticRequire(r.statistics.camillaQueueRecoveries == 1 && r.statistics.camillaDroppedFrames == 48
                    && r.statistics.camillaWriteFailures == 0 && r.writes.count == 3,
                    "Local overflow escalated to failure or lost surviving blocks")
            },
            check("PD53", "Master ramp continues through recovery without a gain reset") {
                let r = try await runPCMWriterRecovery(strategy: .trimOldestToTarget, gain: 0.25, ramp: true)
                let left = stride(from: 0, to: r.samples.count, by: 2).map { r.samples[$0] }
                try diagnosticRequire(left.first! >= 0.25 && left.last! < 0.75, "Short ramp started at wrong gain or jumped to target")
                for i in 1..<left.count {
                    try diagnosticRequire(left[i] >= left[i - 1] && left[i] - left[i - 1] < 0.002,
                        "Master ramp jumped or restarted at discontinuity")
                }
            },
            check("PD54", "Recovery waveform comparison records both policies without assuming trim is quieter") {
                struct Evidence: Codable {
                    let signal: String, strategy: String
                    let droppedFrames: Int, retainedFrames: Int
                    let boundaryJump: Float, peak: Float
                    let samples: [Float]
                }
                var evidence: [Evidence] = []
                for signal in ["37", "997", "8000", "impulse"] {
                    for strategy in [PCMQueueRecoveryStrategy.clearAll, .trimOldestToTarget] {
                        let r = try await runPCMWriterRecovery(strategy: strategy, signal: signal)
                        let boundary = r.writes[0].blockFrames * 2
                        let jump = abs(r.samples[boundary] - r.samples[boundary - 2])
                        let peak = r.samples.map { abs($0) }.max() ?? 0
                        try diagnosticRequire(r.samples.allSatisfy(\.isFinite) && peak <= 0.251,
                            "Recovery amplified the bounded fixture")
                        evidence.append(.init(signal: signal, strategy: strategy.rawValue,
                            droppedFrames: r.recovery.droppedFrames, retainedFrames: r.recovery.retainedFrames,
                            boundaryJump: jump, peak: peak, samples: r.samples))
                    }
                }
                if let path = ProcessInfo.processInfo.environment["CAMITUNE_PCM_RECOVERY_ARTIFACTS"] {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(evidence).write(to: URL(fileURLWithPath: path), options: .atomic)
                }
            }
        ]
    }
}

extension DeveloperSelfTests {
    static func pcmBacklogGuardCases() -> [DiagnosticCase] {
        func check(_ id: String, _ name: String, _ body: @escaping @MainActor () throws -> Void) -> DiagnosticCase {
            .init(id: id, suite: "PCM Delivery & Rate Matching", name: name, safety: .simulated) {
                try body(); return .init(summary: name)
            }
        }
        func input(_ buffered: Int, target: Int = 512, frames: Int = 128, guarded: Bool = true) -> RateMatchObservation {
            .init(bufferedFrames: buffered, targetFrames: target, sampleRate: 48_000, elapsedFrames: frames,
                  recoveryGeneration: 0, requiresStandingBacklog: guarded)
        }
        return [
            check("PD56", "Empty writer queue does not turn packet-size changes into clock correction") {
                var guarded = AdaptiveRateController(), unguarded = AdaptiveRateController()
                for i in 0..<20_000 {
                    let size = [128, 256, 512, 384][i % 4]
                    try diagnosticRequire(guarded.update(input(size, frames: size)) == 0, "Packetization drove guarded PI")
                    _ = unguarded.update(input(size, frames: size, guarded: false))
                }
                try diagnosticRequire(unguarded.adjustmentPPM < -300, "Fixture failed to reproduce the measured windup")
                let evidence = guarded.diagnosticObservation(input(128), targetSource: "configuredWhenQueued")
                try diagnosticRequire(evidence.controlState == "emptyWriterQueue" && evidence.bufferedFrames == 128
                    && evidence.targetFrames == 512, "Guard hid raw occupancy or active policy")
            },
            check("PD57", "Empty-queue guard releases stale integral while respecting output slew") {
                var c = AdaptiveRateController()
                for _ in 0..<20_000 { _ = c.update(input(768, target: 1024)) }
                try diagnosticRequire(c.adjustmentPPM < -300, "Fixture failed to build integral")
                var previous = c.adjustmentPPM
                for _ in 0..<1000 {
                    let value = c.update(input(128, target: 1024))
                    try diagnosticRequire(abs(value - previous) <= 0.640000001, "Guard jumped correction")
                    previous = value
                }
                try diagnosticRequire(c.adjustmentPPM == 0, "Guard retained stale correction")
            },
            check("PD58", "Guard preserves both drift responses while a measurable writer reservoir exists") {
                for drift in [-200.0, 0, 200] {
                    var guarded = AdaptiveRateController(), reference = AdaptiveRateController(), backlog = 1024.0
                    for _ in 0..<100_000 {
                        let observed = Int(backlog.rounded())
                        let a = guarded.update(input(observed, target: 1024, frames: 512))
                        let b = reference.update(input(observed, target: 1024, frames: 512, guarded: false))
                        try diagnosticRequire(a == b && observed > 512, "Guard changed reservoir feedback")
                        backlog += 512 * (drift - a) / 1_000_000
                    }
                    try diagnosticRequire(abs(guarded.adjustmentPPM - drift) < 8 && abs(backlog - 1024) < 35,
                        "Guarded drift failed to settle")
                }
            },
            check("PD59", "Guard still corrects negative and positive errors with queued PCM") {
                var negative = AdaptiveRateController(), positive = AdaptiveRateController()
                for _ in 0..<2000 {
                    _ = negative.update(input(768, target: 1024))
                    _ = positive.update(input(2048, target: 1024))
                }
                try diagnosticRequire(negative.adjustmentPPM < 0 && positive.adjustmentPPM > 0,
                    "Guard suppressed measurable queue error")
            },
            check("PD62", "Empty-writer downstream drift counterexample remains observable") {
                // Characterization, not a passing clock-stability qualification.
                // Both output clocks present the same empty writer queue. Feed
                // the real resampler output into two independent downstream
                // reservoirs; do not clamp either reservoir back to its target.
                var fastController = AdaptiveRateController(), slowController = AdaptiveRateController()
                var resampler = AdaptivePCMResampler()
                let frame = PCMFrame(interleaved: [Float](repeating: 0, count: 512),
                    channelCount: 1, sampleRate: 48_000)
                _ = resampler.process(frame, adjustmentPPM: 0) // Prime cubic history before the observation.
                var fastReservoir = 1024.0, slowReservoir = 1024.0
                var firstStarvationSeconds: Double?
                let blocks = 11_250 // 120 seconds at 512 / 48 kHz, without sleeping.
                for block in 0..<blocks {
                    let observation = input(512, target: 512, frames: 512)
                    let fastPPM = fastController.update(observation)
                    let slowPPM = slowController.update(observation)
                    try diagnosticRequire(fastPPM == 0 && slowPPM == fastPPM,
                        "Identical empty-queue observations unexpectedly distinguished physical clocks")
                    let delivered = resampler.process(frame, adjustmentPPM: fastPPM).frameCount
                    fastReservoir += Double(delivered) - 512 * (1 + 200.0 / 1_000_000)
                    slowReservoir += Double(delivered) - 512 * (1 - 200.0 / 1_000_000)
                    if fastReservoir <= 0 && firstStarvationSeconds == nil {
                        firstStarvationSeconds = Double(block + 1) * 512 / 48_000
                    }
                }
                try diagnosticRequire(firstStarvationSeconds.map { (106.6...106.8).contains($0) } == true,
                    "Fixture did not reproduce approximately 107-second starvation")
                try diagnosticRequire(abs(fastReservoir - (-128)) < 0.001 && abs(slowReservoir - 2176) < 0.001,
                    "Output accounting hid the downstream deficit or accumulating surplus")
            }
        ]
    }
}

private final class PCMCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var completed: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func complete() { lock.lock(); value = true; lock.unlock() }
}

extension DeveloperSelfTests {
    static func pcmBoundaryCases() -> [DiagnosticCase] {
        func check(_ id: String, _ name: String,
                   _ body: @escaping @MainActor () async throws -> Void) -> DiagnosticCase {
            .init(id: id, suite: "PCM Delivery & Rate Matching", name: name, safety: .simulated) {
                try await body(); return .init(summary: name)
            }
        }
        return [
            check("PD45", "Real writer master ramp stays eight milliseconds across 256/512/1024-frame blocks") {
                for size in [256, 512, 1024] {
                    let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                    let path = box.directory.appendingPathComponent("ramp.pcm")
                    FileManager.default.createFile(atPath: path.path, contents: nil)
                    let file = try FileHandle(forWritingTo: path); defer { try? file.close() }
                    let router = PCMRouter(); router.setSystemMaster(linearGain: 0.25, muted: false)
                    let now = PerformanceClock.now()
                    let capture = AudioLatencyCapture(id: UInt64(size), start: now, deadline: now.advanced(seconds: 5), capacity: 100)
                    router.performanceSource.setSession(UUID()); router.performanceSource.setCapture(capture)
                    let config = PCMDeliveryConfiguration(queue: .init(sampleRate: 48_000,
                        operatingTargetFrames: size, recoveryTargetFrames: 0, hardLimitFrames: 4800,
                        recoveryStrategy: .clearAll, rateTargetMode: .configuredWhenQueued), camillaQueueLimit: 4)
                    await router.startFixture(camillaSink: file, deliveryConfiguration: config)
                    do {
                        for block in 0..<4 {
                            if block == 1 { router.setSystemMaster(linearGain: 0.75, muted: false) }
                            router.route(.init(interleaved: [Float](repeating: 1, count: size * 2), channelCount: 2, sampleRate: 48_000))
                            while capture.counts().audio < block + 1 && PerformanceClock.now() < capture.deadline {
                                try await Task.sleep(for: .milliseconds(1))
                            }
                            try diagnosticRequire(capture.counts().audio == block + 1, "Ramp fixture failed to drain")
                        }
                        router.stop()
                        let writes = capture.events().compactMap { event -> AudioLatencySample? in
                            if case .audio(let value) = event { return value }; return nil
                        }
                        let bytes = try Data(contentsOf: path)
                        let samples = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                        let start = writes[0].blockFrames * 2
                        for frame in 0..<384 {
                            let expected = min(Float(0.75), 0.25 + Float(frame + 1) * (0.5 / 384))
                            try diagnosticRequire(abs(samples[start + frame * 2] - expected) < 0.00001
                                && samples[start + frame * 2] == samples[start + frame * 2 + 1], "Ramp duration/channel mismatch at block size \(size)")
                        }
                        try diagnosticRequire(samples[start + 384 * 2] == 0.75
                            && router.statistics.camillaWriteFailures == 0 && capture.telemetryDrops == 0,
                            "Ramp did not finish at eight milliseconds")
                    } catch { router.stop(); throw error }
                }
            },
            check("PD46", "Calibration bypass preserves exact PCM length, gain and reset classification") {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                let path = box.directory.appendingPathComponent("calibration.pcm")
                FileManager.default.createFile(atPath: path.path, contents: nil)
                let file = try FileHandle(forWritingTo: path); defer { try? file.close() }
                let router = PCMRouter(), completed = PCMCompletionFlag(), id = UUID()
                router.setSystemMaster(linearGain: 0.25, muted: false)
                await router.startFixture(camillaSink: file)
                do {
                    let input = (0..<(1027 * 2)).map { Float(($0 % 17) - 8) * 0.002 }
                    let clip = SpatialCalibrationClip(measurementSamples: input, sampleRate: 48_000)!
                    try diagnosticRequire(router.beginSpatialCalibration(id: id)
                        && router.playSpatialCalibration(id: id, clip: clip, completion: { completed.complete() }),
                        "Calibration fixture was rejected")
                    let deadline = PerformanceClock.now().advanced(seconds: 5)
                    while !completed.completed && PerformanceClock.now() < deadline { try await Task.sleep(for: .milliseconds(1)) }
                    try diagnosticRequire(completed.completed, "Calibration writer did not complete")
                    let stats = router.statistics
                    router.endSpatialCalibration(id: id); router.stop()
                    let bytes = try Data(contentsOf: path)
                    let samples = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                    try diagnosticRequire(samples == input.map { $0 * 0.25 }
                        && stats.rateAdjustmentPPM == 0 && stats.camillaQueueRecoveries == 0
                        && stats.camillaQueue.lastRecovery?.reason == .explicitCalibrationReset,
                        "Calibration was resampled, changed gain or counted as overflow")
                } catch { router.stop(); throw error }
            },
            check("PD61", "Candidate survives settings save and telemetry describes the applied profile") {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                var candidate = DiagnosticSandbox.profile()
                candidate.chunkSize = 512
                candidate.processing.global.stages.append(.init(processor: .equalizer(.init(bands: [
                    .init(kind: .peaking, frequency: 1000, gain: -1, q: 1)
                ]))))
                candidate = try AudioRuntimePlanPreparer.normalize(candidate)
                box.profiles.profiles = [candidate]
                let fake = DiagnosticRuntimeFakes()
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                do {
                    await state.activate(profile: candidate)
                    try await state.saveProfileSettings(.init(profile: candidate,
                        activation: box.profiles.activationMode(for: candidate)))
                    try diagnosticRequire(state.runtimeCoordinator.appliedProfile == candidate,
                        "Settings save replaced the isolated candidate")
                    // Repository edits can precede reconciliation. Capture must
                    // continue describing the acknowledged runtime in that gap.
                    var pending = candidate; pending.chunkSize = 2048
                    pending.processing.global.stages.append(.init(processor: .gain(.init(gainDB: -3))))
                    box.profiles.profiles = [pending]
                    let observed = state.performanceEnvironment()
                    try diagnosticRequire(observed.chunkSize == 512
                        && observed.processingStages == candidate.processing.global.stages.count
                            + candidate.processing.channels.reduce(0) { $0 + $1.chain.stages.count },
                        "Capture reported saved intent instead of applied configuration")
                    await state.deactivate()
                } catch { await state.deactivate(); throw error }
            }
        ]
    }
}
