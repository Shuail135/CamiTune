import CamiTuneAudio
import CamiTuneDomain
import Foundation

extension PerformanceTick {
    /// Legacy fixture adapter only: production eligibility never converts Date.
    static func fixtureDate(_ date: Date) -> Self { .init(rawValue: UInt64(max(0, date.timeIntervalSince1970) * 1_000_000_000)) }
}

/// No application registry, hardware or persistence is involved in direct mixer tests.
final class TimelineMixerFixture {
    let mixer = PerAppTimelineMixer(storagePolicy: .init(maximumPacketFrames: 65_536), policyConfiguration: .init(mode: .legacy))
    func ingest(_ packet: PerAppAudioPacket, now: Date, mode: PlaybackMode = .direct) -> PCMFrame? {
        let preparation = mixer.preparePacket(.init(deviceObjectID: packet.deviceObjectID, cycleCounter: packet.cycleCounter, startSampleTime: Int64(packet.sampleTime),
            frameCount: packet.interleaved.count / packet.channelCount, channelCount: packet.channelCount,
            sampleRate: packet.sampleRate, channelLayout: packet.channelLayout, playbackMode: mode))
        return packet.interleaved.withUnsafeBufferPointer { mixer.mixProcessedPacket(preparation, samples: $0, policyNow: .fixtureDate(now)) }
    }
    func flushExpiredMix(now: Date) -> PerAppMixFlushResult { mixer.flushExpired(policyNow: .fixtureDate(now)) }
    func resetRuntime() { mixer.reset() }
}

extension DeveloperSelfTests {
    static func timelineStorageCases() -> [DiagnosticCase] {
        [DiagnosticCase(id: "M00", suite: "Timeline Mixer", name: "Circular storage independent differential", safety: .simulated) {
            let ring = try TimelineCircularStorage(channelCount: 2, maximumFrames: 2048)
            try ring.reserve(16)
            var combined: [Float] = []; var modes: [PlaybackMode: [Float]] = [:]
            var seed: UInt64 = 9031
            for i in 0..<2000 {
                seed = seed &* 6364136223846793005 &+ 1
                let prefix = i % 11 == 0 ? Int(seed % 4) : 0
                let count = 1 + Int(seed % 13)
                let mode = PlaybackMode.allCases[i % PlaybackMode.allCases.count]
                let offset = Int(seed % UInt64(max(1, combined.count / 2 + prefix)))
                let required = max(combined.count / 2 + prefix, offset + count)
                try ring.reserve(required)
                ring.prepend(prefix)
                combined = Array(repeating: 0, count: prefix * 2) + combined
                for key in Array(modes.keys) { modes[key] = Array(repeating: 0, count: prefix * 2) + modes[key]! }
                ring.extend(to: required)
                combined += Array(repeating: 0, count: required * 2 - combined.count)
                for key in Set(modes.keys).union([mode]) {
                    modes[key, default: []] += Array(repeating: 0, count: required * 2 - (modes[key]?.count ?? 0))
                }
                let input = (0..<(count * 2)).map { Float(($0 + i) % 17) / 32 }
                input.withUnsafeBufferPointer { ring.add($0, sourceFrameOffset: 0, frameCount: count, at: offset, mode: mode) }
                for n in input.indices { combined[offset * 2 + n] += input[n]; modes[mode]![offset * 2 + n] += input[n] }
                let output = ring.materializePrefix(ring.frameCount)
                try diagnosticRequire(output.combined == combined && output.modes == modes, "Storage mismatch at operation \(i)")
                let consume = min(ring.frameCount, 1 + Int(seed % 7))
                ring.discardPrefix(consume)
                combined.removeFirst(consume * 2)
                for key in Array(modes.keys) { modes[key]!.removeFirst(consume * 2) }
            }
            try diagnosticRequire(ring.wrappedWrites > 0 && ring.wrappedReads > 0, "Fixture did not wrap")
            do { try ring.reserve(2049); throw DiagnosticFailure(message: "Unbounded reserve accepted") }
            catch TimelineStorageFailure.capacityExceeded { }
            do { _ = try TimelineCircularStorage(channelCount: 32, maximumFrames: Int.max); throw DiagnosticFailure(message: "Byte overflow accepted") }
            catch TimelineStorageFailure.capacityExceeded { }
            return .init(summary: "2,000 exact append/prepend/overlap/wrap/grow/discard comparisons; explicit bound")
        }]
    }
}

