#include "GraphHandoff.h"
#include <algorithm>
#include <cassert>
#include <limits>
#include <new>

namespace ctdsp {

static_assert(std::atomic<PreparedRevision *>::is_always_lock_free);
static_assert(std::atomic<uint32_t>::is_always_lock_free);
static_assert(std::atomic<bool>::is_always_lock_free);

static bool isPristine(const CTDSPState *state) noexcept {
    CTDSPCounters counters{};
    CTDSPStreamInfo stream{};
    ctdsp_read_counters(state, &counters);
    ctdsp_read_stream_info(state, &stream);
    return !counters.processed_blocks && !counters.rejected_blocks && stream.phase == CTDSP_STREAM_ACCEPTING;
}

PreparedRevision::PreparedRevision(Revision id, uint32_t rate, CTDSPFormat dimensions, CTDSPState *state) noexcept
    : revision(id), format{rate, dimensions.input_channels, dimensions.output_channels, dimensions.maximum_frames}, state_(state) {}

std::pair<CTDSPStatus, std::unique_ptr<PreparedRevision>> PreparedRevision::adopt(
    Revision revision, uint32_t sampleRate, CTDSPState *&state) noexcept {
    if (!state || !revision.number || !sampleRate) return {CTDSP_INVALID_ARGUMENT, nullptr};
    CTDSPFormat dimensions{};
    ctdsp_read_format(state, &dimensions);
    // A revision starts from clean histories. A caller may explicitly reset a
    // used state first; adoption itself must not silently alter those histories.
    if (!isPristine(state)) {
        return {CTDSP_INVALID_ARGUMENT, nullptr};
    }
    try {
        std::unique_ptr<PreparedRevision> result(new PreparedRevision(revision, sampleRate, dimensions, state));
        state = nullptr;
        return {CTDSP_OK, std::move(result)};
    } catch (const std::bad_alloc &) {
        return {CTDSP_ALLOCATION_FAILED, nullptr};
    }
}

PreparedRevision::~PreparedRevision() {
    discardContinuation();
    ctdsp_destroy(state_);
}

void PreparedRevision::discardContinuation() noexcept {
    ctdsp_destroy_history_transfer(std::exchange(continuation_, nullptr));
}

CTDSPStatus PreparedRevision::process(const float *input, size_t inputCount, float *output,
                                     size_t outputCount, uint32_t frames) noexcept {
    if (frames > std::numeric_limits<uint64_t>::max() - nextFrame_) {
        lastStatus_ = CTDSP_INVALID_ARGUMENT;
        return lastStatus_;
    }
    return recordRender(ctdsp_process(state_, input, inputCount, output, outputCount, frames), frames);
}

CTDSPStatus PreparedRevision::drain(float *output, size_t outputCount, uint32_t frames, uint32_t *written) noexcept {
    if (written) *written = 0;
    CTDSPStreamInfo info{};
    ctdsp_read_stream_info(state_, &info);
    const uint64_t count = info.phase != CTDSP_STREAM_DRAINING ? 0
        : info.tail_kind == CTDSP_TAIL_FINITE ? std::min(uint64_t(frames), info.remaining_tail_frames) : frames;
    // A final finite request can exceed its actual interval. Check the actual
    // extent before rendering so overflow never advances histories or output.
    if (count > std::numeric_limits<uint64_t>::max() - nextFrame_) {
        return recordRender(CTDSP_INVALID_ARGUMENT, 0);
    }
    const auto status = ctdsp_drain(state_, output, outputCount, frames, written);
    return recordRender(status, status == CTDSP_OK ? *written : 0);
}

CTDSPStatus PreparedRevision::endInput() noexcept {
    CTDSPStreamInfo before{};
    ctdsp_read_stream_info(state_, &before);
    const auto status = ctdsp_end_input(state_);
    if (status == CTDSP_OK && before.phase == CTDSP_STREAM_ACCEPTING) sourceEndFrame_ = nextFrame_;
    return status;
}

CTDSPStatus PreparedRevision::resumeInput() noexcept {
    const auto status = ctdsp_resume_input(state_);
    if (status == CTDSP_OK) sourceEndFrame_.reset();
    return status;
}

CTDSPStatus PreparedRevision::reset() noexcept {
    const auto status = ctdsp_reset(state_);
    if (status == CTDSP_OK) {
        sourceEndFrame_.reset();
        rendered_.reset();
        lastStatus_ = CTDSP_OK;
    }
    // A delivery discontinuity discards history, never the logical timeline.
    return status;
}

bool PreparedRevision::coversProgressOf(const PreparedRevision &other) const noexcept {
    if (nextFrame_ >= other.nextFrame_) return true;
    // Completion proves future zeros, not consumption of missing source input.
    // Repeated end calls and tail rendering cannot move either source boundary.
    if (!sourceEndFrame_ || sourceEndFrame_ != other.sourceEndFrame_) return false;
    CTDSPStreamInfo info{};
    ctdsp_read_stream_info(state_, &info);
    // Recursive Float32 completion does not erase numerical memory. Such a
    // lane must still drain across the peer's real interval before resumption.
    return info.phase == CTDSP_STREAM_DRAINED;
}

CTDSPStatus PreparedRevision::outputComplete(bool *result) const noexcept {
    if (!result) return CTDSP_INVALID_ARGUMENT;
    *result = false;
    CTDSPStreamInfo info{};
    const auto status = ctdsp_read_stream_info(state_, &info);
    if (status != CTDSP_OK) return status;
    if (info.phase == CTDSP_STREAM_FAULTED || info.phase == CTDSP_STREAM_CANCELLED) return CTDSP_INVALID_STATE;
    if (info.phase == CTDSP_STREAM_DRAINED) { *result = true; return CTDSP_OK; }
    if (info.phase != CTDSP_STREAM_DRAINING || info.tail_kind != CTDSP_TAIL_RECURSIVE) return CTDSP_OK;
    double bound = 0;
    const auto bounded = ctdsp_read_tail_peak_bound(state_, &bound);
    if (bounded != CTDSP_OK) return bounded;
    // The entire future range must round to Float32 zero in the rendering
    // thread's environment. This preserves recursive history for later input.
    volatile float positive = static_cast<float>(bound), negative = static_cast<float>(-bound);
    *result = positive == 0 && negative == 0;
    return CTDSP_OK;
}

CTDSPStatus PreparedRevision::recordRender(CTDSPStatus status, uint32_t frames) noexcept {
    if (status == CTDSP_OK && frames) {
        // A completed lane may resume after implied zeros. Report only the
        // latest contiguous actual interval, never the intervening logical gap.
        if (!rendered_ || rendered_->endFrame != nextFrame_) rendered_ = RenderedInterval{nextFrame_, nextFrame_};
        nextFrame_ += frames;
        rendered_->endFrame = nextFrame_;
    }
    // An already-drained success renders no PCM and cannot erase a prior
    // rejected render when deciding whether a candidate may activate.
    if (status != CTDSP_OK || frames) lastStatus_ = status;
    return status;
}

GraphHandoff::GraphHandoff(Generation generation, StreamFormat format, uint64_t firstFrame) noexcept
    : generation_(generation), format_(format), firstFrame_(firstFrame) {}

GraphHandoff::~GraphHandoff() {
    // The caller must first seal, stop the sole consumer and join callbacks.
    // Final release is control-side even if it chooses not to collect an ack.
    assert(isStopped() && !active_ && !candidate_ && !retiring_ && !pending_.load(std::memory_order_relaxed));
    ctdsp_destroy_history_transfer(message_.retiredContinuation);
    delete message_.retired;
    delete stoppedGraph_;
    delete retiredTail_.load(std::memory_order_relaxed);
}

uintptr_t GraphHandoff::publicationToken(PreparedRevision *revision) noexcept {
    static_assert(alignof(PreparedRevision) >= 2);
    static_assert(std::atomic<uintptr_t>::is_always_lock_free);
    return reinterpret_cast<uintptr_t>(revision) | uintptr_t(revision->continuation_ != nullptr);
}

PreparedRevision *GraphHandoff::publicationPointer(uintptr_t token) noexcept {
    return reinterpret_cast<PreparedRevision *>(token & ~uintptr_t(1));
}

Offer GraphHandoff::offer(std::unique_ptr<PreparedRevision> &candidate, HistoryPolicy history) noexcept {
    assert(candidate);
    if (isClosing()) return {OfferStatus::closed, nullptr};
    if (candidate->revision.generation != generation_) return {OfferStatus::wrongGeneration, nullptr};
    if (candidate->revision.number <= lastRevision_) return {OfferStatus::staleRevision, nullptr};
    if (!(candidate->format == format_)) return {OfferStatus::incompatibleFormat, nullptr};
    CTDSPHistoryTransferInfo info{};
    if (history == HistoryPolicy::continueActive) {
        if (!acknowledgedActive_) {
            candidate->discardContinuation();
            return {OfferStatus::historyPreparationFailed, nullptr, CTDSP_INVALID_STATE};
        }
        const auto status = candidate->continuation_
            ? ctdsp_rebind_history_transfer(candidate->continuation_, acknowledgedActive_->state_, candidate->state_)
            : ctdsp_prepare_history_transfer(acknowledgedActive_->state_, candidate->state_, &candidate->continuation_);
        if (status != CTDSP_OK) {
            candidate->discardContinuation();
            return {OfferStatus::historyPreparationFailed, nullptr, status};
        }
        ctdsp_read_history_transfer_info(candidate->continuation_, &info);
    } else candidate->discardContinuation();
    const bool preparedHistory = candidate->continuation_ != nullptr;
    const auto busy = [&]() {
        if (preparedHistory && outstanding_) {
            // A claimed predecessor can become active before this queued offer.
            // Structural compatibility is not transitive: validate both possible
            // predecessors before control commits the queued selection.
            const auto *predecessor = publicationPointer(outstanding_->token);
            const auto status = ctdsp_rebind_history_transfer(candidate->continuation_, predecessor->state_, candidate->state_);
            if (status != CTDSP_OK) {
                candidate->discardContinuation();
                return Offer{OfferStatus::historyPreparationFailed, nullptr, status};
            }
        }
        // A queued control-side candidate must not retain a binding to an
        // active graph that can retire before its next publication attempt.
        ctdsp_unbind_history_transfer(candidate->continuation_);
        return Offer{OfferStatus::busy, nullptr, CTDSP_OK, info, preparedHistory};
    };
    if (outstanding_ && outstanding_->phase == Publication::Phase::awaitingRetirement) return busy();
    PreparedRevision *obsolete = outstanding_ ? publicationPointer(outstanding_->token) : nullptr;
    const uintptr_t publication = publicationToken(candidate.get());
    if (outstanding_) {
        auto expected = outstanding_->token;
        if (!pending_.compare_exchange_strong(expected, publication, std::memory_order_acq_rel)) {
            return busy();
        }
    } else {
        assert(!pending_.load(std::memory_order_relaxed));
        pending_.store(publication, std::memory_order_release);
    }
    lastRevision_ = candidate->revision.number;
    outstanding_ = Publication{publication, candidate->revision};
    candidate.release();
    if (obsolete) obsolete->discardContinuation();
    return {obsolete ? OfferStatus::superseded : OfferStatus::accepted,
            std::unique_ptr<PreparedRevision>(obsolete), CTDSP_OK, info, preparedHistory};
}

Cancellation GraphHandoff::cancel(Revision revision) noexcept {
    if (!outstanding_ || !(outstanding_->revision == revision)) return {CancellationStatus::notFound, nullptr};
    // This is the cancellation/commit ordering point. A resolution already
    // chosen by processing stays truthful, even before its ack is published.
    const auto previous = flags_.fetch_or(cancellation, std::memory_order_acq_rel);
    if (previous & resolutionChosen) return {CancellationStatus::tooLate, nullptr};
    auto expected = outstanding_->token;
    if (pending_.compare_exchange_strong(expected, 0, std::memory_order_acq_rel)) {
        auto *withdrawn = publicationPointer(expected);
        withdrawn->discardContinuation();
        outstanding_.reset();
        flags_.fetch_and(~uint32_t(cancellation), std::memory_order_release);
        return {CancellationStatus::withdrawn, std::unique_ptr<PreparedRevision>(withdrawn)};
    }
    return {CancellationStatus::requested, nullptr};
}

std::unique_ptr<PreparedRevision> GraphHandoff::close() noexcept {
    flags_.fetch_or(closing, std::memory_order_acq_rel);
    acknowledgedActive_ = nullptr;
    auto *unclaimed = publicationPointer(pending_.exchange(0, std::memory_order_acq_rel));
    if (unclaimed) {
        unclaimed->discardContinuation();
        outstanding_.reset();
    }
    return std::unique_ptr<PreparedRevision>(unclaimed);
}

std::optional<Acknowledgement> GraphHandoff::collectAcknowledgement() noexcept {
    if (!acknowledgementReady_.load(std::memory_order_acquire)) return std::nullopt;
    assert(outstanding_ && outstanding_->revision == message_.revision);
    if ((message_.resolution == Resolution::applied || message_.resolution == Resolution::installed) && !isClosing()) {
        acknowledgedActive_ = publicationPointer(outstanding_->token);
    }
    ctdsp_destroy_history_transfer(std::exchange(message_.retiredContinuation, nullptr));
    Acknowledgement result{message_.revision, message_.resolution, message_.processingStatus,
                           message_.rendered, std::unique_ptr<PreparedRevision>(message_.retired), message_.retiring};
    message_.retired = nullptr;
    acknowledgementReady_.store(false, std::memory_order_relaxed);
    if (message_.retiring) outstanding_->phase = Publication::Phase::awaitingRetirement;
    else releasePublication();
    return result;
}

void GraphHandoff::releasePublication() noexcept {
    outstanding_.reset();
    // The next pending release is the consumer's acquire for all ack-slot reuse.
    flags_.fetch_and(~uint32_t(cancellation | resolutionChosen), std::memory_order_release);
}

std::unique_ptr<PreparedRevision> GraphHandoff::collectRetiredTail() noexcept {
    if (!outstanding_ || outstanding_->phase != Publication::Phase::awaitingRetirement) return nullptr;
    auto *retired = retiredTail_.exchange(nullptr, std::memory_order_acq_rel);
    if (!retired) return nullptr;
    releasePublication();
    return std::unique_ptr<PreparedRevision>(retired);
}

std::unique_ptr<PreparedRevision> GraphHandoff::collectStoppedGraph() noexcept {
    if (!isStopped()) return nullptr;
    return std::unique_ptr<PreparedRevision>(std::exchange(stoppedGraph_, nullptr));
}

TransitionStart GraphHandoff::beginTransition(ClaimPolicy policy) noexcept {
    if (candidate_ || flags_.load(std::memory_order_acquire) & (closing | cancellation)) return TransitionStart::noCandidate;
    auto publication = pending_.load(std::memory_order_acquire);
    if (!publication) return TransitionStart::noCandidate;
    if (policy == ClaimPolicy::controlBoundary && active_ && !isPristine(active_->state_)) {
        CTDSPStreamInfo info{};
        ctdsp_read_stream_info(active_->state_, &info);
        if (info.phase == CTDSP_STREAM_ACCEPTING) return TransitionStart::noCandidate;
    }
    // A newer publication gets its own admission check; do not inspect or claim
    // a different policy after checking this token. No unowned node is borrowed.
    if (!pending_.compare_exchange_strong(publication, 0, std::memory_order_acq_rel)) return TransitionStart::noCandidate;
    candidate_ = publicationPointer(publication);
    candidate_->nextFrame_ = active_ ? active_->nextFrame_ : firstFrame_;
    if (candidate_->continuation_) {
        const auto status = ctdsp_apply_history_transfer(candidate_->continuation_, active_->state_, candidate_->state_);
        if (status != CTDSP_OK) {
            resolveRejection(status);
            return TransitionStart::resolved;
        }
        candidate_->sourceEndFrame_ = active_->sourceEndFrame_;
    }
    return TransitionStart::ready;
}

CTDSPStatus GraphHandoff::processActive(const float *input, size_t inputCount, float *output,
                                      size_t outputCount, uint32_t frames) noexcept {
    if (isClosing() || !active_) return CTDSP_INVALID_ARGUMENT;
    return active_->process(input, inputCount, output, outputCount, frames);
}

CTDSPStatus GraphHandoff::processCandidate(const float *input, size_t inputCount, float *output,
                                         size_t outputCount, uint32_t frames) noexcept {
    if (!candidate_ || isClosing()) return CTDSP_INVALID_ARGUMENT;
    return candidate_->process(input, inputCount, output, outputCount, frames);
}

CTDSPStatus GraphHandoff::endActiveInput() noexcept {
    if (isClosing() || !active_) return CTDSP_INVALID_ARGUMENT;
    return active_->endInput();
}

CTDSPStatus GraphHandoff::resumeInput() noexcept {
    if (isClosing() || !active_) return CTDSP_INVALID_ARGUMENT;
    if (candidate_) {
        if (!active_->coversProgressOf(*candidate_) || !candidate_->coversProgressOf(*active_)) return CTDSP_INVALID_STATE;
        CTDSPStreamInfo a{}, b{};
        ctdsp_read_stream_info(active_->state_, &a);
        ctdsp_read_stream_info(candidate_->state_, &b);
        if (a.phase == CTDSP_STREAM_CANCELLED || a.phase == CTDSP_STREAM_FAULTED
            || b.phase == CTDSP_STREAM_CANCELLED || b.phase == CTDSP_STREAM_FAULTED) return CTDSP_INVALID_STATE;
        const auto boundary = std::max(active_->nextFrame_, candidate_->nextFrame_);
        active_->nextFrame_ = candidate_->nextFrame_ = boundary;
        const auto status = candidate_->resumeInput();
        if (status != CTDSP_OK) return status;
    }
    return active_->resumeInput();
}

CTDSPStatus GraphHandoff::resetInput() noexcept {
    if (isClosing() || !active_) return CTDSP_INVALID_STATE;
    if (retiring_) cancelRetiring();
    if (candidate_) {
        const auto boundary = std::max(active_->nextFrame_, candidate_->nextFrame_);
        active_->nextFrame_ = candidate_->nextFrame_ = boundary;
        const auto status = candidate_->reset();
        if (status != CTDSP_OK) return status;
    }
    return active_->reset();
}

CTDSPStatus GraphHandoff::outputComplete(bool candidate, bool *result) const noexcept {
    const auto revision = candidate ? candidate_ : active_;
    if (result) *result = false;
    if (isClosing() || !revision) return CTDSP_INVALID_STATE;
    return revision->outputComplete(result);
}

CTDSPStatus GraphHandoff::activeTailPeakBound(double *result) noexcept {
    if (isClosing() || !active_) return CTDSP_INVALID_STATE;
    return ctdsp_read_tail_peak_bound(active_->state_, result);
}

CTDSPStatus GraphHandoff::outputPeakLimits(bool candidate, double *result, size_t count) const noexcept {
    const auto revision = candidate ? candidate_ : active_;
    if (isClosing() || !revision) return CTDSP_INVALID_STATE;
    return ctdsp_read_output_peak_limits(revision->state_, result, count);
}

CTDSPStatus GraphHandoff::endCandidateInput() noexcept {
    if (!candidate_ || isClosing()) return CTDSP_INVALID_ARGUMENT;
    return candidate_->endInput();
}

CTDSPStatus GraphHandoff::drainActive(float *output, size_t outputCount, uint32_t frames, uint32_t *written) noexcept {
    if (written) *written = 0;
    if (isClosing() || !active_) return CTDSP_INVALID_ARGUMENT;
    return active_->drain(output, outputCount, frames, written);
}

CTDSPStatus GraphHandoff::drainCandidate(float *output, size_t outputCount, uint32_t frames, uint32_t *written) noexcept {
    if (written) *written = 0;
    if (!candidate_ || isClosing()) return CTDSP_INVALID_ARGUMENT;
    return candidate_->drain(output, outputCount, frames, written);
}

CTDSPStatus GraphHandoff::activeStreamInfo(CTDSPStreamInfo *result) const noexcept {
    return ctdsp_read_stream_info(active_ ? active_->state_ : nullptr, result);
}

CTDSPStatus GraphHandoff::candidateStreamInfo(CTDSPStreamInfo *result) const noexcept {
    return ctdsp_read_stream_info(candidate_ ? candidate_->state_ : nullptr, result);
}

bool GraphHandoff::candidateCancellationRequested() const noexcept {
    return candidate_ && (flags_.load(std::memory_order_acquire) & cancellation);
}

Completion GraphHandoff::installPrepared() noexcept {
    if (!candidate_) return Completion::noCandidate;
    const auto intent = flags_.load(std::memory_order_acquire);
    if (intent & closing) return resolveRejection(CTDSP_OK);
    if (intent & cancellation) return Completion::cancellationPending;
    if (candidate_->lastStatus_ != CTDSP_OK) return Completion::processingFailed;
    // Native counters include copied history. An unrendered candidate carrying
    // a live prefix cannot be installed later to replay an already drained tail.
    if (!isPristine(candidate_->state_)) return Completion::candidateNotPristine;
    if (active_) {
        CTDSPStreamInfo activeInfo{};
        ctdsp_read_stream_info(active_->state_, &activeInfo);
        if (activeInfo.phase != CTDSP_STREAM_DRAINED && !isPristine(active_->state_)) return Completion::activeStreamUnfinished;
    }
    return commitSelection(Resolution::installed, RetirementPolicy::discard);
}

bool GraphHandoff::candidateContinuesHistory() const noexcept {
    return candidate_ && candidate_->continuation_;
}

Completion GraphHandoff::installCompleted(RetirementPolicy retirement) noexcept {
    if (!candidate_) return Completion::noCandidate;
    const auto intent = flags_.load(std::memory_order_acquire);
    if (intent & closing) return resolveRejection(CTDSP_OK);
    if (intent & cancellation) return Completion::cancellationPending;
    bool complete = false;
    if (candidate_->lastStatus_ != CTDSP_OK || candidate_->outputComplete(&complete) != CTDSP_OK) return Completion::processingFailed;
    if (!complete) return Completion::activeStreamUnfinished;
    if (active_ && !candidate_->coversProgressOf(*active_)) return Completion::candidateBehindActive;
    return commitSelection(candidate_->rendered_ ? Resolution::applied : Resolution::installed, retirement);
}

Completion GraphHandoff::completeTransition(RetirementPolicy retirement) noexcept {
    if (!candidate_) return Completion::noCandidate;
    const auto intent = flags_.load(std::memory_order_acquire);
    if (intent & closing) return resolveRejection(CTDSP_OK);
    if (intent & cancellation) return Completion::cancellationPending;
    if (!candidate_->rendered_) return Completion::notRendered;
    if (candidate_->lastStatus_ != CTDSP_OK) return Completion::processingFailed;
    if (active_ && !candidate_->coversProgressOf(*active_)) return Completion::candidateBehindActive;
    return commitSelection(Resolution::applied, retirement);
}

Completion GraphHandoff::commitSelection(Resolution outcome, RetirementPolicy retirement) noexcept {
    bool preserveTail = false;
    if (active_ && retirement == RetirementPolicy::preserveTail) {
        CTDSPStreamInfo info{};
        ctdsp_read_stream_info(active_->state_, &info);
        if (info.phase == CTDSP_STREAM_ACCEPTING) return Completion::previousInputNotEnded;
        if (info.phase != CTDSP_STREAM_DRAINING && info.phase != CTDSP_STREAM_DRAINED) return Completion::processingFailed;
        preserveTail = info.phase == CTDSP_STREAM_DRAINING;
    }
    // A cancellation must win before commit is chosen. If it does, retain the
    // candidate for the caller's rollback, including when cancellation arrives
    // after the last mixed sample but before this ordering point.
    uint32_t expected = 0;
    if (!flags_.compare_exchange_strong(expected, resolutionChosen, std::memory_order_acq_rel)) {
        assert(expected & (closing | cancellation));
        return expected & closing ? resolveRejection(CTDSP_OK) : Completion::cancellationPending;
    }
    return publishResolution(outcome, CTDSP_OK, preserveTail);
}

CTDSPStatus GraphHandoff::drainRetiring(float *output, size_t outputCount, uint32_t frames, uint32_t *written) noexcept {
    if (written) *written = 0;
    if (isClosing() || !retiring_) return CTDSP_INVALID_ARGUMENT;
    assert(active_ && active_->nextFrame_ >= retiring_->nextFrame_);
    CTDSPStreamInfo previous{}, selected{};
    ctdsp_read_stream_info(retiring_->state_, &previous);
    ctdsp_read_stream_info(active_->state_, &selected);
    const uint64_t count = previous.tail_kind == CTDSP_TAIL_FINITE
        ? std::min(uint64_t(frames), previous.remaining_tail_frames) : frames;
    if (selected.phase != CTDSP_STREAM_DRAINED && count > active_->nextFrame_ - retiring_->nextFrame_) return CTDSP_INVALID_STATE;
    const auto status = retiring_->drain(output, outputCount, frames, written);
    if (status != CTDSP_OK) return status;
    if (selected.phase == CTDSP_STREAM_DRAINED) active_->nextFrame_ = std::max(active_->nextFrame_, retiring_->nextFrame_);
    return CTDSP_OK;
}

CTDSPStatus GraphHandoff::completeRetiring(bool *completed) noexcept {
    if (!completed) return CTDSP_INVALID_ARGUMENT;
    *completed = false;
    if (isClosing() || !retiring_) return CTDSP_INVALID_STATE;
    if (retiring_->lastStatus_ != CTDSP_OK) return retiring_->lastStatus_;
    const auto status = retiring_->outputComplete(completed);
    if (status == CTDSP_OK && *completed) publishRetirement();
    return status;
}

CTDSPStatus GraphHandoff::retiringStreamInfo(CTDSPStreamInfo *result) const noexcept {
    return ctdsp_read_stream_info(retiring_ ? retiring_->state_ : nullptr, result);
}

void GraphHandoff::publishRetirement() noexcept {
    assert(retiring_ && !retiredTail_.load(std::memory_order_relaxed));
    retiredTail_.store(std::exchange(retiring_, nullptr), std::memory_order_release);
}

bool GraphHandoff::cancelRetiring() noexcept {
    if (!retiring_ || isClosing()) return false;
    ctdsp_cancel(retiring_->state_);
    publishRetirement();
    return true;
}

Completion GraphHandoff::rejectTransition(CTDSPStatus reason) noexcept {
    if (!candidate_) return Completion::noCandidate;
    return resolveRejection(reason);
}

Completion GraphHandoff::resolveRejection(CTDSPStatus reason) noexcept {
    assert(candidate_ && !acknowledgementReady_.load(std::memory_order_relaxed));
    const auto previous = flags_.fetch_or(resolutionChosen, std::memory_order_acq_rel);
    assert(!(previous & resolutionChosen));
    Resolution outcome = Resolution::rejected;
    if (previous & closing) outcome = Resolution::closed;
    else if (previous & cancellation) outcome = Resolution::cancelled;
    return publishResolution(outcome, reason);
}

Completion GraphHandoff::publishResolution(Resolution outcome, CTDSPStatus reason, bool preserveTail) noexcept {
    assert(candidate_ && !acknowledgementReady_.load(std::memory_order_relaxed));
    // Disable application on processing; only control destroys the spent plan.
    // Its immutable inspection/destruction never dereferences retired states.
    message_ = {candidate_->revision, outcome, reason, candidate_->rendered_, nullptr,
                std::exchange(candidate_->continuation_, nullptr), std::nullopt};
    if (outcome == Resolution::applied || outcome == Resolution::installed) {
        // Keep the selected output's logical position even when its shorter
        // finite tail has completed. The acknowledgement above remains actual
        // PCM evidence; later fresh revisions must never bind behind this point.
        if (active_) candidate_->nextFrame_ = std::max(candidate_->nextFrame_, active_->nextFrame_);
        if (preserveTail) {
            assert(active_ && !retiring_ && !retiredTail_.load(std::memory_order_relaxed));
            retiring_ = active_;
            message_.retiring = retiring_->revision;
        } else message_.retired = active_;
        active_ = candidate_;
    } else {
        if (active_ && active_->coversProgressOf(*candidate_)) {
            active_->nextFrame_ = std::max(active_->nextFrame_, candidate_->nextFrame_);
        }
        message_.retired = candidate_;
    }
    candidate_ = nullptr;
    acknowledgementReady_.store(true, std::memory_order_release);
    return Completion::resolved;
}

bool GraphHandoff::stopProcessing() noexcept {
    const auto state = flags_.load(std::memory_order_acquire);
    if (!(state & closing) || state & stopped) return false;
    if (candidate_) resolveRejection(CTDSP_OK);
    if (retiring_) {
        ctdsp_cancel(retiring_->state_);
        publishRetirement();
    }
    stoppedGraph_ = std::exchange(active_, nullptr);
    flags_.fetch_or(stopped, std::memory_order_release);
    return true;
}

std::optional<Revision> GraphHandoff::activeRevision() const noexcept {
    return active_ ? std::optional<Revision>(active_->revision) : std::nullopt;
}

std::optional<Revision> GraphHandoff::candidateRevision() const noexcept {
    return candidate_ ? std::optional<Revision>(candidate_->revision) : std::nullopt;
}

std::optional<Revision> GraphHandoff::retiringRevision() const noexcept {
    return retiring_ ? std::optional<Revision>(retiring_->revision) : std::nullopt;
}

bool GraphHandoff::isClosing() const noexcept { return flags_.load(std::memory_order_acquire) & closing; }
bool GraphHandoff::isStopped() const noexcept { return flags_.load(std::memory_order_acquire) & stopped; }

} // namespace ctdsp
