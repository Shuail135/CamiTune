#ifndef CTDSP_GRAPH_HANDOFF_H
#define CTDSP_GRAPH_HANDOFF_H

#include "CTDSPCore.h"
#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <optional>
#include <utility>

namespace ctdsp {

using Generation = std::array<uint64_t, 2>;

struct Revision {
    Generation generation;
    uint64_t number;
    bool operator==(const Revision &other) const noexcept {
        return generation == other.generation && number == other.number;
    }
};

struct StreamFormat {
    uint32_t sampleRate, inputChannels, outputChannels, maximumFrames;
    bool operator==(const StreamFormat &other) const noexcept {
        return sampleRate == other.sampleRate && inputChannels == other.inputChannels
            && outputChannels == other.outputChannels && maximumFrames == other.maximumFrames;
    }
};

struct RenderedInterval {
    uint64_t firstFrame, endFrame;
};

/// Owns one fresh native state and immutable provenance. Only GraphHandoff can
/// render it. Construction/destruction belong to preparation/control, never PCM.
class PreparedRevision final {
public:
    // Only success consumes state. Adoption allocates one ownership node; it
    // never prepares, resets, copies or destroys the caller's native state.
    static std::pair<CTDSPStatus, std::unique_ptr<PreparedRevision>> adopt(
        Revision revision, uint32_t sampleRate, CTDSPState *&state) noexcept;
    ~PreparedRevision();
    PreparedRevision(const PreparedRevision &) = delete;
    PreparedRevision &operator=(const PreparedRevision &) = delete;
    const Revision revision;
    const StreamFormat format;

private:
    friend class GraphHandoff;
    PreparedRevision(Revision id, uint32_t rate, CTDSPFormat format, CTDSPState *state) noexcept;
    CTDSPStatus process(const float *input, size_t inputCount, float *output,
                        size_t outputCount, uint32_t frames) noexcept;
    CTDSPStatus endInput() noexcept;
    CTDSPStatus resumeInput() noexcept;
    CTDSPStatus reset() noexcept;
    CTDSPStatus drain(float *output, size_t outputCount, uint32_t frames, uint32_t *written) noexcept;
    CTDSPStatus recordRender(CTDSPStatus status, uint32_t frames) noexcept;
    CTDSPStatus outputComplete(bool *result) const noexcept;
    bool coversProgressOf(const PreparedRevision &other) const noexcept;
    void discardContinuation() noexcept;
    CTDSPState *const state_;
    CTDSPHistoryTransfer *continuation_ = nullptr;
    uint64_t nextFrame_ = 0;
    // Logical source end, not another stream phase. The C state owns completion.
    // Unlike total rendered frames, this coordinate excludes every tail frame.
    std::optional<uint64_t> sourceEndFrame_;
    std::optional<RenderedInterval> rendered_;
    CTDSPStatus lastStatus_ = CTDSP_OK;
};

enum class HistoryPolicy { fresh, continueActive };
enum class OfferStatus { accepted, superseded, busy, closed, wrongGeneration, staleRevision, incompatibleFormat, historyPreparationFailed };
struct Offer {
    OfferStatus status;
    std::unique_ptr<PreparedRevision> superseded;
    CTDSPStatus preparationStatus = CTDSP_OK;
    CTDSPHistoryTransferInfo history{};
    // A busy caller still owns the candidate and this unbound plan allocation.
    // Reoffering validates its next source without another allocation.
    bool historyPrepared = false;
};

enum class CancellationStatus { notFound, withdrawn, requested, tooLate };
struct Cancellation {
    CancellationStatus status;
    std::unique_ptr<PreparedRevision> withdrawn;
};

enum class Resolution { applied, rejected, cancelled, closed, installed };
enum class RetirementPolicy { discard, preserveTail };
struct Acknowledgement {
    Revision revision;
    Resolution resolution;
    CTDSPStatus processingStatus;
    std::optional<RenderedInterval> rendered;
    // For applied/installed: the previous graph. Otherwise: the rejected candidate.
    // The consumer has permanently relinquished it before publishing this ack.
    std::unique_ptr<PreparedRevision> retired;
    // Activation is acknowledged now; this previous revision stays with PCM
    // until its drain completes or the caller explicitly cancels its tail.
    std::optional<Revision> retiring;
};

enum class Completion { resolved, noCandidate, notRendered, processingFailed, candidateBehindActive, cancellationPending,
                        previousInputNotEnded, candidateNotPristine, activeStreamUnfinished };
enum class TransitionStart { noCandidate, ready, resolved };
enum class ClaimPolicy { renderBoundary, controlBoundary };

/// Revision ownership protocol; the adapter owns its transition waveform.
/// One serial control owner calls offer/cancel/close/collect. One serial PCM
/// owner calls begin/process/complete/stop. Owners may run concurrently. They
/// must keep this object alive until stop is acknowledged and join callbacks
/// before destruction. No graph/queue/thread is acquired by construction.
///
/// One outstanding revision bounds both publication and its acknowledgement.
/// Unclaimed revisions coalesce with one CAS. Once claimed, control receives
/// explicit backpressure until it collects the resolution and any protected
/// retirement. Activation acknowledgement does not wait for that tail. There is no polling
/// timer: callers signal their existing worker/control executor on publication,
/// cancellation, completion and stop, never for every ordinary PCM block.
class GraphHandoff final {
public:
    GraphHandoff(Generation generation, StreamFormat format, uint64_t firstFrame = 0) noexcept;
    ~GraphHandoff();
    GraphHandoff(const GraphHandoff &) = delete;
    GraphHandoff &operator=(const GraphHandoff &) = delete;

