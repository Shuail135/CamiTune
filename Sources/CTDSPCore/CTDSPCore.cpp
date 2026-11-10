#include "CTDSPCore.h"
#include "PartitionedFIR.h"
#include "NumericalBounds.h"

#include <algorithm>
#include <cmath>
#include <cfloat>
#include <cstring>
#include <memory>
#include <new>
#include <string>
#include <vector>

using namespace ctdsp::bounds;

namespace {

struct BiquadTailBound {
    double center = 0;
    double scale = 0;
    double contraction = HUGE_VAL;
    double inputGain = 0;
    double roundoffFloor = 0;

    // The exact transformed state is (z1, (z2 + center*z1)/scale).
    // Endpoint enclosures also cover cancellation when that second coordinate
    // is much smaller than either original history value.
    double norm(double z1Low, double z1High, double z2Low, double z2High) const {
        const double low = lower(std::fma(center, center >= 0 ? z1Low : z1High, z2Low));
        const double high = upper(std::fma(center, center >= 0 ? z1High : z1Low, z2High));
        return upperNorm(std::max(std::abs(z1Low), std::abs(z1High)),
            upper(std::max(std::abs(low), std::abs(high)) / scale));
    }

    static BiquadTailBound prepare(const double *p) {
        BiquadTailBound result;
        result.center = -0.5 * p[3];
        // An underflowed half coefficient cannot establish this exact change
        // of coordinates. The kernel remains usable, but this bound is unknown.
        if (-2 * result.center != p[3]) return result;
        const double c = result.center;
        const double discriminant = std::fma(c, c, -p[4]);
        result.scale = std::max(std::sqrt(std::abs(discriminant)), (1 - std::abs(c)) * 0.5);
        const double s = result.scale;
        if (!(s > 0) || !std::isfinite(s)) return result;
        const double low = lower(lower(discriminant) / s);
        const double high = upper(upper(discriminant) / s);
        // In these coordinates A = [[c,s],[(c*c-a2)/s,c]]. Bound its
        // Euclidean operator norm by the maximum absolute row sum of A^T A.
        // Complex poles become a rotation/contraction; real and repeated poles
        // use the same certificate without dividing by a pole separation.
        const double cross = upperMultiply(std::abs(c),
            std::max(std::abs(lower(s + low)), std::abs(upper(s + high))));
        const double cSquared = upperMultiply(std::abs(c), std::abs(c));
        const double dMagnitude = std::max(std::abs(low), std::abs(high));
        const double first = upperAdd(upperAdd(cSquared, upperMultiply(dMagnitude, dMagnitude)), cross);
        const double second = upperAdd(upperAdd(cSquared, upperMultiply(s, s)), cross);
        const double exactContraction = upper(std::sqrt(std::max(first, second)));
        const double transform = upperAdd(1, upper(upperAdd(1, std::abs(c)) / s));
        const double feedback = upperAdd(std::abs(p[3]), std::abs(p[4]));
        const double stateTerms = upperAdd(upperAdd(1, feedback), upperAdd(s, std::abs(c)));
        const double inputTerms = upperAdd(upperAdd(std::abs(p[0]), std::abs(p[1])),
            upperAdd(std::abs(p[2]), upperMultiply(feedback, std::abs(p[0]))));
        // The render recurrence has at most seven rounded scalar operations
        // on any state path. 64*epsilon bounds their propagated relative error;
        // 64*DBL_MIN also encloses underflow error, without flushing histories.
        constexpr double rounding = 64 * DBL_EPSILON;
        const double errorScale = upperMultiply(rounding, transform);
        const double contraction = upperAdd(exactContraction, upperMultiply(errorScale, stateTerms));
        if (!(contraction < 1)) return result;
        const double b1 = std::fma(-p[3], p[0], p[1]);
        const double b2 = std::fma(-p[4], p[0], p[2]);
        result.inputGain = upperAdd(result.norm(lower(b1), upper(b1), lower(b2), upper(b2)),
            upperMultiply(errorScale, inputTerms));
        result.roundoffFloor = upperMultiply(64 * DBL_MIN, upperMultiply(transform, upperAdd(1, feedback)));
        if (!std::isfinite(result.inputGain) || !std::isfinite(result.roundoffFloor)) return result;
        result.contraction = contraction;
        return result;
    }

    double peak(double z1, double z2, double input, double directGain) const {
        if (!(contraction < 1)) return HUGE_VAL;
        if (input == 0 && z1 == 0 && z2 == 0) return 0;
        const double equilibrium = upper(upperAdd(upperMultiply(inputGain, input), roundoffFloor)
            / lower(1 - contraction));
        const double state = std::max(norm(z1, z1, z2, z2), equilibrium);
        return upperAdd(upperMultiply(upperAdd(state, upperMultiply(std::abs(directGain), input)),
            1 + 8 * DBL_EPSILON), 8 * DBL_MIN);
    }
};

enum class TailKind { silent, finite, recursive };
struct TailExtent {
    uint64_t frames = 0;
    TailKind kind = TailKind::silent;
};

struct Connection {
    CTDSPConnection values;
    bool firstContribution;
};

struct DelayLine {
    std::vector<double> samples;
    size_t cursor = 0;
    HistoryPeak retained;

    DelayLine() = default;
    explicit DelayLine(size_t frames) : samples(frames) {}

    void process(double &value) {
        if (samples.empty()) return;
        retained.record(value, cursor == 0);
        std::swap(value, samples[cursor]);
        if (++cursor == samples.size()) cursor = 0;
    }

