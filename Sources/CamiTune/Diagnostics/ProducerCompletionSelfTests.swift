import CamiTuneAudio
import CamiTuneDomain
import Foundation

extension DeveloperSelfTests {
    /// Replays normalized constant-marker probe evidence through the actual
    /// assembler, per-client processing and ring mixer. Observed StopIO is
    /// modelled as a hypothetical protocol seal, so this is not live acceptance.
    static func replayProducerCompletion(from url: URL) throws -> String {
        struct Input: Decodable {
            struct Event: Decodable {
                let sequence: UInt64; let epoch: UInt64; let kind: UInt32
                let device: UInt32; let client: UInt32; let cycle: UInt64
                let start: Int64; let frames: Int; let tick: UInt64
                let marker: Float?; let expectedFingerprint: UInt64?
            }
            let events: [Event]
        }
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: url))
        guard input.events.count <= 131_072 else { throw DiagnosticFailure(message: "Probe replay exceeds event bound") }
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        let assembler = ProducerCompletionAssembler(generation: 1)
        var compared = 0, matching = 0, terminalFrames = 0
        for event in input.events {
            guard let kind = ProducerRecordKind(rawValue: event.kind), (0...8192).contains(event.frames),
                  kind != .pcm || event.marker?.isFinite == true else { throw DiagnosticFailure(message: "Invalid probe replay event") }
            let record = ProducerCompletionRecord(generation: 1, sequence: event.sequence, epoch: event.epoch,
                kind: kind, device: event.device, client: event.client, process: 0, cycle: event.cycle,
                start: event.start, frames: event.frames, channels: 2, layout: .stereo, rate: 48_000,
                received: .init(rawValue: event.tick), samples: kind == .pcm ? Array(repeating: event.marker!, count: event.frames * 2) : [])
            for interval in try assembler.ingest(record) {
                guard interval.end > interval.start else { continue }
                let output = try box.perApp.ingestCompletedInterval(interval)
                if interval.terminal { terminalFrames += output.frameCount }
                if let expected = event.expectedFingerprint {
                    compared += 1
                    let hash = output.interleaved.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1.bitPattern)) &* 1099511628211 }
                    if hash == expected { matching += 1 }
                }
            }
        }
        try diagnosticRequire(compared > 0 && compared == matching && assembler.pendingFrames == 0,
            "Producer replay mismatch: \(matching)/\(compared) writes, \(assembler.pendingFrames) pending frames")
        struct Result: Encodable {
            let matchingWrites: Int; let comparedWrites: Int; let terminalFrames: Int
            let statistics: ProducerCompletionStatistics
            let syntheticTerminalSeals = true
            let acceptanceEstablished = false
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(Result(matchingWrites: matching, comparedWrites: compared,
            terminalFrames: terminalFrames, statistics: assembler.statistics)), as: UTF8.self)
    }

    static func producerCompletionCases() -> [DiagnosticCase] {
        let origin = PerformanceTick(rawValue: 1_000_000_000)
        func record(_ sequence: UInt64, _ kind: ProducerRecordKind = .pcm, start: Int64 = 0,
                    frames: Int = 512, client: UInt32 = 1, epoch: UInt64 = 1,
                    generation: UInt64 = 1, value: Float = 0.125, time: Double = 0,
                    rate: Double = 48_000) -> ProducerCompletionRecord {
            .init(generation: generation, sequence: sequence, epoch: epoch, kind: kind, device: 100,
                client: client, process: 0, cycle: 1, start: start, frames: frames,
                channels: 2, layout: .stereo, rate: rate, received: origin.advanced(seconds: time),
                samples: kind == .pcm ? Array(repeating: value, count: frames * 2) : [])
        }
        func expectFault(_ action: () throws -> Void) throws {
            do { try action() } catch is ProducerCompletionFault { return }
            throw DiagnosticFailure(message: "Missing completion evidence did not fault")
        }
        func check(_ id: String, _ name: String, _ body: @escaping @MainActor () throws -> Void) -> DiagnosticCase {
            .init(id: id, suite: "Producer Completion", name: name, safety: .simulated) {
                try body(); return .init(summary: name)
            }
        }
        return [
            check("PC21", "Fast source validation still rejects NaN and infinite audio") {
                for value in [Float.nan, .infinity, -.infinity] {
                    let assembler = ProducerCompletionAssembler(generation: 1)
                    try expectFault { _ = try assembler.ingest(record(0, value: value)) }
                    try diagnosticRequire(assembler.statistics.closures == 0, "Invalid samples reached a completed mix")
                }
            },
            check("PC19", "Eight clients retain exact samples across mixed block sizes and device rates") {
                let sizes = [128, 256, 512, 1024, 2048, 4096, 256, 512]
                for rate in [44_100.0, 48_000, 96_000, 192_000] {
                    let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                    let assembler = ProducerCompletionAssembler(generation: 1)
                    var sequence: UInt64 = 0
                    var outputFrames = 0
                    for start in stride(from: 0, to: 65_536, by: 128) {
                        var events: [ProducerCompletionRecord] = []
                        for (client, size) in sizes.enumerated() where start.isMultiple(of: size) {
                            events.append(record(sequence, start: Int64(start), frames: size,
                                client: UInt32(client + 1), value: Float(client + 1) / 64,
                                time: Double(start) / rate, rate: rate))
                            sequence += 1
                        }
                        events.append(record(sequence, .close, start: Int64(start), frames: 128,
                            time: Double(start) / rate, rate: rate))
                        sequence += 1
                        if start.isMultiple(of: 3968) { events.reverse() }
                        for event in events {
                            for interval in try assembler.ingest(event) {
                                let mixed = try box.perApp.ingestCompletedInterval(interval)
                                try diagnosticRequire(mixed.interleaved == Array(repeating: Float(0.5625), count: 256),
                                    "A client was lost or duplicated at \(rate) Hz, frame \(start)")
                                outputFrames += mixed.frameCount
                            }
                        }
                    }
                    let end = try assembler.ingest(record(sequence, .end, frames: 0, rate: rate))
                    try diagnosticRequire(outputFrames == 65_536 && assembler.pendingFrames == 0
                        && assembler.statistics.faults == 0 && end.count == 1 && end[0].terminal,
                        "Multi-client stream failed to drain")
                }
            },
            check("PC20", "Joining-client zero pre-roll is trimmed without losing its unclosed audio") {
                let assembler = ProducerCompletionAssembler(generation: 1)
                _ = try assembler.ingest(record(0, .close, frames: 256))
                var samples = Array(repeating: Float(0), count: 512)
                samples += Array(repeating: Float(0.25), count: 512)
                let joined = ProducerCompletionRecord(generation: 1, sequence: 1, epoch: 1, kind: .pcm,
                    device: 100, client: 2, process: 0, cycle: 99, start: 0, frames: 512,
                    channels: 2, layout: .stereo, rate: 48_000, received: origin, samples: samples)
                _ = try assembler.ingest(joined)
                let result = try assembler.ingest(record(2, .close, start: 256, frames: 256))
                try diagnosticRequire(result[0].contributions[0].samples == Array(repeating: 0.25, count: 512)
                    && assembler.statistics.closedRevisionFrames == 256 && assembler.pendingFrames == 0,
                    "Join pre-roll replayed closed time or discarded live audio")
                try expectFault { _ = try assembler.ingest(record(3, client: 3, value: 0.25)) }
            },
            check("PC01", "Closure waits for every preceding reservation") {
                let assembler = ProducerCompletionAssembler(generation: 1)
                let early = try assembler.ingest(record(1, .close, time: 0.001))
                try diagnosticRequire(early.isEmpty, "Fence overtook unpublished PCM")
                let result = try assembler.ingest(record(0, time: 0.002))
                try diagnosticRequire(result.count == 1 && result[0].contributions.count == 1
                    && result[0].contributions[0].samples == Array(repeating: 0.125, count: 1024), "Reordered contribution changed")
            },
            check("PC02", "Missing evidence faults at exactly the unchanged 16 ms deadline") {
                let assembler = ProducerCompletionAssembler(generation: 1)
                _ = try assembler.ingest(record(0))
                try assembler.checkDeadline(at: origin.advanced(seconds: 0.015999))
                try expectFault { try assembler.checkDeadline(at: origin.advanced(seconds: 0.016)) }
                try diagnosticRequire(assembler.pendingFrames == 512 && assembler.statistics.faults == 1, "Fault silently flushed or discarded pending input")
                try expectFault { _ = try assembler.ingest(record(1, .close, time: 0.017)) }
                try diagnosticRequire(assembler.statistics.closures == 0 && assembler.statistics.faults == 1, "Late fence repaired a faulted session")
            },
            check("PC03", "A publication gap faults without waiting forever") {
                let assembler = ProducerCompletionAssembler(generation: 1)
                _ = try assembler.ingest(record(1, .close))
                try expectFault { try assembler.checkDeadline(at: origin.advanced(seconds: 0.016)) }
            },
            check("PC04", "Explicit seal preserves the nonzero 512-input/496-write tail") {
                let assembler = ProducerCompletionAssembler(generation: 1)
                _ = try assembler.ingest(record(0, start: 2564))
                let first = try assembler.ingest(record(1, .close, start: 2564, frames: 496, time: 0.001))
                let tail = try assembler.ingest(record(2, .end, frames: 0, time: 0.002))
                try diagnosticRequire(first[0].end == 3060 && tail.count == 1 && tail[0].start == 3060
                    && tail[0].end == 3076 && tail[0].terminal && tail[0].contributions[0].samples == Array(repeating: 0.125, count: 32), "Terminal PCM was cancelled or padded incorrectly")
                try diagnosticRequire(assembler.pendingFrames == 0 && assembler.statistics.terminalFrames == 16, "Tail accounting changed")
            },
            check("PC05", "Stop-time zero revision cannot replay closed DSP time") {
                let assembler = ProducerCompletionAssembler(generation: 1)
                _ = try assembler.ingest(record(0))
                _ = try assembler.ingest(record(1, .close, time: 0.001))
                let repeatResult = try assembler.ingest(record(2, value: 0, time: 0.002))
                let seal = try assembler.ingest(record(3, .end, frames: 0, time: 0.003))
                try diagnosticRequire(repeatResult.isEmpty && seal.count == 1 && seal[0].terminal
                    && seal[0].start == seal[0].end && assembler.statistics.closedRevisionFrames == 512,
                    "Closed callback became new DSP input or its delivery seal was lost")
            },
            check("PC06", "New nonzero late input and ambiguous pending replacement fault") {
                let assembler = ProducerCompletionAssembler(generation: 1)
                _ = try assembler.ingest(record(0))
                _ = try assembler.ingest(record(1, .close, time: 0.001))
                try expectFault { _ = try assembler.ingest(record(2, time: 0.002)) }
                let pending = ProducerCompletionAssembler(generation: 1)
                _ = try pending.ingest(record(0))
                try expectFault { _ = try pending.ingest(record(1, value: 0, time: 0.001)) }
            },
            check("PC07", "A seal isolates reused source times and rejects post-seal input") {
                let assembler = ProducerCompletionAssembler(generation: 1)
                _ = try assembler.ingest(record(0))
                _ = try assembler.ingest(record(1, .end, frames: 0, time: 0.001))
                _ = try assembler.ingest(record(2, epoch: 2, time: 0.002))
                let second = try assembler.ingest(record(3, .close, epoch: 2, time: 0.003))
                try diagnosticRequire(second[0].beginsEpoch && second[0].epoch == 2, "Restart inherited DSP epoch")
                let closed = ProducerCompletionAssembler(generation: 1)
                _ = try closed.ingest(record(0, .end, frames: 0))
                try expectFault { _ = try closed.ingest(record(1, time: 0.001)) }
            },
            check("PC08", "Stale session, duplicate sequence and unsealed epoch changes fault") {
                try expectFault { _ = try ProducerCompletionAssembler(generation: 2).ingest(record(0)) }
                let duplicate = ProducerCompletionAssembler(generation: 1)
                _ = try duplicate.ingest(record(0))
                try expectFault { _ = try duplicate.ingest(record(0, time: 0.001)) }
                let unsealed = ProducerCompletionAssembler(generation: 1)
                _ = try unsealed.ingest(record(0))
                try expectFault { _ = try unsealed.ingest(record(1, epoch: 2, time: 0.001)) }
            },
            check("PC09", "Partial closures refresh the idle deadline and retain the exact suffix") {
                let assembler = ProducerCompletionAssembler(generation: 1)
                _ = try assembler.ingest(record(0))
                _ = try assembler.ingest(record(1, .close, frames: 496, time: 0.010))
                let refreshed = origin.advanced(seconds: 0.010).advanced(seconds: 0.016)
                try diagnosticRequire(assembler.nextDeadline == refreshed, "Partial write did not refresh the idle deadline")
                let last = try assembler.ingest(record(2, .close, start: 496, frames: 16, time: 0.015))
                try diagnosticRequire(last[0].contributions[0].samples.count == 32 && assembler.nextDeadline == nil, "Suffix was copied with incorrect extent")
            },
            check("PC10", "Completion bounds account for retained backing storage") {
                let assembler = ProducerCompletionAssembler(generation: 1, maximumFrames: 512)
                _ = try assembler.ingest(record(0))
                _ = try assembler.ingest(record(1, .close, frames: 511, time: 0.001))
                try expectFault { _ = try assembler.ingest(record(2, start: 512, frames: 2, time: 0.002)) }
            },
            check("PC11", "Completed mixer waits for all clients and preserves zero padding") {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                let assembler = ProducerCompletionAssembler(generation: 1)
                _ = try assembler.ingest(record(0, start: 64, frames: 192))
                _ = try assembler.ingest(record(1, start: 128, frames: 128, client: 2, value: 0.25, time: 0.001))
                let closed = try assembler.ingest(record(2, .close, frames: 512, time: 0.002))
                let output = try box.perApp.ingestCompletedInterval(closed[0])
                let expected = Array(repeating: Float(0), count: 128) + Array(repeating: Float(0.125), count: 128)
                    + Array(repeating: Float(0.375), count: 256) + Array(repeating: Float(0), count: 512)
                try diagnosticRequire(output.interleaved == expected, "A client was omitted or closure padding changed")
            },
            check("PC12", "Reset during completed mixing cannot emit a partial interval") {
                let assembler = ProducerCompletionAssembler(generation: 1)
                _ = try assembler.ingest(record(0))
                let interval = try assembler.ingest(record(1, .close, time: 0.001))[0]
                let mixer = PerAppTimelineMixer(storagePolicy: .init(maximumPacketFrames: 65_536))
                try mixer.beginCompletedInterval(interval)
                mixer.reset()
                try expectFault { _ = try mixer.finishCompletedInterval(interval) }
            },
            check("PC13", "Producer fault and discontinuous closures fail explicitly") {
                try expectFault { _ = try ProducerCompletionAssembler(generation: 1).ingest(record(0, .fault, frames: 0)) }
                let assembler = ProducerCompletionAssembler(generation: 1)
                _ = try assembler.ingest(record(0, .close))
                try expectFault { _ = try assembler.ingest(record(1, .close, start: 513, time: 0.001)) }
            },
            check("PC14", "Stop revision leaves real per-client EQ and gain history unchanged") {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                let reference = PerAppAudioController(settingsURL: box.directory.appendingPathComponent("reference.json"), monitorsRunningApplications: false)
                for controller in [box.perApp, reference] {
                    controller.updateClients([.init(deviceObjectID: 100, clientID: 1, processID: 0,
                        bundleID: "test.completion", isActive: true, generation: 1)])
                    controller.setEqualizerBands([EQBand(kind: .peaking, frequency: 80, gain: -18, q: 10)], for: "test.completion")
                    controller.setEQBypassed(false, for: "test.completion")
                    controller.setVolume(0.5, for: "test.completion")
                }
                let assembler = ProducerCompletionAssembler(generation: 1)
                var actual: [Float] = []
                for event in [record(0), record(1, .close, time: 0.001), record(2, value: 0, time: 0.002),
                              record(3, start: 512, time: 0.003), record(4, .close, start: 512, time: 0.004)] {
                    for interval in try assembler.ingest(event) { actual += try box.perApp.ingestCompletedInterval(interval).interleaved }
                }
                var expected: [Float] = []
                for start in [0, 512] {
                    let packet = PerAppAudioPacket(deviceObjectID: 100, clientID: 1, processID: 0, cycleCounter: 1,
                        sampleTime: Double(start), interleaved: Array(repeating: 0.125, count: 1024),
                        channelCount: 2, sampleRate: 48_000, channelLayout: .stereo)
                    if let frame = reference.ingest(packet) { expected += frame.interleaved }
                }
                while case .flushed(let frame) = reference.flushExpiredMix(policyNow: PerformanceClock.now().advanced(seconds: 1)) {
                    expected += frame.interleaved
                }
                try diagnosticRequire(actual.count == 2048 && actual.count == expected.count
                    && zip(actual, expected).allSatisfy { abs($0 - $1) < 0.00001 }, "Closed zero revision advanced stateful EQ/gain or changed PCM")
            },
            check("PC15", "Steady completed intervals reuse ring capacity without stale samples") {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                let assembler = ProducerCompletionAssembler(generation: 1)
                var initialGrowths: UInt64?
                for block in 0..<100 {
                    let value: Float = block % 2 == 0 ? 0.125 : 0
                    _ = try assembler.ingest(record(UInt64(block * 2), start: Int64(block * 512), value: value, time: Double(block) * 0.010))
                    let interval = try assembler.ingest(record(UInt64(block * 2 + 1), .close,
                        start: Int64(block * 512), time: Double(block) * 0.010 + 0.001))[0]
                    let frame = try box.perApp.ingestCompletedInterval(interval)
                    try diagnosticRequire(frame.interleaved == Array(repeating: value, count: 1024), "Cached ring leaked earlier samples")
                    let statistics = box.perApp.timelineStatisticsSnapshot()!
                    if initialGrowths == nil { initialGrowths = statistics.storageReallocations }
                    try diagnosticRequire(statistics.storageReallocations == initialGrowths
                        && statistics.currentStorageCapacityFrames >= 512 && statistics.storageBytes > 0,
                        "Steady closure reallocated storage or hid cached memory")
                }
            },
            check("PC16", "Producer completion does not create heuristic deadlines or epochs") {
                let mixer = PerAppTimelineMixer(storagePolicy: .init(maximumPacketFrames: 65_536), policyConfiguration: .production)
                let interval = ProducerCompletedInterval(device: 100, epoch: 77, start: 0, end: 4,
                    channels: 2, layout: .stereo, rate: 48_000, contributions: [], terminal: false, beginsEpoch: true)
                try mixer.beginCompletedInterval(interval)
                let packet = PerAppTimelinePacket(deviceObjectID: 100,
                    cycleCounter: 1, startSampleTime: 0, frameCount: 4, channelCount: 2, sampleRate: 48_000,
                    channelLayout: .stereo, playbackMode: .direct)
                let preparation = mixer.preparePacket(packet)
                try diagnosticRequire(preparation.streamEpoch == 77, "Mixer invented a different epoch")
                // No contribution expected in this empty interval: exercise the
                // timer boundary without inserting a mismatched test packet.
                try diagnosticRequire(mixer.nextWakeDelay() == nil, "Completed interval created a timer")
                if case .idle = mixer.flushExpired(policyNow: origin.advanced(seconds: 100)) {} else {
                    throw DiagnosticFailure(message: "Idle timer tried to release a producer interval")
                }
                let output = try mixer.finishCompletedInterval(interval)
                let stats = mixer.statisticsSnapshot()
                try diagnosticRequire(output.interleaved == Array(repeating: 0, count: 8)
                    && stats.reorder.packets == 0 && stats.policySnapshots?.isEmpty == true,
                    "Completed interval ran a redundant heuristic policy")
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                let assembler = ProducerCompletionAssembler(generation: 1)
                _ = try assembler.ingest(record(0, epoch: 77))
                let closed = try assembler.ingest(record(1, .close, epoch: 77, time: 0.001))[0]
                _ = try box.perApp.ingestCompletedInterval(closed)
                let actual = box.perApp.timelineStatisticsSnapshot()!
                try diagnosticRequire(actual.reorder.packets == 0 && actual.policySnapshots?.isEmpty == true
                    && actual.latestStreamEpoch == 77, "Per-client processing reinstated heuristic state")
            },
            check("PC18", "Clock evidence comes from fenced producer timestamps, not sample-only host writes") {
                let assembler = ProducerCompletionAssembler(generation: 1)
                var source = record(0, start: 100)
                source.hostTime = 999; source.timestampFlags = 3
                let staged = try assembler.ingest(source)
                try diagnosticRequire(staged.isEmpty, "Unclosed source exposed its clock")
                let first = try assembler.ingest(record(1, .close, start: 100, frames: 496, time: 0.001))[0]
                try diagnosticRequire(first.clock?.sampleTime == 100 && first.clock?.hostTime == 999
                    && first.clock?.timestampFlags == 3 && first.clock?.deviceID == 100,
                    "Sample-only WriteMix replaced the valid producer clock")
                let suffix = try assembler.ingest(record(2, .close, start: 596, frames: 16, time: 0.002))[0]
                try diagnosticRequire(suffix.clock == nil, "Partial closure shifted or refreshed an old sample/host pair")
                var next = record(3, start: 612, time: 0.003)
                next.hostTime = 256_999; next.timestampFlags = 3
                _ = try assembler.ingest(next)
                let closed = try assembler.ingest(record(4, .close, start: 612, time: 0.004))[0]
                try diagnosticRequire(closed.clock?.sampleTime == 612 && closed.clock?.hostTime == 256_999,
                    "Ordered source clock failed to advance")
            },
            check("PC17", "A completion from a different epoch cannot finish the current batch") {
                let mixer = PerAppTimelineMixer(storagePolicy: .init(maximumPacketFrames: 65_536))
                let current = ProducerCompletedInterval(device: 100, epoch: 2, start: 0, end: 4,
                    channels: 2, layout: .stereo, rate: 48_000, contributions: [], terminal: false, beginsEpoch: true)
                let stale = ProducerCompletedInterval(device: 100, epoch: 1, start: 0, end: 4,
                    channels: 2, layout: .stereo, rate: 48_000, contributions: [], terminal: false, beginsEpoch: true)
                try mixer.beginCompletedInterval(current)
                try expectFault { _ = try mixer.finishCompletedInterval(stale) }
                let unbegun = ProducerCompletedInterval(device: 100, epoch: 3, start: 4, end: 8,
                    channels: 2, layout: .stereo, rate: 48_000, contributions: [], terminal: false, beginsEpoch: false)
                try expectFault { try mixer.beginCompletedInterval(unbegun) }
            }
        ]
    }
}
