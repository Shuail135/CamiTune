#ifndef CTDSP_CORE_H
#define CTDSP_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One owner must serialize process/reset/counters/destroy.
 * No hardware, queues, threads or Swift ownership cross this boundary.
 * Preparation copies every descriptor; processing borrows only sample buffers.
 */
typedef struct CTDSPState CTDSPState;

typedef enum {
    CTDSP_OK = 0,
    CTDSP_INVALID_ARGUMENT = 1,
    CTDSP_UNSUPPORTED_OPERATION = 2,
    CTDSP_ALLOCATION_FAILED = 3,
    CTDSP_NONFINITE_INPUT = 4,
    CTDSP_NUMERICAL_FAILURE = 5,
    CTDSP_RESET_REQUIRED = 6,
    CTDSP_INTERNAL_ERROR = 7,
    CTDSP_RESOURCE_LIMIT = 8,
    CTDSP_INVALID_STATE = 9,
    CTDSP_INCOMPATIBLE_HISTORY = 10
} CTDSPStatus;

enum {
    CTDSP_MAXIMUM_INPUT_CHANNELS = 32,
    CTDSP_MAXIMUM_OUTPUT_CHANNELS = 256,
    CTDSP_MAXIMUM_FRAMES = 16384,
    CTDSP_MAXIMUM_OPERATIONS = 4096,
    CTDSP_MAXIMUM_TOTAL_FIR_COEFFICIENTS = 4194304,
    CTDSP_MAXIMUM_PREPARED_BYTES = 256 * 1024 * 1024
};

typedef enum {
    CTDSP_GAIN = 1,
    CTDSP_BIQUAD = 2,
    CTDSP_HARD_LIMITER = 3,
    CTDSP_SOFT_LIMITER = 4,
    CTDSP_MIXER = 5,
    CTDSP_FIR = 6,
    CTDSP_INTEGER_DELAY = 7
} CTDSPOperationKind;

typedef enum {
    CTDSP_FIR_UNIFORM = 0,
    CTDSP_FIR_LARGER_TAILS = 1
} CTDSPFIRPartitioning;

typedef struct {
    const double *coefficients;
    size_t coefficient_count;
    /* Explicit configured base quantum, 32..2048, power of two. It does not
     * constrain call sizes or change the sample timeline. Initial coefficients
     * use direct convolution; tail sections use base or base/8x/64x FFT blocks.
     */
    uint32_t base_quantum;
    uint32_t partitioning;
} CTDSPFIR;

typedef struct {
    uint32_t source;
    uint32_t destination;
    double gain;
} CTDSPConnection;

typedef struct {
    uint32_t kind;
    uint32_t channel;
    /* gain: parameters[0] = linear gain (zero mutes).
     * biquad: normalized b0, b1, b2, a1, a2; one state per occurrence.
     * limiter: parameters[0] = positive linear ceiling <= 1.
     * mixer: connections are accumulated in the supplied order, into a cleared
     * output bus. Unmapped destinations are zero. It ignores channel/parameters.
     */
    double parameters[5];
    uint32_t output_channels;
    const CTDSPConnection *connections;
    size_t connection_count;
    /* Used only for FIR; copied completely at preparation. No I/O or asset
     * decoding occurs in this numerical owner. One history per occurrence.
     */
    const CTDSPFIR *fir;
    /* Used only for integer delay; 0...38400 frames, <=4194304 total per graph.
     * Fractional delay is resolved into integer delay followed by the existing
     * biquad operation. Zero delay performs no sample arithmetic.
     */
    uint32_t delay_frames;
} CTDSPOperation;

/* Exact identity of one execution occurrence, independent of its position.
 * Preparation copies these bytes. Identities must be unique within a graph;
 * callers retain the same identity for an unchanged stage/channel occurrence.
 */
typedef struct {
    const uint8_t *bytes;
    size_t count;
} CTDSPExecutionIdentity;

typedef struct {
    uint32_t input_channels;
    uint32_t output_channels;
    uint32_t maximum_frames;
    const CTDSPOperation *operations;
    size_t operation_count;
    const CTDSPExecutionIdentity *operation_identities;
} CTDSPConfiguration;

typedef struct {
    uint32_t input_channels;
    uint32_t output_channels;
    uint32_t maximum_frames;
} CTDSPFormat;

typedef struct {
    uint64_t processed_frames;
    uint64_t processed_blocks;
    uint64_t rejected_blocks;
    /* Samples clamped at the hard ceiling or soft curve's +/-1.5 input bound.
     * This is kernel telemetry, not Camilla's final-format clipping counter.
     */
    uint64_t clamped_samples;
} CTDSPCounters;

