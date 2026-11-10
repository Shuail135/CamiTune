#include "CTDSPHandoff.h"
#include "GraphHandoff.h"
#include <cassert>
#include <new>

using namespace ctdsp;

struct CTDSPHandoff {
    GraphHandoff value;
    CTDSPHandoff(Generation generation, StreamFormat format, uint64_t firstFrame) noexcept
        : value(generation, format, firstFrame) {}
};

namespace {
GraphHandoff &owner(CTDSPHandoff *handle) { assert(handle); return handle->value; }
Revision native(CTDSPRevision revision) {
    return {{revision.generation.first, revision.generation.second}, revision.number};
}
CTDSPRevision value(Revision revision) {
    return {{revision.generation[0], revision.generation[1]}, revision.number};
}
PreparedRevision *native(CTDSPPreparedRevision *handle) {
    return reinterpret_cast<PreparedRevision *>(handle);
}
CTDSPPreparedRevision *handle(PreparedRevision *revision) {
    return reinterpret_cast<CTDSPPreparedRevision *>(revision);
}
CTDSPOfferStatus value(OfferStatus status) {
    switch (status) {
    case OfferStatus::accepted: return CTDSP_OFFER_ACCEPTED;
    case OfferStatus::superseded: return CTDSP_OFFER_SUPERSEDED;
    case OfferStatus::busy: return CTDSP_OFFER_BUSY;
    case OfferStatus::closed: return CTDSP_OFFER_CLOSED;
    case OfferStatus::wrongGeneration: return CTDSP_OFFER_WRONG_GENERATION;
    case OfferStatus::staleRevision: return CTDSP_OFFER_STALE_REVISION;
    case OfferStatus::incompatibleFormat: return CTDSP_OFFER_INCOMPATIBLE_FORMAT;
    case OfferStatus::historyPreparationFailed: return CTDSP_OFFER_HISTORY_PREPARATION_FAILED;
    }
}
CTDSPCancellationStatus value(CancellationStatus status) {
    switch (status) {
    case CancellationStatus::notFound: return CTDSP_CANCEL_NOT_FOUND;
    case CancellationStatus::withdrawn: return CTDSP_CANCEL_WITHDRAWN;
    case CancellationStatus::requested: return CTDSP_CANCEL_REQUESTED;
    case CancellationStatus::tooLate: return CTDSP_CANCEL_TOO_LATE;
    }
}
CTDSPResolution value(Resolution resolution) {
    switch (resolution) {
    case Resolution::applied: return CTDSP_REVISION_APPLIED;
    case Resolution::rejected: return CTDSP_REVISION_REJECTED;
    case Resolution::cancelled: return CTDSP_REVISION_CANCELLED;
    case Resolution::closed: return CTDSP_REVISION_CLOSED;
    case Resolution::installed: return CTDSP_REVISION_INSTALLED;
    }
}
CTDSPTransitionStart value(TransitionStart start) {
    switch (start) {
    case TransitionStart::noCandidate: return CTDSP_BEGIN_NO_CANDIDATE;
    case TransitionStart::ready: return CTDSP_BEGIN_READY;
    case TransitionStart::resolved: return CTDSP_BEGIN_RESOLVED;
    }
}
CTDSPCompletion value(Completion completion) {
    switch (completion) {
    case Completion::resolved: return CTDSP_TRANSITION_RESOLVED;
    case Completion::noCandidate: return CTDSP_TRANSITION_NO_CANDIDATE;
    case Completion::notRendered: return CTDSP_TRANSITION_NOT_RENDERED;
    case Completion::processingFailed: return CTDSP_TRANSITION_PROCESSING_FAILED;
    case Completion::candidateBehindActive: return CTDSP_TRANSITION_CANDIDATE_BEHIND_ACTIVE;
    case Completion::cancellationPending: return CTDSP_TRANSITION_CANCELLATION_PENDING;
    case Completion::previousInputNotEnded: return CTDSP_TRANSITION_PREVIOUS_INPUT_NOT_ENDED;
    case Completion::candidateNotPristine: return CTDSP_TRANSITION_CANDIDATE_NOT_PRISTINE;
    case Completion::activeStreamUnfinished: return CTDSP_TRANSITION_ACTIVE_STREAM_UNFINISHED;
    }
}
}

