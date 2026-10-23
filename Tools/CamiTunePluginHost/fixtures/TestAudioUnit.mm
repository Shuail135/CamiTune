#ifdef CAMITUNE_PLUGIN_TESTING
#import "TestAudioUnit.h"
#import <AudioToolbox/AUAudioUnitImplementation.h>
#import <AVFoundation/AVFoundation.h>
#include <atomic>

@interface CTCompatibilityBus : AUAudioUnitBus
@property UInt32 allowedChannels;
@property BOOL canonicalStereo;
@end
@implementation CTCompatibilityBus
- (BOOL)setFormat:(AVAudioFormat*)format error:(NSError**)error {
    if ((self.allowedChannels && format.channelCount != self.allowedChannels) || format.commonFormat != AVAudioPCMFormatFloat32 || format.interleaved
        || (self.canonicalStereo && format.channelLayout.layoutTag != kAudioChannelLayoutTag_Stereo)) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nil];
        return NO;
    }
    return [super setFormat:format error:error];
}
@end

@interface CTCompatibilityUnit : AUAudioUnit {
    AUAudioUnitBusArray* _inputs;
    AUAudioUnitBusArray* _outputs;
    UInt32 _variant;
    std::atomic<float> _programGain;
}
@end
@implementation CTCompatibilityUnit
- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)options error:(NSError**)error {
    if (!(self = [super initWithComponentDescription:d options:options error:error])) return nil;
    _variant = d.componentSubType;
    _programGain = .5f;
    UInt32 inputs = d.componentSubType == 1 ? 1 : 2, outputs = d.componentSubType == 2 ? 1 : 2;
    CTCompatibilityBus* in = [[CTCompatibilityBus alloc] initWithFormat:[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:inputs] error:error];
    CTCompatibilityBus* out = [[CTCompatibilityBus alloc] initWithFormat:[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:outputs] error:error];
    if (!in || !out) return nil;
    in.allowedChannels = inputs; out.allowedChannels = outputs;
    in.canonicalStereo = out.canonicalStereo = d.componentSubType == 3;
    CTCompatibilityBus* sidechain = [[CTCompatibilityBus alloc] initWithFormat:[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2] error:error];
    sidechain.allowedChannels = 2;
    _inputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput
        busses:d.componentSubType == 4 ? @[] : d.componentSubType == 5 ? @[in, sidechain] : @[in]];
    _outputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[out]];
    return self;
}
- (AUAudioUnitBusArray*)inputBusses { return _inputs; }
- (AUAudioUnitBusArray*)outputBusses { return _outputs; }
- (AUScheduleMIDIEventBlock)scheduleMIDIEventBlock {
    if (_variant != 6) return [super scheduleMIDIEventBlock];
    return ^(AUEventSampleTime time, uint8_t cable, NSInteger length, const uint8_t* bytes) {
        if (length > 0 && (bytes[0] & 0xf0) == 0xc0)
            self->_programGain = length == 2 && cable == 0 ? bytes[1] / 127.f : -1.f;
    };
}
- (AUInternalRenderBlock)internalRenderBlock {
    const UInt32 inputs = _inputs.count ? _inputs[0].format.channelCount : 0, outputs = _outputs[0].format.channelCount;
    const UInt32 variant = _variant;
    const bool sidechainEnabled = variant == 5 && _inputs[1].enabled;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags* flags, const AudioTimeStamp* stamp, AUAudioFrameCount frames,
                             NSInteger bus, AudioBufferList* output, const AURenderEvent* events, AURenderPullInputBlock pull) {
        if (!pull || bus || output->mNumberBuffers != outputs) return kAudioUnitErr_FormatNotSupported;
        if (variant == 4) {
            for (UInt32 c = 0; c < outputs; ++c) for (UInt32 f = 0; f < frames; ++f)
                ((float*)output->mBuffers[c].mData)[f] = .1f * (c + 1);
            return noErr;
        }
        struct { UInt32 count; AudioBuffer buffers[2]; } input{};
        input.count = inputs;
        for (UInt32 c = 0; c < inputs; ++c) input.buffers[c] = {1, (UInt32)(frames * sizeof(float)), nullptr};
        auto status = pull(flags, stamp, frames, 0, (AudioBufferList*)&input);
        if (status) return status;
        struct { UInt32 count; AudioBuffer buffers[2]; } detector{};
        if (sidechainEnabled) {
            detector.count = 2;
            for (UInt32 c = 0; c < 2; ++c) detector.buffers[c] = {1, (UInt32)(frames * sizeof(float)), nullptr};
            status = pull(flags, stamp, frames, 1, (AudioBufferList*)&detector);
            if (status) return status;
        }
        for (UInt32 c = 0; c < outputs; ++c) {
            float* target = (float*)output->mBuffers[c].mData;
            for (UInt32 f = 0; f < frames; ++f) {
                float value = ((float*)input.buffers[inputs == 1 ? 0 : c].mData)[f];
                if (inputs == 2 && outputs == 1) value = .5f * (value + ((float*)input.buffers[1].mData)[f]);
                target[f] = (variant == 6 ? self->_programGain.load() : .5f) * value * (variant == 5 ? (sidechainEnabled ? ((float*)detector.buffers[c].mData)[f] : 0) : 1);
            }
        }
        return noErr;
    };
}
@end
AUAudioUnit* makeCompatibilityTestAU(AudioComponentDescription d, NSError** error) {
    return [[CTCompatibilityUnit alloc] initWithComponentDescription:d options:0 error:error];
}
#endif
