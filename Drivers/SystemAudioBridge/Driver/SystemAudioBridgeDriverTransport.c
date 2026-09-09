#include "SystemAudioBridgeDriverTransport.h"

#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <semaphore.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syslog.h>
#include <unistd.h>

typedef struct SABRDriverMappedTransport {
    void* mapping;
    size_t mappingBytes;
    SABRTransportHeader* header;
    SABRTransportClient* clients;
    SABRTransportPacket* packets;
    Float32* samples;
    SABRTransportConfiguration configuration;
    sem_t* notification;
} SABRDriverMappedTransport;

static _Atomic(SABRDriverMappedTransport*) gTransport = NULL;
static _Atomic uint32_t gActiveWriters = 0;
static pthread_mutex_t gSessionMutex = PTHREAD_MUTEX_INITIALIZER;
static pid_t gSessionOwnerProcessID = 0;
static uint64_t gSessionToken = 0;

typedef struct SABRDriverClient {
    Boolean occupied;
    Boolean active;
    uint32_t useCount;
    uint32_t clientID;
    int32_t processID;
    AudioObjectID deviceObjectID;
    uint32_t identityFlags;
    uint64_t generation;
    char bundleID[SABR_TRANSPORT_BUNDLE_ID_CAPACITY];
} SABRDriverClient;

static SABRDriverClient gClients[SABR_TRANSPORT_CLIENT_CAPACITY];

/*
 * MixOutput is a real-time callback and cannot take gClientMutex. Keep a
 * second, lock-free identity snapshot whose only job is attaching the owning
 * process ID to each PCM packet. This snapshot is independent of the shared
 * client roster publication: sabr_publish_clients() intentionally marks that
 * roster transiently unavailable while copying it, which must never make live
 * audio packets lose their application identity.
 */
typedef struct SABRRealtimeClientIdentity {
    _Atomic uint64_t sequence;
    _Atomic uint32_t state;
    _Atomic uint32_t deviceObjectID;
    _Atomic uint32_t clientID;
    _Atomic int32_t processID;
} SABRRealtimeClientIdentity;

static SABRRealtimeClientIdentity gRealtimeClients[SABR_TRANSPORT_CLIENT_CAPACITY];
static uint64_t gClientGeneration = 0;
static uint64_t gClientRegistryOverflowCount = 0;
static uint64_t gClientUseCountSaturationCount = 0;
static pthread_mutex_t gClientMutex = PTHREAD_MUTEX_INITIALIZER;

/*
 * The counter and pointer operations are sequentially consistent as a pair.
 * If a callback observes an old mapping, its counter increment necessarily
 * precedes the exchange that retires that mapping; otherwise it observes the
 * replacement. This prevents disconnect/reconnect from unmapping storage
 * underneath an active real-time callback without putting a lock in that path.
 */
static SABRDriverMappedTransport* sabr_acquire_transport(void) {
    atomic_fetch_add_explicit(&gActiveWriters, 1, memory_order_seq_cst);
    return atomic_load_explicit(&gTransport, memory_order_seq_cst);
}

static void sabr_release_transport_access(void) {
    atomic_fetch_sub_explicit(&gActiveWriters, 1, memory_order_seq_cst);
}

static OSStatus sabr_reject_connection(const char* reason, OSStatus status) {
    syslog(
        LOG_ERR,
        "System Audio Bridge: SABR transport connection rejected at %s (status %d)",
        reason,
        (int)status
    );
    return status;
}

static Boolean sabr_notification_name(
    uint64_t token,
    const char* backingFilePath,
    char destination[32]
) {
    if (token == 0 || backingFilePath == NULL || destination == NULL) { return false; }
    const char* suffix = strrchr(backingFilePath, '.');
    if (suffix == NULL || strlen(suffix + 1) != 6) { return false; }
    const int length = snprintf(
        destination,
        32,
        "/sabr.%016llx.%s",
        (unsigned long long)token,
        suffix + 1
    );
    return length > 0 && length < 32;
}

static Boolean sabr_live_header_is_valid(const SABRDriverMappedTransport* transport) {
    if (transport == NULL || transport->header == NULL) { return false; }
    const SABRTransportHeader* header = transport->header;
    const SABRTransportConfiguration* configuration = &transport->configuration;
    return header->magic == SABR_TRANSPORT_MAGIC &&
        header->protocolVersion == SABR_TRANSPORT_PROTOCOL_VERSION &&
        header->headerBytes == sizeof(SABRTransportHeader) &&
        (header->flags & ~SABR_TRANSPORT_SUPPORTED_HEADER_FLAGS) == 0 &&
        header->direction == configuration->direction &&
        header->streamID == configuration->streamID &&
        header->busIndex == configuration->busIndex &&
        header->channelCapacity == configuration->channelCapacity &&
        header->frameCapacity == configuration->frameCapacity &&
        header->packetCapacity == SABR_TRANSPORT_PACKET_CAPACITY &&
        header->clientCapacity == SABR_TRANSPORT_CLIENT_CAPACITY &&
        header->sessionToken == configuration->sessionToken &&
        header->reserved32 == 0 &&
        header->reservedControl32 == 0 &&
        configuration->regionBytes == transport->mappingBytes;
}

