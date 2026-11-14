/**
 * 宿主 SDK 边界夹具。以真实独立 DSO 导出 Start/Kill，验证生产入口能够从静态依赖的
 * Start 地址认领同一已加载 provider 并保持其寿命。Start 始终拒绝，没有实际子进程/JVM。
 */
#include <AbilityKit/native_child_process.h>
extern "C" void AmclJavaQualificationTestExit(int32_t pid, int32_t signal);
extern "C" int OH_Ability_StartNativeChildProcess(
    const char*, NativeChildProcess_Args, NativeChildProcess_Options, int32_t*) {
    return 801;
}
extern "C" int OH_Ability_KillChildProcess(int32_t pid) {
    AmclJavaQualificationTestExit(pid, 9);
    return 0;
}
