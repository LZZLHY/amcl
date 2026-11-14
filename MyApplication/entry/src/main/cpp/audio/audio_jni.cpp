/**
 * Java Sound自有JNI薄桥。唯一Java owner通过绝对System.load首次绑定，本库不创建音频
 * Runtime，也不FindClass预初始化第三方平台类。阻塞IO使用本地有界副本，不持Java堆pin。
 */
#include "../jvm/jni.h"
#include "audio_client.h"
#include <algorithm>
#include <cstdint>
#include <vector>
namespace {
const AmclAudioApiV1 *require(JNIEnv *env) {
    auto *api = amcl::audio::resolveAudioHost();
    if (!api) {
        auto c = env->FindClass("java/lang/IllegalStateException");
        if (c)
            env->ThrowNew(c, "AMCL audio host is absent or this session has ended");
    }
    return api;
}
void error(JNIEnv *env, int result, bool opening = false) {
    if (result >= 0 || env->ExceptionCheck())
        return;
    const char *type = result == AMCL_AUDIO_PERMISSION ? "java/lang/SecurityException"
                       : opening                       ? "javax/sound/sampled/LineUnavailableException"
                                                       : "java/lang/IllegalStateException";
    auto c = env->FindClass(type);
    if (c)
        env->ThrowNew(c, result == AMCL_AUDIO_PERMISSION
                             ? "Microphone permission or foreground eligibility denied"
                             : "AMCL audio operation failed; device/format/session unavailable");
}
bool bounds(JNIEnv *env, jbyteArray bytes, jint offset, jint size) {
    if (!bytes || offset < 0 || size < 0 || offset > env->GetArrayLength(bytes) ||
        size > env->GetArrayLength(bytes) - offset) {
        auto c =
            env->FindClass(bytes ? "java/lang/IndexOutOfBoundsException" : "java/lang/NullPointerException");
        if (c)
            env->ThrowNew(c, "Invalid audio buffer range");
        return false;
    }
    return true;
}
} // namespace
extern "C" JNIEXPORT jlong JNICALL Java_com_amcl_audio_OhosAudioNative_nOpen(JNIEnv *env, jclass,
                                                                             jboolean capture, jint rate,
                                                                             jint channels, jint encoding,
                                                                             jint bytes) {
    auto *api = require(env);
    if (!api)
        return 0;
    uint64_t handle = 0;
    error(env, api->open(capture ? 1 : 0, rate, channels, encoding, bytes, &handle), true);
    return static_cast<jlong>(handle);
}
#define AMCL_JNI_VOID(javaName, nativeName)                                                                  \
    extern "C" JNIEXPORT void JNICALL Java_com_amcl_audio_OhosAudioNative_##javaName(JNIEnv *env, jclass,    \
                                                                                     jlong h) {              \
        auto *api = require(env);                                                                            \
        if (api)                                                                                             \
            error(env, api->nativeName(static_cast<uint64_t>(h)));                                           \
    }
AMCL_JNI_VOID(nStart, start)
AMCL_JNI_VOID(nStop, stop)
AMCL_JNI_VOID(nRequestFinish, requestFinish)
AMCL_JNI_VOID(nFlush, flush) AMCL_JNI_VOID(nDrain, drain)
#undef AMCL_JNI_VOID
    /** close在宿主已撤销时仍为幂等；End已唤醒并关闭所有流，不借新owner找旧句柄。 */
    extern "C" JNIEXPORT void JNICALL
    Java_com_amcl_audio_OhosAudioNative_nClose(JNIEnv *env, jclass, jlong h) {
    auto *api = amcl::audio::resolveAudioHost();
    if (api)
        error(env, api->close(static_cast<uint64_t>(h)));
}
extern "C" JNIEXPORT jint JNICALL Java_com_amcl_audio_OhosAudioNative_nRead(JNIEnv *env, jclass, jlong h,
                                                                            jbyteArray bytes, jint offset,
                                                                            jint size) {
    if (!bounds(env, bytes, offset, size))
        return 0;
    auto *api = require(env);
    if (!api || size == 0)
        return 0;
    const int frame = api->frameBytes(h);
    if (frame <= 0 || size % frame) {
        error(env, AMCL_AUDIO_INVALID);
        return 0;
    }
    try {
        std::vector<uint8_t> buffer(static_cast<size_t>(std::min(size, 65536)));
        int done = 0;
        while (done < size) {
            int chunk = std::min(size - done, 65536);
            int n = api->read(h, buffer.data(), chunk, 1);
            if (n < 0) {
                error(env, n);
                break;
            }
            if (n)
                env->SetByteArrayRegion(bytes, offset + done, n,
                                        reinterpret_cast<const jbyte *>(buffer.data()));
            done += n;
            if (n < chunk || env->ExceptionCheck() || !(api->state(h) & AMCL_AUDIO_RUNNING))
                break;
        }
        return done;
    } catch (...) {
        error(env, AMCL_AUDIO_LIMIT);
        return 0;
    }
}
extern "C" JNIEXPORT jint JNICALL Java_com_amcl_audio_OhosAudioNative_nWrite(JNIEnv *env, jclass, jlong h,
                                                                             jbyteArray bytes, jint offset,
                                                                             jint size) {
    if (!bounds(env, bytes, offset, size))
        return 0;
    auto *api = require(env);
    if (!api || size == 0)
        return 0;
    const int frame = api->frameBytes(h);
    if (frame <= 0 || size % frame) {
        error(env, AMCL_AUDIO_INVALID);
        return 0;
    }
    try {
        std::vector<uint8_t> buffer(static_cast<size_t>(std::min(size, 65536)));
        int done = 0;
        while (done < size) {
            int chunk = std::min(size - done, 65536);
            env->GetByteArrayRegion(bytes, offset + done, chunk, reinterpret_cast<jbyte *>(buffer.data()));
            if (env->ExceptionCheck())
                break;
            int n = api->write(h, buffer.data(), chunk);
            if (n < 0) {
                error(env, n);
                break;
            }
            done += n;
            if (n < chunk || !(api->state(h) & AMCL_AUDIO_RUNNING))
                break;
        }
        return done;
    } catch (...) {
        error(env, AMCL_AUDIO_LIMIT);
        return 0;
    }
}
#define AMCL_JNI_INT(javaName, nativeName)                                                                   \
    extern "C" JNIEXPORT jint JNICALL Java_com_amcl_audio_OhosAudioNative_##javaName(JNIEnv *env, jclass,    \
                                                                                     jlong h) {              \
        auto *api = require(env);                                                                            \
        if (!api)                                                                                            \
            return 0;                                                                                        \
        const int result = api->nativeName(h);                                                               \
        error(env, result);                                                                                  \
        return std::max(0, result);                                                                          \
    }
AMCL_JNI_INT(nAvailable, available)
AMCL_JNI_INT(nBufferSize, bufferSize)
#undef AMCL_JNI_INT
/** 监控线程在撤销后读到FAILED，不抛异常中断自己的资源回收。 */
extern "C" JNIEXPORT jint JNICALL Java_com_amcl_audio_OhosAudioNative_nState(JNIEnv *, jclass, jlong h) {
    auto *api = amcl::audio::resolveAudioHost();
    return api ? api->state(h) : AMCL_AUDIO_FAILED;
}
extern "C" JNIEXPORT jlong JNICALL Java_com_amcl_audio_OhosAudioNative_nFramePosition(JNIEnv *, jclass,
                                                                                      jlong h) {
    auto *api = amcl::audio::resolveAudioHost();
    return api ? api->framePosition(h) : 0;
}
