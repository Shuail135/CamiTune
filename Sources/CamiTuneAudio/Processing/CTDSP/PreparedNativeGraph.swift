import Foundation
import CamiTuneDomain
import CTDSPCore

enum NativeGraphError: LocalizedError, CustomStringConvertible {
    case unsupported(String)
    case assetMismatch(String)
    case native(CTDSPStatus)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .unsupported(let reason): return "Unsupported graph: \(reason)"
        case .assetMismatch(let id): return "Prepared FIR asset does not match \(id)"
        case .native(let status): return "Native status \(status.rawValue)"
        }
    }
}

/// Prepared numerical storage. One delivery owner serializes processing, reset,
/// counter reads and final release; control never reads mutable DSP histories.
package final class PreparedNativeGraph {
    package static let maximumTotalFIRCoefficients = Int(CTDSP_MAXIMUM_TOTAL_FIR_COEFFICIENTS)
    private var state: OpaquePointer?
    let sampleRate: Int
    let inputChannels: Int
    let outputChannels: Int
    let maximumFrames: Int

    private enum Filter {
        case operations([CTDSPOperation])
        case fir(Int)
    }

    private struct Operation {
        let identity: String
        let implementation: Implementation
        enum Implementation {
            case scalar(CTDSPOperation)
            case mixer(UInt32, Range<Int>)
            case fir(UInt32, Int)
        }
    }

    static func validateGraph(_ graph: ProcessingGraph, maximumFrames: Int) throws {
        // Check representability and the scratch lower bound before domain bus
        // resolution materializes one descriptor per internal channel. The C
        // owner subsequently accounts for every requested native allocation.
        guard (1...Int(CTDSP_MAXIMUM_FRAMES)).contains(maximumFrames),
              (1...Int(CTDSP_MAXIMUM_INPUT_CHANNELS)).contains(graph.inputFormat.channelCount),
              (1...Int(CTDSP_MAXIMUM_OUTPUT_CHANNELS)).contains(graph.outputFormat.channelCount),
              graph.mixers.allSatisfy({ $0.outputChannelCount > 0 && UInt32(exactly: $0.outputChannelCount) != nil }) else {
            throw NativeGraphError.native(CTDSP_INVALID_ARGUMENT)
        }
        let widthLimit = Int(CTDSP_MAXIMUM_PREPARED_BYTES) / (2 * MemoryLayout<Double>.stride * maximumFrames)
        guard graph.mixers.allSatisfy({ $0.outputChannelCount <= widthLimit }) else {
            throw NativeGraphError.native(CTDSP_RESOURCE_LIMIT)
        }
        try graph.validate()
    }

    init(graph: ProcessingGraph, maximumFrames: Int,
         assets: [String: NativeFIRAsset] = [:], partitioning: CTDSPFIRPartitioning = CTDSP_FIR_LARGER_TAILS) throws {
        try Self.validateGraph(graph, maximumFrames: maximumFrames)
        var coefficients: [Double] = []
        var firRanges: [Range<Int>] = []
        var filters: [String: Filter] = [:]
        for processor in graph.processors {
            if case .convolution(let source) = processor.implementation {
                guard let asset = assets[processor.id], asset.source == source,
                      asset.sampleRate == graph.sampleRate else { throw NativeGraphError.assetMismatch(processor.id) }
                guard !asset.coefficients.isEmpty,
                      asset.coefficients.count <= Self.maximumTotalFIRCoefficients - coefficients.count,
                      asset.coefficients.allSatisfy(\.isFinite) else {
                    throw NativeGraphError.native(CTDSP_INVALID_ARGUMENT)
                }
                let start = coefficients.count
                coefficients.append(contentsOf: asset.coefficients)
                filters[processor.id] = .fir(firRanges.count)
                firRanges.append(start..<coefficients.count)
            } else {
                filters[processor.id] = .operations(try Self.filterOperations(processor.implementation, rate: graph.sampleRate))
            }
        }
        let mixers = Dictionary(uniqueKeysWithValues: graph.mixers.map { ($0.id, $0) })
        var operations: [Operation] = []
        var connections: [CTDSPConnection] = []
        var occurrences: [String: Int] = [:]
        func occurrence(_ step: UUID, _ kind: String, _ id: String, _ channel: Int) -> String {
            // Length-prefix the arbitrary processor name. Repeated uses of one
            // definition have distinct histories; unrelated insertion preserves
            // their ordinal within this exact stage/channel occurrence.
            let key = "\(step.uuidString)/\(kind)/\(id.utf8.count):\(id)/\(channel)"
            let ordinal = occurrences[key, default: 0]
            occurrences[key] = ordinal + 1
            return "\(key)/\(ordinal)"
        }
        for step in graph.pipeline {
            switch step.kind {
            case .filter:
                for channel in step.channels {
                    for id in step.processorIDs {
                        let identity = occurrence(step.id, "filter", id, channel)
                        // Full graph validation established every lookup and
                        // channel. Definitions share values, never C histories.
                        switch filters[id]! {
                        case .operations(let values):
                            for (part, var value) in values.enumerated() {
                                value.channel = UInt32(channel)
                                operations.append(.init(identity: "\(identity)/\(part)", implementation: .scalar(value)))
                            }
                        case .fir(let index):
                            operations.append(.init(identity: "\(identity)/0", implementation: .fir(UInt32(channel), index)))
                        }
                        guard operations.count <= Int(CTDSP_MAXIMUM_OPERATIONS) else {
                            throw NativeGraphError.native(CTDSP_INVALID_ARGUMENT)
                        }
                    }
                }
            case .mixer(let id):
                let mixer = mixers[id]!
                let start = connections.count
                for mapping in mixer.mappings {
                    for source in mapping.sources where !source.muted {
                        guard connections.count < Int(CTDSP_MAXIMUM_PREPARED_BYTES) / MemoryLayout<CTDSPConnection>.stride else {
                            throw NativeGraphError.native(CTDSP_RESOURCE_LIMIT)
                        }
                        connections.append(.init(source: UInt32(source.channel), destination: UInt32(mapping.destination),
                            gain: pow(10, source.gainDB / 20) * (source.inverted ? -1 : 1)))
                    }
                }
                operations.append(.init(identity: occurrence(step.id, "mixer", id, 0),
                    implementation: .mixer(UInt32(mixer.outputChannelCount), start..<connections.count)))
                guard operations.count <= Int(CTDSP_MAXIMUM_OPERATIONS) else {
                    throw NativeGraphError.native(CTDSP_INVALID_ARGUMENT)
                }
            }
        }
        let firQuantum = UInt32(exactly: graph.chunkSize)
        guard firRanges.isEmpty || firQuantum != nil else { throw NativeGraphError.native(CTDSP_INVALID_ARGUMENT) }
        var identityBytes: [UInt8] = []
        let identityRanges = operations.map { operation -> Range<Int> in
            let start = identityBytes.count
            identityBytes.append(contentsOf: operation.identity.utf8)
            return start..<identityBytes.count
        }
        var prepared: OpaquePointer?
        let status = coefficients.withUnsafeBufferPointer { coefficientBuffer in
            let descriptors = firRanges.map { range in
                CTDSPFIR(coefficients: coefficientBuffer.baseAddress!.advanced(by: range.lowerBound),
                    coefficient_count: range.count, base_quantum: firQuantum!,
                    partitioning: partitioning.rawValue)
            }
            return descriptors.withUnsafeBufferPointer { firBuffer in
                connections.withUnsafeBufferPointer { connectionBuffer in
                    let values = operations.map { operation -> CTDSPOperation in
                        switch operation.implementation {
                        case .scalar(let value): return value
                        case .mixer(let width, let range):
                            var value = CTDSPOperation()
                            value.kind = CTDSP_MIXER.rawValue
                            value.output_channels = width
                            value.connections = range.isEmpty ? nil : connectionBuffer.baseAddress!.advanced(by: range.lowerBound)
                            value.connection_count = range.count
                            return value
                        case .fir(let channel, let index):
                            var value = CTDSPOperation()
                            value.kind = CTDSP_FIR.rawValue
                            value.channel = channel
                            value.fir = firBuffer.baseAddress!.advanced(by: index)
                            return value
                        }
                    }
                    return values.withUnsafeBufferPointer { buffer in
                        identityBytes.withUnsafeBufferPointer { bytes in
                            let identities = identityRanges.map { range in
                                CTDSPExecutionIdentity(bytes: bytes.baseAddress!.advanced(by: range.lowerBound), count: range.count)
                            }
                            return identities.withUnsafeBufferPointer { names in
                                var configuration = CTDSPConfiguration(input_channels: UInt32(graph.inputFormat.channelCount),
                                    output_channels: UInt32(graph.outputFormat.channelCount), maximum_frames: UInt32(maximumFrames),
                                    operations: buffer.baseAddress, operation_count: buffer.count, operation_identities: names.baseAddress)
                                return ctdsp_prepare(&configuration, &prepared)
                            }
                        }
                    }
                }
            }
        }
        guard status == CTDSP_OK else { throw NativeGraphError.native(status) }
        state = prepared!
        sampleRate = graph.sampleRate
        inputChannels = graph.inputFormat.channelCount
        outputChannels = graph.outputFormat.channelCount
        self.maximumFrames = maximumFrames
    }

    deinit { ctdsp_destroy(state) }

    /// Move the existing C allocation to its next owner. That caller must own
    /// it immediately and destroy it if a subsequent adoption fails. Aliases of
    /// this Swift object retain no C state after the move; their operations fail
    /// through the existing null-state contract instead of touching retired PCM.
    func takeState() throws -> OpaquePointer {
        guard let state else { throw NativeGraphError.native(CTDSP_INVALID_ARGUMENT) }
        self.state = nil
        return state
    }

    func process(input: UnsafeBufferPointer<Float>, output: UnsafeMutableBufferPointer<Float>, frames: Int) throws {
        guard let count = UInt32(exactly: frames) else { throw NativeGraphError.native(CTDSP_INVALID_ARGUMENT) }
        let status = ctdsp_process(state, input.baseAddress, input.count, output.baseAddress, output.count, count)
        guard status == CTDSP_OK else { throw NativeGraphError.native(status) }
    }

    func reset() throws {
        let status = ctdsp_reset(state)
        guard status == CTDSP_OK else { throw NativeGraphError.native(status) }
    }

    func endInput() throws {
        let status = ctdsp_end_input(state)
        guard status == CTDSP_OK else { throw NativeGraphError.native(status) }
    }

    func resumeInput() throws {
        let status = ctdsp_resume_input(state)
        guard status == CTDSP_OK else { throw NativeGraphError.native(status) }
    }

    func tailPeakBound() throws -> Double {
        var value = 0.0
        let status = ctdsp_read_tail_peak_bound(state, &value)
        guard status == CTDSP_OK else { throw NativeGraphError.native(status) }
        return value
    }

    func drain(output: UnsafeMutableBufferPointer<Float>, frames: Int) throws -> Int {
        guard let count = UInt32(exactly: frames) else { throw NativeGraphError.native(CTDSP_INVALID_ARGUMENT) }
        var written: UInt32 = 0
        let status = ctdsp_drain(state, output.baseAddress, output.count, count, &written)
        guard status == CTDSP_OK else { throw NativeGraphError.native(status) }
        return Int(written)
    }

    func cancel() throws {
        let status = ctdsp_cancel(state)
        guard status == CTDSP_OK else { throw NativeGraphError.native(status) }
    }

    func streamInfo() throws -> CTDSPStreamInfo {
        var result = CTDSPStreamInfo()
        let status = ctdsp_read_stream_info(state, &result)
        guard status == CTDSP_OK else { throw NativeGraphError.native(status) }
        return result
    }

    func counters() throws -> CTDSPCounters {
        var result = CTDSPCounters()
        let status = ctdsp_read_counters(state, &result)
        guard status == CTDSP_OK else { throw NativeGraphError.native(status) }
        return result
    }

    /// Offline continuation plan. These strong references keep both immutable
    /// descriptions and allocations alive; moving either allocation invalidates
    /// apply through its cleared handle. Mutable histories remain serial-owned.
    final class HistoryTransfer {
        private let source: PreparedNativeGraph
        private let destination: PreparedNativeGraph
        private let handle: OpaquePointer
        let info: CTDSPHistoryTransferInfo

        init(source: PreparedNativeGraph, destination: PreparedNativeGraph) throws {
            guard source.sampleRate == destination.sampleRate else { throw NativeGraphError.native(CTDSP_INCOMPATIBLE_HISTORY) }
            var result: OpaquePointer?
            let status = ctdsp_prepare_history_transfer(source.state, destination.state, &result)
            guard status == CTDSP_OK else { throw NativeGraphError.native(status) }
            handle = result!
            self.source = source
            self.destination = destination
            var details = CTDSPHistoryTransferInfo()
            _ = ctdsp_read_history_transfer_info(handle, &details)
            info = details
        }

        deinit { ctdsp_destroy_history_transfer(handle) }

        func apply() throws {
            let status = ctdsp_apply_history_transfer(handle, source.state, destination.state)
            guard status == CTDSP_OK else { throw NativeGraphError.native(status) }
        }
    }

    private static func filterOperations(_ implementation: ProcessingGraph.Processor.Implementation, rate: Int) throws -> [CTDSPOperation] {
        var value = CTDSPOperation()
        switch implementation {
        case .gain(let db):
            value.kind = CTDSP_GAIN.rawValue; value.parameters.0 = pow(10, db / 20)
        case .crossfeedGain(let db, let muted, _):
            value.kind = CTDSP_GAIN.rawValue; value.parameters.0 = muted ? 0 : pow(10, db / 20)
        case .biquad(let band):
            guard ![EQBand.Kind.peaking, .allPass].contains(band.kind) || band.q != nil || band.bandwidth != nil else {
                throw NativeGraphError.unsupported("\(band.kind.rawValue) requires Q or bandwidth")
            }
            let q = band.resolvedQ(sampleRate: Double(rate))
            guard q.isFinite && q > 0 else { throw NativeGraphError.native(CTDSP_INVALID_ARGUMENT) }
            let c = BiquadCoefficients(kind: band.kind, frequency: band.frequency, gainDB: band.gain ?? 0,
                q: q, sampleRate: Double(rate))
            value.kind = CTDSP_BIQUAD.rawValue
            value.parameters = (c.b0 / c.a0, c.b1 / c.a0, c.b2 / c.a0, c.a1 / c.a0, c.a2 / c.a0)
        case .limiter(let limiter):
            value.kind = limiter.softClip ? CTDSP_SOFT_LIMITER.rawValue : CTDSP_HARD_LIMITER.rawValue
            value.parameters.0 = pow(10, limiter.clipLimitDB / 20)
        case .firstOrderLowpass(let frequency):
            value.kind = CTDSP_BIQUAD.rawValue
            value.parameters = NativeFilterParameters.firstOrderLowpass(frequency, rate: Double(rate))
        case .delay(let milliseconds, let subsample):
            let delay = NativeFilterParameters.delay(milliseconds, rate: Double(rate), subsample: subsample)
            value.kind = CTDSP_INTEGER_DELAY.rawValue; value.delay_frames = UInt32(delay.frames)
            if let coefficients = delay.allpass {
                var allpass = CTDSPOperation()
                allpass.kind = CTDSP_BIQUAD.rawValue; allpass.parameters = coefficients
                return [value, allpass]
            }
        case .convolution:
            preconditionFailure("FIR coefficients belong to the asset preparation path")
        }
        return [value]
    }
}
