#import "PluginHost.h"
#include <array>
#include <atomic>
#include <algorithm>
#include <cmath>

namespace CamiTunePlugins {
namespace {
std::unique_ptr<Effect> instance(NSDictionary* slot, double rate, NSArray<NSString*>* roles) {
#ifdef CAMITUNE_PLUGIN_TESTING
    // Exercise AU fallback with system effects without requiring a vendor's
    // stereo-only component on the developer machine.
    NSUInteger limit = [slot[@"testMaximumChannels"] unsignedIntegerValue];
    if (limit && roles.count > limit) throw UnsupportedLayout("Fixture channel limit.");
#endif
    return [slot[@"plugin"][@"format"] isEqual:@"AU"] ? makeAU(slot, rate, roles) : makeVST3(slot, rate, roles);
}

// One instrument voice engine, even on a surround profile. Stereo instruments
// feed the front pair; effects after this slot receive the mixed result.
class InstrumentEffect final : public Effect {
    std::unique_ptr<Effect> inner;
    uint32_t channels, width;
    std::vector<uint32_t> destinations;
    std::array<std::array<float, maximumFrames>, maximumChannels> silence{}, generated{};
public:
    InstrumentEffect(std::unique_ptr<Effect> value, NSArray<NSString*>* roles, uint32_t sourceWidth)
        : inner(std::move(value)), channels((uint32_t)roles.count), width(sourceWidth) {
        if (width == channels) for (uint32_t c = 0; c < channels; ++c) destinations.push_back(c);
        else if (channels == 1) destinations = {0};
        else {
            NSUInteger left = [roles indexOfObject:@"left"], right = [roles indexOfObject:@"right"];
            destinations = {(uint32_t)(left == NSNotFound ? 0 : left), (uint32_t)(right == NSNotFound ? 1 : right)};
            if (destinations[0] == destinations[1]) destinations = {0, 1};
        }
    }
    bool render(float* const* input, float** output, uint32_t frames) override {
        float* in[maximumChannels], *out[maximumChannels];
        for (uint32_t c = 0; c < width; ++c) {
            std::fill_n(silence[c].data(), frames, 0.f); std::fill_n(generated[c].data(), frames, 0.f);
            in[c] = silence[c].data(); out[c] = generated[c].data();
        }
        if (!inner->render(in, out, frames)) return false;
        for (uint32_t c = 0; c < channels; ++c) std::copy_n(input[c], frames, output[c]);
        for (uint32_t f = 0; f < frames; ++f) {
            if (channels == 1 && width == 2) output[0][f] += .5f * (generated[0][f] + generated[1][f]);
            else for (size_t c = 0; c < destinations.size(); ++c) output[destinations[c]][f] += generated[width == 1 ? 0 : c][f];
        }
        return true;
    }
    bool isInstrument() override { return true; }
    NSArray<NSDictionary*>* sidechainBuses() override { return inner->sidechainBuses(); }
    void setSidechain(float* const* stereo) override { inner->setSidechain(stereo); }
    void reset() override { inner->reset(); }
    uint32_t latency() override { return inner->latency(); }
    double tailSeconds() override { return inner->tailSeconds(); }
    NSData* saveState() override { return inner->saveState(); }
    NSArray<NSDictionary*>* parameters() override { return inner->parameters(); }
    void setParameter(uint64_t id, double value) override { inner->setParameter(id, value); }
    void scheduleParameter(uint64_t id, double value) override { inner->scheduleParameter(id, value); }
    void observeParameters(ParameterObserver observer) override { inner->observeParameters(std::move(observer)); }
    bool acceptsMIDI() override { return inner->acceptsMIDI(); }
    void midi(const MIDIMessage& message) override { inner->midi(message); }
    void clearMIDI() override { inner->clearMIDI(); }
    void syncParameters() override { inner->syncParameters(); }
    void editor(NSView* parent, EditorCompletion completion) override { inner->editor(parent, completion); }
    void closeEditor() override { inner->closeEditor(); }
    bool flushParameters() override { return inner->flushParameters(); }
    void idle() override { inner->idle(); }
    std::string failure() override { return inner->failure(); }
};

// UI/automation callbacks only publish values. Each audio block consumes a
// single set of changes for all copies; no preset serialization or UI calls
// are allowed on the render worker.
struct ParameterMailbox {
    static constexpr size_t capacity = 4096;
    size_t count = 0;
    std::array<uint64_t, capacity> ids{};
    std::array<std::atomic<double>, capacity> values{};
    std::array<std::atomic<bool>, capacity> dirty{};
    void put(uint64_t id, double value) {
        if (!std::isfinite(value)) return;
        for (size_t i = 0; i < count; ++i) if (ids[i] == id) {
            values[i].store(value, std::memory_order_relaxed);
            dirty[i].store(true, std::memory_order_release); return;
        }
    }
};

class LinkedEffect final : public Effect {
    struct Copy { std::unique_ptr<Effect> effect; std::vector<uint32_t> channels; };
    std::vector<Copy> copies;
    uint32_t width;
    std::shared_ptr<ParameterMailbox> edits = std::make_shared<ParameterMailbox>();
    std::array<std::array<float, maximumFrames>, 2> monoInput{}, monoOutput{};
    std::string error;
    std::shared_ptr<ParameterObserver> observer = std::make_shared<ParameterObserver>();

