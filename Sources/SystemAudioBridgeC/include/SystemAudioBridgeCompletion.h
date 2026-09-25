#ifndef SYSTEM_AUDIO_BRIDGE_COMPLETION_H
#define SYSTEM_AUDIO_BRIDGE_COMPLETION_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

/* Producer-owned admission, not an observed client-count watermark. Lifecycle
 * calls are serialized by the driver control lock. IO never waits for sealing.
 * An epoch cannot be reused while a callback admitted to it still owns a lease.
 * Exactly one closer publishes END, after every admitted callback has published
 * its records. A failed publication must fault the consumer, never fake END. */
typedef struct { _Atomic uint64_t state; } SABRCompletionAdmission;
#define SABR_COMPLETION_OPEN (UINT64_C(1) << 63)
#define SABR_COMPLETION_SEALED (UINT64_C(1) << 62)
#define SABR_COMPLETION_USERS ((UINT64_C(1) << 30) - 1)
#define SABR_COMPLETION_EPOCH_MASK UINT64_C(0xffffffff)

static inline uint64_t sabr_completion_epoch(uint64_t state) {
    return (state >> 30) & SABR_COMPLETION_EPOCH_MASK;
}

/* Only the serialized lifecycle owner may open. Zero means busy/exhausted. */
static inline uint64_t sabr_completion_open(SABRCompletionAdmission* admission) {
    uint64_t state = atomic_load_explicit(&admission->state, memory_order_acquire);
    if ((state & (SABR_COMPLETION_OPEN | SABR_COMPLETION_USERS)) != 0 ||
        (state != 0 && (state & SABR_COMPLETION_SEALED) == 0) ||
        sabr_completion_epoch(state) == SABR_COMPLETION_EPOCH_MASK) { return 0; }
    uint64_t epoch = sabr_completion_epoch(state) + 1;
    uint64_t next = SABR_COMPLETION_OPEN | (epoch << 30);
    return atomic_compare_exchange_strong_explicit(&admission->state, &state, next,
        memory_order_acq_rel, memory_order_acquire) ? epoch : 0;
}

/* Bounded CAS, with rejection rather than callback blocking under contention. */
static inline uint64_t sabr_completion_enter(SABRCompletionAdmission* admission) {
    uint64_t state = atomic_load_explicit(&admission->state, memory_order_acquire);
    for (unsigned attempt = 0; attempt < 8; ++attempt) {
        if (!(state & SABR_COMPLETION_OPEN) ||
            (state & SABR_COMPLETION_USERS) == SABR_COMPLETION_USERS) { return 0; }
        if (atomic_compare_exchange_weak_explicit(&admission->state, &state, state + 1,
                memory_order_acq_rel, memory_order_acquire)) {
            return sabr_completion_epoch(state);
        }
    }
    return 0;
}

/* Claim END publication; opening remains prohibited until publication finishes. */
static inline uint64_t sabr_completion_claim_end(SABRCompletionAdmission* admission) {
    uint64_t state = atomic_load_explicit(&admission->state, memory_order_acquire);
    if (!sabr_completion_epoch(state) ||
        (state & (SABR_COMPLETION_OPEN | SABR_COMPLETION_SEALED | SABR_COMPLETION_USERS))) { return 0; }
    /* A synthetic lease serializes END publication against the next open. */
    uint64_t next = state | SABR_COMPLETION_SEALED | 1;
    return atomic_compare_exchange_strong_explicit(&admission->state, &state, next,
        memory_order_acq_rel, memory_order_acquire) ? sabr_completion_epoch(state) : 0;
}

static inline uint64_t sabr_completion_close(SABRCompletionAdmission* admission) {
    atomic_fetch_and_explicit(&admission->state, ~SABR_COMPLETION_OPEN, memory_order_acq_rel);
    return sabr_completion_claim_end(admission);
}

/* Call only with a successful enter lease; returns the epoch whose END this
 * callback owns, or zero. Never release the synthetic publication lease here. */
static inline uint64_t sabr_completion_leave(SABRCompletionAdmission* admission) {
    uint64_t prior = atomic_fetch_sub_explicit(&admission->state, 1, memory_order_acq_rel);
    return (prior & SABR_COMPLETION_USERS) == 1 && !(prior & SABR_COMPLETION_OPEN)
        ? sabr_completion_claim_end(admission) : 0;
}

static inline void sabr_completion_end_published(SABRCompletionAdmission* admission) {
    atomic_fetch_sub_explicit(&admission->state, 1, memory_order_release);
}

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Completion admission must be lock-free");
#endif
