#include "SystemAudioBridgeClient.h"

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <membership.h>
#include <pthread.h>
#include <pwd.h>
#include <semaphore.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/acl.h>
#include <sys/stat.h>
#include <unistd.h>

struct SABRClientTransport {
    int descriptor;
    void* mapping;
    size_t mappingBytes;
    SABRTransportHeader* header;
    SABRTransportClient* clients;
    SABRTransportPacket* packets;
    Float32* samples;
    SABRTransportConfiguration configuration;
    _Atomic uint64_t malformedPacketCount;
    sem_t* notification;
    char notificationName[32];
    Boolean isLinked;
    Boolean isNotificationLinked;
};

static CFNumberRef sabr_number_create(uint64_t value);

static pthread_once_t gSABRSessionTokenOnce = PTHREAD_ONCE_INIT;
static uint64_t gSABRSessionToken = 0;
static pthread_mutex_t gSABRSemaphoreCreationMutex = PTHREAD_MUTEX_INITIALIZER;

static void sabr_initialize_session_token(void) {
    do {
        arc4random_buf(&gSABRSessionToken, sizeof(gSABRSessionToken));
        gSABRSessionToken &= INT64_MAX;
    } while (gSABRSessionToken == 0);
}

static uint64_t sabr_client_session_token(void) {
    pthread_once(&gSABRSessionTokenOnce, sabr_initialize_session_token);
    return gSABRSessionToken;
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

static Boolean sabr_client_add_authorization(CFMutableDictionaryRef dictionary) {
    if (dictionary == NULL) { return false; }
    CFNumberRef token = sabr_number_create(sabr_client_session_token());
    CFNumberRef abiVersion = sabr_number_create(SABR_TRANSPORT_ABI_VERSION);
    if (token == NULL || abiVersion == NULL) {
        if (token != NULL) { CFRelease(token); }
        if (abiVersion != NULL) { CFRelease(abiVersion); }
        return false;
    }
    CFDictionarySetValue(dictionary, CFSTR(SABR_TRANSPORT_KEY_SESSION_TOKEN), token);
    CFDictionarySetValue(dictionary, CFSTR(SABR_TRANSPORT_KEY_ABI_VERSION), abiVersion);
    CFRelease(token);
    CFRelease(abiVersion);
    return true;
}

static Boolean sabr_grant_coreaudiod_access(int descriptor) {
    struct passwd passwordStorage;
    struct passwd* password = NULL;
    char passwordBuffer[1024];
    if (getpwnam_r(
            "_coreaudiod",
            &passwordStorage,
            passwordBuffer,
            sizeof(passwordBuffer),
            &password) != 0 || password == NULL) {
        return false;
    }

    uuid_t coreAudioUser;
    if (mbr_uid_to_uuid(password->pw_uid, coreAudioUser) != 0) { return false; }

    Boolean configured = false;
    acl_t accessControlList = acl_init(1);
    acl_entry_t entry = NULL;
    acl_permset_t permissions = NULL;
    acl_flagset_t flags = NULL;
    if (accessControlList != NULL &&
        acl_create_entry(&accessControlList, &entry) == 0 &&
        acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0 &&
        acl_set_qualifier(entry, &coreAudioUser) == 0 &&
        acl_get_permset(entry, &permissions) == 0 &&
        acl_clear_perms(permissions) == 0 &&
        acl_add_perm(permissions, ACL_READ_DATA) == 0 &&
        acl_add_perm(permissions, ACL_WRITE_DATA) == 0 &&
        acl_add_perm(permissions, ACL_SYNCHRONIZE) == 0 &&
        acl_set_permset(entry, permissions) == 0 &&
        acl_get_flagset_np(entry, &flags) == 0 &&
        acl_clear_flags_np(flags) == 0 &&
        acl_set_flagset_np(entry, flags) == 0 &&
        acl_valid(accessControlList) == 0 &&
        acl_set_fd_np(descriptor, accessControlList, ACL_TYPE_EXTENDED) == 0) {
        configured = true;
    }
    if (accessControlList != NULL) { acl_free(accessControlList); }
    return configured;
}

static Boolean sabr_packet_is_supported(
    const SABRTransportPacket* packet,
    const SABRTransportHeader* header,
    uint32_t destinationChannelCapacity,
    uint32_t maximumFrames
) {
    const double sampleRate = sabr_bits_to_double(packet->sampleRateBits);
    return packet->frameCount > 0 && packet->frameCount <= maximumFrames &&
        packet->channelCount > 0 && packet->channelCount <= header->channelCapacity &&
        packet->channelCount <= destinationChannelCapacity &&
        packet->deviceObjectID != kAudioObjectUnknown &&
        (packet->flags & ~SABR_TRANSPORT_SUPPORTED_PACKET_FLAGS) == 0 &&
        packet->reserved32 == 0 && packet->reservedCommit32 == 0 &&
        sampleRate > 0 && isfinite(sampleRate);
}

static Boolean sabr_client_header_is_valid(SABRClientTransportRef transport) {
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
        sabr_transport_region_bytes(header->channelCapacity, header->frameCapacity) ==
            transport->mappingBytes;
}

static void sabr_record_malformed_packet(SABRClientTransportRef transport) {
    atomic_fetch_add_explicit(
        &transport->malformedPacketCount,
        1,
        memory_order_relaxed
    );
}

static void sabr_reclaim_consumed_packets(
    SABRClientTransportRef transport,
    uint64_t observedWritePacket
) {
    SABRTransportHeader* header = transport->header;
    uint64_t readPacket = atomic_load_explicit(&header->readPacket, memory_order_relaxed);
    const uint64_t availablePackets = observedWritePacket - readPacket;
    if (availablePackets > header->packetCapacity) { return; }
    const uint64_t limit = readPacket + availablePackets;
    while (readPacket != limit) {
        SABRTransportPacket* packet = &transport->packets[readPacket % header->packetCapacity];
        if (atomic_load_explicit(&packet->committed, memory_order_acquire) !=
                SABR_PACKET_STATE_CONSUMED ||
            packet->reservationSequence != readPacket) {
            break;
        }
        atomic_store_explicit(&packet->committed, SABR_PACKET_STATE_FREE, memory_order_release);
        readPacket += 1;
    }
    atomic_store_explicit(&header->readPacket, readPacket, memory_order_release);
}

static CFNumberRef sabr_number_create(uint64_t value) {
    int64_t signedValue = (int64_t)value;
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &signedValue);
}

