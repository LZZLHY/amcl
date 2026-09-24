/**
 * 自有 CallbackBridge 延迟绑定宿主。
 *
 * 启动线程只发布带 ABI/PID/会话的函数表；JNI_OnLoad 传入实际调用者加载器定义的
 * Class 后才注册。不能由宿主 FindClass：它既可能抢先初始化错误加载器中的类，又会在
 * RegisterNatives 之前触发静态块。GLFW 本身仍走上游 LWJGL FFI，不在这里注册。
 * 函数表借用 libentry → libglfw 的既有输入实现，不创建第二套 input owner。
 */

#include "jni_registry.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <inttypes.h>
#include <unistd.h>
#if defined(AMCL_JNI_BRIDGE_HOST_TEST)
// 宿主回归编译同一注册实现，仅用测试桩替代 Harmony 日志设施和输入设备。
#define AMCL_LOG_I(...) ((void)0)
#define AMCL_LOG_E(...) ((void)0)
#else
#include "../utils/amcl_log.h"
#include <hilog/log.h>
#endif

#undef LOG_TAG
#define LOG_TAG "JNI_REGISTRY"

// ============================================================
// 既有 input_bridge_ohos.c 入口声明；输入状态仍属于该实现的权威实例。
// ============================================================
extern "C" {
    void Java_org_lwjgl_glfw_CallbackBridge_nativeSendCursorPos(void*, void*, float, float);
    void Java_org_lwjgl_glfw_CallbackBridge_nativeSendMouseButton(void*, void*, int, int, int);
    void Java_org_lwjgl_glfw_CallbackBridge_nativeSendKey(void*, void*, int, int, int, int);
    int Java_org_lwjgl_glfw_CallbackBridge_nativeGetKeyDown(void*, void*, int);
    int Java_org_lwjgl_glfw_CallbackBridge_nativeGetMouseDown(void*, void*, int);
    unsigned char Java_org_lwjgl_glfw_CallbackBridge_nativeSendChar(void*, void*, unsigned short);
    unsigned char Java_org_lwjgl_glfw_CallbackBridge_nativeSendCharMods(void*, void*, unsigned short, int);
    void Java_org_lwjgl_glfw_CallbackBridge_nativeSendScroll(void*, void*, double, double);
    void Java_org_lwjgl_glfw_CallbackBridge_nativeSendScreenSize(void*, void*, int, int);
    unsigned char Java_org_lwjgl_glfw_CallbackBridge_nativeSetInputReady(void*, void*, unsigned char);
    void Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing(void*, void*, unsigned char);
    void Java_org_lwjgl_glfw_CallbackBridge_nativeSetUseInputStackQueue(void*, void*, unsigned char);
    void Java_org_lwjgl_glfw_CallbackBridge_nativeSetWindowAttrib(void*, void*, int, int);
    void* Java_org_lwjgl_glfw_CallbackBridge_nativeCreateGamepadButtonBuffer(void*, void*);
    void* Java_org_lwjgl_glfw_CallbackBridge_nativeCreateGamepadAxisBuffer(void*, void*);
    void* Java_org_lwjgl_glfw_CallbackBridge_nativeClipboard(void*, void*, int, void*);
}

// ============================================================
// 精确方法表只覆盖自有 CallbackBridge；未实现能力必须显式报告，不能漏注册后吞异常。
// ============================================================

// JNI 历史接口使用 char*，方法名/签名实际只读，因此仅在这个声明边界显式转换。
#define JNI_METHOD(name, sig, fn) {(char*)(name), (char*)(sig), (void*)(fn)}

/** 历史 Pojav 消息通道未移植；显式异常比“绑定成功但功能静默丢失”更容易定位。 */
static void JNICALL unsupportedSendData(JNIEnv* env, jclass, jboolean, jint, jstring) {
    jclass exception = env->FindClass("java/lang/UnsupportedOperationException");
    if (exception) {
        env->ThrowNew(exception, "CallbackBridge nativeSendData is not supported on HarmonyOS");
        env->DeleteLocalRef(exception);
    }
}

/** 这里仅指旧共享缓冲区协议，不代表 typed/GLFW/SDL 的其他手柄通路不可用。 */
static jboolean JNICALL unsupportedGamepadDirectInput(JNIEnv*, jclass) { return JNI_FALSE; }

