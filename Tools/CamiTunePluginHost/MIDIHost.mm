#import "MIDIHost.h"
#import <CoreMIDI/CoreMIDI.h>
#include <array>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <unordered_map>

namespace CamiTunePlugins {
namespace {
// Bounded MPMC queue: CoreMIDI may call back concurrently for different sources.
// Contention/overflow never waits on a producer; the consumer releases notes.
template<class T, size_t N> class Queue {
    struct Cell { std::atomic<size_t> sequence; T value; };
    std::array<Cell, N> cells;
    std::atomic<size_t> head{0}, tail{0};
public:
    Queue() { for (size_t i = 0; i < N; ++i) cells[i].sequence = i; }
    bool push(const T& value) {
        size_t at = head.load(std::memory_order_relaxed);
        for (int attempt = 0; attempt < 16; ++attempt) {
            auto& cell = cells[at % N]; auto sequence = cell.sequence.load(std::memory_order_acquire);
            auto difference = (intptr_t)sequence - (intptr_t)at;
            if (difference < 0) return false;
            if (difference == 0 && head.compare_exchange_weak(at, at + 1, std::memory_order_relaxed)) {
                cell.value = value; cell.sequence.store(at + 1, std::memory_order_release); return true;
            }
            at = head.load(std::memory_order_relaxed);
        }
        return false;
    }
    bool pop(T& value) {
        size_t at = tail.load(std::memory_order_relaxed);
        auto& cell = cells[at % N];
        if (cell.sequence.load(std::memory_order_acquire) != at + 1) return false;
        value = cell.value; cell.sequence.store(at + N, std::memory_order_release);
        tail.store(at + 1, std::memory_order_relaxed); return true;
    }
};
struct Parameter {
    uint64_t id; double minimum, maximum;
    std::atomic<double> value;
    std::atomic<bool> changed{false};
    double mappedValue = 0; bool mappedDirty = false; // audio worker only
    Parameter(NSDictionary* p) : id([p[@"id"] unsignedLongLongValue]), minimum([p[@"min"] doubleValue]),
        maximum([p[@"max"] doubleValue]), value([p[@"value"] doubleValue]) {}
};
struct ParameterCache {
    NSArray<NSDictionary*>* metadata;
    std::vector<std::unique_ptr<Parameter>> parameters;
    std::unordered_map<uint64_t, int> indices;
    std::atomic<int> touched{-1};
    explicit ParameterCache(NSArray<NSDictionary*>* metadata) : metadata(metadata) {
        for (NSDictionary* p in metadata) {
            indices.emplace([p[@"id"] unsignedLongLongValue], (int)parameters.size());
            parameters.push_back(std::make_unique<Parameter>(p));
        }
    }
    int index(uint64_t id) const { auto found = indices.find(id); return found == indices.end() ? -1 : found->second; }
    void put(uint64_t id, double value, bool touch) {
        int i = index(id); if (i < 0 || !std::isfinite(value)) return;
        auto& p = *parameters[i]; p.value = std::clamp(value, p.minimum, p.maximum); p.changed = true;
        if (touch) touched = i;
    }
};
struct Mapping {
    int slot = 0, parameter = 0, channel = 0, controller = 0; int32_t source = 0;
    double lower = 0, upper = 1; bool pickup = true, acquired = false; double previous = -1, lastApplied = -1;
    bool note = false, pressed = false; int mode = 0, curve = 0;
};
struct Routing {
    bool enabled = false; int32_t source = 0; int channel = 0; uint32_t generation = 0;
    int programSlot = -1;
    size_t count = 0; std::array<Mapping, 256> mappings{};
};
struct Incoming { MIDIMessage message; uint32_t generation; };
struct Learned { MIDIMessage message; int slot, parameter; };
}

NSArray<NSDictionary*>* midiSources() {
    NSMutableArray* sources = [NSMutableArray array];
    for (ItemCount i = 0; i < MIDIGetNumberOfSources(); ++i) {
        MIDIEndpointRef endpoint = MIDIGetSource(i); SInt32 id = 0, offline = 0; CFStringRef name = nullptr;
        if (MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id) || !id) continue;
        MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline); if (offline) continue;
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name);
        [sources addObject:@{@"id": @(id), @"name": name ? (__bridge NSString*)name : @"MIDI input"}];
        if (name) CFRelease(name);
    }
    return sources;
}

