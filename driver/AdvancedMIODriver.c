// AdvancedMIO virtual audio device (CoreAudio AudioServerPlugIn).
//
// Shows up as an output called "AdvancedMIO" in Control Center / System Settings ▸ Sound. Whatever is played to it
// is looped back to the device's own input stream, which the AdvancedMIO app captures and fans out to the real
// outputs with per-device delay. Fixed format: 48 kHz, stereo, 32-bit float.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>

#define kDeviceUID   "AdvancedMIO_Device"
#define kDeviceName  "AdvancedMIO"
#define kMaker       "AdvancedMIO"
#define kSampleRate  48000.0
#define kChannels    2
#define kRingFrames  16384          // power of two; also the zero-timestamp period
#define kAppBundleID "com.kusbeoms.advancedmio"
#define kDbMin       -64.0f
// Custom device property: number of client processes (other than the AdvancedMIO app) currently playing to the device.
// The app polls it so it only captures — and only shows the macOS microphone indicator — while something is playing.
#define kPlaybackClientsSelector ((AudioObjectPropertySelector)'amip')

enum {
    kObj_PlugIn       = kAudioObjectPlugInObject,
    kObj_Device       = 2,
    kObj_StreamInput  = 3,
    kObj_StreamOutput = 4,
    kObj_Volume       = 5,
    kObj_Mute         = 6,
};

static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;
static AudioServerPlugInHostRef gHost = NULL;
static UInt64 gIOCount = 0;
static UInt64 gAnchorHostTime = 0;
static Float64 gHostTicksPerFrame = 0;
static Float32 gRing[kRingFrames * kChannels];
static SInt64 gWrittenEnd = 0;      // sample time just past the newest frame written
static Float32 gVolume = 1.0f;      // master scalar 0…1 (system volume); 1.0 = unity (0 dB), no boost
static UInt32 gMute = 0;
static Float32 gAppliedGain = 1.0f; // IO thread only: gain at the end of the previous cycle (for click-free ramps)
static UInt32 gPlayClients = 0;
static UInt32 gOurClients[8];       // client IDs of the AdvancedMIO app (excluded from gPlayClients)
static UInt32 gOurCount = 0;

// Shared-memory copy of the loopback ring. The app reads it directly instead of opening the device's input stream,
// so macOS never shows the orange microphone indicator. (The input stream stays as a fallback.)
#define kShmName   "/AdvancedMIO.ring"
#define kShmMagic  0x414D494Fu      // 'AMIO'
typedef struct {
    uint32_t magic, version, sampleRate, ringFrames;
    volatile int64_t writeEnd;      // sample time just past the newest frame
    Float32 data[kRingFrames * kChannels];
} SharedRing;
static SharedRing *gShared = NULL;

static void OpenSharedRing(void) {
    int fd = shm_open(kShmName, O_CREAT | O_RDWR, 0666);
    if (fd < 0) return;
    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size == 0) ftruncate(fd, sizeof(SharedRing));
    fchmod(fd, 0666);                // the app runs as the logged-in user, the driver as _coreaudiod
    void *m = mmap(NULL, sizeof(SharedRing), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (m == MAP_FAILED) return;
    SharedRing *r = m;
    r->version = 1; r->sampleRate = (uint32_t)kSampleRate; r->ringFrames = kRingFrames;
    __atomic_store_n(&r->writeEnd, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&r->magic, kShmMagic, __ATOMIC_RELEASE);
    gShared = r;
}

// MARK: - Helpers

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = sizeof(Float32) * kChannels;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = sizeof(Float32) * kChannels;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

static bool IsStream(AudioObjectID o) { return o == kObj_StreamInput || o == kObj_StreamOutput; }
static bool IsControl(AudioObjectID o) { return o == kObj_Volume || o == kObj_Mute; }

// Linear in dB from -64 dB (0) to 0 dB (1): system volume 100 is unity, the device is never boosted digitally.
static Float32 ScalarToDb(Float32 s) { s = s < 0 ? 0 : (s > 1 ? 1 : s); return kDbMin + (0.0f - kDbMin) * s; }
static Float32 DbToScalar(Float32 db) { Float32 s = (db - kDbMin) / (0.0f - kDbMin); return s < 0 ? 0 : (s > 1 ? 1 : s); }
static Float32 ScalarToGain(Float32 s) { return s <= 0 ? 0 : powf(10.0f, ScalarToDb(s) / 20.0f); }

