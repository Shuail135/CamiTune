#pragma once
#import <AppKit/AppKit.h>
#include <memory>
#include <string>
#include <vector>
#include <functional>
#include <stdexcept>

namespace CamiTunePlugins {
constexpr uint32_t maximumFrames = 2048;
constexpr uint32_t maximumChannels = 32;
constexpr size_t maximumStateBytes = 4 * 1024 * 1024;
constexpr uint32_t protocolVersion = 3;
struct UnsupportedLayout : std::runtime_error {
    bool instrument;
    explicit UnsupportedLayout(const char* message, bool isInstrument = false) : std::runtime_error(message), instrument(isInstrument) {}
};
using ParameterObserver = std::function<void(uint64_t, double, bool)>;
// The parent is already installed in a real window before vendor UI code runs.
// nil/nil means no native editor; a non-nil error must not silently fall back.
using EditorCompletion = void (^)(NSView*, NSString*);
struct MIDIMessage { uint64_t timestamp = 0; int32_t source = 0; uint8_t status = 0, data1 = 0, data2 = 0; };

// The socket is the ownership handoff for the shared sample buffer. Exactly one
// request can be outstanding; a timed-out connection is permanently retired.
struct AudioRequest { uint32_t version, frames, sequence, reset; };
struct AudioReply { uint32_t version, status, sequence, reserved; };

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
    virtual void setSidechain(float* const* stereo) {}
    virtual NSData* saveState() = 0;
    virtual NSArray<NSDictionary*>* parameters() = 0;
    virtual void setParameter(uint64_t identifier, double value) = 0;
    // The observer may run on any thread. The adapter only writes preallocated
    // atomics there, then schedules every linked copy on the audio worker.
    virtual void observeParameters(ParameterObserver observer) {}
    virtual void scheduleParameter(uint64_t identifier, double value) = 0;
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