extern "C" CTDSPStatus ctdsp_revision_adopt(CTDSPState **state, CTDSPRevision revision,
                                            uint32_t sampleRate, CTDSPPreparedRevision **result) {
    if (!result) return CTDSP_INVALID_ARGUMENT;
    *result = nullptr;
    if (!state) return CTDSP_INVALID_ARGUMENT;
    auto prepared = PreparedRevision::adopt(native(revision), sampleRate, *state);
    *result = handle(prepared.second.release());
    return prepared.first;
}

extern "C" void ctdsp_revision_destroy(CTDSPPreparedRevision *revision) { delete native(revision); }
extern "C" CTDSPRevision ctdsp_revision_identity(const CTDSPPreparedRevision *revision) {
    assert(revision);
    return value(reinterpret_cast<const PreparedRevision *>(revision)->revision);
}

extern "C" CTDSPStatus ctdsp_handoff_create(CTDSPGeneration generation, CTDSPStreamFormat format,
                                            uint64_t firstFrame, CTDSPHandoff **result) {
    if (!result) return CTDSP_INVALID_ARGUMENT;
    *result = nullptr;
    if (!format.sample_rate || !format.input_channels || format.input_channels > CTDSP_MAXIMUM_INPUT_CHANNELS
        || !format.output_channels || format.output_channels > CTDSP_MAXIMUM_OUTPUT_CHANNELS
        || !format.maximum_frames || format.maximum_frames > CTDSP_MAXIMUM_FRAMES) return CTDSP_INVALID_ARGUMENT;
    try {
        *result = new CTDSPHandoff({generation.first, generation.second},
            {format.sample_rate, format.input_channels, format.output_channels, format.maximum_frames}, firstFrame);
        return CTDSP_OK;
    } catch (const std::bad_alloc &) { return CTDSP_ALLOCATION_FAILED; }
}

extern "C" void ctdsp_handoff_destroy(CTDSPHandoff *handoff) { delete handoff; }

extern "C" CTDSPOfferResult ctdsp_handoff_offer(CTDSPHandoff *handoff, CTDSPPreparedRevision **candidate, CTDSPHistoryPolicy history) {
    if (!candidate || !*candidate || (history != CTDSP_HISTORY_FRESH && history != CTDSP_HISTORY_CONTINUE_ACTIVE)) {
        return {CTDSP_OFFER_INVALID_ARGUMENT, nullptr, CTDSP_INVALID_ARGUMENT, {}, false};
    }
    std::unique_ptr<PreparedRevision> owned(native(*candidate));
    auto offered = owner(handoff).offer(owned, history == CTDSP_HISTORY_FRESH ? HistoryPolicy::fresh : HistoryPolicy::continueActive);
    *candidate = handle(owned.release());
    return {value(offered.status), handle(offered.superseded.release()), offered.preparationStatus,
            offered.history, offered.historyPrepared};
}

extern "C" CTDSPCancellationResult ctdsp_handoff_cancel(CTDSPHandoff *handoff, CTDSPRevision revision) {
    auto cancelled = owner(handoff).cancel(native(revision));
    return {value(cancelled.status), handle(cancelled.withdrawn.release())};
}

extern "C" CTDSPPreparedRevision *ctdsp_handoff_close(CTDSPHandoff *handoff) {
    return handle(owner(handoff).close().release());
}