/// Runs the 9A reference and production mixer on exactly the same arrivals.
/// Exact comparisons include output decisions, segmentation, buses and deadlines.
private final class TimelineDifferentialFixture {
    let ring = PerAppTimelineMixer(storagePolicy: .init(maximumPacketFrames: 65_536), policyConfiguration: .init(mode: .legacy))
    let linear = ReferenceLinearTimelineMixer()
    var now = Date(timeIntervalSince1970: 9000)
    var lastPreparation: TimelinePacketPreparation?
    var emitted: [PCMFrame] = []

    @discardableResult func feed(_ start: Int64, _ count: Int = 4, _ value: Float = 1,
                                device: UInt32 = 100, client: UInt32 = 1, cycle: UInt64 = 100,
                                channels: Int = 2, rate: Double = 48_000, mode: PlaybackMode = .direct,
                                patterned: Bool = false, trace: AudioLatencyCapture? = nil) throws -> PCMFrame? {
        let descriptor = PerAppTimelinePacket(deviceObjectID: device,
            cycleCounter: cycle, startSampleTime: start, frameCount: count, channelCount: channels,
            sampleRate: rate, channelLayout: LPCMChannelLayout(coreAudioTag: 0, channelCount: channels)!, playbackMode: mode)
        let a = ring.preparePacket(descriptor); let b = linear.preparePacket(descriptor)
        lastPreparation = a
        try diagnosticRequire(a.requiresClientDSPReset == b.requiresClientDSPReset && a.streamEpoch == b.streamEpoch,
            "Preparation diverged at \(start)")
        let values = (0..<(count * channels)).map { patterned ? Float($0 % (channels + 3)) / 32 + value : value }
        let received = PerformanceClock.now()
        let context = trace.map { capture in PacketPerformanceContext(capture: capture,
            identity: .init(captureID: capture.id, runtimeSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
                transportGeneration: 1, streamEpoch: a.streamEpoch, deviceObjectID: device, startSampleTime: start,
                frameCount: count, sampleRate: rate, channelCount: channels), received: received, policyTick: received) }
        let output = values.withUnsafeBufferPointer { ring.mixProcessedPacket(a, samples: $0, policyNow: .fixtureDate(now), performance: context, processingCompleted: received) }
        let expected = values.withUnsafeBufferPointer { linear.mixProcessedPacket(b, samples: $0, now: now, performance: context, processingCompleted: received) }
        try Self.compare(output, expected)
        if let output { emitted.append(output) }
        now.addTimeInterval(0.0001)
        return output
    }
    @discardableResult func flush(after delay: Double = 1) throws -> PCMFrame? {
        let date = now.addingTimeInterval(delay)
        let a = ring.flushExpired(policyNow: .fixtureDate(date)); let b = linear.flushExpired(now: date)
        switch (a, b) {
        case (.idle, .idle): return nil
        case (.retryAfter(let x), .retryAfter(let y)):
            try diagnosticRequire(abs(x - y) < 0.000001, "Idle deadline changed"); return nil
        case (.flushed(let x), .flushed(let y)):
            try Self.compare(x, y); emitted.append(x); return x
        default: throw DiagnosticFailure(message: "Idle emission decision changed")
        }
    }
    func reset() { ring.reset(); linear.reset() }
    static func compare(_ a: PCMFrame?, _ b: PCMFrame?) throws {
        guard let a, let b else { try diagnosticRequire(a == nil && b == nil, "Emission decision changed"); return }
        try diagnosticRequire(a.interleaved == b.interleaved && a.playbackModeSamples == b.playbackModeSamples,
            "PCM/bus/segmentation differs from 9A")
        try diagnosticRequire(a.channelCount == b.channelCount && a.sampleRate == b.sampleRate && a.channelLayout == b.channelLayout,
            "Format differs from 9A")
        if let x = a.performanceTrace, let y = b.performanceTrace {
            try diagnosticRequire(x.identity == y.identity && x.firstPacketReceived == y.firstPacketReceived
                && x.lastPacketReceived == y.lastPacketReceived && x.firstPacketProcessed == y.firstPacketProcessed
                && x.lastPacketProcessed == y.lastPacketProcessed && x.contributingPackets == y.contributingPackets,
                "Trace contribution ranges changed")
        } else { try diagnosticRequire(a.performanceTrace == nil && b.performanceTrace == nil, "Trace completeness changed") }
    }
}