struct MIDIHost::Impl {
    std::vector<std::unique_ptr<Effect>>& effects;
    NSArray<NSDictionary*>* slots;
    std::vector<std::shared_ptr<ParameterCache>> caches;
    Queue<Incoming, 1024> incoming;
    Queue<Routing, 8> configurations;
    Queue<Learned, 16> learned;
    Routing routing{}, pending{}; bool hasPending = false;
    std::atomic<uint32_t> generation{0};
    std::atomic<bool> accepting{false}, panic{false}, overflow{false}, discardInput{false}, dirtyState{false};
    std::atomic<bool> inspectorOpen{false};
    double lastChange = 0;
    std::atomic<int> learnSlot{-1}, learnParameter{-1};
    int watching = -1; int inspected = -1;
    MIDIClientRef client = 0; MIDIPortRef port = 0;
    NSDictionary* configuration = @{};
    std::vector<MIDIEndpointRef> connected;
    std::string error;

    Impl(std::vector<std::unique_ptr<Effect>>& effects, NSArray<NSDictionary*>* slots) : effects(effects), slots(slots) {
        for (auto& effect : effects) {
            auto cache = std::make_shared<ParameterCache>(effect->parameters()); caches.push_back(cache);
            effect->observeParameters([cache](uint64_t id, double value, bool touch) { cache->put(id, value, touch); });
        }
    }
    ~Impl() {
        accepting = false;
        if (port) MIDIPortDispose(port);
        if (client) MIDIClientDispose(client);
        for (auto& effect : effects) effect->observeParameters({});
    }
    int slotIndex(NSString* id) { for (int i = 0; i < slots.count; ++i) if ([slots[i][@"id"] isEqual:id]) return i; return -1; }
    void receive(const MIDIMessage& message) {
        if (!accepting.load(std::memory_order_acquire)) return;
        uint8_t kind = message.status & 0xf0;
        if (kind < 0x80 || kind > 0xe0 || message.data1 > 127 || message.data2 > 127) return;
        if (!incoming.push({message, generation.load(std::memory_order_acquire)})) { panic = true; overflow = true; discardInput = true; }
    }
    void connect() {
        accepting = false; panic = true;
        for (auto endpoint : connected) MIDIPortDisconnectSource(port, endpoint);
        connected.clear(); error.clear();
        if (![configuration[@"isEnabled"] boolValue]) { publishSources(); return; }
        if (!client) {
            OSStatus status = MIDIClientCreateWithBlock(CFSTR("CamiTune plug-ins"), &client, ^(const MIDINotification* notification) {
                // No work in CoreMIDI's notification callback.
                if (notification->messageID == kMIDIMsgObjectAdded || notification->messageID == kMIDIMsgObjectRemoved
                    || notification->messageID == kMIDIMsgPropertyChanged || notification->messageID == kMIDIMsgSetupChanged)
                    dispatch_async(dispatch_get_main_queue(), ^{ reconnectIfNeeded(); });
            });
            if (status) { error = "MIDI input could not start."; publishSources(); return; }
        }
        if (!port) {
            OSStatus status = MIDIInputPortCreateWithProtocol(client, CFSTR("Plug-in input"), kMIDIProtocol_1_0, &port,
                ^(const MIDIEventList* list, void* context) {
                    const MIDIEventPacket* packet = &list->packet[0];
                    for (UInt32 p = 0; p < list->numPackets; ++p, packet = MIDIEventPacketNext(packet)) {
                        for (UInt32 w = 0; w < packet->wordCount;) {
                            uint32_t word = packet->words[w]; uint8_t type = word >> 28;
                            // CoreMIDI converts MIDI 2.0 sources to MIDI 1.0 UMP for this port.
                            if (type == 2) receive({packet->timeStamp, (int32_t)(intptr_t)context,
                                (uint8_t)(word >> 16), (uint8_t)(word >> 8), (uint8_t)word});
                            static const uint8_t lengths[16]{1,1,1,2,2,4,1,1,2,2,2,3,3,4,4,4};
                            w += lengths[type];
                        }
                    }
                });
            if (status) { error = "The MIDI input port could not open."; publishSources(); return; }
        }
        int32_t selected = [configuration[@"sourceID"] intValue];
        for (ItemCount i = 0; i < MIDIGetNumberOfSources(); ++i) {
            auto endpoint = MIDIGetSource(i); SInt32 id = 0, offline = 0;
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id);
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline);
            if (!id || offline || (selected && id != selected)) continue;
            if (!MIDIPortConnectSource(port, endpoint, (void*)(intptr_t)id)) connected.push_back(endpoint);
        }
        accepting.store(true, std::memory_order_release); publishSources();
    }
    void reconnectIfNeeded() {
        // Coalesce changes by comparing source identity rather than reopening on every notification.
        NSArray* current = midiSources(); NSMutableSet* expected = [NSMutableSet set];
        int32_t selected = [configuration[@"sourceID"] intValue];
        for (NSDictionary* source in current) if (!selected || [source[@"id"] intValue] == selected) [expected addObject:source[@"id"]];
        NSMutableSet* actual = [NSMutableSet set];
        for (auto endpoint : connected) { SInt32 id = 0; if (!MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id)) [actual addObject:@(id)]; }
        if ([configuration[@"isEnabled"] boolValue] && (![expected isEqual:actual] || actual.count != connected.size())) {
            generation.fetch_add(1); connect();
            pending.generation = generation.load(); hasPending = !configurations.push(pending);
        } else publishSources();
    }
    void publishSources() {
        emit(@{@"event": @"midiStatus", @"sources": midiSources(), @"connected": @(connected.size()), @"message": @(error.c_str())});
    }
    void configure(NSDictionary* config) {
        bool reconnect = [configuration[@"isEnabled"] boolValue] != [config[@"isEnabled"] boolValue]
            || [configuration[@"sourceID"] intValue] != [config[@"sourceID"] intValue];
        configuration = [config copy];
        if (![config[@"isEnabled"] boolValue]) { learnSlot = -1; watching = -1; }
        Routing next{}; next.enabled = [config[@"isEnabled"] boolValue];
        next.source = [config[@"sourceID"] intValue]; next.channel = std::clamp([config[@"channel"] intValue], 0, 16);
        next.programSlot = slotIndex(config[@"programChangeSlotID"]);
        next.generation = generation.fetch_add(1) + 1;
        for (NSDictionary* item in config[@"mappings"]) {
            if (next.count == next.mappings.size()) break;
            int slot = slotIndex(item[@"slotID"]); if (slot < 0) continue;
            int parameter = caches[slot]->index([item[@"parameterID"] unsignedLongLongValue]); if (parameter < 0) continue;
            int channel = [item[@"channel"] intValue], cc = [item[@"controller"] intValue];
            double lower = [item[@"lower"] doubleValue], upper = [item[@"upper"] doubleValue];
            bool note = [item[@"input"] isEqual:@"note"];
            if (channel < 1 || channel > 16 || cc < 0 || cc > (note ? 127 : 119) || !std::isfinite(lower) || !std::isfinite(upper)
                || lower < 0 || lower > 1 || upper < 0 || upper > 1) continue;
            auto& map = next.mappings[next.count++];
            map = {slot, parameter, channel, cc, [item[@"sourceID"] intValue], lower, upper, (bool)[item[@"pickup"] boolValue]};
            map.note = note;
            NSString* mode = item[@"mode"], *curve = item[@"curve"];
            map.mode = [mode isEqual:@"button"] ? 1 : [mode isEqual:@"toggle"] ? 2 : [mode isEqual:@"velocity"] ? 3 : 0;
            map.curve = [curve isEqual:@"soft"] ? 1 : [curve isEqual:@"hard"] ? 2 : [curve isEqual:@"sCurve"] ? 3 : 0;
        }
        pending = next; hasPending = !configurations.push(next); panic = true;
        if (reconnect) connect(); else publishSources();
    }
    void process() {
        while (configurations.pop(routing)) {}
        if (discardInput.exchange(false)) { Incoming discarded{}; for (int i = 0; i < 1024 && incoming.pop(discarded); ++i) {} }
        if (panic.exchange(false)) for (auto& effect : effects) { effect->clearMIDI(); }
        Incoming item{};
        for (int n = 0; n < 1024 && incoming.pop(item); ++n) {
            auto& message = item.message; int channel = (message.status & 15) + 1;
            if (!routing.enabled || item.generation != routing.generation || (routing.source && routing.source != message.source)
                || (routing.channel && routing.channel != channel)) continue;
            if ((message.status & 0xf0) == 0xc0) {
                if (routing.programSlot >= 0) {
                    effects[routing.programSlot]->midi(message);
                    dirtyState = true;
                }
                continue; // Never broadcast program selection or consume it for Learn.
            }
            bool cc = (message.status & 0xf0) == 0xb0 && message.data1 < 120;
            bool note = (message.status & 0xf0) == 0x90 || (message.status & 0xf0) == 0x80;
            bool noteOn = (message.status & 0xf0) == 0x90 && message.data2 > 0;
            int learning = learnSlot.load();
            if ((cc || noteOn) && learning >= 0) {
                int parameter = learnParameter.load();
                if (parameter >= 0 && learnSlot.compare_exchange_strong(learning, -1)) learned.push({message, learning, parameter});
                continue; // Learning never jumps an existing assignment.
            }
            std::array<bool, 16> consumed{};
            if (cc || note) for (size_t i = 0; i < routing.count; ++i) {
                auto& map = routing.mappings[i];
                if (map.note != note || map.source != message.source || map.channel != channel || map.controller != message.data1) continue;
                consumed[map.slot] = true;
                auto& p = *caches[map.slot]->parameters[map.parameter];
                double raw = note && !noteOn ? 0 : message.data2 / 127.0;
                double current = (p.value.load() - p.minimum) / (p.maximum - p.minimum);
                bool pressed = note ? noteOn : raw >= 0.5;
                bool rising = pressed && !map.pressed;
                map.pressed = pressed;
                if (map.mode == 2) {
                    // Toggle only on a rising edge, including note-on velocity > 0.
                    if (!rising) continue;
                    raw = std::abs(current - map.upper) < std::abs(current - map.lower) ? 0 : 1;
                } else if (map.mode == 1) raw = pressed ? 1 : 0;
                else {
                    if (note && !noteOn) continue; // Velocity holds its value after note-off.
                    switch (map.curve) {
                        case 1: raw = std::sqrt(raw); break;
                        case 2: raw *= raw; break;
                        case 3: raw = raw * raw * (3 - 2 * raw); break;
                        default: break;
                    }
                }
                double normalized = map.lower + raw * (map.upper - map.lower);
                bool pickup = map.pickup && map.mode == 0 && !note;
                if (pickup && map.acquired && std::abs(current - map.lastApplied) > 0.015) map.acquired = false;
                if (!pickup || std::abs(current - normalized) <= std::max(1.0 / 127, std::abs(map.upper-map.lower) / 127)
                    || (map.previous >= 0 && (map.previous-current)*(normalized-current) <= 0)) map.acquired = true;
                map.previous = normalized;
                if (!map.acquired) continue;
                map.lastApplied = normalized;
                double value = p.minimum + normalized * (p.maximum - p.minimum);
                p.mappedValue = value; p.mappedDirty = true;
                caches[map.slot]->put(p.id, value, false); dirtyState = true;
            }
            for (int i = 0; i < effects.size(); ++i) if (!consumed[i]) effects[i]->midi(message);
            if ((message.status & 0xf0) >= 0xb0) dirtyState = true;
        }
        // Absolute controllers can send many positions before the next block.
        // Deliver the final position once per parameter without adding a block
        // of latency or filling an AU's automation queue with obsolete values.
        for (size_t i = 0; i < routing.count; ++i) {
            auto& map = routing.mappings[i]; auto& p = *caches[map.slot]->parameters[map.parameter];
            if (p.mappedDirty) { p.mappedDirty = false; effects[map.slot]->scheduleParameter(p.id, p.mappedValue); }
        }
    }
    void parameters(int slot) {
        if (slot < 0) return;
        NSMutableArray* values = [NSMutableArray array]; auto cache = caches[slot];
        for (NSUInteger i = 0; i < cache->parameters.size(); ++i) {
            NSMutableDictionary* p = [cache->metadata[i] mutableCopy]; p[@"value"] = @(cache->parameters[i]->value.load()); [values addObject:p];
        }
        emit(@{@"event": @"parameters", @"slotID": slots[slot][@"id"], @"parameters": values, @"acceptsMIDI": @(effects[slot]->acceptsMIDI())});
    }
    void command(NSDictionary* command) {
        NSString* name = command[@"command"]; int slot = slotIndex(command[@"slotID"]);
        if ([name isEqual:@"parameters"]) { inspectorOpen = slot >= 0; inspected = slot; parameters(slot); publishSources(); }
        if ([name isEqual:@"endParameters"]) { inspectorOpen = false; inspected = watching = -1; learnSlot = -1; }
        if ([name isEqual:@"setParameter"] && slot >= 0) {
            uint64_t id = [command[@"parameterID"] unsignedLongLongValue]; double value = [command[@"value"] doubleValue];
            int index = caches[slot]->index(id); if (index >= 0 && std::isfinite(value)) {
                auto& p = *caches[slot]->parameters[index]; value = std::clamp(value, p.minimum, p.maximum);
                effects[slot]->setParameter(id, value); caches[slot]->put(id, value, true); dirtyState = true;
            }
        }
        if ([name isEqual:@"learnMIDI"]) {
            learnSlot = -1;
            if (slot >= 0 && accepting.load()) { learnParameter = caches[slot]->index([command[@"parameterID"] unsignedLongLongValue]); learnSlot = slot; }
        }
        if ([name isEqual:@"cancelMIDILearn"]) { learnSlot = -1; watching = -1; }
        if ([name isEqual:@"watchParameter"] && slot >= 0) { caches[slot]->touched = -1; watching = slot; }
        if ([name isEqual:@"midiPanic"]) { panic = true; discardInput = true; emit(@{@"event": @"midiPanic"}); }
#ifdef CAMITUNE_PLUGIN_TESTING
        if ([name isEqual:@"testMIDI"]) {
            for (NSDictionary* event in command[@"messages"]) receive({0, [event[@"source"] intValue],
                (uint8_t)[event[@"status"] intValue], (uint8_t)[event[@"data1"] intValue], (uint8_t)[event[@"data2"] intValue]});
            emit(@{@"event": @"testMIDI"});
        }
#endif
    }
    void idle() {
        if (hasPending) hasPending = !configurations.push(pending);
        if (dirtyState.exchange(false)) lastChange = CFAbsoluteTimeGetCurrent();
        if (inspected < 0 && watching < 0 && ![configuration[@"isEnabled"] boolValue]) return;
        Learned result{};
        while (learned.pop(result)) {
            auto cache = caches[result.slot]; NSString* sourceName = @"MIDI input";
            for (NSDictionary* source in midiSources()) if ([source[@"id"] intValue] == result.message.source) sourceName = source[@"name"];
            emit(@{@"event": @"midiLearned", @"slotID": slots[result.slot][@"id"],
                @"parameterID": @(cache->parameters[result.parameter]->id), @"parameterName": cache->metadata[result.parameter][@"name"],
                @"sourceID": @(result.message.source), @"sourceName": sourceName,
                @"input": (result.message.status & 0xf0) == 0x90 ? @"note" : @"controller", @"channel": @((result.message.status & 15)+1), @"controller": @(result.message.data1)});
        }
        if (watching >= 0) {
            int parameter = caches[watching]->touched.exchange(-1);
            if (parameter >= 0) { emit(@{@"event": @"parameterTouched", @"slotID": slots[watching][@"id"],
                @"parameterID": @(caches[watching]->parameters[parameter]->id)}); watching = -1; }
        }
        for (int slot = 0; slot < caches.size(); ++slot) {
            NSMutableArray* changed = slot == inspected ? [NSMutableArray array] : nil;
            for (auto& p : caches[slot]->parameters) if (p->changed.exchange(false) && slot == inspected)
                [changed addObject:@{@"id": @(p->id), @"value": @(p->value.load())}];
            effects[slot]->syncParameters();
            if (changed.count) emit(@{@"event": @"parameterValues", @"slotID": slots[slot][@"id"], @"values": changed});
        }
        if (overflow.exchange(false)) emit(@{@"event": @"midiWarning", @"message": @"MIDI input overflowed. Held notes were released."});
    }
};
MIDIHost::MIDIHost(std::vector<std::unique_ptr<Effect>>& effects, NSArray<NSDictionary*>* slots) : impl(std::make_unique<Impl>(effects, slots)) {}
MIDIHost::~MIDIHost() = default;
void MIDIHost::configure(NSDictionary* config) { impl->configure(config); }
void MIDIHost::command(NSDictionary* command) { impl->command(command); }
void MIDIHost::process() { impl->process(); }
void MIDIHost::idle() { impl->idle(); }
bool MIDIHost::needsIdle() { return impl->accepting.load() || impl->inspectorOpen.load(); }
double MIDIHost::parameterValue(size_t slot, uint64_t id, double fallback) {
    if (slot >= impl->caches.size()) return fallback;
    auto& cache = *impl->caches[slot]; int index = cache.index(id);
    return index < 0 ? fallback : cache.parameters[index]->value.load();
}
bool MIDIHost::takeStateChanges() {
    if (!impl->lastChange || CFAbsoluteTimeGetCurrent() - impl->lastChange < 0.4) return false;
    impl->lastChange = 0; return true;
}
}