    double peak() const {
        // Every retained sample belongs to the current or previous ring lap.
        // Keeping each lap's maximum avoids scanning long delays during tail
        // queries. The enclosure can retain one extra lap, never miss a sample.
        return retained.peak();
    }

    void copyHistoryFrom(const DelayLine &source) {
        std::copy(source.samples.begin(), source.samples.end(), samples.begin());
        cursor = source.cursor;
        retained = source.retained;
    }

    void reset() {
        std::fill(samples.begin(), samples.end(), 0.0);
        cursor = 0;
        retained = {};
    }
};

struct Operation {
    std::string identity;
    uint32_t kind;
    uint32_t channel;
    double parameters[5];
    uint32_t outputChannels;
    std::vector<Connection> connections;
    std::unique_ptr<PartitionedFIR> fir;
    DelayLine delay;
    double z1 = 0;
    double z2 = 0;
    BiquadTailBound tailBound;
};
}

struct CTDSPState {
    uint32_t inputChannels;
    uint32_t outputChannels;
    uint32_t maximumFrames;
    std::vector<Operation> operations;
    // Immutable sorted indices match execution occurrences during preparation.
    // Numerical execution always uses the original operation order.
    std::vector<uint32_t> identityOrder;
    std::vector<double> outputLimits;
    std::vector<double> first;
    std::vector<double> second;
    CTDSPCounters counters{};
    TailExtent initialTail;
    TailExtent retainedTail;
    TailExtent tail;
    uint64_t remainingTail = 0;
    CTDSPStreamPhase phase = CTDSP_STREAM_ACCEPTING;
};

struct CTDSPHistoryTransfer {
    const CTDSPState *source;
    CTDSPState *destination;
    CTDSPHistoryTransferInfo info;
    std::vector<uint32_t> sources;
};

