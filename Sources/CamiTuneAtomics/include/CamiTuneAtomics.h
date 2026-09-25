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

#ifdef __cplusplus
}
#endif
#endif
