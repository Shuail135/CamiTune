import CTDSPCore
import Foundation

/// Control selects prepared revisions without waiting for source PCM.
/// The writer owns rendered activation. One claimed transition and one coalesced
/// prepared successor bound storage while retaining the existing UI transaction.
/// Preparation and acknowledgement disposal never run in an audio callback.
final class CTDSPGraphControl: @unchecked Sendable {
    private typealias Receipt = CheckedContinuation<Void, Error>
    private final class Request: @unchecked Sendable {
        enum State {
            case unsubmitted
            case cancelledBeforeSubmission
            case preparing(Receipt)
            case cancelledPreparation
            case resolved
        }
        // Accessed only under the containing control lock.
        var state = State.unsubmitted
    }
    private static let retirement = DispatchQueue(label: "CamiTune.NativeGraphControl", qos: .userInitiated)
    let handoff: NativeRevisionHandoff
    private let generation = UUID()
    private let lock = NSLock()
    private var wakeup: (@Sendable () -> Void)?
    private var request: Request?
    private var revision: UInt64 = 1
    enum Transition {
        case continued
        case replacing
    }
    private struct Selection {
        let prepared: NativePreparedRevision
        var history: CTDSPHistoryPolicy
    }
    private var publication: CTDSPRevision?
    private var queued: Selection?
    private let deliveryFailure = PerformanceAtomic()

    init(prepared: PreparedNativeGraph) throws {
        handoff = try NativeRevisionHandoff(generation: generation, format: .init(sample_rate: UInt32(prepared.sampleRate),
            input_channels: UInt32(prepared.inputChannels), output_channels: UInt32(prepared.outputChannels),
            maximum_frames: UInt32(prepared.maximumFrames)))
        var adopted = false
        defer {
            if !adopted {
                _ = handoff.close()
                handoff.withProcessingHandle { _ = ctdsp_handoff_stop($0) }
                _ = handoff.acknowledgement()
                _ = handoff.stoppedGraph()
            }
        }
        let initial = try NativePreparedRevision(taking: prepared, generation: generation, revision: revision)
        guard handoff.offer(initial, history: CTDSP_HISTORY_FRESH).status == CTDSP_OFFER_ACCEPTED else {
            throw NativeGraphError.native(CTDSP_INVALID_STATE)
        }
        // Before publication to a writer this scope owns both roles. Install
        // establishes readiness without manufacturing an actual-PCM receipt.
        let installed = handoff.withProcessingHandle { handle in
            ctdsp_handoff_begin(handle) == CTDSP_BEGIN_READY
                && ctdsp_handoff_install_prepared(handle) == CTDSP_TRANSITION_RESOLVED
        }
        guard installed, handoff.acknowledgement()?.resolution == CTDSP_REVISION_INSTALLED else {
            throw NativeGraphError.native(CTDSP_INVALID_STATE)
        }
        adopted = true
    }

    deinit {
        // Last reference proves no processing call still borrows this owner.
        // This also handles preparation failure or retirement before any writer
        // claimed the sink. Native allocation disposal stays on control.
        let retiring = handoff
        let prepared = queued
        Self.retirement.async {
            _ = retiring.close()
            retiring.withProcessingHandle { _ = ctdsp_handoff_stop($0) }
            _ = retiring.acknowledgement()
            _ = retiring.retiredTail()
            _ = retiring.stoppedGraph()
            withExtendedLifetime(prepared) {}
        }
    }

    func setWakeup(_ callback: (@Sendable () -> Void)?) {
        let signal = lock.withLock { () -> (@Sendable () -> Void)? in
            wakeup = callback
            if publication != nil { return callback }
            return nil
        }
        signal?()
    }

