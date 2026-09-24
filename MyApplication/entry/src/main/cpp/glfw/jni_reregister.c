/**
 * CallbackBridge 实际消费者加载的专用 JNI 库。
 *
 * JNI_OnLoad 的 FindClass 使用调用 System.loadLibrary 的类所属加载器，只有这里可以
 * 获取本次初始化的实际 CallbackBridge。宿主只发布原生函数表，绑定函数接收显式 Class，
 * 不再回到启动器的类加载上下文，也不打开第二份 libglfw 或接管第三方 JNI 库。
 * 任一契约校验/注册失败均返回 JNI_ERR；禁止“未找到入口也返回成功版本号”。
 */
#include <errno.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include "../jvm/callback_bridge_host.h"

#if defined(AMCL_JNI_BRIDGE_HOST_TEST)
// 宿主测试直接编译本文件，日志替身只移除 Harmony SDK 依赖，不替换加载/注册逻辑。
#include <stdio.h>
#define BRIDGE_ERROR(message) fprintf(stderr, "JNI_BRIDGE: %s\n", message)
#define BRIDGE_INFO(message) fprintf(stdout, "JNI_BRIDGE: %s\n", message)
#else
#include <hilog/log.h>
#undef LOG_TAG
#define LOG_TAG "JNI_BRIDGE"
#define BRIDGE_ERROR(message) OH_LOG_ERROR(LOG_APP, "%{public}s", message)
#define BRIDGE_INFO(message) OH_LOG_INFO(LOG_APP, "%{public}s", message)
#endif

/** 严格读取无符号字段：拒绝符号、空白、溢出、缺失分隔符及末尾多余字符。 */
static int parseField(const char** cursor, int base, uint64_t maximum, char separator, uint64_t* out) {
    const char* value = *cursor;
    if (!value || !((value[0] >= '0' && value[0] <= '9') ||
        (base == 16 && ((value[0] >= 'a' && value[0] <= 'f') ||
                       (value[0] >= 'A' && value[0] <= 'F'))))) return 0;
    char* end = NULL;
    errno = 0;
    const unsigned long long parsed = strtoull(value, &end, base);
    if (errno || end == value || *end != separator || parsed > maximum) return 0;
    *out = (uint64_t)parsed;
    *cursor = separator ? end + 1 : end;
    return 1;
}

/**
 * 环境字符串不携带可直接解引用的对象。先校验可执行映射中的精确 getter 符号，再调用
 * 它取得只读表；随后核对表身份和 bind 所属 DSO，防止坏地址/旧 PID 被当作函数执行。
 * 不使用 RTLD_DEFAULT 回退，避免命名空间差异静默选中另一个宿主。
 */
static const AmclCallbackBridgeHostV1* resolveHost(void) {
    const char* cursor = getenv(AMCL_CALLBACK_BRIDGE_HOST_ENV);
    if (!cursor || strlen(cursor) >= 128) {
        BRIDGE_ERROR("host descriptor absent or too long");
        return NULL;
    }
    uint64_t abi = 0, pid = 0, launchId = 0, address = 0;
    if (!parseField(&cursor, 10, UINT32_MAX, ':', &abi) ||
        !parseField(&cursor, 10, UINT32_MAX, ':', &pid) ||
        !parseField(&cursor, 10, UINT64_MAX, ':', &launchId) ||
        !parseField(&cursor, 16, UINTPTR_MAX, '\0', &address) ||
        abi != AMCL_CALLBACK_BRIDGE_HOST_ABI || pid != (uint32_t)getpid() ||
        !launchId || !address) {
        BRIDGE_ERROR("host descriptor text/ABI/PID/session invalid");
        return NULL;
    }

    void* getterAddress = (void*)(uintptr_t)address;
    Dl_info getterSymbol;
    memset(&getterSymbol, 0, sizeof(getterSymbol));
    if (!dladdr(getterAddress, &getterSymbol) || !getterSymbol.dli_sname ||
        !getterSymbol.dli_fbase || getterSymbol.dli_saddr != getterAddress ||
        strcmp(getterSymbol.dli_sname, AMCL_CALLBACK_BRIDGE_HOST_GETTER) != 0) {
        BRIDGE_ERROR("host getter is not the exact exported symbol in a loaded DSO");
        return NULL;
    }

    const AmclCallbackBridgeHostV1* host = ((AmclCallbackBridgeHostGetterV1)getterAddress)();
    if (!host || host->magic != AMCL_CALLBACK_BRIDGE_HOST_MAGIC ||
        host->abi != AMCL_CALLBACK_BRIDGE_HOST_ABI || host->size != sizeof(*host) ||
        host->pid != pid || host->reserved != 0 || host->launchId != launchId || !host->bind) {
        BRIDGE_ERROR("host getter revoked or returned an incompatible function table");
        return NULL;
    }

    Dl_info bindSymbol;
    memset(&bindSymbol, 0, sizeof(bindSymbol));
    if (!dladdr((void*)host->bind, &bindSymbol) ||
        bindSymbol.dli_fbase != getterSymbol.dli_fbase) {
        BRIDGE_ERROR("host bind function is outside the validated host DSO");
        return NULL;
    }
    return host;
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    (void)reserved;
    JNIEnv* env = NULL;
    // JVM 调用 JNI_OnLoad 的线程必须已附着；额外 Attach 会掩盖错误调用上下文。
    if (!vm || (*vm)->GetEnv(vm, (void**)&env, JNI_VERSION_1_6) != JNI_OK || !env) {
        BRIDGE_ERROR("JNI_OnLoad has no attached Java caller");
        return JNI_ERR;
    }
    const AmclCallbackBridgeHostV1* host = resolveHost();
    if (!host) {
        BRIDGE_ERROR("host descriptor rejected (absent, stale, ABI/PID/session/symbol mismatch)");
        return JNI_ERR;
    }
    // CallbackBridge.<clinit> 正在同线程执行：取得相同 Class，不重新初始化另一份同名类。
    jclass actualClass = (*env)->FindClass(env, "org/lwjgl/glfw/CallbackBridge");
    if (!actualClass || (*env)->ExceptionCheck(env)) {
        BRIDGE_ERROR("actual CallbackBridge class lookup failed");
        return JNI_ERR;
    }
    const jint result = host->bind(env, actualClass);
    (*env)->DeleteLocalRef(env, actualClass);
    if (result != JNI_OK || (*env)->ExceptionCheck(env)) {
        BRIDGE_ERROR("actual CallbackBridge native binding failed");
        return JNI_ERR;
    }
    BRIDGE_INFO("actual CallbackBridge class bound; shared gamepad buffers remain unsupported");
    return JNI_VERSION_1_6;
}