extension DeveloperSelfTests {
    static func timelineMixerCases() -> [DiagnosticCase] {
        func test(_ id: String, _ name: String, _ body: @escaping @MainActor (TimelineDifferentialFixture) throws -> Void) -> DiagnosticCase {
            DiagnosticCase(id: id, suite: "Timeline Mixer", name: name, safety: .simulated) {
                let fixture = TimelineDifferentialFixture()
                try body(fixture)
                try diagnosticRequire(fixture.ring.statistics.retainedSuffixShiftFrames == 0
                    && fixture.ring.statistics.prependCopiedFrames == 0 && fixture.ring.statistics.packetFrontShiftSamples == 0
                    && fixture.ring.statistics.capacityFailures == 0, "Storage shifted PCM or exceeded capacity")
                return .init(summary: name + "; exact 9A reference equality")
            }
        }
        return [
            test("M09", "Earlier overlapping packet prepends without moving existing PCM") { f in
                try f.feed(100); try f.feed(98, client: 2); let out = try f.flush()
                try diagnosticRequire(out?.interleaved == [1,1,1,1,2,2,2,2,1,1,1,1] && f.ring.statistics.prependFrames == 2, "Prepend incorrect")
            },
            test("M10", "Forward gap remains silent") { f in
                try f.feed(0); try f.feed(8); try f.flush()
                try diagnosticRequire(f.emitted.flatMap(\.interleaved) == [1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1], "Gap leaked old PCM")
            },
            test("M11", "Forward discontinuity emits old window and changes epoch") { f in
                try f.feed(0); let epoch = f.lastPreparation!.streamEpoch
                try f.feed(37); try f.flush()
                try diagnosticRequire(f.ring.statistics.discontinuityFlushes == 1 && f.lastPreparation!.streamEpoch != epoch, "Discontinuity missing")
            },
            test("M12", "Far-old packet is ignored") { f in
                try f.feed(100); try f.feed(0); try f.flush()
                try diagnosticRequire(f.ring.statistics.fullyStalePackets == 1, "Old packet not counted")
            },
            test("M13", "True rewind requests per-device DSP reset") { f in
                try f.feed(10000); let epoch = f.lastPreparation!.streamEpoch
                try f.feed(0, cycle: 0); try f.flush()
                try diagnosticRequire(f.lastPreparation!.requiresClientDSPReset && f.lastPreparation!.streamEpoch != epoch, "Rewind not reset")
            },
            test("M14", "Old packet without restart hint stays stale") { f in
                try f.feed(10000); try f.feed(0, cycle: 99); try f.flush()
                try diagnosticRequire(!f.lastPreparation!.requiresClientDSPReset && f.ring.statistics.timelineRestarts == 0, "False restart")
            },
            test("M15", "Device timelines and restart effects are independent") { f in
                try f.feed(10000, device: 100); try f.feed(10000, 4, 2, device: 200)
                try f.feed(0, device: 100, cycle: 0); try f.flush(); try f.flush()
                try diagnosticRequire(f.emitted.count == 2 && f.emitted.contains { $0.interleaved.allSatisfy { $0 == 2 } }, "Other device changed")
            },
            test("M16", "Runtime reset clears every device and epoch") { f in
                try f.feed(0, device: 100); try f.feed(0, device: 200)
                let old = f.lastPreparation!.streamEpoch
                f.reset(); try f.flush(); try f.feed(0); try f.flush()
                try diagnosticRequire(f.emitted.count == 1 && f.lastPreparation!.streamEpoch > old, "Reset retained old stream")
            },
            test("M17", "Combined and mode buses preserve independent contributions") { f in
                try f.feed(0); try f.feed(0, 4, 2, client: 2, mode: .spatialRender)
                let out = try f.flush()
                try diagnosticRequire(out?.interleaved.allSatisfy { $0 == 3 } == true && out?.playbackModeSamples[.direct]?.allSatisfy { $0 == 1 } == true
                    && out?.playbackModeSamples[.spatialRender]?.allSatisfy { $0 == 2 } == true, "Mode sum wrong")
            },
            test("M18", "New mode bus has zero earlier history") { f in
                try f.feed(0); try f.feed(2, 4, 2, mode: .spatialRender)
                let out = try f.flush()
                try diagnosticRequire(Array(out?.playbackModeSamples[.spatialRender]?.prefix(4) ?? []) == [0,0,0,0], "New bus has stale history")
            },
            test("M19", "Mode buses remain aligned through wrap") { f in
                for i in 0..<200 { try f.feed(Int64(i * 5), 5, mode: PlaybackMode.allCases[i % 3]) }
                try f.flush(); try diagnosticRequire(f.ring.statistics.wrappedReads + f.ring.statistics.wrappedWrites > 0, "No wrap tested")
            },
            test("M20", "Short mode-specific tail obeys idle deadline") { f in
                try f.feed(0, mode: .referencePlayback); try f.flush(after: 0.002)
                try diagnosticRequire(f.emitted.isEmpty, "Early idle flush")
                let out = try f.flush(after: 0.020)
                try diagnosticRequire(out?.playbackModeSamples[.referencePlayback] == out?.interleaved, "Mode tail lost")
            },
            test("M21", "Emitted arrays remain immutable after ring reuse") { f in
                for i in 0..<3 { try f.feed(Int64(i * 4), 4, 1) }
                let held = f.emitted[0]; let bytes = held.interleaved; let buses = held.playbackModeSamples
                for i in 3..<600 { try f.feed(Int64(i * 4), 4, Float(i % 7), mode: PlaybackMode.allCases[i % 3]) }
                try f.flush()
                try diagnosticRequire(held.interleaved == bytes && held.playbackModeSamples == buses && bytes.allSatisfy { $0 == 1 }, "Output aliases ring")
            },
            test("M23", "Partial late packets use a source offset") { f in
                for i in 0..<3 { try f.feed(Int64(i * 4), 4, 0) }
                try f.feed(3, 4, 2, client: 2); try f.flush()
                try diagnosticRequire(f.ring.statistics.partiallyLatePackets == 1 && f.ring.statistics.packetFrontShiftSamples == 0, "Late source shifted")
            },
            test("M24", "Partial emission retains suffix without shifting") { f in
                for i in 0..<30 { try f.feed(Int64(i * 256), 256) }
                try diagnosticRequire(f.ring.statistics.currentPendingFrames == 512 && f.linear.statistics.retainedSuffixShiftFrames > 0, "Holdback/shift baseline missing")
                try f.flush()
            },
            test("M25", "Capacity growth preserves existing PCM and mode buses") { f in
                try f.feed(0, 4, 1); try f.feed(2, 1024, 2, mode: .spatialRender); try f.flush()
                try diagnosticRequire(f.ring.statistics.storageReallocations == 2 && f.ring.statistics.storageGrowthCopiedFrames > 0, "Growth not exercised")
            },
            test("M26", "Steady-state allocation stabilizes") { f in
                for i in 0..<3 { try f.feed(Int64(i * 1024), 1024) }
                let warm = f.ring.statistics.storageReallocations; let bytes = f.ring.statistics.storageBytes
                for i in 3..<250 { try f.feed(Int64(i * 1024), 1024) }
                try diagnosticRequire(f.ring.statistics.storageReallocations == warm && f.ring.statistics.storageBytes == bytes, "Storage grows with runtime")
                try f.flush()
            },
            test("M27", "Thousands of emissions preserve PCM across repeated wraps") { f in
                for i in 0..<2500 { try f.feed(Int64(i * 7), 7, Float(i % 13) / 16, patterned: true) }
                try f.flush()
            },
            test("M28", "32-channel samples remain frame-aligned through wrap") { f in
                for i in 0..<150 { try f.feed(Int64(i * 13), 13, Float(i % 5), channels: 32, patterned: true) }
                try f.flush()
            },
            test("M29", "Mixed packet sizes preserve holdback and idle deadlines") { f in
                var start: Int64 = 0
                for i in 0..<100 {
                    let count = [256,1024,512,256,1024][i % 5]
                    try f.feed(start, count, client: UInt32(i % 3 + 1)); start += Int64(count)
                    if i % 9 == 0 { try f.flush(after: 0) }
                }
                try f.flush()
            },
            test("M31", "Trace contribution trimming matches the linear reference") { f in
                let tick = PerformanceClock.now(); let capture = AudioLatencyCapture(id: 9, start: tick, deadline: tick.advanced(seconds: 60))
                try f.feed(0, 4, trace: capture); try f.feed(2, 4, client: 2, trace: capture)
                try f.feed(6, 4, trace: capture); try f.feed(10, 4, trace: capture); try f.flush()
                try diagnosticRequire(f.emitted.allSatisfy { $0.performanceTrace != nil }, "Trace incomplete")
            },
            test("M32", "Epochs partition reused sample time with tracing on and off") { f in
                let tick = PerformanceClock.now(); let capture = AudioLatencyCapture(id: 10, start: tick, deadline: tick.advanced(seconds: 60))
                try f.feed(10000, 4, trace: capture); let old = try f.flush()?.performanceTrace?.identity.streamEpoch
                try f.feed(0, 4, cycle: 0, trace: capture); let new = try f.flush()?.performanceTrace?.identity.streamEpoch
                try diagnosticRequire(old != nil && new != nil && old != new, "Epoch joined reused time")
                f.reset(); try f.feed(0); try diagnosticRequire(f.lastPreparation!.streamEpoch > new!, "Epoch requires tracing")
            },
            test("M33", "Fixed-seed generated arrivals match 9A exactly") { f in
                var seed: UInt64 = 0xCA590123; var start: Int64 = 10000
                for i in 0..<3000 {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let count = [4,16,64,256][Int(seed % 4)]
                    let skew = Int64(Int((seed >> 8) % 25) - 8)
                    try f.feed(start + skew, count, Float(i % 9) / 16, client: UInt32((seed >> 20) % 3 + 1),
                        mode: PlaybackMode.allCases[Int((seed >> 30) % 3)], patterned: true)
                    start += Int64(count / 2)
                    if i % 137 == 0 { try f.flush() }
                }
                try f.flush()
            },
            test("M34", "Exact stale and discontinuity threshold boundaries") { f in
                try f.feed(0); try f.feed(36) // exactly 8 packet lengths after old end
                try diagnosticRequire(f.ring.statistics.discontinuityFlushes == 0, "Exact maximum gap became discontinuity")
                try f.flush(); f.reset()
                for i in 0..<3 { try f.feed(Int64(i * 4)) }
                try f.feed(0); try f.feed(3); try f.feed(4); try f.flush()
                try diagnosticRequire(f.ring.statistics.fullyStalePackets == 1 && f.ring.statistics.partiallyLatePackets == 1, "Boundary trimming incorrect")
            }
        ]
    }
}

