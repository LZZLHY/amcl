/* OHOS专属libjsound JNI适配。Java继续使用上游MidiIn/OutDevice、Provider、
 * Receiver/Transmitter和软件合成器；只替换此目标原来的平台native适配单元。
 * 统一快照、64位时间戳、完整JNI验错及真实输入hold修复原适配中的必要缺口。
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "midi_core.h"
#include <jni.h>
#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

const char AMCL_Midi_BackendIdentity[]
    __attribute__((section(".amcl.midi"), used, visibility("default"))) = "AMCL_MIDI_OHOS_API24_OPTIONAL_V1";
static pthread_mutex_t ownerLock = PTHREAD_MUTEX_INITIALIZER;
static AmclMidiApi platformApi;
static AmclMidiManager* manager;
static void* hostLease;
static void* clientCodeLease;
static const AmclMidiCallbackAbiV1* callbackTable;
static int apiAttempted, apiStatus, managerStatus;
static char apiDiagnostic[320];

/* client整个有效期保活实际JNI映像，独立CLI的本地typed回调同样受此保护。
 * JVM先调用JNI_OnUnload再释放自身dlopen引用；成功清理才释放本租约，失败保留。 */
static void* keep_code(void) {
    Dl_info owner, actual;
    if (!dladdr((void*)&AMCL_Midi_BackendIdentity, &owner) || !owner.dli_fname || !owner.dli_fbase) return NULL;
    void* lease = dlopen(owner.dli_fname, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
    void* marker = lease ? dlsym(lease, "AMCL_Midi_BackendIdentity") : NULL;
    if (!marker || !dladdr(marker, &actual) || actual.dli_fbase != owner.dli_fbase) {
        if (lease) dlclose(lease);
        return NULL;
    }
    return lease;
}

static void throw_midi(JNIEnv* env, int code, int opening) {
    if ((*env)->ExceptionCheck(env)) return;
    const char* type = code == AMCL_MIDI_MEMORY ? "java/lang/OutOfMemoryError" :
        opening ? "javax/sound/midi/MidiUnavailableException" :
        code == AMCL_MIDI_INVALID ? "java/lang/IllegalArgumentException" : "java/lang/IllegalStateException";
    jclass cls = (*env)->FindClass(env, type);
    if (!cls) return;
    char text[384]; snprintf(text, sizeof(text), "OH_MIDI operation failed (status=%d)%s%s", code,
                            apiStatus ? ": " : "", apiStatus ? apiDiagnostic : "");
    (*env)->ThrowNew(env, cls, text); (*env)->DeleteLocalRef(env, cls);
}
/* 标记、工厂、只读表及三个typed入口必须位于同一正常HAP映像。NOLOAD引用一直
 * 保留到SDK client成功销毁；独立CLI使用本映像正常装载的同源回调。
 */
static const AmclMidiCallbackAbiV1* load_callbacks(void) {
    int (*embedded)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "amcl_jvm_is_embedded");
    if (!embedded || !embedded()) return amcl_midi_local_callbacks_v1();
    const AmclMidiCallbackAbiV1* (*factory)(void) =
        (const AmclMidiCallbackAbiV1* (*)(void))dlsym(RTLD_DEFAULT, "amcl_javasound_midi_callbacks_v1");
    Dl_info marker, owner, actual;
    if (!factory || !dladdr((void*)embedded, &marker) || !marker.dli_fbase ||
        !dladdr((void*)factory, &owner) || !owner.dli_fname || owner.dli_fbase != marker.dli_fbase) return NULL;
    void* lease = dlopen(owner.dli_fname, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
    if (!lease) return NULL;
    if (dlsym(lease, "amcl_javasound_midi_callbacks_v1") != (void*)factory) { dlclose(lease); return NULL; }
    const AmclMidiCallbackAbiV1* table = factory();
    if (!amcl_midi_callbacks_valid_v1(table)) { dlclose(lease); return NULL; }
    const void* addresses[] = {table, (void*)table->onDeviceChange, (void*)table->onError, (void*)table->onReceived};
    for (unsigned i = 0; i < sizeof(addresses)/sizeof(addresses[0]); ++i)
        if (!dladdr(addresses[i], &actual) || actual.dli_fbase != owner.dli_fbase) { dlclose(lease); return NULL; }
    hostLease = lease;
    return table;
}
/* API缺失允许Provider报告零设备；存在但接口不完整、创建失败、服务错误要抛出
 * 实际错误。临时client配额失败可由下一次查询重试，不污染成永久“无设备”。 */
static int get_manager(AmclMidiManager** output) {
    pthread_mutex_lock(&ownerLock);
    if (!apiAttempted) {
        apiAttempted = 1; apiStatus = amcl_midi_api_load(&platformApi, apiDiagnostic, sizeof(apiDiagnostic));
        if (apiStatus) fprintf(stderr, "AMCL MIDI capability: status=%d %s\n", apiStatus, apiDiagnostic);
    }
    int result = apiStatus;
    if (!result && !callbackTable) {
        callbackTable = load_callbacks();
        if (!callbackTable) result = AMCL_MIDI_ABI;
    }
    if (!result && !clientCodeLease) {
        clientCodeLease = keep_code();
        if (!clientCodeLease) result = AMCL_MIDI_ABI;
    }
    if (!result && !manager) {
        managerStatus = amcl_midi_manager_create(&manager, &platformApi, callbackTable);
        if (!managerStatus) fprintf(stderr, "AMCL MIDI backend ready: provider=libohmidi.so api=24 callbackAbi=1; real client created\n");
    }
    if (!result) result = managerStatus;
    *output = result ? NULL : manager;
    pthread_mutex_unlock(&ownerLock); return result;
}
__attribute__((destructor)) static void destroy_backend(void) {
    /* 异常SDK关闭会保留回调数据及provider/HAP租约；不能为零泄漏报告制造UAF。 */
    int result = amcl_midi_manager_destroy(manager);
    if (result) { fprintf(stderr, "AMCL MIDI shutdown retained live ownership: status=%d\n", result); return; }
    manager = NULL;
    amcl_midi_api_close(&platformApi);
    if (hostLease) { dlclose(hostLease); hostLease = NULL; }
    if (clientCodeLease) { void* lease = clientCodeLease; clientCodeLease = NULL; dlclose(lease); }
}
JNIEXPORT void JNICALL JNI_OnUnload(JavaVM* vm, void* reserved) {
    (void)vm; (void)reserved; destroy_backend();
}

/* SDK标准UTF-8精确转UTF-16，保留中文及非BMP设备名；NewStringUTF的modified
 * UTF-8合同不适用于四字节系统字符串。坏编码拒绝快照，不截断、不删除字符。
 */
static jstring utf8_string(JNIEnv* env, const char* text) {
    size_t length = strlen(text), at = 0, count = 0;
    if (length > INT_MAX / sizeof(jchar)) { throw_midi(env, AMCL_MIDI_MEMORY, 0); return NULL; }
    jchar* chars = malloc((length + 1) * sizeof(*chars));
    if (!chars) { throw_midi(env, AMCL_MIDI_MEMORY, 0); return NULL; }
    while (at < length) {
        uint32_t code, minimum; unsigned needed;
        unsigned char first = (unsigned char)text[at++];
        if (first < 0x80) { code = first; minimum = 0; needed = 0; }
        else if (first >= 0xc2 && first <= 0xdf) { code = first & 31u; minimum = 0x80; needed = 1; }
        else if (first >= 0xe0 && first <= 0xef) { code = first & 15u; minimum = 0x800; needed = 2; }
        else if (first >= 0xf0 && first <= 0xf4) { code = first & 7u; minimum = 0x10000; needed = 3; }
        else goto invalid;
        if (needed > length - at) goto invalid;
        for (unsigned i = 0; i < needed; ++i) {
            unsigned char next = (unsigned char)text[at++];
            if ((next & 0xc0u) != 0x80u) goto invalid;
            code = (code << 6) | (next & 63u);
        }
        if (code < minimum || code > 0x10ffffu || (code >= 0xd800 && code <= 0xdfff)) goto invalid;
        if (code <= 0xffff) chars[count++] = (jchar)code;
        else { code -= 0x10000; chars[count++] = (jchar)(0xd800 | (code >> 10)); chars[count++] = (jchar)(0xdc00 | (code & 1023)); }
    }
    jstring value = (*env)->NewString(env, chars, (jsize)count); free(chars); return value;
invalid:
    free(chars); throw_midi(env, AMCL_MIDI_INVALID, 0); return NULL;
}
static jobjectArray device_infos(JNIEnv* env, int direction) {
    AmclMidiManager* m = NULL; AmclMidiEndpoint* endpoints = NULL; size_t count = 0;
    int result = get_manager(&m);
    if (!result) result = amcl_midi_snapshot(m, direction, &endpoints, &count);
    if (result != 0 && result != AMCL_MIDI_API_UNAVAILABLE) { throw_midi(env, result, 0); return NULL; }
    if (count > INT_MAX) { free(endpoints); throw_midi(env, AMCL_MIDI_MEMORY, 0); return NULL; }
    if ((*env)->PushLocalFrame(env, 8) < 0) { free(endpoints); return NULL; }
    const char* name = direction ? "com/sun/media/sound/MidiOutDeviceProvider$MidiOutDeviceInfo" :
                                  "com/sun/media/sound/MidiInDeviceProvider$MidiInDeviceInfo";
    jclass cls = (*env)->FindClass(env, name); jobjectArray array = NULL;
    if (!cls) goto done;
    jmethodID constructor = (*env)->GetMethodID(env, cls, "<init>", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;II)V");
    if (!constructor) goto done;
    array = (*env)->NewObjectArray(env, (jsize)count, cls, NULL);
    if (!array) goto done;
    for (size_t i = 0; i < count; ++i) {
        if ((*env)->PushLocalFrame(env, 6) < 0) { array = NULL; break; }
        char display[384], vendor[40], description[96];
        const AmclMidiEndpoint* endpoint = &endpoints[i];
        snprintf(display, sizeof(display), "%s%s%s", endpoint->device.deviceName,
                 endpoint->port.name[0] ? " / " : "", endpoint->port.name);
        snprintf(vendor, sizeof(vendor), "0x%llx", (unsigned long long)endpoint->device.vendorId);
        snprintf(description, sizeof(description), "%s MIDI %s", endpoint->device.deviceType == OH_MIDI_DEVICE_TYPE_USB ? "USB" : "BLE", direction ? "output" : "input");
        jstring a = utf8_string(env, display), b = NULL, c = NULL, d = NULL;
        if (a) b = utf8_string(env, vendor);
        if (b) c = utf8_string(env, description);
        if (c) d = utf8_string(env, "unknown"); /* SDK未给固件版本，不伪造。 */
        jobject info = d ? (*env)->NewObject(env, cls, constructor, a, b, c, d, (jint)i, (jint)endpoint->token) : NULL;
        if (info) (*env)->SetObjectArrayElement(env, array, (jsize)i, info);
        int failed = !info || (*env)->ExceptionCheck(env);
        (*env)->PopLocalFrame(env, NULL);
        if (failed) { array = NULL; break; }
    }
done:
    free(endpoints); return (jobjectArray)(*env)->PopLocalFrame(env, array);
}
JNIEXPORT jobjectArray JNICALL Java_com_sun_media_sound_MidiInDeviceProvider_nGetDeviceInfos(JNIEnv* env, jclass cls) {
    (void)cls; return device_infos(env, 0);
}
JNIEXPORT jobjectArray JNICALL Java_com_sun_media_sound_MidiOutDeviceProvider_nGetDeviceInfos(JNIEnv* env, jclass cls) {
    (void)cls; return device_infos(env, 1);
}
/* 旧JNI符号仍保留。新的OHOS Java路径只用一致快照；这些兼容入口不会把同一
 * Java Info的四个字符串分散成四次易竞态的枚举。 */
static jint legacy_count(JNIEnv* env, int direction) {
    jobjectArray infos = device_infos(env, direction);
    if (!infos) return 0;
    jint count = (*env)->GetArrayLength(env, infos); (*env)->DeleteLocalRef(env, infos); return count;
}
static jstring legacy_string(JNIEnv* env, int direction, jint index, const char* getter) {
    jobjectArray infos = device_infos(env, direction);
    if (!infos) return NULL;
    jstring value = NULL;
    if (index < 0 || index >= (*env)->GetArrayLength(env, infos)) throw_midi(env, AMCL_MIDI_STALE, 0);
    else {
        jobject info = (*env)->GetObjectArrayElement(env, infos, index);
        if (info) {
            jclass cls = (*env)->GetObjectClass(env, info);
            jmethodID method = cls ? (*env)->GetMethodID(env, cls, getter, "()Ljava/lang/String;") : NULL;
            if (method) { value = (jstring)(*env)->CallObjectMethod(env, info, method); if ((*env)->ExceptionCheck(env)) value = NULL; }
            if (cls) (*env)->DeleteLocalRef(env, cls);
            (*env)->DeleteLocalRef(env, info);
        }
    }
    (*env)->DeleteLocalRef(env, infos); return value;
}
#define AMCL_LEGACY_PROVIDER(Part, direction) \
 JNIEXPORT jint JNICALL Java_com_sun_media_sound_##Part##DeviceProvider_nGetNumDevices(JNIEnv* e,jclass c) { (void)c; return legacy_count(e,direction); } \
 JNIEXPORT jstring JNICALL Java_com_sun_media_sound_##Part##DeviceProvider_nGetName(JNIEnv* e,jclass c,jint i) { (void)c;return legacy_string(e,direction,i,"getName"); } \
 JNIEXPORT jstring JNICALL Java_com_sun_media_sound_##Part##DeviceProvider_nGetVendor(JNIEnv* e,jclass c,jint i) { (void)c;return legacy_string(e,direction,i,"getVendor"); } \
 JNIEXPORT jstring JNICALL Java_com_sun_media_sound_##Part##DeviceProvider_nGetDescription(JNIEnv* e,jclass c,jint i) { (void)c;return legacy_string(e,direction,i,"getDescription"); } \
 JNIEXPORT jstring JNICALL Java_com_sun_media_sound_##Part##DeviceProvider_nGetVersion(JNIEnv* e,jclass c,jint i) { (void)c;return legacy_string(e,direction,i,"getVersion"); }
AMCL_LEGACY_PROVIDER(MidiIn, 0)
AMCL_LEGACY_PROVIDER(MidiOut, 1)
#undef AMCL_LEGACY_PROVIDER

static jlong open_device(JNIEnv* env, jint token, int direction) {
    AmclMidiManager* m = NULL; uint64_t handle = 0; int result = get_manager(&m);
    if (!result) result = amcl_midi_open(m, token, direction, &handle);
    if (result) throw_midi(env, result, 1);
    return (jlong)handle;
}
static AmclMidiUse* acquire(JNIEnv* env, jlong token, int direction) {
    AmclMidiManager* m = NULL; int result = get_manager(&m);
    AmclMidiUse* use = !result ? amcl_midi_acquire(m, (uint64_t)token, direction) : NULL;
    if (!use) throw_midi(env, result ? result : AMCL_MIDI_CLOSED, 0);
    return use;
}
static void close_device(JNIEnv* env, jlong token) {
    if (!token) return;
    AmclMidiManager* m = NULL; int result = get_manager(&m);
    if (!result) result = amcl_midi_close(m, (uint64_t)token);
    if (result && result != AMCL_MIDI_CLOSED) throw_midi(env, result, 0);
}
static jlong position(JNIEnv* env, jlong token, int direction) {
    (void)env; AmclMidiManager* m = NULL;
    if (get_manager(&m)) return -1;
    AmclMidiUse* use = amcl_midi_acquire(m, (uint64_t)token, direction);
    if (!use) return -1;
    int64_t value = amcl_midi_position(use); amcl_midi_release(use); return (jlong)value;
}
#define AMCL_DEVICE_ENTRIES(Part, direction) \
 JNIEXPORT jlong JNICALL Java_com_sun_media_sound_##Part##Device_nOpen(JNIEnv* e,jobject o,jint t) { (void)o;return open_device(e,t,direction); } \
 JNIEXPORT void JNICALL Java_com_sun_media_sound_##Part##Device_nClose(JNIEnv* e,jobject o,jlong t) { (void)o;close_device(e,t); } \
 JNIEXPORT jlong JNICALL Java_com_sun_media_sound_##Part##Device_nGetTimeStamp(JNIEnv* e,jobject o,jlong t) { (void)o;return position(e,t,direction); }
AMCL_DEVICE_ENTRIES(MidiIn, 0)
AMCL_DEVICE_ENTRIES(MidiOut, 1)
#undef AMCL_DEVICE_ENTRIES
JNIEXPORT void JNICALL Java_com_sun_media_sound_MidiInDevice_nStart(JNIEnv* env, jobject object, jlong token) {
    (void)object; AmclMidiUse* use = acquire(env, token, 0); if (!use) return;
    int result = amcl_midi_start(use); amcl_midi_release(use); if (result) throw_midi(env, result, 1);
}
JNIEXPORT void JNICALL Java_com_sun_media_sound_MidiInDevice_nStop(JNIEnv* env, jobject object, jlong token) {
    (void)object; if (!token) return;
    AmclMidiUse* use = acquire(env, token, 0); if (!use) return;
    int result = amcl_midi_stop(use); amcl_midi_release(use); if (result) throw_midi(env, result, 0);
}
JNIEXPORT void JNICALL Java_com_sun_media_sound_MidiOutDevice_nSendShortMessage(JNIEnv* env, jobject object, jlong token, jint packed, jlong micros) {
    (void)object; AmclMidiUse* use = acquire(env, token, 1); if (!use) return;
    int result = amcl_midi_send_short(use, (uint32_t)packed, (int64_t)micros); amcl_midi_release(use);
    if (result) throw_midi(env, result, 0);
}
JNIEXPORT void JNICALL Java_com_sun_media_sound_MidiOutDevice_nSendLongMessage(JNIEnv* env, jobject object, jlong token, jbyteArray bytes, jint size, jlong micros) {
    (void)object;
    if (!bytes || size <= 0 || size > (*env)->GetArrayLength(env, bytes)) { throw_midi(env, AMCL_MIDI_INVALID, 0); return; }
    AmclMidiUse* use = acquire(env, token, 1); if (!use) return;
    jbyte* data = (*env)->GetByteArrayElements(env, bytes, NULL);
    if (!data) { amcl_midi_release(use); return; }
    int result = amcl_midi_send_long(use, (const uint8_t*)data, (size_t)size, (int64_t)micros);
    (*env)->ReleaseByteArrayElements(env, bytes, data, JNI_ABORT); amcl_midi_release(use);
    if (result) throw_midi(env, result, 0);
}
JNIEXPORT void JNICALL Java_com_sun_media_sound_MidiInDevice_nGetMessages(JNIEnv* env, jobject object, jlong token) {
    AmclMidiManager* m = NULL; if (get_manager(&m)) return;
    /* 关闭与Java线程启动/退出可竞态；关闭后无法取得新hold就是正常结束。 */
    AmclMidiUse* use = amcl_midi_acquire(m, (uint64_t)token, 0); if (!use) return;
    int result = amcl_midi_read_begin(use); if (result) { amcl_midi_release(use); throw_midi(env, result, 0); return; }
    Dl_info owner, exported; void* codeLease = NULL;
    if (dladdr((void*)&Java_com_sun_media_sound_MidiInDevice_nGetMessages, &owner) && owner.dli_fname)
        codeLease = dlopen(owner.dli_fname, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
    void* entry = codeLease ? dlsym(codeLease, "Java_com_sun_media_sound_MidiInDevice_nGetMessages") : NULL;
    if (!entry || !dladdr(entry, &exported) || exported.dli_fbase != owner.dli_fbase) {
        if (codeLease) dlclose(codeLease);
        amcl_midi_read_end(use); amcl_midi_release(use); throw_midi(env, AMCL_MIDI_ABI, 0); return;
    }
    if ((*env)->PushLocalFrame(env, 4) < 0) goto release;
    jclass cls = (*env)->GetObjectClass(env, object);
    jmethodID shortMethod = cls ? (*env)->GetMethodID(env, cls, "callbackShortMessage", "(IJ)V") : NULL;
    jmethodID longMethod = shortMethod ? (*env)->GetMethodID(env, cls, "callbackLongMessage", "([BJ)V") : NULL;
    if (longMethod) while (1) {
        AmclMidiMessage message; result = amcl_midi_next(use, &message);
        if (result != 1) { if (result) throw_midi(env, result, 0); break; }
        if (!message.isLong) (*env)->CallVoidMethod(env, object, shortMethod, (jint)message.packed, (jlong)message.microseconds);
        else {
            jbyteArray data = (*env)->NewByteArray(env, (jsize)message.length);
            if (!data) break;
            (*env)->SetByteArrayRegion(env, data, 0, (jsize)message.length, (const jbyte*)message.data);
            if (!(*env)->ExceptionCheck(env)) (*env)->CallVoidMethod(env, object, longMethod, data, (jlong)message.microseconds);
            (*env)->DeleteLocalRef(env, data);
        }
        if ((*env)->ExceptionCheck(env)) break; /* 原用户异常原样传播，不能带pending异常继续JNI。 */
    }
    (*env)->PopLocalFrame(env, NULL);
release:
    amcl_midi_read_end(use); amcl_midi_release(use); dlclose(codeLease);
}
