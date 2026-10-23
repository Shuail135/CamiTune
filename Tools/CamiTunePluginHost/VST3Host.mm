#import "PluginHost.h"
#include <atomic>
#include <array>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <stdexcept>

#define INIT_CLASS_IID
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivsthostapplication.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstmidicontrollers.h"
#include "pluginterfaces/vst/ivstpluginterfacesupport.h"
#include "pluginterfaces/vst/ivstunits.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace CamiTunePlugins {
static bool equalID(const TUID a, const FUID& b) { return FUnknownPrivate::iidEqual(a, b); }
static NSString* string16(const TChar* value) {
    size_t length = 0; while (length < 127 && value[length]) ++length;
    return [[NSString alloc] initWithCharacters:(const unichar*)value length:length] ?: @"";
}
template<size_t N> static NSString* boundedString(const char (&value)[N]) {
    return [[NSString alloc] initWithBytes:value length:strnlen(value, N) encoding:NSUTF8StringEncoding] ?: @"";
}
template<size_t N> static NSString* boundedString(const char16 (&value)[N]) {
    size_t length = 0; while (length < N && value[length]) ++length;
    return [[NSString alloc] initWithCharacters:(const unichar*)value length:length] ?: @"";
}
static void copyString(NSString* value, TChar* out, size_t size = 128) {
    memset(out, 0, size * sizeof(TChar));
    [value getCharacters:(unichar*)out range:NSMakeRange(0, std::min(size - 1, (size_t)value.length))];
}
template<class T> static T* query(FUnknown* object) {
    T* result = nullptr;
    if (object) object->queryInterface(T::iid, (void**)&result);
    return result;
}

class MemoryStream final : public IBStream {
    std::atomic<uint32> refs{1};
    int64 position = 0;
public:
    std::vector<uint8_t> bytes;
    explicit MemoryStream(NSData* data = nil) {
        if (data.length > maximumStateBytes) throw std::runtime_error("The plug-in preset is too large.");
        if (data.length) bytes.assign((const uint8_t*)data.bytes, (const uint8_t*)data.bytes + data.length);
    }
    tresult PLUGIN_API queryInterface(const TUID id, void** result) override {
        if (equalID(id, IBStream::iid) || equalID(id, FUnknown::iid)) { *result = this; addRef(); return kResultOk; }
        *result = nullptr; return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return ++refs; }
    uint32 PLUGIN_API release() override { auto n = --refs; if (!n) delete this; return n; }
    tresult PLUGIN_API read(void* buffer, int32 count, int32* readCount) override {
        if (readCount) *readCount = 0;
        if (!buffer || count < 0 || position < 0 || position > (int64)bytes.size()) return kInvalidArgument;
        auto n = std::min<int64>(count, bytes.size() - position);
        if (n) memcpy(buffer, bytes.data() + position, n);
        position += n; if (readCount) *readCount = (int32)n;
        return n == count ? kResultOk : kResultFalse;
    }
    tresult PLUGIN_API write(void* buffer, int32 count, int32* written) override {
        if (written) *written = 0;
        if (!buffer || count < 0 || position < 0 || position + count > maximumStateBytes) return kInvalidArgument;
        bytes.resize(std::max<size_t>(bytes.size(), position + count));
        if (count) memcpy(bytes.data() + position, buffer, count);
        position += count; if (written) *written = count; return kResultOk;
    }
    tresult PLUGIN_API seek(int64 offset, int32 mode, int64* result = nullptr) override {
        int64 next = offset + (mode == kIBSeekCur ? position : mode == kIBSeekEnd ? bytes.size() : 0);
        if (next < 0 || next > maximumStateBytes) return kInvalidArgument;
        position = next; if (result) *result = next; return kResultOk;
    }
    tresult PLUGIN_API tell(int64* result) override { if (!result) return kInvalidArgument; *result = position; return kResultOk; }
    NSData* data() const { return [NSData dataWithBytes:bytes.data() length:bytes.size()]; }
};

class Attributes final : public IAttributeList {
    std::atomic<uint32> refs{1};
    struct Value { int64 integer = 0; double number = 0; std::u16string string; std::vector<uint8_t> binary; };
    std::map<std::string, Value> values;
public:
    tresult PLUGIN_API queryInterface(const TUID id, void** result) override {
        if (equalID(id, IAttributeList::iid) || equalID(id, FUnknown::iid)) { *result = this; addRef(); return kResultOk; }
        *result = nullptr; return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return ++refs; }
    uint32 PLUGIN_API release() override { auto n = --refs; if (!n) delete this; return n; }
    tresult PLUGIN_API setInt(AttrID id, int64 v) override { values[id].integer = v; return kResultOk; }
    tresult PLUGIN_API getInt(AttrID id, int64& v) override { auto i = values.find(id); if (i == values.end()) return kResultFalse; v = i->second.integer; return kResultOk; }
    tresult PLUGIN_API setFloat(AttrID id, double v) override { values[id].number = v; return kResultOk; }
    tresult PLUGIN_API getFloat(AttrID id, double& v) override { auto i = values.find(id); if (i == values.end()) return kResultFalse; v = i->second.number; return kResultOk; }
    tresult PLUGIN_API setString(AttrID id, const TChar* v) override { values[id].string = v; return kResultOk; }
    tresult PLUGIN_API getString(AttrID id, TChar* v, uint32 size) override {
        auto i = values.find(id); if (i == values.end() || !v || size < sizeof(TChar)) return kResultFalse;
        size_t n = std::min<size_t>(i->second.string.size(), size / sizeof(TChar) - 1);
        memcpy(v, i->second.string.data(), n * sizeof(TChar)); v[n] = 0; return kResultOk;
    }
    tresult PLUGIN_API setBinary(AttrID id, const void* v, uint32 size) override {
        if (size > maximumStateBytes || (!v && size)) return kInvalidArgument;
        auto& target = values[id].binary; target.resize(size); if (size) memcpy(target.data(), v, size); return kResultOk;
    }
    tresult PLUGIN_API getBinary(AttrID id, const void*& v, uint32& size) override {
        auto i = values.find(id); if (i == values.end()) return kResultFalse;
        v = i->second.binary.data(); size = (uint32)i->second.binary.size(); return kResultOk;
    }
};
class Message final : public IMessage {
    std::atomic<uint32> refs{1}; std::string identifier; Attributes* attributes = new Attributes;
public:
    ~Message() { attributes->release(); }
    tresult PLUGIN_API queryInterface(const TUID id, void** result) override {
        if (equalID(id, IMessage::iid) || equalID(id, FUnknown::iid)) { *result = this; addRef(); return kResultOk; }
        *result = nullptr; return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return ++refs; }
    uint32 PLUGIN_API release() override { auto n = --refs; if (!n) delete this; return n; }
    FIDString PLUGIN_API getMessageID() override { return identifier.c_str(); }
    void PLUGIN_API setMessageID(FIDString id) override { identifier = id ? id : ""; }
    IAttributeList* PLUGIN_API getAttributes() override { return attributes; }
};

