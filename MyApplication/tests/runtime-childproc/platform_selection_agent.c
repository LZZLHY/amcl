/* 仅宿主资格：在真实ProcessImpl类准备事件注册新增JNI方法，让完整候选Java类执行。
 * uname返回值由固定测试参数模拟，实际生产谓词使用同一header；不改Java属性来伪装身份。
 * 这不替代目标uname/JNI集成；目标最终以新JDK默认extended运行验证。
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <jni.h>
#include <jvmti.h>
#include <sys/utsname.h>
static char kernel_name[64];
static int wanted_calls, actual_calls, registered;
static int mock_uname(struct utsname* identity) {
    if (strcmp(kernel_name, "error") == 0) { errno = EIO; return -1; }
    memset(identity, 0, sizeof(*identity));
    strcpy(identity->sysname, kernel_name);
    return 0;
}
#define AMCL_PROCESS_UNAME mock_uname
#include "amcl_process_platform.h"

static jboolean JNICALL identify(JNIEnv* env, jclass clazz) {
    (void)env; (void)clazz;
    ++actual_calls;
    return amcl_process_is_ohos() ? JNI_TRUE : JNI_FALSE;
}
static void JNICALL class_prepared(jvmtiEnv* tooling, JNIEnv* env, jthread thread, jclass clazz) {
    (void)thread;
    char* signature = NULL;
    if ((*tooling)->GetClassSignature(tooling, clazz, &signature, NULL) != JVMTI_ERROR_NONE) abort();
    if (strcmp(signature, "Ljava/lang/ProcessImpl;") == 0) {
        JNINativeMethod binding = {"isOhosPlatform", "()Z", (void*)&identify};
        if ((*env)->RegisterNatives(env, clazz, &binding, 1) != JNI_OK || (*env)->ExceptionCheck(env)) {
            (*env)->ExceptionDescribe(env);
            (*env)->FatalError(env, "ProcessImpl candidate native registration failed");
        }
        ++registered;
    }
    if ((*tooling)->Deallocate(tooling, (unsigned char*)signature) != JVMTI_ERROR_NONE) abort();
}
static void JNICALL vm_death(jvmtiEnv* tooling, JNIEnv* env) {
    (void)tooling; (void)env;
    if (registered != 1 || actual_calls != wanted_calls) {
        fprintf(stderr, "platform JNI audit failed registered=%d calls=%d wanted=%d\n",
                registered, actual_calls, wanted_calls);
        abort();
    }
    printf("PASS platform JNI registration=1 actualQueries=%d simulatedKernel=%s\n", actual_calls, kernel_name);
}
JNIEXPORT jint JNICALL Agent_OnLoad(JavaVM* vm, char* options, void* reserved) {
    (void)reserved;
    if (!options || strlen(options) >= sizeof(kernel_name)) return JNI_ERR;
    char* separator = strrchr(options, ':');
    if (!separator || (strcmp(separator, ":0") && strcmp(separator, ":1"))) return JNI_ERR;
    size_t size = (size_t)(separator - options);
    memcpy(kernel_name, options, size); kernel_name[size] = '\0';
    wanted_calls = separator[1] - '0';
    jvmtiEnv* tooling = NULL;
    if ((*vm)->GetEnv(vm, (void**)&tooling, JVMTI_VERSION_1_2) != JNI_OK) return JNI_ERR;
    jvmtiEventCallbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.ClassPrepare = class_prepared; callbacks.VMDeath = vm_death;
    if ((*tooling)->SetEventCallbacks(tooling, &callbacks, sizeof(callbacks)) != JVMTI_ERROR_NONE ||
        (*tooling)->SetEventNotificationMode(tooling, JVMTI_ENABLE, JVMTI_EVENT_CLASS_PREPARE, NULL) != JVMTI_ERROR_NONE ||
        (*tooling)->SetEventNotificationMode(tooling, JVMTI_ENABLE, JVMTI_EVENT_VM_DEATH, NULL) != JVMTI_ERROR_NONE) return JNI_ERR;
    return JNI_OK;
}