static Boolean sabr_dictionary_get_uint64(
    CFDictionaryRef dictionary,
    CFStringRef key,
    uint64_t* value
) {
    if (dictionary == NULL || value == NULL) { return false; }
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

static CFPropertyListRef sabr_client_transport_copy_property_list(
    const SABRTransportConfiguration* configuration
) {
    if (configuration == NULL) { return NULL; }
    CFMutableDictionaryRef dictionary = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    if (dictionary == NULL) { return NULL; }

#define SABR_SET_NUMBER(key, field) \
    do { \
        CFNumberRef number = sabr_number_create(configuration->field); \
        if (number == NULL) { CFRelease(dictionary); return NULL; } \
        CFDictionarySetValue(dictionary, CFSTR(key), number); \
        CFRelease(number); \
    } while (0)

    SABR_SET_NUMBER(SABR_TRANSPORT_KEY_PROTOCOL_VERSION, protocolVersion);
    SABR_SET_NUMBER(SABR_TRANSPORT_KEY_DIRECTION, direction);
    SABR_SET_NUMBER(SABR_TRANSPORT_KEY_STREAM_ID, streamID);
    SABR_SET_NUMBER(SABR_TRANSPORT_KEY_BUS_INDEX, busIndex);
    SABR_SET_NUMBER(SABR_TRANSPORT_KEY_CHANNEL_CAPACITY, channelCapacity);
    SABR_SET_NUMBER(SABR_TRANSPORT_KEY_FRAME_CAPACITY, frameCapacity);
    SABR_SET_NUMBER(SABR_TRANSPORT_KEY_FLAGS, flags);
    SABR_SET_NUMBER(SABR_TRANSPORT_KEY_REGION_BYTES, regionBytes);
    SABR_SET_NUMBER(SABR_TRANSPORT_KEY_SESSION_TOKEN, sessionToken);
#undef SABR_SET_NUMBER

    CFNumberRef abiVersion = sabr_number_create(SABR_TRANSPORT_ABI_VERSION);
    if (abiVersion == NULL) { CFRelease(dictionary); return NULL; }
    CFDictionarySetValue(dictionary, CFSTR(SABR_TRANSPORT_KEY_ABI_VERSION), abiVersion);
    CFRelease(abiVersion);

    CFStringRef path = CFStringCreateWithCString(
        kCFAllocatorDefault,
        configuration->backingFilePath,
        kCFStringEncodingUTF8
    );
    if (path == NULL) { CFRelease(dictionary); return NULL; }
    CFDictionarySetValue(
        dictionary,
        CFSTR(SABR_TRANSPORT_KEY_BACKING_FILE_PATH),
        path
    );
    CFRelease(path);
    return dictionary;
}

SABRClientTransportRef sabr_client_transport_create(
    uint32_t channelCapacity,
    uint32_t frameCapacity
) {
    const size_t mappingBytes = sabr_transport_region_bytes(channelCapacity, frameCapacity);
    if (mappingBytes == 0) { return NULL; }

    SABRClientTransportRef transport = calloc(1, sizeof(*transport));
    if (transport == NULL) { return NULL; }
    transport->descriptor = -1;
    transport->notification = SEM_FAILED;
    atomic_init(&transport->malformedPacketCount, 0);

    char pathTemplate[] = "/private/tmp/sabr.XXXXXX";
    const int descriptor = mkstemp(pathTemplate);
    if (descriptor < 0) {
        free(transport);
        return NULL;
    }
    const int descriptorFlags = fcntl(descriptor, F_GETFD);
    if (descriptorFlags < 0 ||
        fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) != 0) {
        close(descriptor);
        unlink(pathTemplate);
        free(transport);
        return NULL;
    }
    if (strlen(pathTemplate) >= sizeof(transport->configuration.backingFilePath)) {
        close(descriptor);
        unlink(pathTemplate);
        free(transport);
        return NULL;
    }
    strcpy(transport->configuration.backingFilePath, pathTemplate);
    transport->descriptor = descriptor;
    transport->isLinked = true;
    if (fchmod(descriptor, 0600) != 0 ||
        !sabr_grant_coreaudiod_access(descriptor) ||
        ftruncate(descriptor, (off_t)mappingBytes) != 0) {
        sabr_client_transport_destroy(transport);
        return NULL;
    }

    void* mapping = mmap(NULL, mappingBytes, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0);
    if (mapping == MAP_FAILED) {
        transport->mapping = NULL;
        sabr_client_transport_destroy(transport);
        return NULL;
    }
    transport->mapping = mapping;
    transport->mappingBytes = mappingBytes;
    transport->header = (SABRTransportHeader*)mapping;
    transport->clients = sabr_transport_clients(transport->header);
    transport->packets = sabr_transport_packets(transport->header);
    transport->samples = sabr_transport_samples(transport->header);

    memset(mapping, 0, mappingBytes);
    atomic_init(&transport->header->latestChannels, 0);
    atomic_init(&transport->header->latestChannelLayoutTag, 0);
    atomic_init(&transport->header->writeFrame, 0);
    atomic_init(&transport->header->readFrame, 0);
    atomic_init(&transport->header->droppedFrames, 0);
    atomic_init(&transport->header->consumerOverrunCount, 0);
    atomic_init(&transport->header->starvationCount, 0);
    atomic_init(&transport->header->sequence, 0);
    atomic_init(&transport->header->latestSampleRateBits, 0);
    atomic_init(&transport->header->writePacket, 0);
    atomic_init(&transport->header->readPacket, 0);
    atomic_init(&transport->header->droppedPackets, 0);
    atomic_init(&transport->header->clientGeneration, 0);
    atomic_init(&transport->header->clientRegistryOverflowCount, 0);
    atomic_init(&transport->header->clientUseCountSaturationCount, 0);
    atomic_init(&transport->header->controlGeneration, 0);
    atomic_init(&transport->header->controlDeviceObjectID, kAudioObjectUnknown);
    atomic_init(&transport->header->controlLinearGainBits, sabr_float_to_bits(1.0f));
    atomic_init(&transport->header->controlMuted, 0);
    transport->header->reservedControl32 = 0;
    for (uint32_t index = 0; index < SABR_TRANSPORT_CLIENT_CAPACITY; ++index) {
        SABRTransportClient* client = &transport->clients[index];
        atomic_init(&client->state, SABR_CLIENT_STATE_EMPTY);
        atomic_init(&client->clientID, 0);
        atomic_init(&client->processID, 0);
        atomic_init(&client->deviceObjectID, kAudioObjectUnknown);
        atomic_init(&client->identityFlags, SABR_CLIENT_IDENTITY_FLAG_BUNDLE_ID_UNAVAILABLE);
        atomic_init(&client->generation, 0);
        for (uint32_t byte = 0; byte < SABR_TRANSPORT_BUNDLE_ID_CAPACITY; ++byte) {
            atomic_init(&client->bundleID[byte], 0);
        }
    }
    for (uint32_t index = 0; index < SABR_TRANSPORT_PACKET_CAPACITY; ++index) {
        atomic_init(&transport->packets[index].committed, 0);
    }
    transport->header->magic = SABR_TRANSPORT_MAGIC;
    transport->header->protocolVersion = SABR_TRANSPORT_PROTOCOL_VERSION;
    transport->header->headerBytes = sizeof(SABRTransportHeader);
    transport->header->direction = SABR_TRANSPORT_DIRECTION_OUTPUT;
    transport->header->streamID = 0;
    transport->header->busIndex = 0;
    transport->header->channelCapacity = channelCapacity;
    transport->header->frameCapacity = frameCapacity;
    transport->header->packetCapacity = SABR_TRANSPORT_PACKET_CAPACITY;
    transport->header->clientCapacity = SABR_TRANSPORT_CLIENT_CAPACITY;
    transport->header->sessionToken = sabr_client_session_token();

    if (!sabr_notification_name(
            transport->header->sessionToken,
            transport->configuration.backingFilePath,
            transport->notificationName)) {
        sabr_client_transport_destroy(transport);
        return NULL;
    }
    sem_unlink(transport->notificationName);
    /* coreaudiod runs under a different account. The random token is the
     * capability, and the name is unlinked immediately after both processes
     * have opened it. Temporarily suppress umask so mode 0666 is not silently
     * reduced to a mode the driver service cannot open. */
    pthread_mutex_lock(&gSABRSemaphoreCreationMutex);
    const mode_t previousMask = umask(0);
    transport->notification = sem_open(
        transport->notificationName,
        O_CREAT | O_EXCL,
        0666,
        0
    );
    umask(previousMask);
    pthread_mutex_unlock(&gSABRSemaphoreCreationMutex);
    if (transport->notification == SEM_FAILED) {
        sabr_client_transport_destroy(transport);
        return NULL;
    }
    transport->isNotificationLinked = true;

    transport->configuration.protocolVersion = SABR_TRANSPORT_PROTOCOL_VERSION;
    transport->configuration.direction = SABR_TRANSPORT_DIRECTION_OUTPUT;
    transport->configuration.streamID = 0;
    transport->configuration.busIndex = 0;
    transport->configuration.channelCapacity = channelCapacity;
    transport->configuration.frameCapacity = frameCapacity;
    transport->configuration.regionBytes = mappingBytes;
    transport->configuration.sessionToken = transport->header->sessionToken;
    return transport;
}