static void sabr_store_shared_bundle_id(
    SABRTransportClient* destination,
    const char source[SABR_TRANSPORT_BUNDLE_ID_CAPACITY]
) {
    for (uint32_t byte = 0; byte < SABR_TRANSPORT_BUNDLE_ID_CAPACITY; ++byte) {
        atomic_store_explicit(
            &destination->bundleID[byte],
            (uint8_t)source[byte],
            memory_order_relaxed
        );
    }
}

static void sabr_publish_clients(SABRDriverMappedTransport* transport) {
    if (!sabr_live_header_is_valid(transport)) { return; }
    pthread_mutex_lock(&gClientMutex);
    atomic_store_explicit(
        &transport->header->clientGeneration,
        UINT64_MAX,
        memory_order_release
    );
    for (uint32_t index = 0; index < SABR_TRANSPORT_CLIENT_CAPACITY; ++index) {
        SABRTransportClient* destination = &transport->clients[index];
        atomic_store_explicit(&destination->state, SABR_CLIENT_STATE_EMPTY, memory_order_release);
        if (!gClients[index].occupied) { continue; }
        atomic_store_explicit(
            &destination->clientID,
            gClients[index].clientID,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &destination->processID,
            gClients[index].processID,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &destination->deviceObjectID,
            gClients[index].deviceObjectID,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &destination->identityFlags,
            gClients[index].identityFlags,
            memory_order_relaxed
        );
        sabr_store_shared_bundle_id(destination, gClients[index].bundleID);
        atomic_store_explicit(
            &destination->generation,
            gClients[index].generation,
            memory_order_release
        );
        atomic_store_explicit(
            &destination->state,
            gClients[index].active ? SABR_CLIENT_STATE_ACTIVE : SABR_CLIENT_STATE_INACTIVE,
            memory_order_release
        );
    }
    atomic_store_explicit(
        &transport->header->clientGeneration,
        gClientGeneration,
        memory_order_release
    );
    atomic_store_explicit(
        &transport->header->clientRegistryOverflowCount,
        gClientRegistryOverflowCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &transport->header->clientUseCountSaturationCount,
        gClientUseCountSaturationCount,
        memory_order_relaxed
    );
    pthread_mutex_unlock(&gClientMutex);
    if (transport->notification != SEM_FAILED) {
        (void)sem_post(transport->notification);
    }
}

static void sabr_publish_realtime_client_locked(uint32_t index) {
    if (index >= SABR_TRANSPORT_CLIENT_CAPACITY) { return; }
    SABRRealtimeClientIdentity* destination = &gRealtimeClients[index];

    /* Writers are serialized by gClientMutex. Publish the slot through a
     * seqlock so MixOutput can never combine fields from registrations that
     * reused the same bounded slot. Odd means write in progress; even means
     * the whole identity tuple is stable. */
    uint64_t sequence = atomic_load_explicit(&destination->sequence, memory_order_relaxed);
    if ((sequence & 1u) != 0) { sequence += 1; }
    atomic_store_explicit(&destination->sequence, sequence + 1, memory_order_release);

    const Boolean occupied = gClients[index].occupied;
    atomic_store_explicit(
        &destination->state,
        !occupied ? SABR_CLIENT_STATE_EMPTY
            : (gClients[index].active ? SABR_CLIENT_STATE_ACTIVE : SABR_CLIENT_STATE_INACTIVE),
        memory_order_relaxed
    );
    atomic_store_explicit(
        &destination->deviceObjectID,
        occupied ? gClients[index].deviceObjectID : kAudioObjectUnknown,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &destination->clientID,
        occupied ? gClients[index].clientID : 0,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &destination->processID,
        occupied ? gClients[index].processID : 0,
        memory_order_relaxed
    );
    atomic_store_explicit(&destination->sequence, sequence + 2, memory_order_release);
}

