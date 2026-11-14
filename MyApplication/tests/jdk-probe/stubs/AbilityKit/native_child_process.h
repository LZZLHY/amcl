// 只模拟 SDK 拒绝创建的失败路径，不能将本测试作为设备/原生进程资格。
#pragma once
#include <stdint.h>
typedef int Ability_NativeChildProcess_ErrCode;
enum NativeChildProcess_IsolationMode { NCP_ISOLATION_MODE_NORMAL = 0, NCP_ISOLATION_MODE_ISOLATED = 1 };
struct NativeChildProcess_Fd { char* fdName; int32_t fd; NativeChildProcess_Fd* next; };
struct NativeChildProcess_FdList { NativeChildProcess_Fd* head; };
struct NativeChildProcess_Args { char* entryParams; NativeChildProcess_FdList fdList; };
struct NativeChildProcess_Options { NativeChildProcess_IsolationMode isolationMode; int64_t reserved; };
typedef void (*OH_Ability_OnNativeChildProcessExit)(int32_t, int32_t);
extern "C" {
int OH_Ability_RegisterNativeChildProcessExitCallback(OH_Ability_OnNativeChildProcessExit);
int OH_Ability_UnregisterNativeChildProcessExitCallback(OH_Ability_OnNativeChildProcessExit);
int OH_Ability_StartNativeChildProcess(const char*, NativeChildProcess_Args, NativeChildProcess_Options, int32_t*);
}
