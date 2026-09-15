#ifndef SYSTEM_AUDIO_BRIDGE_PROFILE_FORMAT_H
#define SYSTEM_AUDIO_BRIDGE_PROFILE_FORMAT_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreAudio/CoreAudioTypes.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>

/* Versioned control-plane payload; independent of the shared-memory audio ABI.
 * v1 pins each endpoint to the prepared runtime's rate. Changing the format
 * requires removing the idle endpoint and publishing it again. */
#define SABR_PROFILE_FORMAT_VERSION 1
#define SABR_PROFILE_KEY_VERSION "profileFormatVersion"
#define SABR_PROFILE_KEY_CHANNEL_COUNT "channelCount"
#define SABR_PROFILE_KEY_LAYOUT_TAG "channelLayoutTag"
#define SABR_PROFILE_KEY_SAMPLE_RATES "supportedSampleRates"

typedef struct SABRProfileFormat {
    uint32_t version;
    uint32_t channelCount;
    uint32_t channelLayoutTag;
    double sampleRate;
} SABRProfileFormat;

static inline bool sabr_profile_uint32(CFDictionaryRef dictionary, CFStringRef key, uint32_t* result) {
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    double number = 0;
    if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID() ||
        !CFNumberGetValue(value, kCFNumberDoubleType, &number) ||
        !isfinite(number) || number < 0 || number > UINT32_MAX || floor(number) != number) { return false; }
    *result = (uint32_t)number;
    return true;
}

static inline bool sabr_profile_layout_is_valid(uint32_t count, uint32_t tag) {
    if (count < 1 || count > 32 || (tag & 0xffff) != count) { return false; }
    if ((tag & 0xffff0000) == kAudioChannelLayoutTag_DiscreteInOrder) { return true; }
    switch (tag) {
        case kAudioChannelLayoutTag_Mono:
        case kAudioChannelLayoutTag_Stereo:
        case kAudioChannelLayoutTag_Quadraphonic:
        case kAudioChannelLayoutTag_MPEG_5_1_A:
        case kAudioChannelLayoutTag_MPEG_7_1_C:
        case kAudioChannelLayoutTag_Atmos_5_1_2:
        case kAudioChannelLayoutTag_Atmos_5_1_4:
        case kAudioChannelLayoutTag_Atmos_7_1_2:
        case kAudioChannelLayoutTag_Atmos_7_1_4:
        case kAudioChannelLayoutTag_Atmos_9_1_6: return true;
        default: return false;
    }
}

static inline bool sabr_profile_format_parse(CFDictionaryRef dictionary, SABRProfileFormat* format) {
    SABRProfileFormat parsed = {0};
    if (!sabr_profile_uint32(dictionary, CFSTR(SABR_PROFILE_KEY_VERSION), &parsed.version) ||
        parsed.version != SABR_PROFILE_FORMAT_VERSION ||
        !sabr_profile_uint32(dictionary, CFSTR(SABR_PROFILE_KEY_CHANNEL_COUNT), &parsed.channelCount) ||
        !sabr_profile_uint32(dictionary, CFSTR(SABR_PROFILE_KEY_LAYOUT_TAG), &parsed.channelLayoutTag) ||
        !sabr_profile_layout_is_valid(parsed.channelCount, parsed.channelLayoutTag)) { return false; }
    CFTypeRef rates = CFDictionaryGetValue(dictionary, CFSTR(SABR_PROFILE_KEY_SAMPLE_RATES));
    if (rates == NULL || CFGetTypeID(rates) != CFArrayGetTypeID() || CFArrayGetCount(rates) != 1) { return false; }
    CFTypeRef rate = CFArrayGetValueAtIndex(rates, 0);
    if (rate == NULL || CFGetTypeID(rate) != CFNumberGetTypeID() ||
        !CFNumberGetValue(rate, kCFNumberDoubleType, &parsed.sampleRate) || !isfinite(parsed.sampleRate)) { return false; }
    const double supported[] = {8000, 16000, 24000, 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000};
    bool validRate = false;
    for (unsigned i = 0; i < sizeof(supported) / sizeof(supported[0]); ++i) {
        if (parsed.sampleRate == supported[i]) { validRate = true; break; }
    }
    if (!validRate) { return false; }
    *format = parsed;
    return true;
}

static inline bool sabr_profile_format_equal(SABRProfileFormat a, SABRProfileFormat b) {
    return a.version == b.version && a.channelCount == b.channelCount &&
        a.channelLayoutTag == b.channelLayoutTag && a.sampleRate == b.sampleRate;
}

#endif
