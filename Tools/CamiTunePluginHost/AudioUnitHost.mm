#import "PluginHost.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <CoreAudioKit/CoreAudioKit.h>
#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <array>
#include <atomic>
#include <chrono>
#include <unordered_map>
#ifdef CAMITUNE_PLUGIN_TESTING
#import "TestAudioUnit.h"
#endif

namespace CamiTunePlugins {
NSArray<NSDictionary*>* scanAU() {
    NSMutableArray* results = [NSMutableArray array];
    for (OSType type : {kAudioUnitType_Effect, kAudioUnitType_MusicEffect, kAudioUnitType_MusicDevice, kAudioUnitType_Generator}) {
        AudioComponentDescription query{type, 0, 0, 0, 0};
        for (AVAudioUnitComponent* component in [[AVAudioUnitComponentManager sharedAudioUnitComponentManager] componentsMatchingDescription:query]) {
            auto d = component.audioComponentDescription;
            NSString* identifier = [NSString stringWithFormat:@"au:%08x:%08x:%08x", (unsigned)d.componentType, (unsigned)d.componentSubType, (unsigned)d.componentManufacturer];
            [results addObject:@{@"id": identifier, @"name": component.name ?: @"Audio Unit",
                @"manufacturer": component.manufacturerName ?: @"Unknown", @"format": @"AU", @"location": @"",
                @"kind": (type == kAudioUnitType_MusicDevice || type == kAudioUnitType_Generator) ? @"instrument" : @"effect",
                @"componentType": @(d.componentType), @"componentSubtype": @(d.componentSubType), @"componentManufacturer": @(d.componentManufacturer)}];
        }
    }
    return results;
}

static AVAudioChannelLayout* channelLayout(NSArray<NSString*>* roles) {
    if (roles.count == 1) return [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_Mono];
    static NSDictionary<NSString*, NSNumber*>* labels = @{
        @"left": @(kAudioChannelLabel_Left), @"right": @(kAudioChannelLabel_Right),
        @"center": @(kAudioChannelLabel_Center), @"lowFrequencyEffects": @(kAudioChannelLabel_LFEScreen),
        @"leftSurround": @(kAudioChannelLabel_LeftSurround), @"rightSurround": @(kAudioChannelLabel_RightSurround),
        @"leftRearSurround": @(kAudioChannelLabel_RearSurroundLeft), @"rightRearSurround": @(kAudioChannelLabel_RearSurroundRight),
        @"topFrontLeft": @(kAudioChannelLabel_LeftTopFront), @"topFrontRight": @(kAudioChannelLabel_RightTopFront),
        @"topMiddleLeft": @(kAudioChannelLabel_LeftTopMiddle), @"topMiddleRight": @(kAudioChannelLabel_RightTopMiddle),
        @"topRearLeft": @(kAudioChannelLabel_LeftTopRear), @"topRearRight": @(kAudioChannelLabel_RightTopRear),
        @"topCenter": @(kAudioChannelLabel_TopCenterSurround),
        @"frontLeftCenter": @(kAudioChannelLabel_LeftCenter), @"frontRightCenter": @(kAudioChannelLabel_RightCenter),
        @"wideLeft": @(kAudioChannelLabel_LeftWide), @"wideRight": @(kAudioChannelLabel_RightWide)};
    struct Layout { AudioChannelLayoutTag tag; AudioChannelBitmap bitmap; UInt32 count; AudioChannelDescription descriptions[maximumChannels]; } layout{};
    layout.tag = kAudioChannelLayoutTag_UseChannelDescriptions; layout.count = (UInt32)roles.count;
    for (NSUInteger c = 0; c < roles.count; ++c)
        layout.descriptions[c].mChannelLabel = labels[roles[c]] ? labels[roles[c]].unsignedIntValue : (kAudioChannelLabel_Discrete_0 + (UInt32)c);
    return [[AVAudioChannelLayout alloc] initWithLayout:(AudioChannelLayout*)&layout];
}

// AUv2 bridges can echo scheduled automation through their recording observer.
// Remember recent host writes so that these echoes do not become UI gestures or
// feed back into linked-channel automation. Storage is fixed before rendering.
struct AUScheduledParameter {
    std::array<std::atomic<uint64_t>, 32> writes{};
    std::atomic<uint32_t> cursor{0};
    std::atomic<AUValue> pending{0};
    std::atomic<bool> dirty{false}, renderDirty{false};
    static uint32_t milliseconds() {
        return (uint32_t)std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
    }
    static uint32_t bits(AUValue value) { uint32_t result; memcpy(&result, &value, sizeof(result)); return result; }
    void scheduled(AUValue value) {
        uint64_t entry = ((uint64_t)milliseconds() << 32) | bits(value);
        writes[cursor.fetch_add(1, std::memory_order_relaxed) % writes.size()].store(entry, std::memory_order_release);
    }
    bool echoes(AUValue value) {
        uint32_t now = milliseconds(), expected = bits(value);
        for (auto& write : writes) {
            uint64_t entry = write.load(std::memory_order_acquire);
            // Some AUv2 units notify more than once for the same scheduled
            // value. Keep the short-lived stamp for all of those callbacks.
            if (entry && (uint32_t)entry == expected && now - (uint32_t)(entry >> 32) < 1000) return true;
        }
        return false;
    }
};
using AUScheduledParameters = std::unordered_map<uint64_t, std::unique_ptr<AUScheduledParameter>>;

class AUEffect final : public Effect {
    AUAudioUnit* unit;
    AURenderBlock block;
    AUScheduleParameterBlock schedule;
    AUScheduleMIDIEventBlock scheduleMIDI;
    AUParameterTree* observedTree = nil;
    AUParameterObserverToken observerToken = nullptr;
    ParameterObserver parameterObserver;
    std::shared_ptr<AUScheduledParameters> scheduledParameters = std::make_shared<AUScheduledParameters>();
    std::atomic<bool> renderParametersPending{false};
    uint32_t channels, inputChannels = 0, outputChannels = 0;
    std::array<float, maximumFrames> monoInput{}, monoOutput{};
    std::array<std::array<float, maximumFrames>, maximumChannels> sidechainBuffers{};
    bool instrument = false;
    NSInteger mainInputBus = 0, sidechainInput = -1;
    uint32_t sidechainChannels = 0;
    float* const* sidechain = nullptr;
    NSMutableArray<NSDictionary*>* auxiliaryInputs = [NSMutableArray array];
    NSViewController* viewController = nil;
    uint64_t editorGeneration = 0;
    double rate, sampleTime = 0;
    struct BufferList { UInt32 count; AudioBuffer buffers[maximumChannels]; };
public:
    AUEffect(NSDictionary* slot, double sampleRate, NSArray<NSString*>* roles) : rate(sampleRate), channels((uint32_t)roles.count) {
        NSDictionary* descriptor = slot[@"plugin"];
        AudioComponentDescription d{[descriptor[@"componentType"] unsignedIntValue], [descriptor[@"componentSubtype"] unsignedIntValue], [descriptor[@"componentManufacturer"] unsignedIntValue], 0, 0};
        __block AUAudioUnit* loaded = nil; __block NSError* loadingError = nil; __block bool finished = false;
#ifdef CAMITUNE_PLUGIN_TESTING
        if (d.componentManufacturer == 0x43545473) { loaded = makeCompatibilityTestAU(d, &loadingError); finished = true; }
        else
#endif
        [AUAudioUnit instantiateWithComponentDescription:d options:kAudioComponentInstantiation_LoadOutOfProcess completionHandler:^(AUAudioUnit* value, NSError* error) {
            dispatch_async(dispatch_get_main_queue(), ^{ loaded = value; loadingError = error; finished = true; });
        }];
        NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:15];
        while (!finished && deadline.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        if (!loaded) throw std::runtime_error(loadingError ? loadingError.localizedDescription.UTF8String : "The Audio Unit took too long to load.");
        unit = loaded;
        NSError* error = nil;
        NSData* encoded = [[NSData alloc] initWithBase64EncodedString:slot[@"state"] ?: @"" options:0];
        if (encoded.length) {
            if (encoded.length > maximumStateBytes) throw std::runtime_error("The Audio Unit preset is too large.");
            id state = [NSPropertyListSerialization propertyListWithData:encoded options:NSPropertyListImmutable format:nil error:&error];
            if (![state isKindOfClass:NSDictionary.class]) throw std::runtime_error("The Audio Unit preset could not be read.");
            unit.fullState = state;
        }
        instrument = d.componentType == kAudioUnitType_MusicDevice || d.componentType == kAudioUnitType_Generator
            || [descriptor[@"kind"] isEqual:@"instrument"] || unit.inputBusses.count == 0;
        mainInputBus = instrument ? -1 : 0;
        if (unit.outputBusses.count < 1) throw std::runtime_error("This Audio Unit does not produce audio.");
        unit.outputBusses[0].enabled = YES;
        bool wantsSidechain = [slot[@"sidechain"] isKindOfClass:NSDictionary.class];
        NSInteger requested = [slot[@"sidechainBus"] isKindOfClass:NSNumber.class] ? [slot[@"sidechainBus"] integerValue] : -1;
        for (NSUInteger i = 0; i < unit.inputBusses.count; ++i) {
            unit.inputBusses[i].enabled = (NSInteger)i == mainInputBus;
            if ((NSInteger)i != mainInputBus) {
                [auxiliaryInputs addObject:@{@"index": @(i), @"name": unit.inputBusses[i].name ?: @"Sidechain", @"channels": @(unit.inputBusses[i].format.channelCount)}];
                if (wantsSidechain && (requested == (NSInteger)i || (requested < 0 && sidechainInput < 0))) sidechainInput = i;
            }
        }
        if (wantsSidechain && sidechainInput < 0) throw std::runtime_error("This Audio Unit does not have the selected sidechain input. Choose another bus or turn Sidechain off.");
        for (NSUInteger i = 1; i < unit.outputBusses.count; ++i) unit.outputBusses[i].enabled = NO;
        if (sidechainInput >= 0) {
            AUAudioUnitBus* bus = unit.inputBusses[sidechainInput];
            sidechainChannels = std::clamp<UInt32>(bus.format.channelCount, 1, maximumChannels);
            AVAudioFormat* sidechainFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:sidechainChannels];
            if (![bus setFormat:sidechainFormat error:&error]) throw std::runtime_error("The Audio Unit could not prepare its sidechain input at this sample rate.");
            bus.enabled = YES;
        }
        // Restore first: presets may contain a saved bus format. The prepared
        // profile, including its channel order, remains authoritative.
        unit.maximumFramesToRender = maximumFrames;
        auto prepare = [&](AVAudioChannelLayout* inputLayout, AVAudioChannelLayout* outputLayout) {
            AVAudioFormat* in = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:rate interleaved:NO channelLayout:inputLayout];
            AVAudioFormat* out = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:rate interleaved:NO channelLayout:outputLayout];
            if (!in || !out) return false;
            // Coupled AU buses may require one side to be set before the other.
            // Negotiate while stopped; never change a bus on the audio worker.
            bool configured = [unit.outputBusses[0] setFormat:out error:&error] && (mainInputBus < 0 || [unit.inputBusses[mainInputBus] setFormat:in error:&error]);
            if (!configured && mainInputBus >= 0) configured = [unit.inputBusses[mainInputBus] setFormat:in error:&error] && [unit.outputBusses[0] setFormat:out error:&error];
            if (!configured || (mainInputBus >= 0 && ![unit.inputBusses[mainInputBus].format isEqual:in]) || ![unit.outputBusses[0].format isEqual:out]) return false;
            if (![unit allocateRenderResourcesAndReturnError:&error]) {
                [unit deallocateRenderResources];
                if (error.code == kAudioUnitErr_FormatNotSupported) return false;
                throw std::runtime_error(error.localizedDescription.UTF8String ?: "The Audio Unit could not start processing.");
            }
            inputChannels = mainInputBus < 0 ? 0 : in.channelCount; outputChannels = out.channelCount;
            return true;
        };
        AVAudioChannelLayout* layout = channelLayout(roles);
        bool prepared = prepare(layout, layout);
        if (!prepared && channels == 2) {
            AVAudioChannelLayout* stereo = [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_Stereo];
            AVAudioChannelLayout* mono = [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_Mono];
            // Some units accept the canonical stereo tag but not equivalent
            // explicit labels. Mono/stereo variants are adapted automatically.
            prepared = prepare(stereo, stereo) || prepare(mono, stereo) || prepare(stereo, mono);
        }
        if (!prepared) throw UnsupportedLayout("This Audio Unit does not accept a supported audio layout.", instrument);
        block = unit.renderBlock; schedule = unit.scheduleParameterBlock; scheduleMIDI = unit.scheduleMIDIEventBlock;
        for (AUParameter* parameter in unit.parameterTree.allParameters)
            scheduledParameters->emplace(parameter.address, std::make_unique<AUScheduledParameter>());
    }
    ~AUEffect() override { observeParameters({}); [unit deallocateRenderResources]; }
    bool render(float* const* input, float** output, uint32_t frames) override {
        // Submit automation only immediately before a real render. Queuing it
        // while stopped would let an old MIDI value override a newer UI edit
        // when playback resumes.
        if (renderParametersPending.exchange(false, std::memory_order_acquire)) {
            for (auto& entry : *scheduledParameters) if (entry.second->renderDirty.exchange(false, std::memory_order_acquire)) {
                AUValue value = entry.second->pending.load(std::memory_order_relaxed);
                entry.second->scheduled(value);
                schedule(AUEventSampleTimeImmediate, 0, entry.first, value);
            }
        }
        const bool downmixInput = inputChannels == 1 && channels == 2, duplicateOutput = outputChannels == 1 && channels == 2;
        if (downmixInput) for (uint32_t f = 0; f < frames; ++f) monoInput[f] = .5f * (input[0][f] + input[1][f]);
        BufferList outputList{}; outputList.count = outputChannels;
        for (uint32_t c = 0; c < outputChannels; ++c)
            outputList.buffers[c] = {1, (UInt32)(frames * sizeof(float)), duplicateOutput ? monoOutput.data() : output[c]};
        const uint32_t countInputs = inputChannels;
        float* mono = monoInput.data();
        for (uint32_t c = 0; c < sidechainChannels; ++c) for (uint32_t f = 0; f < frames; ++f)
            sidechainBuffers[c][f] = !sidechain ? 0 : sidechainChannels == 1 ? .5f * (sidechain[0][f] + sidechain[1][f]) : c < 2 ? sidechain[c][f] : 0;
        AudioTimeStamp stamp{}; stamp.mFlags = kAudioTimeStampSampleTimeValid; stamp.mSampleTime = sampleTime;
        AudioUnitRenderActionFlags flags = 0;
        auto result = block(&flags, &stamp, frames, 0, (AudioBufferList*)&outputList,
            ^AUAudioUnitStatus(AudioUnitRenderActionFlags*, const AudioTimeStamp*, AUAudioFrameCount count, NSInteger bus, AudioBufferList* list) {
                uint32_t expected = bus == mainInputBus ? countInputs : bus == sidechainInput ? sidechainChannels : 0;
                if (!expected || count != frames || list->mNumberBuffers != expected) return kAudioUnitErr_FormatNotSupported;
                for (uint32_t c = 0; c < expected; ++c) {
                    float* source = bus == sidechainInput ? sidechainBuffers[c].data() : downmixInput ? mono : input[c];
                    if (list->mBuffers[c].mData) memcpy(list->mBuffers[c].mData, source, frames * sizeof(float));
                    else list->mBuffers[c].mData = source;
                    list->mBuffers[c].mDataByteSize = frames * sizeof(float); list->mBuffers[c].mNumberChannels = 1;
                }
                return noErr;
            });
        sampleTime += frames;
        if (result != noErr) return false;
        for (uint32_t c = 0; c < outputChannels; ++c) {
            if (!outputList.buffers[c].mData || outputList.buffers[c].mDataByteSize < frames * sizeof(float)) return false;
            float* target = duplicateOutput ? monoOutput.data() : output[c];
            if (flags & kAudioUnitRenderAction_OutputIsSilence) memset(target, 0, frames * sizeof(float));
            else if (outputList.buffers[c].mData != target) memcpy(target, outputList.buffers[c].mData, frames * sizeof(float));
        }
        if (duplicateOutput) for (uint32_t c = 0; c < channels; ++c) std::copy_n(monoOutput.data(), frames, output[c]);
        return true;
    }
    // Reset processing history without reusing a render timestamp. Some Audio
    // Units cache the last render even across reset and otherwise return an old
    // (or silent) block when the next request starts at sample zero again.
    void reset() override { [unit reset]; }
    bool isInstrument() override { return instrument; }
    NSArray<NSDictionary*>* sidechainBuses() override { return auxiliaryInputs; }
    void setSidechain(float* const* stereo) override { sidechain = stereo; }
    uint32_t latency() override { double seconds = unit.latency; return std::isfinite(seconds) ? (uint32_t)std::clamp(seconds * rate, 0.0, rate * 10) : 0; }
    double tailSeconds() override { double seconds = unit.tailTime; return std::isfinite(seconds) ? std::clamp(seconds, 0.0, 10.0) : 10; }
    NSData* saveState() override {
        NSDictionary* state = unit.fullState;
        return state ? [NSPropertyListSerialization dataWithPropertyList:state format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil] : nil;
    }
    NSArray<NSDictionary*>* parameters() override {
        NSMutableArray* result = [NSMutableArray array];
        for (AUParameter* parameter in unit.parameterTree.allParameters) {
            if (!(parameter.flags & kAudioUnitParameterFlag_IsWritable) || !std::isfinite(parameter.minValue) || !std::isfinite(parameter.maxValue) || parameter.maxValue <= parameter.minValue) continue;
            [result addObject:@{@"id": @(parameter.address), @"name": parameter.displayName ?: parameter.identifier,
                @"value": @(parameter.value), @"min": @(parameter.minValue), @"max": @(parameter.maxValue)}];
        }
        return result;
    }
    void setParameter(uint64_t identifier, double value) override {
        AUParameter* parameter = [unit.parameterTree parameterWithAddress:identifier];
        if (parameter && std::isfinite(value)) {
            AUValue applied = (AUValue)std::clamp(value, (double)parameter.minValue, (double)parameter.maxValue);
            auto found = scheduledParameters->find(identifier);
            if (found != scheduledParameters->end()) { found->second->dirty = false; found->second->renderDirty = false; }
            [parameter setValue:applied originator:observerToken];
            if (parameterObserver) parameterObserver(identifier, applied, true);
        }
    }
    void scheduleParameter(uint64_t identifier, double value) override {
        if (std::isfinite(value)) {
            auto found = scheduledParameters->find(identifier);
            if (found != scheduledParameters->end()) {
                found->second->pending.store((AUValue)value, std::memory_order_relaxed);
                found->second->dirty.store(true, std::memory_order_release);
                found->second->renderDirty.store(true, std::memory_order_release);
                renderParametersPending.store(true, std::memory_order_release);
            }
        }
    }
    bool acceptsMIDI() override { return scheduleMIDI != nil; }
    void midi(const MIDIMessage& message) override {
        if (!scheduleMIDI) return;
        uint8_t bytes[3]{message.status, message.data1, message.data2};
        int kind = message.status & 0xf0;
        scheduleMIDI(AUEventSampleTimeImmediate, 0, kind == 0xc0 || kind == 0xd0 ? 2 : 3, bytes);
    }
    void clearMIDI() override {
        if (!scheduleMIDI) return;
        for (int channel = 0; channel < 16; ++channel) for (uint8_t control : {uint8_t(64), uint8_t(123), uint8_t(120)})
            midi({0, 0, (uint8_t)(0xb0 | channel), control, 0});
    }
    void syncParameters() override {
        // Scheduled events update DSP on the next render. At rest there is no
        // render, so also reflect the final value through the normal AU UI API
        // on the main thread. This updates its editor/preset without processing
        // silence or doing Objective-C parameter-tree work on the audio worker.
        for (auto& entry : *scheduledParameters) if (entry.second->dirty.exchange(false, std::memory_order_acquire)) {
            AUValue value = entry.second->pending.load(std::memory_order_relaxed);
            AUParameter* parameter = [unit.parameterTree parameterWithAddress:entry.first];
            if (parameter && parameter.value != value && entry.second->pending.load(std::memory_order_relaxed) == value) {
                entry.second->scheduled(value);
                [parameter setValue:value originator:observerToken];
            }
        }
    }
    void idle() override { syncParameters(); }
    void observeParameters(ParameterObserver observer) override {
        if (observerToken) { [observedTree removeParameterObserver:observerToken]; observerToken = nullptr; }
        parameterObserver = observer;
        observedTree = unit.parameterTree;
        auto scheduled = scheduledParameters;
        if (observer && observedTree) observerToken = [observedTree tokenByAddingParameterAutomationObserver:^(NSInteger count, const AUParameterAutomationEvent* events) {
            for (NSInteger i = 0; i < count; ++i) {
                auto found = scheduled->find(events[i].address);
                bool echo = events[i].eventType == AUParameterAutomationEventTypeValue
                    && found != scheduled->end() && found->second->echoes(events[i].value);
                if (!echo && found != scheduled->end()) { found->second->dirty = false; found->second->renderDirty = false; }
                observer(events[i].address, events[i].value, !echo);
            }
        }];
    }
    void editor(NSView* parent, EditorCompletion completion) override {
        const auto generation = ++editorGeneration;
        [unit requestViewControllerWithCompletionHandler:^(NSViewController* controller) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != editorGeneration) return;
                @try { try {
                viewController = controller;
                NSView* content = controller.view;
                if (content && (content.frame.size.width <= 0 || content.frame.size.height <= 0)) {
                    NSSize size = controller.preferredContentSize;
                    if (size.width <= 0 || size.height <= 0) size = parent.bounds.size;
                    [content setFrameSize:size];
                }
                completion(content, nil);
                } catch (const std::exception& error) {
                    viewController = nil; completion(nil, @(error.what()));
                } } @catch (NSException*) {
                    viewController = nil;
                    completion(nil, @"The plug-in could not load its native editor. Try opening it again.");
                }
            });
        }];
    }
    void closeEditor() override { ++editorGeneration; viewController = nil; }
};
std::unique_ptr<Effect> makeAU(NSDictionary* slot, double rate, NSArray<NSString*>* roles) { return std::make_unique<AUEffect>(slot, rate, roles); }
}