namespace {
struct BusStorage {
    uint32_t widestBus = 0;
    uint32_t widestMixer = 0;
};

bool claimStorage(size_t count, size_t elementSize, size_t &total) {
    if (count > (CTDSP_MAXIMUM_PREPARED_BYTES - total) / elementSize) return false;
    total += count * elementSize;
    return true;
}

bool finiteParameters(const CTDSPOperation &operation, size_t count) {
    for (size_t index = 0; index < count; ++index) {
        if (!std::isfinite(operation.parameters[index])) return false;
    }
    return true;
}

CTDSPStatus validate(const CTDSPConfiguration &configuration, BusStorage &buses) {
    if (configuration.input_channels == 0 || configuration.input_channels > CTDSP_MAXIMUM_INPUT_CHANNELS
        || configuration.output_channels == 0 || configuration.output_channels > CTDSP_MAXIMUM_OUTPUT_CHANNELS
        || configuration.maximum_frames == 0 || configuration.maximum_frames > CTDSP_MAXIMUM_FRAMES
        || configuration.operation_count > CTDSP_MAXIMUM_OPERATIONS
        || (configuration.operation_count && (!configuration.operations || !configuration.operation_identities))) return CTDSP_INVALID_ARGUMENT;
    uint32_t channels = configuration.input_channels;
    size_t totalCoefficients = 0;
    size_t totalDelayFrames = 0;
    buses.widestBus = channels;
    size_t storageBytes = sizeof(CTDSPState);
    if (!claimStorage(configuration.operation_count, sizeof(Operation), storageBytes)) return CTDSP_RESOURCE_LIMIT;
    if (!claimStorage(configuration.operation_count, sizeof(uint32_t), storageBytes)) return CTDSP_RESOURCE_LIMIT;
    for (size_t index = 0; index < configuration.operation_count; ++index) {
        const auto identity = configuration.operation_identities[index];
        if (identity.count && !identity.bytes) return CTDSP_INVALID_ARGUMENT;
        if (!claimStorage(identity.count, 1, storageBytes) || !claimStorage(1, 1, storageBytes)) return CTDSP_RESOURCE_LIMIT;
        const auto &operation = configuration.operations[index];
        if (operation.kind == CTDSP_MIXER) {
            if (operation.output_channels == 0
                || (operation.connection_count && !operation.connections)) return CTDSP_INVALID_ARGUMENT;
            if (!claimStorage(operation.connection_count, sizeof(Connection), storageBytes)) return CTDSP_RESOURCE_LIMIT;
            for (size_t connectionIndex = 0; connectionIndex < operation.connection_count; ++connectionIndex) {
                const auto &connection = operation.connections[connectionIndex];
                if (connection.source >= channels || connection.destination >= operation.output_channels
                    || !std::isfinite(connection.gain)) return CTDSP_INVALID_ARGUMENT;
            }
            channels = operation.output_channels;
            buses.widestBus = std::max(buses.widestBus, channels);
            buses.widestMixer = std::max(buses.widestMixer, channels);
            continue;
        }
        switch (operation.kind) {
        case CTDSP_GAIN:
            if (!finiteParameters(operation, 1)) return CTDSP_INVALID_ARGUMENT;
            break;
        case CTDSP_INTEGER_DELAY:
            totalDelayFrames += operation.delay_frames;
            if (operation.delay_frames > 38400 || totalDelayFrames > 4194304) return CTDSP_INVALID_ARGUMENT;
            if (!claimStorage(operation.delay_frames, sizeof(double), storageBytes)) return CTDSP_RESOURCE_LIMIT;
            break;
        case CTDSP_BIQUAD:
            if (!finiteParameters(operation, 5)
                || std::abs(operation.parameters[4]) >= 1
                || std::abs(operation.parameters[3]) >= 1 + operation.parameters[4]) return CTDSP_INVALID_ARGUMENT;
            break;
        case CTDSP_HARD_LIMITER:
        case CTDSP_SOFT_LIMITER:
            if (!finiteParameters(operation, 1) || operation.parameters[0] <= 0
                || operation.parameters[0] > 1) return CTDSP_INVALID_ARGUMENT;
            break;
        case CTDSP_FIR: {
            if (!operation.fir) return CTDSP_INVALID_ARGUMENT;
            const auto &fir = *operation.fir;
            if (!fir.coefficients || fir.coefficient_count == 0
                || fir.coefficient_count > CTDSP_MAXIMUM_TOTAL_FIR_COEFFICIENTS - totalCoefficients
                || fir.base_quantum < 32 || fir.base_quantum > 2048
                || (fir.base_quantum & (fir.base_quantum - 1)) != 0
                || fir.partitioning > CTDSP_FIR_LARGER_TAILS) return CTDSP_INVALID_ARGUMENT;
            totalCoefficients += fir.coefficient_count;
            if (!claimStorage(1, PartitionedFIR::requestedStorageBytes(fir), storageBytes)) return CTDSP_RESOURCE_LIMIT;
            for (size_t i = 0; i < fir.coefficient_count; ++i) {
                if (!std::isfinite(fir.coefficients[i])) return CTDSP_INVALID_ARGUMENT;
            }
            break;
        }
        default:
            return CTDSP_UNSUPPORTED_OPERATION;
        }
        if (operation.channel >= channels || operation.connection_count != 0) return CTDSP_INVALID_ARGUMENT;
    }
    if (channels != configuration.output_channels) return CTDSP_INVALID_ARGUMENT;
    const size_t samples = size_t(buses.widestBus) * configuration.maximum_frames;
    if (!claimStorage(samples, 2 * sizeof(double), storageBytes)
        || !claimStorage(configuration.output_channels, sizeof(double), storageBytes)
        || !claimStorage(buses.widestBus, 2 * sizeof(TailExtent), storageBytes)
        || !claimStorage(buses.widestMixer, sizeof(uint8_t), storageBytes)) return CTDSP_RESOURCE_LIMIT;
    return CTDSP_OK;
}

TailExtent longest(TailExtent a, TailExtent b) {
    if (a.kind == TailKind::silent) return b;
    if (b.kind == TailKind::silent) return a;
    if (a.kind == TailKind::recursive || b.kind == TailKind::recursive) return {0, TailKind::recursive};
    return {std::max(a.frames, b.frames), TailKind::finite};
}

TailExtent tailExtent(const CTDSPConfiguration &configuration, uint32_t widestBus, bool retainedHistory) {
    std::vector<TailExtent> current(widestBus), next(widestBus);
    std::fill(current.begin(), current.begin() + configuration.input_channels, TailExtent{0, TailKind::finite});
    uint32_t channels = configuration.input_channels;
    for (size_t index = 0; index < configuration.operation_count; ++index) {
        const auto &operation = configuration.operations[index];
        if (operation.kind == CTDSP_MIXER) {
            std::fill(next.begin(), next.begin() + operation.output_channels, TailExtent{});
            for (size_t connection = 0; connection < operation.connection_count; ++connection) {
                const auto &value = operation.connections[connection];
                if (value.gain != 0) next[value.destination] = longest(next[value.destination], current[value.source]);
            }
            current.swap(next);
            channels = operation.output_channels;
            continue;
        }
        auto &tail = current[operation.channel];
        const auto *p = operation.parameters;
        // Imported histories are independent of today's upstream reachability.
        // A new zero gain/numerator cannot erase a downstream old delay value.
        // Add each stateful stage's possible natural response before propagating
        // the incoming tail. Later output mutes/routing still quench it normally.
        TailExtent memory;
        if (retainedHistory) {
            switch (operation.kind) {
            case CTDSP_INTEGER_DELAY: memory = {operation.delay_frames, TailKind::finite}; break;
            case CTDSP_FIR: memory = {PartitionedFIR::maximumTailFrames(*operation.fir), TailKind::finite}; break;
            case CTDSP_BIQUAD: memory = p[3] != 0 || p[4] != 0 ? TailExtent{0, TailKind::recursive} : TailExtent{2, TailKind::finite}; break;
            default: break;
            }
        }
        if (operation.kind == CTDSP_GAIN && p[0] == 0) tail = {};
        if (operation.kind == CTDSP_BIQUAD && p[0] == 0 && p[1] == 0 && p[2] == 0) tail = {};
        if (tail.kind == TailKind::silent) { tail = memory; continue; }
        if (operation.kind == CTDSP_BIQUAD && (p[3] != 0 || p[4] != 0)) tail = {0, TailKind::recursive};
        if (tail.kind == TailKind::recursive) continue;
        switch (operation.kind) {
        case CTDSP_INTEGER_DELAY: tail.frames += operation.delay_frames; break;
        case CTDSP_FIR: tail.frames += PartitionedFIR::maximumTailFrames(*operation.fir); break;
        case CTDSP_BIQUAD: tail.frames += p[2] != 0 ? 2 : p[1] != 0 ? 1 : 0; break;
        default: break;
        }
        tail = longest(tail, memory);
    }
    TailExtent result;
    for (uint32_t channel = 0; channel < channels; ++channel) result = longest(result, current[channel]);
    return result;
}

void prepareOutputLimits(CTDSPState &state) {
    // A tail-preserving transition adds two outputs. The configured output
    // protection must also constrain that sum. Histories before the last
    // limiter may be arbitrary; stateful processing after it invalidates the
    // bound. Never infer a ceiling from a frequency-response measurement.
    double *current = state.first.data(), *scratch = state.second.data();
    uint32_t channels = state.inputChannels;
    std::fill(current, current + channels, HUGE_VAL);
    for (const auto &operation : state.operations) {
        if (operation.kind == CTDSP_MIXER) {
            std::fill(scratch, scratch + operation.outputChannels, 0.0);
            for (const auto &connection : operation.connections) {
                const auto &value = connection.values;
                scratch[value.destination] = upperAdd(scratch[value.destination],
                    upperMultiply(current[value.source], std::abs(value.gain)));
            }
            std::swap(current, scratch);
            channels = operation.outputChannels;
            continue;
        }
        auto &limit = current[operation.channel];
        switch (operation.kind) {
        case CTDSP_GAIN: limit = upperMultiply(limit, std::abs(operation.parameters[0])); break;
        case CTDSP_HARD_LIMITER: limit = std::min(limit, operation.parameters[0]); break;
        case CTDSP_SOFT_LIMITER:
            limit = upperAdd(upperMultiply(std::min(limit, operation.parameters[0]),
                1 + 64 * DBL_EPSILON), 64 * DBL_MIN);
            break;
        case CTDSP_INTEGER_DELAY:
            if (!operation.delay.samples.empty()) limit = HUGE_VAL;
            break;
        default: limit = HUGE_VAL; break;
        }
    }
    state.outputLimits.assign(current, current + channels);
}
}