extern "C" CTDSPAcknowledgement ctdsp_handoff_collect_acknowledgement(CTDSPHandoff *handoff) {
    auto acknowledgement = owner(handoff).collectAcknowledgement();
    CTDSPAcknowledgement result{};
    if (!acknowledgement) return result;
    result.available = true;
    result.revision = value(acknowledgement->revision);
    result.resolution = value(acknowledgement->resolution);
    result.processing_status = acknowledgement->processingStatus;
    if (acknowledgement->rendered) {
        result.has_rendered_interval = true;
        result.first_frame = acknowledgement->rendered->firstFrame;
        result.end_frame = acknowledgement->rendered->endFrame;
    }
    result.retired = handle(acknowledgement->retired.release());
    if (acknowledgement->retiring) {
        result.has_retiring_revision = true;
        result.retiring_revision = value(*acknowledgement->retiring);
    }
    return result;
}

extern "C" CTDSPPreparedRevision *ctdsp_handoff_collect_stopped(CTDSPHandoff *handoff) {
    return handle(owner(handoff).collectStoppedGraph().release());
}
extern "C" CTDSPPreparedRevision *ctdsp_handoff_collect_retired_tail(CTDSPHandoff *handoff) {
    return handle(owner(handoff).collectRetiredTail().release());
}
extern "C" CTDSPTransitionStart ctdsp_handoff_begin(CTDSPHandoff *handoff) {
    return value(owner(handoff).beginTransition());
}
extern "C" CTDSPTransitionStart ctdsp_handoff_begin_control(CTDSPHandoff *handoff) {
    return value(owner(handoff).beginTransition(ClaimPolicy::controlBoundary));
}

