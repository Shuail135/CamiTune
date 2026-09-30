import CamiTuneDomain
import Foundation

package enum ProducerRecordKind: UInt32, Sendable { case pcm, close, end, fault }

package struct ProducerCompletionRecord: Sendable {
    package init(generation: UInt64, sequence: UInt64, epoch: UInt64, kind: ProducerRecordKind, device: UInt32, client: UInt32, process: Int32, cycle: UInt64, start: Int64, frames: Int, channels: Int, layout: LPCMChannelLayout, rate: Double, received: PerformanceTick, samples: [Float], performance: PacketPerformanceContext? = nil, hostTime: UInt64 = 0, timestampFlags: UInt32 = 0) {
        self.generation = generation
        self.sequence = sequence
        self.epoch = epoch
        self.kind = kind
        self.device = device
        self.client = client
        self.process = process
        self.cycle = cycle
        self.start = start
        self.frames = frames
        self.channels = channels
        self.layout = layout
        self.rate = rate
        self.received = received
        self.samples = samples
        self.performance = performance
        self.hostTime = hostTime
        self.timestampFlags = timestampFlags
    }

    package let generation: UInt64
    package let sequence: UInt64
    package let epoch: UInt64
    package let kind: ProducerRecordKind
    package let device: UInt32
    package let client: UInt32
    package let process: Int32
    package let cycle: UInt64
    package let start: Int64
    package let frames: Int
    package let channels: Int
    package let layout: LPCMChannelLayout
    package let rate: Double
    package let received: PerformanceTick
    package let samples: [Float]
    package var performance: PacketPerformanceContext? = nil
    package var hostTime: UInt64 = 0
    package var timestampFlags: UInt32 = 0
    package var end: Int64 { start + Int64(frames) }
}

package struct ProducerCompletedInterval: Sendable {
    package init(device: UInt32, epoch: UInt64, start: Int64, end: Int64, channels: Int, layout: LPCMChannelLayout, rate: Double, contributions: [ProducerCompletionRecord], terminal: Bool, beginsEpoch: Bool, clock: AudioClockObservation? = nil) {
        self.device = device
        self.epoch = epoch
        self.start = start
        self.end = end
        self.channels = channels
        self.layout = layout
        self.rate = rate
        self.contributions = contributions
        self.terminal = terminal
        self.beginsEpoch = beginsEpoch
        self.clock = clock
    }

    package let device: UInt32
    package let epoch: UInt64
    package let start: Int64
    package let end: Int64
    package let channels: Int
    package let layout: LPCMChannelLayout
    package let rate: Double
    package let contributions: [ProducerCompletionRecord]
    package let terminal: Bool
    package let beginsEpoch: Bool
    package var clock: AudioClockObservation? = nil
}

package struct ProducerCompletionFault: Error, LocalizedError, Sendable, Equatable {
    package init(reason: String) {
        self.reason = reason
    }

    package let reason: String
    package var errorDescription: String? { "Producer completion failed: \(reason). Audio was paused; restart the session to recover." }
}

package struct ProducerCompletionStatistics: Sendable, Codable {
    package init(records: UInt64 = 0, closures: UInt64 = 0, terminalDrains: UInt64 = 0, terminalFrames: UInt64 = 0, closedRevisionFrames: UInt64 = 0, faults: UInt64 = 0, peakPendingFrames: Int = 0, peakReorderedRecords: Int = 0) {
        self.records = records
        self.closures = closures
        self.terminalDrains = terminalDrains
        self.terminalFrames = terminalFrames
        self.closedRevisionFrames = closedRevisionFrames
        self.faults = faults
        self.peakPendingFrames = peakPendingFrames
        self.peakReorderedRecords = peakReorderedRecords
    }

    package var records: UInt64 = 0
    package var closures: UInt64 = 0
    package var terminalDrains: UInt64 = 0
    package var terminalFrames: UInt64 = 0
    package var closedRevisionFrames: UInt64 = 0
    package var faults: UInt64 = 0
    package var peakPendingFrames = 0
    package var peakReorderedRecords = 0
}

