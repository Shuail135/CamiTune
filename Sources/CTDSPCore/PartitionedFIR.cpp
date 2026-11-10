#include "PartitionedFIR.h"
#include "NumericalBounds.h"

#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cfloat>
#include <cstring>
#include <limits>
#include <new>
#include <vector>

using namespace ctdsp::bounds;

namespace {
bool sameBits(const std::vector<double> &a, const std::vector<double> &b) noexcept {
    return a.size() == b.size() && (a.empty() || std::memcmp(a.data(), b.data(), a.size() * sizeof(double)) == 0);
}

struct FFTDeleter {
    void operator()(FFTSetupD setup) const { vDSP_destroy_fftsetupD(setup); }
};
using FFTPlan = std::unique_ptr<OpaqueFFTSetupD, FFTDeleter>;

struct SectionGeometry {
    size_t offset, count, quantum, partitions;
};

struct FIRLayout {
    size_t headCount;
    std::array<SectionGeometry, 3> sections{};
    size_t sectionCount = 0;
};

FIRLayout layout(const CTDSPFIR &configuration) noexcept {
    const size_t count = configuration.coefficient_count, base = configuration.base_quantum;
    FIRLayout result{std::min(count, base)};
    for (size_t offset = base; offset < count;) {
        const size_t end = configuration.partitioning == CTDSP_FIR_UNIFORM || offset >= base * 64
            ? count : std::min(count, offset * 8);
        const size_t length = end - offset;
        result.sections[result.sectionCount++] = {offset, length, offset, (length + offset - 1) / offset};
        offset = end;
    }
    return result;
}

// Same real-FFT packing, scaling and overlap-add contract as the existing
// BinauralConvolver. This experiment uses doubles and one channel per operation.
// A section whose coefficients start at B emits its next B outputs after seeing
// B inputs. The coefficient offset pays for accumulation; no extra delay is added.
class Section {
public:
    Section(const double *coefficients, const SectionGeometry &geometry)
        : block(geometry.quantum), partitions(geometry.partitions), logSize(0),
          filterReal(partitions * block), filterImag(partitions * block),
          historyReal(partitions * block), historyImag(partitions * block),
          real(block), imag(block), sumReal(block), sumImag(block),
          input(block), rendered(block), overlap(block) {
        for (size_t size = block * 2; size > 1; size >>= 1) ++logSize;
        fft.reset(vDSP_create_fftsetupD(logSize, kFFTRadix2));
        if (!fft) throw std::bad_alloc();
        for (size_t partition = 0; partition < partitions; ++partition) {
            const size_t base = partition * block;
            for (size_t i = 0; i < block && base + i < geometry.count; ++i) {
                (i % 2 ? filterImag : filterReal)[base + i / 2] = coefficients[base + i];
            }
            transform(filterReal.data() + base, filterImag.data() + base, false);
            for (size_t i = 0; i < block; ++i) {
                filterReal[base + i] *= 0.5;
                filterImag[base + i] *= 0.5;
                if (!std::isfinite(filterReal[base + i]) || !std::isfinite(filterImag[base + i])) {
                    throw CTDSP_NUMERICAL_FAILURE;
                }
            }
        }
    }

    double next(double sample) {
        const double value = rendered[cursor];
        input[cursor] = sample;
        if (++cursor == block) {
            cursor = 0;
            if (!renderBlock()) return std::numeric_limits<double>::quiet_NaN();
        }
        return value;
    }

    void reset() {
        for (auto *values : {&historyReal, &historyImag, &input, &rendered, &overlap}) {
            std::fill(values->begin(), values->end(), 0.0);
        }
        cursor = historyCursor = 0;
    }

    bool hasCompatibleHistory(const Section &source) const noexcept {
        return block == source.block && partitions == source.partitions
            && sameBits(filterReal, source.filterReal) && sameBits(filterImag, source.filterImag);
    }

    size_t historySampleBytes() const noexcept {
        return (historyReal.size() + historyImag.size() + input.size() + rendered.size() + overlap.size()) * sizeof(double);
    }

    void copyHistoryFrom(const Section &source) noexcept {
        std::copy(source.historyReal.begin(), source.historyReal.end(), historyReal.begin());
        std::copy(source.historyImag.begin(), source.historyImag.end(), historyImag.begin());
        std::copy(source.input.begin(), source.input.end(), input.begin());
        std::copy(source.rendered.begin(), source.rendered.end(), rendered.begin());
        std::copy(source.overlap.begin(), source.overlap.end(), overlap.begin());
        cursor = source.cursor;
        historyCursor = source.historyCursor;
        // Transform/summation scratch is overwritten before use; coefficients
        // and FFT plans remain the destination's immutable prepared resources.
    }

private:
    size_t block, partitions;
    vDSP_Length logSize;
    FFTPlan fft;
    std::vector<double> filterReal, filterImag, historyReal, historyImag;
    std::vector<double> real, imag, sumReal, sumImag, input, rendered, overlap;
    size_t cursor = 0, historyCursor = 0;

