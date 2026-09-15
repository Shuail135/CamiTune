#ifndef SYSTEM_AUDIO_BRIDGE_CLIENT_H
#define SYSTEM_AUDIO_BRIDGE_CLIENT_H

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include "SystemAudioBridgeTransport.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SABRClientTransport* SABRClientTransportRef;

#define SABR_CLIENT_BUNDLE_ID_CAPACITY SABR_TRANSPORT_BUNDLE_ID_CAPACITY

typedef struct SABRClientAudioPacketInfo {
    uint32_t clientID;
    int32_t processID;
    uint32_t deviceObjectID;
    uint64_t cycleCounter;
    double sampleTime;
    uint32_t frameCount;
    uint32_t channelCount;
    uint32_t channelLayoutTag;
    double sampleRate;
} SABRClientAudioPacketInfo;

typedef struct SABRClientIdentity {
    uint32_t clientID;
    int32_t processID;
    uint32_t deviceObjectID;
    uint32_t identityFlags;
    Boolean isActive;
    uint64_t generation;
    char bundleID[SABR_CLIENT_BUNDLE_ID_CAPACITY];
} SABRClientIdentity;

typedef SABRTransportStatistics SABRClientTransportStatistics;

typedef struct SABRClientControlState {
    uint64_t generation;
    uint32_t deviceObjectID;
    float linearGain;
    Boolean muted;
} SABRClientControlState;

_Static_assert(
    sizeof(((SABRClientIdentity*)0)->bundleID) == SABR_TRANSPORT_BUNDLE_ID_CAPACITY,
    "Client bundle identifier capacity must match the transport ABI"
);

SABRClientTransportRef sabr_client_transport_create(
    uint32_t channelCapacity,
    uint32_t frameCapacity
);

OSStatus sabr_client_transport_connect(
    SABRClientTransportRef transport,
    AudioObjectID deviceObjectID
);

OSStatus sabr_client_set_presentation(
    AudioObjectID deviceObjectID,
    const char* displayName,
    Boolean visible
);

OSStatus sabr_client_set_profile_devices(
    AudioObjectID deviceObjectID,
    CFArrayRef profiles
);

/* Version 1 requires complete format dictionaries. Older drivers are rejected
 * before publication rather than silently advertising their compiled width. */
uint32_t sabr_client_profile_format_version(AudioObjectID deviceObjectID);
CFArrayRef sabr_client_copy_profile_devices(AudioObjectID deviceObjectID) CF_RETURNS_RETAINED;
OSStatus sabr_client_set_profile_devices_with_formats(AudioObjectID deviceObjectID, CFArrayRef profiles);

OSStatus sabr_client_transport_disconnect(
    SABRClientTransportRef transport,
    AudioObjectID deviceObjectID
);

uint32_t sabr_client_transport_read(
    SABRClientTransportRef transport,
    Float32* interleavedDestination,
    uint32_t destinationChannelCapacity,
    uint32_t maximumFrames,
    uint32_t* activeChannels,
    double* sampleRate
);

uint32_t sabr_client_transport_read_packet(
    SABRClientTransportRef transport,
    Float32* interleavedDestination,
    uint32_t destinationChannelCapacity,
    uint32_t maximumFrames,
    SABRClientAudioPacketInfo* packetInfo
);

uint32_t sabr_client_transport_copy_clients(
    SABRClientTransportRef transport,
    SABRClientIdentity* destination,
    uint32_t destinationCapacity
);

Boolean sabr_client_transport_copy_control_state(
    SABRClientTransportRef transport,
    SABRClientControlState* controlState
);

uint64_t sabr_client_transport_client_generation(SABRClientTransportRef transport);

void sabr_client_transport_get_statistics(
    SABRClientTransportRef transport,
    SABRClientTransportStatistics* statistics
);

void sabr_client_transport_destroy(SABRClientTransportRef transport);

uint32_t sabr_client_transport_max_channels(void);
uint32_t sabr_client_transport_channel_count(AudioObjectID deviceObjectID);
uint32_t sabr_client_transport_default_frame_capacity(void);
uint32_t sabr_client_transport_max_clients(void);
Boolean sabr_client_transport_is_supported(AudioObjectID deviceObjectID);
Boolean sabr_client_transport_wait_for_notification(SABRClientTransportRef transport);
void sabr_client_transport_signal(SABRClientTransportRef transport);

#ifdef __cplusplus
}
#endif

#endif