static int32_t sabr_active_process_id(
    AudioObjectID deviceObjectID,
    uint32_t clientID
) {
    for (uint32_t index = 0; index < SABR_TRANSPORT_CLIENT_CAPACITY; ++index) {
        const SABRRealtimeClientIdentity* client = &gRealtimeClients[index];
        const uint64_t before = atomic_load_explicit(&client->sequence, memory_order_acquire);
        if ((before & 1u) != 0) { continue; }

        const uint32_t state = atomic_load_explicit(&client->state, memory_order_relaxed);
        const uint32_t candidateDevice = atomic_load_explicit(
            &client->deviceObjectID,
            memory_order_relaxed
        );
        const uint32_t candidateClient = atomic_load_explicit(
            &client->clientID,
            memory_order_relaxed
        );
        const int32_t processID = atomic_load_explicit(
            &client->processID,
            memory_order_relaxed
        );
        const uint64_t after = atomic_load_explicit(&client->sequence, memory_order_acquire);
        if (before != after || (after & 1u) != 0) { continue; }

        if (state == SABR_CLIENT_STATE_ACTIVE &&
            candidateDevice == deviceObjectID && candidateClient == clientID) {
            return processID;
        }
    }
    return 0;
}

static Boolean sabr_dictionary_get_uint64(
    CFDictionaryRef dictionary,
    CFStringRef key,
    uint64_t* value
) {
    CFTypeRef object = CFDictionaryGetValue(dictionary, key);
    if (object == NULL || CFGetTypeID(object) != CFNumberGetTypeID()) { return false; }
    int64_t signedValue = 0;
    if (!CFNumberGetValue((CFNumberRef)object, kCFNumberSInt64Type, &signedValue) ||
        signedValue < 0) {
        return false;
    }
    *value = (uint64_t)signedValue;
    return true;
}

static OSStatus sabr_authorize_session(pid_t clientProcessID, uint64_t sessionToken) {
    if (clientProcessID <= 0 || sessionToken == 0 || sessionToken > INT64_MAX) {
        return kAudioHardwareIllegalOperationError;
    }

    OSStatus result = noErr;
    pthread_mutex_lock(&gSessionMutex);
    if (gSessionOwnerProcessID != 0 &&
        (gSessionOwnerProcessID != clientProcessID || gSessionToken != sessionToken)) {
        errno = 0;
        const Boolean ownerIsAlive = kill(gSessionOwnerProcessID, 0) == 0 || errno != ESRCH;
        if (ownerIsAlive) {
            result = kAudioHardwareIllegalOperationError;
        } else {
            gSessionOwnerProcessID = 0;
            gSessionToken = 0;
        }
    }
    if (result == noErr && gSessionOwnerProcessID == 0) {
        gSessionOwnerProcessID = clientProcessID;
        gSessionToken = sessionToken;
    }
    pthread_mutex_unlock(&gSessionMutex);
    return result;
}

static Boolean sabr_backing_file_name_is_valid(const char* name) {
    static const char prefix[] = "/private/tmp/sabr.";
    if (name == NULL || strncmp(name, prefix, sizeof(prefix) - 1) != 0 ||
        strlen(name) != (sizeof(prefix) - 1) + 6) {
        return false;
    }
    for (size_t index = sizeof(prefix) - 1; name[index] != '\0'; ++index) {
        const char character = name[index];
        const Boolean isAlphaNumeric =
            (character >= '0' && character <= '9') ||
            (character >= 'A' && character <= 'Z') ||
            (character >= 'a' && character <= 'z');
        if (!isAlphaNumeric) { return false; }
    }
    return true;
}

static void sabr_release_transport(SABRDriverMappedTransport* transport) {
    if (transport == NULL) { return; }
    while (atomic_load_explicit(&gActiveWriters, memory_order_seq_cst) != 0) {
        sched_yield();
    }
    munmap(transport->mapping, transport->mappingBytes);
    if (transport->notification != SEM_FAILED) { sem_close(transport->notification); }
    free(transport);
}

static void sabr_replace_transport(SABRDriverMappedTransport* replacement) {
    SABRDriverMappedTransport* previous = atomic_exchange_explicit(
        &gTransport,
        replacement,
        memory_order_seq_cst
    );
    sabr_release_transport(previous);
}

