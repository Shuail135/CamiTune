import Foundation
import CTDSPCore

func nativeGeneration(_ generation: UUID) -> CTDSPGeneration {
    // Explicit byte order avoids depending on UUID alignment or host endianness.
    withUnsafeBytes(of: generation.uuid) { bytes in
        var first: UInt64 = 0, second: UInt64 = 0
        for index in 0..<8 { first = (first << 8) | UInt64(bytes[index]) }
        for index in 8..<16 { second = (second << 8) | UInt64(bytes[index]) }
        return CTDSPGeneration(first: first, second: second)
    }
}

/// A serial control owner holds this revision until publication or disposal.
/// Neither the numerical state nor this move-only-by-contract handle is Sendable.
final class NativePreparedRevision {
    private var handle: OpaquePointer?
    let identity: CTDSPRevision

    init(taking graph: PreparedNativeGraph, generation: UUID, revision: UInt64) throws {
        guard let rate = UInt32(exactly: graph.sampleRate), rate > 0, revision > 0 else {
            throw NativeGraphError.native(CTDSP_INVALID_ARGUMENT)
        }
        identity = CTDSPRevision(generation: nativeGeneration(generation), number: revision)
        var state: OpaquePointer? = try graph.takeState()
        // This scope owns the moved partial result before adoption can allocate
        // or fail. Failure disposes it here; success clears the C state pointer.
        defer { ctdsp_destroy(state) }
        var result: OpaquePointer?
        let status = ctdsp_revision_adopt(&state, identity, rate, &result)
        guard status == CTDSP_OK else { throw NativeGraphError.native(status) }
        handle = result!
    }

    fileprivate init(retired handle: OpaquePointer) {
        self.handle = handle
        identity = ctdsp_revision_identity(handle)
    }

    deinit { ctdsp_revision_destroy(handle) }

    fileprivate func offer(to handoff: OpaquePointer, history: CTDSPHistoryPolicy) -> CTDSPOfferResult {
        // The ABI leaves the pointer intact for backpressure/rejection and
        // clears it only on publication. Repeated offers of a moved alias fail.
        ctdsp_handoff_offer(handoff, &handle, history)
    }
}

struct NativeRevisionAcknowledgement {
    let identity: CTDSPRevision
    // INSTALLED means ready for a future source and carries no rendered range.
    // APPLIED retains the stronger actual-PCM contract for live transitions.
    let resolution: CTDSPResolution
    let processingStatus: CTDSPStatus
    let rendered: Range<UInt64>?
    let retired: NativePreparedRevision?
    let retiring: CTDSPRevision?
}

/// Serial control adapter. Mutable DSP remains in the C++ sole consumer.
/// This owner is deliberately non-Sendable. Its borrowed processing handle may
/// be used by one worker only; that worker must join before the borrow returns.
/// No queue, callback or hardware acquisition occurs here.
final class NativeRevisionHandoff {
    private let handle: OpaquePointer

    init(generation: UUID, format: CTDSPStreamFormat, firstFrame: UInt64 = 0) throws {
        var result: OpaquePointer?
        let status = ctdsp_handoff_create(nativeGeneration(generation), format, firstFrame, &result)
        guard status == CTDSP_OK else { throw NativeGraphError.native(status) }
        handle = result!
    }

    deinit { ctdsp_handoff_destroy(handle) }

    func offer(_ candidate: NativePreparedRevision, history: CTDSPHistoryPolicy)
        -> (status: CTDSPOfferStatus, superseded: NativePreparedRevision?, preparationStatus: CTDSPStatus, history: CTDSPHistoryTransferInfo, historyPrepared: Bool) {
        let result = candidate.offer(to: handle, history: history)
        return (result.status, result.superseded.map { NativePreparedRevision(retired: $0) }, result.preparation_status, result.history, result.history_prepared)
    }

    func cancel(_ identity: CTDSPRevision) -> (status: CTDSPCancellationStatus, withdrawn: NativePreparedRevision?) {
        let result = ctdsp_handoff_cancel(handle, identity)
        return (result.status, result.withdrawn.map { NativePreparedRevision(retired: $0) })
    }

    @discardableResult
    func close() -> NativePreparedRevision? {
        ctdsp_handoff_close(handle).map { NativePreparedRevision(retired: $0) }
    }

    func acknowledgement() -> NativeRevisionAcknowledgement? {
        let result = ctdsp_handoff_collect_acknowledgement(handle)
        guard result.available else { return nil }
        return NativeRevisionAcknowledgement(identity: result.revision, resolution: result.resolution,
            processingStatus: result.processing_status,
            rendered: result.has_rendered_interval ? result.first_frame..<result.end_frame : nil,
            retired: result.retired.map { NativePreparedRevision(retired: $0) },
            retiring: result.has_retiring_revision ? result.retiring_revision : nil)
    }

    func retiredTail() -> NativePreparedRevision? {
        ctdsp_handoff_collect_retired_tail(handle).map { NativePreparedRevision(retired: $0) }
    }

    func stoppedGraph() -> NativePreparedRevision? {
        ctdsp_handoff_collect_stopped(handle).map { NativePreparedRevision(retired: $0) }
    }

    func withProcessingHandle<Result>(_ body: (OpaquePointer) throws -> Result) rethrows -> Result {
        try withExtendedLifetime(self) { try body(handle) }
    }
}
