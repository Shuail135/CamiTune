// Deterministic gain/filter effect used only by host integration tests. Never bundled.
#define INIT_CLASS_IID
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivsthostapplication.h"
#include "pluginterfaces/vst/ivstunits.h"
#include <atomic>
#include <cstring>
#include <cmath>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
using namespace Steinberg;
using namespace Steinberg::Vst;
static const FUID classID(0x43616D69, 0x54756E65, 0x54657374, 0x45666678);
static bool factoryContextReady = false;
class TestEffect : public IComponent, public IAudioProcessor, public IEditController, public IMidiMapping, public IUnitInfo {
    std::atomic<uint32> refs{1}; std::atomic<float> gain{0.5f}; uint32 mode =
#ifdef CAMITUNE_INSTRUMENT
        20;
#else
        0;
#endif
    int blocks = 0;
    double controllerGain = .5; float history[32]{};
    SpeakerArrangement arrangement = SpeakerArr::kStereo;
    SpeakerArrangement inputArrangement = SpeakerArr::kStereo, outputArrangement = SpeakerArr::kStereo;
    std::atomic<uint64> audioFrames{0}, parameterFlushes{0};
    bool note = false;
    double programs[2]{.5, .5};
    uint32 lastProgramParameter = 0;
public:
    tresult PLUGIN_API queryInterface(const TUID id, void** object) override {
        *object = nullptr;
        if (FUnknownPrivate::iidEqual(id, IComponent::iid) || FUnknownPrivate::iidEqual(id, FUnknown::iid) || FUnknownPrivate::iidEqual(id, IPluginBase::iid)) *object = static_cast<IComponent*>(this);
        if (FUnknownPrivate::iidEqual(id, IAudioProcessor::iid)) *object = static_cast<IAudioProcessor*>(this);
        if (FUnknownPrivate::iidEqual(id, IEditController::iid)) *object = static_cast<IEditController*>(this);
        if (FUnknownPrivate::iidEqual(id, IMidiMapping::iid)) *object = static_cast<IMidiMapping*>(this);
        if (mode == 25 && FUnknownPrivate::iidEqual(id, IUnitInfo::iid)) *object = static_cast<IUnitInfo*>(this);
        if (*object) { addRef(); return kResultOk; } return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return ++refs; }
    uint32 PLUGIN_API release() override { auto n = --refs; if (!n) delete this; return n; }
    tresult PLUGIN_API initialize(FUnknown*) override {
#ifdef CAMITUNE_UNICODE_FACTORY
        if (!factoryContextReady) return kResultFalse;
#endif
        return kResultOk;
    }
    tresult PLUGIN_API terminate() override { return kResultOk; }
    tresult PLUGIN_API getControllerClassId(TUID) override { return kNoInterface; }
    tresult PLUGIN_API setIoMode(IoMode) override { return kResultOk; }
    int32 PLUGIN_API getBusCount(MediaType type, BusDirection direction) override { return type == kAudio ? ((mode == 20 || mode == 21) && direction == kInput ? 0 : (mode == 13 || mode == 22 || mode == 23) ? 2 : 1) : mode >= 10 && mode != 24 && direction == kInput ? 1 : 0; }
    tresult PLUGIN_API getBusInfo(MediaType type, BusDirection direction, int32 index, BusInfo& bus) override {
        if (index < 0 || index >= getBusCount(type, direction)) return kInvalidArgument;
        bool main = (mode != 13 && mode != 22 && mode != 23) || index == 1;
        bus = {}; bus.mediaType = type; bus.direction = direction;
        bus.channelCount = type == kAudio ? (main ? SpeakerArr::getChannelCount(direction == kInput ? inputArrangement : outputArrangement) : 2) : 16;
        bus.busType = main ? kMain : kAux; bus.flags = main ? BusInfo::kDefaultActive : 0; return kResultOk;
    }
    tresult PLUGIN_API getRoutingInfo(RoutingInfo&, RoutingInfo&) override { return kNotImplemented; }
    tresult PLUGIN_API activateBus(MediaType type, BusDirection, int32 index, TBool active) override {
        if (mode == 13 && type == kAudio && active != (index == 1)) return kResultFalse;
        return kResultOk;
    }
    tresult PLUGIN_API setActive(TBool) override { return kResultOk; }
    tresult PLUGIN_API setState(IBStream* stream) override {
        float value; stream->read(&value, sizeof(value)); gain = value; controllerGain = value; stream->read(&mode, sizeof(mode));
        programs[0] = programs[1] = value;
        arrangement = mode == 6 ? SpeakerArr::kMono : SpeakerArr::kStereo;
        inputArrangement = mode == 16 ? SpeakerArr::kMono : arrangement;
        outputArrangement = mode == 17 ? SpeakerArr::kMono : arrangement;
        return kResultOk;
    }
    tresult PLUGIN_API getState(IBStream* stream) override {
        float value = gain.load(); stream->write(&value, sizeof(value)); stream->write(&mode, sizeof(mode));
        if (mode == 4) { uint64 frames = audioFrames.load(), flushes = parameterFlushes.load(); stream->write(&frames, sizeof(frames)); stream->write(&flushes, sizeof(flushes)); }
        if (mode == 25) stream->write(&lastProgramParameter, sizeof(lastProgramParameter));
        return kResultOk;
    }
    tresult PLUGIN_API setComponentState(IBStream* stream) override { float value; stream->read(&value, sizeof(value)); controllerGain = value; return kResultOk; }
    int32 PLUGIN_API getParameterCount() override { return mode == 25 ? 3 : mode == 24 || mode == 10 ? 2 : 1; }
    tresult PLUGIN_API getParameterInfo(int32 index, ParameterInfo& info) override {
        if (index < 0 || index >= getParameterCount()) return kInvalidArgument;
        info = {}; info.id = 0; info.defaultNormalizedValue = .5; info.flags = ParameterInfo::kCanAutomate;
        if (index) {
            info.id = index; info.defaultNormalizedValue = 0; info.flags = ParameterInfo::kIsProgramChange;
            info.stepCount = index == 1 ? 3 : 7; info.unitId = mode == 25 ? index : 0;
        }
        const char* name = "Gain"; for (int i = 0; name[i]; ++i) info.title[i] = name[i]; return kResultOk;
    }
    tresult PLUGIN_API getParamStringByValue(ParamID, ParamValue, String128) override { return kNotImplemented; }
    tresult PLUGIN_API getParamValueByString(ParamID, TChar*, ParamValue&) override { return kNotImplemented; }
    ParamValue PLUGIN_API normalizedParamToPlain(ParamID, ParamValue value) override { return value; }
    ParamValue PLUGIN_API plainParamToNormalized(ParamID, ParamValue value) override { return value; }
    ParamValue PLUGIN_API getParamNormalized(ParamID id) override { return id > 0 && id <= 2 ? programs[id - 1] : controllerGain; }
    tresult PLUGIN_API setParamNormalized(ParamID id, ParamValue value) override {
        if (id > 0 && id <= 2) programs[id - 1] = value; else controllerGain = value;
        return kResultOk;
    }
    tresult PLUGIN_API setComponentHandler(IComponentHandler*) override { return kResultOk; }
    tresult PLUGIN_API getMidiControllerAssignment(int32 bus, int16, CtrlNumber control, ParamID& id) override {
        if (mode < 10 || bus || (control != 7 && control != 129)) return kResultFalse;
        id = 0; return kResultOk;
    }
    IPlugView* PLUGIN_API createView(FIDString) override { return nullptr; }
    int32 PLUGIN_API getUnitCount() override { return 3; }
    tresult PLUGIN_API getUnitInfo(int32 index, UnitInfo& info) override {
        if (index < 0 || index > 2) return kInvalidArgument;
        info = {}; info.id = index; info.parentUnitId = index ? 0 : -1; info.programListId = index ? index : -1; return kResultOk;
    }
    int32 PLUGIN_API getProgramListCount() override { return 2; }
    tresult PLUGIN_API getProgramListInfo(int32 index, ProgramListInfo& info) override {
        if (index < 0 || index > 1) return kInvalidArgument;
        info = {}; info.id = index + 1; info.programCount = index == 0 ? 4 : 8; return kResultOk;
    }
    tresult PLUGIN_API getProgramName(ProgramListID, int32, String128) override { return kNotImplemented; }
    tresult PLUGIN_API getProgramInfo(ProgramListID, int32, Vst::CString, String128) override { return kNotImplemented; }
    tresult PLUGIN_API hasProgramPitchNames(ProgramListID, int32) override { return kResultFalse; }
    tresult PLUGIN_API getProgramPitchName(ProgramListID, int32, int16, String128) override { return kNotImplemented; }
    UnitID PLUGIN_API getSelectedUnit() override { return 0; }
    tresult PLUGIN_API selectUnit(UnitID) override { return kResultOk; }
    tresult PLUGIN_API getUnitByBus(MediaType type, BusDirection direction, int32 bus, int32 channel, UnitID& unit) override {
        if (type != kEvent || direction != kInput || bus || channel > 1) return kResultFalse;
        unit = channel + 1; return kResultOk;
    }
    tresult PLUGIN_API setUnitProgramData(int32, int32, IBStream*) override { return kNotImplemented; }
    tresult PLUGIN_API setBusArrangements(SpeakerArrangement* in, int32 ni, SpeakerArrangement* out, int32 no) override {
        if (mode == 20 || mode == 21) {
            return ni == 0 && no == 1 && out[0] == SpeakerArr::kStereo ? kResultOk : kResultFalse;
        }
        if (mode == 13 || mode == 22 || mode == 23) {
            if (ni != 2 || no != 2 || in[0] != SpeakerArr::kStereo || out[0] != SpeakerArr::kStereo
                || in[1] != SpeakerArr::kStereo || out[1] != SpeakerArr::kStereo) return kResultFalse;
            return kResultOk;
        }
        if (ni != 1 || no != 1) return kResultFalse;
        if (mode == 16 || mode == 17) {
            if (in[0] != (mode == 16 ? SpeakerArr::kMono : SpeakerArr::kStereo)
                || out[0] != (mode == 17 ? SpeakerArr::kMono : SpeakerArr::kStereo)) return kResultFalse;
            inputArrangement = in[0]; outputArrangement = out[0]; return kResultOk;
        }
        if (in[0] != out[0]) return kResultFalse;
        int channels = SpeakerArr::getChannelCount(in[0]);
        bool accepted = (mode == 5 || mode == 8) ? channels >= 1 && channels <= 32
            : mode == 6 ? in[0] == SpeakerArr::kMono : in[0] == SpeakerArr::kStereo;
        if (!accepted) return kResultFalse;
        arrangement = inputArrangement = outputArrangement = in[0]; return mode == 14 ? kResultFalse : kResultOk;
    }
    tresult PLUGIN_API getBusArrangement(BusDirection direction, int32, SpeakerArrangement& result) override {
        result = direction == kInput ? inputArrangement : outputArrangement; return kResultOk;
    }
    tresult PLUGIN_API canProcessSampleSize(int32 size) override { return size == ((mode == 12 || mode == 21 || mode == 23) ? kSample64 : kSample32) ? kResultOk : kResultFalse; }
    uint32 PLUGIN_API getLatencySamples() override { return 0; }
    tresult PLUGIN_API setupProcessing(ProcessSetup& setup) override { return canProcessSampleSize(setup.symbolicSampleSize); }
    tresult PLUGIN_API setProcessing(TBool enabled) override { if (enabled) { memset(history, 0, sizeof(history)); audioFrames = 0; } return kResultOk; }
    tresult PLUGIN_API process(ProcessData& data) override {
        if (canProcessSampleSize(data.symbolicSampleSize) != kResultOk) return kResultFalse;
        if (data.inputParameterChanges) for (int i = 0; i < data.inputParameterChanges->getParameterCount(); ++i) {
            auto queue = data.inputParameterChanges->getParameterData(i); int32 offset; ParamValue value;
            if (queue->getParameterId() == 0 && queue->getPoint(queue->getPointCount()-1, offset, value) == kResultOk) gain = (float)value;
            if (queue->getParameterId() > 0 && queue->getPoint(queue->getPointCount()-1, offset, value) == kResultOk) {
                lastProgramParameter = queue->getParameterId(); gain = (float)value;
            }
        }
        if (mode == 4 && (!data.processContext || data.processContext->projectTimeSamples != (int64)audioFrames.load())) return kResultFalse;
        if (!data.numSamples) {
            if (data.numInputs || data.numOutputs || data.inputs || data.outputs) return kResultFalse;
            ++parameterFlushes; return kResultOk;
        }
        ++blocks;
        if ((mode == 10 || mode == 20 || mode == 21) && data.inputEvents) for (int i = 0; i < data.inputEvents->getEventCount(); ++i) {
            Event event{}; data.inputEvents->getEvent(i, event);
            if (event.type == Event::kNoteOnEvent) note = true;
            if (event.type == Event::kNoteOffEvent) note = false;
        }
        if (blocks > 3 && mode == 1) _exit(99);
        if (blocks > 3 && mode == 2) for (;;) pause();
        float currentGain = gain.load();
        if (mode == 20 || mode == 21) {
            if (data.numInputs != 0 || data.numOutputs != 1 || data.outputs[0].numChannels != 2) return kResultFalse;
            for (int c = 0; c < 2; ++c) for (int f = 0; f < data.numSamples; ++f) {
                float value = note ? currentGain * (c + 1) * .1f : 0;
                if (data.symbolicSampleSize == kSample64) data.outputs[0].channelBuffers64[c][f] = value;
                else data.outputs[0].channelBuffers32[c][f] = value;
            }
            return kResultOk;
        }
        int main = (mode == 13 || mode == 22 || mode == 23) ? 1 : 0;
        int channels = SpeakerArr::getChannelCount(outputArrangement), inputChannels = SpeakerArr::getChannelCount(inputArrangement);
        if (data.numInputs != ((mode == 13 || mode == 22 || mode == 23) ? 2 : 1) || data.numOutputs != ((mode == 13 || mode == 22 || mode == 23) ? 2 : 1)
            || data.inputs[main].numChannels != inputChannels || data.outputs[main].numChannels != channels) return kResultFalse;
        if (mode == 13) {
            if (data.inputs[0].numChannels != 2 || data.outputs[0].numChannels != 2 || data.inputs[0].silenceFlags != ~uint64(0)) return kResultFalse;
            for (int c = 0; c < 2; ++c) for (int f = 0; f < data.numSamples; ++f) {
                if (data.inputs[0].channelBuffers32[c][f] != 0) return kResultFalse;
                data.inputs[0].channelBuffers32[c][f] = .9f; // host must clear before next block
                data.outputs[0].channelBuffers32[c][f] = .8f; // must never leak into main output
            }
        }
        for (int c = 0; c < channels; ++c) for (int f = 0; f < data.numSamples; ++f) {
            int source = inputChannels == 1 ? 0 : c;
            float value = data.symbolicSampleSize == kSample64 ? data.inputs[main].channelBuffers64[source][f] : data.inputs[main].channelBuffers32[source][f];
            if (mode == 17) value = .5f * (data.inputs[main].channelBuffers32[0][f] + data.inputs[main].channelBuffers32[1][f]);
            if (mode == 22 || mode == 23) value *= data.symbolicSampleSize == kSample64
                ? data.inputs[0].channelBuffers64[c][f] : data.inputs[0].channelBuffers32[c][f];
            if (mode == 10 && !note) value = 0;
            if (mode == 9) value = .75f * value + .25f * data.inputs[0].channelBuffers32[1-c][f];
            if (mode == 4) { history[c] += .05f * (value - history[c]); value = history[c]; }
            // Mode 8 encodes the canonical VST3 bus index, making channel
            // ordering errors observable even if input/output reorder together.
            if (mode == 8) value *= (c + 1);
            float result = blocks > 3 && mode == 3 ? NAN : value * currentGain;
            if (data.symbolicSampleSize == kSample64) data.outputs[main].channelBuffers64[c][f] = result;
            else data.outputs[main].channelBuffers32[c][f] = result;
        }
        audioFrames += data.numSamples;
        return kResultOk;
    }
    uint32 PLUGIN_API getTailSamples() override { return 0; }
};
class Factory : public
#ifdef CAMITUNE_UNICODE_FACTORY
    IPluginFactory3