extension DeveloperSelfTests {
    static func timelineIntegrationCases() -> [DiagnosticCase] {
        func test(_ id: String, _ name: String, _ body: @escaping @MainActor (DiagnosticSandbox) throws -> Void) -> DiagnosticCase {
            DiagnosticCase(id: id, suite: "Timeline Mixer", name: name, safety: .simulated) {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                try body(box); return .init(summary: name)
            }
        }
        let date = Date(timeIntervalSince1970: 9000)
        func packet(_ client: UInt32 = 1, start: Double = 0, value: Float = 1) -> PerAppAudioPacket {
            .init(deviceObjectID: 100, clientID: client, processID: 0, cycleCounter: UInt64(max(0, start / 4)), sampleTime: start,
                interleaved: Array(repeating: value, count: 8), channelCount: 2, sampleRate: 48000)
        }
        func flush(_ controller: PerAppAudioController) throws -> PCMFrame {
            guard case .flushed(let frame) = controller.flushExpiredMix(now: date.addingTimeInterval(1), policyNow: PerformanceClock.now().advanced(seconds: 1)) else { throw DiagnosticFailure(message: "No controller output") }
            return frame
        }
        return [
            test("M22", "Transport reusable memory is copied before it is reused") { box in
                let input = UnsafeMutablePointer<Float>.allocate(capacity: 8)
                input.initialize(repeating: 0.25, count: 8)
                defer { input.deinitialize(count: 8); input.deallocate() }
                _ = box.perApp.ingestTransportPacket(packet(), samples: .init(start: input, count: 8), sampleCount: 8)
                for n in 0..<8 { input[n] = 99 }
                guard case .flushed(let frame) = box.perApp.flushExpiredMix(now: Date().addingTimeInterval(1), policyNow: PerformanceClock.now().advanced(seconds: 1)) else { throw DiagnosticFailure(message: "No borrowed-input tail") }
                try diagnosticRequire(frame.interleaved == Array(repeating: 0.25, count: 8), "Transport memory escaped ingest")
            },
            test("I01", "Same application retains independent client filter and gain histories") { box in
                let solo = PerAppAudioController(settingsURL: box.directory.appendingPathComponent("solo.json"), monitorsRunningApplications: false)
                let clients = [UInt32(1), 2].map { PerAppDriverClient(deviceObjectID: 100, clientID: $0, processID: 0, bundleID: "test.same", isActive: true, generation: 1) }
                for controller in [box.perApp, solo] {
                    controller.updateClients(clients)
                    controller.setEqualizerBands([EQBand(kind: .peaking, frequency: 1000, gain: -6, q: 1)], for: "test.same")
                    controller.setEQBypassed(false, for: "test.same")
                    controller.setVolume(0.5, for: "test.same")
                }
                var mixed: [Float] = []; var single: [Float] = []
                for i in 0..<20 {
                    if i == 10 { box.perApp.setVolume(0.2, for: "test.same"); solo.setVolume(0.2, for: "test.same") }
                    let p = packet(start: Double(i * 4), value: i == 0 ? 1 : 0)
                    if let frame = box.perApp.ingest(p, now: date) { mixed += frame.interleaved }
                    if let frame = box.perApp.ingest(packet(2, start: Double(i * 4), value: i == 0 ? 1 : 0), now: date) { mixed += frame.interleaved }
                    if let frame = solo.ingest(p, now: date) { single += frame.interleaved }
                }
                mixed += try flush(box.perApp).interleaved; single += try flush(solo).interleaved
                try diagnosticRequire(mixed.count == single.count && zip(mixed, single).allSatisfy { abs($0 - $1 * 2) < 0.00001 }, "Client DSP histories merged")
            },
            test("I03", "Controller reset clears pending audio and advances stream identity") { box in
                _ = box.perApp.ingest(packet(), now: date)
                let epoch = box.perApp.timelineStatisticsSnapshot()!.latestStreamEpoch
                box.perApp.resetRuntime()
                guard case .idle = box.perApp.flushExpiredMix(now: date.addingTimeInterval(1), policyNow: PerformanceClock.now().advanced(seconds: 1)) else { throw DiagnosticFailure(message: "Controller retained pending PCM") }
                _ = box.perApp.ingest(packet(value: 0.5), now: date)
                let output = try flush(box.perApp)
                try diagnosticRequire(output.interleaved == Array(repeating: 0.5, count: 8), "Reset retained gain/filter PCM")
                try diagnosticRequire(box.perApp.timelineStatisticsSnapshot()!.latestStreamEpoch > epoch, "Controller reused epoch")
            },
            test("I04", "Registry refresh preserves pending timeline") { box in
                _ = box.perApp.ingest(packet(value: 0.25), now: date)
                box.perApp.updateClients([])
                let output = try flush(box.perApp)
                try diagnosticRequire(output.interleaved == Array(repeating: 0.25, count: 8), "Registry update destroyed pending audio")
            },
            test("I05", "Packet-time playback mode selects each bus") { box in
                var profile = DiagnosticSandbox.profile(); profile.endpointKind = .headphones
                box.perApp.setPlaybackContext(.init(profile: profile))
                box.perApp.updateClients([.init(deviceObjectID: 100, clientID: 1, processID: 0, bundleID: "test.mode", isActive: true, generation: 1)])
                _ = box.perApp.ingest(packet(), now: date)
                box.perApp.setPlaybackModeOverride(.spatialRender, for: "test.mode")
                _ = box.perApp.ingest(packet(start: 4, value: 2), now: date)
                let out = try flush(box.perApp)
                try diagnosticRequire(out.playbackModeSamples[.direct] == Array(repeating: 1, count: 8) + Array(repeating: 0, count: 8)
                    && out.playbackModeSamples[.spatialRender] == Array(repeating: 0, count: 8) + Array(repeating: 2, count: 8), "Packet mode was retroactive")
            },
            test("M35", "Invalid metadata and capacity fail without corrupting pending audio") { box in
                let mixer = PerAppTimelineMixer(storagePolicy: .init(maximumPacketFrames: 4), policyConfiguration: .init(mode: .legacy))
                func descriptor(_ count: Int, _ start: Int64 = 0) -> PerAppTimelinePacket {
                    .init(deviceObjectID: 100, cycleCounter: 100,
                        startSampleTime: start, frameCount: count, channelCount: 2, sampleRate: 48000, channelLayout: .stereo,
                        playbackMode: .direct)
                }
                let good = mixer.preparePacket(descriptor(4))
                _ = [Float](repeating: 1, count: 8).withUnsafeBufferPointer { mixer.mixProcessedPacket(good, samples: $0, policyNow: .fixtureDate(date)) }
                try diagnosticRequire(!mixer.preparePacket(descriptor(5)).isValid && !mixer.preparePacket(descriptor(4, Int64.max)).isValid, "Invalid descriptor accepted")
                guard case .flushed(let frame) = mixer.flushExpired(policyNow: .fixtureDate(date.addingTimeInterval(1))) else { throw DiagnosticFailure(message: "Invalid packet damaged pending state") }
                try diagnosticRequire(frame.interleaved == Array(repeating: 1, count: 8) && mixer.statistics.capacityFailures == 1 && mixer.statistics.invalidPackets == 1, "Invalid input not observable")
                let invalid = PerAppAudioPacket(deviceObjectID: 100, clientID: 1, processID: 0, cycleCounter: 0, sampleTime: Double(Int64.max),
                    interleaved: [0,0], channelCount: 2, sampleRate: 48000)
                try diagnosticRequire(box.perApp.ingest(invalid) == nil, "Out-of-range Double sample time accepted")
            }
        ]
    }
}