    // CONTROL. Ownership remains with caller on rejection/backpressure.
    // Continuation is prepared here while the acknowledged source is still
    // owned by this handoff. Incompatibility never falls back to fresh history.
    Offer offer(std::unique_ptr<PreparedRevision> &candidate, HistoryPolicy history) noexcept;
    Cancellation cancel(Revision revision) noexcept;
    std::unique_ptr<PreparedRevision> close() noexcept;
    std::optional<Acknowledgement> collectAcknowledgement() noexcept;
    // Collect after the activation acknowledgement. Until this succeeds, new
    // publication stays busy. No second processing transition can share its slot.
    std::unique_ptr<PreparedRevision> collectRetiredTail() noexcept;
    std::unique_ptr<PreparedRevision> collectStoppedGraph() noexcept;

    // PROCESSING. Begin binds the candidate to the current logical PCM boundary.
    // The caller owns transition/output selection and may render both states for
    // several blocks. Complete requires actual successful candidate PCM and
    // coverage of the old state's progress. A fully drained candidate also
    // covers later silence when both sources ended at the same logical frame.
    // Resolution retains that logical position without inventing rendered PCM.
    // It publishes the new active pointer and its ack together. The explicit
    // policy either relinquishes the old state or protects its ended tail. These calls allocate
    // and destroy nothing, take no mutex and never wait for control.
    // Copy failure resolves through the existing acknowledgement and returns
    // resolved. Continuation retains the producer's logical END even when
    // claimed during a tail. Copied counters are never candidate render evidence.
    TransitionStart beginTransition(ClaimPolicy policy = ClaimPolicy::renderBoundary) noexcept;
    // Install an untouched candidate before starting input, or after the active
    // finite stream is fully drained. An accepting graph that has rendered, or
    // any unfinished tail, still requires an explicit live transition. Silence
    // and absent callbacks are not readiness evidence. The installed resolution
    // has no rendered interval and uses the same bounded acknowledgement slot.
    Completion installPrepared() noexcept;
    // Select a completed candidate after the adapter finishes its output fade.
    // This carries no invented render evidence when the candidate emitted none.
    Completion installCompleted(RetirementPolicy retirement) noexcept;
    bool candidateContinuesHistory() const noexcept;
    CTDSPStatus processActive(const float *input, size_t inputCount, float *output,
                             size_t outputCount, uint32_t frames) noexcept;
    CTDSPStatus processCandidate(const float *input, size_t inputCount, float *output,
                                size_t outputCount, uint32_t frames) noexcept;
    // Completion belongs to each revision's existing C state. Ending an old
    // graph does not end its replacement or seal publication. Drain advances
    // the same logical timeline by the actual written count; a zero-frame
    // result supplies no new activation evidence. Close/stop cancels immediately.
    CTDSPStatus endActiveInput() noexcept;
    CTDSPStatus resumeInput() noexcept;
    CTDSPStatus resetInput() noexcept;
    CTDSPStatus outputComplete(bool candidate, bool *result) const noexcept;
    CTDSPStatus activeTailPeakBound(double *result) noexcept;
    CTDSPStatus outputPeakLimits(bool candidate, double *result, size_t count) const noexcept;
    CTDSPStatus endCandidateInput() noexcept;
    CTDSPStatus drainActive(float *output, size_t outputCount, uint32_t frames, uint32_t *written) noexcept;
    CTDSPStatus drainCandidate(float *output, size_t outputCount, uint32_t frames, uint32_t *written) noexcept;
    CTDSPStatus activeStreamInfo(CTDSPStreamInfo *result) const noexcept;
    CTDSPStatus candidateStreamInfo(CTDSPStreamInfo *result) const noexcept;
    // Cancellation revokes activation but retains both renderable states until
    // the caller finishes its output rollback and rejects the candidate. A
    // cancellation winning the final commit race returns cancellationPending;
    // it cannot retire the candidate while its output is still selected.
    bool candidateCancellationRequested() const noexcept;
    Completion completeTransition(RetirementPolicy retirement) noexcept;
    // Render the active graph first. Its actual progress covers this drain,
    // unless it has fully completed and contributes known zeros. In that case
    // old-tail PCM advances the selected timeline, never its actual-render ack.
    // Drain retains storage until the caller confirms downstream acceptance.
    CTDSPStatus drainRetiring(float *output, size_t outputCount, uint32_t frames, uint32_t *written) noexcept;
    CTDSPStatus retiringStreamInfo(CTDSPStreamInfo *result) const noexcept;
    CTDSPStatus completeRetiring(bool *completed) noexcept;
    bool cancelRetiring() noexcept;
    // CTDSP_OK means deliberate rejection without a DSP failure, including
    // completion of a requested cancellation. Close/stop still retires at once.
    Completion rejectTransition(CTDSPStatus reason) noexcept;
    bool stopProcessing() noexcept;
    std::optional<Revision> activeRevision() const noexcept;
    std::optional<Revision> candidateRevision() const noexcept;
    std::optional<Revision> retiringRevision() const noexcept;