OSStatus sabr_client_transport_connect(
    SABRClientTransportRef transport,
    AudioObjectID deviceObjectID
) {
    if (transport == NULL || transport->mapping == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    CFPropertyListRef propertyList = sabr_client_transport_copy_property_list(
        &transport->configuration
    );
    if (propertyList == NULL) { return kAudioHardwareUnspecifiedError; }
    AudioObjectPropertyAddress address = {
        .mSelector = SABR_TRANSPORT_PROPERTY,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    if (!AudioObjectHasProperty(deviceObjectID, &address)) {
        CFRelease(propertyList);
        return kAudioHardwareUnknownPropertyError;
    }
    const OSStatus result = AudioObjectSetPropertyData(
        deviceObjectID,
        &address,
        0,
        NULL,
        sizeof(propertyList),
        &propertyList
    );
    CFRelease(propertyList);
    if (result == noErr && transport->isLinked) {
        unlink(transport->configuration.backingFilePath);
        transport->isLinked = false;
    }
    if (result == noErr && transport->isNotificationLinked) {
        sem_unlink(transport->notificationName);
        transport->isNotificationLinked = false;
    }
    return result;
}

OSStatus sabr_client_set_presentation(
    AudioObjectID deviceObjectID,
    const char* displayName,
    Boolean visible
) {
    if (displayName == NULL || displayName[0] == '\0') {
        return kAudioHardwareIllegalOperationError;
    }
    CFStringRef name = CFStringCreateWithCString(
        kCFAllocatorDefault,
        displayName,
        kCFStringEncodingUTF8
    );
    if (name == NULL) { return kAudioHardwareIllegalOperationError; }
    if (CFStringGetLength(name) > SABR_TRANSPORT_MAX_DISPLAY_NAME_UTF16_LENGTH) {
        CFRelease(name);
        return kAudioHardwareIllegalOperationError;
    }
    CFMutableDictionaryRef command = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    if (command == NULL) {
        CFRelease(name);
        return kAudioHardwareUnspecifiedError;
    }
    CFDictionarySetValue(
        command,
        CFSTR(SABR_TRANSPORT_KEY_COMMAND),
        CFSTR(SABR_TRANSPORT_COMMAND_PRESENTATION)
    );
    CFDictionarySetValue(command, CFSTR(SABR_TRANSPORT_KEY_DISPLAY_NAME), name);
    CFDictionarySetValue(
        command,
        CFSTR(SABR_TRANSPORT_KEY_VISIBLE),
        visible ? kCFBooleanTrue : kCFBooleanFalse
    );
    if (!sabr_client_add_authorization(command)) {
        CFRelease(command);
        CFRelease(name);
        return kAudioHardwareUnspecifiedError;
    }
    CFPropertyListRef propertyList = command;
    AudioObjectPropertyAddress address = {
        .mSelector = SABR_TRANSPORT_PROPERTY,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    const OSStatus result = AudioObjectSetPropertyData(
        deviceObjectID,
        &address,
        0,
        NULL,
        sizeof(propertyList),
        &propertyList
    );
    CFRelease(command);
    CFRelease(name);
    return result;
}

CFArrayRef sabr_client_copy_profile_devices(AudioObjectID deviceObjectID) {
    AudioObjectPropertyAddress address = {
        SABR_TRANSPORT_PROPERTY, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    CFPropertyListRef capabilities = NULL;
    UInt32 size = sizeof(capabilities);
    CFArrayRef result = NULL;
    OSStatus status = AudioObjectGetPropertyData(deviceObjectID, &address, 0, NULL, &size, &capabilities);
    if (status == noErr && capabilities != NULL && CFGetTypeID(capabilities) == CFDictionaryGetTypeID()) {
        CFTypeRef profiles = CFDictionaryGetValue(capabilities, CFSTR(SABR_TRANSPORT_KEY_PROFILES));
        if (profiles != NULL && CFGetTypeID(profiles) == CFArrayGetTypeID()) { result = CFArrayCreateCopy(kCFAllocatorDefault, profiles); }
    }
    if (capabilities != NULL) { CFRelease(capabilities); }
    return result;
}

uint32_t sabr_client_profile_format_version(AudioObjectID deviceObjectID) {
    AudioObjectPropertyAddress address = {
        SABR_TRANSPORT_PROPERTY, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    CFPropertyListRef capabilities = NULL;
    UInt32 size = sizeof(capabilities), version = 0;
    OSStatus status = AudioObjectGetPropertyData(deviceObjectID, &address, 0, NULL, &size, &capabilities);
    if (status == noErr && capabilities != NULL && CFGetTypeID(capabilities) == CFDictionaryGetTypeID()) {
        (void)sabr_profile_uint32(capabilities, CFSTR(SABR_PROFILE_KEY_VERSION), &version);
    }
    if (capabilities != NULL) { CFRelease(capabilities); }
    return version;
}

OSStatus sabr_client_set_profile_devices_with_formats(AudioObjectID deviceObjectID, CFArrayRef profiles) {
    if (profiles == NULL || CFGetTypeID(profiles) != CFArrayGetTypeID() ||
        CFArrayGetCount(profiles) > SABR_TRANSPORT_MAX_PROFILE_DEVICES) { return kAudioHardwareIllegalOperationError; }
    for (CFIndex i = 0; i < CFArrayGetCount(profiles); ++i) {
        CFTypeRef value = CFArrayGetValueAtIndex(profiles, i);
        SABRProfileFormat format;
        if (value == NULL || CFGetTypeID(value) != CFDictionaryGetTypeID() ||
            !sabr_profile_format_parse(value, &format)) { return kAudioDeviceUnsupportedFormatError; }
    }
    if (sabr_client_profile_format_version(deviceObjectID) != SABR_PROFILE_FORMAT_VERSION ||
        !sabr_client_transport_is_supported(deviceObjectID) ||
        sabr_client_transport_channel_count(deviceObjectID) != SABR_TRANSPORT_MAX_CHANNELS) {
        return kAudioHardwareUnsupportedOperationError;
    }
    return sabr_client_set_profile_devices(deviceObjectID, profiles);
}

OSStatus sabr_client_set_profile_devices(
    AudioObjectID deviceObjectID,
    CFArrayRef profiles
) {
    if (profiles == NULL || CFGetTypeID(profiles) != CFArrayGetTypeID()) {
        return kAudioHardwareIllegalOperationError;
    }
    const CFIndex profileCount = CFArrayGetCount(profiles);
    if (profileCount < 0 || profileCount > SABR_TRANSPORT_MAX_PROFILE_DEVICES) {
        return kAudioHardwareIllegalOperationError;
    }
    for (CFIndex index = 0; index < profileCount; ++index) {
        CFTypeRef value = CFArrayGetValueAtIndex(profiles, index);
        if (value == NULL || CFGetTypeID(value) != CFDictionaryGetTypeID()) {
            return kAudioHardwareIllegalOperationError;
        }
        CFDictionaryRef profile = (CFDictionaryRef)value;
        CFTypeRef uid = CFDictionaryGetValue(profile, CFSTR(SABR_TRANSPORT_KEY_DEVICE_UID));
        CFTypeRef name = CFDictionaryGetValue(profile, CFSTR(SABR_TRANSPORT_KEY_DISPLAY_NAME));
        if (uid == NULL || CFGetTypeID(uid) != CFStringGetTypeID() ||
            CFStringGetLength((CFStringRef)uid) == 0 ||
            CFStringGetLength((CFStringRef)uid) > SABR_TRANSPORT_MAX_DEVICE_UID_UTF16_LENGTH ||
            name == NULL || CFGetTypeID(name) != CFStringGetTypeID() ||
            CFStringGetLength((CFStringRef)name) == 0 ||
            CFStringGetLength((CFStringRef)name) > SABR_TRANSPORT_MAX_DISPLAY_NAME_UTF16_LENGTH) {
            return kAudioHardwareIllegalOperationError;
        }
    }
    CFMutableDictionaryRef command = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    if (command == NULL) { return kAudioHardwareUnspecifiedError; }
    CFDictionarySetValue(
        command,
        CFSTR(SABR_TRANSPORT_KEY_COMMAND),
        CFSTR(SABR_TRANSPORT_COMMAND_PROFILE_DEVICES)
    );
    CFDictionarySetValue(command, CFSTR(SABR_TRANSPORT_KEY_PROFILES), profiles);
    if (!sabr_client_add_authorization(command)) {
        CFRelease(command);
        return kAudioHardwareUnspecifiedError;
    }
    CFPropertyListRef propertyList = command;
    AudioObjectPropertyAddress address = {
        .mSelector = SABR_TRANSPORT_PROPERTY,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    const OSStatus result = AudioObjectSetPropertyData(
        deviceObjectID,
        &address,
        0,
        NULL,
        sizeof(propertyList),
        &propertyList
    );
    CFRelease(command);
    return result;
}

OSStatus sabr_client_transport_disconnect(
    SABRClientTransportRef transport,
    AudioObjectID deviceObjectID
) {
    if (transport == NULL || deviceObjectID == kAudioObjectUnknown) {
        return kAudioHardwareIllegalOperationError;
    }
    /*
     * CFNull is not a valid binary property-list value. Core Audio's proxy
     * attempts to serialize custom CFPropertyList properties as CFData and
     * crashes in CFDataGetBytePtr when handed kCFNull. Use an explicit,
     * serializable command dictionary instead.
     */
    CFMutableDictionaryRef command = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    if (command == NULL) { return kAudioHardwareUnspecifiedError; }
    CFDictionarySetValue(
        command,
        CFSTR(SABR_TRANSPORT_KEY_COMMAND),
        CFSTR(SABR_TRANSPORT_COMMAND_DISCONNECT)
    );
    if (!sabr_client_add_authorization(command)) {
        CFRelease(command);
        return kAudioHardwareUnspecifiedError;
    }
    CFPropertyListRef propertyList = command;
    AudioObjectPropertyAddress address = {
        .mSelector = SABR_TRANSPORT_PROPERTY,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    const OSStatus result = AudioObjectSetPropertyData(
        deviceObjectID,
        &address,
        0,
        NULL,
        sizeof(propertyList),
        &propertyList
    );
    CFRelease(command);
    return result;
}

uint32_t sabr_client_transport_read(
    SABRClientTransportRef transport,
    Float32* interleavedDestination,
    uint32_t destinationChannelCapacity,
    uint32_t maximumFrames,
    uint32_t* activeChannels,
    double* sampleRate
) {
    if (activeChannels != NULL) { *activeChannels = 0; }
    if (sampleRate != NULL) { *sampleRate = 0; }
    SABRClientAudioPacketInfo packet;
    const uint32_t frames = sabr_client_transport_read_packet(
        transport,
        interleavedDestination,
        destinationChannelCapacity,
        maximumFrames,
        &packet
    );
    if (frames > 0 && activeChannels != NULL) { *activeChannels = packet.channelCount; }
    if (frames > 0 && sampleRate != NULL) { *sampleRate = packet.sampleRate; }
    return frames;
}

uint32_t sabr_client_transport_read_packet(
    SABRClientTransportRef transport,
    Float32* interleavedDestination,
    uint32_t destinationChannelCapacity,
    uint32_t maximumFrames,
    SABRClientAudioPacketInfo* packetInfo
) {
    if (packetInfo != NULL) { memset(packetInfo, 0, sizeof(*packetInfo)); }
    if (transport == NULL || interleavedDestination == NULL || packetInfo == NULL ||
        maximumFrames == 0) {
        return 0;
    }
    if (!sabr_client_header_is_valid(transport)) {
        sabr_record_malformed_packet(transport);
        return 0;
    }
    SABRTransportHeader* header = transport->header;
    const uint64_t readPacket = atomic_load_explicit(&header->readPacket, memory_order_relaxed);
    /* Load the frame frontier first. Every frame reservation belongs to a
     * packet reservation visible in the later writePacket snapshot. */
    const uint64_t observedWriteFrame = atomic_load_explicit(
        &header->writeFrame,
        memory_order_acquire
    );
    const uint64_t writePacket = atomic_load_explicit(&header->writePacket, memory_order_acquire);
    const uint64_t availablePackets = writePacket - readPacket;
    if (availablePackets == 0) {
        atomic_fetch_add_explicit(&header->starvationCount, 1, memory_order_relaxed);
        return 0;
    }
    if (availablePackets > header->packetCapacity) {
        atomic_fetch_add_explicit(&header->consumerOverrunCount, 1, memory_order_relaxed);
        sabr_record_malformed_packet(transport);
        atomic_store_explicit(&header->readFrame, observedWriteFrame, memory_order_release);
        atomic_store_explicit(&header->readPacket, writePacket, memory_order_release);
        return 0;
    }

    const uint64_t readFrame = atomic_load_explicit(&header->readFrame, memory_order_relaxed);
    SABRTransportPacket* source = NULL;
    SABRTransportPacket packet = {0};
    Boolean allObservedPacketsAreReady = true;
    Boolean sawReadyNonemptyPacket = false;
    Boolean sawInvalidReservationSequence = false;
    for (uint64_t offset = 0; offset < availablePackets; ++offset) {
        const uint64_t ticket = readPacket + offset;
        SABRTransportPacket* candidate =
            &transport->packets[ticket % header->packetCapacity];
        if (atomic_load_explicit(&candidate->committed, memory_order_acquire) !=
                SABR_PACKET_STATE_READY) {
            allObservedPacketsAreReady = false;
            continue;
        }
        if (candidate->reservationSequence != ticket) {
            sawInvalidReservationSequence = true;
            continue;
        }
        if (candidate->frameCount == 0) {
            /* A producer reserved a packet but found no frame capacity. */
            atomic_store_explicit(
                &candidate->committed,
                SABR_PACKET_STATE_CONSUMED,
                memory_order_release
            );
            continue;
        }
        sawReadyNonemptyPacket = true;
        if (candidate->startFrame != readFrame) { continue; }
        packet = (SABRTransportPacket) {
            .startFrame = candidate->startFrame,
            .cycleCounter = candidate->cycleCounter,
            .sampleTimeBits = candidate->sampleTimeBits,
            .sampleRateBits = candidate->sampleRateBits,
            .clientID = candidate->clientID,
            .processID = candidate->processID,
            .deviceObjectID = candidate->deviceObjectID,
            .frameCount = candidate->frameCount,
            .channelCount = candidate->channelCount,
            .channelLayoutTag = candidate->channelLayoutTag,
            .flags = candidate->flags,
            .reserved32 = candidate->reserved32,
            .reservationSequence = candidate->reservationSequence,
            .reservedCommit32 = candidate->reservedCommit32,
        };
        source = candidate;
        break;
    }
    sabr_reclaim_consumed_packets(transport, writePacket);
    if (source == NULL) {
        /* If every reservation in the snapshot is complete but none begins at
         * readFrame, the descriptor chain is corrupt rather than merely out of
         * producer order. Drop exactly that completed snapshot and resume at
         * its captured frame frontier; later reservations remain untouched. */
        if (sawInvalidReservationSequence ||
            (allObservedPacketsAreReady && sawReadyNonemptyPacket)) {
            sabr_record_malformed_packet(transport);
            for (uint64_t offset = 0; offset < availablePackets; ++offset) {
                const uint64_t ticket = readPacket + offset;
                SABRTransportPacket* candidate =
                    &transport->packets[ticket % header->packetCapacity];
                if (atomic_load_explicit(&candidate->committed, memory_order_acquire) ==
                    SABR_PACKET_STATE_READY) {
                    atomic_store_explicit(
                        &candidate->committed,
                        SABR_PACKET_STATE_CONSUMED,
                        memory_order_release
                    );
                }
            }
            atomic_store_explicit(
                &header->readFrame,
                observedWriteFrame,
                memory_order_release
            );
            atomic_store_explicit(&header->readPacket, writePacket, memory_order_release);
        }
        return 0;
    }
    if (!sabr_packet_is_supported(
            &packet,
            header,
            destinationChannelCapacity,
            maximumFrames)) {
        /* Reject the v4 descriptor without leaving the queue permanently wedged. */
        sabr_record_malformed_packet(transport);
        if (packet.frameCount <= header->frameCapacity) {
            atomic_store_explicit(
                &header->readFrame,
                packet.startFrame + packet.frameCount,
                memory_order_release
            );
        } else {
            atomic_fetch_add_explicit(&header->consumerOverrunCount, 1, memory_order_relaxed);
        }
        atomic_store_explicit(
            &source->committed,
            SABR_PACKET_STATE_CONSUMED,
            memory_order_release
        );
        sabr_reclaim_consumed_packets(transport, writePacket);
        return 0;
    }
    const uint32_t startFrame = (uint32_t)(packet.startFrame % header->frameCapacity);
    const uint32_t firstFrames = packet.frameCount < header->frameCapacity - startFrame
        ? packet.frameCount
        : header->frameCapacity - startFrame;
    const uint32_t secondFrames = packet.frameCount - firstFrames;
    if (packet.channelCount == header->channelCapacity) {
        memcpy(
            interleavedDestination,
            transport->samples + ((size_t)startFrame * header->channelCapacity),
            (size_t)firstFrames * packet.channelCount * sizeof(Float32)
        );
        if (secondFrames > 0) {
            memcpy(
                interleavedDestination + ((size_t)firstFrames * packet.channelCount),
                transport->samples,
                (size_t)secondFrames * packet.channelCount * sizeof(Float32)
            );
        }
    } else {
        for (uint32_t frame = 0; frame < packet.frameCount; ++frame) {
            const uint32_t sourceFrame =
                (uint32_t)((packet.startFrame + frame) % header->frameCapacity);
            memcpy(
                interleavedDestination + ((size_t)frame * packet.channelCount),
                transport->samples + ((size_t)sourceFrame * header->channelCapacity),
                (size_t)packet.channelCount * sizeof(Float32)
            );
        }
    }

    packetInfo->clientID = packet.clientID;
    packetInfo->processID = packet.processID;
    packetInfo->deviceObjectID = packet.deviceObjectID;
    packetInfo->cycleCounter = packet.cycleCounter;
    packetInfo->sampleTime = sabr_bits_to_double(packet.sampleTimeBits);
    packetInfo->frameCount = packet.frameCount;
    packetInfo->channelCount = packet.channelCount;
    packetInfo->channelLayoutTag = packet.channelLayoutTag;
    packetInfo->sampleRate = sabr_bits_to_double(packet.sampleRateBits);
    atomic_store_explicit(
        &header->readFrame,
        packet.startFrame + packet.frameCount,
        memory_order_release
    );
    atomic_store_explicit(
        &source->committed,
        SABR_PACKET_STATE_CONSUMED,
        memory_order_release
    );
    sabr_reclaim_consumed_packets(transport, writePacket);
    return packet.frameCount;
}

uint32_t sabr_client_transport_copy_clients(
    SABRClientTransportRef transport,
    SABRClientIdentity* destination,
    uint32_t destinationCapacity
) {
    if (transport == NULL || destination == NULL || destinationCapacity == 0) { return 0; }
    if (!sabr_client_header_is_valid(transport)) {
        sabr_record_malformed_packet(transport);
        return UINT32_MAX;
    }
    const uint64_t startingGeneration = atomic_load_explicit(
        &transport->header->clientGeneration,
        memory_order_acquire
    );
    if (startingGeneration == UINT64_MAX) { return UINT32_MAX; }
    uint32_t count = 0;
    for (uint32_t index = 0;
         index < transport->header->clientCapacity && count < destinationCapacity;
         ++index) {
        SABRTransportClient* source = &transport->clients[index];
        const uint32_t state = atomic_load_explicit(&source->state, memory_order_acquire);
        if (state == SABR_CLIENT_STATE_EMPTY) { continue; }
        const uint64_t slotGeneration = atomic_load_explicit(
            &source->generation,
            memory_order_acquire
        );
        destination[count].clientID = atomic_load_explicit(
            &source->clientID,
            memory_order_relaxed
        );
        destination[count].processID = atomic_load_explicit(
            &source->processID,
            memory_order_relaxed
        );
        destination[count].deviceObjectID = atomic_load_explicit(
            &source->deviceObjectID,
            memory_order_relaxed
        );
        destination[count].identityFlags = atomic_load_explicit(
            &source->identityFlags,
            memory_order_relaxed
        );
        destination[count].isActive = state == SABR_CLIENT_STATE_ACTIVE;
        destination[count].generation = slotGeneration;
        for (uint32_t byte = 0; byte < SABR_CLIENT_BUNDLE_ID_CAPACITY; ++byte) {
            destination[count].bundleID[byte] = (char)atomic_load_explicit(
                &source->bundleID[byte],
                memory_order_relaxed
            );
        }
        destination[count].bundleID[sizeof(destination[count].bundleID) - 1] = '\0';
        if (slotGeneration != atomic_load_explicit(&source->generation, memory_order_acquire) ||
            state != atomic_load_explicit(&source->state, memory_order_acquire)) {
            return UINT32_MAX;
        }
        count += 1;
    }
    const uint64_t endingGeneration = atomic_load_explicit(
        &transport->header->clientGeneration,
        memory_order_acquire
    );
    if (startingGeneration != endingGeneration || endingGeneration == UINT64_MAX) {
        return UINT32_MAX;
    }
    return count;
}

Boolean sabr_client_transport_copy_control_state(
    SABRClientTransportRef transport,
    SABRClientControlState* controlState
) {
    if (controlState == NULL) { return false; }
    memset(controlState, 0, sizeof(*controlState));
    controlState->deviceObjectID = kAudioObjectUnknown;
    controlState->linearGain = 1.0f;
    if (transport == NULL || !sabr_client_header_is_valid(transport)) { return false; }

    SABRTransportHeader* header = transport->header;
    // Latest-value lane: bracket the relaxed payload loads with acquire reads
    // of the generation. This is constant-time and independent of PCM ring
    // occupancy, unlike the full diagnostics snapshot.
    for (int attempt = 0; attempt < 8; ++attempt) {
        const uint64_t startingGeneration = atomic_load_explicit(
            &header->controlGeneration,
            memory_order_acquire
        );
        if ((startingGeneration & 1u) != 0) { continue; }
        const uint32_t deviceObjectID = atomic_load_explicit(
            &header->controlDeviceObjectID,
            memory_order_relaxed
        );
        const float linearGain = sabr_bits_to_float(atomic_load_explicit(
            &header->controlLinearGainBits,
            memory_order_relaxed
        ));
        const uint32_t muted = atomic_load_explicit(
            &header->controlMuted,
            memory_order_relaxed
        );
        const uint64_t endingGeneration = atomic_load_explicit(
            &header->controlGeneration,
            memory_order_acquire
        );
        if (startingGeneration != endingGeneration || (endingGeneration & 1u) != 0) {
            continue;
        }
        if (!isfinite(linearGain) || linearGain < 0.0f || linearGain > 1.0f) {
            return false;
        }
        controlState->generation = endingGeneration;
        controlState->deviceObjectID = deviceObjectID;
        controlState->linearGain = linearGain;
        controlState->muted = muted != 0;
        return true;
    }
    return false;
}

uint64_t sabr_client_transport_client_generation(SABRClientTransportRef transport) {
    if (transport == NULL || !sabr_client_header_is_valid(transport)) { return UINT64_MAX; }
    return atomic_load_explicit(
        &transport->header->clientGeneration,
        memory_order_acquire
    );
}

void sabr_client_transport_get_statistics(
    SABRClientTransportRef transport,
    SABRClientTransportStatistics* statistics
) {
    if (statistics == NULL) { return; }
    memset(statistics, 0, sizeof(*statistics));
    if (transport == NULL) { return; }
    statistics->malformedPacketCount = atomic_load_explicit(
        &transport->malformedPacketCount,
        memory_order_relaxed
    );
    if (!sabr_client_header_is_valid(transport)) {
        sabr_record_malformed_packet(transport);
        statistics->malformedPacketCount += 1;
        return;
    }
    SABRTransportHeader* header = transport->header;
    const uint64_t readFrame = atomic_load_explicit(&header->readFrame, memory_order_acquire);
    const uint64_t readPacket = atomic_load_explicit(&header->readPacket, memory_order_acquire);
    const uint64_t reservedWritePacket = atomic_load_explicit(
        &header->writePacket,
        memory_order_acquire
    );
    const uint64_t reservedPackets = reservedWritePacket - readPacket;
    uint64_t committedFrames = 0;
    uint64_t committedPackets = 0;
    if (reservedPackets <= header->packetCapacity) {
        for (uint64_t offset = 0; offset < reservedPackets; ++offset) {
            const uint64_t ticket = readPacket + offset;
            const SABRTransportPacket* packet =
                &transport->packets[ticket % header->packetCapacity];
            if (atomic_load_explicit(&packet->committed, memory_order_acquire) !=
                    SABR_PACKET_STATE_READY ||
                packet->reservationSequence != ticket) {
                continue;
            }
            committedPackets += 1;
            if (packet->frameCount <= header->frameCapacity - committedFrames) {
                committedFrames += packet->frameCount;
            } else {
                committedFrames = header->frameCapacity;
            }
        }
    }
    /* Public occupancy reports completed descriptors, not in-flight reservations. */
    statistics->writeFrame = readFrame + committedFrames;
    statistics->readFrame = readFrame;
    statistics->droppedFrames = atomic_load_explicit(&header->droppedFrames, memory_order_relaxed);
    statistics->consumerOverrunCount = atomic_load_explicit(
        &header->consumerOverrunCount,
        memory_order_relaxed
    );
    statistics->starvationCount = atomic_load_explicit(
        &header->starvationCount,
        memory_order_relaxed
    );
    statistics->sequence = atomic_load_explicit(&header->sequence, memory_order_relaxed);
    statistics->latestChannels = atomic_load_explicit(
        &header->latestChannels,
        memory_order_relaxed
    );
    statistics->latestChannelLayoutTag = atomic_load_explicit(
        &header->latestChannelLayoutTag,
        memory_order_relaxed
    );
    statistics->frameCapacity = header->frameCapacity;
    statistics->latestSampleRate = sabr_bits_to_double(
        atomic_load_explicit(&header->latestSampleRateBits, memory_order_relaxed)
    );
    statistics->writePacket = readPacket + committedPackets;
    statistics->readPacket = readPacket;
    statistics->droppedPackets = atomic_load_explicit(&header->droppedPackets, memory_order_relaxed);
    statistics->clientGeneration = atomic_load_explicit(
        &header->clientGeneration,
        memory_order_acquire
    );
    statistics->clientRegistryOverflowCount = atomic_load_explicit(
        &header->clientRegistryOverflowCount,
        memory_order_relaxed
    );
    statistics->clientUseCountSaturationCount = atomic_load_explicit(
        &header->clientUseCountSaturationCount,
        memory_order_relaxed
    );
    statistics->malformedPacketCount = atomic_load_explicit(
        &transport->malformedPacketCount,
        memory_order_relaxed
    );

    SABRClientControlState controlState = {0};
    if (sabr_client_transport_copy_control_state(transport, &controlState)) {
        statistics->controlGeneration = controlState.generation;
        statistics->controlDeviceObjectID = controlState.deviceObjectID;
        statistics->controlLinearGain = controlState.linearGain;
        statistics->controlMuted = controlState.muted ? 1u : 0u;
    }
}

void sabr_client_transport_destroy(SABRClientTransportRef transport) {
    if (transport == NULL) { return; }
    if (transport->mapping != NULL && transport->mappingBytes > 0) {
        munmap(transport->mapping, transport->mappingBytes);
    }
    if (transport->descriptor >= 0) { close(transport->descriptor); }
    if (transport->isLinked) { unlink(transport->configuration.backingFilePath); }
    if (transport->notification != SEM_FAILED) { sem_close(transport->notification); }
    if (transport->isNotificationLinked) { sem_unlink(transport->notificationName); }
    free(transport);
}

uint32_t sabr_client_transport_max_channels(void) {
    return SABR_TRANSPORT_MAX_CHANNELS;
}

uint32_t sabr_client_transport_channel_count(AudioObjectID deviceObjectID) {
    AudioObjectPropertyAddress address = {
        .mSelector = SABR_TRANSPORT_PROPERTY,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    CFPropertyListRef capability = NULL;
    UInt32 capabilitySize = sizeof(capability);
    const OSStatus status = AudioObjectGetPropertyData(
        deviceObjectID,
        &address,
        0,
        NULL,
        &capabilitySize,
        &capability
    );
    uint64_t channelCount = 0;
    const Boolean valid = status == noErr && capability != NULL &&
        CFGetTypeID(capability) == CFDictionaryGetTypeID() &&
        sabr_dictionary_get_uint64(
            (CFDictionaryRef)capability,
            CFSTR(SABR_TRANSPORT_KEY_CHANNEL_CAPACITY),
            &channelCount) &&
        channelCount > 0 && channelCount <= SABR_TRANSPORT_MAX_CHANNELS;
    if (capability != NULL) { CFRelease(capability); }
    return valid ? (uint32_t)channelCount : 0;
}

uint32_t sabr_client_transport_default_frame_capacity(void) {
    return SABR_TRANSPORT_DEFAULT_FRAME_CAPACITY;
}

uint32_t sabr_client_transport_max_clients(void) {
    return SABR_TRANSPORT_CLIENT_CAPACITY;
}

Boolean sabr_client_transport_is_supported(AudioObjectID deviceObjectID) {
    AudioObjectPropertyAddress address = {
        .mSelector = SABR_TRANSPORT_PROPERTY,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    if (!AudioObjectHasProperty(deviceObjectID, &address)) { return false; }
    Boolean settable = false;
    if (AudioObjectIsPropertySettable(deviceObjectID, &address, &settable) != noErr ||
        !settable) {
        return false;
    }

    CFPropertyListRef capability = NULL;
    UInt32 capabilitySize = sizeof(capability);
    const OSStatus status = AudioObjectGetPropertyData(
        deviceObjectID,
        &address,
        0,
        NULL,
        &capabilitySize,
        &capability
    );
    if (status != noErr || capability == NULL ||
        CFGetTypeID(capability) != CFDictionaryGetTypeID()) {
        if (capability != NULL) { CFRelease(capability); }
        return false;
    }
    uint64_t protocolVersion = 0;
    uint64_t abiVersion = 0;
    uint64_t channelCount = 0;
    const Boolean supported = sabr_dictionary_get_uint64(
            (CFDictionaryRef)capability,
            CFSTR(SABR_TRANSPORT_KEY_PROTOCOL_VERSION),
            &protocolVersion) &&
        sabr_dictionary_get_uint64(
            (CFDictionaryRef)capability,
            CFSTR(SABR_TRANSPORT_KEY_ABI_VERSION),
            &abiVersion) &&
        sabr_dictionary_get_uint64(
            (CFDictionaryRef)capability,
            CFSTR(SABR_TRANSPORT_KEY_CHANNEL_CAPACITY),
            &channelCount) &&
        protocolVersion == SABR_TRANSPORT_PROTOCOL_VERSION &&
        abiVersion == SABR_TRANSPORT_ABI_VERSION &&
        channelCount > 0 && channelCount <= SABR_TRANSPORT_MAX_CHANNELS;
    CFRelease(capability);
    return supported;
}

Boolean sabr_client_transport_wait_for_notification(SABRClientTransportRef transport) {
    if (transport == NULL || transport->notification == SEM_FAILED) { return false; }
    int result;
    do {
        result = sem_wait(transport->notification);
    } while (result != 0 && errno == EINTR);
    return result == 0;
}

void sabr_client_transport_signal(SABRClientTransportRef transport) {
    if (transport == NULL || transport->notification == SEM_FAILED) { return; }
    (void)sem_post(transport->notification);
}