private struct TimelineBenchmarkResult: Codable {
    let scenario: String
    let implementation: String
    let iteration: Int
    let channels: Int
    let clients: Int
    let packetCount: Int
    let packetWork: LatencyDistribution
    let emittingPacketWork: LatencyDistribution
    let nonEmittingPacketWork: LatencyDistribution
    let processCPUSeconds: Double
    let emittedFrames: [Int: Int]
    let statistics: PerAppTimelineMixerStatistics
}

extension DeveloperSelfTests {
    static func timelineBenchmarkCases() -> [DiagnosticCase] {
        [DiagnosticCase(id: "M36", suite: "Timeline Mixer", name: "Paired Release mixer performance matrix", safety: .simulated) {
            guard let path = ProcessInfo.processInfo.environment["CAMITUNE_STAGE9_MATRIX_PATH"] else {
                return .init(summary: "Set CAMITUNE_STAGE9_MATRIX_PATH to run/export the paired timing matrix", details: "M09–M35 always run; the matrix is opt-in to keep routine diagnostics short.")
            }
            let scenarios: [(String, Int, Int, Bool, Bool)] = [
                ("T9.1 single client 1024", 2, 1, false, false),
                ("T9.2 three clients 1024", 2, 3, false, false),
                ("T9.3 mixed 256/1024", 2, 3, true, false),
                ("T9.4 three playback modes", 2, 3, true, true),
                ("T9.5 eight channels synthetic", 8, 3, true, true),
                ("T9.6 thirty-two channels synthetic", 32, 3, true, true)
            ]
            var results: [TimelineBenchmarkResult] = []
            for (label, channels, clients, mixed, modes) in scenarios {
                let sizes = mixed ? [256, 1024, 512, 256, 1024] : [1024]
                let inputs = Dictionary(uniqueKeysWithValues: Set(sizes).map { ($0, [Float](repeating: 0.125, count: $0 * channels)) })
                for iteration in 0..<4 {
                    // Alternate execution order to reduce first-run/order bias.
                    for useRing in (iteration % 2 == 0 ? [false, true] : [true, false]) {
                        let ring = PerAppTimelineMixer(storagePolicy: .init(maximumPacketFrames: 65_536), policyConfiguration: .init(mode: .legacy)); let linear = ReferenceLinearTimelineMixer()
                        var durations: [Double] = []; var emissions: [Double] = []; var insertions: [Double] = []; var emitted: [Int: Int] = [:]
                        var start: Int64 = 0; let date = Date(timeIntervalSince1970: 1000)
                        let cpu = RuntimePerformanceRecorder.cpuSeconds()
                        for cycle in 0..<400 {
                            let count = sizes[cycle % sizes.count]
                            for client in 1...clients {
                                // Every eleventh cycle includes a valid earlier arrival before
                                // any prefix can have committed that small interval.
                                let skew: Int64 = client > 1 && cycle % 11 == 0 ? -8 : 0
                                let packet = PerAppTimelinePacket(deviceObjectID: 100,
                                    cycleCounter: UInt64(cycle + 100), startSampleTime: start + skew, frameCount: count,
                                    channelCount: channels, sampleRate: 48000, channelLayout: LPCMChannelLayout(coreAudioTag: 0, channelCount: channels)!,
                                    playbackMode: modes ? PlaybackMode.allCases[client % 3] : .direct)
                                let tick = PerformanceClock.now()
                                let frame = inputs[count]!.withUnsafeBufferPointer { samples -> PCMFrame? in
                                    if useRing { return ring.mixProcessedPacket(ring.preparePacket(packet), samples: samples, policyNow: .fixtureDate(date)) }
                                    return linear.mixProcessedPacket(linear.preparePacket(packet), samples: samples, now: date)
                                }
                                let duration = PerformanceClock.milliseconds(tick, PerformanceClock.now())
                                if cycle >= 20 {
                                    durations.append(duration)
                                    if frame != nil { emissions.append(duration) } else { insertions.append(duration) }
                                }
                                if let frame { emitted[frame.frameCount, default: 0] += 1 }
                            }
                            start += Int64(count)
                        }
                        let usedCPU = RuntimePerformanceRecorder.cpuSeconds() - cpu
                        let result = useRing ? ring.flushExpired(policyNow: .fixtureDate(date.addingTimeInterval(1))) : linear.flushExpired(now: date.addingTimeInterval(1))
                        if case .flushed(let frame) = result { emitted[frame.frameCount, default: 0] += 1 }
                        results.append(.init(scenario: label, implementation: useRing ? "circular" : "9A linear reference", iteration: iteration,
                            channels: channels, clients: clients, packetCount: 400 * clients, packetWork: .init(durations),
                            emittingPacketWork: .init(emissions), nonEmittingPacketWork: .init(insertions), processCPUSeconds: usedCPU,
                            emittedFrames: emitted, statistics: useRing ? ring.statistics : linear.statistics))
                    }
                    let a = results[results.count - 1]; let b = results[results.count - 2]
                    try diagnosticRequire(a.emittedFrames == b.emittedFrames, "Benchmark frame segmentation changed")
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: URL(fileURLWithPath: path), options: .atomic)
            return .init(summary: "Six workloads × four alternating pairs; frame distributions equal", details: "Timing includes prepare/insertion/emission. UI-visible/hidden controller publication is covered separately by W02/W03/W06; this isolated matrix does not render SwiftUI or exercise hardware multichannel output.")
        }]
    }
}
