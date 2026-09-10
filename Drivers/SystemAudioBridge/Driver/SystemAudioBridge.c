/*
     File: SystemAudioBridge.c
  
 Copyright (C) 2019 Existential Audio Inc.
  
*/
/*==================================================================================================
	SystemAudioBridge.c
==================================================================================================*/

//==================================================================================================
//	Includes
//==================================================================================================

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdint.h>
#include <sys/syslog.h>
#include <Accelerate/Accelerate.h>
#include <Availability.h>
#include "SystemAudioBridgeDriverTransport.h"

//==================================================================================================
#pragma mark -
#pragma mark Macros
//==================================================================================================

#if TARGET_RT_BIG_ENDIAN
#define    FourCCToCString(the4CC)    { ((char*)&the4CC)[0], ((char*)&the4CC)[1], ((char*)&the4CC)[2], ((char*)&the4CC)[3], 0 }
#else
#define    FourCCToCString(the4CC)    { ((char*)&the4CC)[3], ((char*)&the4CC)[2], ((char*)&the4CC)[1], ((char*)&the4CC)[0], 0 }
#endif

#ifndef __MAC_12_0
#define kAudioObjectPropertyElementMain kAudioObjectPropertyElementMaster
#endif

#if DEBUG

    #define    DebugMsg(inFormat, ...)    syslog(LOG_NOTICE, inFormat, ## __VA_ARGS__)

    #define    FailIf(inCondition, inHandler, inMessage)                           \
    if(inCondition)                                                                \
    {                                                                              \
        DebugMsg(inMessage);                                                       \
        goto inHandler;                                                            \
    }

    #define    FailWithAction(inCondition, inAction, inHandler, inMessage)         \
    if(inCondition)                                                                \
    {                                                                              \
        DebugMsg(inMessage);                                                       \
        { inAction; }                                                              \
        goto inHandler;                                                            \
        }

#else

    #define    DebugMsg(inFormat, ...)

    #define    FailIf(inCondition, inHandler, inMessage)                           \
    if(inCondition)                                                                \
    {                                                                              \
    goto inHandler;                                                                \
    }

    #define    FailWithAction(inCondition, inAction, inHandler, inMessage)         \
    if(inCondition)                                                                \
    {                                                                              \
    { inAction; }                                                                  \
    goto inHandler;                                                                \
    }

#endif


//==================================================================================================
#pragma mark -
#pragma mark SystemAudioBridge State
//==================================================================================================

//    The driver has the following
//    qualities:
//    - a box
//    - a device
//        - supports 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000, 8000, 16000 sample rates


//        - provides a rate scalar of 1.0 via hard coding
//    - a single output stream
//        - supports a standard 2.0, 5.1, or 7.1 build of 32 bit float LPCM samples
//        - writes to ring buffer
//    - a single input stream
//        - supports 16 channels of 32 bit float LPCM samples
//        - reads from ring buffer
//    - controls
//        - master input volume
//        - master output volume
//        - master input mute
//        - master output mute


//    Declare the internal object ID numbers for all the objects this driver implements. Note that
//    because the driver has fixed set of objects that never grows or shrinks. If this were not the
//    case, the driver would need to have a means to dynamically allocate these IDs. It is important
//    to realize that a lot of the structure of this driver is vastly simpler when the IDs are all
//    known a priori. Comments in the code will try to identify some of these simplifications and
//    point out what a more complicated driver will need to do.
enum
{
    kObjectID_PlugIn                    = kAudioObjectPlugInObject,
    kObjectID_Box                       = 2,
    kObjectID_Device                    = 3,
    kObjectID_Stream_Input              = 4,
    kObjectID_Volume_Input_Master       = 5,
    kObjectID_Mute_Input_Master         = 6,
    kObjectID_Stream_Output             = 7,
    kObjectID_Volume_Output_Master      = 8,
    kObjectID_Mute_Output_Master        = 9,
    kObjectID_Pitch_Adjust              = 10,
    kObjectID_ClockSource               = 11,
    kObjectID_Device2                   = 12,
    kObjectID_ProfileDevice_First       = kObjectID_Device2,
    kObjectID_ProfileDevice_Last        = 43,
    kObjectID_ProfileStream_First       = 44,
    kObjectID_ProfileStream_Last        = 75,
    kObjectID_ProfileVolume_First       = 76,
    kObjectID_ProfileVolume_Last        = 107,
    kObjectID_ProfileMute_First         = 108,
    kObjectID_ProfileMute_Last          = 139,
};

#define kProfileDevice_Count 32
#define kDevice_ClockDomain 0x53414252U /* 'SABR' */

_Static_assert(
    kObjectID_ProfileDevice_Last - kObjectID_ProfileDevice_First + 1 == kProfileDevice_Count,
    "profile device ID range must match profile capacity"
);
_Static_assert(
    kObjectID_ProfileStream_Last - kObjectID_ProfileStream_First + 1 == kProfileDevice_Count,
    "profile stream ID range must match profile capacity"
);
_Static_assert(
    kObjectID_ProfileVolume_Last - kObjectID_ProfileVolume_First + 1 == kProfileDevice_Count,
    "profile volume ID range must match profile capacity"
);
_Static_assert(
    kObjectID_ProfileMute_Last - kObjectID_ProfileMute_First + 1 == kProfileDevice_Count,
    "profile mute ID range must match profile capacity"
);

enum
{
    ChangeAction_SetSampleRate          = 1,
    ChangeAction_EnablePitchControl     = 2,
    ChangeAction_DisablePitchControl    = 3,
};

enum ObjectType
{
    kObjectType_Stream,
    kObjectType_Control
};

struct ObjectInfo {
    AudioObjectID id;
    enum ObjectType type;
    AudioObjectPropertyScope scope;
};

//    The main transport device and each published profile device have stable object IDs. Profile
//    devices own distinct stream/control objects and keep independent IO state. They intentionally
//    share one sample-rate clock domain because they are endpoints of the same bridge engine.


#ifndef kDriver_Name
#define                             kDriver_Name                        "System Audio Bridge"
#endif

#ifndef kPlugIn_BundleID
#define                             kPlugIn_BundleID                    "local.camillaaudio.driver"
#endif

#ifndef kPlugIn_Icon
#define                             kPlugIn_Icon                        "AppIcon.icns"
#endif

#ifndef kHas_Driver_Name_Format
#define                             kHas_Driver_Name_Format             false
#endif

#if kHas_Driver_Name_Format
#define                             kDriver_Name_Format                 "%ich"
#define                             kBox_UID                            kDriver_Name kDriver_Name_Format "_UID"
#define                             kDevice_UID                         kDriver_Name kDriver_Name_Format "_UID"
#define                             kDevice2_UID                        kDriver_Name kDriver_Name_Format "_2_UID"
#define                             kDevice_ModelUID                    kDriver_Name kDriver_Name_Format "_ModelUID"


#ifndef kDevice_Name
#define                             kDevice_Name                        kDriver_Name " %ich"
#endif

#ifndef kDevice2_Name
#define                             kDevice2_Name                       kDriver_Name " %ich 2"
#endif


#else
#define                             kBox_UID                            "local.systemaudiobridge.box"
#define                             kDevice_UID                         "local.systemaudiobridge.device"
#define                             kDevice2_UID                        "local.systemaudiobridge.device.mirror"
#define                             kDevice_ModelUID                    "local.systemaudiobridge.model"


#ifndef kDevice_Name
#define                             kDevice_Name                        kDriver_Name
#endif

#ifndef kDevice2_Name
#define                             kDevice2_Name                       kDriver_Name " Mirror"
#endif

#endif

#ifndef kDevice_IsHidden
#define                             kDevice_IsHidden                    false
#endif

#ifndef kDevice2_IsHidden
#define                             kDevice2_IsHidden                   true
#endif



#ifndef kDevice_HasInput
#define                             kDevice_HasInput                    false
#endif

#ifndef kDevice_HasOutput
#define                             kDevice_HasOutput                   true
#endif

// A profile endpoint intentionally exposes the same app-facing output scope as
// the main bridge. Its role is selected by the transport mapping, not by
// reversing these direction flags.
#ifndef kDevice2_HasInput
#define                             kDevice2_HasInput                   false
#endif

#ifndef kDevice2_HasOutput
#define                             kDevice2_HasOutput                  true
#endif



#ifndef kManufacturer_Name
#define                             kManufacturer_Name                  "System Audio Bridge contributors"
#endif

#ifndef kLatency_Frame_Size
#define                             kLatency_Frame_Size                 0
#endif

#ifndef kNumber_Of_Channels
#define                             kNumber_Of_Channels                 2
#endif

#ifndef kEnableVolumeControl
#define                             kEnableVolumeControl                 true
#endif

#ifndef kCanBeDefaultDevice
#define                             kCanBeDefaultDevice                 true
#endif

#ifndef kCanBeDefaultSystemDevice
#define                             kCanBeDefaultSystemDevice           true
#endif

static pthread_mutex_t              gPlugIn_StateMutex                  = PTHREAD_MUTEX_INITIALIZER;
static UInt32                       gPlugIn_RefCount                    = 0;
static AudioServerPlugInHostRef     gPlugIn_Host                        = NULL;


static CFStringRef                  gBox_Name                           = NULL;

#define kBoxAcquiredStorageKey CFSTR("box acquired")
#define kBoxNameStorageKey CFSTR("box name")

#ifndef kBox_Aquired
#define                             kBox_Aquired                 	true
#endif
static Boolean                      gBox_Acquired                       = kBox_Aquired;


static CFStringRef                  gDevice_DisplayName                 = NULL;
static Boolean                      gDevice_IsHidden                    = kDevice_IsHidden;
static CFStringRef                  gProfileDevice_UIDs[kProfileDevice_Count] = { NULL };
static CFStringRef                  gProfileDevice_AssignedUIDs[kProfileDevice_Count] = { NULL };
static CFStringRef                  gProfileDevice_Names[kProfileDevice_Count] = { NULL };
/*
 * Profile object IDs are validated from the HAL real-time callbacks. Never
 * take gPlugIn_StateMutex from those callbacks. The backing IO-state array has
 * static lifetime, and profile liveness plus volume/mute controls are atomic so
 * media-key traffic cannot priority-invert the audio thread.
 */
static _Atomic bool                 gProfileDevice_IsLive[kProfileDevice_Count] = { false };
static Float64                      gDevice_SampleRate                  = 48000.0;
static const UInt32                 kDevice_RingBufferSize              = 16384;
static Float64                      gDevice_HostTicksPerFrame           = 0.0;
static Float64                      gDevice_AdjustedTicksPerFrame       = 0.0;

static bool                         gStream_Input_IsActive              = true;

static const Float32                kVolume_MinDB                       = -96.0;
static const Float32                kVolume_MaxDB                       = 0.0;
static _Atomic Float32              gVolume_Master_Value                = 1.0f;
static Float32                      gPitch_Adjust                       = 0.5;
static _Atomic bool                 gMute_Master_Value                  = false;
static UInt32                       kClockSource_NumberItems            = 2;
#define                             kClockSource_InternalFixed         "Internal Fixed"
#define                             kClockSource_InternalAdjustable    "Internal Adjustable"
static UInt32                       gClockSource_Value                  = 0;
static bool                         gPitch_Adjust_Enabled               = false;
static _Atomic UInt64               gTimingSampleRateBits               = 0;
static _Atomic UInt64               gTimingEffectiveTicksPerFrameBits   = 0;

#if DEBUG
static _Atomic bool                 gDebugOverloadPending                = false;
static dispatch_source_t            gDebugOverloadReporter               = NULL;
#endif

static struct ObjectInfo            kDevice_ObjectList[]                = {
#if kDevice_HasInput
    { kObjectID_Stream_Input,           kObjectType_Stream,     kAudioObjectPropertyScopeInput  },
    { kObjectID_Volume_Input_Master,    kObjectType_Control,    kAudioObjectPropertyScopeInput  },
    { kObjectID_Mute_Input_Master,      kObjectType_Control,    kAudioObjectPropertyScopeInput  },
#endif
#if kDevice_HasOutput
    { kObjectID_Stream_Output,          kObjectType_Stream,     kAudioObjectPropertyScopeOutput },
    { kObjectID_Volume_Output_Master,   kObjectType_Control,    kAudioObjectPropertyScopeOutput },
    { kObjectID_Mute_Output_Master,     kObjectType_Control,    kAudioObjectPropertyScopeOutput },
    { kObjectID_Pitch_Adjust,           kObjectType_Control,    kAudioObjectPropertyScopeOutput },
#endif
    { kObjectID_ClockSource,            kObjectType_Control,    kAudioObjectPropertyScopeGlobal }
};

static const UInt32                 kDevice_ObjectListSize              = sizeof(kDevice_ObjectList) / sizeof(struct ObjectInfo);

#ifndef kSampleRates
#define                             kSampleRates       8000, 16000, 24000, 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000
#endif

static Float64                      kDevice_SampleRates[]               = { kSampleRates };

static const UInt32                 kDevice_SampleRatesSize             = sizeof(kDevice_SampleRates) / sizeof(Float64);



#define                             kBits_Per_Channel                   32
#define                             kBytes_Per_Channel                  (kBits_Per_Channel/ 8)
#define                             kBytes_Per_Frame                    (kNumber_Of_Channels * kBytes_Per_Channel)
#define                             kRing_Buffer_Frame_Size             ((65536 + kLatency_Frame_Size))

struct DeviceIOState {
    pthread_mutex_t ioMutex;
    UInt64 runningCount;
    Float64 requestedSampleRate;
    Float64 previousTicks;
    UInt64 numberTimeStamps;
    UInt64 anchorHostTime;
#if kDevice_HasInput
    Float32* ringBuffer;
    Float64 lastOutputSampleTime;
    Float64 lastMixOutputSampleTime;
    Boolean isBufferClear;
#endif
    bool outputStreamIsActive;
    _Atomic Float32 volume;
    _Atomic bool mute;
};

/* Called with gPlugIn_StateMutex held; real-time readers load one atomic value. */
static void publish_timing_snapshot(void)
{
    atomic_store_explicit(
        &gTimingSampleRateBits,
        sabr_double_to_bits(gDevice_SampleRate),
        memory_order_release
    );
    atomic_store_explicit(
        &gTimingEffectiveTicksPerFrameBits,
        sabr_double_to_bits(
            gClockSource_Value > 0
                ? gDevice_AdjustedTicksPerFrame
                : gDevice_HostTicksPerFrame
        ),
        memory_order_release
    );
}

static Float64 copy_timing_sample_rate(void)
{
    return sabr_bits_to_double(atomic_load_explicit(
        &gTimingSampleRateBits,
        memory_order_acquire
    ));
}

static Float64 copy_timing_effective_ticks_per_frame(void)
{
    return sabr_bits_to_double(atomic_load_explicit(
        &gTimingEffectiveTicksPerFrameBits,
        memory_order_acquire
    ));
}

#if DEBUG
static void start_debug_overload_reporter(void)
{
    if(gDebugOverloadReporter != NULL) { return; }
    dispatch_source_t reporter = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER,
        0,
        0,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)
    );
    if(reporter == NULL) { return; }
    gDebugOverloadReporter = reporter;
    dispatch_source_set_timer(
        reporter,
        dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
        NSEC_PER_SEC,
        NSEC_PER_MSEC * 100
    );
    dispatch_source_set_event_handler(reporter, ^{
        if(atomic_exchange_explicit(
            &gDebugOverloadPending,
            false,
            memory_order_acq_rel
        ))
        {
            DebugMsg("SystemAudioBridge overload: MixOutput missed an audio deadline. Try increasing the buffer frame size.");
        }
    });
    dispatch_resume(reporter);
}
#endif

static struct DeviceIOState gMainDeviceIOState = {
    .ioMutex = PTHREAD_MUTEX_INITIALIZER,
#if kDevice_HasInput
    .lastMixOutputSampleTime = -1.0,
    .isBufferClear = true,
#endif
    .outputStreamIsActive = true,
    .volume = 1.0f,
};
static struct DeviceIOState gProfileDeviceIOStates[kProfileDevice_Count];
static bool gProfileDeviceIOStatesInitialized = false;


//==================================================================================================
#pragma mark -
#pragma mark AudioServerPlugInDriverInterface Implementation
//==================================================================================================

#pragma mark Prototypes

//    Entry points for the COM methods
void*                SystemAudioBridge_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
static HRESULT        SystemAudioBridge_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG        SystemAudioBridge_AddRef(void* inDriver);
static ULONG        SystemAudioBridge_Release(void* inDriver);
static OSStatus        SystemAudioBridge_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus        SystemAudioBridge_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus        SystemAudioBridge_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus        SystemAudioBridge_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus        SystemAudioBridge_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus        SystemAudioBridge_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus        SystemAudioBridge_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean        SystemAudioBridge_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus        SystemAudioBridge_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus        SystemAudioBridge_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus        SystemAudioBridge_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus        SystemAudioBridge_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus        SystemAudioBridge_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus        SystemAudioBridge_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus        SystemAudioBridge_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus        SystemAudioBridge_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus        SystemAudioBridge_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus        SystemAudioBridge_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus        SystemAudioBridge_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

//    Implementation
static Boolean        SystemAudioBridge_HasPlugInProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus        SystemAudioBridge_IsPlugInPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus        SystemAudioBridge_GetPlugInPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus        SystemAudioBridge_GetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus        SystemAudioBridge_SetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean        SystemAudioBridge_HasBoxProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus        SystemAudioBridge_IsBoxPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus        SystemAudioBridge_GetBoxPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus        SystemAudioBridge_GetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus        SystemAudioBridge_SetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean        SystemAudioBridge_HasDeviceProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus        SystemAudioBridge_IsDevicePropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus        SystemAudioBridge_GetDevicePropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus        SystemAudioBridge_GetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus        SystemAudioBridge_SetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean        SystemAudioBridge_HasStreamProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus        SystemAudioBridge_IsStreamPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus        SystemAudioBridge_GetStreamPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus        SystemAudioBridge_GetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus        SystemAudioBridge_SetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean        SystemAudioBridge_HasControlProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus        SystemAudioBridge_IsControlPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus        SystemAudioBridge_GetControlPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus        SystemAudioBridge_GetControlPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus        SystemAudioBridge_SetControlPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

#pragma mark The Interface

static AudioServerPlugInDriverInterface    gAudioServerPlugInDriverInterface =
{
    NULL,
    SystemAudioBridge_QueryInterface,
    SystemAudioBridge_AddRef,
    SystemAudioBridge_Release,
    SystemAudioBridge_Initialize,
    SystemAudioBridge_CreateDevice,
    SystemAudioBridge_DestroyDevice,
    SystemAudioBridge_AddDeviceClient,
    SystemAudioBridge_RemoveDeviceClient,
    SystemAudioBridge_PerformDeviceConfigurationChange,
    SystemAudioBridge_AbortDeviceConfigurationChange,
    SystemAudioBridge_HasProperty,
    SystemAudioBridge_IsPropertySettable,
    SystemAudioBridge_GetPropertyDataSize,
    SystemAudioBridge_GetPropertyData,
    SystemAudioBridge_SetPropertyData,
    SystemAudioBridge_StartIO,
    SystemAudioBridge_StopIO,
    SystemAudioBridge_GetZeroTimeStamp,
    SystemAudioBridge_WillDoIOOperation,
    SystemAudioBridge_BeginIOOperation,
    SystemAudioBridge_DoIOOperation,
    SystemAudioBridge_EndIOOperation
};
static AudioServerPlugInDriverInterface*    gAudioServerPlugInDriverInterfacePtr    = &gAudioServerPlugInDriverInterface;
static AudioServerPlugInDriverRef            gAudioServerPlugInDriverRef                = &gAudioServerPlugInDriverInterfacePtr;


#if kHas_Driver_Name_Format
#define RETURN_FORMATTED_STRING(_string_fmt) \
	return CFStringCreateWithFormat(NULL, NULL, CFSTR(_string_fmt), kNumber_Of_Channels);
#else
#define RETURN_FORMATTED_STRING(_string_fmt) \
	return CFStringCreateWithCString(NULL, _string_fmt, kCFStringEncodingUTF8);
#endif

static CFStringRef get_box_uid(void)          { RETURN_FORMATTED_STRING(kBox_UID) }
static CFStringRef get_device_uid(void)       { RETURN_FORMATTED_STRING(kDevice_UID) }
static CFStringRef get_device_name(void)
{
    CFStringRef name = NULL;
    pthread_mutex_lock(&gPlugIn_StateMutex);
    if(gDevice_DisplayName != NULL)
    {
        name = gDevice_DisplayName;
        CFRetain(name);
    }
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    if(name == NULL)
    {
        RETURN_FORMATTED_STRING(kDevice_Name)
    }
    return name;
}
static CFStringRef get_device_model_uid(void) { RETURN_FORMATTED_STRING(kDevice_ModelUID) }

static bool is_profile_device_id(AudioObjectID objectID)
{
    return objectID >= kObjectID_ProfileDevice_First &&
        objectID <= kObjectID_ProfileDevice_Last;
}

static bool is_profile_stream_id(AudioObjectID objectID)
{
    return objectID >= kObjectID_ProfileStream_First &&
        objectID <= kObjectID_ProfileStream_Last;
}

static bool is_profile_volume_id(AudioObjectID objectID)
{
    return objectID >= kObjectID_ProfileVolume_First &&
        objectID <= kObjectID_ProfileVolume_Last;
}

static bool is_profile_mute_id(AudioObjectID objectID)
{
    return objectID >= kObjectID_ProfileMute_First &&
        objectID <= kObjectID_ProfileMute_Last;
}

static UInt32 profile_device_index(AudioObjectID objectID)
{
    return (UInt32)(objectID - kObjectID_ProfileDevice_First);
}

static AudioObjectID profile_device_id(UInt32 index)
{
    return kObjectID_ProfileDevice_First + index;
}

static AudioObjectID profile_stream_id(UInt32 index)
{
    return kObjectID_ProfileStream_First + index;
}

static AudioObjectID profile_volume_id(UInt32 index)
{
    return kObjectID_ProfileVolume_First + index;
}

static AudioObjectID profile_mute_id(UInt32 index)
{
    return kObjectID_ProfileMute_First + index;
}

static UInt32 profile_child_index(AudioObjectID objectID)
{
    if(is_profile_stream_id(objectID)) { return (UInt32)(objectID - kObjectID_ProfileStream_First); }
    if(is_profile_volume_id(objectID)) { return (UInt32)(objectID - kObjectID_ProfileVolume_First); }
    return (UInt32)(objectID - kObjectID_ProfileMute_First);
}

static bool profile_slot_is_live(UInt32 index)
{
    if(index >= kProfileDevice_Count) { return false; }
    return atomic_load_explicit(
        &gProfileDevice_IsLive[index],
        memory_order_acquire
    );
}

static bool is_profile_device_object(AudioObjectID objectID)
{
    return is_profile_device_id(objectID) &&
        profile_slot_is_live(profile_device_index(objectID));
}

static bool is_profile_stream_object(AudioObjectID objectID)
{
    return is_profile_stream_id(objectID) && profile_slot_is_live(profile_child_index(objectID));
}

static bool is_profile_control_object(AudioObjectID objectID)
{
    return (is_profile_volume_id(objectID) || is_profile_mute_id(objectID)) &&
        profile_slot_is_live(profile_child_index(objectID));
}

static bool is_device_object(AudioObjectID objectID)
{
    return objectID == kObjectID_Device || is_profile_device_object(objectID);
}

static bool is_stream_object(AudioObjectID objectID)
{
    return objectID == kObjectID_Stream_Input ||
        objectID == kObjectID_Stream_Output ||
        is_profile_stream_object(objectID);
}

static bool is_control_object(AudioObjectID objectID)
{
    return objectID == kObjectID_Volume_Input_Master ||
        objectID == kObjectID_Volume_Output_Master ||
        objectID == kObjectID_Mute_Input_Master ||
        objectID == kObjectID_Mute_Output_Master ||
        objectID == kObjectID_Pitch_Adjust ||
        objectID == kObjectID_ClockSource ||
        is_profile_control_object(objectID);
}

static AudioObjectID profile_owner_device(AudioObjectID childObjectID)
{
    return profile_device_id(profile_child_index(childObjectID));
}

static AudioObjectID stream_owner_device(AudioObjectID streamObjectID)
{
    return is_profile_stream_id(streamObjectID)
        ? profile_owner_device(streamObjectID)
        : kObjectID_Device;
}

