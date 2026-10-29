#include "CamiTuneAtomics.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <dispatch/dispatch.h>

// These counters never acquire a mutex on a transport or PCM worker.
struct CMTPerformanceAtomic { _Atomic(uint64_t) value; };
CMTPerformanceAtomicRef cmt_performance_atomic_create(void) {
    CMTPerformanceAtomicRef result = calloc(1, sizeof(*result));
    if (result) atomic_init(&result->value, 0);
    return result;
}
void cmt_performance_atomic_destroy(CMTPerformanceAtomicRef value) { free(value); }
uint64_t cmt_performance_atomic_load(CMTPerformanceAtomicRef value) { return atomic_load_explicit(&value->value, memory_order_relaxed); }
void cmt_performance_atomic_store(CMTPerformanceAtomicRef value, uint64_t number) { atomic_store_explicit(&value->value, number, memory_order_relaxed); }
void cmt_performance_atomic_increment(CMTPerformanceAtomicRef value) { atomic_fetch_add_explicit(&value->value, 1, memory_order_relaxed); }
uint64_t cmt_performance_atomic_load_acquire(CMTPerformanceAtomicRef value) { return atomic_load_explicit(&value->value, memory_order_acquire); }
void cmt_performance_atomic_store_release(CMTPerformanceAtomicRef value, uint64_t number) { atomic_store_explicit(&value->value, number, memory_order_release); }
int cmt_performance_atomic_compare_exchange(CMTPerformanceAtomicRef value, uint64_t expected, uint64_t desired) {
    return atomic_compare_exchange_strong_explicit(&value->value, &expected, desired, memory_order_acq_rel, memory_order_acquire);
}

uint64_t cmt_performance_atomic_exchange(CMTPerformanceAtomicRef value, uint64_t number) { return atomic_exchange_explicit(&value->value, number, memory_order_acq_rel); }

