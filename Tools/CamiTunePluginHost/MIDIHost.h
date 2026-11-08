#pragma once
#include "PluginHost.h"

namespace CamiTunePlugins {
NSArray<NSDictionary*>* midiSources();
class MIDIHost {
    struct Impl;
    std::unique_ptr<Impl> impl;
public:
    MIDIHost(std::vector<std::unique_ptr<Effect>>& effects, NSArray<NSDictionary*>* slots, double sampleRate,
             std::function<void()> wakeWorker);
    ~MIDIHost();
    void configure(NSDictionary* configuration);
    void command(NSDictionary* command);
    // A zero-frame pass flushes due controls at rest without advancing audio.
    void process(uint64_t hostTimeNanoseconds, uint32_t frames); // bounded audio-worker work
    int inputWaitMilliseconds(); // audio worker: next scheduled control, or -1
    void idle(); // main thread: coalesced control display and learning results
    bool needsIdle();
    double parameterValue(size_t slot, uint64_t id, double fallback);
    bool takeStateChanges();
};
}
