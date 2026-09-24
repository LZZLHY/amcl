/**
 * JNI 所有权回归的原生设备替身：真实编译产品注册器，只替换最终输入设备入口。
 * 按键状态/事件计数证明 native 方法确实被正确 Class 调用；不声称这是 OHOS 真机事件流。
 * 每个用例在全新 JVM 运行，避免 DLL 卸载/GC 时机让负例出现假通过。
 */
#include "../../../jvm/jni_registry.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>

static int g_keyState[512]{};
static int g_nativeCalls = 0;

extern "C" {
void Java_org_lwjgl_glfw_CallbackBridge_nativeSendCursorPos(void*, void*, float, float) { ++g_nativeCalls; }
void Java_org_lwjgl_glfw_CallbackBridge_nativeSendMouseButton(void*, void*, int, int, int) { ++g_nativeCalls; }
void Java_org_lwjgl_glfw_CallbackBridge_nativeSendKey(void*, void*, int key, int, int action, int) {
    ++g_nativeCalls;
    if (key >= 0 && key < 512) g_keyState[key] = action;
}
int Java_org_lwjgl_glfw_CallbackBridge_nativeGetKeyDown(void*, void*, int key) {
    ++g_nativeCalls;
    return key >= 0 && key < 512 ? g_keyState[key] : 0;
}
int Java_org_lwjgl_glfw_CallbackBridge_nativeGetMouseDown(void*, void*, int) { ++g_nativeCalls; return 0; }
unsigned char Java_org_lwjgl_glfw_CallbackBridge_nativeSendChar(void*, void*, unsigned short) { ++g_nativeCalls; return 1; }
unsigned char Java_org_lwjgl_glfw_CallbackBridge_nativeSendCharMods(void*, void*, unsigned short, int) { ++g_nativeCalls; return 1; }
void Java_org_lwjgl_glfw_CallbackBridge_nativeSendScroll(void*, void*, double, double) { ++g_nativeCalls; }
void Java_org_lwjgl_glfw_CallbackBridge_nativeSendScreenSize(void*, void*, int, int) { ++g_nativeCalls; }
unsigned char Java_org_lwjgl_glfw_CallbackBridge_nativeSetInputReady(void*, void*, unsigned char ready) { ++g_nativeCalls; return ready; }
void Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing(void*, void*, unsigned char) { ++g_nativeCalls; }
void Java_org_lwjgl_glfw_CallbackBridge_nativeSetUseInputStackQueue(void*, void*, unsigned char) { ++g_nativeCalls; }
void Java_org_lwjgl_glfw_CallbackBridge_nativeSetWindowAttrib(void*, void*, int, int) { ++g_nativeCalls; }
void* Java_org_lwjgl_glfw_CallbackBridge_nativeCreateGamepadButtonBuffer(void*, void*) { ++g_nativeCalls; return nullptr; }
void* Java_org_lwjgl_glfw_CallbackBridge_nativeCreateGamepadAxisBuffer(void*, void*) { ++g_nativeCalls; return nullptr; }
void* Java_org_lwjgl_glfw_CallbackBridge_nativeClipboard(void*, void*, int, void*) { ++g_nativeCalls; return nullptr; }

/** 首次发布产品描述符；负例精确破坏单个字段，验证失败不会跳过检查或执行坏指针。 */
JNIEXPORT jint JNICALL Java_NativeOwnershipTest_setup(JNIEnv* env, jclass, jstring modeValue) {
    const char* modeChars = env->GetStringUTFChars(modeValue, nullptr);
    if (!modeChars) return JNI_ERR;
    const std::string mode(modeChars);
    env->ReleaseStringUTFChars(modeValue, modeChars);
    if (publishCallbackBridgeHostV1(73) != JNI_OK) return JNI_ERR;
    if (publishCallbackBridgeHostV1(74) != JNI_ERR) return JNI_ERR;
    const char* published = getenv(AMCL_CALLBACK_BRIDGE_HOST_ENV);
    const std::string saved = published ? published : "";
    auto* host = const_cast<AmclCallbackBridgeHostV1*>(amclCallbackBridgeHostGetV1());
    if (!host) return JNI_ERR;
    if (mode == "missing") unsetenv(AMCL_CALLBACK_BRIDGE_HOST_ENV);
    else if (mode == "wrong-pid") {
        const std::string text = "1:0:73:1";
        setenv(AMCL_CALLBACK_BRIDGE_HOST_ENV, text.c_str(), 1);
    } else if (mode == "bad-address") {
        char text[128];
        snprintf(text, sizeof(text), "1:%u:73:1", (unsigned)getpid());
        setenv(AMCL_CALLBACK_BRIDGE_HOST_ENV, text, 1);
    } else if (mode == "bad-symbol") {
        char text[128];
        snprintf(text, sizeof(text), "1:%u:73:%llx", (unsigned)getpid(),
                 (unsigned long long)(uintptr_t)&publishCallbackBridgeHostV1);
        setenv(AMCL_CALLBACK_BRIDGE_HOST_ENV, text, 1);
    } else if (mode == "bad-text") setenv(AMCL_CALLBACK_BRIDGE_HOST_ENV, " 1:0:73:1", 1);
    else if (mode == "overflow") setenv(AMCL_CALLBACK_BRIDGE_HOST_ENV, "18446744073709551616:0:73:1", 1);
    else if (mode == "trailing-data") setenv(AMCL_CALLBACK_BRIDGE_HOST_ENV, (saved + ":garbage").c_str(), 1);
    else if (mode == "bad-abi") host->abi = 7;
    else if (mode == "bad-magic") host->magic = 1;
    else if (mode == "bad-size") host->size = 0;
    else if (mode == "bad-session") host->launchId = 74;
    else if (mode == "bad-reserved") host->reserved = 1;
    else if (mode == "null-bind") host->bind = nullptr;
    else if (mode == "foreign-bind") {
        // GetVersion 位于真实 JVM DLL，而非宿主 DSO；验证跨模块坏入口在调用前被拒绝。
        host->bind = reinterpret_cast<jint (*)(JNIEnv*, jclass)>(env->functions->GetVersion);
    }
    else if (mode == "revoked") {
        revokeCallbackBridgeHostV1();
        if (publishCallbackBridgeHostV1(75) != JNI_ERR) return JNI_ERR;
        setenv(AMCL_CALLBACK_BRIDGE_HOST_ENV, saved.c_str(), 1);
    }
    return JNI_OK;
}

/** 暴露计数供 Java 验证真实 JNI 调用，而非只看一行“已注册”的日志。 */
JNIEXPORT jint JNICALL Java_NativeOwnershipTest_nativeCalls(JNIEnv*, jclass) { return g_nativeCalls; }
}
