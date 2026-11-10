#ifndef CTDSP_HANDOFF_C_H
#define CTDSP_HANDOFF_C_H

#include "CTDSPCore.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CTDSPPreparedRevision CTDSPPreparedRevision;
typedef struct CTDSPHandoff CTDSPHandoff;
typedef struct { uint64_t first, second; } CTDSPGeneration;
typedef struct { CTDSPGeneration generation; uint64_t number; } CTDSPRevision;
typedef struct {
    uint32_t sample_rate, input_channels, output_channels, maximum_frames;
} CTDSPStreamFormat;

/* Adoption consumes *state only on success and always initializes *result.
 * Channel/frame dimensions come from the C state; the rate comes from the
 * graph that supplied its coefficients. Only freshly prepared or explicitly
 * reset state may be adopted. Failure leaves the caller responsible for it.
 * No C++ types or exceptions cross this ABI.
 */
CTDSPStatus ctdsp_revision_adopt(CTDSPState **state, CTDSPRevision revision,
                                uint32_t sample_rate, CTDSPPreparedRevision **result);
void ctdsp_revision_destroy(CTDSPPreparedRevision *revision);
CTDSPRevision ctdsp_revision_identity(const CTDSPPreparedRevision *revision);

typedef enum {
    CTDSP_OFFER_ACCEPTED, CTDSP_OFFER_SUPERSEDED, CTDSP_OFFER_BUSY,
    CTDSP_OFFER_CLOSED, CTDSP_OFFER_WRONG_GENERATION, CTDSP_OFFER_STALE_REVISION,
    CTDSP_OFFER_INCOMPATIBLE_FORMAT, CTDSP_OFFER_HISTORY_PREPARATION_FAILED, CTDSP_OFFER_INVALID_ARGUMENT
} CTDSPOfferStatus;
typedef enum { CTDSP_HISTORY_FRESH, CTDSP_HISTORY_CONTINUE_ACTIVE } CTDSPHistoryPolicy;
typedef struct {
    CTDSPOfferStatus status;
    CTDSPPreparedRevision *superseded;
    CTDSPStatus preparation_status;
    CTDSPHistoryTransferInfo history;
    bool history_prepared;
} CTDSPOfferResult;

typedef enum {
    CTDSP_CANCEL_NOT_FOUND, CTDSP_CANCEL_WITHDRAWN, CTDSP_CANCEL_REQUESTED, CTDSP_CANCEL_TOO_LATE
} CTDSPCancellationStatus;
typedef struct {
    CTDSPCancellationStatus status;
    CTDSPPreparedRevision *withdrawn;
} CTDSPCancellationResult;

typedef enum {
    CTDSP_REVISION_APPLIED, CTDSP_REVISION_REJECTED, CTDSP_REVISION_CANCELLED, CTDSP_REVISION_CLOSED,
    CTDSP_REVISION_INSTALLED
} CTDSPResolution;
typedef enum { CTDSP_RETIRE_PREVIOUS, CTDSP_PRESERVE_PREVIOUS_TAIL } CTDSPRetirementPolicy;
typedef struct {
    bool available;
    CTDSPRevision revision;
    CTDSPResolution resolution;
    CTDSPStatus processing_status;
    bool has_rendered_interval;
    uint64_t first_frame, end_frame;
    CTDSPPreparedRevision *retired;
    bool has_retiring_revision;
    CTDSPRevision retiring_revision;
} CTDSPAcknowledgement;

typedef enum {
    CTDSP_TRANSITION_RESOLVED, CTDSP_TRANSITION_NO_CANDIDATE,
    CTDSP_TRANSITION_NOT_RENDERED, CTDSP_TRANSITION_PROCESSING_FAILED,
    CTDSP_TRANSITION_CANDIDATE_BEHIND_ACTIVE, CTDSP_TRANSITION_CANCELLATION_PENDING,
    CTDSP_TRANSITION_PREVIOUS_INPUT_NOT_ENDED, CTDSP_TRANSITION_INVALID_ARGUMENT,
    CTDSP_TRANSITION_CANDIDATE_NOT_PRISTINE, CTDSP_TRANSITION_ACTIVE_STREAM_UNFINISHED
} CTDSPCompletion;
typedef enum { CTDSP_BEGIN_NO_CANDIDATE, CTDSP_BEGIN_READY, CTDSP_BEGIN_RESOLVED } CTDSPTransitionStart;