static bool IsOurClient(UInt32 id) {       // call with gMutex held
    for (UInt32 i = 0; i < gOurCount; i++) if (gOurClients[i] == id) return true;
    return false;
}

static void NotifyChanged(AudioObjectID obj, AudioObjectPropertySelector sel) {
    if (!gHost) return;
    AudioObjectPropertyAddress a = { sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    gHost->PropertiesChanged(gHost, obj, 1, &a);
}

// Property reply helpers. `out == NULL` means "size query only".
#define HIT() (*has = true)
#define RET_VALUE(type, val) do { HIT(); *outSize = sizeof(type); \
    if (out) { if (inSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; *(type *)out = (val); } \
    return kAudioHardwareNoError; } while (0)
#define RET_STRING(cstr) do { HIT(); *outSize = sizeof(CFStringRef); \
    if (out) { if (inSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError; \
        *(CFStringRef *)out = CFStringCreateWithCString(NULL, cstr, kCFStringEncodingUTF8); } \
    return kAudioHardwareNoError; } while (0)

static OSStatus ReplyIDs(const AudioObjectID *ids, UInt32 n, UInt32 inSize, UInt32 *outSize, void *out, bool *has) {
    *has = true;
    if (!out) { *outSize = n * sizeof(AudioObjectID); return kAudioHardwareNoError; }
    UInt32 fit = inSize / sizeof(AudioObjectID);
    if (fit < n) n = fit;
    memcpy(out, ids, n * sizeof(AudioObjectID));
    *outSize = n * sizeof(AudioObjectID);
    return kAudioHardwareNoError;
}

// MARK: - Properties

static OSStatus Property(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q,
                         UInt32 inSize, UInt32 *outSize, void *out, bool *has, bool *settable) {
    *has = false; *settable = false; *outSize = 0;
    if (obj != kObj_PlugIn && obj != kObj_Device && !IsStream(obj) && !IsControl(obj)) return kAudioHardwareBadObjectError;

    if (obj == kObj_PlugIn) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:   RET_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:       RET_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner:       RET_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RET_STRING(kMaker);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: { AudioObjectID d = kObj_Device; return ReplyIDs(&d, 1, inSize, outSize, out, has); }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (qSize != sizeof(CFStringRef) || !q) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef *)q;
            bool match = uid && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo;
            RET_VALUE(AudioObjectID, match ? kObj_Device : kAudioObjectUnknown);
        }
        case kAudioPlugInPropertyResourceBundle: RET_STRING("");
        }
        return kAudioHardwareUnknownPropertyError;
    }

    if (obj == kObj_Device) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:   RET_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:       RET_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:       RET_VALUE(AudioObjectID, kObj_PlugIn);
        case kAudioObjectPropertyName:        RET_STRING(kDeviceName);
        case kAudioObjectPropertyManufacturer: RET_STRING(kMaker);
        case kAudioDevicePropertyDeviceUID:   RET_STRING(kDeviceUID);
        case kAudioDevicePropertyModelUID:    RET_STRING("AdvancedMIO_Model");
        case kAudioObjectPropertyOwnedObjects: {
            AudioObjectID s[4] = { kObj_StreamInput, kObj_StreamOutput, kObj_Volume, kObj_Mute };
            return ReplyIDs(s, 4, inSize, outSize, out, has);
        }
        case kAudioDevicePropertyStreams: {
            AudioObjectID s[2]; UInt32 n = 0;
            if (a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == kAudioObjectPropertyScopeInput)  s[n++] = kObj_StreamInput;
            if (a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == kAudioObjectPropertyScopeOutput) s[n++] = kObj_StreamOutput;
            return ReplyIDs(s, n, inSize, outSize, out, has);
        }
        case kAudioObjectPropertyControlList: {
            AudioObjectID c[2] = { kObj_Volume, kObj_Mute };
            return ReplyIDs(c, 2, inSize, outSize, out, has);
        }
        case kPlaybackClientsSelector: {
            pthread_mutex_lock(&gMutex); UInt32 n = gPlayClients; pthread_mutex_unlock(&gMutex);
            RET_VALUE(UInt32, n);
        }
        case kAudioDevicePropertyRelatedDevices: { AudioObjectID d = kObj_Device; return ReplyIDs(&d, 1, inSize, outSize, out, has); }
        case kAudioDevicePropertyTransportType: RET_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyClockDomain:   RET_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RET_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gMutex); UInt32 r = gIOCount > 0; pthread_mutex_unlock(&gMutex);
            RET_VALUE(UInt32, r);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            RET_VALUE(UInt32, a->mScope == kAudioObjectPropertyScopeOutput ? 1 : 0);   // output only: never the default mic
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            RET_VALUE(UInt32, a->mScope == kAudioObjectPropertyScopeOutput ? 1 : 0);
        case kAudioDevicePropertyLatency:       RET_VALUE(UInt32, 0);
        case kAudioDevicePropertySafetyOffset:  RET_VALUE(UInt32, 0);
        case kAudioDevicePropertyIsHidden:      RET_VALUE(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: RET_VALUE(UInt32, kRingFrames);
        case kAudioDevicePropertyNominalSampleRate: RET_VALUE(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange r = { kSampleRate, kSampleRate };
            RET_VALUE(AudioValueRange, r);
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            HIT(); *outSize = 2 * sizeof(UInt32);
            if (out) { if (inSize < *outSize) return kAudioHardwareBadPropertySizeError; ((UInt32 *)out)[0] = 1; ((UInt32 *)out)[1] = 2; }
            return kAudioHardwareNoError;
        }
        }
        return kAudioHardwareUnknownPropertyError;
    }

    if (IsControl(obj)) {
        bool vol = obj == kObj_Volume;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RET_VALUE(AudioClassID, vol ? kAudioLevelControlClassID : kAudioBooleanControlClassID);
        case kAudioObjectPropertyClass:     RET_VALUE(AudioClassID, vol ? kAudioVolumeControlClassID : kAudioMuteControlClassID);
        case kAudioObjectPropertyOwner:     RET_VALUE(AudioObjectID, kObj_Device);
        case kAudioObjectPropertyOwnedObjects: return ReplyIDs(NULL, 0, inSize, outSize, out, has);
        case kAudioControlPropertyScope:    RET_VALUE(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
        case kAudioControlPropertyElement:  RET_VALUE(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
        }
        if (vol) switch (a->mSelector) {
        case kAudioLevelControlPropertyScalarValue: *settable = true; RET_VALUE(Float32, gVolume);
        case kAudioLevelControlPropertyDecibelValue: *settable = true; RET_VALUE(Float32, ScalarToDb(gVolume));
        case kAudioLevelControlPropertyDecibelRange: { AudioValueRange r = { kDbMin, 0.0 }; RET_VALUE(AudioValueRange, r); }
        case kAudioLevelControlPropertyConvertScalarToDecibels:
            HIT(); *outSize = sizeof(Float32);
            if (out) { if (inSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError; *(Float32 *)out = ScalarToDb(*(Float32 *)out); }
            return kAudioHardwareNoError;
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            HIT(); *outSize = sizeof(Float32);
            if (out) { if (inSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError; *(Float32 *)out = DbToScalar(*(Float32 *)out); }
            return kAudioHardwareNoError;
        } else if (a->mSelector == kAudioBooleanControlPropertyValue) { *settable = true; RET_VALUE(UInt32, gMute); }
        return kAudioHardwareUnknownPropertyError;
    }

    // Streams
    bool isInput = obj == kObj_StreamInput;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass:   RET_VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass:       RET_VALUE(AudioClassID, kAudioStreamClassID);
    case kAudioObjectPropertyOwner:       RET_VALUE(AudioObjectID, kObj_Device);
    case kAudioObjectPropertyName:        RET_STRING(isInput ? "AdvancedMIO Capture" : "AdvancedMIO Output");
    case kAudioStreamPropertyIsActive:    RET_VALUE(UInt32, 1);
    case kAudioStreamPropertyDirection:   RET_VALUE(UInt32, isInput ? 1 : 0);
    case kAudioStreamPropertyTerminalType: RET_VALUE(UInt32, isInput ? kAudioStreamTerminalTypeLine : kAudioStreamTerminalTypeSpeaker);
    case kAudioStreamPropertyStartingChannel: RET_VALUE(UInt32, 1);
    case kAudioStreamPropertyLatency:     RET_VALUE(UInt32, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: RET_VALUE(AudioStreamBasicDescription, StreamFormat());
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription r = { StreamFormat(), { kSampleRate, kSampleRate } };
        RET_VALUE(AudioStreamRangedDescription, r);
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

// MARK: - Driver interface

static HRESULT QueryInterface(void *self, REFIID iid, LPVOID *out) {
    if (!out) return E_POINTER;
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, iid);
    HRESULT r = E_NOINTERFACE;
    if (CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gMutex); gRefCount++; pthread_mutex_unlock(&gMutex);
        *out = self; r = S_OK;
    }
    CFRelease(req);
    return r;
}
static ULONG AddRef(void *self) {
    pthread_mutex_lock(&gMutex); ULONG n = ++gRefCount; pthread_mutex_unlock(&gMutex); return n;
}
static ULONG Release(void *self) {
    pthread_mutex_lock(&gMutex); if (gRefCount > 0) gRefCount--; ULONG n = gRefCount; pthread_mutex_unlock(&gMutex); return n;
}

static OSStatus Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef host) {
    gHost = host;
    struct mach_timebase_info tb; mach_timebase_info(&tb);
    Float64 ticksPerSecond = 1e9 * (Float64)tb.denom / (Float64)tb.numer;
    gHostTicksPerFrame = ticksPerSecond / kSampleRate;
    OpenSharedRing();
    return kAudioHardwareNoError;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *o) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID o) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) {
    if (c && c->mBundleID && CFStringCompare(c->mBundleID, CFSTR(kAppBundleID), 0) == kCFCompareEqualTo) {
        pthread_mutex_lock(&gMutex);
        if (gOurCount < 8) gOurClients[gOurCount++] = c->mClientID;
        pthread_mutex_unlock(&gMutex);
    }
    return kAudioHardwareNoError;
}
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) {
    if (c) {
        pthread_mutex_lock(&gMutex);
        for (UInt32 i = 0; i < gOurCount; i++) if (gOurClients[i] == c->mClientID) { gOurClients[i] = gOurClients[--gOurCount]; break; }
        pthread_mutex_unlock(&gMutex);
    }
    return kAudioHardwareNoError;
}
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void *i) { return kAudioHardwareNoError; }
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void *i) { return kAudioHardwareNoError; }

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a) {
    UInt32 sz; bool has, set;
    Property(o, a, 0, NULL, 0, &sz, NULL, &has, &set);
    return has;
}
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *out) {
    UInt32 sz; bool has, set;
    OSStatus s = Property(o, a, 0, NULL, 0, &sz, NULL, &has, &set);
    if (!has) return s ? s : kAudioHardwareUnknownPropertyError;
    // Format / rate are "settable" so clients that insist on writing them get a clean accept (same value) or refusal.
    *out = set
        || (o == kObj_Device && a->mSelector == kAudioDevicePropertyNominalSampleRate)
        || (IsStream(o) && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat));
    return kAudioHardwareNoError;
}
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *size) {
    bool has, set;
    OSStatus s = Property(o, a, qs, q, 0, size, NULL, &has, &set);
    return has ? s : (s ? s : kAudioHardwareUnknownPropertyError);
}
static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 inSize, UInt32 *outSize, void *out) {
    bool has, set;
    OSStatus s = Property(o, a, qs, q, inSize, outSize, out, &has, &set);
    return has ? s : (s ? s : kAudioHardwareUnknownPropertyError);
}
static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 size, const void *data) {
    if (o == kObj_Device && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (size != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *(const Float64 *)data == kSampleRate ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
    }
    if (IsStream(o) && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (size != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription *f = data;
        return (f->mSampleRate == kSampleRate && f->mFormatID == kAudioFormatLinearPCM && f->mChannelsPerFrame == kChannels
                && (f->mFormatFlags & kAudioFormatFlagIsFloat) && f->mBitsPerChannel == 32)
            ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
    }
    if (IsControl(o)) {
        if (o == kObj_Volume && (a->mSelector == kAudioLevelControlPropertyScalarValue || a->mSelector == kAudioLevelControlPropertyDecibelValue)) {
            if (size != sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            Float32 v = *(const Float32 *)data;
            gVolume = a->mSelector == kAudioLevelControlPropertyScalarValue ? (v < 0 ? 0 : (v > 1 ? 1 : v)) : DbToScalar(v);
            NotifyChanged(o, kAudioLevelControlPropertyScalarValue);
            NotifyChanged(o, kAudioLevelControlPropertyDecibelValue);
            return kAudioHardwareNoError;
        }
        if (o == kObj_Mute && a->mSelector == kAudioBooleanControlPropertyValue) {
            if (size != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            gMute = *(const UInt32 *)data != 0;
            NotifyChanged(o, kAudioBooleanControlPropertyValue);
            return kAudioHardwareNoError;
        }
    }
    return kAudioHardwareUnsupportedOperationError;
}

// MARK: IO

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 client) {
    if (o != kObj_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gIOCount == 0) {
        gAnchorHostTime = mach_absolute_time();
        memset(gRing, 0, sizeof gRing);
        gWrittenEnd = 0;
        if (gShared) { memset(gShared->data, 0, sizeof gShared->data); __atomic_store_n(&gShared->writeEnd, 0, __ATOMIC_RELEASE); }
    }
    gIOCount++;
    if (!IsOurClient(client)) gPlayClients++;
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}
static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 client) {
    if (o != kObj_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gIOCount > 0) gIOCount--;
    if (!IsOurClient(client) && gPlayClients > 0) gPlayClients--;
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 client, Float64 *sampleTime, UInt64 *hostTime, UInt64 *seed) {
    if (o != kObj_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    UInt64 ticksPerRing = (UInt64)(gHostTicksPerFrame * kRingFrames);
    UInt64 elapsed = mach_absolute_time() - gAnchorHostTime;
    UInt64 rings = ticksPerRing ? elapsed / ticksPerRing : 0;
    *sampleTime = (Float64)(rings * kRingFrames);
    *hostTime = gAnchorHostTime + rings * ticksPerRing;
    *seed = 1;
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 client, UInt32 op, Boolean *willDo, Boolean *inPlace) {
    *willDo = (op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix);
    *inPlace = true;
    return kAudioHardwareNoError;
}
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 client, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *i) { return kAudioHardwareNoError; }
static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 client, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *i) { return kAudioHardwareNoError; }

static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, AudioObjectID stream, UInt32 client, UInt32 op,
                              UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle, void *main, void *secondary) {
    if (!main) return kAudioHardwareNoError;
    Float32 *buf = main;
    if (op == kAudioServerPlugInIOOperationWriteMix) {
        SInt64 t = (SInt64)cycle->mOutputTime.mSampleTime;
        Float32 target = gMute ? 0.0f : ScalarToGain(gVolume);
        Float32 g = gAppliedGain, step = (target - g) / (Float32)frames;
        for (UInt32 i = 0; i < frames; i++) {
            g += step;
            UInt32 slot = (UInt32)((t + i) & (kRingFrames - 1)) * kChannels;
            gRing[slot] = buf[i * kChannels] * g;
            gRing[slot + 1] = buf[i * kChannels + 1] * g;
            if (gShared) { gShared->data[slot] = gRing[slot]; gShared->data[slot + 1] = gRing[slot + 1]; }
        }
        gAppliedGain = target;
        SInt64 end = t + frames;
        if (end > __atomic_load_n(&gWrittenEnd, __ATOMIC_RELAXED)) __atomic_store_n(&gWrittenEnd, end, __ATOMIC_RELAXED);
        if (gShared && end > gShared->writeEnd) __atomic_store_n(&gShared->writeEnd, end, __ATOMIC_RELEASE);
    } else if (op == kAudioServerPlugInIOOperationReadInput) {
        SInt64 t = (SInt64)cycle->mInputTime.mSampleTime;
        SInt64 end = __atomic_load_n(&gWrittenEnd, __ATOMIC_RELAXED);
        for (UInt32 i = 0; i < frames; i++) {
            SInt64 idx = t + i;
            if (idx >= end || idx < end - kRingFrames) {      // not written (yet / any more): silence, never stale audio
                buf[i * kChannels] = 0; buf[i * kChannels + 1] = 0;
            } else {
                UInt32 slot = (UInt32)(idx & (kRingFrames - 1)) * kChannels;
                buf[i * kChannels] = gRing[slot]; buf[i * kChannels + 1] = gRing[slot + 1];
            }
        }
    }
    return kAudioHardwareNoError;
}

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddDeviceClient, RemoveDeviceClient,
    PerformDeviceConfigurationChange, AbortDeviceConfigurationChange, HasProperty, IsPropertySettable,
    GetPropertyDataSize, GetPropertyData, SetPropertyData, StartIO, StopIO, GetZeroTimeStamp,
    WillDoIOOperation, BeginIOOperation, DoIOOperation, EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriver = &gInterfacePtr;

__attribute__((visibility("default")))
void *AdvancedMIO_Create(CFAllocatorRef allocator, CFUUIDRef requestedType) {
    if (!CFEqual(requestedType, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriver;
}
