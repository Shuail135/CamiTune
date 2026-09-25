#pragma once
#ifndef SABR_SYSTEM_AUDIO_BRIDGE_DRIVER_TRANSPORT_H
#define SABR_SYSTEM_AUDIO_BRIDGE_DRIVER_TRANSPORT_H

#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <sys/types.h>
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
OSStatus sabr_driver_transport_add_client(
    AudioObjectID deviceObjectID,
    uint32_t clientID,
    int32_t processID,
    CFStringRef bundleID
);
/* Idle registrations do not consume the bounded shared active-audio roster. */
OSStatus sabr_driver_transport_start_client(AudioObjectID deviceObjectID, uint32_t clientID);
void sabr_driver_transport_stop_client(AudioObjectID deviceObjectID, uint32_t clientID);
void sabr_driver_transport_remove_client(AudioObjectID deviceObjectID, uint32_t clientID, int32_t processID);
/* Retire active IO when an endpoint is unpublished; retain HAL registrations. */
void sabr_driver_transport_suspend_device_clients(AudioObjectID deviceObjectID);
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
void sabr_driver_transport_write_completed_source(
    const Float32* samples, uint32_t frames, uint32_t channels, uint32_t layout,
    double sampleRate, AudioObjectID device, uint32_t client, uint64_t cycle,
    double sampleTime, uint64_t epoch, uint64_t hostTime, uint32_t timestampFlags);
void sabr_driver_transport_write_completion(
    uint32_t kind, AudioObjectID device, uint64_t epoch, double sampleTime,
    uint32_t frames, double sampleRate, uint32_t channels, uint32_t layout,
    uint64_t hostTime, uint32_t timestampFlags);
void sabr_driver_transport_get_configuration(SABRTransportConfiguration* configuration);

#ifdef __cplusplus
}
#endif

#endif /* SABR_SYSTEM_AUDIO_BRIDGE_DRIVER_TRANSPORT_H */
