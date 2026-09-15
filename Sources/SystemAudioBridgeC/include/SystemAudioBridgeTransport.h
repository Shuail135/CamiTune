#ifndef SYSTEM_AUDIO_BRIDGE_TRANSPORT_H
#define SYSTEM_AUDIO_BRIDGE_TRANSPORT_H

#include <CoreAudio/CoreAudioTypes.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include "SystemAudioBridgeProfileFormat.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SABR_TRANSPORT_MAGIC UINT32_C(0x53414252) /* 'SABR' */
#define SABR_TRANSPORT_PROTOCOL_VERSION UINT32_C(5)
#define SABR_TRANSPORT_ABI_VERSION UINT32_C(5)
#define SABR_TRANSPORT_PROPERTY ((AudioObjectPropertySelector)UINT32_C(0x73616272)) /* 'sabr' */
#define SABR_TRANSPORT_SHM_NAME_CAPACITY 128
#define SABR_TRANSPORT_MAX_CHANNELS 32
#define SABR_TRANSPORT_DEFAULT_FRAME_CAPACITY 65536
#define SABR_TRANSPORT_MAX_FRAME_CAPACITY 262144
#define SABR_TRANSPORT_PACKET_CAPACITY 1024
#define SABR_TRANSPORT_CLIENT_CAPACITY 64
#define SABR_TRANSPORT_BUNDLE_ID_CAPACITY 256
#define SABR_TRANSPORT_MAX_PROFILE_DEVICES 32
#define SABR_TRANSPORT_MAX_DEVICE_UID_UTF16_LENGTH 256
#define SABR_TRANSPORT_MAX_DISPLAY_NAME_UTF16_LENGTH 128
#define SABR_TRANSPORT_SUPPORTED_CONFIGURATION_FLAGS UINT32_C(0)
#define SABR_TRANSPORT_SUPPORTED_HEADER_FLAGS UINT32_C(0)
#define SABR_TRANSPORT_SUPPORTED_PACKET_FLAGS UINT32_C(0)
#define SABR_CLIENT_IDENTITY_FLAG_BUNDLE_ID_UNAVAILABLE UINT32_C(1)
#define SABR_PACKET_STATE_FREE UINT32_C(0)
#define SABR_PACKET_STATE_READY UINT32_C(1)
#define SABR_PACKET_STATE_CONSUMED UINT32_C(2)

#define SABR_TRANSPORT_KEY_PROTOCOL_VERSION "protocolVersion"
#define SABR_TRANSPORT_KEY_ABI_VERSION "abiVersion"
#define SABR_TRANSPORT_KEY_DIRECTION "direction"
#define SABR_TRANSPORT_KEY_STREAM_ID "streamID"
#define SABR_TRANSPORT_KEY_BUS_INDEX "busIndex"
#define SABR_TRANSPORT_KEY_CHANNEL_CAPACITY "channelCapacity"
#define SABR_TRANSPORT_KEY_FRAME_CAPACITY "frameCapacity"
#define SABR_TRANSPORT_KEY_FLAGS "flags"
#define SABR_TRANSPORT_KEY_REGION_BYTES "regionBytes"
#define SABR_TRANSPORT_KEY_BACKING_FILE_PATH "backingFilePath"
#define SABR_TRANSPORT_KEY_SESSION_TOKEN "sessionToken"
#define SABR_TRANSPORT_KEY_COMMAND "command"
#define SABR_TRANSPORT_KEY_DISPLAY_NAME "displayName"
#define SABR_TRANSPORT_KEY_VISIBLE "visible"
#define SABR_TRANSPORT_KEY_PROFILES "profiles"
#define SABR_TRANSPORT_KEY_DEVICE_UID "deviceUID"
#define SABR_TRANSPORT_COMMAND_DISCONNECT "disconnect"
#define SABR_TRANSPORT_COMMAND_PRESENTATION "presentation"
#define SABR_TRANSPORT_COMMAND_PROFILE_DEVICES "profileDevices"

typedef enum SABRTransportDirection {
    SABR_TRANSPORT_DIRECTION_OUTPUT = 1,
    SABR_TRANSPORT_DIRECTION_INPUT = 2
} SABRTransportDirection;

