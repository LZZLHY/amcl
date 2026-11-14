/* 直接编译执行固定JDK8 awt_LoadLibrary.c；仅JNI/系统库边界提供可控替身。
 * 真实C控制流、原子成功缓存、错误停止与local refs由生产源码决定，不复制初始化算法。
 */
#define _GNU_SOURCE 1
#include <assert.h>
#include <dlfcn.h>
#include <jni.h>
#include <jni_util.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum Fault {
    NONE, ENV_NULL, PREEXISTING, CLASS_THROW, CLASS_NULL, CLASS_VALUE_THROW,
    METHOD_THROW, METHOD_NULL, METHOD_VALUE_THROW, BOOLEAN_THROW,
    PROP_THROW, PROP_NULL, MANAGER_THROW, MANAGER_NULL, SET_PROPERTY_THROW,
    PATH_THROW, PATH_NULL, SYSTEM_LOAD_THROW, DLOPEN_NULL
};
struct State {
    enum Fault fault;
    int pending, unchecked, ordinaryAfterPending, uncheckedUse, wrongThread;
    int live, nextRef, slots[64], getEnvCalls, findCalls, booleanCalls, loadCalls, dlCalls;
    int internalThrows, clears, fatalCalls, reenter, headless, useBarrier, nullProperty;
    char backend[256];
};
static __thread struct State state;
static __thread JNIEnv currentEnv;
static struct JNINativeInterface_ functions;
static JavaVM fakeVm;
static pthread_barrier_t barrier;

/* 普通JNI调用必须来自当前线程，且上一次Java调用已检查异常、当前没有pending异常。
 * ExceptionCheck/DeleteLocalRef单独记录，因为它们本身允许用于失败清理。 */
static void normal(JNIEnv* env) {
    if (env != &currentEnv) ++state.wrongThread;
    if (state.pending) ++state.ordinaryAfterPending;
    if (state.unchecked) ++state.uncheckedUse;
}
static jobject reference(void) {
    ++state.nextRef; assert(state.nextRef < 64); state.slots[state.nextRef] = 1; ++state.live;
    return (jobject)(uintptr_t)state.nextRef;
}
static jboolean JNICALL exceptionCheck(JNIEnv* env) {
    if (env != &currentEnv) ++state.wrongThread;
    state.unchecked = 0; return state.pending ? JNI_TRUE : JNI_FALSE;
}
static void JNICALL exceptionClear(JNIEnv* env) { (void)env; ++state.clears; state.pending = 0; }
static void JNICALL fatalError(JNIEnv* env, const char* message) { (void)env; (void)message; ++state.fatalCalls; abort(); }
static void JNICALL deleteLocalRef(JNIEnv* env, jobject value) {
    if (env != &currentEnv) ++state.wrongThread;
    const uintptr_t index = (uintptr_t)value;
    assert(index && index < 64 && state.slots[index]); state.slots[index] = 0; --state.live;
}
static jclass JNICALL findClass(JNIEnv* env, const char* name) {
    normal(env); assert(!strcmp(name, "java/awt/GraphicsEnvironment")); ++state.findCalls;
    if (state.fault == CLASS_THROW) { state.pending = CLASS_THROW; return NULL; }
    if (state.fault == CLASS_NULL) return NULL;
    if (state.fault == CLASS_VALUE_THROW) state.pending = CLASS_VALUE_THROW;
    return (jclass)reference();
}
static jmethodID JNICALL getStaticMethod(JNIEnv* env, jclass type, const char* name, const char* signature) {
    normal(env); assert(type && !strcmp(name, "isHeadless") && !strcmp(signature, "()Z"));
    if (state.fault == METHOD_THROW) { state.pending = METHOD_THROW; return NULL; }
    if (state.fault == METHOD_NULL) return NULL;
    if (state.fault == METHOD_VALUE_THROW) state.pending = METHOD_VALUE_THROW;
    return (jmethodID)(uintptr_t)0x100;
}
JNIEXPORT jboolean JNICALL AWTIsHeadless(void);
static jboolean JNICALL callBoolean(JNIEnv* env, jclass type, jmethodID method, ...) {
    normal(env); assert(type && method); ++state.booleanCalls;
    if (state.useBarrier) { int result = pthread_barrier_wait(&barrier); assert(!result || result == PTHREAD_BARRIER_SERIAL_THREAD); }
    if (state.reenter) { state.reenter = 0; assert(AWTIsHeadless() == JNI_TRUE); }
    state.unchecked = 1;
    if (state.fault == BOOLEAN_THROW) { state.pending = BOOLEAN_THROW; return JNI_FALSE; }
    return state.headless ? JNI_TRUE : JNI_FALSE;
}
static jstring JNICALL newString(JNIEnv* env, const char* value) {
    normal(env);
    const int property = !strcmp(value, "sun.font.fontmanager");
    if ((property && state.fault == PROP_THROW) || (!property && state.fault == MANAGER_THROW)) {
        state.pending = state.fault; return NULL;
    }
    if ((property && state.fault == PROP_NULL) || (!property && state.fault == MANAGER_NULL)) return NULL;
    return (jstring)reference();
}