OSStatus sabr_driver_transport_connect(
    const SABRTransportConfiguration* configuration,
    pid_t clientProcessID
) {
    if (configuration == NULL || configuration->backingFilePath[0] == '\0') {
        return sabr_reject_connection("missing configuration", kAudioHardwareIllegalOperationError);
    }
    if (configuration->protocolVersion != SABR_TRANSPORT_PROTOCOL_VERSION ||
        configuration->direction != SABR_TRANSPORT_DIRECTION_OUTPUT ||
        configuration->streamID != 0 ||
        configuration->busIndex != 0 ||
        configuration->channelCapacity == 0 ||
        configuration->channelCapacity > SABR_TRANSPORT_MAX_CHANNELS ||
        configuration->frameCapacity == 0 ||
        configuration->frameCapacity > SABR_TRANSPORT_MAX_FRAME_CAPACITY ||
        (configuration->flags & ~SABR_TRANSPORT_SUPPORTED_CONFIGURATION_FLAGS) != 0 ||
        configuration->reserved32 != 0 ||
        configuration->sessionToken == 0) {
        return sabr_reject_connection("configuration validation", kAudioHardwareIllegalOperationError);
    }

    const size_t requiredBytes = sabr_transport_region_bytes(
        configuration->channelCapacity,
        configuration->frameCapacity
    );
    if (requiredBytes == 0 || configuration->regionBytes != requiredBytes) {
        return sabr_reject_connection("region-size validation", kAudioHardwareBadPropertySizeError);
    }

    char name[SABR_TRANSPORT_SHM_NAME_CAPACITY];
    memcpy(name, configuration->backingFilePath, sizeof(name));
    name[sizeof(name) - 1] = '\0';
    if (!sabr_backing_file_name_is_valid(name)) {
        return sabr_reject_connection("backing-file path validation", kAudioHardwareIllegalOperationError);
    }

    const int descriptor = open(name, O_RDWR | O_NOFOLLOW, 0);
    if (descriptor < 0) {
        return sabr_reject_connection("backing-file open", kAudioHardwareUnspecifiedError);
    }

    struct stat status;
    if (fstat(descriptor, &status) != 0) {
        close(descriptor);
        return sabr_reject_connection("backing-file stat", kAudioHardwareIllegalOperationError);
    }
    if (status.st_size < 0 || !S_ISREG(status.st_mode) || status.st_uid == 0 ||
        (status.st_mode & 0777) != 0600 || status.st_nlink != 1 ||
        (uint64_t)status.st_size != configuration->regionBytes) {
        syslog(
            LOG_ERR,
            "System Audio Bridge: SABR backing metadata rejected "
            "(mode %o, owner %u, expected non-root owner, links %u, size %lld, expected size %llu)",
            (unsigned)(status.st_mode & 07777),
            (unsigned)status.st_uid,
            (unsigned)status.st_nlink,
            (long long)status.st_size,
            (unsigned long long)configuration->regionBytes
        );
        close(descriptor);
        return kAudioHardwareIllegalOperationError;
    }

    void* mapping = mmap(NULL, requiredBytes, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0);
    close(descriptor);
    if (mapping == MAP_FAILED) {
        return sabr_reject_connection("backing-file mapping", kAudioHardwareUnspecifiedError);
    }

    SABRTransportHeader* header = (SABRTransportHeader*)mapping;
    if (header->magic != SABR_TRANSPORT_MAGIC ||
        header->protocolVersion != SABR_TRANSPORT_PROTOCOL_VERSION ||
        header->headerBytes != sizeof(SABRTransportHeader) ||
        (header->flags & ~SABR_TRANSPORT_SUPPORTED_HEADER_FLAGS) != 0 ||
        header->direction != configuration->direction ||
        header->streamID != configuration->streamID ||
        header->busIndex != configuration->busIndex ||
        header->channelCapacity != configuration->channelCapacity ||
        header->frameCapacity != configuration->frameCapacity ||
        header->sessionToken != configuration->sessionToken ||
        header->reserved32 != 0 ||
        header->reservedControl32 != 0 ||
        header->packetCapacity != SABR_TRANSPORT_PACKET_CAPACITY ||
        header->clientCapacity != SABR_TRANSPORT_CLIENT_CAPACITY) {
        munmap(mapping, requiredBytes);
        return sabr_reject_connection("mapped-header validation", kAudioHardwareIllegalOperationError);
    }

    /*
     * AudioServerPlugIn callbacks run in Apple's sandboxed driver service,
     * where proc_pidinfo(appPID) is denied. After validating the private file
     * and its token-bearing header, bind the Core Audio supplied PID to that
     * unguessable token instead.
     */
    const OSStatus authorization = sabr_authorize_session(
        clientProcessID,
        configuration->sessionToken
    );
    if (authorization != noErr) {
        munmap(mapping, requiredBytes);
        return sabr_reject_connection("session authorization", authorization);
    }

    SABRDriverMappedTransport* transport = calloc(1, sizeof(*transport));
    if (transport == NULL) {
        munmap(mapping, requiredBytes);
        return sabr_reject_connection("transport allocation", kAudioHardwareUnspecifiedError);
    }
    transport->mapping = mapping;
    transport->notification = SEM_FAILED;
    transport->mappingBytes = requiredBytes;
    transport->header = header;
    transport->clients = sabr_transport_clients(header);
    transport->packets = sabr_transport_packets(header);
    transport->samples = sabr_transport_samples(header);
    transport->configuration = *configuration;

    char notificationName[32];
    if (!sabr_notification_name(
            configuration->sessionToken,
            configuration->backingFilePath,
            notificationName)) {
        sabr_release_transport(transport);
        return sabr_reject_connection("notification name", kAudioHardwareIllegalOperationError);
    }
    transport->notification = sem_open(notificationName, 0);
    if (transport->notification == SEM_FAILED) {
        sabr_release_transport(transport);
        return sabr_reject_connection("notification open", kAudioHardwareUnspecifiedError);
    }

    sabr_publish_clients(transport);
    sabr_replace_transport(transport);
    return noErr;
}