typedef struct SABRTransportConfiguration {
    uint32_t protocolVersion;
    uint32_t direction;
    uint32_t streamID;
    uint32_t busIndex;
    uint32_t channelCapacity;
    uint32_t frameCapacity;
    uint32_t flags;
    uint32_t reserved32;
    uint64_t regionBytes;
    uint64_t sessionToken;
    char backingFilePath[SABR_TRANSPORT_SHM_NAME_CAPACITY];
} SABRTransportConfiguration;

/*
 * Protocol version 5 identifies the source endpoint and sample rate in every
 * packet and reserves a lock-free diagnostics/control snapshot lane. ABI revision 5 also
 * requires the token-derived wake semaphore and channel-capacity capability
 * used by the companion during negotiation.
 * The latest* fields are producer diagnostics only; consumers must use packet
 * metadata for queued audio. writeFrame and writePacket are reservation
 * cursors. Each packet's committed state publishes that producer's completed
 * descriptor independently, so overlapping real-time writers never wait for
 * an earlier writer to finish.
 */
typedef struct SABRTransportHeader {
    uint32_t magic;
    uint32_t protocolVersion;
    uint32_t headerBytes;
    uint32_t flags;

    uint32_t direction;
    uint32_t streamID;
    uint32_t busIndex;
    uint32_t channelCapacity;

    _Atomic uint32_t latestChannels;
    uint32_t frameCapacity;
    _Atomic uint32_t latestChannelLayoutTag;
    uint32_t reserved32;

    _Atomic uint64_t writeFrame;
    _Atomic uint64_t readFrame;
    _Atomic uint64_t droppedFrames;
    _Atomic uint64_t consumerOverrunCount;
    _Atomic uint64_t starvationCount;
    _Atomic uint64_t sequence;
    _Atomic uint64_t latestSampleRateBits;

    _Atomic uint64_t writePacket;
    _Atomic uint64_t readPacket;
    _Atomic uint64_t droppedPackets;
    uint32_t packetCapacity;
    uint32_t clientCapacity;
    _Atomic uint64_t clientGeneration;
    _Atomic uint64_t clientRegistryOverflowCount;
    _Atomic uint64_t clientUseCountSaturationCount;

    uint64_t sessionToken;

    /*
     * Diagnostics/control snapshot lane retained for protocol-v5 ABI compatibility.
     * Runtime profile volume/mute changes deliberately do not publish here: media-key
     * traffic must stay completely off the SABR PCM transport and its writer counters.
     * If diagnostics publish a snapshot, controlGeneration is an odd/even seqlock.
     */
    _Atomic uint64_t controlGeneration;
    _Atomic uint32_t controlDeviceObjectID;
    _Atomic uint32_t controlLinearGainBits;
    _Atomic uint32_t controlMuted;
    uint32_t reservedControl32;
} SABRTransportHeader;

typedef enum SABRClientState {
    SABR_CLIENT_STATE_EMPTY = 0,
    SABR_CLIENT_STATE_ACTIVE = 1,
    SABR_CLIENT_STATE_INACTIVE = 2
} SABRClientState;

typedef struct SABRTransportClient {
    _Atomic uint32_t state;
    _Atomic uint32_t clientID;
    _Atomic int32_t processID;
    _Atomic uint32_t deviceObjectID;
    _Atomic uint32_t identityFlags;
    _Atomic uint64_t generation;
    _Atomic uint8_t bundleID[SABR_TRANSPORT_BUNDLE_ID_CAPACITY];
} SABRTransportClient;

typedef struct SABRTransportPacket {
    uint64_t startFrame;
    uint64_t cycleCounter;
    uint64_t sampleTimeBits;
    uint64_t sampleRateBits;
    uint32_t clientID;
    int32_t processID;
    uint32_t deviceObjectID;
    uint32_t frameCount;
    uint32_t channelCount;
    uint32_t channelLayoutTag;
    uint32_t flags;
    uint32_t reserved32;
    uint64_t reservationSequence;
    _Atomic uint32_t committed;
    uint32_t reservedCommit32;
} SABRTransportPacket;

