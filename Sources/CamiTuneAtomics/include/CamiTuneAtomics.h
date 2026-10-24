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

// One delivery writer and one Core Audio render callback. No allocation or
// locks in push/render. The owner stops callbacks before destroying the ring.
typedef struct CMTOutputRing* CMTOutputRingRef;
typedef struct {
    uint64_t buffered_frames, underrun_frames, rendered_frames, clipped_samples;
    uint64_t host_time, last_signal_host_time;
    double sample_time;
    uint32_t timestamp_flags, callback_frames;
} CMTOutputSnapshot;
CMTOutputRingRef cmt_output_ring_create(uint32_t channels, uint32_t capacity_frames, uint32_t preroll_frames);
void cmt_output_ring_destroy(CMTOutputRingRef ring);
void cmt_output_ring_cancel(CMTOutputRingRef ring);
int cmt_output_ring_accepting(CMTOutputRingRef ring);
uint32_t cmt_output_ring_channels(CMTOutputRingRef ring);
uint32_t cmt_output_ring_push(CMTOutputRingRef ring, const float* samples, uint32_t frames);
void cmt_output_ring_render(CMTOutputRingRef ring, float* output, uint32_t frames,
                            double sample_time, uint64_t host_time, uint32_t flags);
CMTOutputSnapshot cmt_output_ring_snapshot(CMTOutputRingRef ring);
float cmt_output_ring_peak(CMTOutputRingRef ring, uint32_t channel);
float cmt_output_ring_rms(CMTOutputRingRef ring, uint32_t channel);

#ifdef __cplusplus
}
#endif
#endif