extern "C" CTDSPStatus ctdsp_prepare(const CTDSPConfiguration *configuration, CTDSPState **result) {
    if (!result) return CTDSP_INVALID_ARGUMENT;
    *result = nullptr;
    if (!configuration) return CTDSP_INVALID_ARGUMENT;
    BusStorage buses;
    const auto status = validate(*configuration, buses);
    if (status != CTDSP_OK) return status;
    try {
        auto state = std::make_unique<CTDSPState>();
        state->inputChannels = configuration->input_channels;
        state->outputChannels = configuration->output_channels;
        state->maximumFrames = configuration->maximum_frames;
        state->initialTail = tailExtent(*configuration, buses.widestBus, false);
        state->retainedTail = tailExtent(*configuration, buses.widestBus, true);
        state->tail = state->initialTail;
        const size_t samples = size_t(buses.widestBus) * configuration->maximum_frames;
        state->first.resize(samples);
        state->second.resize(samples);
        state->operations.reserve(configuration->operation_count);
        state->identityOrder.reserve(configuration->operation_count);
        std::vector<uint8_t> mapped(buses.widestMixer);
        for (size_t index = 0; index < configuration->operation_count; ++index) {
            const auto &source = configuration->operations[index];
            Operation operation{};
            const auto identity = configuration->operation_identities[index];
            if (identity.count) operation.identity.assign(reinterpret_cast<const char *>(identity.bytes), identity.count);
            operation.kind = source.kind;
            operation.channel = source.kind == CTDSP_MIXER ? 0 : source.channel;
            const size_t parameterCount = source.kind == CTDSP_MIXER || source.kind == CTDSP_FIR || source.kind == CTDSP_INTEGER_DELAY
                ? 0 : source.kind == CTDSP_BIQUAD ? 5 : 1;
            std::copy(source.parameters, source.parameters + parameterCount, operation.parameters);
            if (source.kind == CTDSP_BIQUAD) operation.tailBound = BiquadTailBound::prepare(operation.parameters);
            operation.outputChannels = source.kind == CTDSP_MIXER ? source.output_channels : 0;
            if (source.kind == CTDSP_FIR) operation.fir = std::make_unique<PartitionedFIR>(*source.fir);
            if (source.kind == CTDSP_INTEGER_DELAY) operation.delay = DelayLine(source.delay_frames);
            if (source.kind == CTDSP_MIXER) std::fill(mapped.begin(), mapped.begin() + source.output_channels, 0);
            operation.connections.reserve(source.connection_count);
            for (size_t connectionIndex = 0; connectionIndex < source.connection_count; ++connectionIndex) {
                const auto connection = source.connections[connectionIndex];
                operation.connections.push_back({connection, mapped[connection.destination] == 0});
                mapped[connection.destination] = 1;
            }
            state->operations.push_back(std::move(operation));
            state->identityOrder.push_back(static_cast<uint32_t>(index));
        }
        std::sort(state->identityOrder.begin(), state->identityOrder.end(), [&](uint32_t a, uint32_t b) {
            return state->operations[a].identity < state->operations[b].identity;
        });
        for (size_t i = 1; i < state->identityOrder.size(); ++i) {
            if (state->operations[state->identityOrder[i - 1]].identity == state->operations[state->identityOrder[i]].identity) {
                return CTDSP_INVALID_ARGUMENT;
            }
        }
        prepareOutputLimits(*state);
        *result = state.release();
        return CTDSP_OK;
    } catch (const std::bad_alloc &) {
        return CTDSP_ALLOCATION_FAILED;
    } catch (CTDSPStatus failure) {
        return failure;
    } catch (...) {
        // No exception crosses the ABI; RAII still owns the partial result.
        return CTDSP_INTERNAL_ERROR;
    }
}