/* One serial control owner and one serial processing owner may run concurrently.
 * Except create/destroy, all handoff arguments must be live, nonnull handles.
 * Control keeps the handle alive, seals it, joins processing after its stop,
 * and destroys it on control. Stop alone is not callback joining.
 * Every returned revision pointer transfers ownership to control, which must
 * destroy it. Processing never releases native storage or waits on control.
 */
CTDSPStatus ctdsp_handoff_create(CTDSPGeneration generation, CTDSPStreamFormat format,
                                uint64_t first_frame, CTDSPHandoff **result);
void ctdsp_handoff_destroy(CTDSPHandoff *handoff);

/* CONTROL. Offer clears *candidate only when ownership was accepted. A busy
 * or rejected offer leaves it intact. Returned superseded/withdrawn/retired
 * states must be disposed outside the processing owner.
 */
/* Continue-active requires an acknowledged source and prepares its comparison
 * before publication. The returned history info describes an admitted copy.
 * Failure leaves ownership intact; there is no automatic fresh-history fallback.
 */
CTDSPOfferResult ctdsp_handoff_offer(CTDSPHandoff *handoff, CTDSPPreparedRevision **candidate, CTDSPHistoryPolicy history);
CTDSPCancellationResult ctdsp_handoff_cancel(CTDSPHandoff *handoff, CTDSPRevision revision);
CTDSPPreparedRevision *ctdsp_handoff_close(CTDSPHandoff *handoff);
CTDSPAcknowledgement ctdsp_handoff_collect_acknowledgement(CTDSPHandoff *handoff);
/* Collect after activation acknowledgement. Publication remains busy until the
 * protected tail completes or is cancelled and this control collection succeeds.
 */
CTDSPPreparedRevision *ctdsp_handoff_collect_retired_tail(CTDSPHandoff *handoff);
CTDSPPreparedRevision *ctdsp_handoff_collect_stopped(CTDSPHandoff *handoff);

/* PROCESSING. Borrowed samples and actual successful render evidence retain
 * the C++ protocol's semantics; the caller selects transition/output policy.
 */
/* A continuation copy uses the latest active history at this boundary. Failure
 * returns RESOLVED and publishes an acknowledgement for control collection.
 * The producer's phase and logical END accompany the latest histories.
 * Successful copying alone cannot satisfy actual candidate-render evidence.
 */
CTDSPTransitionStart ctdsp_handoff_begin(CTDSPHandoff *handoff);
/* PROCESSING control boundary with no source interval to render. An
 * accepting stream with prior history stays unclaimed, so control may still
 * supersede its prepared revision while the producer supplies neither PCM nor
 * END. Pristine and ended work can resolve immediately.
 * The ordinary begin call claims at the next actual rendering boundary.
 */
CTDSPTransitionStart ctdsp_handoff_begin_control(CTDSPHandoff *handoff);
/* PROCESSING. Install a claimed, untouched accepting candidate without PCM.
 * The active graph must have received no input or completed its entire finite
 * stream. Silence, a paused producer and a quiet recursive tail do not qualify.
 * INSTALLED uses the existing acknowledgement slot and has no rendered interval;
 * APPLIED still requires actual PCM through complete. Cancellation/close share
 * the same commit ordering point. Callers wake their serial owner for this work;
 * no PCM callback, synthetic sample, polling timer or second worker is required.
 */
CTDSPCompletion ctdsp_handoff_install_prepared(CTDSPHandoff *handoff);
CTDSPStatus ctdsp_handoff_process_active(CTDSPHandoff *handoff, const float *input, size_t input_count,
                                        float *output, size_t output_count, uint32_t frames);
CTDSPStatus ctdsp_handoff_process_candidate(CTDSPHandoff *handoff, const float *input, size_t input_count,
                                           float *output, size_t output_count, uint32_t frames);
/* Each revision retains its own source/end/drain phase and histories. Ending
 * active input permits its tail while a candidate continues receiving source.
 * Drain follows CTDSPCore's partial-final-write and recursive-tail contracts,
 * and advances activation's logical interval only by actual rendered frames.
 * Empty drain is not activation evidence. These are PROCESSING-only calls;
 * stream info is not a cross-owner snapshot. Close/stop remains immediate.
 */
CTDSPStatus ctdsp_handoff_end_active_input(CTDSPHandoff *handoff);
/* Resumption and explicit delivery discontinuity apply to both transition
 * lanes. Resumption aligns a finite completed lane only with proof of the same source
 * END; reset clears both histories. Neither rewinds the logical position.
 * During protected retirement, resume affects the selected graph only. Reset
 * cancels the retired tail as part of the explicit source discontinuity.
 */