JNIEXPORT void* JNICALL JNU_GetEnv(JavaVM* vm, jint version) {
    assert(vm == &fakeVm && version == JNI_VERSION_1_2); ++state.getEnvCalls;
    currentEnv = &functions; return state.fault == ENV_NULL ? NULL : &currentEnv;
}
JNIEXPORT void JNICALL JNU_ThrowInternalError(JNIEnv* env, const char* message) {
    (void)message; normal(env); assert(!state.pending); ++state.internalThrows; state.pending = 777;
}
JNIEXPORT void JNICALL JNU_ThrowByName(JNIEnv* env, const char* name, const char* message) {
    (void)message; normal(env); assert(!state.pending && !strcmp(name, "java/lang/UnsatisfiedLinkError")); state.pending = 778;
}
JNIEXPORT jstring JNICALL JNU_NewStringPlatform(JNIEnv* env, const char* text) {
    normal(env); strncpy(state.backend, text, sizeof(state.backend) - 1);
    if (state.fault == PATH_THROW) { state.pending = PATH_THROW; return NULL; }
    if (state.fault == PATH_NULL) return NULL;
    return (jstring)reference();
}
JNIEXPORT jvalue JNICALL JNU_CallStaticMethodByName(JNIEnv* env, jboolean* hasException,
        const char* type, const char* name, const char* signature, ...) {
    (void)hasException; (void)signature; normal(env); assert(!strcmp(type, "java/lang/System"));
    jvalue result = {0}; state.unchecked = 1;
    if (!strcmp(name, "setProperty")) {
        if (state.fault == SET_PROPERTY_THROW) state.pending = SET_PROPERTY_THROW;
        else if (!state.nullProperty) result.l = reference(); // 旧属性值允许NULL；非NULL必须释放。
    } else {
        assert(!strcmp(name, "load")); ++state.loadCalls;
        if (state.fault == SYSTEM_LOAD_THROW) state.pending = SYSTEM_LOAD_THROW;
    }
    return result;
}

static int fake_dladdr(const void* address, Dl_info* result) { (void)address; result->dli_fname = "/virtual/libawt.so"; return 1; }
static char* fake_realpath(const char* input, char* output) { strcpy(output, input); return output; }
static void* fake_dlopen(const char* name, int flags) {
    (void)name; (void)flags; ++state.dlCalls; assert(!state.pending && !state.unchecked);
    return state.fault == DLOPEN_NULL ? NULL : (void*)(uintptr_t)0x200;
}
static void* fake_dlsym(void* handle, const char* name) { (void)handle; (void)name; return NULL; }
static char* fake_dlerror(void) { return "injected-dlopen-error"; }
#define dladdr fake_dladdr
#define realpath fake_realpath
#define dlopen fake_dlopen
#define dlsym fake_dlsym
#define dlerror fake_dlerror
#include AMCL_AWT_SOURCE
#undef dladdr
#undef realpath
#undef dlopen
#undef dlsym
#undef dlerror

static void reset(enum Fault fault, int headless) {
    memset(&state, 0, sizeof(state)); state.fault = fault; state.headless = headless;
    currentEnv = &functions; jvm = &fakeVm; awtHandle = NULL;
#ifndef AMCL_AWT_OLD
    // 测试隔离时才重置成功缓存；被测的失败重试/并发/重入过程不重置它。
    __atomic_store_n(&awtHeadlessState, -1, __ATOMIC_RELAXED);
#endif
    if (fault == PREEXISTING) state.pending = PREEXISTING;
}
static void init(void) {
    memset(&functions, 0, sizeof(functions));
    functions.FindClass = findClass; functions.GetStaticMethodID = getStaticMethod;
    functions.CallStaticBooleanMethod = callBoolean; functions.ExceptionCheck = exceptionCheck;
    functions.ExceptionClear = exceptionClear; functions.FatalError = fatalError;
    functions.DeleteLocalRef = deleteLocalRef; functions.NewStringUTF = newString;
}

