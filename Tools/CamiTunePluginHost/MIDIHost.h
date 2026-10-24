#pragma once
#include "PluginHost.h"

namespace CamiTunePlugins {
NSArray<NSDictionary*>* midiSources();
class MIDIHost {
    struct Impl;
    std::unique_ptr<Impl> impl;
public:
    MIDIHost(std::vector<std::unique_ptr<Effect>>& effects, NSArray<NSDictionary*>* slots,
             std::function<void()> wakeWorker);
    ~MIDIHost();
    void configure(NSDictionary* configuration);
    void command(NSDictionary* command);
    void process(); // audio worker: bounded, no allocation, locks or UI calls
    void idle(); // main thread: coalesced control display and learning results
    bool needsIdle();
    double parameterValue(size_t slot, uint64_t id, double fallback);
    bool takeStateChanges();
};
}