typedef enum {
    CTDSP_STREAM_ACCEPTING = 0,
    CTDSP_STREAM_DRAINING = 1,
    CTDSP_STREAM_DRAINED = 2,
    CTDSP_STREAM_CANCELLED = 3,
    CTDSP_STREAM_FAULTED = 4
} CTDSPStreamPhase;

typedef enum {
    CTDSP_TAIL_FINITE = 0,
    CTDSP_TAIL_RECURSIVE = 1
} CTDSPTailKind;

typedef struct {
    uint32_t phase;
    uint32_t tail_kind;
    /* Conservative output-path bound, including finite FFT work-buffer
     * support. Neither field is a finite quota for a recursive tail.
     * Remaining is meaningful only after end_input on a finite stream.
     */
    uint64_t tail_frames;
    uint64_t remaining_tail_frames;
} CTDSPStreamInfo;

/* Input has 1..32 channels; physical output has 1..256 slots, including unused
 * slots. Internal mixer buses are independent of those widths. The sole bound
 * on their width is the prepared-storage budget, not a hardware-channel limit.
 * Maximum frames is 1..16384, with <=4096 resolved operations.
 * Up to 256 MiB of requested C++ storage covers scratch, routing, histories,
 * FIR arrays, execution identities and preparation scratch. Allocation metadata, library vector
 * capacity overhead and opaque Accelerate FFT plans are not included: this is
 * not an RSS cap. Exhausting this budget returns CTDSP_RESOURCE_LIMIT before
 * allocation; it never reduces frame capacity, channels or filter length.
 * FIR: nonempty finite coefficients, <=4194304 total across all resolved FIR
 * occurrences per prepared graph. A single FIR may use the entire budget.
 * Returns a null result on every failure. No exceptions escape the C ABI.
 */
CTDSPStatus ctdsp_prepare(const CTDSPConfiguration *configuration, CTDSPState **result);
void ctdsp_destroy(CTDSPState *state);

/* Immutable per-output magnitude bounds from configured limiting, gains and
 * ordered routing. Infinity means the graph supplies no proven terminal bound
 * for that channel; retained state after a limiter also makes it unbounded.
 * Bounds include conservative arithmetic allowance before Float32 conversion.
 * A transition that adds outputs must enforce the selected graph's protection
 * on the combined signal. This query does not apply a limiter or certify tails.
 * Copies output_channels doubles without allocation or mutable-state access;
 * insufficient capacity leaves result unchanged. May run on control or processing.
 */
CTDSPStatus ctdsp_read_output_peak_limits(const CTDSPState *state, double *result, size_t count);

/* Float32 interleaved I/O; Float64 scratch, coefficients and histories.
 * Both pointers need only align for float. Aliased input/output is supported.
 * Counts are sample capacities, not bytes. Frames must be in 1..maximum_frames.
 * No allocation, locks, I/O or background work occurs during processing.
 * Argument/nonfinite-input rejection leaves histories and output unchanged.
 * Numerical overflow poisons the stream until reset; no partial output is written.
 */
CTDSPStatus ctdsp_process(CTDSPState *state, const float *input, size_t input_count,
                         float *output, size_t output_count, uint32_t frames);

/* Explicit source completion; never inferred from quiet PCM. End is idempotent
 * for an ending/ended stream and rejects further source input. No PCM is rendered
 * by end itself. An empty source ends immediately. Recursive output paths have
 * no inferred finite completion, even if their recent output is zero.
 */
CTDSPStatus ctdsp_end_input(CTDSPState *state);

/* A later producer may resume an accepting, draining or drained stream. Preserve
 * histories and counters at the exact rendered position, including any zeros
 * already drained. This does not infer or fill an unrendered wall-clock gap.
 * Cancelled/faulted streams cannot resume; they still require explicit reset.
 */
CTDSPStatus ctdsp_resume_input(CTDSPState *state);

/* Render zeros through the same operations and histories, after end_input.
 * Frames must be 1..maximum_frames. A finite final call may write fewer frames;
 * only that actual count needs output capacity. Drained returns zero frames and
 * accepts a null output. Written is required and is set to zero on failure.
 * Output is untouched on rejection/failure. Counters include drained PCM.
 * No allocation, locks, I/O, deadline polling or background work occurs here.
 */
CTDSPStatus ctdsp_drain(CTDSPState *state, float *output, size_t output_count,
                       uint32_t frames, uint32_t *written);

/* Cancellation ends immediately without rendering or clearing histories.
 * Only explicit reset permits more source PCM. Destroy never drains.
 */
CTDSPStatus ctdsp_cancel(CTDSPState *state);
CTDSPStatus ctdsp_read_stream_info(const CTDSPState *state, CTDSPStreamInfo *result);