    func install(prepare: @escaping @Sendable (@escaping @Sendable () throws -> Void) throws -> PreparedNativeGraph) async throws {
        let next = Request()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (receipt: Receipt) in
                let admitted = lock.withLock { () -> Bool in
                    if case .cancelledBeforeSubmission = next.state {
                        receipt.resume(throwing: CancellationError()); return false
                    }
                    guard !handoff.withProcessingHandle({ ctdsp_handoff_is_closing($0) }) else {
                        next.state = .resolved; receipt.resume(throwing: CancellationError()); return false
                    }
                    guard request == nil, wakeup != nil else {
                        next.state = .resolved
                        receipt.resume(throwing: NativeGraphError.unsupported("The native writer is not ready for another graph installation."))
                        return false
                    }
                    next.state = .preparing(receipt); request = next
                    return true
                }
                if admitted {
                    Task.detached(priority: .userInitiated) { self.prepareAndPublish(next, prepare: prepare) }
                }
            }
        } onCancel: {
            self.cancel(next)
        }
    }

    private func prepareAndPublish(_ next: Request,
        prepare: (@escaping @Sendable () throws -> Void) throws -> PreparedNativeGraph) {
        do {
            let prepared = try prepare {
                try self.lock.withLock {
                    guard case .preparing = next.state else { throw CancellationError() }
                }
            }
            let signal = try lock.withLock { () throws -> (@Sendable () -> Void)? in
                guard case .preparing(let receipt) = next.state else {
                    if request === next { request = nil }
                    next.state = .resolved
                    return nil
                }
                guard revision < UInt64.max else { throw NativeGraphError.native(CTDSP_RESOURCE_LIMIT) }
                revision += 1
                let candidate = try NativePreparedRevision(taking: prepared, generation: generation, revision: revision)
                let published = try offer(Selection(prepared: candidate, history: CTDSP_HISTORY_CONTINUE_ACTIVE))
                // Selection is the transaction's commit point. A later Task
                // cancellation cannot undo it; undo is a new selected revision.
                next.state = .resolved; request = nil
                receipt.resume()
                return published ? wakeup : nil
            }
            signal?()
        } catch {
            let receipt = lock.withLock { () -> Receipt? in
                defer { if request === next { request = nil }; next.state = .resolved }
                if case .preparing(let receipt) = next.state { return receipt }
                return nil
            }
            receipt?.resume(throwing: error)
        }
    }

    /// Control lock owns selection and disposal. An incompatible history mapping
    /// chooses the structural waveform; preparation/format failures stay errors.
    private func offer(_ selection: Selection) throws -> Bool {
        var next = selection
        var result = handoff.offer(next.prepared, history: next.history)
        if result.status == CTDSP_OFFER_HISTORY_PREPARATION_FAILED,
           result.preparationStatus == CTDSP_INCOMPATIBLE_HISTORY {
            next.history = CTDSP_HISTORY_FRESH
            result = handoff.offer(next.prepared, history: next.history)
        }
        switch result.status {
        case CTDSP_OFFER_ACCEPTED, CTDSP_OFFER_SUPERSEDED:
            publication = next.prepared.identity
            queued = nil
            return true
        case CTDSP_OFFER_BUSY where next.history == CTDSP_HISTORY_FRESH || result.historyPrepared:
            // Continued selections retain reserved, unbound transfer storage.
            // Structural selections already own all their numerical storage.
            queued = next
            return false
        default:
            throw NativeGraphError.native(result.preparationStatus == CTDSP_OK ? CTDSP_INVALID_STATE : result.preparationStatus)
        }
    }

    private func cancel(_ next: Request) {
        let receipt = lock.withLock { () -> Receipt? in
            switch next.state {
            case .unsubmitted: next.state = .cancelledBeforeSubmission
            case .preparing(let waiting):
                next.state = .cancelledPreparation
                // The preparation owns its late result and this slot until it
                // returns. No second preparation can overlap it in this session.
                return waiting
            case .cancelledBeforeSubmission, .cancelledPreparation, .resolved: break
            }
            return nil
        }
        receipt?.resume(throwing: CancellationError())
    }

    /// Sole writer, outside the delivery condition. Returns the waveform needed
    /// by a prepared graph. No control lock or graph
    /// disposal lies on this path. Control-only calls leave paused input pending.
    func beginTransition(rendering: Bool) throws -> Transition? {
        let failure = deliveryFailure.acquired
        if failure != 0 { throw NativeGraphError.native(CTDSPStatus(rawValue: UInt32(failure - 1))) }
        return try handoff.withProcessingHandle { handle in
            let begun = rendering ? ctdsp_handoff_begin(handle) : ctdsp_handoff_begin_control(handle)
            switch begun {
            case CTDSP_BEGIN_READY:
                switch ctdsp_handoff_install_prepared(handle) {
                case CTDSP_TRANSITION_RESOLVED:
                    collectAfterResolution(); return nil
                case CTDSP_TRANSITION_CANCELLATION_PENDING:
                    _ = ctdsp_handoff_reject(handle, CTDSP_OK)
                    collectAfterResolution(); return nil
                case CTDSP_TRANSITION_CANDIDATE_NOT_PRISTINE, CTDSP_TRANSITION_ACTIVE_STREAM_UNFINISHED:
                    return ctdsp_handoff_candidate_continues_history(handle) ? .continued : .replacing
                default: throw NativeGraphError.native(CTDSP_INVALID_STATE)
                }
            case CTDSP_BEGIN_RESOLVED:
                collectAfterResolution()
                throw NativeGraphError.native(CTDSP_INVALID_STATE)
            default: return nil
            }
        }
    }

    func collectAfterResolution() {
        Self.retirement.async { self.collectAcknowledgement() }
    }

    private func collectAcknowledgement() {
        let signal = lock.withLock { () -> (@Sendable () -> Void)? in
            if let acknowledgement = handoff.acknowledgement() {
                guard publication?.number == acknowledgement.identity.number else {
                    preconditionFailure("Unowned native acknowledgement")
                }
                publication = nil
                if acknowledgement.resolution == CTDSP_REVISION_REJECTED {
                    deliveryFailure.publish(UInt64(acknowledgement.processingStatus == CTDSP_OK
                        ? CTDSP_INVALID_STATE.rawValue : acknowledgement.processingStatus.rawValue) + 1)
                }
            }
            _ = handoff.retiredTail()
            guard !handoff.withProcessingHandle({ ctdsp_handoff_is_closing($0) }), let next = queued else { return nil }
            do { return try offer(next) ? wakeup : nil }
            catch {
                // Readiness has already committed. Surface a revalidation
                // failure through delivery so the session cannot appear healthy.
                queued = nil
                deliveryFailure.publish(UInt64(CTDSP_INVALID_STATE.rawValue) + 1)
                return wakeup
            }
        }
        signal?()
    }

    func close() {
        var receipt: Receipt?
        let signal = lock.withLock { () -> (@Sendable () -> Void)? in
            let withdrawn = handoff.close()
            queued = nil
            if withdrawn != nil { publication = nil }
            if let request {
                switch request.state {
                case .preparing(let waiting): receipt = waiting; request.state = .cancelledPreparation
                default: break
                }
            }
            return wakeup
        }
        receipt?.resume(throwing: CancellationError())
        signal?()
    }

    /// Caller has finished its last native processing call. Activation and
    /// stopped-owner collection are serialized with other control work.
    func finishProcessing() {
        handoff.withProcessingHandle { _ = ctdsp_handoff_stop($0) }
        Self.retirement.async {
            self.collectAcknowledgement()
            self.lock.withLock {
                _ = self.handoff.retiredTail()
                _ = self.handoff.stoppedGraph()
            }
        }
    }
}