static AudioObjectID control_owner_device(AudioObjectID controlObjectID)
{
    return (is_profile_volume_id(controlObjectID) || is_profile_mute_id(controlObjectID))
        ? profile_owner_device(controlObjectID)
        : kObjectID_Device;
}

static AudioObjectID canonical_control_id(AudioObjectID controlObjectID)
{
    if(is_profile_volume_id(controlObjectID)) { return kObjectID_Volume_Output_Master; }
    if(is_profile_mute_id(controlObjectID)) { return kObjectID_Mute_Output_Master; }
    return controlObjectID;
}

static struct DeviceIOState* device_io_state(AudioObjectID deviceObjectID)
{
    if(deviceObjectID == kObjectID_Device) { return &gMainDeviceIOState; }
    if(!is_profile_device_id(deviceObjectID)) { return NULL; }
    return &gProfileDeviceIOStates[profile_device_index(deviceObjectID)];
}

static struct DeviceIOState* control_io_state(AudioObjectID controlObjectID)
{
    return device_io_state(control_owner_device(controlObjectID));
}

/* Requires gPlugIn_StateMutex. */
static UInt32 profile_device_count_locked(void)
{
    UInt32 count = 0;
    for(UInt32 index = 0; index < kProfileDevice_Count; ++index)
    {
        if(gProfileDevice_UIDs[index] != NULL) { ++count; }
    }
    return count;
}

static UInt32 profile_device_count(void)
{
    pthread_mutex_lock(&gPlugIn_StateMutex);
    const UInt32 count = profile_device_count_locked();
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return count;
}

/* Requires gPlugIn_StateMutex and snapshots acquisition plus profile membership together. */
static UInt32 published_device_count_locked(void)
{
    return gBox_Acquired ? 1 + profile_device_count_locked() : 0;
}

/* Requires gPlugIn_StateMutex. Returns the exact number of IDs written. */
static UInt32 copy_published_devices_locked(AudioObjectID* destination, UInt32 capacity)
{
    UInt32 written = 0;
    if(destination == NULL || capacity == 0 || !gBox_Acquired) { return 0; }
    destination[written++] = kObjectID_Device;
    for(UInt32 slot = 0; slot < kProfileDevice_Count && written < capacity; ++slot)
    {
        if(gProfileDevice_UIDs[slot] != NULL)
        {
            destination[written++] = profile_device_id(slot);
        }
    }
    return written;
}

static CFStringRef copy_profile_device_uid(AudioObjectID objectID)
{
    CFStringRef result = NULL;
    if(!is_profile_device_id(objectID)) { return NULL; }
    pthread_mutex_lock(&gPlugIn_StateMutex);
    result = gProfileDevice_UIDs[profile_device_index(objectID)];
    if(result != NULL) { CFRetain(result); }
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return result;
}

static CFStringRef copy_profile_device_name(AudioObjectID objectID)
{
    CFStringRef result = NULL;
    if(!is_profile_device_id(objectID)) { return NULL; }
    pthread_mutex_lock(&gPlugIn_StateMutex);
    result = gProfileDevice_Names[profile_device_index(objectID)];
    if(result != NULL) { CFRetain(result); }
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return result;
}

static void notify_profile_devices(
    UInt32 addressCount,
    const AudioObjectPropertyAddress* addresses
)
{
    if(gPlugIn_Host == NULL || addressCount == 0 || addresses == NULL) { return; }
    AudioObjectID deviceIDs[kProfileDevice_Count];
    UInt32 deviceCount = 0;
    pthread_mutex_lock(&gPlugIn_StateMutex);
    for(UInt32 slot = 0; slot < kProfileDevice_Count; ++slot)
    {
        if(gProfileDevice_UIDs[slot] != NULL)
        {
            deviceIDs[deviceCount++] = kObjectID_ProfileDevice_First + slot;
        }
    }
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    for(UInt32 index = 0; index < deviceCount; ++index)
    {
        gPlugIn_Host->PropertiesChanged(
            gPlugIn_Host,
            deviceIDs[index],
            addressCount,
            addresses
        );
    }
}

static OSStatus set_profile_devices(CFArrayRef profiles)
{
    if(profiles == NULL || CFGetTypeID(profiles) != CFArrayGetTypeID())
    {
        return kAudioHardwareIllegalOperationError;
    }

    CFIndex count = CFArrayGetCount(profiles);
    if(count < 0 || count > kProfileDevice_Count) { return kAudioHardwareIllegalOperationError; }

    CFStringRef requestedUIDs[kProfileDevice_Count] = { NULL };
    CFStringRef requestedNames[kProfileDevice_Count] = { NULL };
    CFStringRef previousUIDs[kProfileDevice_Count] = { NULL };
    CFStringRef previousNames[kProfileDevice_Count] = { NULL };
    SInt32 requestedSlots[kProfileDevice_Count];
    bool assignedSlots[kProfileDevice_Count] = { false };
    bool addedSlots[kProfileDevice_Count] = { false };
    bool removedSlots[kProfileDevice_Count] = { false };
    bool changedNames[kProfileDevice_Count] = { false };
    bool deviceListChanged = false;
    OSStatus result = noErr;

    for(UInt32 index = 0; index < kProfileDevice_Count; ++index)
    {
        requestedSlots[index] = -1;
    }

    for(CFIndex index = 0; index < count; ++index)
    {
        CFTypeRef value = CFArrayGetValueAtIndex(profiles, index);
        if(value == NULL || CFGetTypeID(value) != CFDictionaryGetTypeID())
        {
            result = kAudioHardwareIllegalOperationError;
            goto Cleanup;
        }
        CFDictionaryRef profile = (CFDictionaryRef)value;
        CFTypeRef uid = CFDictionaryGetValue(profile, CFSTR(SABR_TRANSPORT_KEY_DEVICE_UID));
        CFTypeRef name = CFDictionaryGetValue(profile, CFSTR(SABR_TRANSPORT_KEY_DISPLAY_NAME));
        if(uid == NULL || CFGetTypeID(uid) != CFStringGetTypeID() ||
            CFStringGetLength((CFStringRef)uid) == 0 ||
            CFStringGetLength((CFStringRef)uid) > SABR_TRANSPORT_MAX_DEVICE_UID_UTF16_LENGTH ||
            name == NULL || CFGetTypeID(name) != CFStringGetTypeID() ||
            CFStringGetLength((CFStringRef)name) == 0 ||
            CFStringGetLength((CFStringRef)name) > SABR_TRANSPORT_MAX_DISPLAY_NAME_UTF16_LENGTH)
        {
            result = kAudioHardwareIllegalOperationError;
            goto Cleanup;
        }
        for(CFIndex prior = 0; prior < index; ++prior)
        {
            if(CFStringCompare(requestedUIDs[prior], (CFStringRef)uid, 0) == kCFCompareEqualTo)
            {
                result = kAudioHardwareIllegalOperationError;
                goto Cleanup;
            }
        }
        requestedUIDs[index] = CFStringCreateCopy(kCFAllocatorDefault, (CFStringRef)uid);
        requestedNames[index] = CFStringCreateCopy(kCFAllocatorDefault, (CFStringRef)name);
        if(requestedUIDs[index] == NULL || requestedNames[index] == NULL)
        {
            result = kAudioHardwareUnspecifiedError;
            goto Cleanup;
        }
    }

    pthread_mutex_lock(&gPlugIn_StateMutex);
    for(CFIndex index = 0; index < count; ++index)
    {
        SInt32 slot = -1;
        for(UInt32 candidate = 0; candidate < kProfileDevice_Count; ++candidate)
        {
            if(!assignedSlots[candidate] && gProfileDevice_AssignedUIDs[candidate] != NULL &&
                CFStringCompare(gProfileDevice_AssignedUIDs[candidate], requestedUIDs[index], 0) == kCFCompareEqualTo)
            {
                slot = (SInt32)candidate;
                break;
            }
        }
        if(slot < 0)
        {
            for(UInt32 candidate = 0; candidate < kProfileDevice_Count; ++candidate)
            {
                if(!assignedSlots[candidate] && gProfileDevice_AssignedUIDs[candidate] == NULL)
                {
                    slot = (SInt32)candidate;
                    break;
                }
            }
        }
        if(slot < 0)
        {
            result = kAudioHardwareIllegalOperationError;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            goto Cleanup;
        }
        assignedSlots[slot] = true;
        requestedSlots[index] = slot;
    }

    for(UInt32 slot = 0; slot < kProfileDevice_Count; ++slot)
    {
        if(!assignedSlots[slot] && gProfileDevice_UIDs[slot] != NULL &&
            gProfileDeviceIOStates[slot].runningCount > 0)
        {
            result = kAudioHardwareIllegalOperationError;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            goto Cleanup;
        }
    }

    for(UInt32 slot = 0; slot < kProfileDevice_Count; ++slot)
    {
        previousUIDs[slot] = gProfileDevice_UIDs[slot];
        previousNames[slot] = gProfileDevice_Names[slot];
        removedSlots[slot] = previousUIDs[slot] != NULL && !assignedSlots[slot];
        if(removedSlots[slot])
        {
            // Publish death before releasing the CF objects. Removed slots are
            // guaranteed not to have running IO by the check above.
            atomic_store_explicit(
                &gProfileDevice_IsLive[slot],
                false,
                memory_order_release
            );
        }
        gProfileDevice_UIDs[slot] = NULL;
        gProfileDevice_Names[slot] = NULL;
    }

    for(CFIndex index = 0; index < count; ++index)
    {
        UInt32 slot = (UInt32)requestedSlots[index];
        if(gProfileDevice_AssignedUIDs[slot] == NULL)
        {
            gProfileDevice_AssignedUIDs[slot] = requestedUIDs[index];
            requestedUIDs[index] = NULL;
        }
        gProfileDevice_UIDs[slot] = gProfileDevice_AssignedUIDs[slot];
        CFRetain(gProfileDevice_UIDs[slot]);
        gProfileDevice_Names[slot] = requestedNames[index];
        requestedNames[index] = NULL;
        addedSlots[slot] = previousUIDs[slot] == NULL;
        if(addedSlots[slot])
        {
            // All profile metadata and persistent IO state are ready before a
            // real-time callback can accept this object ID.
            atomic_store_explicit(
                &gProfileDevice_IsLive[slot],
                true,
                memory_order_release
            );
        }
        if(previousNames[slot] != NULL)
        {
            changedNames[slot] = CFStringCompare(
                previousNames[slot],
                gProfileDevice_Names[slot],
                0
            ) != kCFCompareEqualTo;
        }
        deviceListChanged = deviceListChanged || addedSlots[slot];
    }
    for(UInt32 slot = 0; slot < kProfileDevice_Count; ++slot)
    {
        deviceListChanged = deviceListChanged || removedSlots[slot];
    }
    pthread_mutex_unlock(&gPlugIn_StateMutex);

    if(gPlugIn_Host != NULL)
    {
        AudioObjectPropertyAddress nameAddress = {
            kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
        };
        if(deviceListChanged)
        {
            // The plug-in device list is the creation/destruction boundary. Never
            // notify a new object before HAL discovers it or a dead object after removal.
            AudioObjectPropertyAddress plugInAddresses[] = {
                { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                { kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
            };
            gPlugIn_Host->PropertiesChanged(
                gPlugIn_Host,
                kObjectID_PlugIn,
                sizeof(plugInAddresses) / sizeof(plugInAddresses[0]),
                plugInAddresses
            );
            AudioObjectPropertyAddress boxDeviceListAddress = {
                kAudioBoxPropertyDeviceList,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Box, 1, &boxDeviceListAddress);

            AudioObjectPropertyAddress relatedAddress = {
                kAudioDevicePropertyRelatedDevices,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 1, &relatedAddress);
            notify_profile_devices(1, &relatedAddress);
        }
        for(UInt32 slot = 0; slot < kProfileDevice_Count; ++slot)
        {
            if(assignedSlots[slot] && !addedSlots[slot] && changedNames[slot])
            {
                gPlugIn_Host->PropertiesChanged(
                    gPlugIn_Host,
                    profile_device_id(slot),
                    1,
                    &nameAddress
                );
            }
        }
    }

Cleanup:
    for(UInt32 index = 0; index < kProfileDevice_Count; ++index)
    {
        if(requestedUIDs[index] != NULL) { CFRelease(requestedUIDs[index]); }
        if(requestedNames[index] != NULL) { CFRelease(requestedNames[index]); }
        if(previousUIDs[index] != NULL) { CFRelease(previousUIDs[index]); }
        if(previousNames[index] != NULL) { CFRelease(previousNames[index]); }
    }
    return result;
}

static CFPropertyListRef create_transport_capabilities(void)
{
    CFMutableDictionaryRef capabilities = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        3,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    if(capabilities == NULL) { return NULL; }
    int64_t protocolValue = SABR_TRANSPORT_PROTOCOL_VERSION;
    int64_t abiValue = SABR_TRANSPORT_ABI_VERSION;
    int64_t channelCapacityValue = kNumber_Of_Channels;
    CFNumberRef protocolVersion = CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberSInt64Type,
        &protocolValue
    );
    CFNumberRef abiVersion = CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberSInt64Type,
        &abiValue
    );
    CFNumberRef channelCapacity = CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberSInt64Type,
        &channelCapacityValue
    );
    if(protocolVersion == NULL || abiVersion == NULL || channelCapacity == NULL)
    {
        if(protocolVersion != NULL) { CFRelease(protocolVersion); }
        if(abiVersion != NULL) { CFRelease(abiVersion); }
        if(channelCapacity != NULL) { CFRelease(channelCapacity); }
        CFRelease(capabilities);
        return NULL;
    }
    CFDictionarySetValue(
        capabilities,
        CFSTR(SABR_TRANSPORT_KEY_PROTOCOL_VERSION),
        protocolVersion
    );
    CFDictionarySetValue(
        capabilities,
        CFSTR(SABR_TRANSPORT_KEY_ABI_VERSION),
        abiVersion
    );
    CFDictionarySetValue(
        capabilities,
        CFSTR(SABR_TRANSPORT_KEY_CHANNEL_CAPACITY),
        channelCapacity
    );
    CFRelease(protocolVersion);
    CFRelease(abiVersion);
    CFRelease(channelCapacity);
    return capabilities;
}

// Volume conversions

static Float32 volume_to_decibel(Float32 volume)
{
	if (volume <= powf(10.0f, kVolume_MinDB / 20.0f))
		return kVolume_MinDB;
	else
		return 20.0f * log10f(volume);
}

static Float32 volume_from_decibel(Float32 decibel)
{
	if (decibel <= kVolume_MinDB)
		return 0.0f;
	else
		return powf(10.0f, decibel / 20.0f);
}

static Float32 volume_to_scalar(Float32 volume)
{
    // Keep the macOS-facing profile scalar round-trippable. This value is a
    // control surface only: private SABR PCM is never attenuated here, and the
    // companion applies the physical endpoint's measured curve in PCM.
    if(!isfinite(volume) || volume <= 0.0f) { return 0.0f; }
    if(volume >= 1.0f) { return 1.0f; }
    return volume;
}

static Float32 volume_from_scalar(Float32 scalar)
{
    if(!isfinite(scalar) || scalar <= 0.0f) { return 0.0f; }
    if(scalar >= 1.0f) { return 1.0f; }
    return scalar;
}

static AudioObjectID mute_control_for_volume(AudioObjectID volumeControlID)
{
    if(is_profile_volume_id(volumeControlID))
    {
        return profile_mute_id(profile_child_index(volumeControlID));
    }
    return canonical_control_id(volumeControlID) == kObjectID_Volume_Input_Master
        ? kObjectID_Mute_Input_Master
        : kObjectID_Mute_Output_Master;
}

static void notify_mute_control_changed(AudioObjectID volumeControlID)
{
    if(gPlugIn_Host == NULL) { return; }
    const AudioObjectID muteControlID = mute_control_for_volume(volumeControlID);
    const AudioObjectPropertyScope scope =
        canonical_control_id(volumeControlID) == kObjectID_Volume_Input_Master
            ? kAudioObjectPropertyScopeInput
            : kAudioObjectPropertyScopeOutput;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        AudioObjectPropertyAddress address = {
            kAudioBooleanControlPropertyValue,
            scope,
            kAudioObjectPropertyElementMain
        };
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, muteControlID, 1, &address);
    });
}

// Store the profile/bridge control state only. A positive volume write also
// clears a stale mute, matching normal macOS behavior. The lock-free SABR
// latest-value lane carries the complete snapshot to the companion; it does
// not wake PCM delivery and never touches the live physical endpoint.
static bool set_volume_control_state(
    AudioObjectID volumeControlID,
    Float32 newVolume,
    bool* outMuteChanged
)
{
    if(outMuteChanged != NULL) { *outMuteChanged = false; }
    struct DeviceIOState* state = control_io_state(volumeControlID);
    const bool isProfile = is_profile_volume_id(volumeControlID) && state != NULL;
    const Float32 previousVolume = isProfile
        ? atomic_load_explicit(&state->volume, memory_order_relaxed)
        : atomic_load_explicit(&gVolume_Master_Value, memory_order_relaxed);
    const bool wasMuted = isProfile
        ? atomic_load_explicit(&state->mute, memory_order_relaxed)
        : atomic_load_explicit(&gMute_Master_Value, memory_order_relaxed);

    const bool muteChanged = newVolume > 0.0f && wasMuted;
    if(previousVolume == newVolume && !muteChanged) { return false; }

    if(isProfile)
    {
        atomic_store_explicit(&state->volume, newVolume, memory_order_relaxed);
        if(muteChanged)
        {
            atomic_store_explicit(&state->mute, false, memory_order_relaxed);
        }
    }
    else
    {
        atomic_store_explicit(&gVolume_Master_Value, newVolume, memory_order_relaxed);
        if(muteChanged)
        {
            atomic_store_explicit(&gMute_Master_Value, false, memory_order_relaxed);
        }
    }
    const bool volumeChanged = previousVolume != newVolume;
    if(outMuteChanged != NULL) { *outMuteChanged = muteChanged; }
    if(volumeChanged || muteChanged)
    {
        sabr_driver_transport_publish_control(
            control_owner_device(volumeControlID),
            newVolume,
            muteChanged ? false : wasMuted
        );
    }
    return volumeChanged;
}

static UInt32 device_object_list_size(AudioObjectPropertyScope scope, AudioObjectID objectID) {
    if(is_profile_device_object(objectID))
    {
        return scope == kAudioObjectPropertyScopeGlobal ||
            scope == kAudioObjectPropertyScopeOutput ? 3 : 0;
    }
    if(objectID != kObjectID_Device) { return 0; }
    if(scope == kAudioObjectPropertyScopeGlobal) { return kDevice_ObjectListSize; }
    UInt32 count = 0;
    for(UInt32 index = 0; index < kDevice_ObjectListSize; ++index)
    {
        count += (kDevice_ObjectList[index].scope == scope);
    }
    return count;
}

static UInt32 device_stream_list_size(AudioObjectPropertyScope scope, AudioObjectID objectID) {
    if(is_profile_device_object(objectID))
    {
        return scope == kAudioObjectPropertyScopeGlobal ||
            scope == kAudioObjectPropertyScopeOutput ? 1 : 0;
    }
    if(objectID != kObjectID_Device) { return 0; }
    UInt32 count = 0;
    for(UInt32 index = 0; index < kDevice_ObjectListSize; ++index)
    {
        count += kDevice_ObjectList[index].type == kObjectType_Stream &&
            (kDevice_ObjectList[index].scope == scope || scope == kAudioObjectPropertyScopeGlobal);
    }
    return count;
}

static UInt32 device_control_list_size(AudioObjectPropertyScope scope, AudioObjectID objectID) {
    if(is_profile_device_object(objectID))
    {
        return scope == kAudioObjectPropertyScopeGlobal ||
            scope == kAudioObjectPropertyScopeOutput ? 2 : 0;
    }
    if(objectID != kObjectID_Device) { return 0; }
    UInt32 count = 0;
    for(UInt32 index = 0; index < kDevice_ObjectListSize; ++index)
    {
        count += kDevice_ObjectList[index].type == kObjectType_Control &&
            (kDevice_ObjectList[index].scope == scope || scope == kAudioObjectPropertyScopeGlobal);
    }
    return count;
}

static UInt32 related_device_count(void)
{
    return 1 + profile_device_count();
}

static UInt32 copy_related_devices(AudioObjectID* destination, UInt32 capacity)
{
    UInt32 written = 0;
    if(destination == NULL || capacity == 0) { return 0; }
    pthread_mutex_lock(&gPlugIn_StateMutex);
    destination[written++] = kObjectID_Device;
    for(UInt32 slot = 0; slot < kProfileDevice_Count && written < capacity; ++slot)
    {
        if(gProfileDevice_UIDs[slot] != NULL)
        {
            destination[written++] = profile_device_id(slot);
        }
    }
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return written;
}

static UInt32 minimum(UInt32 a, UInt32 b) {
    return a < b ? a : b;
}

static bool is_valid_sample_rate(Float64 sample_rate)
{
    for(UInt32 i = 0; i < kDevice_SampleRatesSize; i++)
    {
        if (sample_rate == kDevice_SampleRates[i])
        {
            return true;
        }
    }

    return false;
}

static AudioChannelLayoutTag device_channel_layout_tag(void)
{
    _Static_assert(kNumber_Of_Channels >= 1 && kNumber_Of_Channels <= SABR_TRANSPORT_MAX_CHANNELS,
                   "System Audio Bridge supports 1 through 32 channels");
#ifdef SABR_CHANNEL_LAYOUT_TAG
    _Static_assert((SABR_CHANNEL_LAYOUT_TAG & 0xFFFF) == kNumber_Of_Channels,
                   "Channel layout and stream count must agree");
    return SABR_CHANNEL_LAYOUT_TAG;
#else
    switch(kNumber_Of_Channels)
    {
        case 2: return kAudioChannelLayoutTag_Stereo;
        case 6: return kAudioChannelLayoutTag_MPEG_5_1_A;
        case 8: return kAudioChannelLayoutTag_MPEG_7_1_C;
        default: return kAudioChannelLayoutTag_DiscreteInOrder | kNumber_Of_Channels;
    }
#endif
}

#pragma mark Factory

void*	SystemAudioBridge_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
	//	This is the CFPlugIn factory function. Its job is to create the implementation for the given
	//	type provided that the type is supported. Because this driver is simple and all its
	//	initialization is handled via static initialization when the bundle is loaded, all that
	//	needs to be done is to return the AudioServerPlugInDriverRef that points to the driver's
	//	interface. A more complicated driver would create any base line objects it needs to satisfy
	//	the IUnknown methods that are used to discover that actual interface to talk to the driver.
	//	The majority of the driver's initialization should be handled in the Initialize() method of
	//	the driver's AudioServerPlugInDriverInterface.
	
	#pragma unused(inAllocator)
    void* theAnswer = NULL;
    if(CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID))
    {
		theAnswer = gAudioServerPlugInDriverRef;
    }
    return theAnswer;
}

#pragma mark Inheritance

static HRESULT	SystemAudioBridge_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
	//	This function is called by the HAL to get the interface to talk to the plug-in through.
	//	AudioServerPlugIns are required to support the IUnknown interface and the
	//	AudioServerPlugInDriverInterface. As it happens, all interfaces must also provide the
	//	IUnknown interface, so we can always just return the single interface we made with
	//	gAudioServerPlugInDriverInterfacePtr regardless of which one is asked for.

	//	declare the local variables
	HRESULT theAnswer = 0;
	CFUUIDRef theRequestedUUID = NULL;
	
	//	validate the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_QueryInterface: bad driver reference");
	FailWithAction(outInterface == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_QueryInterface: no place to store the returned interface");

	//	make a CFUUIDRef from inUUID
	theRequestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
	FailWithAction(theRequestedUUID == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_QueryInterface: failed to create the CFUUIDRef");

	//	AudioServerPlugIns only support two interfaces, IUnknown (which has to be supported by all
	//	CFPlugIns and AudioServerPlugInDriverInterface (which is the actual interface the HAL will
	//	use).
	if(CFEqual(theRequestedUUID, IUnknownUUID) || CFEqual(theRequestedUUID, kAudioServerPlugInDriverInterfaceUUID))
	{
		pthread_mutex_lock(&gPlugIn_StateMutex);
		++gPlugIn_RefCount;
		pthread_mutex_unlock(&gPlugIn_StateMutex);
		*outInterface = gAudioServerPlugInDriverRef;
	}
	else
	{
		theAnswer = E_NOINTERFACE;
	}
	
	//	make sure to release the UUID we created
	CFRelease(theRequestedUUID);
		
Done:
	return theAnswer;
}

static ULONG	SystemAudioBridge_AddRef(void* inDriver)
{
	//	This call returns the resulting reference count after the increment.
	
	//	declare the local variables
	ULONG theAnswer = 0;
	
	//	check the arguments
	FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "SystemAudioBridge_AddRef: bad driver reference");

	//	increment the refcount
	pthread_mutex_lock(&gPlugIn_StateMutex);
	if(gPlugIn_RefCount < UINT32_MAX)
	{
		++gPlugIn_RefCount;
	}
	theAnswer = gPlugIn_RefCount;
	pthread_mutex_unlock(&gPlugIn_StateMutex);

Done:
	return theAnswer;
}