    void transform(double *r, double *i, bool inverse) {
        DSPDoubleSplitComplex split{r, i};
        vDSP_fft_zripD(fft.get(), &split, 1, logSize,
                      inverse ? kFFTDirection_Inverse : kFFTDirection_Forward);
    }

    bool renderBlock() {
        for (size_t i = 0; i < block; ++i) {
            real[i] = i < block / 2 ? input[2 * i] : 0;
            imag[i] = i < block / 2 ? input[2 * i + 1] : 0;
        }
        transform(real.data(), imag.data(), false);
        for (size_t i = 0; i < block; ++i) {
            if (!std::isfinite(real[i]) || !std::isfinite(imag[i])) return false;
        }
        std::copy(real.begin(), real.end(), historyReal.begin() + historyCursor * block);
        std::copy(imag.begin(), imag.end(), historyImag.begin() + historyCursor * block);
        std::fill(sumReal.begin(), sumReal.end(), 0.0);
        std::fill(sumImag.begin(), sumImag.end(), 0.0);
        for (size_t partition = 0; partition < partitions; ++partition) {
            const size_t h = ((historyCursor + partitions - partition) % partitions) * block;
            const size_t f = partition * block;
            const double dc = sumReal[0] + historyReal[h] * filterReal[f];
            const double nyquist = sumImag[0] + historyImag[h] * filterImag[f];
            DSPDoubleSplitComplex history{historyReal.data() + h, historyImag.data() + h};
            DSPDoubleSplitComplex filter{filterReal.data() + f, filterImag.data() + f};
            DSPDoubleSplitComplex sum{sumReal.data(), sumImag.data()}, destination = sum;
            vDSP_zvmaD(&history, 1, &filter, 1, &sum, 1, &destination, 1, block);
            sumReal[0] = dc;
            sumImag[0] = nyquist;
        }
        transform(sumReal.data(), sumImag.data(), true);
        // Filter FFTs were halved once. Real forward contributes 2, inverse N.
        const double scale = 1.0 / (4.0 * block);
        for (size_t i = 0; i < block / 2; ++i) {
            rendered[2 * i] = sumReal[i] * scale + overlap[2 * i];
            rendered[2 * i + 1] = sumImag[i] * scale + overlap[2 * i + 1];
            overlap[2 * i] = sumReal[i + block / 2] * scale;
            overlap[2 * i + 1] = sumImag[i + block / 2] * scale;
        }
        for (size_t i = 0; i < block; ++i) {
            if (!std::isfinite(rendered[i]) || !std::isfinite(overlap[i])) return false;
        }
        historyCursor = (historyCursor + 1) % partitions;
        return true;
    }
};
}

struct PartitionedFIR::Storage {
    std::vector<double> head, history;
    std::vector<std::unique_ptr<Section>> later;
    size_t cursor = 0;
    uint64_t peakCursor = 0, historySpan = 0;
    HistoryPeak retained;
    double boundGain = 0, boundFloor = 0;
};

size_t PartitionedFIR::requestedStorageBytes(const CTDSPFIR &configuration) noexcept {
    const auto plan = layout(configuration);
    size_t bytes = sizeof(PartitionedFIR) + sizeof(Storage)
        + plan.headCount * 3 * sizeof(double) + plan.sectionCount * sizeof(std::unique_ptr<Section>);
    for (size_t index = 0; index < plan.sectionCount; ++index) {
        const auto &section = plan.sections[index];
        bytes += sizeof(Section) + (4 * section.partitions + 7) * section.quantum * sizeof(double);
    }
    return bytes;
}

uint64_t PartitionedFIR::maximumTailFrames(const CTDSPFIR &configuration) noexcept {
    const auto plan = layout(configuration);
    uint64_t result = plan.headCount - 1;
    for (size_t index = 0; index < plan.sectionCount; ++index) {
        const auto &section = plan.sections[index];
        // The final nonzero input block can begin at its first sample. Each
        // section is delayed by its quantum, and the last partition contributes
        // a full rendered block followed by its overlap block. Include both;
        // mathematical coefficient length alone excludes FFT rounding residue.
        result = std::max(result, uint64_t(section.partitions + 2) * section.quantum - 1);
    }
    return result;
}