extern "C" void ctdsp_destroy(CTDSPState *state) { delete state; }

extern "C" CTDSPStatus ctdsp_read_output_peak_limits(const CTDSPState *state, double *result, size_t count) {
    if (!state || !result || count < state->outputChannels) return CTDSP_INVALID_ARGUMENT;
    std::copy(state->outputLimits.begin(), state->outputLimits.end(), result);
    return CTDSP_OK;
}

namespace {
constexpr uint32_t noHistorySource = UINT32_MAX;

uint32_t matchingOperation(const CTDSPState &state, const std::string &identity) {
    const auto found = std::lower_bound(state.identityOrder.begin(), state.identityOrder.end(), identity,
        [&](uint32_t index, const std::string &key) { return state.operations[index].identity < key; });
    return found != state.identityOrder.end() && state.operations[*found].identity == identity
        ? *found : noHistorySource;
}

CTDSPStatus describeHistoryTransfer(const CTDSPState *source, const CTDSPState *destination,
                                   CTDSPHistoryTransferInfo &info) {
    if (!source || !destination || source == destination) return CTDSP_INVALID_ARGUMENT;
    if (source->inputChannels != destination->inputChannels || source->outputChannels != destination->outputChannels
        || source->maximumFrames != destination->maximumFrames) {
        return CTDSP_INCOMPATIBLE_HISTORY;
    }
    info = {};
    // Only immutable descriptions are inspected here, never cursors, samples,
    // stream phase or counters that the source's processing owner may change.
    for (const auto &before : source->operations) {
        if (matchingOperation(*destination, before.identity) != noHistorySource) continue;
        // A removed stateful occurrence needs a separate retirement waveform.
        // An identity match cannot authorize discarding its delayed contribution.
        if (before.kind == CTDSP_BIQUAD || before.kind == CTDSP_FIR
            || (before.kind == CTDSP_INTEGER_DELAY && !before.delay.samples.empty())) return CTDSP_INCOMPATIBLE_HISTORY;
        ++info.changed_operations;
    }
    for (size_t index = 0; index < destination->operations.size(); ++index) {
        const auto &after = destination->operations[index];
        const auto sourceIndex = matchingOperation(*source, after.identity);
        if (sourceIndex == noHistorySource) { ++info.changed_operations; continue; }
        const auto &before = source->operations[sourceIndex];
        if (before.kind != after.kind || before.channel != after.channel || before.outputChannels != after.outputChannels
            || before.connections.size() != after.connections.size() || before.delay.samples.size() != after.delay.samples.size()) {
            return CTDSP_INCOMPATIBLE_HISTORY;
        }
        bool changed = sourceIndex != index;
        if (before.kind == CTDSP_FIR) {
            if (!after.fir->hasCompatibleHistory(*before.fir)) return CTDSP_INCOMPATIBLE_HISTORY;
            info.history_sample_bytes += before.fir->historySampleBytes();
        } else if (before.kind == CTDSP_INTEGER_DELAY) {
            info.history_sample_bytes += before.delay.samples.size() * sizeof(double);
        } else if (before.kind == CTDSP_MIXER) {
            for (size_t connection = 0; connection < before.connections.size(); ++connection) {
                const auto &a = before.connections[connection].values, &b = after.connections[connection].values;
                if (a.source != b.source || a.destination != b.destination) return CTDSP_INCOMPATIBLE_HISTORY;
                changed |= std::memcmp(&a.gain, &b.gain, sizeof(double)) != 0;
            }
        } else {
            const size_t count = before.kind == CTDSP_BIQUAD ? 5 : 1;
            changed |= std::memcmp(before.parameters, after.parameters, count * sizeof(double)) != 0;
            if (before.kind == CTDSP_BIQUAD) info.history_sample_bytes += 2 * sizeof(double);
        }
        if (changed) ++info.changed_operations;
    }
    return CTDSP_OK;
}

void bindHistorySources(CTDSPHistoryTransfer &transfer, const CTDSPState &source) {
    // Destination storage is fixed at construction. Rebinding neither allocates
    // nor mutates a plan until the complete immutable compatibility check passes.
    for (size_t index = 0; index < transfer.sources.size(); ++index) {
        transfer.sources[index] = matchingOperation(source, transfer.destination->operations[index].identity);
    }
}
}

extern "C" CTDSPStatus ctdsp_prepare_history_transfer(const CTDSPState *source, CTDSPState *destination,
                                                      CTDSPHistoryTransfer **result) {
    if (!result) return CTDSP_INVALID_ARGUMENT;
    *result = nullptr;
    CTDSPHistoryTransferInfo info{};
    const auto status = describeHistoryTransfer(source, destination, info);
    if (status != CTDSP_OK) return status;
    try {
        auto transfer = std::make_unique<CTDSPHistoryTransfer>(CTDSPHistoryTransfer{
            source, destination, info, std::vector<uint32_t>(destination->operations.size())});
        bindHistorySources(*transfer, *source);
        *result = transfer.release();
        return CTDSP_OK;
    } catch (const std::bad_alloc &) { return CTDSP_ALLOCATION_FAILED; }
}

