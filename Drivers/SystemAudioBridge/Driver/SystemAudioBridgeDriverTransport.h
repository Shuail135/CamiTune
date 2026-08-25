#ifndef SYSTEM_AUDIO_BRIDGE_DRIVER_TRANSPORT_H
#define SYSTEM_AUDIO_BRIDGE_DRIVER_TRANSPORT_H

#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include "../Shared/SystemAudioBridgeTransport.h"

#ifdef __cplusplus
extern "C" {
#endif

OSStatus sabr_driver_transport_connect(
    const SABRTransportConfiguration* configuration,
    pid_t clientProcessID
);
OSStatus sabr_driver_transport_authorize_property_list(
    CFPropertyListRef propertyList,
    pid_t clientProcessID
);
OSStatus sabr_driver_transport_connect_property_list(
    CFPropertyListRef propertyList,
    pid_t clientProcessID
);
void sabr_driver_transport_disconnect(void);
void sabr_driver_transport_add_client(
    AudioObjectID deviceObjectID,
    uint32_t clientID,
    int32_t processID,
    CFStringRef bundleID
);
void sabr_driver_transport_remove_client(AudioObjectID deviceObjectID, uint32_t clientID);
void sabr_driver_transport_publish_control(
    AudioObjectID deviceObjectID,
    Float32 linearGain,
    Boolean muted
);
void sabr_driver_transport_write(
    const Float32* interleavedSamples,
    uint32_t frameCount,
    uint32_t channelCount,
    uint32_t channelLayoutTag,
    double sampleRate,
    AudioObjectID deviceObjectID,
    uint32_t clientID,
    uint64_t cycleCounter,
    double sampleTime
);
void sabr_driver_transport_get_configuration(SABRTransportConfiguration* configuration);

#ifdef __cplusplus
}
#endif

#endif