CTDSPStatus ctdsp_handoff_resume_input(CTDSPHandoff *handoff);
CTDSPStatus ctdsp_handoff_reset_input(CTDSPHandoff *handoff);
/* Accepting input is never complete. Finite completion requires its full span;
 * recursive completion requires a certified future range rounding to Float32
 * zero. The stream's phase and histories remain available for resumption.
 */
CTDSPStatus ctdsp_handoff_output_complete(CTDSPHandoff *handoff, bool candidate, bool *result);
bool ctdsp_handoff_candidate_continues_history(CTDSPHandoff *handoff);
/* After selecting its completed output, install without inventing PCM. An
 * actual interval, if present, retains APPLIED; otherwise this is INSTALLED.
 */
CTDSPCompletion ctdsp_handoff_install_completed(CTDSPHandoff *handoff, CTDSPRetirementPolicy retirement);
CTDSPStatus ctdsp_handoff_output_peak_limits(CTDSPHandoff *handoff, bool candidate, double *result, size_t count);
CTDSPStatus ctdsp_handoff_active_tail_peak_bound(CTDSPHandoff *handoff, double *result);
CTDSPStatus ctdsp_handoff_end_candidate_input(CTDSPHandoff *handoff);
CTDSPStatus ctdsp_handoff_drain_active(CTDSPHandoff *handoff, float *output, size_t output_count,
                                      uint32_t frames, uint32_t *written);
CTDSPStatus ctdsp_handoff_drain_candidate(CTDSPHandoff *handoff, float *output, size_t output_count,
                                         uint32_t frames, uint32_t *written);
CTDSPStatus ctdsp_handoff_active_stream_info(CTDSPHandoff *handoff, CTDSPStreamInfo *result);
CTDSPStatus ctdsp_handoff_candidate_stream_info(CTDSPHandoff *handoff, CTDSPStreamInfo *result);
/* PROCESSING. Cancellation revokes activation, but render/end/drain remain
 * available until processing rejects after selecting the old output again.
 * A cancellation winning complete's commit race returns CANCELLATION_PENDING
 * without acknowledging or relinquishing either state. Close stops immediately.
 */
bool ctdsp_handoff_candidate_cancellation_requested(CTDSPHandoff *handoff);
/* Actual successful PCM is required. A fully drained candidate may cover the
 * old graph's later tail frames when both sources ended at the same logical
 * frame. Resolution retains the selected logical position, while the returned
 * rendered interval counts only native PCM, never implied completion zeros.
 */
/* Preserving a previous tail requires ended input. Acknowledgement identifies
 * that retained revision without transferring it to control. Recursive tails
 * require an explicit cancellation policy; no silence threshold retires them.
 */
CTDSPCompletion ctdsp_handoff_complete(CTDSPHandoff *handoff, CTDSPRetirementPolicy retirement);
/* Process/drain active first. Retiring PCM cannot run ahead of its progress
 * unless active is fully drained. Old-tail output then advances only the logical
 * boundary, never the candidate's actual-PCM acknowledgement. Drain retains the
 * old revision until complete_retiring confirms downstream output acceptance.
 */
CTDSPStatus ctdsp_handoff_drain_retiring(CTDSPHandoff *handoff, float *output, size_t output_count,
                                       uint32_t frames, uint32_t *written);
CTDSPStatus ctdsp_handoff_retiring_stream_info(CTDSPHandoff *handoff, CTDSPStreamInfo *result);
/* PROCESSING, after accepting the rendered retiring interval downstream.
 * Publish retirement only for a fully drained finite stream or a certified
 * future output that rounds to Float32 zero. An unfinished tail returns OK and
 * false without releasing it. No cancellation or guessed deadline is inferred.
 */
CTDSPStatus ctdsp_handoff_complete_retiring(CTDSPHandoff *handoff, bool *completed);
bool ctdsp_handoff_cancel_retiring(CTDSPHandoff *handoff);
bool ctdsp_handoff_retiring_revision(CTDSPHandoff *handoff, CTDSPRevision *result);
/* OK permits deliberate rejection or completed rollback without a DSP error. */
CTDSPCompletion ctdsp_handoff_reject(CTDSPHandoff *handoff, CTDSPStatus reason);
bool ctdsp_handoff_stop(CTDSPHandoff *handoff);
bool ctdsp_handoff_active_revision(CTDSPHandoff *handoff, CTDSPRevision *result);

/* Cross-owner snapshots contain no mutable DSP fields. */
bool ctdsp_handoff_is_closing(CTDSPHandoff *handoff);
bool ctdsp_handoff_is_stopped(CTDSPHandoff *handoff);

#ifdef __cplusplus
}
#endif
#endif
