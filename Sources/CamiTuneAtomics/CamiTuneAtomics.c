#include "CamiTuneAtomics.h"
#include <stdatomic.h>
#include <stdlib.h>

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

uint64_t cmt_performance_atomic_exchange(CMTPerformanceAtomicRef value, uint64_t number) { return atomic_exchange_explicit(&value->value, number, memory_order_acq_rel); }