#else
    IPluginFactory
#endif
{
public:
    tresult PLUGIN_API queryInterface(const TUID id, void** object) override {
#ifdef CAMITUNE_UNICODE_FACTORY
        if (FUnknownPrivate::iidEqual(id, IPluginFactory2::iid) || FUnknownPrivate::iidEqual(id, IPluginFactory3::iid)) { *object = this; return kResultOk; }
#endif
        if (FUnknownPrivate::iidEqual(id, IPluginFactory::iid) || FUnknownPrivate::iidEqual(id, FUnknown::iid)) { *object = this; return kResultOk; }
        *object = nullptr; return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    tresult PLUGIN_API getFactoryInfo(PFactoryInfo* info) override { *info = {}; strcpy(info->vendor, "CamiTune Tests"); return kResultOk; }
    int32 PLUGIN_API countClasses() override { return 1; }
    tresult PLUGIN_API getClassInfo(int32 index, PClassInfo* info) override {
#ifdef CAMITUNE_UNICODE_FACTORY
        return kResultFalse; // Only the Unicode factory can describe this class.
#endif
        if (index != 0) return kInvalidArgument;
        *info = {}; classID.toTUID(info->cid); strcpy(info->name, "CamiTune Test Gain"); strcpy(info->category, kVstAudioEffectClass); info->cardinality = PClassInfo::kManyInstances; return kResultOk;
    }
#ifdef CAMITUNE_UNICODE_FACTORY
    tresult PLUGIN_API getClassInfo2(int32, PClassInfo2*) override { return kResultFalse; }
    tresult PLUGIN_API getClassInfoUnicode(int32 index, PClassInfoW* info) override {
        if (index || !factoryContextReady) return kResultFalse;
        *info = {}; classID.toTUID(info->cid); strcpy(info->category, kVstAudioEffectClass); strcpy(info->subCategories,
#ifdef CAMITUNE_INSTRUMENT
            "Instrument|Synth"
#else
            "Fx|Dynamics"
#endif
        );
        const char16* name = u"CamiTune Écho 音"; const char16* vendor = u"Créateur 音";
        for (int i = 0; name[i]; ++i) info->name[i] = name[i];
        for (int i = 0; vendor[i]; ++i) info->vendor[i] = vendor[i];
        return kResultOk;
    }
    tresult PLUGIN_API setHostContext(FUnknown* context) override {
        factoryContextReady = false;
        if (!context) return kResultOk;
        IHostApplication* host = nullptr;
        if (context->queryInterface(IHostApplication::iid, (void**)&host) != kResultOk || !host) return kResultFalse;
        String128 name{}; factoryContextReady = host->getName(name) == kResultOk && name[0] == u'C'; host->release(); return kResultOk;
    }
#endif
    tresult PLUGIN_API createInstance(FIDString cid, FIDString iid, void** object) override {
        if (!FUnknownPrivate::iidEqual(cid, classID)) return kInvalidArgument;
        auto instance = new TestEffect; auto result = instance->queryInterface(iid, object); instance->release(); return result;
    }
};
extern "C" __attribute__((visibility("default"))) IPluginFactory* GetPluginFactory() { static Factory factory; return &factory; }
static bool bundleEntered = false;
extern "C" __attribute__((visibility("default"))) bool bundleEntry(CFBundleRef) {
    if (bundleEntered) return false;
    bundleEntered = true; return true;
}
extern "C" __attribute__((visibility("default"))) bool bundleExit() { bundleEntered = false; return true; }
