/*
 * OHOS 专属 PortMixer JNI，替换该目标的两个上游 PortMixer C 适配单元。
 * 使用标准 JavaSound 类/类型和真实OHAudio快照；不构造假Float/Boolean控制，不把没有
 * SDK setter的系统音量映射成本地变量。其他平台继续编译原上游JNI实现。
 */
#include "ports_ohos.h"
#include <jni.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ohaudio/native_audio_device_base.h>

/* 保留首个Java异常，所有查类/分配失败路径立即返回，不能在pending异常下继续JNI。 */
static void throw_ports(JNIEnv *env, const char *type, int code, int native_error)
{
    jclass cls; char message[128];
    if ((*env)->ExceptionCheck(env)) return;
    cls = (*env)->FindClass(env, type);
    if (!cls) return;
    snprintf(message, sizeof(message), "OHAudio port operation failed (result=%d, native=%d)", code, native_error);
    (*env)->ThrowNew(env, cls, message); (*env)->DeleteLocalRef(env, cls);
}

static void throw_result(JNIEnv *env, int code, int native_error, int opening)
{
    const char *type = code == AMCL_PORTS_NO_MEMORY ? "java/lang/OutOfMemoryError" :
        opening ? "javax/sound/sampled/LineUnavailableException" : "java/lang/IllegalStateException";
    throw_ports(env, type, code, native_error);
}

/* JNI NewStringUTF接受modified UTF-8，不能直接消费系统标准UTF-8中的4字节字符。
 * 在有界输入中精确解码为UTF-16，非BMP写surrogate pair；坏编码明确失败，不删为ASCII。 */
static jstring utf8_string(JNIEnv *env, const char *text)
{
    const unsigned char *bytes = (const unsigned char *)text;
    size_t length, at = 0, count = 0;
    jchar *chars; jstring value;
    if (!text) { throw_result(env, AMCL_PORTS_INVALID, 0, 0); return NULL; }
    length = strlen(text);
    if (length > 65535u) { throw_result(env, AMCL_PORTS_INVALID, 0, 0); return NULL; }
    chars = (jchar *)malloc((length + 1) * sizeof(jchar));
    if (!chars) { throw_result(env, AMCL_PORTS_NO_MEMORY, 0, 0); return NULL; }
    while (at < length) {
        uint32_t code, minimum; unsigned needed, i;
        unsigned char first = bytes[at++];
        if (first < 0x80) { code = first; minimum = 0; needed = 0; }
        else if (first >= 0xc2 && first <= 0xdf) { code = first & 31u; minimum = 0x80; needed = 1; }
        else if (first >= 0xe0 && first <= 0xef) { code = first & 15u; minimum = 0x800; needed = 2; }
        else if (first >= 0xf0 && first <= 0xf4) { code = first & 7u; minimum = 0x10000; needed = 3; }
        else goto invalid;
        if (needed > length - at) goto invalid;
        for (i = 0; i < needed; ++i) {
            unsigned char next = bytes[at++]; if ((next & 0xc0u) != 0x80u) goto invalid;
            code = (code << 6) | (next & 63u);
        }
        if (code < minimum || code > 0x10ffffu || (code >= 0xd800u && code <= 0xdfffu)) goto invalid;
        if (code <= 0xffffu) chars[count++] = (jchar)code;
        else { code -= 0x10000u; chars[count++] = (jchar)(0xd800u | (code >> 10)); chars[count++] = (jchar)(0xdc00u | (code & 1023u)); }
    }
    value = (*env)->NewString(env, chars, (jsize)count); free(chars); return value;
invalid:
    free(chars); throw_result(env, AMCL_PORTS_INVALID, 0, 0); return NULL;
}

JNIEXPORT jint JNICALL Java_com_sun_media_sound_PortMixerProvider_nGetNumDevices(JNIEnv *env, jclass cls)
{
    size_t count = 0; uint64_t generation = 0; int native_error = 0, result; (void)cls;
    result = amcl_ports_refresh(&count, &generation, &native_error);
    if (result != AMCL_PORTS_OK || count > INT_MAX) { throw_result(env, result, native_error, 0); return 0; }
    return (jint)count;
}