extern "C" CTDSPStatus ctdsp_handoff_process_active(CTDSPHandoff *handoff, const float *input, size_t inputCount,
                                                    float *output, size_t outputCount, uint32_t frames) {
    return owner(handoff).processActive(input, inputCount, output, outputCount, frames);
}
extern "C" CTDSPCompletion ctdsp_handoff_install_prepared(CTDSPHandoff *handoff) {
    return value(owner(handoff).installPrepared());
}
extern "C" CTDSPStatus ctdsp_handoff_process_candidate(CTDSPHandoff *handoff, const float *input, size_t inputCount,
                                                       float *output, size_t outputCount, uint32_t frames) {
    return owner(handoff).processCandidate(input, inputCount, output, outputCount, frames);
}
extern "C" CTDSPStatus ctdsp_handoff_end_active_input(CTDSPHandoff *handoff) { return owner(handoff).endActiveInput(); }
extern "C" CTDSPStatus ctdsp_handoff_resume_input(CTDSPHandoff *handoff) { return owner(handoff).resumeInput(); }
extern "C" CTDSPStatus ctdsp_handoff_reset_input(CTDSPHandoff *handoff) { return owner(handoff).resetInput(); }
extern "C" CTDSPStatus ctdsp_handoff_output_complete(CTDSPHandoff *handoff, bool candidate, bool *result) {
    return owner(handoff).outputComplete(candidate, result);
}
extern "C" bool ctdsp_handoff_candidate_continues_history(CTDSPHandoff *handoff) {
    return owner(handoff).candidateContinuesHistory();
}
extern "C" CTDSPCompletion ctdsp_handoff_install_completed(CTDSPHandoff *handoff, CTDSPRetirementPolicy retirement) {
    if (retirement != CTDSP_RETIRE_PREVIOUS && retirement != CTDSP_PRESERVE_PREVIOUS_TAIL) return CTDSP_TRANSITION_INVALID_ARGUMENT;
    return value(owner(handoff).installCompleted(retirement == CTDSP_RETIRE_PREVIOUS
        ? RetirementPolicy::discard : RetirementPolicy::preserveTail));
}
extern "C" CTDSPStatus ctdsp_handoff_output_peak_limits(CTDSPHandoff *handoff, bool candidate, double *result, size_t count) {
    return owner(handoff).outputPeakLimits(candidate, result, count);
}
extern "C" CTDSPStatus ctdsp_handoff_active_tail_peak_bound(CTDSPHandoff *handoff, double *result) {
    return owner(handoff).activeTailPeakBound(result);
}
extern "C" CTDSPStatus ctdsp_handoff_end_candidate_input(CTDSPHandoff *handoff) { return owner(handoff).endCandidateInput(); }
extern "C" CTDSPStatus ctdsp_handoff_drain_active(CTDSPHandoff *handoff, float *output, size_t outputCount,
                                                 uint32_t frames, uint32_t *written) {
    return owner(handoff).drainActive(output, outputCount, frames, written);
}
extern "C" CTDSPStatus ctdsp_handoff_drain_candidate(CTDSPHandoff *handoff, float *output, size_t outputCount,
                                                    uint32_t frames, uint32_t *written) {
    return owner(handoff).drainCandidate(output, outputCount, frames, written);
}
extern "C" CTDSPStatus ctdsp_handoff_active_stream_info(CTDSPHandoff *handoff, CTDSPStreamInfo *result) {
    return owner(handoff).activeStreamInfo(result);
}
extern "C" CTDSPStatus ctdsp_handoff_candidate_stream_info(CTDSPHandoff *handoff, CTDSPStreamInfo *result) {
    return owner(handoff).candidateStreamInfo(result);
}
extern "C" bool ctdsp_handoff_candidate_cancellation_requested(CTDSPHandoff *handoff) {
    return owner(handoff).candidateCancellationRequested();
}
extern "C" CTDSPCompletion ctdsp_handoff_complete(CTDSPHandoff *handoff, CTDSPRetirementPolicy retirement) {
    if (retirement != CTDSP_RETIRE_PREVIOUS && retirement != CTDSP_PRESERVE_PREVIOUS_TAIL) return CTDSP_TRANSITION_INVALID_ARGUMENT;
    return value(owner(handoff).completeTransition(retirement == CTDSP_RETIRE_PREVIOUS
        ? RetirementPolicy::discard : RetirementPolicy::preserveTail));
}
extern "C" CTDSPStatus ctdsp_handoff_drain_retiring(CTDSPHandoff *handoff, float *output, size_t outputCount,
                                                  uint32_t frames, uint32_t *written) {
    return owner(handoff).drainRetiring(output, outputCount, frames, written);
}
extern "C" CTDSPStatus ctdsp_handoff_retiring_stream_info(CTDSPHandoff *handoff, CTDSPStreamInfo *result) {
    return owner(handoff).retiringStreamInfo(result);
}
extern "C" CTDSPStatus ctdsp_handoff_complete_retiring(CTDSPHandoff *handoff, bool *completed) {
    return owner(handoff).completeRetiring(completed);
}
extern "C" bool ctdsp_handoff_cancel_retiring(CTDSPHandoff *handoff) { return owner(handoff).cancelRetiring(); }
extern "C" bool ctdsp_handoff_retiring_revision(CTDSPHandoff *handoff, CTDSPRevision *result) {
    assert(result);
    const auto revision = owner(handoff).retiringRevision();
    if (!revision) return false;
    *result = value(*revision);
    return true;
}
extern "C" CTDSPCompletion ctdsp_handoff_reject(CTDSPHandoff *handoff, CTDSPStatus reason) {
    return value(owner(handoff).rejectTransition(reason));
}
extern "C" bool ctdsp_handoff_stop(CTDSPHandoff *handoff) { return owner(handoff).stopProcessing(); }
extern "C" bool ctdsp_handoff_active_revision(CTDSPHandoff *handoff, CTDSPRevision *result) {
    assert(result);
    auto revision = owner(handoff).activeRevision();
    if (!revision) return false;
    *result = value(*revision);
    return true;
}
extern "C" bool ctdsp_handoff_is_closing(CTDSPHandoff *handoff) { return owner(handoff).isClosing(); }
extern "C" bool ctdsp_handoff_is_stopped(CTDSPHandoff *handoff) { return owner(handoff).isStopped(); }