class ParameterQueue final : public IParamValueQueue {
public:
    ParamID id = 0; ParamValue value = 0; int32 offset = 0; bool present = false;
    tresult PLUGIN_API queryInterface(const TUID iid, void** object) override {
        if (equalID(iid, IParamValueQueue::iid) || equalID(iid, FUnknown::iid)) { *object = this; return kResultOk; }
        *object = nullptr; return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    ParamID PLUGIN_API getParameterId() override { return id; }
    int32 PLUGIN_API getPointCount() override { return present ? 1 : 0; }
    tresult PLUGIN_API getPoint(int32 index, int32& sample, ParamValue& v) override {
        if (index || !present) return kInvalidArgument; sample = offset; v = value; return kResultOk;
    }
    tresult PLUGIN_API addPoint(int32 sample, ParamValue v, int32& index) override {
        offset = sample; value = v; present = true; index = 0; return kResultOk;
    }
};
class ParameterChanges final : public IParameterChanges {
public:
    static constexpr int capacity = 4096;
    std::array<ParameterQueue, capacity> queues;
    int32 count = 0;
    tresult PLUGIN_API queryInterface(const TUID iid, void** object) override {
        if (equalID(iid, IParameterChanges::iid) || equalID(iid, FUnknown::iid)) { *object = this; return kResultOk; }
        *object = nullptr; return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    int32 PLUGIN_API getParameterCount() override { return count; }
    IParamValueQueue* PLUGIN_API getParameterData(int32 index) override { return index >= 0 && index < count ? &queues[index] : nullptr; }
    IParamValueQueue* PLUGIN_API addParameterData(const ParamID& id, int32& index) override {
        for (int i = 0; i < count; ++i) if (queues[i].id == id) { index = i; return &queues[i]; }
        if (count == capacity) return nullptr;
        index = count++; queues[index].id = id; queues[index].present = false; return &queues[index];
    }
};
class EmptyEvents final : public IEventList {
public:
    tresult PLUGIN_API queryInterface(const TUID id, void** result) override {
        if (equalID(id, IEventList::iid) || equalID(id, FUnknown::iid)) { *result = this; return kResultOk; }
        *result = nullptr; return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    int32 PLUGIN_API getEventCount() override { return 0; }
    tresult PLUGIN_API getEvent(int32, Event&) override { return kResultFalse; }
    tresult PLUGIN_API addEvent(Event&) override { return kResultOk; }
};
class MIDIEvents final : public IEventList {
public:
    std::array<Event, 2304> values{}; int count = 0;
    tresult PLUGIN_API queryInterface(const TUID id, void** result) override {
        if (equalID(id, IEventList::iid) || equalID(id, FUnknown::iid)) { *result = this; return kResultOk; }
        *result = nullptr; return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    int32 PLUGIN_API getEventCount() override { return count; }
    tresult PLUGIN_API getEvent(int32 i, Event& event) override { if (i < 0 || i >= count) return kInvalidArgument; event = values[i]; return kResultOk; }
    tresult PLUGIN_API addEvent(Event& event) override { if (count == values.size()) return kResultFalse; values[count++] = event; return kResultOk; }
};

// Factories can keep the host context across instances, including a rejected
// layout followed by linked copies. Its lifetime must not belong to one effect.
class FactoryHostContext final : public IHostApplication, public IPlugInterfaceSupport {
public:
    tresult PLUGIN_API queryInterface(const TUID id, void** result) override {
        *result = nullptr;
        if (equalID(id, IHostApplication::iid) || equalID(id, FUnknown::iid)) *result = static_cast<IHostApplication*>(this);
        else if (equalID(id, IPlugInterfaceSupport::iid)) *result = static_cast<IPlugInterfaceSupport*>(this);
        return *result ? kResultOk : kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    tresult PLUGIN_API getName(String128 name) override { copyString(@"CamiTune", name); return kResultOk; }
    tresult PLUGIN_API createInstance(TUID cid, TUID iid, void** object) override {
        *object = nullptr;
        if (equalID(cid, IMessage::iid) && equalID(iid, IMessage::iid)) *object = new Message;
        else if (equalID(cid, IAttributeList::iid) && equalID(iid, IAttributeList::iid)) *object = new Attributes;
        return *object ? kResultOk : kNoInterface;
    }
    tresult PLUGIN_API isPlugInterfaceSupported(const TUID id) override {
        return equalID(id, IComponent::iid) || equalID(id, IAudioProcessor::iid) || equalID(id, IEditController::iid)
            || equalID(id, IConnectionPoint::iid) || equalID(id, IMidiMapping::iid) ? kResultTrue : kResultFalse;
    }
};
static FactoryHostContext factoryHostContext;

struct LoadedModule {
    CFBundleRef bundle = nullptr; IPluginFactory* factory = nullptr; bool entered = false;
    explicit LoadedModule(NSString* path) {
        try {
        bundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)[NSURL fileURLWithPath:path]);
        if (!bundle || !CFBundleLoadExecutable(bundle)) throw std::runtime_error("This VST3 cannot load on this Mac. Install a version for your Mac's processor.");
        auto entry = (bool (*)(CFBundleRef))CFBundleGetFunctionPointerForName(bundle, CFSTR("bundleEntry"));
        if (entry && !entry(bundle)) throw std::runtime_error("The VST3 could not initialize its bundle.");
        entered = true;
        auto getFactory = (IPluginFactory* (*)())CFBundleGetFunctionPointerForName(bundle, CFSTR("GetPluginFactory"));
        factory = getFactory ? getFactory() : nullptr;
        if (!factory) throw std::runtime_error("The bundle does not contain a VST3 factory.");
        if (auto factory3 = query<IPluginFactory3>(factory)) {
            factory3->setHostContext(static_cast<IHostApplication*>(&factoryHostContext)); factory3->release();
        }
        } catch (...) { cleanup(); throw; }
    }
    ~LoadedModule() { cleanup(); }
    void cleanup() {
        if (auto factory3 = query<IPluginFactory3>(factory)) { factory3->setHostContext(nullptr); factory3->release(); }
        if (factory) factory->release();
        if (entered) { auto exit = (bool (*)())CFBundleGetFunctionPointerForName(bundle, CFSTR("bundleExit")); if (exit) exit(); }
        if (bundle) CFRelease(bundle);
    }
};

// A bundle has one entry/exit lifecycle, shared by every instance/class in the
// rack. A rejected layout or a retired copy must not tear down another copy's
// factory/global resources. Preparation and destruction run on the main thread.
struct Module {
    std::shared_ptr<LoadedModule> loaded;
    IPluginFactory* factory;
    explicit Module(NSString* path) {
        static std::map<std::string, std::weak_ptr<LoadedModule>> modules;
        std::string key = path.stringByStandardizingPath.UTF8String;
        loaded = modules[key].lock();
        if (!loaded) { loaded = std::make_shared<LoadedModule>(path); modules[key] = loaded; }
        factory = loaded->factory;
    }
};

NSArray<NSDictionary*>* scanVST3(NSString* path) {
    Module module(path); NSMutableArray* results = [NSMutableArray array];
    PFactoryInfo factoryInfo{}; module.factory->getFactoryInfo(&factoryInfo);
    auto factory2 = query<IPluginFactory2>(module.factory);
    auto factory3 = query<IPluginFactory3>(module.factory);
    for (int32 index = 0, count = std::min<int32>(module.factory->countClasses(), 1024); index < count; ++index) {
        PClassInfoW unicode{}; PClassInfo2 extended{}; PClassInfo basic{};
        TUID cid{}; NSString *name = nil, *vendor = nil, *category = nil, *subcategories = nil;
        if (factory3 && factory3->getClassInfoUnicode(index, &unicode) == kResultOk) {
            memcpy(cid, unicode.cid, sizeof(cid)); name = boundedString(unicode.name); vendor = boundedString(unicode.vendor);
            category = boundedString(unicode.category); subcategories = boundedString(unicode.subCategories);
        } else if (factory2 && factory2->getClassInfo2(index, &extended) == kResultOk) {
            memcpy(cid, extended.cid, sizeof(cid)); name = boundedString(extended.name); vendor = boundedString(extended.vendor);
            category = boundedString(extended.category); subcategories = boundedString(extended.subCategories);
        } else if (module.factory->getClassInfo(index, &basic) == kResultOk) {
            memcpy(cid, basic.cid, sizeof(cid)); name = boundedString(basic.name); category = boundedString(basic.category);
        }
        if (![category isEqual:@(kVstAudioEffectClass)] || !name.length) continue;
        char identifier[33]{}; FUID::fromTUID(cid).toString(identifier);
        vendor = [vendor stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!vendor.length) vendor = [boundedString(factoryInfo.vendor) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [results addObject:@{@"id": @(identifier), @"name": name, @"manufacturer": vendor.length ? vendor : @"Maker not identified",
            @"kind": ([subcategories containsString:@"Instrument"] || [subcategories containsString:@"Generator"]) ? @"instrument" : @"effect",
            @"format": @"VST3", @"location": path, @"componentType": @0, @"componentSubtype": @0, @"componentManufacturer": @0}];
    }
    if (factory3) factory3->release(); if (factory2) factory2->release(); return results;
}

class VSTEffect final : public Effect, public IHostApplication, public IComponentHandler, public IPlugFrame, public IPlugInterfaceSupport, public IUnitHandler, public IUnitHandler2 {
    Module module;
    IComponent* component = nullptr; IAudioProcessor* processor = nullptr; IEditController* controller = nullptr;
    IConnectionPoint* componentConnection = nullptr; IConnectionPoint* controllerConnection = nullptr;
    IPlugView* view = nullptr; NSView* editorContainer = nil;
    bool separateController = false, componentInitialized = false, controllerInitialized = false, active = false, processing = false; double rate; int64 sampleTime = 0;
    std::atomic<int32> restartFlags{0};
    ParameterObserver parameterObserver;
    SpeakerArrangement arrangement = 0;
    std::vector<uint32_t> busToHost;
    std::array<ParamID, ParameterChanges::capacity> parameterIDs{};
    std::array<std::atomic<double>, ParameterChanges::capacity> pending{}, returned{};
    std::array<std::atomic<bool>, ParameterChanges::capacity> dirty{}, outputDirty{};
    int parameterCount = 0;
    ParameterChanges inputChanges, outputChanges; EmptyEvents events;
    MIDIEvents midiEvents;
    std::array<std::array<ParamID, 130>, 16> midiAssignments{};
    // Parameter ID and step count travel together when the controller updates
    // channel/unit assignments. The audio worker never calls IUnitInfo.
    std::array<std::atomic<uint64_t>, 16> programAssignments{};
    std::atomic<bool> programsChanged{false};
    std::array<std::array<bool, 128>, 16> heldNotes{};
    bool hasMIDI = false;
    bool midiOverflow = false;
    std::vector<AudioBusBuffers> inputs, outputs;
    std::vector<std::vector<float>> extraBuffers;
    std::vector<std::vector<float*>> extraPointers;
    std::vector<std::vector<double>> doubleBuffers;
    std::vector<std::vector<double*>> doublePointers;
    std::array<float, maximumFrames> monoInput{}, monoOutput{};
    int32 sampleSize = kSample32;
    int mainInput = -1, mainOutput = -1;
    int sidechainInput = -1, requestedSidechain = -1;
    bool instrument = false, sidechainEnabled = false;
    float* const* sidechain = nullptr;
    NSMutableArray<NSDictionary*>* auxiliaryInputs = [NSMutableArray array];
    uint32_t latencyFrames = 0; double tail = 0; bool invalidIO = false;

    int parameterIndex(ParamID id) const { for (int i = 0; i < parameterCount; ++i) if (parameterIDs[i] == id) return i; return -1; }
    void refreshProgramAssignments() {
        auto units = query<IUnitInfo>(controller);
        std::vector<ParameterInfo> programs;
        if (controller) for (int i = 0; i < parameterCount; ++i) {
            ParameterInfo info{};
            if (controller->getParameterInfo(i, info) == kResultOk && (info.flags & ParameterInfo::kIsProgramChange)
                && !(info.flags & ParameterInfo::kIsReadOnly) && info.stepCount >= 0) programs.push_back(info);
        }
        for (int channel = 0; channel < 16; ++channel) {
            UnitID unit = kRootUnitId;
            if (units && units->getUnitByBus(kEvent, kInput, 0, channel, unit) != kResultOk) unit = kRootUnitId;
            const ParameterInfo* selected = nullptr;
            for (const auto& info : programs) if (units ? info.unitId == unit : programs.size() == 1) {
                if (selected) { selected = nullptr; break; } // Ambiguous lists must not select an arbitrary program.
                selected = &info;
            }
            programAssignments[channel].store(selected ? (uint64_t(uint32_t(selected->stepCount)) << 32) | selected->id : kNoParamId);
        }
        if (units) units->release();
    }
    void takeParameterChanges() {
        inputChanges.count = outputChanges.count = 0;
        for (int i = 0; i < parameterCount; ++i) if (dirty[i].exchange(false, std::memory_order_acquire)) {
            int32 index = 0, point = 0; auto q = inputChanges.addParameterData(parameterIDs[i], index);
            if (q) q->addPoint(0, pending[i].load(std::memory_order_relaxed), point);
        }
    }
    void publishParameterChanges() {
        for (int i = 0; i < outputChanges.count; ++i) {
            auto& queue = outputChanges.queues[i]; int index = parameterIndex(queue.id);
            if (index >= 0 && queue.present && std::isfinite(queue.value)) { returned[index].store(queue.value); outputDirty[index].store(true); }
        }
    }
    void chooseArrangement(NSArray<NSString*>* roles) {
        if (roles.count == 1) { arrangement = SpeakerArr::kMono; busToHost = {0}; return; }
        bool rear = [roles containsObject:@"leftRearSurround"] || [roles containsObject:@"rightRearSurround"];
        NSDictionary<NSString*, NSNumber*>* speakers = @{
            @"left": @(kSpeakerL), @"right": @(kSpeakerR), @"center": @(kSpeakerC), @"lowFrequencyEffects": @(kSpeakerLfe),
            @"leftSurround": @(rear ? kSpeakerSl : kSpeakerLs), @"rightSurround": @(rear ? kSpeakerSr : kSpeakerRs),
            @"leftRearSurround": @(kSpeakerLs), @"rightRearSurround": @(kSpeakerRs),
            @"topFrontLeft": @(kSpeakerTfl), @"topFrontRight": @(kSpeakerTfr),
            @"topMiddleLeft": @(kSpeakerTsl), @"topMiddleRight": @(kSpeakerTsr),
            @"topRearLeft": @(kSpeakerTrl), @"topRearRight": @(kSpeakerTrr), @"topCenter": @(kSpeakerTc),
            @"frontLeftCenter": @(kSpeakerLc), @"frontRightCenter": @(kSpeakerRc), @"wideLeft": @(kSpeakerLw), @"wideRight": @(kSpeakerRw)};
        std::vector<std::pair<Speaker, uint32_t>> ordered;
        for (NSUInteger c = 0; c < roles.count; ++c) {
            Speaker speaker = [speakers[roles[c]] unsignedLongLongValue];
            if (!speaker || (arrangement & speaker)) throw UnsupportedLayout("VST3 needs named, unique speakers for a native bus.");
            arrangement |= speaker; ordered.emplace_back(speaker, (uint32_t)c);
        }
        std::sort(ordered.begin(), ordered.end());
        for (auto item : ordered) busToHost.push_back(item.second);
    }
    void setupBusses() {
        int inputCount = component->getBusCount(kAudio, kInput), outputCount = component->getBusCount(kAudio, kOutput);
        if (inputCount < 0 || outputCount < 1 || inputCount > 64 || outputCount > 64) throw std::runtime_error("This plug-in does not provide audio output.");
        if (inputCount == 0) instrument = true;
        std::vector<SpeakerArrangement> in(inputCount, SpeakerArr::kEmpty), out(outputCount, SpeakerArr::kEmpty);
        for (int dir = 0; dir < 2; ++dir) {
            int count = dir == 0 ? inputCount : outputCount;
            for (int i = 0; i < count; ++i) {
                BusInfo info{};
                BusDirection direction = dir == 0 ? kInput : kOutput;
                if (component->getBusInfo(kAudio, direction, i, info) != kResultOk
                    || processor->getBusArrangement(direction, i, (dir == 0 ? in : out)[i]) != kResultOk)
                    throw std::runtime_error("The VST3 did not describe its audio buses.");
                int& main = dir == 0 ? mainInput : mainOutput;
                if (info.busType == kMain && main < 0 && !(info.flags & BusInfo::kIsControlVoltage)) main = i;
                if (dir == 0 && info.busType == kAux && !(info.flags & BusInfo::kIsControlVoltage)) {
                    [auxiliaryInputs addObject:@{@"index": @(i), @"name": string16(info.name), @"channels": @(info.channelCount)}];
                    if (sidechainEnabled && (requestedSidechain == i || (requestedSidechain < 0 && sidechainInput < 0))) sidechainInput = i;
                }
            }
        }
        if ((!instrument && mainInput < 0) || mainOutput < 0) throw std::runtime_error("This plug-in has no usable main audio bus.");
        if (sidechainEnabled && sidechainInput < 0) throw std::runtime_error("This plug-in does not have the selected sidechain input. Choose another bus or turn Sidechain off.");
        // Bus activation and speaker layout are separate. Keep each unconnected
        // bus's declared layout; requesting kEmpty breaks fixed sidechain buses.
        auto negotiate = [&](SpeakerArrangement requestedIn, SpeakerArrangement requestedOut) {
            if (mainInput >= 0) in[mainInput] = requestedIn;
            out[mainOutput] = requestedOut;
            processor->setBusArrangements(in.data(), inputCount, out.data(), outputCount);
            SpeakerArrangement actualIn{}, actualOut{};
            return (mainInput < 0 || (processor->getBusArrangement(kInput, mainInput, actualIn) == kResultOk && actualIn == requestedIn))
                && processor->getBusArrangement(kOutput, mainOutput, actualOut) == kResultOk && actualOut == requestedOut;
        };
        // A false result can mean an auxiliary bus was kept at its fixed
        // layout. The resulting main arrangements, not that boolean, govern
        // whether the rack can safely use the plug-in.
        if (!negotiate(arrangement, arrangement)
            && !(arrangement == SpeakerArr::kStereo && (negotiate(SpeakerArr::kMono, arrangement)
                || negotiate(arrangement, SpeakerArr::kMono))))
            throw UnsupportedLayout("This VST3 does not accept a supported audio-effect layout.");
        inputs.resize(inputCount); outputs.resize(outputCount);
        extraBuffers.resize(inputCount + outputCount); extraPointers.resize(inputCount + outputCount);
        doubleBuffers.resize(inputCount + outputCount); doublePointers.resize(inputCount + outputCount);
        int totalChannels = 0;
        for (int dir = 0; dir < 2; ++dir) {
            auto& buffers = dir == 0 ? inputs : outputs;
            for (size_t i = 0; i < buffers.size(); ++i) {
                BusInfo info{};
                if (component->getBusInfo(kAudio, dir == 0 ? kInput : kOutput, (int)i, info) != kResultOk
                    || info.channelCount < 0 || info.channelCount > 64 || (totalChannels += info.channelCount) > 512)
                    throw std::runtime_error("Unsupported VST3 channel layout.");
                bool main = (int)i == (dir == 0 ? mainInput : mainOutput);
                bool active = main || (dir == 0 && (int)i == sidechainInput);
                auto activated = component->activateBus(kAudio, dir == 0 ? kInput : kOutput, (int)i, active);
                if (active && activated != kResultOk) throw std::runtime_error("The VST3 could not activate its main audio bus.");
                SpeakerArrangement actual{};
                if (processor->getBusArrangement(dir == 0 ? kInput : kOutput, (int)i, actual) != kResultOk
                    || SpeakerArr::getChannelCount(actual) != info.channelCount)
                    throw UnsupportedLayout("The VST3 channel count does not match its speaker layout.");
                buffers[i].numChannels = info.channelCount;
                size_t at = dir == 0 ? i : inputCount + i;
                if (sampleSize == kSample64) {
                    doubleBuffers[at].resize(info.channelCount * maximumFrames, 0);
                    for (int c = 0; c < info.channelCount; ++c) doublePointers[at].push_back(doubleBuffers[at].data() + c * maximumFrames);
                    buffers[i].channelBuffers64 = doublePointers[at].data();
                } else if (!main) {
                    extraBuffers[at].resize(info.channelCount * maximumFrames, 0);
                    for (int c = 0; c < info.channelCount; ++c) extraPointers[at].push_back(extraBuffers[at].data() + c * maximumFrames);
                    buffers[i].channelBuffers32 = extraPointers[at].data();
                }
                buffers[i].silenceFlags = active ? 0 : ~uint64(0);
            }
            int count = component->getBusCount(kEvent, dir == 0 ? kInput : kOutput);
            for (int i = 0; i < count; ++i) component->activateBus(kEvent, dir == 0 ? kInput : kOutput, i, dir == 0 && i == 0);
            if (dir == 0) hasMIDI = count > 0;
        }
    }
public:
    VSTEffect(NSDictionary* slot, double sampleRate, NSArray<NSString*>* roles) : module(slot[@"plugin"][@"location"]), rate(sampleRate) {
        try {
        instrument = [slot[@"plugin"][@"kind"] isEqual:@"instrument"];
        sidechainEnabled = [slot[@"sidechain"] isKindOfClass:NSDictionary.class];
        requestedSidechain = [slot[@"sidechainBus"] isKindOfClass:NSNumber.class] ? [slot[@"sidechainBus"] intValue] : -1;
        FUID id; if (!id.fromString([slot[@"plugin"][@"id"] UTF8String])) throw std::runtime_error("Invalid VST3 identity.");
        if (module.factory->createInstance(id, IComponent::iid, (void**)&component) != kResultOk || !component) throw std::runtime_error("The VST3 effect could not be created.");
        if (component->initialize(static_cast<IHostApplication*>(this)) != kResultOk) throw std::runtime_error("The VST3 effect could not initialize.");
        componentInitialized = true;
        component->setIoMode(kSimple);
        processor = query<IAudioProcessor>(component);
        if (!processor) throw std::runtime_error("This VST3 does not provide an audio processor.");
        controller = query<IEditController>(component);
        if (!controller) {
            TUID cid{};
            if (component->getControllerClassId(cid) == kResultOk && module.factory->createInstance(cid, IEditController::iid, (void**)&controller) == kResultOk && controller) {
                separateController = true;
                if (controller->initialize(static_cast<IHostApplication*>(this)) != kResultOk) throw std::runtime_error("The VST3 editor could not initialize.");
                separateController = true; controllerInitialized = true;
            }
        }
        if (controller) {
            controller->setComponentHandler(this);
            componentConnection = query<IConnectionPoint>(component); controllerConnection = query<IConnectionPoint>(controller);
            if (componentConnection && controllerConnection && separateController) {
                componentConnection->connect(controllerConnection); controllerConnection->connect(componentConnection);
            }
        }
        NSData* encoded = [[NSData alloc] initWithBase64EncodedString:slot[@"state"] ?: @"" options:0];
        if (encoded.length) {
            NSDictionary* saved = [NSPropertyListSerialization propertyListWithData:encoded options:NSPropertyListImmutable format:nil error:nil];
            if (![saved isKindOfClass:NSDictionary.class] || ![saved[@"component"] isKindOfClass:NSData.class]) throw std::runtime_error("The VST3 preset could not be read.");
            MemoryStream* stream = new MemoryStream(saved[@"component"]);
            auto restored = component->setState(stream); stream->seek(0, IBStream::kIBSeekSet);
            if (controller) controller->setComponentState(stream); stream->release();
            if (restored != kResultOk) throw std::runtime_error("The VST3 rejected its saved preset.");
            if (controller && [saved[@"controller"] isKindOfClass:NSData.class]) { auto s = new MemoryStream(saved[@"controller"]); controller->setState(s); s->release(); }
        } else if (controller) {
            auto stream = new MemoryStream; component->getState(stream); stream->seek(0, IBStream::kIBSeekSet); controller->setComponentState(stream); stream->release();
        }
        if (controller) {
            parameterCount = std::min<int>(ParameterChanges::capacity, std::max(0, controller->getParameterCount()));
            for (int i = 0; i < parameterCount; ++i) { ParameterInfo info{}; controller->getParameterInfo(i, info); parameterIDs[i] = info.id; dirty[i] = false; outputDirty[i] = false; }
        }
        instrument = instrument || component->getBusCount(kAudio, kInput) == 0;
        chooseArrangement(roles);
        if (processor->canProcessSampleSize(kSample32) == kResultOk) sampleSize = kSample32;
        else if (processor->canProcessSampleSize(kSample64) == kResultOk) sampleSize = kSample64;
        else throw std::runtime_error("This VST3 does not support floating-point audio processing.");
        setupBusses(); ProcessSetup setup{kRealtime, sampleSize, (int32)maximumFrames, rate};
        for (auto& channel : midiAssignments) channel.fill(kNoParamId);
        if (auto mapping = query<IMidiMapping>(controller)) {
            for (int channel = 0; channel < 16; ++channel) for (int control = 0; control < 130; ++control) {
                ParamID id = kNoParamId;
                if (mapping->getMidiControllerAssignment(0, channel, control, id) == kResultOk) midiAssignments[channel][control] = id;
            }
            mapping->release();
        }
        refreshProgramAssignments();
        if (processor->setupProcessing(setup) != kResultOk) throw std::runtime_error("The VST3 could not prepare audio processing.");
        if (component->setActive(true) != kResultOk) throw std::runtime_error("The VST3 could not activate audio processing.");
        active = true;
        if (processor->setProcessing(true) != kResultOk) throw std::runtime_error("The VST3 could not start audio processing.");
        processing = true;
        latencyFrames = processor->getLatencySamples(); uint32 samples = processor->getTailSamples();
        tail = samples == kInfiniteTail ? 10 : std::min(10.0, samples / rate);
        restartFlags = 0;
        } catch (const UnsupportedLayout& error) { cleanup(); throw UnsupportedLayout(error.what(), instrument); }
        catch (...) { cleanup(); throw; }
    }
    ~VSTEffect() override { cleanup(); }
    void cleanup() {
        closeEditor();
        if (processing) processor->setProcessing(false);
        if (active) component->setActive(false);
        if (componentConnection && controllerConnection && separateController) { componentConnection->disconnect(controllerConnection); controllerConnection->disconnect(componentConnection); }
        if (componentConnection) componentConnection->release(); if (controllerConnection) controllerConnection->release();
        if (controller) { controller->setComponentHandler(nullptr); if (controllerInitialized) controller->terminate(); controller->release(); }
        if (processor) processor->release(); if (component) { if (componentInitialized) component->terminate(); component->release(); }
    }
    tresult PLUGIN_API queryInterface(const TUID id, void** result) override {
        *result = nullptr;
        if (equalID(id, IHostApplication::iid) || equalID(id, FUnknown::iid)) *result = static_cast<IHostApplication*>(this);
        else if (equalID(id, IComponentHandler::iid)) *result = static_cast<IComponentHandler*>(this);
        else if (equalID(id, IPlugFrame::iid)) *result = static_cast<IPlugFrame*>(this);
        else if (equalID(id, IPlugInterfaceSupport::iid)) *result = static_cast<IPlugInterfaceSupport*>(this);
        else if (equalID(id, IUnitHandler::iid)) *result = static_cast<IUnitHandler*>(this);
        else if (equalID(id, IUnitHandler2::iid)) *result = static_cast<IUnitHandler2*>(this);
        return *result ? kResultOk : kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    tresult PLUGIN_API getName(String128 name) override { copyString(@"CamiTune", name); return kResultOk; }
    tresult PLUGIN_API createInstance(TUID cid, TUID iid, void** object) override {
        *object = nullptr;
        if (equalID(cid, IMessage::iid) && equalID(iid, IMessage::iid)) *object = new Message;
        else if (equalID(cid, IAttributeList::iid) && equalID(iid, IAttributeList::iid)) *object = new Attributes;
        return *object ? kResultOk : kNoInterface;
    }
    tresult PLUGIN_API isPlugInterfaceSupported(const TUID id) override {
        return equalID(id, IComponent::iid) || equalID(id, IAudioProcessor::iid) || equalID(id, IEditController::iid) || equalID(id, IConnectionPoint::iid) || equalID(id, IMidiMapping::iid) ? kResultTrue : kResultFalse;
    }
    tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API performEdit(ParamID id, ParamValue value) override {
        int index = parameterIndex(id); if (index < 0 || !std::isfinite(value)) return kInvalidArgument;
        scheduleParameter(id, value);
        if (parameterObserver) parameterObserver(id, value, true);
        return kResultOk;
    }
    tresult PLUGIN_API restartComponent(int32 flags) override { restartFlags.fetch_or(flags); return kResultOk; }
    tresult PLUGIN_API notifyUnitSelection(UnitID) override { return kResultOk; }
    tresult PLUGIN_API notifyProgramListChange(ProgramListID, int32) override { programsChanged = true; return kResultOk; }
    tresult PLUGIN_API notifyUnitByBusChange() override { programsChanged = true; return kResultOk; }
    tresult PLUGIN_API resizeView(IPlugView* candidate, ViewRect* rect) override {
        if (!rect || candidate != view || !editorContainer || rect->getWidth() < 1 || rect->getHeight() < 1 || rect->getWidth() > 4096 || rect->getHeight() > 4096) return kInvalidArgument;
        [editorContainer.window setContentSize:NSMakeSize(rect->getWidth(), rect->getHeight())];
        [editorContainer setFrameSize:NSMakeSize(rect->getWidth(), rect->getHeight())]; view->onSize(rect); return kResultOk;
    }
    bool render(float* const* input, float** output, uint32_t frames) override {
        takeParameterChanges();
        float* orderedInput[maximumChannels], *orderedOutput[maximumChannels];
        for (size_t c = 0; c < busToHost.size(); ++c) { orderedInput[c] = input[busToHost[c]]; orderedOutput[c] = output[busToHost[c]]; }
        const bool downmixInput = mainInput >= 0 && inputs[mainInput].numChannels == 1 && busToHost.size() == 2;
        const bool duplicateOutput = outputs[mainOutput].numChannels == 1 && busToHost.size() == 2;
        if (downmixInput) {
            for (uint32_t f = 0; f < frames; ++f) monoInput[f] = .5f * (orderedInput[0][f] + orderedInput[1][f]);
            orderedInput[0] = monoInput.data();
        }
        if (duplicateOutput) orderedOutput[0] = monoOutput.data();
        if (sampleSize == kSample64 && mainInput >= 0) {
            for (int c = 0; c < inputs[mainInput].numChannels; ++c)
                std::copy_n(orderedInput[c], frames, inputs[mainInput].channelBuffers64[c]);
        } else {
            if (sampleSize == kSample32) {
                if (mainInput >= 0) inputs[mainInput].channelBuffers32 = orderedInput;
                outputs[mainOutput].channelBuffers32 = orderedOutput;
            }
        }
        // Some processors touch unused buffers despite their inactive state.
        // Restore silent inputs and output flags without allocating on render.
        for (size_t i = 0; i < inputs.size(); ++i) {
            const bool external = (int)i == sidechainInput && sidechain;
            inputs[i].silenceFlags = (int)i == mainInput || external ? 0 : ~uint64(0);
            if ((int)i != mainInput) for (int c = 0; c < inputs[i].numChannels; ++c) {
                for (uint32_t f = 0; f < frames; ++f) {
                    float value = !external ? 0 : inputs[i].numChannels == 1 ? .5f * (sidechain[0][f] + sidechain[1][f]) : c < 2 ? sidechain[c][f] : 0;
                    if (sampleSize == kSample64) inputs[i].channelBuffers64[c][f] = value;
                    else inputs[i].channelBuffers32[c][f] = value;
                }
            }
        }
        for (auto& bus : outputs) bus.silenceFlags = 0;
        ProcessContext context{}; context.sampleRate = rate; context.projectTimeSamples = sampleTime; context.continousTimeSamples = sampleTime;
        context.state = ProcessContext::kPlaying | ProcessContext::kContTimeValid;
        ProcessData data; data.processMode = kRealtime; data.symbolicSampleSize = sampleSize; data.numSamples = frames;
        data.numInputs = (int32)inputs.size(); data.numOutputs = (int32)outputs.size(); data.inputs = inputs.data(); data.outputs = outputs.data();
        data.inputParameterChanges = &inputChanges; data.outputParameterChanges = &outputChanges;
        data.inputEvents = &midiEvents; data.outputEvents = &events; data.processContext = &context;
        bool ok = processor->process(data) == kResultOk; sampleTime += frames;
        // Track notes until their release has actually reached the processor.
        // Repeated panic/disconnect notifications before a render must not
        // erase the only queued note-off and leave a sounding voice behind.
        if (ok) for (int i = 0; i < midiEvents.count; ++i) {
            const auto& event = midiEvents.values[i];
            if (event.type == Event::kNoteOnEvent) heldNotes[event.noteOn.channel][event.noteOn.pitch] = true;
            if (event.type == Event::kNoteOffEvent) heldNotes[event.noteOff.channel][event.noteOff.pitch] = false;
        }
        midiEvents.count = 0;
        midiOverflow = false;
        publishParameterChanges();
        for (int c = 0; c < outputs[mainOutput].numChannels; ++c) {
            if (outputs[mainOutput].silenceFlags & (uint64(1) << c)) std::fill_n(orderedOutput[c], frames, 0.f);
            else if (sampleSize == kSample64) std::copy_n(outputs[mainOutput].channelBuffers64[c], frames, orderedOutput[c]);
        }
        if (duplicateOutput) for (size_t c = 0; c < busToHost.size(); ++c) std::copy_n(monoOutput.data(), frames, output[busToHost[c]]);
        return ok;
    }
    bool flushParameters() override {
        takeParameterChanges();
        if (!inputChanges.count) return true;
        // VST3 explicitly supports a parameter-only process call: no buses,
        // no samples, and no advancement of the audible sample clock.
        ProcessContext context{}; context.sampleRate = rate;
        context.projectTimeSamples = context.continousTimeSamples = sampleTime;
        context.state = ProcessContext::kContTimeValid;
        ProcessData data; data.processMode = kRealtime; data.symbolicSampleSize = sampleSize;
        data.inputParameterChanges = &inputChanges; data.outputParameterChanges = &outputChanges;
        data.processContext = &context;
        bool ok = processor->process(data) == kResultOk;
        publishParameterChanges();
        return ok;
    }
    void reset() override { processor->setProcessing(false); processor->setProcessing(true); sampleTime = 0; }
    void idle() override {
        int32 flags = restartFlags.exchange(0);
        if (programsChanged.exchange(false) || (flags & kParamTitlesChanged)) refreshProgramAssignments();
        if (flags & (kIoChanged | kReloadComponent)) invalidIO = true;
        if (flags & kLatencyChanged) latencyFrames = processor->getLatencySamples();
        uint32 samples = processor->getTailSamples();
        tail = samples == kInfiniteTail ? 10 : std::min(10.0, samples / rate);
        if (controller) for (int i = 0; i < parameterCount; ++i) {
            if (flags & kParamValuesChanged) performEdit(parameterIDs[i], controller->getParamNormalized(parameterIDs[i]));
        }
        syncParameters();
    }
    std::string failure() override { return invalidIO ? "The plug-in changed its audio layout. Bypass the rack, then enable it again to reload." : ""; }
    uint32_t latency() override { return latencyFrames; }
    bool isInstrument() override { return instrument; }
    NSArray<NSDictionary*>* sidechainBuses() override { return auxiliaryInputs; }
    void setSidechain(float* const* stereo) override { sidechain = stereo; }
    double tailSeconds() override { return tail; }
    NSData* saveState() override {
        auto componentState = new MemoryStream; auto result = component->getState(componentState);
        if (result != kResultOk) { componentState->release(); return nil; }
        NSMutableDictionary* saved = [NSMutableDictionary dictionaryWithObject:componentState->data() forKey:@"component"]; componentState->release();
        if (controller) { auto s = new MemoryStream; if (controller->getState(s) == kResultOk) saved[@"controller"] = s->data(); s->release(); }
        return [NSPropertyListSerialization dataWithPropertyList:saved format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    }
    NSArray<NSDictionary*>* parameters() override {
        NSMutableArray* result = [NSMutableArray array]; if (!controller) return result;
        for (int i = 0; i < parameterCount; ++i) {
            ParameterInfo info{}; if (controller->getParameterInfo(i, info) != kResultOk || (info.flags & ParameterInfo::kIsReadOnly)) continue;
            [result addObject:@{@"id": @(info.id), @"name": string16(info.title), @"value": @(controller->getParamNormalized(info.id)), @"min": @0, @"max": @1}];
        }
        return result;
    }
    void observeParameters(ParameterObserver observer) override { parameterObserver = std::move(observer); }
    void scheduleParameter(uint64_t id, double value) override {
        int index = parameterIndex((ParamID)id); if (index < 0 || !std::isfinite(value)) return;
        pending[index].store(std::clamp(value, 0.0, 1.0), std::memory_order_relaxed); dirty[index].store(true, std::memory_order_release);
        returned[index].store(std::clamp(value, 0.0, 1.0)); outputDirty[index].store(true);
    }
    void syncParameters() override {
        if (controller) for (int i = 0; i < parameterCount; ++i)
            if (outputDirty[i].exchange(false)) {
                double value = returned[i].load(); controller->setParamNormalized(parameterIDs[i], value);
                if (parameterObserver) parameterObserver(parameterIDs[i], value, false);
            }
    }
    bool acceptsMIDI() override { return hasMIDI; }
    void midi(const MIDIMessage& message) override {
        int channel = message.status & 15, kind = message.status & 0xf0;
        if (kind == 0xc0) {
            uint64_t assignment = programAssignments[channel].load();
            ParamID id = (ParamID)assignment; uint32_t steps = (uint32_t)(assignment >> 32);
            // Program indices are discrete, not CC values: normalize against
            // this list's length, and ignore indices beyond it instead of clamping.
            if (id != kNoParamId && message.data1 <= steps)
                scheduleParameter(id, steps ? double(message.data1) / steps : 0);
            return;
        }
        if (!hasMIDI || midiOverflow) return;
        int control = kind == 0xb0 ? message.data1 : kind == 0xd0 ? 128 : kind == 0xe0 ? 129 : -1;
        if (control >= 0) {
            ParamID id = midiAssignments[channel][control];
            if (id != kNoParamId) scheduleParameter(id, kind == 0xe0 ? (message.data1 + 128 * message.data2) / 16383.0
                : (kind == 0xd0 ? message.data1 : message.data2) / 127.0);
            if (kind == 0xb0 && (control == 120 || control == 123)) releaseNotes(channel);
            return;
        }
        if (kind != 0x80 && kind != 0x90 && kind != 0xa0) return;
        if (midiEvents.count >= 256) { clearMIDI(); midiOverflow = true; return; }
        Event event{}; event.flags = Event::kIsLive; event.sampleOffset = 0; event.busIndex = 0;
        if (kind == 0x90 && message.data2) {
            event.type = Event::kNoteOnEvent; event.noteOn = {(int16)channel, message.data1, 0, message.data2 / 127.f, 0, -1};
            heldNotes[channel][message.data1] = true;
        } else if (kind == 0xa0) {
            event.type = Event::kPolyPressureEvent; event.polyPressure = {(int16)channel, message.data1, message.data2 / 127.f, -1};
        } else {
            event.type = Event::kNoteOffEvent; event.noteOff = {(int16)channel, message.data1, message.data2 / 127.f, -1, 0};
        }
        midiEvents.addEvent(event);
    }
    void releaseNotes(int channel) {
        for (int note = 0; note < 128; ++note) if (heldNotes[channel][note]) {
            Event event{}; event.flags = Event::kIsLive; event.type = Event::kNoteOffEvent;
            event.noteOff = {(int16)channel, (int16)note, 0, -1, 0}; midiEvents.addEvent(event);
        }
    }
    void clearMIDI() override {
        midiEvents.count = 0;
        for (int channel = 0; channel < 16; ++channel) {
            releaseNotes(channel);
            for (int control : {64, 120, 123}) if (midiAssignments[channel][control] != kNoParamId)
                scheduleParameter(midiAssignments[channel][control], 0);
        }
    }
    void setParameter(uint64_t id, double value) override { if (controller) { controller->setParamNormalized((ParamID)id, value); performEdit((ParamID)id, value); } }
    void editor(void (^completion)(NSView*)) override {
        if (!controller) { completion(nil); return; }
        if (!view) view = controller->createView(ViewType::kEditor);
        if (!view || view->isPlatformTypeSupported(kPlatformTypeNSView) != kResultOk) { closeEditor(); completion(nil); return; }
        ViewRect rect{}; view->getSize(&rect);
        if (rect.getWidth() < 1 || rect.getHeight() < 1 || rect.getWidth() > 4096 || rect.getHeight() > 4096) { closeEditor(); completion(nil); return; }
        editorContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, rect.getWidth(), rect.getHeight())];
        view->setFrame(this);
        if (view->attached((__bridge void*)editorContainer, kPlatformTypeNSView) != kResultOk) { closeEditor(); completion(nil); return; }
        completion(editorContainer);
    }
    void closeEditor() override {
        if (view) { if (editorContainer) view->removed(); view->setFrame(nullptr); view->release(); view = nullptr; }
        editorContainer = nil;
    }
};
std::unique_ptr<Effect> makeVST3(NSDictionary* slot, double rate, NSArray<NSString*>* roles) { return std::make_unique<VSTEffect>(slot, rate, roles); }
}