JNIEXPORT jlong JNICALL Java_com_sun_media_sound_PortMixerProvider_nGetGeneration(JNIEnv *env, jclass cls)
{
    (void)env; (void)cls; return (jlong)amcl_ports_generation();
}

/* 每个Mixer对应一个真正的descriptor。Java数组下标和native稳定token分别传入，
 * 避免拔插后同一下标悄悄指向另一设备。完整名称放在Mixer.Info，typed Port遵循标准名称。 */
JNIEXPORT jobject JNICALL Java_com_sun_media_sound_PortMixerProvider_nNewPortMixerInfoSnapshot(
    JNIEnv *env, jclass cls, jint index, jlong generation)
{
    AmclPortInfo info; int result; jclass type; jmethodID constructor;
    jstring name, vendor, description, version; jobject value = NULL; char detail[128]; (void)cls;
    result = amcl_ports_info_at((size_t)index, (uint64_t)generation, &info);
    if (result != AMCL_PORTS_OK) { throw_result(env, result, 0, 0); return NULL; }
    if ((*env)->PushLocalFrame(env, 8) < 0) { amcl_ports_info_free(&info); return NULL; }
    type = (*env)->FindClass(env, "com/sun/media/sound/PortMixerProvider$PortMixerInfo");
    if (!type) goto done;
    constructor = (*env)->GetMethodID(env, type, "<init>", "(IJLjava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V");
    if (!constructor) goto done;
    name = utf8_string(env, info.name); if (!name) goto done;
    vendor = utf8_string(env, "OHAudio"); if (!vendor) goto done;
    snprintf(detail, sizeof(detail), "OHAudio device %u, type %d, role %d; system controls not publicly writable", info.device_id, info.type, info.role);
    description = utf8_string(env, detail); if (!description) goto done;
    version = utf8_string(env, "1"); if (!version) goto done;
    value = (*env)->NewObject(env, type, constructor, index, (jlong)info.token, name, vendor, description, version);
done:
    amcl_ports_info_free(&info); return (*env)->PopLocalFrame(env, value);
}

/* 上游旧调用点保留符号兼容，OHOS新Java分支始终传入明确代次。 */
JNIEXPORT jobject JNICALL Java_com_sun_media_sound_PortMixerProvider_nNewPortMixerInfo(JNIEnv *env, jclass cls, jint index)
{
    return Java_com_sun_media_sound_PortMixerProvider_nNewPortMixerInfoSnapshot(env, cls, index, (jlong)amcl_ports_generation());
}

JNIEXPORT jlong JNICALL Java_com_sun_media_sound_PortMixer_nOpenSnapshot(JNIEnv *env, jclass cls, jlong token)
{
    uint64_t handle = 0; int native_error = 0, result; (void)cls;
    result = amcl_ports_open((uint64_t)token, &handle, &native_error);
    if (result != AMCL_PORTS_OK) { throw_result(env, result, native_error, 1); return 0; }
    return (jlong)handle;
}

JNIEXPORT jlong JNICALL Java_com_sun_media_sound_PortMixer_nOpen(JNIEnv *env, jclass cls, jint index)
{
    AmclPortInfo info; jlong value; int result = amcl_ports_info_at((size_t)index, amcl_ports_generation(), &info);
    if (result != AMCL_PORTS_OK) { throw_result(env, result, 0, 1); return 0; }
    value = Java_com_sun_media_sound_PortMixer_nOpenSnapshot(env, cls, (jlong)info.token);
    amcl_ports_info_free(&info); return value;
}

JNIEXPORT void JNICALL Java_com_sun_media_sound_PortMixer_nClose(JNIEnv *env, jclass cls, jlong handle)
{
    (void)env; (void)cls; if (handle) (void)amcl_ports_close((uint64_t)handle);
}

/* 一个真实设备只暴露一个源或目标Port，不增加“默认设备”或虚拟mixer占位符。 */
JNIEXPORT jint JNICALL Java_com_sun_media_sound_PortMixer_nGetPortCount(JNIEnv *env, jclass cls, jlong handle)
{
    AmclPortInfo info; int result; (void)cls;
    result = amcl_ports_handle_info((uint64_t)handle, &info);
    if (result != AMCL_PORTS_OK) { throw_result(env, result, 0, 0); return 0; }
    amcl_ports_info_free(&info); return 1;
}

