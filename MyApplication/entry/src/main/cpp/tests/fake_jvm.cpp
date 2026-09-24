// fake_jvm.cpp — 模拟 JVM 的共享库，用于验证 dlopen 加载能力
// 这个文件会被编译为 libfakejvm.so，然后在运行时通过 dlopen 加载

#include <cstdio>
#include <cstring>
#include <cstdint>

// 模拟 JNI 类型定义（不依赖真实 jni.h）
typedef int32_t jint;
typedef int64_t jlong;
typedef uint8_t jboolean;

struct JavaVM;
struct JNIEnv;

typedef struct {
    jint version;
    const char* name;
    void* vm;
    jint nOptions;
} JavaVMInitArgs;

// 模拟 JNI_CreateJavaVM 接口
extern "C" {

// 版本信息
const char* FakeJVM_GetVersion() {
    return "FakeJVM 1.0 (JNI compatibility test)";
}

// 模拟 JNI_CreateJavaVM
jint FakeJVM_CreateJavaVM(JavaVM** pvm, JNIEnv** penv, JavaVMInitArgs* args) {
    // 模拟成功创建 JVM
    *pvm = (JavaVM*)0xDEADBEEF;
    *penv = (JNIEnv*)0xCAFEBABE;
    return 0; // JNI_OK
}

// 模拟运行 Java 方法
const char* FakeJVM_RunHelloWorld() {
    return "Hello from FakeJVM! JNI call convention works.";
}

// 模拟获取 JVM 信息
const char* FakeJVM_GetInfo() {
    static char buf[512];
    snprintf(buf, sizeof(buf),
        "FakeJVM Info:\n"
        "  sizeof(jint)=%zu\n"
        "  sizeof(jlong)=%zu\n"
        "  sizeof(jboolean)=%zu\n"
        "  sizeof(void*)=%zu\n"
        "  JNI interface simulation: OK\n",
        sizeof(jint), sizeof(jlong), sizeof(jboolean), sizeof(void*));
    return buf;
}

// 模拟复杂的 JNI 函数指针表（验证函数指针调用约定）
typedef const char* (*JNIMethod)(void);

struct FakeJNINativeInterface {
    jint version;
    JNIMethod GetVersion;
    JNIMethod RunHelloWorld;
    JNIMethod GetInfo;
};

static FakeJNINativeInterface g_fakeJNI = {
    .version = 0x00110000, // JNI 1.1
    .GetVersion = FakeJVM_GetVersion,
    .RunHelloWorld = FakeJVM_RunHelloWorld,
    .GetInfo = FakeJVM_GetInfo,
};

// 获取 JNI 函数指针表
FakeJNINativeInterface* FakeJVM_GetJNIInterface() {
    return &g_fakeJNI;
}

} // extern "C"