OSStatus sabr_driver_transport_authorize_property_list(
    CFPropertyListRef propertyList,
    pid_t clientProcessID
) {
    if (propertyList == NULL || propertyList == kCFNull ||
        CFGetTypeID(propertyList) == CFNullGetTypeID() ||
        CFGetTypeID(propertyList) != CFDictionaryGetTypeID()) {
        return kAudioHardwareIllegalOperationError;
    }
    uint64_t sessionToken = 0;
    uint64_t abiVersion = 0;
    if (!sabr_dictionary_get_uint64(
            (CFDictionaryRef)propertyList,
            CFSTR(SABR_TRANSPORT_KEY_SESSION_TOKEN),
            &sessionToken) ||
        !sabr_dictionary_get_uint64(
            (CFDictionaryRef)propertyList,
            CFSTR(SABR_TRANSPORT_KEY_ABI_VERSION),
            &abiVersion) ||
        abiVersion != SABR_TRANSPORT_ABI_VERSION) {
        return kAudioHardwareIllegalOperationError;
    }
    return sabr_authorize_session(clientProcessID, sessionToken);
}

OSStatus sabr_driver_transport_connect_property_list(
    CFPropertyListRef propertyList,
    pid_t clientProcessID
) {
    if (propertyList == NULL || propertyList == kCFNull ||
        CFGetTypeID(propertyList) == CFNullGetTypeID() ||
        CFGetTypeID(propertyList) != CFDictionaryGetTypeID()) {
        return kAudioHardwareIllegalOperationError;
    }

    CFDictionaryRef dictionary = (CFDictionaryRef)propertyList;
    CFTypeRef command = CFDictionaryGetValue(
        dictionary,
        CFSTR(SABR_TRANSPORT_KEY_COMMAND)
    );
    if (command != NULL && CFGetTypeID(command) == CFStringGetTypeID() &&
        CFStringCompare(
            (CFStringRef)command,
            CFSTR(SABR_TRANSPORT_COMMAND_DISCONNECT),
            0
        ) == kCFCompareEqualTo) {
        const OSStatus authorization = sabr_driver_transport_authorize_property_list(
            propertyList,
            clientProcessID
        );
        if (authorization != noErr) { return authorization; }
        sabr_driver_transport_disconnect();
        return noErr;
    }

    SABRTransportConfiguration configuration;
    memset(&configuration, 0, sizeof(configuration));
    uint64_t value = 0;

#define SABR_READ_U32(field, key) \
    do { \
        if (!sabr_dictionary_get_uint64(dictionary, CFSTR(key), &value) || value > UINT32_MAX) { \
            return kAudioHardwareIllegalOperationError; \
        } \
        configuration.field = (uint32_t)value; \
    } while (0)

    SABR_READ_U32(protocolVersion, SABR_TRANSPORT_KEY_PROTOCOL_VERSION);
    SABR_READ_U32(direction, SABR_TRANSPORT_KEY_DIRECTION);
    SABR_READ_U32(streamID, SABR_TRANSPORT_KEY_STREAM_ID);
    SABR_READ_U32(busIndex, SABR_TRANSPORT_KEY_BUS_INDEX);
    SABR_READ_U32(channelCapacity, SABR_TRANSPORT_KEY_CHANNEL_CAPACITY);
    SABR_READ_U32(frameCapacity, SABR_TRANSPORT_KEY_FRAME_CAPACITY);
    SABR_READ_U32(flags, SABR_TRANSPORT_KEY_FLAGS);
#undef SABR_READ_U32

    if (!sabr_dictionary_get_uint64(
            dictionary,
            CFSTR(SABR_TRANSPORT_KEY_REGION_BYTES),
            &configuration.regionBytes)) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!sabr_dictionary_get_uint64(
            dictionary,
            CFSTR(SABR_TRANSPORT_KEY_SESSION_TOKEN),
            &configuration.sessionToken)) {
        return kAudioHardwareIllegalOperationError;
    }

    CFTypeRef path = CFDictionaryGetValue(
        dictionary,
        CFSTR(SABR_TRANSPORT_KEY_BACKING_FILE_PATH)
    );
    if (path == NULL || CFGetTypeID(path) != CFStringGetTypeID() ||
        !CFStringGetCString(
            (CFStringRef)path,
            configuration.backingFilePath,
            sizeof(configuration.backingFilePath),
            kCFStringEncodingUTF8)) {
        return kAudioHardwareIllegalOperationError;
    }

    return sabr_driver_transport_connect(&configuration, clientProcessID);
}