extern "C" CTDSPStatus ctdsp_rebind_history_transfer(CTDSPHistoryTransfer *transfer,
                                                     const CTDSPState *source, CTDSPState *destination) {
    if (!transfer || destination != transfer->destination) return CTDSP_INVALID_ARGUMENT;
    CTDSPHistoryTransferInfo info{};
    const auto status = describeHistoryTransfer(source, destination, info);
    if (status != CTDSP_OK) return status;
    bindHistorySources(*transfer, *source);
    transfer->source = source;
    transfer->info = info;
    return CTDSP_OK;
}

extern "C" void ctdsp_destroy_history_transfer(CTDSPHistoryTransfer *transfer) { delete transfer; }

extern "C" void ctdsp_unbind_history_transfer(CTDSPHistoryTransfer *transfer) {
    if (transfer) transfer->source = nullptr;
}

extern "C" CTDSPStatus ctdsp_read_history_transfer_info(const CTDSPHistoryTransfer *transfer, CTDSPHistoryTransferInfo *result) {
    if (!transfer || !result) return CTDSP_INVALID_ARGUMENT;
    *result = transfer->info;
    return CTDSP_OK;
}

extern "C" CTDSPStatus ctdsp_apply_history_transfer(const CTDSPHistoryTransfer *transfer,
                                                    const CTDSPState *source, CTDSPState *destination) {
    if (!transfer || !source || !destination || source != transfer->source || destination != transfer->destination) {
        return CTDSP_INVALID_ARGUMENT;
    }
    if (source->phase == CTDSP_STREAM_FAULTED || source->phase == CTDSP_STREAM_CANCELLED
        || destination->phase != CTDSP_STREAM_ACCEPTING
        || destination->counters.processed_frames || destination->counters.processed_blocks
        || destination->counters.rejected_blocks || destination->counters.clamped_samples) return CTDSP_INVALID_STATE;
    // All possible failures precede mutation. Equal preallocation was proved on
    // preparation; these immutable layouts cannot change while states are live.
    for (size_t index = 0; index < destination->operations.size(); ++index) {
        const auto sourceIndex = transfer->sources[index];
        if (sourceIndex == noHistorySource) continue;
        const auto &before = source->operations[sourceIndex];
        auto &after = destination->operations[index];
        switch (after.kind) {
        case CTDSP_BIQUAD:
            after.z1 = before.z1;
            after.z2 = before.z2;
            break;
        case CTDSP_INTEGER_DELAY:
            after.delay.copyHistoryFrom(before.delay);
            break;
        case CTDSP_FIR: after.fir->copyHistoryFrom(*before.fir); break;
        default: break;
        }
    }
    destination->counters = source->counters;
    destination->tail = transfer->info.changed_operations
        ? (source->counters.processed_frames ? destination->retainedTail : destination->initialTail) : source->tail;
    if (source->phase != CTDSP_STREAM_ACCEPTING) {
        // A coefficient/routing change may reveal retained memory that the old
        // output path muted. Its conservative extent starts at this copied
        // state, not at the old producer's END or elapsed drain count.
        if (transfer->info.changed_operations) return ctdsp_end_input(destination);
        destination->phase = source->phase;
        destination->remainingTail = source->remainingTail;
    }
    return CTDSP_OK;
}