/* Upper bound on every future pre-Float32 output magnitude if input remains
 * zero, from the current histories. Includes the existing Float64 recurrence's
 * rounding/underflow error. Infinity means this graph/state has no certificate;
 * callers must continue rendering or explicitly cancel, never infer silence.
 * FIR uses its enforced output-magnitude contract, including retained input
 * spans; a numerical result outside that contract fails instead of being clipped.
 * Covers gain, biquad, integer delay, FIR, mixer and limiter operations. It does not
 * declare a recursive stream finite, clear histories or advance its timeline.
 * The sole numerical owner may call it before or after end_input. It reuses
 * prepared scratch without allocation; counters and histories are unchanged.
 */
CTDSPStatus ctdsp_read_tail_peak_bound(CTDSPState *state, double *result);

/* Reset clears histories/counters and reopens source input. Callers that supply
 * explicit settling zeros through process remain supported until end_input.
 */
CTDSPStatus ctdsp_reset(CTDSPState *state);
CTDSPStatus ctdsp_read_counters(const CTDSPState *state, CTDSPCounters *result);
/* Immutable prepared dimensions, read by the serial owner before transferring
 * the state. A transfer must derive these from the state, not caller metadata.
 */
CTDSPStatus ctdsp_read_format(const CTDSPState *state, CTDSPFormat *result);

/* State continuation by exact execution occurrence. Preparation compares immutable
 * execution descriptions only, so source may continue rendering on its owner.
 * A plan retains neither state. Each apply requires the exact original live
 * allocations; owners must permanently disable the plan before transferring or
 * releasing either state. Inspection/destruction of a disabled plan is safe and
 * does not dereference states. Formats must match. Matched occurrences require
 * the same kind/channel, mixer endpoints/order, delay length and bit-identical
 * prepared FIR kernels/layouts. Position may change; inserted occurrences retain
 * their fresh histories. Removed stateful occurrences reject because they need
 * a retirement waveform. Stateless occurrences may be inserted or removed. Gain, biquad,
 * limiter parameters and mixer gains may differ; incompatibility is explicit.
 * No graph is reset, copied or changed during preparation.
 */
typedef struct CTDSPHistoryTransfer CTDSPHistoryTransfer;
typedef struct {
    uint64_t history_sample_bytes; /* Numeric histories only, excluding cursors/counters. */
    uint32_t changed_operations; /* Includes inserted, removed and moved occurrences. */
} CTDSPHistoryTransferInfo;
CTDSPStatus ctdsp_prepare_history_transfer(const CTDSPState *source, CTDSPState *destination,
                                          CTDSPHistoryTransfer **result);
/* CONTROL, while the plan is unpublished. Revalidate the same destination
 * against its new source using the already allocated plan. Success replaces
 * the binding and changed-operation description; failure changes neither.
 * Release the old source only after successful rebinding or explicit unbinding.
 * An unbound plan cannot be applied. No numerical state is read or
 * mutated, and no allocation is performed.
 */
CTDSPStatus ctdsp_rebind_history_transfer(CTDSPHistoryTransfer *transfer,
                                        const CTDSPState *source, CTDSPState *destination);
/* CONTROL. Disable an unpublished plan before releasing its source, retaining
 * only its allocation and immutable inspection result for later revalidation.
 */
void ctdsp_unbind_history_transfer(CTDSPHistoryTransfer *transfer);
void ctdsp_destroy_history_transfer(CTDSPHistoryTransfer *transfer);
CTDSPStatus ctdsp_read_history_transfer_info(const CTDSPHistoryTransfer *transfer, CTDSPHistoryTransferInfo *result);

/* The sole processing owner must serialize both states for this call. It copies
 * current histories into a fresh/reset destination, leaving source unchanged.
 * The destination must accept input; the source may accept input, drain, or
 * have completed. Faulted/cancelled sources reject without changing either
 * state. The plan is bound to these exact live state handles.
 *
 * Biquads retain their two transposed-direct-form-II delay values under the new
 * fixed coefficients, matching the reference's parameter-update state semantics.
 * This is continuation of the old state, not replay of the new filter's past.
 * FIR/delay histories and their partial-block cursors are copied completely.
 * Counters carry the rendered prefix; they are not new-revision activation
 * evidence. An unchanged graph also copies producer phase and exact remaining
 * tail. Changed parameters retain producer END and use a conservative extent
 * from the copied memories; an output change can expose a previously muted
 * tail even after the old output completed. Elapsed drain is not subtracted
 * from that new extent. Reset restores fresh bounds.
 *
 * No allocation, freeing, locks or I/O occurs. Work scales with the declared
 * history bytes; this API alone does not qualify a real-time deadline or choose
 * smoothing, cancellation/output policy or processing-side revision ownership.
 */
CTDSPStatus ctdsp_apply_history_transfer(const CTDSPHistoryTransfer *transfer,
                                        const CTDSPState *source, CTDSPState *destination);

#ifdef __cplusplus
}
#endif
#endif