    // Cross-owner observations contain no mutable DSP fields.
    bool isClosing() const noexcept;
    bool isStopped() const noexcept;

private:
    enum Flags : uint32_t { closing = 1, cancellation = 2, resolutionChosen = 4, stopped = 8 };
    struct Message {
        Revision revision{};
        Resolution resolution = Resolution::rejected;
        CTDSPStatus processingStatus = CTDSP_OK;
        std::optional<RenderedInterval> rendered;
        PreparedRevision *retired = nullptr;
        CTDSPHistoryTransfer *retiredContinuation = nullptr;
        std::optional<Revision> retiring;
    };
    struct Publication {
        uintptr_t token;
        Revision revision;
        enum class Phase { awaitingAcknowledgement, awaitingRetirement } phase = Phase::awaitingAcknowledgement;
    };
    Completion resolveRejection(CTDSPStatus reason) noexcept;
    Completion commitSelection(Resolution outcome, RetirementPolicy retirement) noexcept;
    Completion publishResolution(Resolution outcome, CTDSPStatus reason, bool preserveTail = false) noexcept;
    void publishRetirement() noexcept;
    void releasePublication() noexcept;
    static uintptr_t publicationToken(PreparedRevision *revision) noexcept;
    static PreparedRevision *publicationPointer(uintptr_t token) noexcept;

    const Generation generation_;
    const StreamFormat format_;
    const uint64_t firstFrame_;
    std::atomic<uint32_t> flags_{0};
    // The low bit describes continuation in the same atomic publication as its
    // pointer. Processing can defer a paused edit without dereferencing a node
    // that control is still allowed to supersede and destroy.
    std::atomic<uintptr_t> pending_{0};
    std::atomic<bool> acknowledgementReady_{false};
    Message message_;
    // One ownership mailbox, separate from activation's acknowledgement. A
    // release publishes a permanently relinquished graph, not mutable DSP state.
    std::atomic<PreparedRevision *> retiredTail_{nullptr};

    // CONTROL-only. Identity is a value: shutdown can release the newly active
    // graph before control collects its still-pending acknowledgement.
    std::optional<Publication> outstanding_;
    uint64_t lastRevision_ = 0;
    // Borrow of the last acknowledged selected graph. Before the next collection
    // it remains active, in the acknowledgement slot or protected until retirement
    // collection. Only serial control can release it. Close disables the borrow.
    PreparedRevision *acknowledgedActive_ = nullptr;

    // PROCESSING-only until the corresponding release publication.
    PreparedRevision *active_ = nullptr;
    PreparedRevision *candidate_ = nullptr;
    PreparedRevision *retiring_ = nullptr;
    PreparedRevision *stoppedGraph_ = nullptr;
};

} // namespace ctdsp
#endif