namespace {
CTDSPStatus reject(CTDSPState *state, CTDSPStatus status) {
    ++state->counters.rejected_blocks;
    return status;
}

// Both source delivery and drain enter with first filled. Keep numerical
// operation order and final Float32 conversion identical for the two callers.
CTDSPStatus renderBlock(CTDSPState *state, float *output, uint32_t frames) {
    auto numericalFailure = [state]() {
        state->phase = CTDSP_STREAM_FAULTED;
        return reject(state, CTDSP_NUMERICAL_FAILURE);
    };
    double *current = state->first.data();
    double *scratch = state->second.data();
    uint32_t channels = state->inputChannels;
    uint64_t clamped = 0;
    for (auto &operation : state->operations) {
        if (operation.kind == CTDSP_MIXER) {
            std::fill(scratch, scratch + size_t(frames) * operation.outputChannels, 0.0);
            for (const auto &prepared : operation.connections) {
                const auto &connection = prepared.values;
                for (uint32_t frame = 0; frame < frames; ++frame) {
                    double &destination = scratch[size_t(frame) * operation.outputChannels + connection.destination];
                    const double contribution = current[size_t(frame) * channels + connection.source] * connection.gain;
                    // Assignment for the first contribution retains signed zero
                    // on a pure channel copy. Subsequent sources keep their order.
                    if (prepared.firstContribution) destination = contribution;
                    else destination += contribution;
                }
            }
            for (size_t index = 0; index < size_t(frames) * operation.outputChannels; ++index) {
                if (!std::isfinite(scratch[index])) return numericalFailure();
            }
            std::swap(current, scratch);
            channels = operation.outputChannels;
            continue;
        }
        if (operation.kind == CTDSP_FIR) {
            if (!operation.fir->process(current + operation.channel, channels, frames)) return numericalFailure();
            continue;
        }
        const auto *p = operation.parameters;
        switch (operation.kind) {
        case CTDSP_GAIN: {
            const double gain = p[0];
            for (uint32_t frame = 0; frame < frames; ++frame) {
                double &value = current[size_t(frame) * channels + operation.channel];
                value *= gain;
                if (!std::isfinite(value)) return numericalFailure();
            }
            break;
        }
        case CTDSP_INTEGER_DELAY:
            for (uint32_t frame = 0; frame < frames; ++frame) {
                double &value = current[size_t(frame) * channels + operation.channel];
                operation.delay.process(value);
                if (!std::isfinite(value)) return numericalFailure();
            }
            break;
        case CTDSP_BIQUAD: {
            const double b0 = p[0], b1 = p[1], b2 = p[2], a1 = p[3], a2 = p[4];
            double z1 = operation.z1, z2 = operation.z2;
            for (uint32_t frame = 0; frame < frames; ++frame) {
                double &value = current[size_t(frame) * channels + operation.channel];
                const double next = b0 * value + z1;
                z1 = b1 * value - a1 * next + z2;
                z2 = b2 * value - a2 * next;
                value = next;
                if (!std::isfinite(z1) || !std::isfinite(z2) || !std::isfinite(value)) {
                    operation.z1 = z1;
                    operation.z2 = z2;
                    return numericalFailure();
                }
            }
            operation.z1 = z1;
            operation.z2 = z2;
            break;
        }
        case CTDSP_HARD_LIMITER: {
            const double limit = p[0];
            for (uint32_t frame = 0; frame < frames; ++frame) {
                double &value = current[size_t(frame) * channels + operation.channel];
                if (value < -limit || value > limit) ++clamped;
                value = std::clamp(value, -limit, limit);
                if (!std::isfinite(value)) return numericalFailure();
            }
            break;
        }
        case CTDSP_SOFT_LIMITER: {
            const double limit = p[0];
            for (uint32_t frame = 0; frame < frames; ++frame) {
                double &value = current[size_t(frame) * channels + operation.channel];
                double scaled = value / limit;
                if (scaled < -1.5 || scaled > 1.5) ++clamped;
                scaled = std::clamp(scaled, -1.5, 1.5);
                value = (scaled - (1.0 / 6.75) * (scaled * scaled * scaled)) * limit;
                if (!std::isfinite(value)) return numericalFailure();
            }
            break;
        }
        default:
            break; // All tags and bus widths were resolved during preparation.
        }
    }
    const size_t outputSamples = size_t(frames) * channels;
    for (size_t index = 0; index < outputSamples; ++index) {
        if (!std::isfinite(current[index]) || std::abs(current[index]) > FLT_MAX) {
            return numericalFailure();
        }
    }
    for (size_t index = 0; index < outputSamples; ++index) output[index] = static_cast<float>(current[index]);
    state->counters.processed_frames += frames;
    ++state->counters.processed_blocks;
    state->counters.clamped_samples += clamped;
    return CTDSP_OK;
}

} // namespace

extern "C" CTDSPStatus ctdsp_process(CTDSPState *state, const float *input, size_t inputCount,
                                     float *output, size_t outputCount, uint32_t frames) {
    if (!state) return CTDSP_INVALID_ARGUMENT;
    if (state->phase == CTDSP_STREAM_FAULTED) return reject(state, CTDSP_RESET_REQUIRED);
    if (state->phase != CTDSP_STREAM_ACCEPTING) return reject(state, CTDSP_INVALID_STATE);
    if (!input || !output || frames == 0 || frames > state->maximumFrames
        || inputCount < size_t(frames) * state->inputChannels
        || outputCount < size_t(frames) * state->outputChannels) return reject(state, CTDSP_INVALID_ARGUMENT);
    const size_t inputSamples = size_t(frames) * state->inputChannels;
    for (size_t index = 0; index < inputSamples; ++index) {
        if (!std::isfinite(input[index])) return reject(state, CTDSP_NONFINITE_INPUT);
        state->first[index] = input[index];
    }
    return renderBlock(state, output, frames);
}

extern "C" CTDSPStatus ctdsp_end_input(CTDSPState *state) {
    if (!state) return CTDSP_INVALID_ARGUMENT;
    if (state->phase == CTDSP_STREAM_FAULTED) return CTDSP_RESET_REQUIRED;
    if (state->phase == CTDSP_STREAM_CANCELLED) return CTDSP_INVALID_STATE;
    if (state->phase != CTDSP_STREAM_ACCEPTING) return CTDSP_OK;
    state->remainingTail = state->counters.processed_frames ? state->tail.frames : 0;
    state->phase = state->counters.processed_frames && (state->tail.kind == TailKind::recursive || state->remainingTail)
        ? CTDSP_STREAM_DRAINING : CTDSP_STREAM_DRAINED;
    return CTDSP_OK;
}

extern "C" CTDSPStatus ctdsp_resume_input(CTDSPState *state) {
    if (!state) return CTDSP_INVALID_ARGUMENT;
    if (state->phase == CTDSP_STREAM_FAULTED) return CTDSP_RESET_REQUIRED;
    if (state->phase == CTDSP_STREAM_CANCELLED) return CTDSP_INVALID_STATE;
    state->phase = CTDSP_STREAM_ACCEPTING;
    state->remainingTail = 0;
    return CTDSP_OK;
}

