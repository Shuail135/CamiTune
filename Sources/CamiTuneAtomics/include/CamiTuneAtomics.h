#ifndef CAMITUNE_ATOMICS_H
#define CAMITUNE_ATOMICS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Lock-free scalar for telemetry flags/counters and presentation mailbox ownership.
// Exchange uses acquire/release ordering; scalar load/store/increment are relaxed.
typedef struct CMTPerformanceAtomic* CMTPerformanceAtomicRef;
CMTPerformanceAtomicRef cmt_performance_atomic_create(void);
void cmt_performance_atomic_destroy(CMTPerformanceAtomicRef value);
uint64_t cmt_performance_atomic_load(CMTPerformanceAtomicRef value);
void cmt_performance_atomic_store(CMTPerformanceAtomicRef value, uint64_t number);
uint64_t cmt_performance_atomic_exchange(CMTPerformanceAtomicRef value, uint64_t number);
void cmt_performance_atomic_increment(CMTPerformanceAtomicRef value);
// Publication counters for the single-producer/single-consumer analysis handoff.
uint64_t cmt_performance_atomic_load_acquire(CMTPerformanceAtomicRef value);
void cmt_performance_atomic_store_release(CMTPerformanceAtomicRef value, uint64_t number);
int cmt_performance_atomic_compare_exchange(CMTPerformanceAtomicRef value, uint64_t expected, uint64_t desired);

// Append-only telemetry: multiple writers reserve unique slots, then publish
// after initializing their Swift payload. Slots are never reused. A reader may
// inspect a payload only after its publication flag is acquired.
typedef struct CMTPerformanceStore* CMTPerformanceStoreRef;
CMTPerformanceStoreRef cmt_performance_store_create(uint64_t capacity);
void cmt_performance_store_destroy(CMTPerformanceStoreRef store);
// A successful reservation must be published exactly once. -1 means closed;
// -2 means full (already counted as a telemetry drop). Neither path waits.
int64_t cmt_performance_store_reserve(CMTPerformanceStoreRef store);
void cmt_performance_store_publish(CMTPerformanceStoreRef store, uint64_t slot);
uint64_t cmt_performance_store_reserved(CMTPerformanceStoreRef store);
int cmt_performance_store_published(CMTPerformanceStoreRef store, uint64_t slot);
int cmt_performance_store_stopped(CMTPerformanceStoreRef store);
uint64_t cmt_performance_store_drops(CMTPerformanceStoreRef store);
void cmt_performance_store_discard(CMTPerformanceStoreRef store);
// Stop is called once by the owner and returns the reserved prefix at closure.
uint64_t cmt_performance_store_stop(CMTPerformanceStoreRef store);
// Non-audio reader only, after stop. Returns 1 if publishers settled, 0 on
// timeout. A timed-out reader must skip and count every unpublished slot.
int cmt_performance_store_wait(CMTPerformanceStoreRef store, uint64_t timeout_ns);

// One delivery writer and one Core Audio render callback. No allocation or
// locks in push/render. The owner stops callbacks before destroying the ring.
typedef struct CMTOutputRing* CMTOutputRingRef;
typedef struct {
    uint64_t buffered_frames, underrun_frames, rendered_frames, clipped_samples;
    uint64_t host_time, render_entry_host_time, last_signal_host_time;
    double sample_time;
    uint32_t timestamp_flags, callback_frames;
} CMTOutputSnapshot;
#define CMT_OUTPUT_MAX_CHANNELS 256
typedef enum { CMT_OUTPUT_EXCLUSIVE_PLUGIN, CMT_OUTPUT_PREPARED_GRAPH } CMTOutputPolicy;
// Exclusive plug-ins retain the final ceiling and 32-frame edge fade. Prepared
// graph output retains its finite sample values; its graph owns all limiting.
CMTOutputRingRef cmt_output_ring_create(uint32_t channels, uint32_t capacity_frames, uint32_t preroll_frames, CMTOutputPolicy policy);
void cmt_output_ring_destroy(CMTOutputRingRef ring);
void cmt_output_ring_cancel(CMTOutputRingRef ring);
int cmt_output_ring_accepting(CMTOutputRingRef ring);
uint32_t cmt_output_ring_channels(CMTOutputRingRef ring);
uint32_t cmt_output_ring_push(CMTOutputRingRef ring, const float* samples, uint32_t frames);
// Sole writer only. Sleeps until a callback advances, cancellation, or timeout.
// Arm/recheck prevents a callback between the writer's snapshot and wait being lost.
void cmt_output_ring_wait(CMTOutputRingRef ring, uint64_t rendered_frames, uint64_t timeout_ns);
void cmt_output_ring_render(CMTOutputRingRef ring, float* output, uint32_t frames,
                            double sample_time, uint64_t host_time, uint32_t flags);
CMTOutputSnapshot cmt_output_ring_snapshot(CMTOutputRingRef ring);
float cmt_output_ring_peak(CMTOutputRingRef ring, uint32_t channel);
float cmt_output_ring_rms(CMTOutputRingRef ring, uint32_t channel);

#ifdef __cplusplus
}
#endif
#endif