#ifndef AMCL_AWT_OLD
static void* concurrent(void* opaque) {
    struct State* result = opaque;
    memset(&state, 0, sizeof(state)); state.headless = 1; state.useBarrier = 1; currentEnv = &functions;
    assert(AWTIsHeadless() == JNI_TRUE); *result = state; return NULL;
}
static void positives(void) {
    // 两个后端均执行完整OnLoad，并分别覆盖setProperty的合法NULL/非NULL返回值。
    for (int value = 0; value <= 1; ++value) {
        reset(NONE, value);
        state.nullProperty = !value;
        assert(JNI_OnLoad(&fakeVm, NULL) == JNI_VERSION_1_2);
        assert(strstr(state.backend, value ? "libawt_headless.so" : "libawt_xawt.so"));
        assert(!state.live && !state.unchecked && !state.uncheckedUse && !state.ordinaryAfterPending && !state.wrongThread);
        int queries = state.booleanCalls, envs = state.getEnvCalls;
        for (int n = 0; n < 100000; ++n) assert(AWTIsHeadless() == value);
        assert(state.booleanCalls == queries && state.getEnvCalls == envs);
    }
    // 逐点注入异常、NULL-only和系统库加载失败；首个异常必须原样保留。
    for (int fault = ENV_NULL; fault <= DLOPEN_NULL; ++fault) {
        reset((enum Fault)fault, 1);
        assert(JNI_OnLoad(&fakeVm, NULL) == JNI_ERR);
        int expected = fault;
        if (fault == ENV_NULL) expected = 0;
        if (fault == CLASS_NULL || fault == METHOD_NULL || fault == PROP_NULL ||
            fault == MANAGER_NULL || fault == PATH_NULL) expected = 777;
        if (fault == DLOPEN_NULL) expected = 778;
        assert(state.pending == expected);
        assert(!state.live && !state.unchecked && !state.uncheckedUse && !state.ordinaryAfterPending && !state.wrongThread);
        assert(!state.clears && !state.fatalCalls);
        if (fault < PATH_THROW) assert(state.loadCalls == 0 && state.dlCalls == 0);
        if (fault == PATH_THROW || fault == PATH_NULL || fault == SYSTEM_LOAD_THROW) assert(state.dlCalls == 0);
        printf("PASS OnLoad fault=%d pending=%d localRefs=%d downstreamLoad=%d\n", fault, state.pending, state.live, state.loadCalls);
    }
    // 每个冷查询失败都不能发布默认false；清理注入故障后必须真正重新执行Java查询。
    for (int fault = ENV_NULL; fault <= BOOLEAN_THROW; ++fault) {
        reset((enum Fault)fault, 0);
        assert(AWTIsHeadless() == JNI_TRUE && !state.live);
        int attempts = state.booleanCalls;
        state.pending = 0; state.fault = NONE;
        assert(AWTIsHeadless() == JNI_FALSE && state.booleanCalls == attempts + 1 && !state.live);
    }
    // Java类初始化可能重入，不允许持非递归锁跨JNI；成功热路径不再访问Java/线程env。
    reset(NONE, 1); state.reenter = 1;
    assert(AWTIsHeadless() == JNI_TRUE && state.booleanCalls == 2 && !state.live && !state.unchecked);
    reset(NONE, 1);
    enum { Threads = 16 }; pthread_t threads[Threads]; struct State results[Threads];
    assert(pthread_barrier_init(&barrier, NULL, Threads) == 0);
    for (int n = 0; n < Threads; ++n) assert(pthread_create(&threads[n], NULL, concurrent, &results[n]) == 0);
    for (int n = 0; n < Threads; ++n) {
        assert(pthread_join(threads[n], NULL) == 0);
        assert(results[n].booleanCalls == 1 && results[n].getEnvCalls == 1 && !results[n].live &&
               !results[n].pending && !results[n].unchecked && !results[n].wrongThread);
    }
    assert(pthread_barrier_destroy(&barrier) == 0);
    puts("PASS JDK8 AWT JNI: 2 backend paths, 18 failure stages, 200000 cached calls, 9 failed-query retries, reentry, 16 current-thread environments");
}
#endif

int main(int argc, char** argv) {
    init();
#ifdef AMCL_AWT_OLD
    assert(argc == 2);
    if (!strcmp(argv[1], "unchecked")) {
        reset(NONE, 1); assert(AWTIsHeadless() == JNI_TRUE && state.unchecked == 1);
        puts("REPRO old AWTIsHeadless returns without checking CallStaticBooleanMethod"); return 77;
    }
    assert(!strcmp(argv[1], "poison"));
    reset(CLASS_THROW, 1); assert(AWTIsHeadless() == JNI_TRUE && state.pending);
    state.pending = 0; state.fault = NONE;
    assert(AWTIsHeadless() == JNI_FALSE && state.booleanCalls == 0);
    puts("REPRO old failed AWT headless lookup poisons cache with false"); return 77;
#else
    (void)argc; (void)argv; positives(); return 0;
#endif
}
