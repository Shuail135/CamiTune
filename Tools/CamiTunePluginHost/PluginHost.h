#pragma once
#import <AppKit/AppKit.h>
#include <memory>
#include <string>
#include <vector>
#include <functional>
#include <stdexcept>
#include <cmath>
#include <atomic>
#include <mach/mach_time.h>

namespace CamiTunePlugins {
constexpr uint32_t maximumFrames = 2048;
constexpr uint32_t maximumChannels = 32;
constexpr size_t maximumStateBytes = 4 * 1024 * 1024;
constexpr size_t maximumParameters = 65536;
constexpr uint32_t protocolVersion = 4;
struct UnsupportedLayout : std::runtime_error {
    bool instrument;
    explicit UnsupportedLayout(const char* message, bool isInstrument = false) : std::runtime_error(message), instrument(isInstrument) {}
};
using ParameterObserver = std::function<void(uint64_t, double, bool)>;
// The parent is already installed in a real window before vendor UI code runs.
// nil/nil means no native editor; a non-nil error must not silently fall back.
using EditorCompletion = void (^)(NSView*, NSString*);
struct HostClock {
    mach_timebase_info_data_t timebase{};
    HostClock() { mach_timebase_info(&timebase); }
    uint64_t nanoseconds(uint64_t ticks) const {
        __uint128_t value = (__uint128_t)ticks * timebase.numer / timebase.denom;
        return value > UINT64_MAX ? UINT64_MAX : static_cast<uint64_t>(value);
    }
    uint64_t nowNanoseconds() const { return nanoseconds(mach_absolute_time()); }
};
struct MIDIMessage {
    uint64_t timestamp = 0;
    int32_t source = 0;
    uint8_t status = 0, data1 = 0, data2 = 0;
    uint32_t sampleOffset = 0;
};

inline void recordParameterGesture(std::atomic<uint64_t>& latest, uint64_t timestamp) {
    uint64_t previous = latest.load(std::memory_order_relaxed);
    while (previous < timestamp && !latest.compare_exchange_weak(previous, timestamp,
        std::memory_order_release, std::memory_order_relaxed)) {}
}

// The socket is the ownership handoff for the shared sample buffer. Exactly one
// request can be outstanding; a timed-out connection is permanently retired.
// Mach ticks differ under Rosetta. Every architecture group receives the same
// render interval in uptime nanoseconds, not a hardware presentation timestamp.
struct AudioRequest { uint32_t version, frames, sequence, reset; uint64_t hostTimeNanoseconds; };
static_assert(sizeof(AudioRequest) == 24);
struct AudioReply { uint32_t version, status, sequence, reserved; };

inline float sidechainSample(const float* stereo, uint32_t channels, uint32_t channel, uint32_t frame) {
    if (!stereo || channel >= 2) return 0;
    float value = stereo[frame * 2 + channel];
    if (!std::isfinite(value)) value = 0;
    if (channels != 1) return value;
    float right = stereo[frame * 2 + 1];
    return .5f * (value + (std::isfinite(right) ? right : 0));
}

class Effect {
public:
    virtual ~Effect() = default;
    virtual bool render(float* const* input, float** output, uint32_t frames) = 0;
    virtual void reset() = 0;
    virtual uint32_t latency() = 0;
    virtual double tailSeconds() = 0;
    virtual uint32_t instanceCount() { return 1; }
    virtual bool isInstrument() { return false; }
    virtual NSArray<NSDictionary*>* sidechainBuses() { return @[]; }
    virtual void setSidechain(const float* interleavedStereo) {}
    virtual NSData* saveState() = 0;
    virtual NSArray<NSDictionary*>* parameters() = 0;
    virtual void setParameter(uint64_t identifier, double value) = 0;
    // The observer may run on any thread. The adapter only writes preallocated
    // atomics there, then schedules every linked copy on the audio worker.
    virtual void observeParameters(ParameterObserver observer) {}
    // Preserve the originating editor gesture across linked copies. A queued
    // older MIDI controller must not overwrite a newer manual parameter edit.
    virtual void scheduleParameter(uint64_t identifier, double value, uint64_t gestureTime = 0) = 0;
    virtual bool acceptsMIDI() { return false; }
    // Audio-worker only. MIDI is consumed in the existing render cycle.
    virtual void midi(const MIDIMessage& message) {}
    virtual void clearMIDI() {}
    virtual void syncParameters() {} // main thread, coalesced controller updates
    virtual void editor(NSView* parent, EditorCompletion completion) = 0;
    virtual void closeEditor() {}
    // Audio worker only. Deliver pending edits at rest without rendering any
    // samples or advancing filter, delay, transport, or tail history.
    virtual bool flushParameters() { return true; }
    virtual void idle() {}
    virtual std::string failure() { return {}; }
};

std::unique_ptr<Effect> makeAU(NSDictionary* slot, double rate, NSArray<NSString*>* roles);
std::unique_ptr<Effect> makeVST3(NSDictionary* slot, double rate, NSArray<NSString*>* roles);
std::unique_ptr<Effect> makeChannelEffect(NSDictionary* slot, double rate, NSArray<NSString*>* roles);
NSArray<NSDictionary*>* scanAU();
NSArray<NSDictionary*>* scanVST3(NSString* path);
void emit(NSDictionary* event);
}