/// Single transport-reader owner. PCM is staged *before* stateful DSP. Only an
/// ordered host closure or producer-owned END can release it. A missing fence
/// faults at the idle or residence deadline; neither timer nor occupancy can
/// authorize audio.
package final class ProducerCompletionAssembler {
    private struct Piece {
        let record: ProducerCompletionRecord
        var first: Int
        var count: Int
        var start: Int64 { record.start + Int64(first) }
        var end: Int64 { start + Int64(count) }
        func slice(_ start: Int64, _ end: Int64) -> ProducerCompletionRecord {
            let lower = Int(start - record.start) * record.channels
            let upper = Int(end - record.start) * record.channels
            return .init(generation: record.generation, sequence: record.sequence, epoch: record.epoch,
                kind: .pcm, device: record.device, client: record.client, process: record.process,
                cycle: record.cycle, start: start, frames: Int(end - start), channels: record.channels,
                layout: record.layout, rate: record.rate, received: record.received,
                samples: Array(record.samples[lower..<upper]), performance: record.performance)
        }
    }
    // One reader owns each epoch. Reference storage avoids copying its pending
    // pieces on every lookup from the device dictionary.
    private final class Epoch {
        let id: UInt64
        let channels: Int
        let layout: LPCMChannelLayout
        let rate: Double
        var pieces: [Piece] = []
        var closedEnd: Int64?
        var sealed = false
        var emitted = false
        var clockSampleTime: Int64?
        init(id: UInt64, channels: Int, layout: LPCMChannelLayout, rate: Double) {
            self.id = id; self.channels = channels; self.layout = layout; self.rate = rate
        }
    }
    package let generation: UInt64
    private var nextSequence: UInt64 = 0
    private var reordered: [UInt64: ProducerCompletionRecord] = [:]
    private var epochs: [UInt32: Epoch] = [:]
    private var lastEvidenceReceived: PerformanceTick?
    private var largestObservedPacketFrames = 0
    private var observedSampleRate: Double = 0
    package private(set) var statistics = ProducerCompletionStatistics()
    package private(set) var fault: ProducerCompletionFault?
    private let maximumFrames: Int
    private let maximumRecords: Int

    package init(generation: UInt64, maximumFrames: Int = 65_536, maximumRecords: Int = 1024) {
        precondition((1...262_144).contains(maximumFrames) && (1...1024).contains(maximumRecords))
        self.generation = generation; self.maximumFrames = maximumFrames; self.maximumRecords = maximumRecords
    }

    package var pendingFrames: Int { epochs.values.reduce(0) { $0 + $1.pieces.reduce(0) { $0 + $1.count } } }
    private var ownedSourceFrames: Int { epochs.values.reduce(0) { $0 + $1.pieces.reduce(0) { $0 + $1.record.frames } } }
    /// Evaluated only for diagnostics; never retain or log source sample data.
    package var diagnosticSummary: String {
        let sequences = reordered.keys.sorted()
        let devices = epochs.keys.sorted().map { device -> String in
            let epoch = epochs[device]!
            return "device=\(device) epoch=\(epoch.id) closed=\(epoch.closedEnd.map(String.init) ?? "none") pieces=\(epoch.pieces.count) span=\(epoch.pieces.map(\.start).min() ?? 0)..<\(epoch.pieces.map(\.end).max() ?? 0)"
        }.joined(separator: "; ")
        return "next=\(nextSequence) reordered=\(sequences.count) sequenceRange=\(sequences.first.map(String.init) ?? "none")...\(sequences.last.map(String.init) ?? "none") pendingFrames=\(pendingFrames) retainedFrames=\(ownedSourceFrames) closures=\(statistics.closures); \(devices)"
    }
    private var idleDeadline: PerformanceTick? {
        guard pendingFrames > 0 || !reordered.isEmpty, let lastEvidenceReceived else { return nil }
        return lastEvidenceReceived.advanced(seconds:
            TimelineReorderPolicy.legacyIdleDelay(largestObservedPacketFrames, sampleRate: observedSampleRate))
    }
    private var residenceDeadline: PerformanceTick? {
        let source = epochs.values.flatMap { $0.pieces.map { $0.record.received } }.min()
        let gap = reordered.values.map(\.received).min()
        guard let oldest = [source, gap].compactMap({ $0 }).min() else { return nil }
        // Continuous unrelated records cannot postpone an unfinished interval
        // forever. The storage bound also defines its maximum residence time.
        return oldest.advanced(seconds: Double(maximumFrames) / observedSampleRate)
    }
    package var nextDeadline: PerformanceTick? {
        [idleDeadline, residenceDeadline].compactMap { $0 }.min()
    }

    package func fail(_ reason: String) throws -> Never {
        throw latchFailure(reason)
    }

    @discardableResult package func latchFailure(_ reason: String) -> ProducerCompletionFault {
        if fault == nil {
            fault = .init(reason: "\(reason) (next transport record \(nextSequence))")
            statistics.faults += 1
        }
        return fault!
    }

    package func checkDeadline(at tick: PerformanceTick) throws {
        if let fault { throw fault }
        if let deadline = residenceDeadline, tick >= deadline {
            try fail("completion evidence did not arrive before the bounded residence deadline")
        }
        if let deadline = idleDeadline, tick >= deadline {
            try fail("completion evidence did not arrive before the retained idle deadline")
        }
    }

    package func ingest(_ record: ProducerCompletionRecord) throws -> [ProducerCompletedInterval] {
        if let fault { throw fault }
        guard record.generation == generation, record.epoch != 0, record.device != 0,
              record.sequence >= nextSequence, reordered[record.sequence] == nil,
              record.sequence - nextSequence < UInt64(maximumRecords),
              (1...32).contains(record.channels), record.layout.channelCount == record.channels,
              record.rate.isFinite, (8_000...768_000).contains(record.rate), record.frames >= 0, record.frames <= maximumFrames,
              !record.start.addingReportingOverflow(Int64(record.frames)).overflow,
              record.samples.count == (record.kind == .pcm ? record.frames * record.channels : 0),
              ((record.kind == .pcm || record.kind == .close) ? record.frames > 0 : record.frames == 0) else {
            try fail("invalid, duplicate, stale-session or unsupported producer record")
        }
        guard reordered.count < maximumRecords,
              ownedSourceFrames + reordered.values.reduce(0, { $0 + ($1.kind == .pcm ? $1.frames : 0) })
                + (record.kind == .pcm ? record.frames : 0) <= maximumFrames else {
            try fail("completion reorder storage reached its bound")
        }
        // A ready record may already contain the missing closure when the reader
        // wakes late. Apply ordered producer evidence before declaring idle; only
        // an empty read can establish that completion is still absent.
        reordered[record.sequence] = record
        statistics.records += 1
        statistics.peakReorderedRecords = max(statistics.peakReorderedRecords, reordered.count)
        var completed: [ProducerCompletedInterval] = []
        while let ordered = reordered.removeValue(forKey: nextSequence) {
            guard nextSequence != UInt64.max else { try fail("transport sequence exhausted") }
            nextSequence += 1
            completed += try apply(ordered)
        }
        lastEvidenceReceived = max(lastEvidenceReceived ?? record.received, record.received)
        largestObservedPacketFrames = max(largestObservedPacketFrames, record.frames)
        observedSampleRate = record.rate
        return completed
    }

    private func apply(_ record: ProducerCompletionRecord) throws -> [ProducerCompletedInterval] {
        if record.kind == .fault { try fail("the producer reported missing or rejected data") }
        if let prior = epochs[record.device], prior.id != record.epoch {
            guard prior.sealed, record.epoch > prior.id else { try fail("source epoch changed without a completed seal") }
            epochs.removeValue(forKey: record.device)
        }
        guard epochs.count < 32 || epochs[record.device] != nil else { try fail("too many source devices") }
        var epoch = epochs[record.device] ?? Epoch(id: record.epoch, channels: record.channels, layout: record.layout, rate: record.rate)
        guard !epoch.sealed, epoch.channels == record.channels, epoch.layout == record.layout, epoch.rate == record.rate else {
            try fail("record follows a sealed epoch or changes format inside an epoch")
        }
        var result: [ProducerCompletedInterval] = []
        switch record.kind {
        case .pcm:
            let finite = record.samples.withUnsafeBufferPointer { samples in
                var index = 0
                while index < samples.count {
                    if !samples[index].isFinite { return false }
                    index += 1
                }
                return true
            }
            guard finite else { try fail("nonfinite source PCM") }
            let distance = (epoch.closedEnd ?? record.start).subtractingReportingOverflow(record.start)
            let closedPrefix = distance.overflow ? (epoch.closedEnd! > record.start ? record.frames : 0)
                : min(record.frames, max(0, Int(distance.partialValue)))
            if closedPrefix > 0 {
                // HAL can send zero pre-roll when another client joins, as well
                // as zero revisions when one stops. Closed silence contributes
                // nothing to the host's completed mix. Trim exactly that prefix
                // before DSP; preserve all unclosed samples, including tails.
                // Nonzero late input still contradicts the completion fence.
                guard record.samples.prefix(closedPrefix * record.channels).allSatisfy({ $0 == 0 }) else {
                    try fail("nonzero input revisits an already-closed interval")
                }
                statistics.closedRevisionFrames += UInt64(closedPrefix)
            }
            let piece = Piece(record: record, first: closedPrefix, count: record.frames - closedPrefix)
            if piece.count > 0 {
                // No unproven replacement rule: ambiguous revisions of pending
                // input are explicit faults, even when the replacement is zero.
                guard !epoch.pieces.contains(where: {
                    $0.record.client == record.client && max($0.start, piece.start) < min($0.end, piece.end)
                }) else { try fail("overlapping revisions of unclosed client input") }
                guard ownedSourceFrames + record.frames <= maximumFrames,
                      epochs.values.reduce(0, { $0 + $1.pieces.count }) < maximumRecords else {
                    try fail("pending source PCM reached its bound")
                }
                epoch.pieces.append(piece)
            }
        case .close:
            if let closed = epoch.closedEnd, record.start != closed { try fail("host closure is discontinuous or revisits closed time") }
            if epoch.pieces.contains(where: { $0.start < record.start }) { try fail("host closure skips pending source input") }
            result.append(extract(&epoch, device: record.device, start: record.start, end: record.end, terminal: false))
            epoch.closedEnd = record.end
            epoch.emitted = true
            statistics.closures += 1
        case .end:
            // END is a driver-owned admission seal, ordered after every admitted
            // callback, not a sampled StopIO/client-count observation. Preserve
            // the final unclosed input (including the measured 16-frame tail).
            if let first = epoch.pieces.map(\.start).min(), let end = epoch.pieces.map(\.end).max() {
                let start = epoch.closedEnd ?? first
                let span = end.subtractingReportingOverflow(start)
                guard first >= start, !span.overflow, span.partialValue <= Int64(maximumFrames) else { try fail("terminal source interval exceeds its bound") }
                result.append(extract(&epoch, device: record.device, start: start, end: end, terminal: true))
                statistics.terminalDrains += 1
                statistics.terminalFrames += UInt64(end - start)
                epoch.closedEnd = end
            } else {
                let end = epoch.closedEnd ?? record.start
                result.append(extract(&epoch, device: record.device, start: end, end: end, terminal: true))
            }
            epoch.sealed = true
        case .fault: break // handled above
        }
        epochs[record.device] = epoch
        statistics.peakPendingFrames = max(statistics.peakPendingFrames, pendingFrames)
        return result
    }

    private func extract(_ epoch: inout Epoch, device: UInt32, start: Int64, end: Int64, terminal: Bool) -> ProducerCompletedInterval {
        var inputs: [ProducerCompletionRecord] = []
        var retained: [Piece] = []
        var clockSource: ProducerCompletionRecord?
        for var piece in epoch.pieces {
            let lower = max(piece.start, start), upper = min(piece.end, end)
            if upper > lower {
                // WriteMix carries only sample time on the observed HAL. Use
                // the original ProcessOutput sample/host pair, after its PCM
                // has crossed the ordered completion fence. Never shift a
                // sliced sample position without its corresponding host time.
                let source = piece.record
                if source.hostTime > 0, source.timestampFlags & 3 == 3,
                   epoch.clockSampleTime.map({ source.start > $0 }) ?? true,
                   clockSource.map({ source.start > $0.start }) ?? true {
                    clockSource = source
                }
                inputs.append(piece.slice(lower, upper))
                let consumed = Int(upper - piece.start)
                piece.first += consumed; piece.count -= consumed
            }
            if piece.count > 0 { retained.append(piece) }
        }
        epoch.pieces = retained
        let clock = clockSource.map { source -> AudioClockObservation in
            epoch.clockSampleTime = source.start
            return .init(epoch: epoch.id, sampleTime: Double(source.start), hostTime: source.hostTime,
                nominalRate: source.rate, timestampFlags: source.timestampFlags,
                received: source.received, deviceID: device)
        }
        return .init(device: device, epoch: epoch.id, start: start, end: end, channels: epoch.channels,
            layout: epoch.layout, rate: epoch.rate, contributions: inputs.sorted {
                $0.start == $1.start ? $0.sequence < $1.sequence : $0.start < $1.start
            }, terminal: terminal, beginsEpoch: !epoch.emitted, clock: clock)
    }
}