static ULONG	SystemAudioBridge_Release(void* inDriver)
{
	//	This call returns the resulting reference count after the decrement.

	//	declare the local variables
	ULONG theAnswer = 0;
	
	//	check the arguments
	FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "SystemAudioBridge_Release: bad driver reference");

	//	decrement the refcount
	pthread_mutex_lock(&gPlugIn_StateMutex);
	if(gPlugIn_RefCount > 0)
	{
		--gPlugIn_RefCount;
		//	Note that we don't do anything special if the refcount goes to zero as the HAL
		//	will never fully release a plug-in it opens. We keep managing the refcount so that
		//	the API semantics are correct though.
	}
	theAnswer = gPlugIn_RefCount;
	pthread_mutex_unlock(&gPlugIn_StateMutex);

Done:
	return theAnswer;
}

#pragma mark Basic Operations

static OSStatus	SystemAudioBridge_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
	//	The job of this method is, as the name implies, to get the driver initialized. One specific
	//	thing that needs to be done is to store the AudioServerPlugInHostRef so that it can be used
	//	later. Note that when this call returns, the HAL will scan the various lists the driver
	//	maintains (such as the device list) to get the initial set of objects the driver is
	//	publishing. So, there is no need to notify the HAL about any objects created as part of the
	//	execution of this method.

	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_Initialize: bad driver reference");
	
	//	store the AudioServerPlugInHostRef
	gPlugIn_Host = inHost;

	// The public name and visibility are controlled by the app. CamiTune keeps
	// this transport hidden and exposes stable native profile endpoints above it.
	pthread_mutex_lock(&gPlugIn_StateMutex);
	if(gDevice_DisplayName == NULL)
	{
		gDevice_DisplayName = CFStringCreateWithCString(
			kCFAllocatorDefault,
			kDevice_Name,
			kCFStringEncodingUTF8
		);
	}
	if(!gProfileDeviceIOStatesInitialized)
	{
		for(UInt32 slot = 0; slot < kProfileDevice_Count; ++slot)
		{
			pthread_mutex_init(&gProfileDeviceIOStates[slot].ioMutex, NULL);
#if kDevice_HasInput
			gProfileDeviceIOStates[slot].lastMixOutputSampleTime = -1.0;
			gProfileDeviceIOStates[slot].isBufferClear = true;
#endif
			gProfileDeviceIOStates[slot].outputStreamIsActive = true;
			atomic_store_explicit(&gProfileDeviceIOStates[slot].volume, 1.0f, memory_order_relaxed);
			atomic_store_explicit(&gProfileDeviceIOStates[slot].mute, false, memory_order_relaxed);
		}
		gProfileDeviceIOStatesInitialized = true;
	}
	gDevice_IsHidden = kDevice_IsHidden;
	pthread_mutex_unlock(&gPlugIn_StateMutex);
	
	//	initialize the box acquired property from the settings
	CFPropertyListRef theSettingsData = NULL;
	Boolean restoredBoxAcquired = kBox_Aquired;
	gPlugIn_Host->CopyFromStorage(gPlugIn_Host, kBoxAcquiredStorageKey, &theSettingsData);
	if(theSettingsData != NULL)
	{
		if(CFGetTypeID(theSettingsData) == CFBooleanGetTypeID())
		{
			restoredBoxAcquired = CFBooleanGetValue((CFBooleanRef)theSettingsData);
		}
		else if(CFGetTypeID(theSettingsData) == CFNumberGetTypeID())
		{
			SInt32 theValue = 0;
			CFNumberGetValue((CFNumberRef)theSettingsData, kCFNumberSInt32Type, &theValue);
			restoredBoxAcquired = theValue ? 1 : 0;
		}
		CFRelease(theSettingsData);
		theSettingsData = NULL;
	}
	
	//	initialize the box name from the settings
	CFStringRef restoredBoxName = NULL;
	gPlugIn_Host->CopyFromStorage(gPlugIn_Host, kBoxNameStorageKey, &theSettingsData);
	if(theSettingsData != NULL)
	{
		if(CFGetTypeID(theSettingsData) == CFStringGetTypeID())
		{
			restoredBoxName = CFStringCreateCopy(
				kCFAllocatorDefault,
				(CFStringRef)theSettingsData
			);
		}
		CFRelease(theSettingsData);
		theSettingsData = NULL;
	}
	
	//	set the box name directly as a last resort
	if(restoredBoxName == NULL)
	{
		restoredBoxName = CFStringCreateWithCString(
			kCFAllocatorDefault,
			"SystemAudioBridge Box",
			kCFStringEncodingUTF8
		);
	}
	FailWithAction(restoredBoxName == NULL, theAnswer = kAudioHardwareUnspecifiedError, Done, "SystemAudioBridge_Initialize: unable to allocate the box name");
	
	//	calculate the host ticks per frame
	struct mach_timebase_info theTimeBaseInfo;
	mach_timebase_info(&theTimeBaseInfo);
	Float64 theHostClockFrequency = (Float64)theTimeBaseInfo.denom / (Float64)theTimeBaseInfo.numer;
	theHostClockFrequency *= 1000000000.0;
	pthread_mutex_lock(&gPlugIn_StateMutex);
	gBox_Acquired = restoredBoxAcquired;
	if(gBox_Name != NULL) { CFRelease(gBox_Name); }
	gBox_Name = restoredBoxName;
	gDevice_HostTicksPerFrame = theHostClockFrequency / gDevice_SampleRate;
	gDevice_AdjustedTicksPerFrame = gDevice_HostTicksPerFrame - gDevice_HostTicksPerFrame/100.0 * 2.0*(gPitch_Adjust - 0.5);
	publish_timing_snapshot();
	pthread_mutex_unlock(&gPlugIn_StateMutex);
#if DEBUG
	start_debug_overload_reporter();