PartitionedFIR::PartitionedFIR(const CTDSPFIR &configuration) : storage(std::make_unique<Storage>()) {
    const auto plan = layout(configuration);
    storage->head.assign(configuration.coefficients, configuration.coefficients + plan.headCount);
    std::reverse(storage->head.begin(), storage->head.end());
    storage->history.resize(plan.headCount * 2);
    storage->historySpan = maximumTailFrames(configuration) + 1;
    for (size_t i = 0; i < configuration.coefficient_count; ++i) {
        storage->boundGain = upperAdd(storage->boundGain, std::abs(configuration.coefficients[i]));
    }
    // This is an enforced magnitude contract, not an assumed FFT error bound.
    // Permit twice the exact convolution's L1 envelope plus a small absolute
    // Double underflow allowance. Unexpected Accelerate results fail explicitly
    // below; they are never clipped or delivered as successful PCM.
    storage->boundGain = upperMultiply(storage->boundGain, 2);
    storage->boundFloor = upperMultiply(8 * double(configuration.coefficient_count), DBL_MIN);
    storage->later.reserve(plan.sectionCount);
    for (size_t index = 0; index < plan.sectionCount; ++index) {
        const auto &section = plan.sections[index];
        storage->later.push_back(std::make_unique<Section>(configuration.coefficients + section.offset, section));
    }
}

PartitionedFIR::~PartitionedFIR() = default;

bool PartitionedFIR::hasCompatibleHistory(const PartitionedFIR &source) const noexcept {
    if (!sameBits(storage->head, source.storage->head) || storage->later.size() != source.storage->later.size()) return false;
    for (size_t index = 0; index < storage->later.size(); ++index) {
        if (!storage->later[index]->hasCompatibleHistory(*source.storage->later[index])) return false;
    }
    return true;
}

size_t PartitionedFIR::historySampleBytes() const noexcept {
    size_t bytes = storage->history.size() * sizeof(double);
    for (const auto &section : storage->later) bytes += section->historySampleBytes();
    return bytes;
}

void PartitionedFIR::copyHistoryFrom(const PartitionedFIR &source) noexcept {
    std::copy(source.storage->history.begin(), source.storage->history.end(), storage->history.begin());
    storage->cursor = source.storage->cursor;
    storage->peakCursor = source.storage->peakCursor;
    storage->retained = source.storage->retained;
    for (size_t index = 0; index < storage->later.size(); ++index) {
        storage->later[index]->copyHistoryFrom(*source.storage->later[index]);
    }
}

bool PartitionedFIR::process(double *channel, size_t stride, size_t frames) {
    auto &s = *storage;
    const size_t count = s.head.size();
    double blockPeak = 0;
    for (size_t frame = 0; frame < frames; ++frame) blockPeak = std::max(blockPeak, std::abs(channel[frame * stride]));
    const double admittedPeak = tailPeakBound(blockPeak);
    for (size_t frame = 0; frame < frames; ++frame) {
        double &value = channel[frame * stride];
        const double sample = value;
        s.retained.record(sample, s.peakCursor == 0);
        if (++s.peakCursor == s.historySpan) s.peakCursor = 0;
        s.history[s.cursor] = s.history[s.cursor + count] = sample;
        double result = 0;
        vDSP_dotprD(s.head.data(), 1, s.history.data() + s.cursor + 1, 1, &result, count);
        if (++s.cursor == count) s.cursor = 0;
        for (auto &section : s.later) result += section->next(sample);
        value = result;
        if (!std::isfinite(value) || std::abs(value) > admittedPeak) return false;
    }
    return true;
}

void PartitionedFIR::reset() {
    std::fill(storage->history.begin(), storage->history.end(), 0.0);
    storage->cursor = 0;
    storage->peakCursor = 0;
    storage->retained = {};
    for (auto &section : storage->later) section->reset();
}

double PartitionedFIR::tailPeakBound(double futureInputPeak) const noexcept {
    const auto &s = *storage;
    if (!std::isfinite(s.boundGain) || !std::isfinite(s.boundFloor)) return HUGE_VAL;
    // The complete declared FIR span includes every partition and overlap.
    // Its retained input lies in the current or previous span. No later call
    // with input <= futureInputPeak can admit an output above this same limit.
    // The check in process makes this independent of opaque FFT arithmetic.
    const double input = std::max(futureInputPeak, s.retained.peak());
    if (input == 0) return 0;
    return upperAdd(upperMultiply(input, s.boundGain), s.boundFloor);
}
