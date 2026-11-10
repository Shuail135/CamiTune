#ifndef CTDSP_PARTITIONED_FIR_H
#define CTDSP_PARTITIONED_FIR_H

#include "CTDSPCore.h"
#include <memory>

// Local feasibility kernel. The direct initial section and the delayed FFT
// sections cover disjoint coefficient ranges. Every coefficient is retained.
class PartitionedFIR {
public:
    // The C preparation boundary validates the descriptor before either call.
    // Includes all requested C++ storage, excluding opaque Accelerate FFT plans.
    static size_t requestedStorageBytes(const CTDSPFIR &configuration) noexcept;
    // Includes the last partition's overlap-add window and any rounding
    // residue in its padded FFT bins. Independent of input-end block alignment.
    static uint64_t maximumTailFrames(const CTDSPFIR &configuration) noexcept;
    explicit PartitionedFIR(const CTDSPFIR &configuration);
    ~PartitionedFIR();
    // Borrow one interleaved channel for the supplied interval. The same dot
    // and FFT contribution order applies at every sample and call boundary.
    // False marks nonfinite numerical output; the C owner faults the stream.
    bool process(double *channel, size_t stride, size_t frames);
    void reset();
    // Compare immutable prepared kernels on preparation/control. The serial
    // processing owner may then copy only histories into equal preallocation.
    bool hasCompatibleHistory(const PartitionedFIR &source) const noexcept;
    size_t historySampleBytes() const noexcept;
    void copyHistoryFrom(const PartitionedFIR &source) noexcept;
    // Bounds all future Double output for bounded future input, including
    // retained FFT/overlap histories. Constant work; no history scan or mutation.
    double tailPeakBound(double futureInputPeak) const noexcept;
private:
    struct Storage;
    std::unique_ptr<Storage> storage;
};

#endif