static int get_info(JNIEnv *env, jlong handle, jint index, AmclPortInfo *info)
{
    int result = index == 0 ? amcl_ports_handle_info((uint64_t)handle, info) : AMCL_PORTS_INVALID;
    if (result != AMCL_PORTS_OK) { throw_result(env, result, 0, 0); return 0; }
    return 1;
}

JNIEXPORT jint JNICALL Java_com_sun_media_sound_PortMixer_nGetPortType(JNIEnv *env, jclass cls, jlong handle, jint index)
{
    AmclPortInfo info; jint type; (void)cls;
    if (!get_info(env, handle, index, &info)) return 0;
    if (info.role == AUDIO_DEVICE_ROLE_INPUT) {
        type = info.type == AUDIO_DEVICE_TYPE_MIC || info.type == AUDIO_DEVICE_TYPE_WIRED_HEADSET || info.type == AUDIO_DEVICE_TYPE_USB_HEADSET ? 0x02 : 0x01;
    } else {
        type = info.type == AUDIO_DEVICE_TYPE_SPEAKER ? 0x0200 :
            info.type == AUDIO_DEVICE_TYPE_WIRED_HEADPHONES || info.type == AUDIO_DEVICE_TYPE_WIRED_HEADSET || info.type == AUDIO_DEVICE_TYPE_USB_HEADSET ? 0x0300 : 0x0100;
    }
    amcl_ports_info_free(&info); return type;
}

JNIEXPORT jstring JNICALL Java_com_sun_media_sound_PortMixer_nGetPortName(JNIEnv *env, jclass cls, jlong handle, jint index)
{
    AmclPortInfo info; jstring value; (void)cls;
    if (!get_info(env, handle, index, &info)) return NULL;
    value = utf8_string(env, info.name); amcl_ports_info_free(&info); return value;
}

/* 查询控制前确认设备仍在。当前公开SDK没有系统音量/静音setter，Vector保持空是能力
 * 事实，不创建可写外观或调用局部Renderer gain。无控制不等于无真实设备。 */
JNIEXPORT void JNICALL Java_com_sun_media_sound_PortMixer_nGetControls(JNIEnv *env, jclass cls, jlong handle, jint index, jobject vector)
{
    int native_error = 0, result; (void)cls;
    if (index != 0 || !vector) { throw_result(env, AMCL_PORTS_INVALID, 0, 1); return; }
    result = amcl_ports_check_present((uint64_t)handle, &native_error);
    if (result != AMCL_PORTS_OK) throw_result(env, result, native_error, 1);
}

/* 未公布任何控制句柄。即使通过反射误调旧私有native入口，也必须报不支持，不能假成功。 */
#define CONTROL_UNSUPPORTED(env) throw_ports(env, "java/lang/UnsupportedOperationException", AMCL_PORTS_INVALID, 0)
JNIEXPORT void JNICALL Java_com_sun_media_sound_PortMixer_nControlSetIntValue(JNIEnv *env, jclass cls, jlong id, jint value)
{ (void)cls; (void)id; (void)value; CONTROL_UNSUPPORTED(env); }
JNIEXPORT jint JNICALL Java_com_sun_media_sound_PortMixer_nControlGetIntValue(JNIEnv *env, jclass cls, jlong id)
{ (void)cls; (void)id; CONTROL_UNSUPPORTED(env); return 0; }
JNIEXPORT void JNICALL Java_com_sun_media_sound_PortMixer_nControlSetFloatValue(JNIEnv *env, jclass cls, jlong id, jfloat value)
{ (void)cls; (void)id; (void)value; CONTROL_UNSUPPORTED(env); }
JNIEXPORT jfloat JNICALL Java_com_sun_media_sound_PortMixer_nControlGetFloatValue(JNIEnv *env, jclass cls, jlong id)
{ (void)cls; (void)id; CONTROL_UNSUPPORTED(env); return 0; }