struct CMTOutputRing {
    uint32_t channels, capacity, preroll;
    float* samples;
    _Atomic(uint64_t) read, write, accepting, underruns, rendered, clipped;
    _Atomic(uint64_t) sequence, host, sample, flags, callback, signal_host;
    _Atomic(uint32_t) peak[32], rms[32];
    dispatch_semaphore_t writer_signal;
    _Atomic(int) writer_waiting;
    // Render-callback-owned ramp and startup state.
    float last[32];
    uint32_t ramp, waiting_frames;
    int primed;
};
static uint32_t cmt_float_bits(float value) { uint32_t bits; memcpy(&bits, &value, sizeof(bits)); return bits; }
static float cmt_bits_float(uint32_t bits) { float value; memcpy(&value, &bits, sizeof(value)); return value; }
CMTOutputRingRef cmt_output_ring_create(uint32_t channels, uint32_t capacity, uint32_t preroll) {
    if (!channels || channels > 32 || !capacity || capacity > 1048576 || !preroll || preroll > capacity) return NULL;
    CMTOutputRingRef r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->samples = calloc((size_t)channels * capacity, sizeof(float));
    if (!r->samples) { free(r); return NULL; }
    r->writer_signal = dispatch_semaphore_create(0);
    if (!r->writer_signal) { free(r->samples); free(r); return NULL; }
    atomic_init(&r->writer_waiting, 0);
    r->channels = channels; r->capacity = capacity; r->preroll = preroll;
    atomic_init(&r->read, 0); atomic_init(&r->write, 0); atomic_init(&r->accepting, 1);
    atomic_init(&r->underruns, 0); atomic_init(&r->rendered, 0); atomic_init(&r->clipped, 0);
    atomic_init(&r->sequence, 0); atomic_init(&r->host, 0); atomic_init(&r->sample, 0);
    atomic_init(&r->flags, 0); atomic_init(&r->callback, 0);
    atomic_init(&r->signal_host, 0);
    for (uint32_t c = 0; c < channels; ++c) { atomic_init(&r->peak[c], 0); atomic_init(&r->rms[c], 0); }
    return r;
}
void cmt_output_ring_destroy(CMTOutputRingRef r) { if (r) { dispatch_release(r->writer_signal); free(r->samples); free(r); } }
static void cmt_output_ring_wake(CMTOutputRingRef r) {
    // No signal syscall when the writer has work or there is no input audio.
    if (atomic_exchange_explicit(&r->writer_waiting, 0, memory_order_seq_cst)) dispatch_semaphore_signal(r->writer_signal);
}
void cmt_output_ring_cancel(CMTOutputRingRef r) {
    atomic_store_explicit(&r->accepting, 0, memory_order_seq_cst);
    cmt_output_ring_wake(r);
}
void cmt_output_ring_wait(CMTOutputRingRef r, uint64_t rendered, uint64_t timeout_ns) {
    // A signal may arrive after a previous arm/recheck avoided sleeping. Drain
    // those tickets before arming; never accumulate notifications per callback.
    while (dispatch_semaphore_wait(r->writer_signal, DISPATCH_TIME_NOW) == 0) {}
    atomic_store_explicit(&r->writer_waiting, 1, memory_order_seq_cst);
    if (atomic_load_explicit(&r->rendered, memory_order_seq_cst) == rendered &&
        atomic_load_explicit(&r->accepting, memory_order_seq_cst)) {
        dispatch_semaphore_wait(r->writer_signal, dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ns));
    }
    atomic_store_explicit(&r->writer_waiting, 0, memory_order_seq_cst);
}
int cmt_output_ring_accepting(CMTOutputRingRef r) { return atomic_load_explicit(&r->accepting, memory_order_acquire) != 0; }
uint32_t cmt_output_ring_channels(CMTOutputRingRef r) { return r->channels; }
uint32_t cmt_output_ring_push(CMTOutputRingRef r, const float* samples, uint32_t frames) {
    if (!samples || !cmt_output_ring_accepting(r)) return 0;
    uint64_t w = atomic_load_explicit(&r->write, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&r->read, memory_order_acquire);
    uint32_t available = r->capacity - (uint32_t)(w - read);
    uint32_t count = frames < available ? frames : available;
    uint32_t first = r->capacity - (uint32_t)(w % r->capacity);
    if (first > count) first = count;
    memcpy(r->samples + (w % r->capacity) * r->channels, samples, (size_t)first * r->channels * sizeof(float));
    memcpy(r->samples, samples + (size_t)first * r->channels, (size_t)(count - first) * r->channels * sizeof(float));
    atomic_store_explicit(&r->write, w + count, memory_order_release);
    return count;
}
void cmt_output_ring_render(CMTOutputRingRef r, float* output, uint32_t frames, double sample, uint64_t host, uint32_t flags) {
    if (!output) return;
    uint64_t read = atomic_load_explicit(&r->read, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&r->write, memory_order_acquire);
    uint32_t available = (uint32_t)(w - read);
    // Device buffer sizes can change while other Core Audio clients are active.
    // Keep two callbacks of startup/recovery cover, bounded by ring capacity.
    uint32_t preroll = frames > r->capacity / 2 ? r->capacity : frames * 2;
    if (preroll < r->preroll) preroll = r->preroll;
    if (!r->primed) {
        if (available > 0) r->waiting_frames += frames;
        else r->waiting_frames = 0;
        if (available >= preroll || (available > 0 && r->waiting_frames >= preroll)) {
            r->primed = 1; r->ramp = 32; r->waiting_frames = 0;
        }
    }
    int was_primed = r->primed;
    uint32_t count = r->primed && cmt_output_ring_accepting(r) ? (available < frames ? available : frames) : 0;
    float peaks[32] = {0}; double sums[32] = {0}; uint64_t clipped = 0;
    for (uint32_t f = 0; f < frames; ++f) {
        if (f == count && r->primed) { r->primed = 0; r->ramp = 32; }
        for (uint32_t c = 0; c < r->channels; ++c) {
            float value = f < count ? r->samples[((read + f) % r->capacity) * r->channels + c] : 0;
            if (!isfinite(value)) value = 0;
            // Last-resort finite sample ceiling. The linked gain limiter lives
            // on the writer; no third-party code runs in this callback.
            value = fmaxf(-0.944060876f, fminf(0.944060876f, value));
            if (r->ramp) value = r->last[c] + (value - r->last[c]) / (float)r->ramp;
            r->last[c] = value; output[(size_t)f * r->channels + c] = value;
            peaks[c] = fmaxf(peaks[c], fabsf(value)); sums[c] += (double)value * value;
            if (fabsf(value) > 1) ++clipped;
        }
        if (r->ramp) --r->ramp;
    }
    atomic_store_explicit(&r->read, read + count, memory_order_release);
    if (was_primed && count < frames) atomic_fetch_add_explicit(&r->underruns, frames - count, memory_order_relaxed);
    atomic_fetch_add_explicit(&r->clipped, clipped, memory_order_relaxed);
    for (uint32_t c = 0; c < r->channels; ++c) {
        if (peaks[c] > 0) atomic_store_explicit(&r->signal_host, host, memory_order_relaxed);
        uint32_t peak = cmt_float_bits(peaks[c]);
        uint32_t previous = atomic_load_explicit(&r->peak[c], memory_order_relaxed);
        while (previous < peak && !atomic_compare_exchange_weak_explicit(&r->peak[c], &previous, peak, memory_order_relaxed, memory_order_relaxed)) {}
        atomic_store_explicit(&r->rms[c], cmt_float_bits(frames ? sqrtf((float)(sums[c] / frames)) : 0), memory_order_relaxed);
    }
    uint64_t sample_bits; memcpy(&sample_bits, &sample, sizeof(sample_bits));
    atomic_fetch_add_explicit(&r->sequence, 1, memory_order_seq_cst);
    atomic_store_explicit(&r->sample, sample_bits, memory_order_relaxed);
    atomic_store_explicit(&r->host, host, memory_order_relaxed);
    atomic_store_explicit(&r->flags, flags, memory_order_relaxed);
    atomic_store_explicit(&r->callback, frames, memory_order_relaxed);
    atomic_fetch_add_explicit(&r->sequence, 1, memory_order_seq_cst);
    // Publish consumption and the new callback size before notifying the writer.
    atomic_fetch_add_explicit(&r->rendered, frames, memory_order_seq_cst);
    cmt_output_ring_wake(r);
}
CMTOutputSnapshot cmt_output_ring_snapshot(CMTOutputRingRef r) {
    CMTOutputSnapshot s = {0};
    for (int attempt = 0; attempt < 4; ++attempt) {
        uint64_t seq = atomic_load_explicit(&r->sequence, memory_order_seq_cst);
        if (seq & 1) continue;
        uint64_t bits = atomic_load_explicit(&r->sample, memory_order_relaxed);
        memcpy(&s.sample_time, &bits, sizeof(bits));
        s.host_time = atomic_load_explicit(&r->host, memory_order_relaxed);
        s.timestamp_flags = (uint32_t)atomic_load_explicit(&r->flags, memory_order_relaxed);
        s.callback_frames = (uint32_t)atomic_load_explicit(&r->callback, memory_order_relaxed);
        if (seq == atomic_load_explicit(&r->sequence, memory_order_seq_cst)) break;
        s.timestamp_flags = 0;
    }
    uint64_t read = atomic_load_explicit(&r->read, memory_order_acquire);
    uint64_t write = atomic_load_explicit(&r->write, memory_order_acquire);
    s.buffered_frames = write >= read ? write - read : 0;
    s.underrun_frames = atomic_load_explicit(&r->underruns, memory_order_relaxed);
    s.rendered_frames = atomic_load_explicit(&r->rendered, memory_order_relaxed);
    s.clipped_samples = atomic_load_explicit(&r->clipped, memory_order_relaxed);
    s.last_signal_host_time = atomic_load_explicit(&r->signal_host, memory_order_relaxed);
    return s;
}
float cmt_output_ring_peak(CMTOutputRingRef r, uint32_t c) { return c < r->channels ? cmt_bits_float(atomic_exchange_explicit(&r->peak[c], 0, memory_order_relaxed)) : 0; }
float cmt_output_ring_rms(CMTOutputRingRef r, uint32_t c) { return c < r->channels ? cmt_bits_float(atomic_load_explicit(&r->rms[c], memory_order_relaxed)) : 0; }