#endif
    
    // DebugMsg("SystemAudioBridge theTimeBaseInfo.numer: %u \t theTimeBaseInfo.denom: %u", theTimeBaseInfo.numer, theTimeBaseInfo.denom);
	
Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
	//	This method is used to tell a driver that implements the Transport Manager semantics to
	//	create an AudioEndpointDevice from a set of AudioEndpoints. Since this driver is not a
	//	Transport Manager, we just check the arguments and return
	//	kAudioHardwareUnsupportedOperationError.
	
	#pragma unused(inDescription, inClientInfo, outDeviceObjectID)
	
	//	declare the local variables
	OSStatus theAnswer = kAudioHardwareUnsupportedOperationError;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_CreateDevice: bad driver reference");

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
	//	This method is used to tell a driver that implements the Transport Manager semantics to
	//	destroy an AudioEndpointDevice. Since this driver is not a Transport Manager, we just check
	//	the arguments and return kAudioHardwareUnsupportedOperationError.
	
	#pragma unused(inDeviceObjectID)
	
	//	declare the local variables
	OSStatus theAnswer = kAudioHardwareUnsupportedOperationError;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_DestroyDevice: bad driver reference");

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
	//	This method is used to inform the driver about a new client that is using the given device.
	//	This allows the device to act differently depending on who the client is. This driver does
	//	not need to track the clients using the device, so we just check the arguments and return
	//	successfully.
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_AddDeviceClient: bad driver reference");
	FailWithAction(!is_device_object(inDeviceObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_AddDeviceClient: bad device ID");
	FailWithAction(inClientInfo == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_AddDeviceClient: missing client info");
	sabr_driver_transport_add_client(
		inDeviceObjectID,
		inClientInfo->mClientID,
		inClientInfo->mProcessID,
		inClientInfo->mBundleID
	);

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
	//	This method is used to inform the driver about a client that is no longer using the given
	//	device. This driver does not track clients, so we just check the arguments and return
	//	successfully.
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_RemoveDeviceClient: bad driver reference");
	FailWithAction(!is_device_object(inDeviceObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_RemoveDeviceClient: bad device ID");
	FailWithAction(inClientInfo == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_RemoveDeviceClient: missing client info");
	sabr_driver_transport_remove_client(inDeviceObjectID, inClientInfo->mClientID);

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
	//	This method is called to tell the device that it can perform the configuration change that it
	//	had requested via a call to the host method, RequestDeviceConfigurationChange(). The
	//	arguments, inChangeAction and inChangeInfo are the same as what was passed to
	//	RequestDeviceConfigurationChange().
	//
	//	The HAL guarantees that IO will be stopped while this method is in progress. The HAL will
	//	also handle figuring out exactly what changed for the non-control related properties. This
	//	means that the only notifications that would need to be sent here would be for either
	//	custom properties the HAL doesn't know about or for controls.
	//
	//	For the device implemented by this driver, sample rate changes and enabling/disabling
	//	the pitch adjust go through this process.
	//	These are the only states that can be changed for the device that aren't controls.
	//	Which change is requested is passed in the inChangeAction argument.
	
	#pragma unused(inChangeInfo)

	//	declare the local variables
	OSStatus theAnswer = 0;
    Float64 newSampleRate = 0.0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_PerformDeviceConfigurationChange: bad driver reference");
    FailWithAction(!is_device_object(inDeviceObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_PerformDeviceConfigurationChange: bad device ID");
    switch(inChangeAction)
    {
        case ChangeAction_EnablePitchControl:
            FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_PerformDeviceConfigurationChange: pitch belongs to the main device");
            pthread_mutex_lock(&gPlugIn_StateMutex);
            gPitch_Adjust_Enabled = true;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            break;
        case ChangeAction_DisablePitchControl:
            FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_PerformDeviceConfigurationChange: pitch belongs to the main device");
            pthread_mutex_lock(&gPlugIn_StateMutex);
            gPitch_Adjust_Enabled = false;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            break;
        case ChangeAction_SetSampleRate:
            pthread_mutex_lock(&gPlugIn_StateMutex);
            struct DeviceIOState* requestingState = device_io_state(inDeviceObjectID);
            newSampleRate = requestingState != NULL
                ? requestingState->requestedSampleRate
                : 0.0;
            bool relatedIOIsRunning = gMainDeviceIOState.runningCount > 0;
            for(UInt32 slot = 0; slot < kProfileDevice_Count && !relatedIOIsRunning; ++slot)
            {
                relatedIOIsRunning = gProfileDeviceIOStates[slot].runningCount > 0;
            }
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            FailWithAction(relatedIOIsRunning, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_PerformDeviceConfigurationChange: related device IO is running");
            FailWithAction(!is_valid_sample_rate(newSampleRate), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_PerformDeviceConfigurationChange: bad sample rate");
            
            //	lock the state mutex
            pthread_mutex_lock(&gPlugIn_StateMutex);
            
            //	change the sample rate
            gDevice_SampleRate = newSampleRate;
            
            //	recalculate the state that depends on the sample rate
            struct mach_timebase_info theTimeBaseInfo;
            mach_timebase_info(&theTimeBaseInfo);
            Float64 theHostClockFrequency = (Float64)theTimeBaseInfo.denom / (Float64)theTimeBaseInfo.numer;
            theHostClockFrequency *= 1000000000.0;
            gDevice_HostTicksPerFrame = theHostClockFrequency / gDevice_SampleRate;
            gDevice_AdjustedTicksPerFrame = gDevice_HostTicksPerFrame - gDevice_HostTicksPerFrame/100.0 * 2.0*(gPitch_Adjust - 0.5);
			publish_timing_snapshot();
            
            //	unlock the state mutex
            pthread_mutex_unlock(&gPlugIn_StateMutex);

            if(gPlugIn_Host != NULL)
            {
                AudioObjectID relatedDevices[1 + kProfileDevice_Count];
                UInt32 relatedCount = copy_related_devices(
                    relatedDevices,
                    sizeof(relatedDevices) / sizeof(relatedDevices[0])
                );
                AudioObjectPropertyAddress rateAddress = {
                    kAudioDevicePropertyNominalSampleRate,
                    kAudioObjectPropertyScopeGlobal,
                    kAudioObjectPropertyElementMain
                };
                AudioObjectPropertyAddress formatAddresses[] = {
                    { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                    { kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                };
                for(UInt32 index = 0; index < relatedCount; ++index)
                {
                    if(relatedDevices[index] != inDeviceObjectID)
                    {
                        gPlugIn_Host->PropertiesChanged(
                            gPlugIn_Host,
                            relatedDevices[index],
                            1,
                            &rateAddress
                        );
                    }
                    AudioObjectID outputStream = relatedDevices[index] == kObjectID_Device
                        ? kObjectID_Stream_Output
                        : profile_stream_id(profile_device_index(relatedDevices[index]));
                    gPlugIn_Host->PropertiesChanged(
                        gPlugIn_Host,
                        outputStream,
                        sizeof(formatAddresses) / sizeof(formatAddresses[0]),
                        formatAddresses
                    );
#if kDevice_HasInput
                    if(relatedDevices[index] == kObjectID_Device)
                    {
                        gPlugIn_Host->PropertiesChanged(
                            gPlugIn_Host,
                            kObjectID_Stream_Input,
                            sizeof(formatAddresses) / sizeof(formatAddresses[0]),
                            formatAddresses
                        );
                    }
#endif
                }
            }
            
            // DebugMsg("SystemAudioBridge theTimeBaseInfo.numer: %u \t theTimeBaseInfo.denom: %u", theTimeBaseInfo.numer, theTimeBaseInfo.denom);
            break;
    };
	
Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
	//	This method is called to tell the driver that a request for a config change has been denied.
	//	This provides the driver an opportunity to clean up any state associated with the request.
	//	For this driver, an aborted config change requires no action. So we just check the arguments
	//	and return

	#pragma unused(inChangeAction, inChangeInfo)

	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_PerformDeviceConfigurationChange: bad driver reference");
	FailWithAction(!is_device_object(inDeviceObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_PerformDeviceConfigurationChange: bad device ID");

Done:
	return theAnswer;
}

#pragma mark Property Operations

static Boolean	SystemAudioBridge_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
	//	This method returns whether or not the given object has the given property.
	
	//	declare the local variables
	Boolean theAnswer = false;
	
	//	check the arguments
	FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "SystemAudioBridge_HasProperty: bad driver reference");
	FailIf(inAddress == NULL, Done, "SystemAudioBridge_HasProperty: no address");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetPropertyData() method.
	switch(inObjectID)
	{
		case kObjectID_PlugIn:
			theAnswer = SystemAudioBridge_HasPlugInProperty(inDriver, inObjectID, inClientProcessID, inAddress);
			break;
		
		case kObjectID_Box:
			theAnswer = SystemAudioBridge_HasBoxProperty(inDriver, inObjectID, inClientProcessID, inAddress);
			break;
		
		case kObjectID_Device:
			theAnswer = SystemAudioBridge_HasDeviceProperty(inDriver, inObjectID, inClientProcessID, inAddress);
			break;
		
		case kObjectID_Stream_Input:
		case kObjectID_Stream_Output:
			theAnswer = SystemAudioBridge_HasStreamProperty(inDriver, inObjectID, inClientProcessID, inAddress);
			break;
		
		case kObjectID_Volume_Output_Master:
		case kObjectID_Mute_Output_Master:
		case kObjectID_Volume_Input_Master:
		case kObjectID_Mute_Input_Master:
		case kObjectID_Pitch_Adjust:
		case kObjectID_ClockSource:
			theAnswer = SystemAudioBridge_HasControlProperty(inDriver, inObjectID, inClientProcessID, inAddress);
			break;

		default:
			if(is_profile_device_object(inObjectID))
			{
				theAnswer = SystemAudioBridge_HasDeviceProperty(inDriver, inObjectID, inClientProcessID, inAddress);
			}
			else if(is_profile_stream_object(inObjectID))
			{
				theAnswer = SystemAudioBridge_HasStreamProperty(inDriver, inObjectID, inClientProcessID, inAddress);
			}
			else if(is_profile_control_object(inObjectID))
			{
				theAnswer = SystemAudioBridge_HasControlProperty(inDriver, inObjectID, inClientProcessID, inAddress);
			}
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
	//	This method returns whether or not the given property on the object can have its value
	//	changed.
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_IsPropertySettable: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_IsPropertySettable: no address");
	FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_IsPropertySettable: no place to put the return value");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetPropertyData() method.
	switch(inObjectID)
	{
		case kObjectID_PlugIn:
			theAnswer = SystemAudioBridge_IsPlugInPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
			break;
		
		case kObjectID_Box:
			theAnswer = SystemAudioBridge_IsBoxPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
			break;
		
		case kObjectID_Device:
			theAnswer = SystemAudioBridge_IsDevicePropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
			break;
		
		case kObjectID_Stream_Input:
		case kObjectID_Stream_Output:
			theAnswer = SystemAudioBridge_IsStreamPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
			break;

		case kObjectID_Volume_Output_Master:
		case kObjectID_Mute_Output_Master:
		case kObjectID_Volume_Input_Master:
		case kObjectID_Mute_Input_Master:
		case kObjectID_Pitch_Adjust:
        case kObjectID_ClockSource:
			theAnswer = SystemAudioBridge_IsControlPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
			break;

		default:
			if(is_profile_device_object(inObjectID))
			{
				theAnswer = SystemAudioBridge_IsDevicePropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
			}
			else if(is_profile_stream_object(inObjectID))
			{
				theAnswer = SystemAudioBridge_IsStreamPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
			}
			else if(is_profile_control_object(inObjectID))
			{
				theAnswer = SystemAudioBridge_IsControlPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
			}
			else { theAnswer = kAudioHardwareBadObjectError; }
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
	//	This method returns the byte size of the property's data.
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetPropertyDataSize: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetPropertyDataSize: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetPropertyDataSize: no place to put the return value");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetPropertyData() method.
	switch(inObjectID)
	{
		case kObjectID_PlugIn:
			theAnswer = SystemAudioBridge_GetPlugInPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
			break;
		
		case kObjectID_Box:
			theAnswer = SystemAudioBridge_GetBoxPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
			break;
		
		case kObjectID_Device:
			theAnswer = SystemAudioBridge_GetDevicePropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
			break;
		
		case kObjectID_Stream_Input:
		case kObjectID_Stream_Output:
			theAnswer = SystemAudioBridge_GetStreamPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
			break;
			
		case kObjectID_Volume_Output_Master:
		case kObjectID_Mute_Output_Master:
		case kObjectID_Volume_Input_Master:
		case kObjectID_Mute_Input_Master:
		case kObjectID_Pitch_Adjust:
        case kObjectID_ClockSource:
			theAnswer = SystemAudioBridge_GetControlPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
			break;
			
		default:
			if(is_profile_device_object(inObjectID))
			{
				theAnswer = SystemAudioBridge_GetDevicePropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
			}
			else if(is_profile_stream_object(inObjectID))
			{
				theAnswer = SystemAudioBridge_GetStreamPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
			}
			else if(is_profile_control_object(inObjectID))
			{
				theAnswer = SystemAudioBridge_GetControlPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
			}
			else { theAnswer = kAudioHardwareBadObjectError; }
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetPropertyData: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetPropertyData: no place to put the return value size");
	FailWithAction(outData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetPropertyData: no place to put the return value");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required.
	//
	//	Also, since most of the data that will get returned is static, there are few instances where
	//	it is necessary to lock the state mutex.
	switch(inObjectID)
	{
		case kObjectID_PlugIn:
			theAnswer = SystemAudioBridge_GetPlugInPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
			break;
		
		case kObjectID_Box:
			theAnswer = SystemAudioBridge_GetBoxPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
			break;
		
		case kObjectID_Device:
			theAnswer = SystemAudioBridge_GetDevicePropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
			break;
		
		case kObjectID_Stream_Input:
		case kObjectID_Stream_Output:
			theAnswer = SystemAudioBridge_GetStreamPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
			break;
		
		case kObjectID_Volume_Output_Master:
		case kObjectID_Mute_Output_Master:
		case kObjectID_Volume_Input_Master:
		case kObjectID_Mute_Input_Master:
		case kObjectID_Pitch_Adjust:
        case kObjectID_ClockSource:
			theAnswer = SystemAudioBridge_GetControlPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
			break;
			
		default:
			if(is_profile_device_object(inObjectID))
			{
				theAnswer = SystemAudioBridge_GetDevicePropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
			}
			else if(is_profile_stream_object(inObjectID))
			{
				theAnswer = SystemAudioBridge_GetStreamPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
			}
			else if(is_profile_control_object(inObjectID))
			{
				theAnswer = SystemAudioBridge_GetControlPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
			}
			else { theAnswer = kAudioHardwareBadObjectError; }
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
	//	declare the local variables
	OSStatus theAnswer = 0;
	UInt32 theNumberPropertiesChanged = 0;
	AudioObjectPropertyAddress theChangedAddresses[2];
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_SetPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetPropertyData: no address");
	FailWithAction(inData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetPropertyData: no data");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetPropertyData() method.
	switch(inObjectID)
	{
		case kObjectID_PlugIn:
			theAnswer = SystemAudioBridge_SetPlugInPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
			break;
		
		case kObjectID_Box:
			theAnswer = SystemAudioBridge_SetBoxPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
			break;
		
		case kObjectID_Device:
			theAnswer = SystemAudioBridge_SetDevicePropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
			break;
		
		case kObjectID_Stream_Input:
		case kObjectID_Stream_Output:
			theAnswer = SystemAudioBridge_SetStreamPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
			break;
			
		case kObjectID_Volume_Output_Master:
		case kObjectID_Mute_Output_Master:
		case kObjectID_Volume_Input_Master:
		case kObjectID_Mute_Input_Master:
		case kObjectID_Pitch_Adjust:
        case kObjectID_ClockSource:
			theAnswer = SystemAudioBridge_SetControlPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
			break;
			
		default:
			if(is_profile_device_object(inObjectID))
			{
				theAnswer = SystemAudioBridge_SetDevicePropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
			}
			else if(is_profile_stream_object(inObjectID))
			{
				theAnswer = SystemAudioBridge_SetStreamPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
			}
			else if(is_profile_control_object(inObjectID))
			{
				theAnswer = SystemAudioBridge_SetControlPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
			}
			else { theAnswer = kAudioHardwareBadObjectError; }
			break;
	};

	//	send any notifications
	if(theNumberPropertiesChanged > 0 && gPlugIn_Host != NULL)
	{
		gPlugIn_Host->PropertiesChanged(gPlugIn_Host, inObjectID, theNumberPropertiesChanged, theChangedAddresses);

		// A presentation command changes whether the main device appears in
		// macOS and may also rename it. Notify the plug-in device list as well
		// as the device properties so Sound Settings immediately replaces its
		// cached row instead of briefly retaining a grey duplicate.
		if(inObjectID == kObjectID_Device && inAddress->mSelector == SABR_TRANSPORT_PROPERTY)
		{
			AudioObjectPropertyAddress theDeviceListAddress =
			{
				kAudioPlugInPropertyDeviceList,
				kAudioObjectPropertyScopeGlobal,
				kAudioObjectPropertyElementMain
			};
			gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_PlugIn, 1, &theDeviceListAddress);
		}
	}

Done:
	return theAnswer;
}

#pragma mark PlugIn Property Operations

static Boolean	SystemAudioBridge_HasPlugInProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
	//	This method returns whether or not the plug-in object has the given property.
	
	#pragma unused(inClientProcessID)
	
	//	declare the local variables
	Boolean theAnswer = false;
	
	//	check the arguments
	FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "SystemAudioBridge_HasPlugInProperty: bad driver reference");
	FailIf(inAddress == NULL, Done, "SystemAudioBridge_HasPlugInProperty: no address");
	FailIf(inObjectID != kObjectID_PlugIn, Done, "SystemAudioBridge_HasPlugInProperty: not the plug-in object");
	
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetPlugInPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyManufacturer:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioPlugInPropertyBoxList:
		case kAudioPlugInPropertyTranslateUIDToBox:
		case kAudioPlugInPropertyDeviceList:
		case kAudioPlugInPropertyTranslateUIDToDevice:
		case kAudioPlugInPropertyResourceBundle:
			theAnswer = true;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_IsPlugInPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
	//	This method returns whether or not the given property on the plug-in object can have its
	//	value changed.
	
	#pragma unused(inClientProcessID)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_IsPlugInPropertySettable: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_IsPlugInPropertySettable: no address");
	FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_IsPlugInPropertySettable: no place to put the return value");
	FailWithAction(inObjectID != kObjectID_PlugIn, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_IsPlugInPropertySettable: not the plug-in object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetPlugInPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyManufacturer:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioPlugInPropertyBoxList:
		case kAudioPlugInPropertyTranslateUIDToBox:
		case kAudioPlugInPropertyDeviceList:
		case kAudioPlugInPropertyTranslateUIDToDevice:
		case kAudioPlugInPropertyResourceBundle:
			*outIsSettable = false;
			break;
		
		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_GetPlugInPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
	//	This method returns the byte size of the property's data.
	
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetPlugInPropertyDataSize: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetPlugInPropertyDataSize: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetPlugInPropertyDataSize: no place to put the return value");
	FailWithAction(inObjectID != kObjectID_PlugIn, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetPlugInPropertyDataSize: not the plug-in object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetPlugInPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
			*outDataSize = sizeof(AudioClassID);
			break;
			
		case kAudioObjectPropertyClass:
			*outDataSize = sizeof(AudioClassID);
			break;
			
		case kAudioObjectPropertyOwner:
			*outDataSize = sizeof(AudioObjectID);
			break;
			
		case kAudioObjectPropertyManufacturer:
			*outDataSize = sizeof(CFStringRef);
			break;
			
		case kAudioObjectPropertyOwnedObjects:
			pthread_mutex_lock(&gPlugIn_StateMutex);
			*outDataSize = (1 + published_device_count_locked()) * sizeof(AudioObjectID);
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			break;
			
		case kAudioPlugInPropertyBoxList:
			*outDataSize = sizeof(AudioClassID);
			break;
			
		case kAudioPlugInPropertyTranslateUIDToBox:
			*outDataSize = sizeof(AudioObjectID);
			break;
			
		case kAudioPlugInPropertyDeviceList:
			pthread_mutex_lock(&gPlugIn_StateMutex);
			*outDataSize = published_device_count_locked() * sizeof(AudioObjectID);
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			break;
			
		case kAudioPlugInPropertyTranslateUIDToDevice:
			*outDataSize = sizeof(AudioObjectID);
			break;
			
		case kAudioPlugInPropertyResourceBundle:
			*outDataSize = sizeof(CFStringRef);
			break;
			
		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_GetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
	#pragma unused(inClientProcessID)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	UInt32 theNumberItemsToFetch;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetPlugInPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetPlugInPropertyData: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetPlugInPropertyData: no place to put the return value size");
	FailWithAction(outData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetPlugInPropertyData: no place to put the return value");
	FailWithAction(inObjectID != kObjectID_PlugIn, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetPlugInPropertyData: not the plug-in object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required.
	//
	//	Also, since most of the data that will get returned is static, there are few instances where
	//	it is necessary to lock the state mutex.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
			//	The base class for kAudioPlugInClassID is kAudioObjectClassID
			FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetPlugInPropertyData: not enough space for the return value of kAudioObjectPropertyBaseClass for the plug-in");
			*((AudioClassID*)outData) = kAudioObjectClassID;
			*outDataSize = sizeof(AudioClassID);
			break;
			
		case kAudioObjectPropertyClass:
			//	The class is always kAudioPlugInClassID for regular drivers
			FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetPlugInPropertyData: not enough space for the return value of kAudioObjectPropertyClass for the plug-in");
			*((AudioClassID*)outData) = kAudioPlugInClassID;
			*outDataSize = sizeof(AudioClassID);
			break;
			
		case kAudioObjectPropertyOwner:
			//	The plug-in doesn't have an owning object
			FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetPlugInPropertyData: not enough space for the return value of kAudioObjectPropertyOwner for the plug-in");
			*((AudioObjectID*)outData) = kAudioObjectUnknown;
			*outDataSize = sizeof(AudioObjectID);
			break;
			
		case kAudioObjectPropertyManufacturer:
			//	This is the human readable name of the maker of the plug-in.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetPlugInPropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the plug-in");
			*((CFStringRef*)outData) = CFSTR(kManufacturer_Name);
			*outDataSize = sizeof(CFStringRef);
			break;
			
		case kAudioObjectPropertyOwnedObjects:
			//	Calculate the number of items that have been requested. Note that this
			//	number is allowed to be smaller than the actual size of the list. In such
			//	case, only that number of items will be returned
			theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);
			UInt32 writtenObjects = 0;
			pthread_mutex_lock(&gPlugIn_StateMutex);
			if(writtenObjects < theNumberItemsToFetch)
			{
				((AudioObjectID*)outData)[writtenObjects++] = kObjectID_Box;
				writtenObjects += copy_published_devices_locked(
					((AudioObjectID*)outData) + writtenObjects,
					theNumberItemsToFetch - writtenObjects
				);
			}
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			
			//	Return how many bytes we wrote to
			*outDataSize = writtenObjects * sizeof(AudioObjectID);
			break;
			
		case kAudioPlugInPropertyBoxList:
			//	Calculate the number of items that have been requested. Note that this
			//	number is allowed to be smaller than the actual size of the list. In such
			//	case, only that number of items will be returned
			theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);
			
			//	Clamp that to the number of boxes this driver implements (which is just 1)
			if(theNumberItemsToFetch > 1)
			{
				theNumberItemsToFetch = 1;
			}
			
			//	Write the devices' object IDs into the return value
			if(theNumberItemsToFetch > 0)
			{
				((AudioObjectID*)outData)[0] = kObjectID_Box;
			}
			
			//	Return how many bytes we wrote to
			*outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
			break;
			
		case kAudioPlugInPropertyTranslateUIDToBox:
			//	This property takes the CFString passed in the qualifier and converts that
			//	to the object ID of the box it corresponds to. For this driver, there is
			//	just the one box. Note that it is not an error if the string in the
			//	qualifier doesn't match any devices. In such case, kAudioObjectUnknown is
			//	the object ID to return.
			FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetPlugInPropertyData: not enough space for the return value of kAudioPlugInPropertyTranslateUIDToBox");
			FailWithAction(inQualifierDataSize != sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetPlugInPropertyData: the qualifier is the wrong size for kAudioPlugInPropertyTranslateUIDToBox");
			FailWithAction(inQualifierData == NULL, theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetPlugInPropertyData: no qualifier for kAudioPlugInPropertyTranslateUIDToBox");
			CFStringRef requestedBoxUID = *((CFStringRef const*)inQualifierData);
			FailWithAction(requestedBoxUID == NULL || CFGetTypeID(requestedBoxUID) != CFStringGetTypeID(), theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetPlugInPropertyData: invalid qualifier for kAudioPlugInPropertyTranslateUIDToBox");

			CFStringRef boxUID = get_box_uid();

			if(CFStringCompare(requestedBoxUID, boxUID, 0) == kCFCompareEqualTo)
			{
				*((AudioObjectID*)outData) = kObjectID_Box;
			}
			else
			{
				*((AudioObjectID*)outData) = kAudioObjectUnknown;
			}
			*outDataSize = sizeof(AudioObjectID);
			CFRelease(boxUID);
			break;
			
		case kAudioPlugInPropertyDeviceList:
			//	Calculate the number of items that have been requested. Note that this
			//	number is allowed to be smaller than the actual size of the list. In such
			//	case, only that number of items will be returned
			theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);
			pthread_mutex_lock(&gPlugIn_StateMutex);
			const UInt32 writtenDevices = copy_published_devices_locked(
				(AudioObjectID*)outData,
				theNumberItemsToFetch
			);
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			
			//	Return how many bytes we wrote to
			*outDataSize = writtenDevices * sizeof(AudioObjectID);
			break;
			
		case kAudioPlugInPropertyTranslateUIDToDevice:
			//	This property takes the CFString passed in the qualifier and converts that
			//	to the object ID of the device it corresponds to. For this driver, there is
			//	just the one device. Note that it is not an error if the string in the
			//	qualifier doesn't match any devices. In such case, kAudioObjectUnknown is
			//	the object ID to return.
			FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetPlugInPropertyData: not enough space for the return value of kAudioPlugInPropertyTranslateUIDToDevice");
			FailWithAction(inQualifierDataSize != sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetPlugInPropertyData: the qualifier is the wrong size for kAudioPlugInPropertyTranslateUIDToDevice");
			FailWithAction(inQualifierData == NULL, theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetPlugInPropertyData: no qualifier for kAudioPlugInPropertyTranslateUIDToDevice");
            
            
			
			CFStringRef requestedUID = *((CFStringRef const*)inQualifierData);
			FailWithAction(requestedUID == NULL || CFGetTypeID(requestedUID) != CFStringGetTypeID(), theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetPlugInPropertyData: invalid qualifier for kAudioPlugInPropertyTranslateUIDToDevice");
			CFStringRef deviceUID = get_device_uid();

			if(CFStringCompare(requestedUID, deviceUID, 0) == kCFCompareEqualTo)
			{
				*((AudioObjectID*)outData) = kObjectID_Device;
			}
			else
			{
				*((AudioObjectID*)outData) = kAudioObjectUnknown;
				pthread_mutex_lock(&gPlugIn_StateMutex);
				for(UInt32 slot = 0; slot < kProfileDevice_Count; ++slot)
				{
					if(gProfileDevice_UIDs[slot] != NULL &&
						CFStringCompare(requestedUID, gProfileDevice_UIDs[slot], 0) == kCFCompareEqualTo)
					{
						*((AudioObjectID*)outData) = kObjectID_ProfileDevice_First + slot;
						break;
					}
				}
				pthread_mutex_unlock(&gPlugIn_StateMutex);
			}
			*outDataSize = sizeof(AudioObjectID);
			CFRelease(deviceUID);
			break;
			
		case kAudioPlugInPropertyResourceBundle:
			//	The resource bundle is a path relative to the path of the plug-in's bundle.
			//	To specify that the plug-in bundle itself should be used, we just return the
			//	empty string.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetPlugInPropertyData: not enough space for the return value of kAudioPlugInPropertyResourceBundle");
			*((CFStringRef*)outData) = CFSTR("");
			*outDataSize = sizeof(CFStringRef);
			break;
			
		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_SetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData, inDataSize, inData)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_SetPlugInPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetPlugInPropertyData: no address");
	FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetPlugInPropertyData: no place to return the number of properties that changed");
	FailWithAction(outChangedAddresses == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetPlugInPropertyData: no place to return the properties that changed");
	FailWithAction(inObjectID != kObjectID_PlugIn, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_SetPlugInPropertyData: not the plug-in object");
	
	//	initialize the returned number of changed properties
	*outNumberPropertiesChanged = 0;
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetPlugInPropertyData() method.
	switch(inAddress->mSelector)
	{
		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

#pragma mark Box Property Operations

static Boolean	SystemAudioBridge_HasBoxProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
	//	This method returns whether or not the box object has the given property.
	
	#pragma unused(inClientProcessID)
	
	//	declare the local variables
	Boolean theAnswer = false;
	
	//	check the arguments
	FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "SystemAudioBridge_HasBoxProperty: bad driver reference");
	FailIf(inAddress == NULL, Done, "SystemAudioBridge_HasBoxProperty: no address");
	FailIf(inObjectID != kObjectID_Box, Done, "SystemAudioBridge_HasBoxProperty: not the box object");
	
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetBoxPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyName:
		case kAudioObjectPropertyModelName:
		case kAudioObjectPropertyManufacturer:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioObjectPropertyIdentify:
		case kAudioObjectPropertySerialNumber:
		case kAudioObjectPropertyFirmwareVersion:
		case kAudioBoxPropertyBoxUID:
		case kAudioBoxPropertyTransportType:
		case kAudioBoxPropertyHasAudio:
		case kAudioBoxPropertyHasVideo:
		case kAudioBoxPropertyHasMIDI:
		case kAudioBoxPropertyIsProtected:
		case kAudioBoxPropertyAcquired:
		case kAudioBoxPropertyAcquisitionFailed:
		case kAudioBoxPropertyDeviceList:
			theAnswer = true;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_IsBoxPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
	//	This method returns whether or not the given property on the plug-in object can have its
	//	value changed.
	
	#pragma unused(inClientProcessID)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_IsBoxPropertySettable: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_IsBoxPropertySettable: no address");
	FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_IsBoxPropertySettable: no place to put the return value");
	FailWithAction(inObjectID != kObjectID_Box, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_IsBoxPropertySettable: not the plug-in object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetBoxPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyModelName:
		case kAudioObjectPropertyManufacturer:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioObjectPropertySerialNumber:
		case kAudioObjectPropertyFirmwareVersion:
		case kAudioBoxPropertyBoxUID:
		case kAudioBoxPropertyTransportType:
		case kAudioBoxPropertyHasAudio:
		case kAudioBoxPropertyHasVideo:
		case kAudioBoxPropertyHasMIDI:
		case kAudioBoxPropertyIsProtected:
		case kAudioBoxPropertyAcquisitionFailed:
		case kAudioBoxPropertyDeviceList:
			*outIsSettable = false;
			break;
		
		case kAudioObjectPropertyName:
		case kAudioObjectPropertyIdentify:
		case kAudioBoxPropertyAcquired:
			*outIsSettable = true;
			break;
		
		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_GetBoxPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
	//	This method returns the byte size of the property's data.
	
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetBoxPropertyDataSize: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetBoxPropertyDataSize: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetBoxPropertyDataSize: no place to put the return value");
	FailWithAction(inObjectID != kObjectID_Box, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetBoxPropertyDataSize: not the plug-in object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetBoxPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
			*outDataSize = sizeof(AudioClassID);
			break;
			
		case kAudioObjectPropertyClass:
			*outDataSize = sizeof(AudioClassID);
			break;
			
		case kAudioObjectPropertyOwner:
			*outDataSize = sizeof(AudioObjectID);
			break;
			
		case kAudioObjectPropertyName:
			*outDataSize = sizeof(CFStringRef);
			break;
			
		case kAudioObjectPropertyModelName:
			*outDataSize = sizeof(CFStringRef);
			break;
			
		case kAudioObjectPropertyManufacturer:
			*outDataSize = sizeof(CFStringRef);
			break;
			
		case kAudioObjectPropertyOwnedObjects:
			*outDataSize = 0;
			break;
			
		case kAudioObjectPropertyIdentify:
			*outDataSize = sizeof(UInt32);
			break;
			
		case kAudioObjectPropertySerialNumber:
			*outDataSize = sizeof(CFStringRef);
			break;
			
		case kAudioObjectPropertyFirmwareVersion:
			*outDataSize = sizeof(CFStringRef);
			break;
			
		case kAudioBoxPropertyBoxUID:
			*outDataSize = sizeof(CFStringRef);
			break;
			
		case kAudioBoxPropertyTransportType:
			*outDataSize = sizeof(UInt32);
			break;
			
		case kAudioBoxPropertyHasAudio:
			*outDataSize = sizeof(UInt32);
			break;
			
		case kAudioBoxPropertyHasVideo:
			*outDataSize = sizeof(UInt32);
			break;
			
		case kAudioBoxPropertyHasMIDI:
			*outDataSize = sizeof(UInt32);
			break;
			
		case kAudioBoxPropertyIsProtected:
			*outDataSize = sizeof(UInt32);
			break;
			
		case kAudioBoxPropertyAcquired:
			*outDataSize = sizeof(UInt32);
			break;
			
		case kAudioBoxPropertyAcquisitionFailed:
			*outDataSize = sizeof(UInt32);
			break;
			
		case kAudioBoxPropertyDeviceList:
			{
				pthread_mutex_lock(&gPlugIn_StateMutex);
				*outDataSize = published_device_count_locked() * sizeof(AudioObjectID);
				pthread_mutex_unlock(&gPlugIn_StateMutex);
			}
			break;
			
		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_GetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetBoxPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetBoxPropertyData: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetBoxPropertyData: no place to put the return value size");
	FailWithAction(outData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetBoxPropertyData: no place to put the return value");
	FailWithAction(inObjectID != kObjectID_Box, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetBoxPropertyData: not the plug-in object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required.
	//
	//	Also, since most of the data that will get returned is static, there are few instances where
	//	it is necessary to lock the state mutex.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
			//	The base class for kAudioBoxClassID is kAudioObjectClassID
			FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyBaseClass for the box");
			*((AudioClassID*)outData) = kAudioObjectClassID;
			*outDataSize = sizeof(AudioClassID);
			break;
			
		case kAudioObjectPropertyClass:
			//	The class is always kAudioBoxClassID for regular drivers
			FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyClass for the box");
			*((AudioClassID*)outData) = kAudioBoxClassID;
			*outDataSize = sizeof(AudioClassID);
			break;
			
		case kAudioObjectPropertyOwner:
			//	The owner is the plug-in object
			FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyOwner for the box");
			*((AudioObjectID*)outData) = kObjectID_PlugIn;
			*outDataSize = sizeof(AudioObjectID);
			break;
			
		case kAudioObjectPropertyName:
			//	This is the human readable name of the maker of the box.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the box");
			pthread_mutex_lock(&gPlugIn_StateMutex);
			*((CFStringRef*)outData) = gBox_Name;
			if(*((CFStringRef*)outData) != NULL)
			{
				CFRetain(*((CFStringRef*)outData));
			}
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			*outDataSize = sizeof(CFStringRef);
			break;
			
		case kAudioObjectPropertyModelName:
			//	This is the human readable name of the maker of the box.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the box");
			*((CFStringRef*)outData) = CFSTR("SystemAudioBridge");
			*outDataSize = sizeof(CFStringRef);
			break;
			
		case kAudioObjectPropertyManufacturer:
			//	This is the human readable name of the maker of the box.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the box");
			*((CFStringRef*)outData) = CFSTR("Existential Audio Inc.");
			*outDataSize = sizeof(CFStringRef);
			break;
			
		case kAudioObjectPropertyOwnedObjects:
			//	This returns the objects directly owned by the object. Boxes don't own anything.
			*outDataSize = 0;
			break;
			
		case kAudioObjectPropertyIdentify:
			//	This is used to highling the device in the UI, but it's value has no meaning
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyIdentify for the box");
			*((UInt32*)outData) = 0;
			*outDataSize = sizeof(UInt32);
			break;
			
		case kAudioObjectPropertySerialNumber:
			//	This is the human readable serial number of the box.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertySerialNumber for the box");
			*((CFStringRef*)outData) = CFSTR("dd658747-4b9a-4de8-a001-c6a2ef1bb235");
			*outDataSize = sizeof(CFStringRef);
			break;
			
		case kAudioObjectPropertyFirmwareVersion:
			//	This is the human readable firmware version of the box.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyFirmwareVersion for the box");
            CFStringRef version = (CFStringRef)CFBundleGetValueForInfoDictionaryKey(CFBundleGetBundleWithIdentifier(CFSTR(kPlugIn_BundleID)), CFSTR("CFBundleShortVersionString"));
            CFRetain(version);
			*((CFStringRef*)outData) = version;
			*outDataSize = sizeof(CFStringRef);
			break;
			
		case kAudioBoxPropertyBoxUID:
			//	Boxes have UIDs the same as devices
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the box");

			*((CFStringRef*)outData) = get_box_uid();
			break;
			
		case kAudioBoxPropertyTransportType:
			//	This value represents how the device is attached to the system. This can be
			//	any 32 bit integer, but common values for this property are defined in
			//	<CoreAudio/AudioHardwareBase.h>
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetBoxPropertyData: not enough space for the return value of kAudioDevicePropertyTransportType for the box");
			*((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
			*outDataSize = sizeof(UInt32);
			break;
			
		case kAudioBoxPropertyHasAudio:
			//	Indicates whether or not the box has audio capabilities
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyHasAudio for the box");
			*((UInt32*)outData) = 1;
			*outDataSize = sizeof(UInt32);
			break;
			
		case kAudioBoxPropertyHasVideo:
			//	Indicates whether or not the box has video capabilities
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyHasVideo for the box");
			*((UInt32*)outData) = 0;
			*outDataSize = sizeof(UInt32);
			break;
			
		case kAudioBoxPropertyHasMIDI:
			//	Indicates whether or not the box has MIDI capabilities
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyHasMIDI for the box");
			*((UInt32*)outData) = 0;
			*outDataSize = sizeof(UInt32);
			break;
			
		case kAudioBoxPropertyIsProtected:
			//	Indicates whether or not the box has requires authentication to use
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyIsProtected for the box");
			*((UInt32*)outData) = 0;
			*outDataSize = sizeof(UInt32);
			break;
			
		case kAudioBoxPropertyAcquired:
			//	When set to a non-zero value, the device is acquired for use by the local machine
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyAcquired for the box");
			pthread_mutex_lock(&gPlugIn_StateMutex);
			*((UInt32*)outData) = gBox_Acquired ? 1 : 0;
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			*outDataSize = sizeof(UInt32);
			break;
			
		case kAudioBoxPropertyAcquisitionFailed:
			//	This is used for notifications to say when an attempt to acquire a device has failed.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyAcquisitionFailed for the box");
			*((UInt32*)outData) = 0;
			*outDataSize = sizeof(UInt32);
			break;
			
		case kAudioBoxPropertyDeviceList:
			//	This is used to indicate which devices came from this box
			pthread_mutex_lock(&gPlugIn_StateMutex);
			const UInt32 written = copy_published_devices_locked(
				(AudioObjectID*)outData,
				inDataSize / sizeof(AudioObjectID)
			);
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			*outDataSize = written * sizeof(AudioObjectID);
			break;
			
		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_SetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData, inDataSize, inData)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_SetBoxPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetBoxPropertyData: no address");
	FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetBoxPropertyData: no place to return the number of properties that changed");
	FailWithAction(outChangedAddresses == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetBoxPropertyData: no place to return the properties that changed");
	FailWithAction(inObjectID != kObjectID_Box, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_SetBoxPropertyData: not the box object");
	FailWithAction(inData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetBoxPropertyData: no data");
	
	//	initialize the returned number of changed properties
	*outNumberPropertiesChanged = 0;
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetPlugInPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyName:
			//	Boxes should allow their name to be editable
			{
				FailWithAction(inDataSize != sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_SetBoxPropertyData: wrong size for the data for kAudioObjectPropertyName");
				CFStringRef const* theNewName = (CFStringRef const*)inData;
				FailWithAction(*theNewName == NULL || CFGetTypeID(*theNewName) != CFStringGetTypeID(), theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetBoxPropertyData: invalid data for kAudioObjectPropertyName");
				CFStringRef persistedName = CFStringCreateCopy(kCFAllocatorDefault, *theNewName);
				FailWithAction(persistedName == NULL, theAnswer = kAudioHardwareUnspecifiedError, Done, "SystemAudioBridge_SetBoxPropertyData: unable to copy kAudioObjectPropertyName");
				pthread_mutex_lock(&gPlugIn_StateMutex);
				CFStringRef previousName = gBox_Name;
				gBox_Name = persistedName;
				CFRetain(gBox_Name);
				pthread_mutex_unlock(&gPlugIn_StateMutex);
				if(previousName != NULL) { CFRelease(previousName); }
				gPlugIn_Host->WriteToStorage(gPlugIn_Host, kBoxNameStorageKey, persistedName);
				CFRelease(persistedName);
				*outNumberPropertiesChanged = 1;
				outChangedAddresses[0].mSelector = kAudioObjectPropertyName;
				outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
				outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
			}
			break;
			
		case kAudioObjectPropertyIdentify:
			//	since we don't have any actual hardware to flash, we will schedule a notification for
			//	this property off into the future as a testing thing. Note that a real implementation
			//	of this property should only send the notification if the hardware wants the app to
			//	flash it's UI for the device.
			{
				syslog(LOG_NOTICE, "The identify property has been set on the Box implemented by the SystemAudioBridge driver.");
				FailWithAction(inDataSize != sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_SetBoxPropertyData: wrong size for the data for kAudioObjectPropertyIdentify");
				dispatch_after(dispatch_time(0, 2ULL * 1000ULL * 1000ULL * 1000ULL), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),	^()
																																		{
																																			AudioObjectPropertyAddress theAddress = { kAudioObjectPropertyIdentify, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
																																			gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Box, 1, &theAddress);
																																		});
			}
			break;
			
		case kAudioBoxPropertyAcquired:
			//	When the box is acquired, it means the contents, namely the device, are available to the system
			{
				FailWithAction(inDataSize != sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_SetBoxPropertyData: wrong size for the data for kAudioBoxPropertyAcquired");
				const Boolean newAcquired = *((const UInt32*)inData) != 0;
				Boolean acquisitionChanged = false;
				pthread_mutex_lock(&gPlugIn_StateMutex);
				if(gBox_Acquired != newAcquired)
				{
					gBox_Acquired = newAcquired;
					acquisitionChanged = true;
				}
				pthread_mutex_unlock(&gPlugIn_StateMutex);
				if(acquisitionChanged)
				{
					gPlugIn_Host->WriteToStorage(gPlugIn_Host, kBoxAcquiredStorageKey, newAcquired ? kCFBooleanTrue : kCFBooleanFalse);

					//	and it means that this property and the device list property have changed
					*outNumberPropertiesChanged = 2;
					outChangedAddresses[0].mSelector = kAudioBoxPropertyAcquired;
					outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
					outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
					outChangedAddresses[1].mSelector = kAudioBoxPropertyDeviceList;
					outChangedAddresses[1].mScope = kAudioObjectPropertyScopeGlobal;
					outChangedAddresses[1].mElement = kAudioObjectPropertyElementMain;
					
					//	but it also means that the device list has changed for the plug-in too
					dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),	^()
																									{
																										AudioObjectPropertyAddress theAddress = { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
																										gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_PlugIn, 1, &theAddress);
																		});
				}
			}
			break;
			
		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

#pragma mark Device Property Operations

static Boolean	SystemAudioBridge_HasDeviceProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
	//	This method returns whether or not the given object has the given property.
	
	#pragma unused(inClientProcessID)
	
	//	declare the local variables
	Boolean theAnswer = false;
	
	//	check the arguments
	FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "SystemAudioBridge_HasDeviceProperty: bad driver reference");
	FailIf(inAddress == NULL, Done, "SystemAudioBridge_HasDeviceProperty: no address");
	FailIf(!is_device_object(inObjectID), Done, "SystemAudioBridge_HasDeviceProperty: not the device object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetDevicePropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyName:
		case kAudioObjectPropertyManufacturer:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioDevicePropertyDeviceUID:
		case kAudioDevicePropertyModelUID:
		case kAudioDevicePropertyTransportType:
		case kAudioDevicePropertyRelatedDevices:
		case kAudioDevicePropertyClockDomain:
		case kAudioDevicePropertyDeviceIsAlive:
		case kAudioDevicePropertyDeviceIsRunning:
		case kAudioObjectPropertyControlList:
		case kAudioDevicePropertyNominalSampleRate:
		case kAudioDevicePropertyAvailableNominalSampleRates:
		case kAudioDevicePropertyIsHidden:
		case kAudioDevicePropertyZeroTimeStampPeriod:
		case kAudioDevicePropertyIcon:
		case kAudioDevicePropertyStreams:
		case kAudioObjectPropertyCustomPropertyInfoList:
		case SABR_TRANSPORT_PROPERTY:
			theAnswer = true;
			break;
			
		case kAudioDevicePropertyDeviceCanBeDefaultDevice:
		case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
		case kAudioDevicePropertyLatency:
		case kAudioDevicePropertySafetyOffset:
		case kAudioDevicePropertyStreamConfiguration:
		case kAudioDevicePropertyPreferredChannelsForStereo:
		case kAudioDevicePropertyPreferredChannelLayout:
			theAnswer = (inAddress->mScope == kAudioObjectPropertyScopeInput) || (inAddress->mScope == kAudioObjectPropertyScopeOutput);
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_IsDevicePropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
	//	This method returns whether or not the given property on the object can have its value
	//	changed.
	
	#pragma unused(inClientProcessID)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_IsDevicePropertySettable: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_IsDevicePropertySettable: no address");
	FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_IsDevicePropertySettable: no place to put the return value");
	FailWithAction(!is_device_object(inObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_IsDevicePropertySettable: not the device object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetDevicePropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyName:
		case kAudioObjectPropertyManufacturer:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioDevicePropertyDeviceUID:
		case kAudioDevicePropertyModelUID:
		case kAudioDevicePropertyTransportType:
		case kAudioDevicePropertyRelatedDevices:
		case kAudioDevicePropertyClockDomain:
		case kAudioDevicePropertyDeviceIsAlive:
		case kAudioDevicePropertyDeviceIsRunning:
		case kAudioDevicePropertyDeviceCanBeDefaultDevice:
		case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
		case kAudioDevicePropertyLatency:
		case kAudioDevicePropertyStreams:
		case kAudioObjectPropertyControlList:
		case kAudioDevicePropertyStreamConfiguration:
		case kAudioDevicePropertySafetyOffset:
		case kAudioDevicePropertyAvailableNominalSampleRates:
		case kAudioDevicePropertyIsHidden:
		case kAudioDevicePropertyPreferredChannelsForStereo:
		case kAudioDevicePropertyPreferredChannelLayout:
		case kAudioDevicePropertyZeroTimeStampPeriod:
		case kAudioDevicePropertyIcon:
		case kAudioObjectPropertyCustomPropertyInfoList:
			*outIsSettable = false;
			break;

		case SABR_TRANSPORT_PROPERTY:
			*outIsSettable = true;
			break;
		
		case kAudioDevicePropertyNominalSampleRate:
			*outIsSettable = true;
			break;
		
		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_GetDevicePropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
	//	This method returns the byte size of the property's data.
	
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetDevicePropertyDataSize: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetDevicePropertyDataSize: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetDevicePropertyDataSize: no place to put the return value");
	FailWithAction(!is_device_object(inObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetDevicePropertyDataSize: not the device object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetDevicePropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
			*outDataSize = sizeof(AudioClassID);
			break;
			
		case kAudioObjectPropertyClass:
			*outDataSize = sizeof(AudioClassID);
			break;
			
		case kAudioObjectPropertyOwner:
			*outDataSize = sizeof(AudioObjectID);
			break;
			
		case kAudioObjectPropertyName:
			*outDataSize = sizeof(CFStringRef);
			break;
			
		case kAudioObjectPropertyManufacturer:
			*outDataSize = sizeof(CFStringRef);
			break;
			
		case kAudioObjectPropertyOwnedObjects:
            *outDataSize = device_object_list_size(inAddress->mScope, inObjectID) * sizeof(AudioObjectID);
			break;

		case kAudioDevicePropertyDeviceUID:
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioDevicePropertyModelUID:
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioDevicePropertyTransportType:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyRelatedDevices:
			*outDataSize = related_device_count() * sizeof(AudioObjectID);
			break;

		case kAudioDevicePropertyClockDomain:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyDeviceIsAlive:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyDeviceIsRunning:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyDeviceCanBeDefaultDevice:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyLatency:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyStreams:
            *outDataSize = device_stream_list_size(inAddress->mScope, inObjectID) * sizeof(AudioObjectID);
			break;

		case kAudioObjectPropertyControlList:
            *outDataSize = device_control_list_size(inAddress->mScope, inObjectID) * sizeof(AudioObjectID);
			break;

		case kAudioDevicePropertyStreamConfiguration:
			*outDataSize = offsetof(AudioBufferList, mBuffers) +
				(inAddress->mScope == kAudioObjectPropertyScopeOutput ? sizeof(AudioBuffer) : 0);
			break;

		case kAudioDevicePropertySafetyOffset:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyNominalSampleRate:
			*outDataSize = sizeof(Float64);
			break;

		case kAudioDevicePropertyAvailableNominalSampleRates:
			*outDataSize = kDevice_SampleRatesSize * sizeof(AudioValueRange);
			break;
		
		case kAudioDevicePropertyIsHidden:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyPreferredChannelsForStereo:
			*outDataSize = 2 * sizeof(UInt32);
			break;

		case kAudioDevicePropertyPreferredChannelLayout:
			*outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions);
			break;

		case kAudioDevicePropertyZeroTimeStampPeriod:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyIcon:
			*outDataSize = sizeof(CFURLRef);
			break;

		case kAudioObjectPropertyCustomPropertyInfoList:
			*outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
			break;

		case SABR_TRANSPORT_PROPERTY:
			*outDataSize = sizeof(CFPropertyListRef);
			break;

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_GetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	UInt32 theNumberItemsToFetch;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetDevicePropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetDevicePropertyData: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetDevicePropertyData: no place to put the return value size");
	FailWithAction(outData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetDevicePropertyData: no place to put the return value");
	FailWithAction(!is_device_object(inObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetDevicePropertyData: not the device object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required.
	//
	//	Also, since most of the data that will get returned is static, there are few instances where
	//	it is necessary to lock the state mutex.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
			//	The base class for kAudioDeviceClassID is kAudioObjectClassID
			FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyBaseClass for the device");
			*((AudioClassID*)outData) = kAudioObjectClassID;
			*outDataSize = sizeof(AudioClassID);
			break;
			
		case kAudioObjectPropertyClass:
			//	The class is always kAudioDeviceClassID for devices created by drivers
			FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyClass for the device");
			*((AudioClassID*)outData) = kAudioDeviceClassID;
			*outDataSize = sizeof(AudioClassID);
			break;
			
		case kAudioObjectPropertyOwner:
			//	The device's owner is the plug-in object
			FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyOwner for the device");
			*((AudioObjectID*)outData) = kObjectID_PlugIn;
			*outDataSize = sizeof(AudioObjectID);
			break;
			
		case kAudioObjectPropertyName:
			//	This is the human readable name of the device.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the device");
            
			*((CFStringRef*)outData) = inObjectID == kObjectID_Device
				? get_device_name()
				: copy_profile_device_name(inObjectID);
			FailWithAction(*((CFStringRef*)outData) == NULL, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetDevicePropertyData: inactive profile device");
			*outDataSize = sizeof(CFStringRef);
			break;
			
		case kAudioObjectPropertyManufacturer:
			//	This is the human readable name of the maker of the plug-in.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the device");
			*((CFStringRef*)outData) = CFSTR(kManufacturer_Name);
			*outDataSize = sizeof(CFStringRef);
			break;
			
		case kAudioObjectPropertyOwnedObjects:
			//	Calculate the number of items that have been requested. Note that this
			//	number is allowed to be smaller than the actual size of the list. In such
			//	case, only that number of items will be returned
            theNumberItemsToFetch = minimum(inDataSize / sizeof(AudioObjectID), device_object_list_size(inAddress->mScope, inObjectID));

			if(is_profile_device_id(inObjectID))
			{
				UInt32 slot = profile_device_index(inObjectID);
				AudioObjectID profileObjects[] = {
					profile_stream_id(slot), profile_volume_id(slot), profile_mute_id(slot)
				};
				for(UInt32 index = 0; index < theNumberItemsToFetch; ++index)
				{
					((AudioObjectID*)outData)[index] = profileObjects[index];
				}
			}
			else
			{
				for(UInt32 index = 0, written = 0; written < theNumberItemsToFetch; ++index)
				{
					if(kDevice_ObjectList[index].scope == inAddress->mScope || inAddress->mScope == kAudioObjectPropertyScopeGlobal)
					{
						((AudioObjectID*)outData)[written++] = kDevice_ObjectList[index].id;
					}
				}
			}

			//	report how much we wrote
			*outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
			break;

		case kAudioDevicePropertyDeviceUID:
			//	This is a CFString that is a persistent token that can identify the same
			//	audio device across boot sessions. Note that two instances of the same
			//	device must have different values for this property.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyDeviceUID for the device");

			*((CFStringRef*)outData) = inObjectID == kObjectID_Device
				? get_device_uid()
				: copy_profile_device_uid(inObjectID);
			FailWithAction(*((CFStringRef*)outData) == NULL, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetDevicePropertyData: inactive profile device");
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioDevicePropertyModelUID:
			//	This is a CFString that is a persistent token that can identify audio
			//	devices that are the same kind of device. Note that two instances of the
			//	save device must have the same value for this property.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyModelUID for the device");

            *((CFStringRef*)outData) = get_device_model_uid();
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioDevicePropertyTransportType:
			//	This value represents how the device is attached to the system. This can be
			//	any 32 bit integer, but common values for this property are defined in
			//	<CoreAudio/AudioHardwareBase.h>
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyTransportType for the device");
			*((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyRelatedDevices:
			//	The related devices property identifys device objects that are very closely
			//	related. Generally, this is for relating devices that are packaged together
			//	in the hardware such as when the input side and the output side of a piece
			//	of hardware can be clocked separately and therefore need to be represented
			//	as separate AudioDevice objects. In such case, both devices would report
			//	that they are related to each other. Note that at minimum, a device is
			//	related to itself, so this list will always be at least one item long.

			theNumberItemsToFetch = minimum(
				inDataSize / sizeof(AudioObjectID),
				related_device_count()
			);
			theNumberItemsToFetch = copy_related_devices(
				(AudioObjectID*)outData,
				theNumberItemsToFetch
			);
			
			//	report how much we wrote
			*outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
			break;

		case kAudioDevicePropertyClockDomain:
			//	This property allows the device to declare what other devices it is
			//	synchronized with in hardware. The way it works is that if two devices have
			//	the same value for this property and the value is not zero, then the two
			//	devices are synchronized in hardware. Note that a device that either can't
			//	be synchronized with others or doesn't know should return 0 for this
			//	property.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyClockDomain for the device");
			*((UInt32*)outData) = kDevice_ClockDomain;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyDeviceIsAlive:
			//	This property returns whether or not the device is alive. Note that it is
			//	not uncommon for a device to be dead but still momentarily available in the
			//	device list. In the case of this device, it will always be alive.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyDeviceIsAlive for the device");
			if(inObjectID == kObjectID_Device)
			{
				*((UInt32*)outData) = 1;
			}
			else
			{
				CFStringRef uid = copy_profile_device_uid(inObjectID);
				*((UInt32*)outData) = uid != NULL ? 1 : 0;
				if(uid != NULL) { CFRelease(uid); }
			}
			*outDataSize = sizeof(UInt32);
			break;

        case kAudioDevicePropertyDeviceIsRunning:
            //    This property returns whether or not IO is running for the device. Note that
            //    we need to take both the state lock to check this value for thread safety.
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyDeviceIsRunning for the device");
			pthread_mutex_lock(&gPlugIn_StateMutex);
			struct DeviceIOState* runningState = device_io_state(inObjectID);
			*((UInt32*)outData) = runningState != NULL && runningState->runningCount > 0 ? 1 : 0;
			pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outDataSize = sizeof(UInt32);
            break;

		case kAudioDevicePropertyDeviceCanBeDefaultDevice:
			//	This property returns whether or not the device wants to be able to be the
			//	default device for content. This is the device that iTunes and QuickTime
			//	will use to play their content on and FaceTime will use as it's microhphone.
			//	Nearly all devices should allow for this.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyDeviceCanBeDefaultDevice for the device");
			*((UInt32*)outData) = kCanBeDefaultDevice;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
			//	This property returns whether or not the device wants to be the system
			//	default device. This is the device that is used to play interface sounds and
			//	other incidental or UI-related sounds on. Most devices should allow this
			//	although devices with lots of latency may not want to.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyDeviceCanBeDefaultSystemDevice for the device");
			*((UInt32*)outData) = kCanBeDefaultSystemDevice;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyLatency:
			//	This property returns the presentation latency of the device. For this,
			//	device, the value is 0 due to the fact that it always vends silence.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyLatency for the device");
			*((UInt32*)outData) = 0;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyStreams:
			//	Calculate the number of items that have been requested. Note that this
			//	number is allowed to be smaller than the actual size of the list. In such
			//	case, only that number of items will be returned
            theNumberItemsToFetch = minimum(inDataSize / sizeof(AudioObjectID), device_stream_list_size(inAddress->mScope, inObjectID));

			if(is_profile_device_id(inObjectID))
			{
				if(theNumberItemsToFetch > 0)
				{
					((AudioObjectID*)outData)[0] = profile_stream_id(profile_device_index(inObjectID));
				}
			}
			else
			{
				for(UInt32 index = 0, written = 0; written < theNumberItemsToFetch; ++index)
				{
					if(kDevice_ObjectList[index].type == kObjectType_Stream &&
						(kDevice_ObjectList[index].scope == inAddress->mScope || inAddress->mScope == kAudioObjectPropertyScopeGlobal))
					{
						((AudioObjectID*)outData)[written++] = kDevice_ObjectList[index].id;
					}
				}
			}

			//	report how much we wrote
			*outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
			break;

		case kAudioObjectPropertyControlList:
			//	Calculate the number of items that have been requested. Note that this
			//	number is allowed to be smaller than the actual size of the list. In such
			//	case, only that number of items will be returned

            theNumberItemsToFetch = minimum(inDataSize / sizeof(AudioObjectID), device_control_list_size(inAddress->mScope, inObjectID));

			if(is_profile_device_id(inObjectID))
			{
				UInt32 slot = profile_device_index(inObjectID);
				AudioObjectID profileControls[] = {
					profile_volume_id(slot), profile_mute_id(slot)
				};
				for(UInt32 index = 0; index < theNumberItemsToFetch; ++index)
				{
					((AudioObjectID*)outData)[index] = profileControls[index];
				}
			}
			else
			{
				pthread_mutex_lock(&gPlugIn_StateMutex);
				for(UInt32 index = 0, written = 0; written < theNumberItemsToFetch; ++index)
				{
					if(kDevice_ObjectList[index].type == kObjectType_Control &&
						!(!gPitch_Adjust_Enabled && kDevice_ObjectList[index].id == kObjectID_Pitch_Adjust))
					{
						((AudioObjectID*)outData)[written++] = kDevice_ObjectList[index].id;
					}
				}
				pthread_mutex_unlock(&gPlugIn_StateMutex);
			}

			//	report how much we wrote
			*outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
			break;

		case kAudioDevicePropertyStreamConfiguration:
			{
				const bool hasOutput = inAddress->mScope == kAudioObjectPropertyScopeOutput;
				const UInt32 configurationSize = offsetof(AudioBufferList, mBuffers) +
					(hasOutput ? sizeof(AudioBuffer) : 0);
				FailWithAction(inDataSize < configurationSize, theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for kAudioDevicePropertyStreamConfiguration");
				AudioBufferList* configuration = (AudioBufferList*)outData;
				configuration->mNumberBuffers = hasOutput ? 1 : 0;
				if(hasOutput)
				{
					configuration->mBuffers[0].mNumberChannels = kNumber_Of_Channels;
					configuration->mBuffers[0].mDataByteSize = 0;
					configuration->mBuffers[0].mData = NULL;
				}
				*outDataSize = configurationSize;
			}
			break;

		case kAudioDevicePropertySafetyOffset:
			//	This property returns the how close to now the HAL can read and write. For
			//	this, device, the value is 0 due to the fact that it always vends silence.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertySafetyOffset for the device");
			*((UInt32*)outData) = kLatency_Frame_Size;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyNominalSampleRate:
			//	This property returns the nominal sample rate of the device. Note that we
			//	only need to take the state lock to get this value.
			FailWithAction(inDataSize < sizeof(Float64), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyNominalSampleRate for the device");
			pthread_mutex_lock(&gPlugIn_StateMutex);
			*((Float64*)outData) = gDevice_SampleRate;
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			*outDataSize = sizeof(Float64);
			break;

		case kAudioDevicePropertyAvailableNominalSampleRates:
			//	This returns all nominal sample rates the device supports as an array of
			//	AudioValueRangeStructs. Note that for discrete sampler rates, the range
			//	will have the minimum value equal to the maximum value.
			
			//	Calculate the number of items that have been requested. Note that this
			//	number is allowed to be smaller than the actual size of the list. In such
			//	case, only that number of items will be returned
			theNumberItemsToFetch = inDataSize / sizeof(AudioValueRange);
			
			//	clamp it to the number of items we have
			if(theNumberItemsToFetch > kDevice_SampleRatesSize)
			{
				theNumberItemsToFetch = kDevice_SampleRatesSize;
			}
			
            //	fill out the return array
            for(UInt32 i = 0; i < theNumberItemsToFetch; i++)
            {
                ((AudioValueRange*)outData)[i].mMinimum = kDevice_SampleRates[i];
                ((AudioValueRange*)outData)[i].mMaximum = kDevice_SampleRates[i];
            }

			//	report how much we wrote
			*outDataSize = theNumberItemsToFetch * sizeof(AudioValueRange);
			break;
		
		case kAudioDevicePropertyIsHidden:
			//	This returns whether or not the device is visible to clients.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyIsHidden for the device");
            
			if(inObjectID == kObjectID_Device)
			{
				pthread_mutex_lock(&gPlugIn_StateMutex);
				*((UInt32*)outData) = gDevice_IsHidden;
				pthread_mutex_unlock(&gPlugIn_StateMutex);
			}
			else
			{
				CFStringRef uid = copy_profile_device_uid(inObjectID);
				*((UInt32*)outData) = uid == NULL ? 1 : 0;
				if(uid != NULL) { CFRelease(uid); }
			}
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyPreferredChannelsForStereo:
			//	This property returns which two channels to use as left/right for stereo
			//	data by default. Note that the channel numbers are 1-based.xz
			FailWithAction(inDataSize < (2 * sizeof(UInt32)), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyPreferredChannelsForStereo for the device");
			((UInt32*)outData)[0] = 1;
			((UInt32*)outData)[1] = 2;
			*outDataSize = 2 * sizeof(UInt32);
			break;

		case kAudioDevicePropertyPreferredChannelLayout:
			//	This property returns the semantic order for the device's
			//	compiled 2.0, 5.1, or 7.1 LPCM layout.
			{
				// A tag-only layout is fixed-size and survives the HAL's out-of-process
				// property proxy without a variable trailing-description payload.
				UInt32 theACLSize = offsetof(AudioChannelLayout, mChannelDescriptions);
				FailWithAction(inDataSize < theACLSize, theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyPreferredChannelLayout for the device");
				((AudioChannelLayout*)outData)->mChannelLayoutTag = device_channel_layout_tag();
				((AudioChannelLayout*)outData)->mChannelBitmap = 0;
				((AudioChannelLayout*)outData)->mNumberChannelDescriptions = 0;
				*outDataSize = theACLSize;
			}
			break;

		case kAudioDevicePropertyZeroTimeStampPeriod:
			//	This property returns how many frames the HAL should expect to see between
			//	successive sample times in the zero time stamps this device provides.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyZeroTimeStampPeriod for the device");
			*((UInt32*)outData) = kDevice_RingBufferSize;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyIcon:
			{
				//	This is a CFURL that points to the device's Icon in the plug-in's resource bundle.
				FailWithAction(inDataSize < sizeof(CFURLRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyDeviceUID for the device");
				CFBundleRef theBundle = CFBundleGetBundleWithIdentifier(CFSTR(kPlugIn_BundleID));
				FailWithAction(theBundle == NULL, theAnswer = kAudioHardwareUnspecifiedError, Done, "SystemAudioBridge_GetDevicePropertyData: could not get the plug-in bundle for kAudioDevicePropertyIcon");
				CFURLRef theURL = CFBundleCopyResourceURL(theBundle, CFSTR(kPlugIn_Icon), NULL, NULL);
				FailWithAction(theURL == NULL, theAnswer = kAudioHardwareUnspecifiedError, Done, "SystemAudioBridge_GetDevicePropertyData: could not get the URL for kAudioDevicePropertyIcon");
				*((CFURLRef*)outData) = theURL;
				*outDataSize = sizeof(CFURLRef);
			}
			break;

		case SABR_TRANSPORT_PROPERTY:
			FailWithAction(inDataSize < sizeof(CFPropertyListRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for transport property list");
			*((CFPropertyListRef*)outData) = create_transport_capabilities();
			FailWithAction(*((CFPropertyListRef*)outData) == NULL, theAnswer = kAudioHardwareUnspecifiedError, Done, "SystemAudioBridge_GetDevicePropertyData: could not create transport capabilities");
			*outDataSize = sizeof(CFPropertyListRef);
			break;

		case kAudioObjectPropertyCustomPropertyInfoList:
			FailWithAction(inDataSize < sizeof(AudioServerPlugInCustomPropertyInfo), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetDevicePropertyData: not enough space for custom property information");
			((AudioServerPlugInCustomPropertyInfo*)outData)->mSelector = SABR_TRANSPORT_PROPERTY;
			((AudioServerPlugInCustomPropertyInfo*)outData)->mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
			((AudioServerPlugInCustomPropertyInfo*)outData)->mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
			*outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
			break;
			
		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_SetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
	#pragma unused(inQualifierDataSize, inQualifierData)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	Float64 theOldSampleRate;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_SetDevicePropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetDevicePropertyData: no address");
	FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetDevicePropertyData: no place to return the number of properties that changed");
	FailWithAction(outChangedAddresses == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetDevicePropertyData: no place to return the properties that changed");
	FailWithAction(!is_device_object(inObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_SetDevicePropertyData: not the device object");
	FailWithAction(inData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetDevicePropertyData: no data");
	
	//	initialize the returned number of changed properties
	*outNumberPropertiesChanged = 0;
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetDevicePropertyData() method.
	switch(inAddress->mSelector)
	{
		case SABR_TRANSPORT_PROPERTY:
			FailWithAction(inDataSize != sizeof(CFPropertyListRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_SetDevicePropertyData: wrong transport property-list size");
			CFPropertyListRef propertyList = *((CFPropertyListRef const*)inData);
			if(propertyList != NULL &&
				CFGetTypeID(propertyList) == CFDictionaryGetTypeID())
			{
				CFDictionaryRef dictionary = (CFDictionaryRef)propertyList;
				CFTypeRef command = CFDictionaryGetValue(
					dictionary,
					CFSTR(SABR_TRANSPORT_KEY_COMMAND)
				);
				if(command != NULL &&
					CFGetTypeID(command) == CFStringGetTypeID() &&
					CFStringCompare(
						(CFStringRef)command,
						CFSTR(SABR_TRANSPORT_COMMAND_PRESENTATION),
						0
					) == kCFCompareEqualTo)
				{
					FailWithAction(inObjectID != kObjectID_Device, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetDevicePropertyData: presentation is only supported by the main device");
					theAnswer = sabr_driver_transport_authorize_property_list(
						propertyList,
						inClientProcessID
					);
					FailWithAction(theAnswer != noErr, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetDevicePropertyData: unauthorized presentation command");
					CFTypeRef name = CFDictionaryGetValue(
						dictionary,
						CFSTR(SABR_TRANSPORT_KEY_DISPLAY_NAME)
					);
					CFTypeRef visible = CFDictionaryGetValue(
						dictionary,
						CFSTR(SABR_TRANSPORT_KEY_VISIBLE)
					);
					FailWithAction(name == NULL ||
							CFGetTypeID(name) != CFStringGetTypeID() ||
							CFStringGetLength((CFStringRef)name) == 0 ||
							CFStringGetLength((CFStringRef)name) > SABR_TRANSPORT_MAX_DISPLAY_NAME_UTF16_LENGTH ||
						visible == NULL ||
						CFGetTypeID(visible) != CFBooleanGetTypeID(),
						theAnswer = kAudioHardwareIllegalOperationError,
						Done,
						"SystemAudioBridge_SetDevicePropertyData: invalid presentation command");

					CFStringRef replacement = CFStringCreateCopy(
						kCFAllocatorDefault,
						(CFStringRef)name
					);
					FailWithAction(replacement == NULL, theAnswer = kAudioHardwareUnspecifiedError, Done, "SystemAudioBridge_SetDevicePropertyData: could not copy presentation name");
					pthread_mutex_lock(&gPlugIn_StateMutex);
					CFStringRef previous = gDevice_DisplayName;
					gDevice_DisplayName = replacement;
					gDevice_IsHidden = !CFBooleanGetValue((CFBooleanRef)visible);
					pthread_mutex_unlock(&gPlugIn_StateMutex);
					if(previous != NULL) { CFRelease(previous); }

					*outNumberPropertiesChanged = 2;
					outChangedAddresses[0].mSelector = kAudioObjectPropertyName;
					outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
					outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
					outChangedAddresses[1].mSelector = kAudioDevicePropertyIsHidden;
					outChangedAddresses[1].mScope = kAudioObjectPropertyScopeGlobal;
					outChangedAddresses[1].mElement = kAudioObjectPropertyElementMain;
					break;
				}
				if(command != NULL &&
					CFGetTypeID(command) == CFStringGetTypeID() &&
					CFStringCompare(
						(CFStringRef)command,
						CFSTR(SABR_TRANSPORT_COMMAND_PROFILE_DEVICES),
						0
					) == kCFCompareEqualTo)
				{
					FailWithAction(inObjectID != kObjectID_Device, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetDevicePropertyData: profile devices are only configured through the main device");
					theAnswer = sabr_driver_transport_authorize_property_list(
						propertyList,
						inClientProcessID
					);
					FailWithAction(theAnswer != noErr, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetDevicePropertyData: unauthorized profile-device command");
					CFTypeRef profiles = CFDictionaryGetValue(
						dictionary,
						CFSTR(SABR_TRANSPORT_KEY_PROFILES)
					);
					theAnswer = set_profile_devices((CFArrayRef)profiles);
					break;
				}
			}
			theAnswer = sabr_driver_transport_connect_property_list(
				propertyList,
				inClientProcessID
			);
			break;

		case kAudioDevicePropertyNominalSampleRate:
			//	Changing the sample rate needs to be handled via the
			//	RequestConfigChange/PerformConfigChange machinery.

			//	check the arguments
			FailWithAction(inDataSize != sizeof(Float64), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_SetDevicePropertyData: wrong size for the data for kAudioDevicePropertyNominalSampleRate");
			FailWithAction(!is_valid_sample_rate(*(const Float64*)inData), theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetDevicePropertyData: unsupported value for kAudioDevicePropertyNominalSampleRate");
			
			//	make sure that the new value is different than the old value
			pthread_mutex_lock(&gPlugIn_StateMutex);
			theOldSampleRate = gDevice_SampleRate;
			struct DeviceIOState* requestingState = device_io_state(inObjectID);
			FailWithAction(requestingState == NULL, pthread_mutex_unlock(&gPlugIn_StateMutex); theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_SetDevicePropertyData: missing device state");
			requestingState->requestedSampleRate = *((const Float64*)inData);
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			if(*((const Float64*)inData) != theOldSampleRate)
			{
				//	we dispatch this so that the change can happen asynchronously
				AudioObjectID requestingDevice = inObjectID;
				dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, requestingDevice, ChangeAction_SetSampleRate, NULL); });
			}
			break;
		
		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

#pragma mark Stream Property Operations

static Boolean	SystemAudioBridge_HasStreamProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
	//	This method returns whether or not the given object has the given property.
	
	#pragma unused(inClientProcessID)
	
	//	declare the local variables
	Boolean theAnswer = false;
	
	//	check the arguments
	FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "SystemAudioBridge_HasStreamProperty: bad driver reference");
	FailIf(inAddress == NULL, Done, "SystemAudioBridge_HasStreamProperty: no address");
	FailIf(!is_stream_object(inObjectID), Done, "SystemAudioBridge_HasStreamProperty: not a stream object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetStreamPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioStreamPropertyIsActive:
		case kAudioStreamPropertyDirection:
		case kAudioStreamPropertyTerminalType:
		case kAudioStreamPropertyStartingChannel:
		case kAudioStreamPropertyLatency:
		case kAudioStreamPropertyVirtualFormat:
		case kAudioStreamPropertyPhysicalFormat:
		case kAudioStreamPropertyAvailableVirtualFormats:
		case kAudioStreamPropertyAvailablePhysicalFormats:
			theAnswer = true;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_IsStreamPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
	//	This method returns whether or not the given property on the object can have its value
	//	changed.
	
	#pragma unused(inClientProcessID)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_IsStreamPropertySettable: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_IsStreamPropertySettable: no address");
	FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_IsStreamPropertySettable: no place to put the return value");
	FailWithAction(!is_stream_object(inObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_IsStreamPropertySettable: not a stream object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetStreamPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioStreamPropertyDirection:
		case kAudioStreamPropertyTerminalType:
		case kAudioStreamPropertyStartingChannel:
		case kAudioStreamPropertyLatency:
		case kAudioStreamPropertyAvailableVirtualFormats:
		case kAudioStreamPropertyAvailablePhysicalFormats:
			*outIsSettable = false;
			break;
		
		case kAudioStreamPropertyIsActive:
		case kAudioStreamPropertyVirtualFormat:
		case kAudioStreamPropertyPhysicalFormat:
			*outIsSettable = true;
			break;
		
		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_GetStreamPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
	//	This method returns the byte size of the property's data.
	
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetStreamPropertyDataSize: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetStreamPropertyDataSize: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetStreamPropertyDataSize: no place to put the return value");
	FailWithAction(!is_stream_object(inObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetStreamPropertyDataSize: not a stream object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetStreamPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyClass:
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyOwner:
			*outDataSize = sizeof(AudioObjectID);
			break;

		case kAudioObjectPropertyOwnedObjects:
			*outDataSize = 0 * sizeof(AudioObjectID);
			break;

		case kAudioStreamPropertyIsActive:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyDirection:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyTerminalType:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyStartingChannel:
			*outDataSize = sizeof(UInt32);
			break;
		
		case kAudioStreamPropertyLatency:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyVirtualFormat:
		case kAudioStreamPropertyPhysicalFormat:
			*outDataSize = sizeof(AudioStreamBasicDescription);
			break;

		case kAudioStreamPropertyAvailableVirtualFormats:
		case kAudioStreamPropertyAvailablePhysicalFormats:
			*outDataSize = kDevice_SampleRatesSize * sizeof(AudioStreamRangedDescription);
			break;

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_GetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	UInt32 theNumberItemsToFetch;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetStreamPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetStreamPropertyData: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetStreamPropertyData: no place to put the return value size");
	FailWithAction(outData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetStreamPropertyData: no place to put the return value");
	FailWithAction(!is_stream_object(inObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetStreamPropertyData: not a stream object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required.
	//
	//	Also, since most of the data that will get returned is static, there are few instances where
	//	it is necessary to lock the state mutex.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
			//	The base class for kAudioStreamClassID is kAudioObjectClassID
			FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetStreamPropertyData: not enough space for the return value of kAudioObjectPropertyBaseClass for the stream");
			*((AudioClassID*)outData) = kAudioObjectClassID;
			*outDataSize = sizeof(AudioClassID);
			break;
			
		case kAudioObjectPropertyClass:
			//	The class is always kAudioStreamClassID for streams created by drivers
			FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetStreamPropertyData: not enough space for the return value of kAudioObjectPropertyClass for the stream");
			*((AudioClassID*)outData) = kAudioStreamClassID;
			*outDataSize = sizeof(AudioClassID);
			break;
			
		case kAudioObjectPropertyOwner:
			//	The stream's owner is the device object
			FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetStreamPropertyData: not enough space for the return value of kAudioObjectPropertyOwner for the stream");
			*((AudioObjectID*)outData) = stream_owner_device(inObjectID);
			*outDataSize = sizeof(AudioObjectID);
			break;
			
		case kAudioObjectPropertyOwnedObjects:
			//	Streams do not own any objects
			*outDataSize = 0 * sizeof(AudioObjectID);
			break;

		case kAudioStreamPropertyIsActive:
			//	This property tells the device whether or not the given stream is going to
			//	be used for IO. Note that we need to take the state lock to examine this
			//	value.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyIsActive for the stream");
			pthread_mutex_lock(&gPlugIn_StateMutex);
			struct DeviceIOState* streamState = device_io_state(stream_owner_device(inObjectID));
			*((UInt32*)outData) = inObjectID == kObjectID_Stream_Input
				? gStream_Input_IsActive
				: (streamState != NULL && streamState->outputStreamIsActive ? 1 : 0);
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyDirection:
			//	This returns whether the stream is an input stream or an output stream.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyDirection for the stream");
			*((UInt32*)outData) = (inObjectID == kObjectID_Stream_Input) ? 1 : 0;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyTerminalType:
			//	This returns a value that indicates what is at the other end of the stream
			//	such as a speaker or headphones, or a microphone. Values for this property
			//	are defined in <CoreAudio/AudioHardwareBase.h>
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyTerminalType for the stream");
			*((UInt32*)outData) = (inObjectID == kObjectID_Stream_Input) ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyStartingChannel:
			//	This property returns the absolute channel number for the first channel in
			//	the stream. For example, if a device has two output streams with two
			//	channels each, then the starting channel number for the first stream is 1
			//	and the starting channel number fo the second stream is 3.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyStartingChannel for the stream");
			*((UInt32*)outData) = 1;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyLatency:
			//	This property returns any additional presentation latency the stream has.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyStartingChannel for the stream");
			*((UInt32*)outData) = kLatency_Frame_Size;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyVirtualFormat:
		case kAudioStreamPropertyPhysicalFormat:
			//	This returns the current format of the stream in an
			//	AudioStreamBasicDescription. Note that we need to hold the state lock to get
			//	this value.
			//	Note that for devices that don't override the mix operation, the virtual
			//	format has to be the same as the physical format.
			FailWithAction(inDataSize < sizeof(AudioStreamBasicDescription), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyVirtualFormat for the stream");
			pthread_mutex_lock(&gPlugIn_StateMutex);
            ((AudioStreamBasicDescription*)outData)->mSampleRate = gDevice_SampleRate;
            ((AudioStreamBasicDescription*)outData)->mFormatID = kAudioFormatLinearPCM;
            ((AudioStreamBasicDescription*)outData)->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
            ((AudioStreamBasicDescription*)outData)->mBytesPerPacket = kBytes_Per_Channel * kNumber_Of_Channels;
            ((AudioStreamBasicDescription*)outData)->mFramesPerPacket = 1;
            ((AudioStreamBasicDescription*)outData)->mBytesPerFrame = kBytes_Per_Channel * kNumber_Of_Channels;
            ((AudioStreamBasicDescription*)outData)->mChannelsPerFrame = kNumber_Of_Channels;
            ((AudioStreamBasicDescription*)outData)->mBitsPerChannel = kBits_Per_Channel;
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			*outDataSize = sizeof(AudioStreamBasicDescription);
			break;

		case kAudioStreamPropertyAvailableVirtualFormats:
		case kAudioStreamPropertyAvailablePhysicalFormats:
			//	This returns an array of AudioStreamRangedDescriptions that describe what
			//	formats are supported.

			//	Calculate the number of items that have been requested. Note that this
			//	number is allowed to be smaller than the actual size of the list. In such
			//	case, only that number of items will be returned
			theNumberItemsToFetch = inDataSize / sizeof(AudioStreamRangedDescription);
			
			//	clamp it to the number of items we have
			if(theNumberItemsToFetch > kDevice_SampleRatesSize)
			{
				theNumberItemsToFetch = kDevice_SampleRatesSize;
			}

            //	fill out the return array
            for(UInt32 i = 0; i < theNumberItemsToFetch; i++)
            {
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mSampleRate = kDevice_SampleRates[i];
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mFormatID = kAudioFormatLinearPCM;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mBytesPerPacket = kBytes_Per_Frame;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mFramesPerPacket = 1;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mBytesPerFrame = kBytes_Per_Frame;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mChannelsPerFrame = kNumber_Of_Channels;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mBitsPerChannel = kBits_Per_Channel;
                ((AudioStreamRangedDescription*)outData)[i].mSampleRateRange.mMinimum = kDevice_SampleRates[i];
                ((AudioStreamRangedDescription*)outData)[i].mSampleRateRange.mMaximum = kDevice_SampleRates[i];
            }

			//	report how much we wrote
			*outDataSize = theNumberItemsToFetch * sizeof(AudioStreamRangedDescription);
			break;

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_SetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	Float64 theOldSampleRate;
	Float64 theRequestedSampleRate;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_SetStreamPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetStreamPropertyData: no address");
	FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetStreamPropertyData: no place to return the number of properties that changed");
	FailWithAction(outChangedAddresses == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetStreamPropertyData: no place to return the properties that changed");
	FailWithAction(!is_stream_object(inObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_SetStreamPropertyData: not a stream object");
	FailWithAction(inData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetStreamPropertyData: no data");
	
	//	initialize the returned number of changed properties
	*outNumberPropertiesChanged = 0;
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetStreamPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioStreamPropertyIsActive:
			//	Changing the active state of a stream doesn't affect IO or change the structure
			//	so we can just save the state and send the notification.
			FailWithAction(inDataSize != sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_SetStreamPropertyData: wrong size for the data for kAudioDevicePropertyNominalSampleRate");
			pthread_mutex_lock(&gPlugIn_StateMutex);
			if(inObjectID == kObjectID_Stream_Input)
			{
				if(gStream_Input_IsActive != (*((const UInt32*)inData) != 0))
				{
					gStream_Input_IsActive = *((const UInt32*)inData) != 0;
					*outNumberPropertiesChanged = 1;
					outChangedAddresses[0].mSelector = kAudioStreamPropertyIsActive;
					outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
					outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
				}
			}
			else
			{
				struct DeviceIOState* streamState = device_io_state(stream_owner_device(inObjectID));
				FailWithAction(streamState == NULL, pthread_mutex_unlock(&gPlugIn_StateMutex); theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_SetStreamPropertyData: missing device state");
				if(streamState->outputStreamIsActive != (*((const UInt32*)inData) != 0))
				{
					streamState->outputStreamIsActive = *((const UInt32*)inData) != 0;
					*outNumberPropertiesChanged = 1;
					outChangedAddresses[0].mSelector = kAudioStreamPropertyIsActive;
					outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
					outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
				}
			}
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			break;
			
		case kAudioStreamPropertyVirtualFormat:
		case kAudioStreamPropertyPhysicalFormat:
			//	Changing the stream format needs to be handled via the
			//	RequestConfigChange/PerformConfigChange machinery. Note that because this
			//	The channel layout is fixed by the product build. The stream accepts
			//	interleaved Float32 LPCM and can change only its sample rate at runtime.
			FailWithAction(inDataSize != sizeof(AudioStreamBasicDescription), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_SetStreamPropertyData: wrong size for the data for kAudioStreamPropertyPhysicalFormat");
			FailWithAction(((const AudioStreamBasicDescription*)inData)->mFormatID != kAudioFormatLinearPCM, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "SystemAudioBridge_SetStreamPropertyData: unsupported format ID for kAudioStreamPropertyPhysicalFormat");
			FailWithAction(((const AudioStreamBasicDescription*)inData)->mFormatFlags != (kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked), theAnswer = kAudioDeviceUnsupportedFormatError, Done, "SystemAudioBridge_SetStreamPropertyData: unsupported format flags for kAudioStreamPropertyPhysicalFormat");
			FailWithAction(((const AudioStreamBasicDescription*)inData)->mBytesPerPacket != kBytes_Per_Frame, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "SystemAudioBridge_SetStreamPropertyData: unsupported bytes per packet for kAudioStreamPropertyPhysicalFormat");
			FailWithAction(((const AudioStreamBasicDescription*)inData)->mFramesPerPacket != 1, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "SystemAudioBridge_SetStreamPropertyData: unsupported frames per packet for kAudioStreamPropertyPhysicalFormat");
			FailWithAction(((const AudioStreamBasicDescription*)inData)->mBytesPerFrame != kBytes_Per_Frame, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "SystemAudioBridge_SetStreamPropertyData: unsupported bytes per frame for kAudioStreamPropertyPhysicalFormat");
			FailWithAction(((const AudioStreamBasicDescription*)inData)->mChannelsPerFrame != kNumber_Of_Channels, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "SystemAudioBridge_SetStreamPropertyData: unsupported channels per frame for kAudioStreamPropertyPhysicalFormat");
			FailWithAction(((const AudioStreamBasicDescription*)inData)->mBitsPerChannel != kBits_Per_Channel, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "SystemAudioBridge_SetStreamPropertyData: unsupported bits per channel for kAudioStreamPropertyPhysicalFormat");
			theRequestedSampleRate = ((const AudioStreamBasicDescription*)inData)->mSampleRate;
			if(theRequestedSampleRate == 0)
			{
				// Core Audio can use zero as an unspecified rate while mirroring an
				// otherwise-identical format through its out-of-process proxy.
				pthread_mutex_lock(&gPlugIn_StateMutex);
				theRequestedSampleRate = gDevice_SampleRate;
				pthread_mutex_unlock(&gPlugIn_StateMutex);
			}
			FailWithAction(!is_valid_sample_rate(theRequestedSampleRate), theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetStreamPropertyData: unsupported sample rate for kAudioStreamPropertyPhysicalFormat");
			
			//	If we made it this far, the requested format is something we support, so make sure the sample rate is actually different
			pthread_mutex_lock(&gPlugIn_StateMutex);
			theOldSampleRate = gDevice_SampleRate;
			AudioObjectID requestingDevice = stream_owner_device(inObjectID);
			struct DeviceIOState* requestingState = device_io_state(requestingDevice);
			FailWithAction(requestingState == NULL, pthread_mutex_unlock(&gPlugIn_StateMutex); theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_SetStreamPropertyData: missing device state");
			requestingState->requestedSampleRate = theRequestedSampleRate;
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			if(theRequestedSampleRate != theOldSampleRate)
			{
				//	we dispatch this so that the change can happen asynchronously
				dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, requestingDevice, ChangeAction_SetSampleRate, NULL); });
			}
			break;
		
		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

#pragma mark Control Property Operations

static Boolean	SystemAudioBridge_HasControlProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
	//	This method returns whether or not the given object has the given property.
	
	#pragma unused(inClientProcessID)
	
	//	declare the local variables
	Boolean theAnswer = false;
	
	//	check the arguments
	FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "SystemAudioBridge_HasControlProperty: bad driver reference");
	FailIf(inAddress == NULL, Done, "SystemAudioBridge_HasControlProperty: no address");
	FailIf(!is_control_object(inObjectID), Done, "SystemAudioBridge_HasControlProperty: not a control object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetControlPropertyData() method.
	switch(canonical_control_id(inObjectID))
	{
		case kObjectID_Volume_Input_Master:
		case kObjectID_Volume_Output_Master:
			switch(inAddress->mSelector)
			{
				case kAudioObjectPropertyBaseClass:
				case kAudioObjectPropertyClass:
				case kAudioObjectPropertyOwner:
				case kAudioObjectPropertyOwnedObjects:
				case kAudioControlPropertyScope:
				case kAudioControlPropertyElement:
				case kAudioLevelControlPropertyScalarValue:
				case kAudioLevelControlPropertyDecibelValue:
				case kAudioLevelControlPropertyDecibelRange:
				case kAudioLevelControlPropertyConvertScalarToDecibels:
				case kAudioLevelControlPropertyConvertDecibelsToScalar:
					theAnswer = true;
					break;
			};
			break;
		
		case kObjectID_Mute_Input_Master:
		case kObjectID_Mute_Output_Master:
			switch(inAddress->mSelector)
			{
				case kAudioObjectPropertyBaseClass:
				case kAudioObjectPropertyClass:
				case kAudioObjectPropertyOwner:
				case kAudioObjectPropertyOwnedObjects:
				case kAudioControlPropertyScope:
				case kAudioControlPropertyElement:
				case kAudioBooleanControlPropertyValue:
					theAnswer = true;
					break;
			};
			break;

		case kObjectID_Pitch_Adjust:
			switch(inAddress->mSelector)
			{
				case kAudioObjectPropertyBaseClass:
				case kAudioObjectPropertyClass:
				case kAudioObjectPropertyOwner:
				case kAudioObjectPropertyOwnedObjects:
				case kAudioControlPropertyScope:
				case kAudioControlPropertyElement:
				case kAudioStereoPanControlPropertyValue:
					theAnswer = true;
					break;
			};
			break;
			
		case kObjectID_ClockSource:
			switch(inAddress->mSelector)
			{
				case kAudioObjectPropertyBaseClass:
				case kAudioObjectPropertyClass:
				case kAudioObjectPropertyOwner:
				case kAudioObjectPropertyOwnedObjects:
				case kAudioControlPropertyScope:
				case kAudioControlPropertyElement:
				case kAudioSelectorControlPropertyCurrentItem:
				case kAudioSelectorControlPropertyAvailableItems:
				case kAudioSelectorControlPropertyItemName:
					theAnswer = true;
					break;
			};
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_IsControlPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
	//	This method returns whether or not the given property on the object can have its value
	//	changed.
	
	#pragma unused(inClientProcessID)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_IsControlPropertySettable: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_IsControlPropertySettable: no address");
	FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_IsControlPropertySettable: no place to put the return value");
	FailWithAction(!is_control_object(inObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_IsControlPropertySettable: not a control object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetControlPropertyData() method.
	switch(canonical_control_id(inObjectID))
	{
		case kObjectID_Volume_Input_Master:
		case kObjectID_Volume_Output_Master:
			switch(inAddress->mSelector)
			{
				case kAudioObjectPropertyBaseClass:
				case kAudioObjectPropertyClass:
				case kAudioObjectPropertyOwner:
				case kAudioObjectPropertyOwnedObjects:
				case kAudioControlPropertyScope:
				case kAudioControlPropertyElement:
				case kAudioLevelControlPropertyDecibelRange:
				case kAudioLevelControlPropertyConvertScalarToDecibels:
				case kAudioLevelControlPropertyConvertDecibelsToScalar:
					*outIsSettable = false;
					break;
				
				case kAudioLevelControlPropertyScalarValue:
				case kAudioLevelControlPropertyDecibelValue:
					*outIsSettable = true;
					break;
				
				default:
					theAnswer = kAudioHardwareUnknownPropertyError;
					break;
			};
			break;
		
		case kObjectID_Mute_Input_Master:
		case kObjectID_Mute_Output_Master:
			switch(inAddress->mSelector)
			{
				case kAudioObjectPropertyBaseClass:
				case kAudioObjectPropertyClass:
				case kAudioObjectPropertyOwner:
				case kAudioObjectPropertyOwnedObjects:
				case kAudioControlPropertyScope:
				case kAudioControlPropertyElement:
					*outIsSettable = false;
					break;
				
				case kAudioBooleanControlPropertyValue:
					*outIsSettable = true;
					break;
				
				default:
					theAnswer = kAudioHardwareUnknownPropertyError;
					break;
			};
			break;

		case kObjectID_Pitch_Adjust:
			switch(inAddress->mSelector)
			{
				case kAudioObjectPropertyBaseClass:
				case kAudioObjectPropertyClass:
				case kAudioObjectPropertyOwner:
				case kAudioObjectPropertyOwnedObjects:
				case kAudioControlPropertyScope:
				case kAudioControlPropertyElement:
					*outIsSettable = false;
					break;

				case kAudioStereoPanControlPropertyValue:
					*outIsSettable = true;
					break;

				default:
					theAnswer = kAudioHardwareUnknownPropertyError;
					break;
			};
			break;
		case kObjectID_ClockSource:
			switch(inAddress->mSelector)
			{
				case kAudioObjectPropertyBaseClass:
				case kAudioObjectPropertyClass:
				case kAudioObjectPropertyOwner:
				case kAudioObjectPropertyOwnedObjects:
				case kAudioControlPropertyScope:
				case kAudioControlPropertyElement:
					*outIsSettable = false;
					break;
					
				case kAudioSelectorControlPropertyCurrentItem:
					*outIsSettable = true;
					break;
					
				default:
					theAnswer = kAudioHardwareUnknownPropertyError;
					break;
			};
			break;

		default:
			theAnswer = kAudioHardwareBadObjectError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_GetControlPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
	//	This method returns the byte size of the property's data.
	
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetControlPropertyDataSize: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetControlPropertyDataSize: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetControlPropertyDataSize: no place to put the return value");
	FailWithAction(!is_control_object(inObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetControlPropertyDataSize: not a control object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetControlPropertyData() method.
	switch(canonical_control_id(inObjectID))
	{
		case kObjectID_Volume_Input_Master:
		case kObjectID_Volume_Output_Master:
			switch(inAddress->mSelector)
			{
				case kAudioObjectPropertyBaseClass:
					*outDataSize = sizeof(AudioClassID);
					break;

				case kAudioObjectPropertyClass:
					*outDataSize = sizeof(AudioClassID);
					break;

				case kAudioObjectPropertyOwner:
					*outDataSize = sizeof(AudioObjectID);
					break;

				case kAudioObjectPropertyOwnedObjects:
					*outDataSize = 0 * sizeof(AudioObjectID);
					break;

				case kAudioControlPropertyScope:
					*outDataSize = sizeof(AudioObjectPropertyScope);
					break;

				case kAudioControlPropertyElement:
					*outDataSize = sizeof(AudioObjectPropertyElement);
					break;

				case kAudioLevelControlPropertyScalarValue:
					*outDataSize = sizeof(Float32);
					break;

				case kAudioLevelControlPropertyDecibelValue:
					*outDataSize = sizeof(Float32);
					break;

				case kAudioLevelControlPropertyDecibelRange:
					*outDataSize = sizeof(AudioValueRange);
					break;

				case kAudioLevelControlPropertyConvertScalarToDecibels:
					*outDataSize = sizeof(Float32);
					break;

				case kAudioLevelControlPropertyConvertDecibelsToScalar:
					*outDataSize = sizeof(Float32);
					break;

				default:
					theAnswer = kAudioHardwareUnknownPropertyError;
					break;
			};
			break;
		
		case kObjectID_Mute_Input_Master:
		case kObjectID_Mute_Output_Master:
			switch(inAddress->mSelector)
			{
				case kAudioObjectPropertyBaseClass:
					*outDataSize = sizeof(AudioClassID);
					break;

				case kAudioObjectPropertyClass:
					*outDataSize = sizeof(AudioClassID);
					break;

				case kAudioObjectPropertyOwner:
					*outDataSize = sizeof(AudioObjectID);
					break;

				case kAudioObjectPropertyOwnedObjects:
					*outDataSize = 0 * sizeof(AudioObjectID);
					break;

				case kAudioControlPropertyScope:
					*outDataSize = sizeof(AudioObjectPropertyScope);
					break;

				case kAudioControlPropertyElement:
					*outDataSize = sizeof(AudioObjectPropertyElement);
					break;

				case kAudioBooleanControlPropertyValue:
					*outDataSize = sizeof(UInt32);
					break;

				default:
					theAnswer = kAudioHardwareUnknownPropertyError;
					break;
			};
			break;
			
		case kObjectID_Pitch_Adjust:
			switch(inAddress->mSelector)
			{
				case kAudioObjectPropertyBaseClass:
					*outDataSize = sizeof(AudioClassID);
					break;

				case kAudioObjectPropertyClass:
					*outDataSize = sizeof(AudioClassID);
					break;

				case kAudioObjectPropertyOwner:
					*outDataSize = sizeof(AudioObjectID);
					break;

				case kAudioObjectPropertyOwnedObjects:
					*outDataSize = 0 * sizeof(AudioObjectID);
					break;

				case kAudioControlPropertyScope:
					*outDataSize = sizeof(AudioObjectPropertyScope);
					break;

				case kAudioControlPropertyElement:
					*outDataSize = sizeof(AudioObjectPropertyElement);
					break;

				case kAudioStereoPanControlPropertyValue:
					*outDataSize = sizeof(Float32);
					break;

				default:
					theAnswer = kAudioHardwareUnknownPropertyError;
					break;
			};
			break;
			
		case kObjectID_ClockSource:
			switch(inAddress->mSelector)
			{
				case kAudioObjectPropertyBaseClass:
					*outDataSize = sizeof(AudioClassID);
					break;
				case kAudioObjectPropertyClass:
					*outDataSize = sizeof(AudioClassID);
					break;
				case kAudioObjectPropertyOwner:
					*outDataSize = sizeof(AudioObjectID);
					break;
				case kAudioObjectPropertyOwnedObjects:
					*outDataSize = 0 * sizeof(AudioObjectID);
					break;
				case kAudioControlPropertyScope:
					*outDataSize = sizeof(AudioObjectPropertyScope);
					break;
				case kAudioControlPropertyElement:
					*outDataSize = sizeof(AudioObjectPropertyElement);
					break;
					
				case kAudioSelectorControlPropertyCurrentItem:
					*outDataSize = sizeof(UInt32);
					break;
					
				case kAudioSelectorControlPropertyAvailableItems:
					*outDataSize = kClockSource_NumberItems * sizeof(UInt32);
					break;
				case kAudioSelectorControlPropertyItemName:
					*outDataSize = sizeof(CFStringRef);
					break;
				default:
					theAnswer = kAudioHardwareUnknownPropertyError;
					break;
			};
			break;
		default:
			theAnswer = kAudioHardwareBadObjectError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_GetControlPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
	#pragma unused(inClientProcessID, inQualifierData, inQualifierDataSize)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
    UInt32 theNumberItemsToFetch;
    UInt32 theItemIndex;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetControlPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetControlPropertyData: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetControlPropertyData: no place to put the return value size");
	FailWithAction(outData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetControlPropertyData: no place to put the return value");
	FailWithAction(!is_control_object(inObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetControlPropertyData: not a control object");
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required.
	//
	//	Also, since most of the data that will get returned is static, there are few instances where
	//	it is necessary to lock the state mutex.
	switch(canonical_control_id(inObjectID))
	{
		case kObjectID_Volume_Input_Master:
		case kObjectID_Volume_Output_Master:
			switch(inAddress->mSelector)
			{
				case kAudioObjectPropertyBaseClass:
					//	The base class for kAudioVolumeControlClassID is kAudioLevelControlClassID
					FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioObjectPropertyBaseClass for the volume control");
					*((AudioClassID*)outData) = kAudioLevelControlClassID;
					*outDataSize = sizeof(AudioClassID);
					break;
					
				case kAudioObjectPropertyClass:
					//	Volume controls are of the class, kAudioVolumeControlClassID
					FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioObjectPropertyClass for the volume control");
					*((AudioClassID*)outData) = kAudioVolumeControlClassID;
					*outDataSize = sizeof(AudioClassID);
					break;
					
				case kAudioObjectPropertyOwner:
					//	The control's owner is the device object
					FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioObjectPropertyOwner for the volume control");
					*((AudioObjectID*)outData) = control_owner_device(inObjectID);
					*outDataSize = sizeof(AudioObjectID);
					break;
					
				case kAudioObjectPropertyOwnedObjects:
					//	Controls do not own any objects
					*outDataSize = 0 * sizeof(AudioObjectID);
					break;

				case kAudioControlPropertyScope:
					//	This property returns the scope that the control is attached to.
					FailWithAction(inDataSize < sizeof(AudioObjectPropertyScope), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioControlPropertyScope for the volume control");
					*((AudioObjectPropertyScope*)outData) = canonical_control_id(inObjectID) == kObjectID_Volume_Input_Master ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
					*outDataSize = sizeof(AudioObjectPropertyScope);
					break;

				case kAudioControlPropertyElement:
					//	This property returns the element that the control is attached to.
					FailWithAction(inDataSize < sizeof(AudioObjectPropertyElement), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioControlPropertyElement for the volume control");
					*((AudioObjectPropertyElement*)outData) = kAudioObjectPropertyElementMain;
					*outDataSize = sizeof(AudioObjectPropertyElement);
					break;

				case kAudioLevelControlPropertyScalarValue:
					//	This returns the value of the control in the normalized range of 0 to 1.
					//	The media-key control path is intentionally lock-free.
					FailWithAction(inDataSize < sizeof(Float32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioLevelControlPropertyScalarValue for the volume control");
					struct DeviceIOState* volumeState = control_io_state(inObjectID);
					Float32 volumeValue = is_profile_volume_id(inObjectID) && volumeState != NULL
						? atomic_load_explicit(&volumeState->volume, memory_order_relaxed)
						: atomic_load_explicit(&gVolume_Master_Value, memory_order_relaxed);
					*((Float32*)outData) = volume_to_scalar(volumeValue);
					*outDataSize = sizeof(Float32);
					break;

				case kAudioLevelControlPropertyDecibelValue:
					//	This returns the dB value of the control.
					//	The media-key control path is intentionally lock-free.
					FailWithAction(inDataSize < sizeof(Float32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioLevelControlPropertyDecibelValue for the volume control");
					struct DeviceIOState* decibelState = control_io_state(inObjectID);
					*((Float32*)outData) = is_profile_volume_id(inObjectID) && decibelState != NULL
						? atomic_load_explicit(&decibelState->volume, memory_order_relaxed)
						: atomic_load_explicit(&gVolume_Master_Value, memory_order_relaxed);
					*((Float32*)outData) = volume_to_decibel(*((Float32*)outData));
					
					//	report how much we wrote
					*outDataSize = sizeof(Float32);
					break;

				case kAudioLevelControlPropertyDecibelRange:
					//	This returns the dB range of the control.
					FailWithAction(inDataSize < sizeof(AudioValueRange), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioLevelControlPropertyDecibelRange for the volume control");
					((AudioValueRange*)outData)->mMinimum = kVolume_MinDB;
					((AudioValueRange*)outData)->mMaximum = kVolume_MaxDB;
					*outDataSize = sizeof(AudioValueRange);
					break;

				case kAudioLevelControlPropertyConvertScalarToDecibels:
					//	This takes the scalar value in outData and converts it to dB.
					FailWithAction(inDataSize < sizeof(Float32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioLevelControlPropertyDecibelValue for the volume control");
					
					//	clamp the value to be between 0 and 1
					if(*((Float32*)outData) < 0.0)
					{
						*((Float32*)outData) = 0;
					}
					if(*((Float32*)outData) > 1.0)
					{
						*((Float32*)outData) = 1.0;
					}
					
					// Keep the HAL conversion property exactly consistent with the
					// scalar getter/setter exposed by the profile control.
					*((Float32*)outData) = volume_to_decibel(
						volume_from_scalar(*((Float32*)outData))
					);
					
					//	report how much we wrote
					*outDataSize = sizeof(Float32);
					break;

				case kAudioLevelControlPropertyConvertDecibelsToScalar:
					//	This takes the dB value in outData and converts it to scalar.
					FailWithAction(inDataSize < sizeof(Float32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioLevelControlPropertyDecibelValue for the volume control");
					
					//	clamp the value to be between kVolume_MinDB and kVolume_MaxDB
					if(*((Float32*)outData) < kVolume_MinDB)
					{
						*((Float32*)outData) = kVolume_MinDB;
					}
					if(*((Float32*)outData) > kVolume_MaxDB)
					{
						*((Float32*)outData) = kVolume_MaxDB;
					}
					
					// Inverse of kAudioLevelControlPropertyConvertScalarToDecibels.
					*((Float32*)outData) = volume_to_scalar(
						volume_from_decibel(*((Float32*)outData))
					);
					
					//	report how much we wrote
					*outDataSize = sizeof(Float32);
					break;

				default:
					theAnswer = kAudioHardwareUnknownPropertyError;
					break;
			};
			break;
		
		case kObjectID_Mute_Input_Master:
		case kObjectID_Mute_Output_Master:
			switch(inAddress->mSelector)
			{
				case kAudioObjectPropertyBaseClass:
					//	The base class for kAudioMuteControlClassID is kAudioBooleanControlClassID
					FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioObjectPropertyBaseClass for the mute control");
					*((AudioClassID*)outData) = kAudioBooleanControlClassID;
					*outDataSize = sizeof(AudioClassID);
					break;
					
				case kAudioObjectPropertyClass:
					//	Mute controls are of the class, kAudioMuteControlClassID
					FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioObjectPropertyClass for the mute control");
					*((AudioClassID*)outData) = kAudioMuteControlClassID;
					*outDataSize = sizeof(AudioClassID);
					break;
					
				case kAudioObjectPropertyOwner:
					//	The control's owner is the device object
					FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioObjectPropertyOwner for the mute control");
					*((AudioObjectID*)outData) = control_owner_device(inObjectID);
					*outDataSize = sizeof(AudioObjectID);
					break;
					
				case kAudioObjectPropertyOwnedObjects:
					//	Controls do not own any objects
					*outDataSize = 0 * sizeof(AudioObjectID);
					break;

				case kAudioControlPropertyScope:
					//	This property returns the scope that the control is attached to.
					FailWithAction(inDataSize < sizeof(AudioObjectPropertyScope), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioControlPropertyScope for the mute control");
					*((AudioObjectPropertyScope*)outData) = canonical_control_id(inObjectID) == kObjectID_Mute_Input_Master ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
					*outDataSize = sizeof(AudioObjectPropertyScope);
					break;

				case kAudioControlPropertyElement:
					//	This property returns the element that the control is attached to.
					FailWithAction(inDataSize < sizeof(AudioObjectPropertyElement), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioControlPropertyElement for the mute control");
					*((AudioObjectPropertyElement*)outData) = kAudioObjectPropertyElementMain;
					*outDataSize = sizeof(AudioObjectPropertyElement);
					break;

				case kAudioBooleanControlPropertyValue:
					//	This returns the value of the mute control where 0 means that mute is off
					//	and audio can be heard and 1 means that mute is on and audio cannot be heard.
					//	The media-key control path is intentionally lock-free.
					FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioBooleanControlPropertyValue for the mute control");
					struct DeviceIOState* muteState = control_io_state(inObjectID);
					*((UInt32*)outData) = is_profile_mute_id(inObjectID) && muteState != NULL
						? (atomic_load_explicit(&muteState->mute, memory_order_relaxed) ? 1 : 0)
						: (atomic_load_explicit(&gMute_Master_Value, memory_order_relaxed) ? 1 : 0);
					*outDataSize = sizeof(UInt32);
					break;

				default:
					theAnswer = kAudioHardwareUnknownPropertyError;
					break;
			};
			break;

		case kObjectID_Pitch_Adjust:
			switch(inAddress->mSelector)
			{
				case kAudioObjectPropertyBaseClass:
					//    The base class for kAudioMuteControlClassID is kAudioBooleanControlClassID
					FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioObjectPropertyBaseClass for the pitch control");
					*((AudioClassID*)outData) = kAudioStereoPanControlClassID;
					*outDataSize = sizeof(AudioClassID);
					break;

				case kAudioObjectPropertyClass:
					//    Level controls are of the class, kAudioLevelControlClassID
					FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioObjectPropertyClass for the pitch control");
					*((AudioClassID*)outData) = kAudioStereoPanControlClassID;
					*outDataSize = sizeof(AudioClassID);
					break;

				case kAudioObjectPropertyOwner:
					//    The control's owner is the device object
					FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioObjectPropertyOwner for the pitch control");
					*((AudioObjectID*)outData) = control_owner_device(inObjectID);
					*outDataSize = sizeof(AudioObjectID);
					break;

				case kAudioObjectPropertyOwnedObjects:
					//    Controls do not own any objects
					*outDataSize = 0 * sizeof(AudioObjectID);
					break;

				case kAudioControlPropertyScope:
					//    This property returns the scope that the control is attached to.
					FailWithAction(inDataSize < sizeof(AudioObjectPropertyScope), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioControlPropertyScope for the pitch control");
					*((AudioObjectPropertyScope*)outData) = kAudioObjectPropertyScopeOutput;
					*outDataSize = sizeof(AudioObjectPropertyScope);
					break;

				case kAudioControlPropertyElement:
					//    This property returns the element that the control is attached to.
					FailWithAction(inDataSize < sizeof(AudioObjectPropertyElement), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioControlPropertyElement for the pitch control");
					*((AudioObjectPropertyElement*)outData) = kAudioObjectPropertyElementMain;
					*outDataSize = sizeof(AudioObjectPropertyElement);
					break;

				case kAudioStereoPanControlPropertyValue:
					//    This returns the value of the pitch control.
					//    Note that we need to take the state lock to examine this value.
					FailWithAction(inDataSize < sizeof(Float32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioLevelControlScalarValue for the pitch control");
					pthread_mutex_lock(&gPlugIn_StateMutex);
					*((Float32*)outData) = (inObjectID == kObjectID_Pitch_Adjust) ? gPitch_Adjust : 0.5;
					pthread_mutex_unlock(&gPlugIn_StateMutex);
					*outDataSize = sizeof(Float32);
					break;

				default:
					theAnswer = kAudioHardwareUnknownPropertyError;
					break;
			};
			break;
		case kObjectID_ClockSource:
			switch(inAddress->mSelector)
			{
				case kAudioObjectPropertyBaseClass:
					//    The base class for kAudioDataSourceControlClassID is kAudioSelectorControlClassID
					FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioObjectPropertyBaseClass for the data source control");
					*((AudioClassID*)outData) = kAudioSelectorControlClassID;
					*outDataSize = sizeof(AudioClassID);
					break;
					
				case kAudioObjectPropertyClass:
					//    Data Source controls are of the class, kAudioDataSourceControlClassID
					FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioObjectPropertyClass for the data source control");
					*((AudioClassID*)outData) = kAudioClockSourceControlClassID;
					*outDataSize = sizeof(AudioClassID);
					break;
					
				case kAudioObjectPropertyOwner:
					//    The control's owner is the device object
					FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioObjectPropertyOwner for the data source control");
					*((AudioObjectID*)outData) = control_owner_device(inObjectID);
					*outDataSize = sizeof(AudioObjectID);
					break;
					
				case kAudioObjectPropertyOwnedObjects:
					//    Controls do not own any objects
					*outDataSize = 0 * sizeof(AudioObjectID);
					break;
					
				case kAudioControlPropertyScope:
					//    This property returns the scope that the control is attached to.
					FailWithAction(inDataSize < sizeof(AudioObjectPropertyScope), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioControlPropertyScope for the data source control");
					*((AudioObjectPropertyScope*)outData) = kAudioObjectPropertyScopeGlobal;
					*outDataSize = sizeof(AudioObjectPropertyScope);
					break;
					
				case kAudioControlPropertyElement:
					//    This property returns the element that the control is attached to.
					FailWithAction(inDataSize < sizeof(AudioObjectPropertyElement), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioControlPropertyElement for the data source control");
					*((AudioObjectPropertyElement*)outData) = kAudioObjectPropertyElementMain;
					*outDataSize = sizeof(AudioObjectPropertyElement);
					break;
					
				case kAudioSelectorControlPropertyCurrentItem:
					//    This returns the value of the data source selector.
					//    Note that we need to take the state lock to examine this value.
					FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioSelectorControlPropertyCurrentItem for the data source control");
					pthread_mutex_lock(&gPlugIn_StateMutex);
					*((UInt32*)outData) = gClockSource_Value;
					pthread_mutex_unlock(&gPlugIn_StateMutex);
					*outDataSize = sizeof(UInt32);
					break;
					
				case kAudioSelectorControlPropertyAvailableItems:
					//    This returns the IDs for all the items the data source control supports.
					
					//    Calculate the number of items that have been requested. Note that this
					//    number is allowed to be smaller than the actual size of the list. In such
					//    case, only that number of items will be returned
					theNumberItemsToFetch = inDataSize / sizeof(UInt32);
					
					//    clamp it to the number of items we have
					if(theNumberItemsToFetch > kClockSource_NumberItems)
					{
						theNumberItemsToFetch = kClockSource_NumberItems;
					}
					
					//    fill out the return array
					for(theItemIndex = 0; theItemIndex < theNumberItemsToFetch; ++theItemIndex)
					{
						((UInt32*)outData)[theItemIndex] = theItemIndex;
					}
					
					//    report how much we wrote
					*outDataSize = theNumberItemsToFetch * sizeof(UInt32);

					break;

				case kAudioSelectorControlPropertyItemName:
					//    This returns the user-readable name for the selector item in the qualifier
					FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: not enough space for the return value of kAudioSelectorControlPropertyItemName for the clock source control");
					FailWithAction(inQualifierDataSize != sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_GetControlPropertyData: wrong size for the qualifier of kAudioSelectorControlPropertyItemName for the clock source control");
					FailWithAction(*((const UInt32*)inQualifierData) >= kClockSource_NumberItems, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetControlPropertyData: the item in the qualifier is not valid for kAudioSelectorControlPropertyItemName for the data source control");
					if (*(UInt32*)inQualifierData == 0) {
						*(CFStringRef*)outData = CFSTR(kClockSource_InternalFixed);
					}
					else if (*(UInt32*)inQualifierData == 1) {
						*(CFStringRef*)outData = CFSTR(kClockSource_InternalAdjustable);
					}
					//else {
					//    *(CFStringRef*)outData = CFSTR("Unknown");
					//}
					*outDataSize = sizeof(CFStringRef);

					break;

				default:
					theAnswer = kAudioHardwareUnknownPropertyError;
					break;
			};
			break;
		default:
			theAnswer = kAudioHardwareBadObjectError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_SetControlPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	Float32 theNewVolume;
    Float32 theNewPitch;
    UInt32 theNewSource;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_SetControlPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetControlPropertyData: no address");
	FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetControlPropertyData: no place to return the number of properties that changed");
	FailWithAction(outChangedAddresses == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetControlPropertyData: no place to return the properties that changed");
	FailWithAction(inData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_SetControlPropertyData: no data");
	FailWithAction(!is_control_object(inObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_SetControlPropertyData: not a control object");
	
	//	initialize the returned number of changed properties
	*outNumberPropertiesChanged = 0;
	
	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the SystemAudioBridge_GetControlPropertyData() method.
	switch(canonical_control_id(inObjectID))
	{
		case kObjectID_Volume_Input_Master:
		case kObjectID_Volume_Output_Master:
			switch(inAddress->mSelector)
			{
				case kAudioLevelControlPropertyScalarValue:
					//	For the scalar volume, we clamp the new value to [0, 1]. Note that if this
					//	value changes, it implies that the dB value changed too.
					FailWithAction(inDataSize != sizeof(Float32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_SetControlPropertyData: wrong size for the data for kAudioLevelControlPropertyScalarValue");
					theNewVolume = volume_from_scalar(*((const Float32*)inData));
					if(theNewVolume < 0.0)
					{
						theNewVolume = 0.0;
					}
					else if(theNewVolume > 1.0)
					{
						theNewVolume = 1.0;
					}
                    bool scalarMuteChanged = false;
                    const bool scalarVolumeChanged = set_volume_control_state(
                        inObjectID,
                        theNewVolume,
                        &scalarMuteChanged
                    );
                    if(scalarVolumeChanged)
                    {
                        *outNumberPropertiesChanged = 2;
                        outChangedAddresses[0].mSelector = kAudioLevelControlPropertyScalarValue;
                        outChangedAddresses[0].mScope = canonical_control_id(inObjectID) == kObjectID_Volume_Input_Master ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
                        outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
                        outChangedAddresses[1].mSelector = kAudioLevelControlPropertyDecibelValue;
                        outChangedAddresses[1].mScope = outChangedAddresses[0].mScope;
                        outChangedAddresses[1].mElement = kAudioObjectPropertyElementMain;
                    }
                    if(scalarMuteChanged) { notify_mute_control_changed(inObjectID); }
					break;
				
				case kAudioLevelControlPropertyDecibelValue:
					//	For the dB value, we first convert it to a scalar value since that is how
					//	the value is tracked. Note that if this value changes, it implies that the
					//	scalar value changes as well.
					FailWithAction(inDataSize != sizeof(Float32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_SetControlPropertyData: wrong size for the data for kAudioLevelControlPropertyScalarValue");
					theNewVolume = *((const Float32*)inData);
					if(theNewVolume < kVolume_MinDB)
					{
						theNewVolume = kVolume_MinDB;
					}
					else if(theNewVolume > kVolume_MaxDB)
					{
						theNewVolume = kVolume_MaxDB;
					}
					theNewVolume = volume_from_decibel(theNewVolume);
                    bool decibelMuteChanged = false;
                    const bool decibelVolumeChanged = set_volume_control_state(
                        inObjectID,
                        theNewVolume,
                        &decibelMuteChanged
                    );
                    if(decibelVolumeChanged)
                    {
                        *outNumberPropertiesChanged = 2;
                        outChangedAddresses[0].mSelector = kAudioLevelControlPropertyScalarValue;
                        outChangedAddresses[0].mScope = canonical_control_id(inObjectID) == kObjectID_Volume_Input_Master ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
                        outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
                        outChangedAddresses[1].mSelector = kAudioLevelControlPropertyDecibelValue;
                        outChangedAddresses[1].mScope = outChangedAddresses[0].mScope;
                        outChangedAddresses[1].mElement = kAudioObjectPropertyElementMain;
                    }
                    if(decibelMuteChanged) { notify_mute_control_changed(inObjectID); }
					break;
				
				default:
					theAnswer = kAudioHardwareUnknownPropertyError;
					break;
			};
			break;
		
		case kObjectID_Mute_Input_Master:
		case kObjectID_Mute_Output_Master:
			switch(inAddress->mSelector)
			{
				case kAudioBooleanControlPropertyValue:
					FailWithAction(inDataSize != sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_SetControlPropertyData: wrong size for the data for kAudioBooleanControlPropertyValue");
					struct DeviceIOState* muteState = control_io_state(inObjectID);
					bool newMute = *((const UInt32*)inData) != 0;
					bool previousMute = is_profile_mute_id(inObjectID) && muteState != NULL
						? atomic_load_explicit(&muteState->mute, memory_order_relaxed)
						: atomic_load_explicit(&gMute_Master_Value, memory_order_relaxed);
					if(previousMute != newMute)
					{
						if(is_profile_mute_id(inObjectID) && muteState != NULL)
						{
							atomic_store_explicit(&muteState->mute, newMute, memory_order_relaxed);
						}
						else
						{
							atomic_store_explicit(&gMute_Master_Value, newMute, memory_order_relaxed);
						}
						const Float32 currentVolume =
							is_profile_mute_id(inObjectID) && muteState != NULL
								? atomic_load_explicit(&muteState->volume, memory_order_relaxed)
								: atomic_load_explicit(&gVolume_Master_Value, memory_order_relaxed);
						sabr_driver_transport_publish_control(
							control_owner_device(inObjectID),
							currentVolume,
							newMute
						);
						*outNumberPropertiesChanged = 1;
						outChangedAddresses[0].mSelector = kAudioBooleanControlPropertyValue;
						outChangedAddresses[0].mScope = canonical_control_id(inObjectID) == kObjectID_Mute_Input_Master ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
						outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
					}
					break;
				
				default:
					theAnswer = kAudioHardwareUnknownPropertyError;
					break;
			};
			break;

		case kObjectID_Pitch_Adjust:
			switch(inAddress->mSelector)
			{
				case kAudioStereoPanControlPropertyValue:
					//    For the scalar pitch, we clamp the new value to [0, 1].
					FailWithAction(inDataSize != sizeof(Float32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_SetControlPropertyData: wrong size for the data for kAudioLevelControlPropertyScalarValue");
					theNewPitch = *((const Float32*)inData);
					if(theNewPitch < 0.0)
					{
						theNewPitch = 0.0;
					}
					else if(theNewPitch > 1.0)
					{
						theNewPitch = 1.0;
					}
					pthread_mutex_lock(&gPlugIn_StateMutex);

					if(gPitch_Adjust != theNewPitch)
					{
						gPitch_Adjust = theNewPitch;
							gDevice_AdjustedTicksPerFrame = gDevice_HostTicksPerFrame - gDevice_HostTicksPerFrame/100.0 * 2.0*(gPitch_Adjust - 0.5);
							publish_timing_snapshot();
						*outNumberPropertiesChanged = 1;
						outChangedAddresses[0].mSelector = kAudioStereoPanControlPropertyValue;
						outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
						outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
					}
					pthread_mutex_unlock(&gPlugIn_StateMutex);
					break;
					
				default:
					theAnswer = kAudioHardwareUnknownPropertyError;
					break;
			};
			break;
			
		case kObjectID_ClockSource:
			switch(inAddress->mSelector)
			{
				case kAudioSelectorControlPropertyCurrentItem:
					FailWithAction(inDataSize != sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "SystemAudioBridge_SetControlPropertyData: wrong size for the data for kAudioSelectorControlPropertyCurrentItem");
					theNewSource = *((const UInt32*)inData);
					if(theNewSource >= kClockSource_NumberItems)
					{
						theNewSource = kClockSource_NumberItems - 1;
					}
					pthread_mutex_lock(&gPlugIn_StateMutex);
					if(gClockSource_Value != theNewSource)
					{
							gClockSource_Value = theNewSource;
							publish_timing_snapshot();
						UInt64 changeAction = (theNewSource > 0) ? ChangeAction_EnablePitchControl : ChangeAction_DisablePitchControl;

						*outNumberPropertiesChanged = 1;
						outChangedAddresses[0].mSelector = kAudioSelectorControlPropertyCurrentItem;
						outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
						outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;

						// Notify HAL about device configuration change
						dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
							gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, kObjectID_Device, changeAction, NULL);
						});
					}
					pthread_mutex_unlock(&gPlugIn_StateMutex);
					break;

				default:
					theAnswer = kAudioHardwareUnknownPropertyError;
					break;
			};
			break;

		default:
			theAnswer = kAudioHardwareBadObjectError;
			break;
	};

Done:
	return theAnswer;
}

#pragma mark IO Operations

static OSStatus	SystemAudioBridge_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
	//	This call tells the device that IO is starting for the given client. When this routine
	//	returns, the device's clock is running and it is ready to have data read/written. It is
	//	important to note that multiple clients can have IO running on the device at the same time.
	//	So, work only needs to be done when the first client starts. All subsequent starts simply
	//	increment the counter.
    
    DebugMsg("SystemAudioBridge_StartIO");
	
	#pragma unused(inClientID)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_StartIO: bad driver reference");

	// Validate the live profile and mutate its count under the same lock.
	pthread_mutex_lock(&gPlugIn_StateMutex);
	const bool deviceIsLive = inDeviceObjectID == kObjectID_Device ||
		(is_profile_device_id(inDeviceObjectID) &&
		 gProfileDevice_UIDs[profile_device_index(inDeviceObjectID)] != NULL);
	if(!deviceIsLive)
	{
		pthread_mutex_unlock(&gPlugIn_StateMutex);
		theAnswer = kAudioHardwareBadObjectError;
		goto Done;
	}
	struct DeviceIOState* state = device_io_state(inDeviceObjectID);
	if(state == NULL || state->runningCount == UINT64_MAX)
	{
		pthread_mutex_unlock(&gPlugIn_StateMutex);
		theAnswer = state == NULL
			? kAudioHardwareBadObjectError
			: kAudioHardwareIllegalOperationError;
		goto Done;
	}

	if(state->runningCount == 0)
	{
		pthread_mutex_lock(&state->ioMutex);
		state->numberTimeStamps = 0;
		state->anchorHostTime = mach_absolute_time();
		state->previousTicks = 0;
		pthread_mutex_unlock(&state->ioMutex);
#if kDevice_HasInput
		state->lastOutputSampleTime = 0;
		state->lastMixOutputSampleTime = -1;
		state->isBufferClear = true;
		state->ringBuffer = calloc(kRing_Buffer_Frame_Size * kNumber_Of_Channels, sizeof(Float32));
		if(state->ringBuffer == NULL)
		{
			theAnswer = kAudioHardwareUnspecifiedError;
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			goto Done;
		}
#endif
    }
	state->runningCount += 1;

	//	unlock the state lock
	pthread_mutex_unlock(&gPlugIn_StateMutex);
	
Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
	//	This call tells the device that the client has stopped IO. The driver can stop the hardware
	//	once all clients have stopped.
	
	#pragma unused(inClientID)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_StopIO: bad driver reference");

	// Validate the live profile and mutate its count under the same lock.
	pthread_mutex_lock(&gPlugIn_StateMutex);
	const bool deviceIsLive = inDeviceObjectID == kObjectID_Device ||
		(is_profile_device_id(inDeviceObjectID) &&
		 gProfileDevice_UIDs[profile_device_index(inDeviceObjectID)] != NULL);
	if(!deviceIsLive)
	{
		pthread_mutex_unlock(&gPlugIn_StateMutex);
		theAnswer = kAudioHardwareBadObjectError;
		goto Done;
	}
	struct DeviceIOState* state = device_io_state(inDeviceObjectID);
	if(state == NULL || state->runningCount == 0)
	{
		pthread_mutex_unlock(&gPlugIn_StateMutex);
		theAnswer = state == NULL
			? kAudioHardwareBadObjectError
			: kAudioHardwareIllegalOperationError;
		goto Done;
	}
	state->runningCount -= 1;

#if kDevice_HasInput
    if(state->runningCount == 0 && state->ringBuffer != NULL)
    {
        free(state->ringBuffer);
        state->ringBuffer = NULL;
    }
#endif
	
	//	unlock the state lock
	pthread_mutex_unlock(&gPlugIn_StateMutex);
	
Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
	//	This method returns the current zero time stamp for the device. The HAL models the timing of
	//	a device as a series of time stamps that relate the sample time to a host time. The zero
	//	time stamps are spaced such that the sample times are the value of
	//	kAudioDevicePropertyZeroTimeStampPeriod apart. This is often modeled using a ring buffer
	//	where the zero time stamp is updated when wrapping around the ring buffer.
	//
	//	For this device, the zero time stamps' sample time increments every kDevice_RingBufferSize
	//	frames and the host time increments by kDevice_RingBufferSize * gDevice_HostTicksPerFrame.
	
	#pragma unused(inClientID)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	UInt64 theCurrentHostTime;
	Float64 theAdjustedTicksPerRingBuffer;
	Float64 theNextTickOffset;
	UInt64 theNextHostTime;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetZeroTimeStamp: bad driver reference");
	FailWithAction(!is_device_object(inDeviceObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetZeroTimeStamp: bad device ID");
	FailWithAction(outSampleTime == NULL || outHostTime == NULL || outSeed == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_GetZeroTimeStamp: no place for return values");
	struct DeviceIOState* state = device_io_state(inDeviceObjectID);
	FailWithAction(state == NULL, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_GetZeroTimeStamp: missing device state");

	//	we need to hold the locks
	pthread_mutex_lock(&state->ioMutex);
	
	//	get the current host time
	theCurrentHostTime = mach_absolute_time();
	//	calculate the next host time
	theAdjustedTicksPerRingBuffer = copy_timing_effective_ticks_per_frame() *
		((Float64)kDevice_RingBufferSize);
    
	theNextTickOffset = state->previousTicks + theAdjustedTicksPerRingBuffer;
    
	theNextHostTime = state->anchorHostTime + ((UInt64)theNextTickOffset);
	
	//	go to the next time if the next host time is less than the current time
	if(theNextHostTime <= theCurrentHostTime)
	{
		++state->numberTimeStamps;
		state->previousTicks = theNextTickOffset;
	}
	
	//	set the return values
	*outSampleTime = state->numberTimeStamps * kDevice_RingBufferSize;
	*outHostTime = state->anchorHostTime + state->previousTicks;
	*outSeed = 1;
    
    // DebugMsg("SampleTime: %f \t HostTime: %llu", *outSampleTime, *outHostTime);
	
	//	unlock the state lock
	pthread_mutex_unlock(&state->ioMutex);
	
Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
	//	This method returns whether or not the device will do a given IO operation. For this device,
	//	we support reading input data and mixing each output client separately.
	
	#pragma unused(inClientID, inDeviceObjectID)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_WillDoIOOperation: bad driver reference");
	FailWithAction(!is_device_object(inDeviceObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_WillDoIOOperation: bad device ID");

	//	figure out if we support the operation
	bool willDo = false;
	bool willDoInPlace = true;
	switch(inOperationID)
	{
		#if kDevice_HasInput
		case kAudioServerPlugInIOOperationReadInput:
			willDo = inDeviceObjectID == kObjectID_Device;
			willDoInPlace = true;
			break;
		#endif
			
		case kAudioServerPlugInIOOperationMixOutput:
			willDo = true;
			willDoInPlace = true;
			break;
			
	};
	
	//	fill out the return values
	if(outWillDo != NULL)
	{
		*outWillDo = willDo;
	}
	if(outWillDoInPlace != NULL)
	{
		*outWillDoInPlace = willDoInPlace;
	}

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
	//	This is called at the beginning of an IO operation. This device doesn't do anything, so just
	//	check the arguments and return.
	
	#pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo, inDeviceObjectID)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_BeginIOOperation: bad driver reference");
	FailWithAction(!is_device_object(inDeviceObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_BeginIOOperation: bad device ID");

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
	//	This is called to actually perform a given operation. 
	
	#pragma unused(ioSecondaryBuffer)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_DoIOOperation: bad driver reference");
	FailWithAction(!is_device_object(inDeviceObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_DoIOOperation: bad device ID");
	FailWithAction(!is_stream_object(inStreamObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_DoIOOperation: bad stream ID");
	FailWithAction(stream_owner_device(inStreamObjectID) != inDeviceObjectID, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_DoIOOperation: stream does not belong to device");
	Boolean isSupportedOperation = inOperationID == kAudioServerPlugInIOOperationMixOutput;
#if kDevice_HasInput
	isSupportedOperation = isSupportedOperation || inOperationID == kAudioServerPlugInIOOperationReadInput;
#endif
	if(!isSupportedOperation) { goto Done; }
	FailWithAction(inOperationID == kAudioServerPlugInIOOperationMixOutput && inStreamObjectID == kObjectID_Stream_Input, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_DoIOOperation: MixOutput requires an output stream");
#if kDevice_HasInput
	FailWithAction(inOperationID == kAudioServerPlugInIOOperationReadInput && (inDeviceObjectID != kObjectID_Device || inStreamObjectID != kObjectID_Stream_Input), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_DoIOOperation: ReadInput requires the main input stream");
#endif
	FailWithAction(inIOCycleInfo == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_DoIOOperation: no IO cycle info");
	FailWithAction(ioMainBuffer == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_DoIOOperation: no main buffer");
	struct DeviceIOState* state = device_io_state(inDeviceObjectID);
	FailWithAction(state == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_DoIOOperation: missing IO state");
#if kDevice_HasInput
	FailWithAction(state->ringBuffer == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SystemAudioBridge_DoIOOperation: IO is not running");

	// Calculate the ring buffer offsets and splits.
    UInt64 mSampleTime = inOperationID == kAudioServerPlugInIOOperationReadInput ? inIOCycleInfo->mInputTime.mSampleTime : inIOCycleInfo->mOutputTime.mSampleTime;
    UInt32 ringBufferFrameLocationStart = mSampleTime % kRing_Buffer_Frame_Size;
    UInt32 firstPartFrameSize = kRing_Buffer_Frame_Size - ringBufferFrameLocationStart;
    UInt32 secondPartFrameSize = 0;
    
    if (firstPartFrameSize >= inIOBufferFrameSize)
    {
        firstPartFrameSize = inIOBufferFrameSize;
    }
    else
    {
        secondPartFrameSize = inIOBufferFrameSize - firstPartFrameSize;
    }
    
    // From SystemAudioBridge to Application
    if(inOperationID == kAudioServerPlugInIOOperationReadInput)
    {
        // If mute is one let's just fill the buffer with zeros or if there's no apps outputting audio
        if (atomic_load_explicit(&gMute_Master_Value, memory_order_relaxed) || state->lastOutputSampleTime - inIOBufferFrameSize < inIOCycleInfo->mInputTime.mSampleTime)
        {
            // Clear the ioMainBuffer
            vDSP_vclr(ioMainBuffer, 1, inIOBufferFrameSize * kNumber_Of_Channels);
            
            // Clear the ring buffer.
            if (!state->isBufferClear)
            {
                vDSP_vclr(state->ringBuffer, 1, kRing_Buffer_Frame_Size * kNumber_Of_Channels);
                state->isBufferClear = true;
            }
        }
        else
        {
            // Copy the buffers.
            memcpy(ioMainBuffer, state->ringBuffer + ringBufferFrameLocationStart * kNumber_Of_Channels, firstPartFrameSize * kNumber_Of_Channels * sizeof(Float32));
            memcpy((Float32*)ioMainBuffer + firstPartFrameSize * kNumber_Of_Channels, state->ringBuffer, secondPartFrameSize * kNumber_Of_Channels * sizeof(Float32));
            
            // Finally we'll apply the output volume to the buffer.
	    if(kEnableVolumeControl)
	    {
			Float32 masterVolume = atomic_load_explicit(&gVolume_Master_Value, memory_order_relaxed);
			vDSP_vsmul(ioMainBuffer, 1, &masterVolume, ioMainBuffer, 1, inIOBufferFrameSize * kNumber_Of_Channels);
	    }

		}
	}
#endif

	// From Application to SystemAudioBridge
	if(inOperationID == kAudioServerPlugInIOOperationMixOutput)
	{
		const Float64 timingSampleRate = copy_timing_sample_rate();
		const bool currentSampleTimeIsValid =
			(inIOCycleInfo->mCurrentTime.mFlags & kAudioTimeStampSampleTimeValid) != 0;
		const bool outputSampleTimeIsValid =
			(inIOCycleInfo->mOutputTime.mFlags & kAudioTimeStampSampleTimeValid) != 0;
		const Float64 outputSampleTime = outputSampleTimeIsValid
			? inIOCycleInfo->mOutputTime.mSampleTime
			: (currentSampleTimeIsValid
				? inIOCycleInfo->mCurrentTime.mSampleTime
				: (Float64)(inIOCycleInfo->mIOCycleCounter * inIOBufferFrameSize));
        
		// Do not interpret an unset proxy timestamp as a missed deadline. The HAL
		// explicitly marks which AudioTimeStamp fields are valid.
		if (currentSampleTimeIsValid && outputSampleTimeIsValid &&
			inIOCycleInfo->mCurrentTime.mSampleTime > outputSampleTime + inIOBufferFrameSize + kLatency_Frame_Size)
        {
#if DEBUG
			atomic_store_explicit(&gDebugOverloadPending, true, memory_order_relaxed);
#endif
            return kAudioHardwareUnspecifiedError;
        }

	#if kDevice_HasInput
		// MixOutput is called with one client's block. Clear the destination
        // once per cycle, then accumulate every client for the legacy loopback
        // input. The private transport publishes the blocks separately below.
        if (state->lastMixOutputSampleTime != outputSampleTime)
        {
            vDSP_vclr(
                state->ringBuffer + ringBufferFrameLocationStart * kNumber_Of_Channels,
                1,
                firstPartFrameSize * kNumber_Of_Channels
            );
            if (secondPartFrameSize > 0)
            {
                vDSP_vclr(
                    state->ringBuffer,
                    1,
                    secondPartFrameSize * kNumber_Of_Channels
			);
			}
			state->lastMixOutputSampleTime = outputSampleTime;
        }
        vDSP_vadd(
            (const Float32*)ioMainBuffer,
            1,
            state->ringBuffer + ringBufferFrameLocationStart * kNumber_Of_Channels,
            1,
            state->ringBuffer + ringBufferFrameLocationStart * kNumber_Of_Channels,
            1,
            firstPartFrameSize * kNumber_Of_Channels
        );
        if (secondPartFrameSize > 0)
        {
            vDSP_vadd(
                (const Float32*)ioMainBuffer + firstPartFrameSize * kNumber_Of_Channels,
                1,
                state->ringBuffer,
                1,
                state->ringBuffer,
                1,
                secondPartFrameSize * kNumber_Of_Channels
			);
		}
		#endif

        // Publish this client's interleaved block before Core Audio combines it
        // with other applications. The profile volume is a control surface for
        // media keys; the private transport remains full scale. CamiTune
        // consumes the control snapshot and applies the physical device's
        // measured transfer curve exactly once downstream.
        sabr_driver_transport_write(
            (const Float32*)ioMainBuffer,
            inIOBufferFrameSize,
            kNumber_Of_Channels,
            device_channel_layout_tag(),
			timingSampleRate,
            inDeviceObjectID,
            inClientID,
            inIOCycleInfo->mIOCycleCounter,
			outputSampleTime
        );
        
        // Save the last output time.
	#if kDevice_HasInput
		state->lastOutputSampleTime = outputSampleTime + inIOBufferFrameSize;
		state->isBufferClear = false;
	#endif
    }

Done:
	return theAnswer;
}

static OSStatus	SystemAudioBridge_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
	//	This is called at the end of an IO operation. This device doesn't do anything, so just check
	//	the arguments and return.
	
	#pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo, inDeviceObjectID)
	
	//	declare the local variables
	OSStatus theAnswer = 0;
	
	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_EndIOOperation: bad driver reference");
	FailWithAction(!is_device_object(inDeviceObjectID), theAnswer = kAudioHardwareBadObjectError, Done, "SystemAudioBridge_EndIOOperation: bad device ID");

Done:
	return theAnswer;
}