void sabr_driver_transport_disconnect(void) {
    sabr_replace_transport(NULL);

    /*
     * The driver service outlives the client application. A normal disconnect
     * therefore has to retire both halves of the session: keeping the owner
     * PID/token here makes the next app launch look like an attempted session
     * hijack until coreaudiod itself is restarted.
     *
     * Production callers reach this function only after the disconnect
     * property list has passed sabr_authorize_session(). Tests also use it as
     * the driver-side teardown primitive.
     */
    pthread_mutex_lock(&gSessionMutex);
    gSessionOwnerProcessID = 0;
    gSessionToken = 0;
    pthread_mutex_unlock(&gSessionMutex);
}

void sabr_driver_transport_add_client(
    AudioObjectID deviceObjectID,
    uint32_t clientID,
    int32_t processID,
    CFStringRef bundleID
) {
    pthread_mutex_lock(&gClientMutex);
    uint32_t slot = SABR_TRANSPORT_CLIENT_CAPACITY;
    uint32_t emptySlot = SABR_TRANSPORT_CLIENT_CAPACITY;
    for (uint32_t index = 0; index < SABR_TRANSPORT_CLIENT_CAPACITY; ++index) {
        if (gClients[index].occupied &&
            gClients[index].deviceObjectID == deviceObjectID &&
            gClients[index].clientID == clientID) {
            slot = index;
            break;
        }
        if (!gClients[index].occupied) {
            if (emptySlot == SABR_TRANSPORT_CLIENT_CAPACITY) { emptySlot = index; }
            continue;
        }
    }
    if (slot == SABR_TRANSPORT_CLIENT_CAPACITY) {
        slot = emptySlot;
    }
    if (slot < SABR_TRANSPORT_CLIENT_CAPACITY) {
        SABRDriverClient* client = &gClients[slot];
        const Boolean existing = client->occupied &&
            client->deviceObjectID == deviceObjectID &&
            client->clientID == clientID;
        if (!existing) { memset(client, 0, sizeof(*client)); }
        client->occupied = true;
        client->active = true;
        if (!existing) {
            client->useCount = 1;
        } else if (client->useCount == UINT32_MAX) {
            gClientUseCountSaturationCount += 1;
        } else {
            client->useCount += 1;
        }
        client->clientID = clientID;
        client->processID = processID;
        client->deviceObjectID = deviceObjectID;
        client->generation = ++gClientGeneration;
        memset(client->bundleID, 0, sizeof(client->bundleID));
        client->identityFlags = SABR_CLIENT_IDENTITY_FLAG_BUNDLE_ID_UNAVAILABLE;
        if (bundleID != NULL) {
            const Boolean converted = CFStringGetCString(
                bundleID,
                client->bundleID,
                sizeof(client->bundleID),
                kCFStringEncodingUTF8
            );
            if (converted) {
                client->identityFlags = 0;
            } else {
                client->bundleID[0] = '\0';
            }
        }
    } else {
        /* The bounded shared registry never sacrifices an active identity. */
        gClientRegistryOverflowCount += 1;
    }
    if (slot < SABR_TRANSPORT_CLIENT_CAPACITY) {
        sabr_publish_realtime_client_locked(slot);
    }
    pthread_mutex_unlock(&gClientMutex);

    SABRDriverMappedTransport* transport = sabr_acquire_transport();
    sabr_publish_clients(transport);
    sabr_release_transport_access();
}

void sabr_driver_transport_remove_client(AudioObjectID deviceObjectID, uint32_t clientID) {
    pthread_mutex_lock(&gClientMutex);
    for (uint32_t index = 0; index < SABR_TRANSPORT_CLIENT_CAPACITY; ++index) {
        if (!gClients[index].occupied ||
            gClients[index].deviceObjectID != deviceObjectID ||
            gClients[index].clientID != clientID) {
            continue;
        }
        if (gClients[index].useCount > 0) { gClients[index].useCount -= 1; }
        gClientGeneration += 1;
        if (gClients[index].useCount == 0) {
            /* Retention policy: reclaim immediately after the last reference. */
            memset(&gClients[index], 0, sizeof(gClients[index]));
        } else {
            gClients[index].active = true;
            gClients[index].generation = gClientGeneration;
        }
        sabr_publish_realtime_client_locked(index);
        break;
    }
    pthread_mutex_unlock(&gClientMutex);

    SABRDriverMappedTransport* transport = sabr_acquire_transport();
    sabr_publish_clients(transport);
    sabr_release_transport_access();
}