extern "C" CTDSPStatus ctdsp_drain(CTDSPState *state, float *output, size_t outputCount,
                                   uint32_t frames, uint32_t *written) {
    if (written) *written = 0;
    if (!state) return CTDSP_INVALID_ARGUMENT;
    if (!written) return reject(state, CTDSP_INVALID_ARGUMENT);
    if (state->phase == CTDSP_STREAM_FAULTED) return reject(state, CTDSP_RESET_REQUIRED);
    if (state->phase != CTDSP_STREAM_DRAINING && state->phase != CTDSP_STREAM_DRAINED) return reject(state, CTDSP_INVALID_STATE);
    if (frames == 0 || frames > state->maximumFrames) return reject(state, CTDSP_INVALID_ARGUMENT);
    if (state->phase == CTDSP_STREAM_DRAINED) return CTDSP_OK;
    const uint32_t count = state->tail.kind == TailKind::recursive ? frames
        : static_cast<uint32_t>(std::min(uint64_t(frames), state->remainingTail));
    if (!output || outputCount < size_t(count) * state->outputChannels) return reject(state, CTDSP_INVALID_ARGUMENT);
    std::fill(state->first.begin(), state->first.begin() + size_t(count) * state->inputChannels, 0.0);
    const auto status = renderBlock(state, output, count);
    if (status != CTDSP_OK) return status;
    *written = count;
    if (state->tail.kind != TailKind::recursive) {
        state->remainingTail -= count;
        if (!state->remainingTail) state->phase = CTDSP_STREAM_DRAINED;
    }
    return CTDSP_OK;
}

extern "C" CTDSPStatus ctdsp_cancel(CTDSPState *state) {
    if (!state) return CTDSP_INVALID_ARGUMENT;
    state->phase = CTDSP_STREAM_CANCELLED;
    state->remainingTail = 0;
    return CTDSP_OK;
}

extern "C" CTDSPStatus ctdsp_read_stream_info(const CTDSPState *state, CTDSPStreamInfo *result) {
    if (!state || !result) return CTDSP_INVALID_ARGUMENT;
    *result = {uint32_t(state->phase), state->tail.kind == TailKind::recursive ? CTDSP_TAIL_RECURSIVE : CTDSP_TAIL_FINITE,
               state->tail.frames, state->remainingTail};
    return CTDSP_OK;
}

extern "C" CTDSPStatus ctdsp_read_tail_peak_bound(CTDSPState *state, double *result) {
    if (!state || !result) return CTDSP_INVALID_ARGUMENT;
    if (state->phase == CTDSP_STREAM_FAULTED) return CTDSP_RESET_REQUIRED;
    if (state->phase == CTDSP_STREAM_CANCELLED) return CTDSP_INVALID_STATE;
    double *current = state->first.data(), *scratch = state->second.data();
    uint32_t channels = state->inputChannels;
    std::fill(current, current + channels, 0.0);
    for (const auto &operation : state->operations) {
        if (operation.kind == CTDSP_MIXER) {
            std::fill(scratch, scratch + operation.outputChannels, 0.0);
            for (const auto &prepared : operation.connections) {
                const auto &connection = prepared.values;
                double &destination = scratch[connection.destination];
                destination = upperAdd(destination,
                    upperMultiply(current[connection.source], std::abs(connection.gain)));
            }
            for (uint32_t channel = 0; channel < operation.outputChannels; ++channel) {
                if (!std::isfinite(scratch[channel])) { *result = HUGE_VAL; return CTDSP_OK; }
            }
            std::swap(current, scratch);
            channels = operation.outputChannels;
            continue;
        }
        double &bound = current[operation.channel];
        switch (operation.kind) {
        case CTDSP_GAIN:
            bound = upperMultiply(bound, std::abs(operation.parameters[0]));
            break;
        case CTDSP_BIQUAD:
            bound = operation.tailBound.peak(operation.z1, operation.z2, bound, operation.parameters[0]);
            break;
        case CTDSP_INTEGER_DELAY:
            // Future output is either a retained sample or a future input.
            // Copying a delayed sample introduces no arithmetic roundoff.
            bound = std::max(bound, operation.delay.peak());
            break;
        case CTDSP_HARD_LIMITER:
            bound = std::min(bound, operation.parameters[0]);
            break;
        case CTDSP_SOFT_LIMITER:
            if (bound > 0) bound = upperAdd(upperMultiply(std::min(bound, operation.parameters[0]),
                1 + 64 * DBL_EPSILON), 64 * DBL_MIN);
            break;
        case CTDSP_FIR:
            bound = operation.fir->tailPeakBound(bound);
            break;
        default:
            *result = HUGE_VAL;
            return CTDSP_OK;
        }
        if (!std::isfinite(bound)) { *result = HUGE_VAL; return CTDSP_OK; }
    }
    *result = *std::max_element(current, current + channels);
    return CTDSP_OK;
}

extern "C" CTDSPStatus ctdsp_reset(CTDSPState *state) {
    if (!state) return CTDSP_INVALID_ARGUMENT;
    for (auto &operation : state->operations) {
        operation.z1 = operation.z2 = 0;
        if (operation.fir) operation.fir->reset();
        operation.delay.reset();
    }
    state->phase = CTDSP_STREAM_ACCEPTING;
    state->tail = state->initialTail;
    state->remainingTail = 0;
    state->counters = {};
    return CTDSP_OK;
}

extern "C" CTDSPStatus ctdsp_read_counters(const CTDSPState *state, CTDSPCounters *result) {
    if (!state || !result) return CTDSP_INVALID_ARGUMENT;
    *result = state->counters;
    return CTDSP_OK;
}

extern "C" CTDSPStatus ctdsp_read_format(const CTDSPState *state, CTDSPFormat *result) {
    if (!state || !result) return CTDSP_INVALID_ARGUMENT;
    *result = {state->inputChannels, state->outputChannels, state->maximumFrames};
    return CTDSP_OK;
}