static JNINativeMethod g_callbackBridgeMethods[] = {
    JNI_METHOD("nativeSendCursorPos",          "(FF)V",                   Java_org_lwjgl_glfw_CallbackBridge_nativeSendCursorPos),
    JNI_METHOD("nativeSendMouseButton",        "(III)V",                  Java_org_lwjgl_glfw_CallbackBridge_nativeSendMouseButton),
    JNI_METHOD("nativeSendKey",                "(IIII)V",                 Java_org_lwjgl_glfw_CallbackBridge_nativeSendKey),
    JNI_METHOD("nativeGetKeyDown",             "(I)I",                    Java_org_lwjgl_glfw_CallbackBridge_nativeGetKeyDown),
    JNI_METHOD("nativeGetMouseDown",           "(I)I",                    Java_org_lwjgl_glfw_CallbackBridge_nativeGetMouseDown),
    JNI_METHOD("nativeSendChar",               "(C)Z",                    Java_org_lwjgl_glfw_CallbackBridge_nativeSendChar),
    JNI_METHOD("nativeSendCharMods",           "(CI)Z",                   Java_org_lwjgl_glfw_CallbackBridge_nativeSendCharMods),
    JNI_METHOD("nativeSendScroll",             "(DD)V",                   Java_org_lwjgl_glfw_CallbackBridge_nativeSendScroll),
    JNI_METHOD("nativeSendScreenSize",         "(II)V",                   Java_org_lwjgl_glfw_CallbackBridge_nativeSendScreenSize),
    JNI_METHOD("nativeSetInputReady",          "(Z)Z",                    Java_org_lwjgl_glfw_CallbackBridge_nativeSetInputReady),
    JNI_METHOD("nativeSetGrabbing",            "(Z)V",                    Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing),
    JNI_METHOD("nativeSetUseInputStackQueue",  "(Z)V",                    Java_org_lwjgl_glfw_CallbackBridge_nativeSetUseInputStackQueue),
    JNI_METHOD("nativeSetWindowAttrib",        "(II)V",                   Java_org_lwjgl_glfw_CallbackBridge_nativeSetWindowAttrib),
    JNI_METHOD("nativeCreateGamepadButtonBuffer","()Ljava/nio/ByteBuffer;",Java_org_lwjgl_glfw_CallbackBridge_nativeCreateGamepadButtonBuffer),
    JNI_METHOD("nativeCreateGamepadAxisBuffer","()Ljava/nio/ByteBuffer;", Java_org_lwjgl_glfw_CallbackBridge_nativeCreateGamepadAxisBuffer),
    JNI_METHOD("nativeClipboard",              "(I[B)Ljava/lang/String;", Java_org_lwjgl_glfw_CallbackBridge_nativeClipboard),
    JNI_METHOD("nativeSendData",               "(ZILjava/lang/String;)V", unsupportedSendData),
    JNI_METHOD("nativeEnableGamepadDirectInput", "()Z",                  unsupportedGamepadDirectInput),
};

// ============================================================
// 显式 Class 绑定及发布生命周期。active 的 release/acquire 保证消费者只看见完整只读表。
// ============================================================

static AmclCallbackBridgeHostV1 g_callbackBridgeHost{};
static std::atomic<bool> g_callbackBridgeActive{false};
static std::atomic<bool> g_callbackBridgePublished{false};

/** JNI_OnLoad 中取得的实际 Class 正处于当前线程的初始化流程；不递归查找同名类。 */
static jint bindCallbackBridge(JNIEnv* env, jclass actualClass) {
    if (!g_callbackBridgeActive.load(std::memory_order_acquire) ||
        g_callbackBridgeHost.pid != static_cast<uint32_t>(getpid()) ||
        !env || !actualClass || env->ExceptionCheck()) return JNI_ERR;
    const jint count = sizeof(g_callbackBridgeMethods) / sizeof(g_callbackBridgeMethods[0]);
    const jint result = env->RegisterNatives(actualClass, g_callbackBridgeMethods, count);
    if (result != JNI_OK || env->ExceptionCheck()) {
        AMCL_LOG_E(LOG_TAG, "CallbackBridge binding failed rc=%{public}d", result);
        return JNI_ERR;
    }
    AMCL_LOG_I(LOG_TAG, "CallbackBridge bound actualClass=%{public}p methods=%{public}d pid=%{public}u",
               static_cast<void*>(actualClass), count, g_callbackBridgeHost.pid);
    return JNI_OK;
}

JNIEXPORT const AmclCallbackBridgeHostV1* amclCallbackBridgeHostGetV1(void) {
    if (!g_callbackBridgeActive.load(std::memory_order_acquire) ||
        g_callbackBridgeHost.pid != static_cast<uint32_t>(getpid())) return nullptr;
    return &g_callbackBridgeHost;
}

int publishCallbackBridgeHostV1(uint64_t launchId) {
    // 同一个进程的游戏只发布一次，撤销不恢复 published；这样失败重试不会复用旧 JNI 状态。
    bool expected = false;
    if (!launchId || !g_callbackBridgePublished.compare_exchange_strong(expected, true)) return JNI_ERR;
    g_callbackBridgeHost = {AMCL_CALLBACK_BRIDGE_HOST_MAGIC, AMCL_CALLBACK_BRIDGE_HOST_ABI,
        sizeof(AmclCallbackBridgeHostV1), static_cast<uint32_t>(getpid()), 0, launchId, bindCallbackBridge};
    char descriptor[128]{};
    const int length = snprintf(descriptor, sizeof(descriptor), "%u:%u:%" PRIu64 ":%" PRIxPTR,
        g_callbackBridgeHost.abi, g_callbackBridgeHost.pid, launchId,
        reinterpret_cast<uintptr_t>(&amclCallbackBridgeHostGetV1));
    if (length <= 0 || static_cast<size_t>(length) >= sizeof(descriptor)) return JNI_ERR;
    g_callbackBridgeActive.store(true, std::memory_order_release);
    if (setenv(AMCL_CALLBACK_BRIDGE_HOST_ENV, descriptor, 1) != 0) {
        g_callbackBridgeActive.store(false, std::memory_order_release);
        return JNI_ERR;
    }
    return JNI_OK;
}

void revokeCallbackBridgeHostV1(void) {
    // 已绑定的方法表不能安全撤销；只禁止新的绑定。游戏进程退出负责清理全部 native 状态。
    g_callbackBridgeActive.store(false, std::memory_order_release);
    unsetenv(AMCL_CALLBACK_BRIDGE_HOST_ENV);
}