void sabr_driver_transport_get_configuration(SABRTransportConfiguration* configuration) {
    if (configuration == NULL) { return; }
    memset(configuration, 0, sizeof(*configuration));
    SABRDriverMappedTransport* transport = sabr_acquire_transport();
    if (transport != NULL) { *configuration = transport->configuration; }
    sabr_release_transport_access();
}

static Boolean sabr_reserve_ring_space(
    _Atomic uint64_t* writeCursor,
    const _Atomic uint64_t* readCursor,
    uint64_t capacity,
    uint64_t requested,
    uint64_t* reservation
) {
    uint64_t candidate = atomic_load_explicit(writeCursor, memory_order_relaxed);
    for (;;) {
        const uint64_t read = atomic_load_explicit(readCursor, memory_order_acquire);
        const uint64_t used = candidate - read;
        if (used > capacity || requested > capacity - used) { return false; }
        if (atomic_compare_exchange_weak_explicit(
                writeCursor,
                &candidate,
                candidate + requested,
                memory_order_acq_rel,
                memory_order_relaxed)) {
            *reservation = candidate;
            return true;
        }
    }
}

void sabr_driver_transport_publish_control(
    AudioObjectID deviceObjectID,
    Float32 linearGain,
    Boolean muted
) {
    if (deviceObjectID == kAudioObjectUnknown || !isfinite(linearGain)) { return; }
    if (linearGain < 0.0f) { linearGain = 0.0f; }
    if (linearGain > 1.0f) { linearGain = 1.0f; }

    SABRDriverMappedTransport* transport = sabr_acquire_transport();
    if (transport == NULL || !sabr_live_header_is_valid(transport)) {
        sabr_release_transport_access();
        return;
    }

    /*
     * Publish media-key state on a tiny writer-serialized seqlock lane rather
     * than forcing the companion back through HAL/CamillaDSP. A plain
     * "payload then generation++" scheme lets a reader observe half of the
     * next key-repeat write while the generation still describes the previous
     * value. Claim an odd generation first, write the complete payload, then
     * commit the following even generation. This also serializes concurrent
     * HAL control writers without a mutex or any MixOutput involvement.
     */
    uint64_t generation = atomic_load_explicit(
        &transport->header->controlGeneration,
        memory_order_acquire
    );
    for (;;) {
        if ((generation & 1u) != 0) {
            generation = atomic_load_explicit(
                &transport->header->controlGeneration,
                memory_order_acquire
            );
            continue;
        }
        uint64_t expected = generation;
        if (atomic_compare_exchange_weak_explicit(
                &transport->header->controlGeneration,
                &expected,
                generation + 1,
                memory_order_acq_rel,
                memory_order_acquire)) {
            break;
        }
        generation = expected;
    }

    atomic_store_explicit(
        &transport->header->controlDeviceObjectID,
        deviceObjectID,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &transport->header->controlLinearGainBits,
        sabr_float_to_bits(linearGain),
        memory_order_relaxed
    );
    atomic_store_explicit(
        &transport->header->controlMuted,
        muted ? 1u : 0u,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &transport->header->controlGeneration,
        generation + 2,
        memory_order_release
    );
    /*
     * Do not signal the PCM consumer for control-only changes. The next audio
     * packet reads this latest value before it is routed; the existing
     * maintenance wake handles idle playback. A key repeat therefore cannot
     * add scheduler pressure or perturb packet/timeline processing.
     */
    sabr_release_transport_access();
}

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
) {
    if (interleavedSamples == NULL || frameCount == 0 || channelCount == 0) { return; }

    SABRDriverMappedTransport* transport = sabr_acquire_transport();
    if (transport == NULL) {
        sabr_release_transport_access();
        return;
    }
    if (!sabr_live_header_is_valid(transport)) {
        sabr_release_transport_access();
        return;
    }

    SABRTransportHeader* header = transport->header;
    const uint32_t capacity = header->frameCapacity;
    const uint32_t channelCapacity = header->channelCapacity;
    if (channelCount > channelCapacity || frameCount > capacity) {
        atomic_fetch_add_explicit(&header->droppedFrames, frameCount, memory_order_relaxed);
        atomic_fetch_add_explicit(&header->droppedPackets, 1, memory_order_relaxed);
        sabr_release_transport_access();
        return;
    }

    uint64_t writePacket = 0;
    if (!sabr_reserve_ring_space(
            &header->writePacket,
            &header->readPacket,
            header->packetCapacity,
            1,
            &writePacket)) {
        atomic_fetch_add_explicit(&header->droppedFrames, frameCount, memory_order_relaxed);
        atomic_fetch_add_explicit(&header->droppedPackets, 1, memory_order_relaxed);
        sabr_release_transport_access();
        return;
    }

    SABRTransportPacket* packet = &transport->packets[writePacket % header->packetCapacity];
    atomic_store_explicit(&packet->committed, SABR_PACKET_STATE_FREE, memory_order_relaxed);
    packet->reservationSequence = writePacket;

    uint64_t writeFrame = 0;
    if (!sabr_reserve_ring_space(
            &header->writeFrame,
            &header->readFrame,
            capacity,
            frameCount,
            &writeFrame)) {
        packet->startFrame = 0;
        packet->cycleCounter = cycleCounter;
        packet->sampleTimeBits = sabr_double_to_bits(sampleTime);
        packet->sampleRateBits = sabr_double_to_bits(sampleRate);
        packet->clientID = clientID;
        packet->processID = 0;
        packet->deviceObjectID = deviceObjectID;
        packet->frameCount = 0;
        packet->channelCount = 0;
        packet->channelLayoutTag = 0;
        packet->flags = 0;
        packet->reserved32 = 0;
        packet->reservedCommit32 = 0;
        atomic_store_explicit(&packet->committed, SABR_PACKET_STATE_READY, memory_order_release);
        (void)sem_post(transport->notification);
        atomic_fetch_add_explicit(&header->droppedFrames, frameCount, memory_order_relaxed);
        atomic_fetch_add_explicit(&header->droppedPackets, 1, memory_order_relaxed);
        sabr_release_transport_access();
        return;
    }

    const uint32_t startFrame = (uint32_t)(writeFrame % capacity);
    const uint32_t firstFrames = frameCount < capacity - startFrame ? frameCount : capacity - startFrame;
    const uint32_t secondFrames = frameCount - firstFrames;
    if (channelCount == channelCapacity) {
        memcpy(
            transport->samples + ((size_t)startFrame * channelCapacity),
            interleavedSamples,
            (size_t)firstFrames * channelCount * sizeof(Float32)
        );
    } else {
        /* Clear each contiguous ring span once, then expand only the active
         * channels. This removes a second function call from every frame and
         * keeps the normal negotiated equal-stride path entirely bulk-copy. */
        memset(
            transport->samples + ((size_t)startFrame * channelCapacity),
            0,
            (size_t)firstFrames * channelCapacity * sizeof(Float32)
        );
        for (uint32_t sourceFrame = 0; sourceFrame < firstFrames; ++sourceFrame) {
            Float32* destination = transport->samples +
                ((size_t)(startFrame + sourceFrame) * channelCapacity);
            const Float32* source = interleavedSamples + ((size_t)sourceFrame * channelCount);
            memcpy(destination, source, (size_t)channelCount * sizeof(Float32));
        }
    }
    if (secondFrames > 0) {
        if (channelCount == channelCapacity) {
            memcpy(
                transport->samples,
                interleavedSamples + ((size_t)firstFrames * channelCount),
                (size_t)secondFrames * channelCount * sizeof(Float32)
            );
        } else {
            memset(
                transport->samples,
                0,
                (size_t)secondFrames * channelCapacity * sizeof(Float32)
            );
            for (uint32_t frame = 0; frame < secondFrames; ++frame) {
                Float32* destination = transport->samples + ((size_t)frame * channelCapacity);
                const Float32* source = interleavedSamples +
                    ((size_t)(firstFrames + frame) * channelCount);
                memcpy(destination, source, (size_t)channelCount * sizeof(Float32));
            }
        }
    }

    atomic_store_explicit(&header->latestChannels, channelCount, memory_order_relaxed);
    atomic_store_explicit(
        &header->latestChannelLayoutTag,
        channelLayoutTag,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &header->latestSampleRateBits,
        sabr_double_to_bits(sampleRate),
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(&header->sequence, 1, memory_order_relaxed);
    packet->startFrame = writeFrame;
    packet->cycleCounter = cycleCounter;
    packet->sampleTimeBits = sabr_double_to_bits(sampleTime);
    packet->sampleRateBits = sabr_double_to_bits(sampleRate);
    packet->clientID = clientID;
    packet->deviceObjectID = deviceObjectID;
    packet->processID = sabr_active_process_id(deviceObjectID, clientID);
    packet->frameCount = frameCount;
    packet->channelCount = channelCount;
    packet->channelLayoutTag = channelLayoutTag;
    packet->flags = 0;
    packet->reserved32 = 0;
    packet->reservedCommit32 = 0;
    /* Publish only after this producer has finished its unique sample reservation. */
    atomic_store_explicit(&packet->committed, SABR_PACKET_STATE_READY, memory_order_release);
    (void)sem_post(transport->notification);
    sabr_release_transport_access();
}