typedef struct SABRTransportStatistics {
    uint64_t writeFrame;
    uint64_t readFrame;
    uint64_t droppedFrames;
    uint64_t consumerOverrunCount;
    uint64_t starvationCount;
    uint64_t sequence;
    uint32_t latestChannels;
    uint32_t latestChannelLayoutTag;
    uint32_t frameCapacity;
    double latestSampleRate;
    uint64_t writePacket;
    uint64_t readPacket;
    uint64_t droppedPackets;
    uint64_t clientGeneration;
    uint64_t clientRegistryOverflowCount;
    uint64_t clientUseCountSaturationCount;
    uint64_t malformedPacketCount;
    uint64_t controlGeneration;
    uint32_t controlDeviceObjectID;
    float controlLinearGain;
    uint32_t controlMuted;
} SABRTransportStatistics;

static inline uint32_t sabr_float_to_bits(float value) {
    union { float value; uint32_t bits; } conversion = { .value = value };
    return conversion.bits;
}

static inline float sabr_bits_to_float(uint32_t bits) {
    union { float value; uint32_t bits; } conversion = { .bits = bits };
    return conversion.value;
}

static inline uint64_t sabr_double_to_bits(double value) {
    union { double value; uint64_t bits; } conversion = { .value = value };
    return conversion.bits;
}

static inline double sabr_bits_to_double(uint64_t bits) {
    union { double value; uint64_t bits; } conversion = { .bits = bits };
    return conversion.value;
}

static inline size_t sabr_transport_region_bytes(uint32_t channelCapacity, uint32_t frameCapacity) {
    if ((size_t)SABR_TRANSPORT_CLIENT_CAPACITY > SIZE_MAX / sizeof(SABRTransportClient) ||
        (size_t)SABR_TRANSPORT_PACKET_CAPACITY > SIZE_MAX / sizeof(SABRTransportPacket)) {
        return 0;
    }
    const size_t clientsBytes =
        (size_t)SABR_TRANSPORT_CLIENT_CAPACITY * sizeof(SABRTransportClient);
    const size_t packetsBytes =
        (size_t)SABR_TRANSPORT_PACKET_CAPACITY * sizeof(SABRTransportPacket);
    if (clientsBytes > SIZE_MAX - sizeof(SABRTransportHeader) ||
        packetsBytes > SIZE_MAX - sizeof(SABRTransportHeader) - clientsBytes) {
        return 0;
    }
    const size_t fixedBytes = sizeof(SABRTransportHeader) + clientsBytes + packetsBytes;
    if (channelCapacity == 0 || channelCapacity > SABR_TRANSPORT_MAX_CHANNELS ||
        frameCapacity == 0 || frameCapacity > SABR_TRANSPORT_MAX_FRAME_CAPACITY) {
        return 0;
    }
    if ((size_t)channelCapacity > SIZE_MAX / sizeof(Float32)) { return 0; }
    const size_t bytesPerFrame = (size_t)channelCapacity * sizeof(Float32);
    if ((size_t)frameCapacity > (SIZE_MAX - fixedBytes) / bytesPerFrame) { return 0; }
    return fixedBytes + ((size_t)frameCapacity * bytesPerFrame);
}

static inline SABRTransportClient* sabr_transport_clients(SABRTransportHeader* header) {
    return (SABRTransportClient*)((uint8_t*)header + sizeof(SABRTransportHeader));
}

static inline SABRTransportPacket* sabr_transport_packets(SABRTransportHeader* header) {
    return (SABRTransportPacket*)(
        (uint8_t*)sabr_transport_clients(header) +
        ((size_t)SABR_TRANSPORT_CLIENT_CAPACITY * sizeof(SABRTransportClient))
    );
}

static inline Float32* sabr_transport_samples(SABRTransportHeader* header) {
    return (Float32*)(
        (uint8_t*)sabr_transport_packets(header) +
        ((size_t)SABR_TRANSPORT_PACKET_CAPACITY * sizeof(SABRTransportPacket))
    );
}

_Static_assert(sizeof(SABRTransportHeader) == 192, "Transport header layout changed");
_Static_assert(sizeof(SABRTransportClient) == 288, "Transport client layout changed");
_Static_assert(sizeof(SABRTransportPacket) == 80, "Transport packet layout changed");
_Static_assert(ATOMIC_CHAR_LOCK_FREE == 2, "Byte transport atomics must be lock-free");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "32-bit transport atomics must be lock-free");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "64-bit transport atomics must be lock-free");

#ifdef __cplusplus
}
#endif

#endif