    void applyEdits() {
        for (size_t i = 0; i < edits->count; ++i) if (edits->dirty[i].exchange(false, std::memory_order_acquire)) {
            double value = edits->values[i].load(std::memory_order_relaxed);
            for (auto& copy : copies) copy.effect->scheduleParameter(edits->ids[i], value);
        }
    }
public:
    LinkedEffect(NSDictionary* slot, double rate, NSArray<NSString*>* roles) {
        // Keep the same instance width for every group, so one editor/preset
        // has the same parameter schema and algorithmic latency everywhere.
        std::unique_ptr<Effect> first;
        NSArray<NSString*>* format = @[@"left", @"right"];
        try { first = instance(slot, rate, format); width = 2; }
        catch (const UnsupportedLayout&) { format = @[@"center"]; first = instance(slot, rate, format); width = 1; }

        std::vector<std::vector<uint32_t>> groups;
        std::array<bool, maximumChannels> used{};
        if (width == 2) {
            NSArray<NSArray<NSString*>*>* pairs = @[@[@"left", @"right"], @[@"leftSurround", @"rightSurround"],
                @[@"leftRearSurround", @"rightRearSurround"], @[@"topFrontLeft", @"topFrontRight"],
                @[@"topMiddleLeft", @"topMiddleRight"], @[@"topRearLeft", @"topRearRight"],
                @[@"frontLeftCenter", @"frontRightCenter"], @[@"wideLeft", @"wideRight"]];
            for (NSArray<NSString*>* pair in pairs) {
                // Duplicate/custom roles are separate signals, never guessed
                // to be a stereo pair. Center and LFE are always independent.
                if ([[roles filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == %@", pair[0]]] count] != 1
                    || [[roles filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == %@", pair[1]]] count] != 1) continue;
                uint32_t left = (uint32_t)[roles indexOfObject:pair[0]], right = (uint32_t)[roles indexOfObject:pair[1]];
                groups.push_back({left, right}); used[left] = used[right] = true;
            }
        }
        for (uint32_t c = 0; c < roles.count; ++c) if (!used[c]) groups.push_back({c});
        for (auto& group : groups) copies.push_back({copies.empty() ? std::move(first) : instance(slot, rate, format), group});
        NSArray<NSDictionary*>* parameters = copies[0].effect->parameters();
        if (parameters.count > ParameterMailbox::capacity) throw std::runtime_error("This effect has too many parameters to link across channels.");
        for (NSDictionary* parameter in parameters) edits->ids[edits->count++] = [parameter[@"id"] unsignedLongLongValue];
        auto mailbox = edits;
        auto external = observer;
        copies[0].effect->observeParameters([mailbox, external](uint64_t id, double value, bool touch) {
            if (touch) mailbox->put(id, value);
            if (*external) (*external)(id, value, touch);
        });
        // Start every instance with exactly the editor's current values, even
        // when the plug-in chooses instance-dependent defaults.
        for (NSDictionary* parameter in parameters) edits->put([parameter[@"id"] unsignedLongLongValue], [parameter[@"value"] doubleValue]);
        idle();
        if (!error.empty()) throw std::runtime_error(error);
    }
    ~LinkedEffect() override { copies[0].effect->observeParameters({}); }
    bool render(float* const* input, float** output, uint32_t frames) override {
        applyEdits();
        for (auto& copy : copies) {
            uint32_t left = copy.channels[0];
            if (width == 2 && copy.channels.size() == 1) {
                // A stereo-only effect on a single speaker sees dual mono;
                // fold its result back at unity gain without touching a neighbor.
                for (int c = 0; c < 2; ++c) memcpy(monoInput[c].data(), input[left], frames * sizeof(float));
                float* in[2]{monoInput[0].data(), monoInput[1].data()}, *out[2]{monoOutput[0].data(), monoOutput[1].data()};
                if (!copy.effect->render(in, out, frames)) return false;
                for (uint32_t f = 0; f < frames; ++f) output[left][f] = .5f * (out[0][f] + out[1][f]);
            } else {
                uint32_t right = copy.channels.back();
                float* in[2]{input[left], input[right]}, *out[2]{output[left], output[right]};
                if (!copy.effect->render(in, out, frames)) return false;
            }
        }
        return true;
    }
    bool flushParameters() override {
        applyEdits();
        for (auto& copy : copies) if (!copy.effect->flushParameters()) return false;
        return true;
    }
    void reset() override { for (auto& copy : copies) copy.effect->reset(); }
    uint32_t latency() override { return copies[0].effect->latency(); }
    uint32_t instanceCount() override { return (uint32_t)copies.size(); }
    double tailSeconds() override { double tail = 0; for (auto& copy : copies) tail = std::max(tail, copy.effect->tailSeconds()); return tail; }
    NSData* saveState() override { return copies[0].effect->saveState(); }
    NSArray<NSDictionary*>* parameters() override { return copies[0].effect->parameters(); }
    void setParameter(uint64_t id, double value) override { copies[0].effect->setParameter(id, value); edits->put(id, value); if (*observer) (*observer)(id, value, true); }
    void scheduleParameter(uint64_t id, double value) override { edits->put(id, value); }
    void observeParameters(ParameterObserver value) override { *observer = std::move(value); }
    bool acceptsMIDI() override { return copies[0].effect->acceptsMIDI(); }
    NSArray<NSDictionary*>* sidechainBuses() override { return copies[0].effect->sidechainBuses(); }
    void setSidechain(float* const* stereo) override { for (auto& copy : copies) copy.effect->setSidechain(stereo); }
    void midi(const MIDIMessage& message) override { for (auto& copy : copies) copy.effect->midi(message); }
    void clearMIDI() override { for (auto& copy : copies) copy.effect->clearMIDI(); }
    void syncParameters() override { copies[0].effect->syncParameters(); }
    void editor(NSView* parent, EditorCompletion completion) override {
        // Parameter edits already reach every copy through the mailbox. On
        // close, the app prepares a replacement rack from the captured full
        // preset, so private assets/programs also reach every channel safely.
        copies[0].effect->editor(parent, completion);
    }
    void closeEditor() override { copies[0].effect->closeEditor(); }
    void idle() override {
        for (auto& copy : copies) {
            copy.effect->idle();
            if (!copy.effect->failure().empty()) error = copy.effect->failure();
        }
        // Equal formats and linked settings should have equal latency. Never
        // silently play misaligned channels if a plug-in violates that contract.
        for (auto& copy : copies) if (copy.effect->latency() != latency())
            error = "The plug-in's linked channels reported different delays. Reload the rack to realign them.";
    }
    std::string failure() override { return error; }
};
}

std::unique_ptr<Effect> makeChannelEffect(NSDictionary* slot, double rate, NSArray<NSString*>* roles) {
    bool instrument = [slot[@"plugin"][@"kind"] isEqual:@"instrument"]
        || [slot[@"plugin"][@"componentType"] unsignedIntValue] == 0x61756d75
        || [slot[@"plugin"][@"componentType"] unsignedIntValue] == 0x6175676e;
    try {
        auto effect = instance(slot, rate, roles);
        if (effect->isInstrument()) return std::make_unique<InstrumentEffect>(std::move(effect), roles, (uint32_t)roles.count);
        return effect;
    } catch (const UnsupportedLayout& error) {
        if (!instrument && !error.instrument) return std::make_unique<LinkedEffect>(slot, rate, roles);
        std::unique_ptr<Effect> effect; uint32_t width = 2;
        try { effect = instance(slot, rate, @[@"left", @"right"]); }
        catch (const UnsupportedLayout&) { width = 1; effect = instance(slot, rate, @[@"center"]); }
        return std::make_unique<InstrumentEffect>(std::move(effect), roles, width);
    }
}
}
