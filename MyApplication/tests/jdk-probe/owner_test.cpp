/** 真实生产 NAPI 入口的失败注入：引用、工作项、handle scope 和 FD 必须全部配对。 */
#include "napi/napi_jdk_probe.h"
#include "napi/napi_helpers.h"
#include "jvm/elf_loader.h"
#include <AbilityKit/native_child_process.h>
#include <cassert>
#include <cstdio>
#include <dirent.h>
#include <new>
#include <string>

struct napi_async_work__ {
    napi_async_execute_callback execute;
    napi_async_complete_callback complete;
    void* data;
};
struct napi_ref__ {};
namespace {
int fault = 0, refs = 0, works = 0, scopes = 0, callbacks = 0, stringCalls = 0, registered = 0;
napi_async_work queued = nullptr;
napi_env env = reinterpret_cast<napi_env>(1);
napi_value value = reinterpret_cast<napi_value>(1);
int fdCount() {
    DIR* directory = opendir("/proc/self/fd");
    assert(directory);
    int count = 0;
    while (readdir(directory)) ++count;
    closedir(directory);
    return count;
}
}
namespace amcl::napi {
bool ReadStringValue(napi_env, napi_value, std::string& output) {
    if (fault == 5) throw std::bad_alloc();
    output = "/tmp";
    return true;
}
}
extern "C" {
// 本套件真实拒绝原生子进程启动，只验 NAPI 所有权；不能借空 loader 替身伪造设备 EH 通过。
elf_handle_t* elf_open(const char*) { assert(false && "child unwind probe must not run in owner test"); return nullptr; }
void* elf_sym(elf_handle_t*, const char*) { assert(false); return nullptr; }
void elf_close(elf_handle_t*) { assert(false); }
int elf_dlclose(void*) { assert(false && "child TLS probe must not run in owner test"); return -1; }
int elf_get_tls_stats(elf_tls_stats*) { assert(false && "child TLS stats must not run in owner test"); return EINVAL; }
void elf_set_search_path(const char*) { assert(false); }
const char* elf_error() { assert(false); return "unreachable"; }
napi_status napi_get_undefined(napi_env, napi_value* result) { *result = value; return napi_ok; }
napi_status napi_get_cb_info(napi_env, napi_callback_info, size_t* count, napi_value* args, napi_value*, void**) {
    *count = 2; args[0] = args[1] = value; return napi_ok;
}
napi_status napi_typeof(napi_env, napi_value, napi_valuetype* type) { *type = napi_function; return napi_ok; }
napi_status napi_throw_error(napi_env, const char*, const char*) { return napi_ok; }
napi_status napi_throw_type_error(napi_env, const char*, const char*) { return napi_ok; }
napi_status napi_create_reference(napi_env, napi_value, uint32_t, napi_ref* result) {
    if (fault == 1) return napi_generic_failure;
    *result = new napi_ref__; ++refs; return napi_ok;
}
napi_status napi_delete_reference(napi_env, napi_ref ref) { delete ref; --refs; return napi_ok; }
napi_status napi_get_reference_value(napi_env, napi_ref, napi_value* result) {
    if (fault == 6) return napi_generic_failure;
    *result = value; return napi_ok;
}
napi_status napi_create_string_utf8(napi_env, const char*, size_t, napi_value* result) {
    ++stringCalls;
    if ((fault == 2 && stringCalls == 1) || (fault == 7 && stringCalls == 2)) return napi_generic_failure;
    *result = value; return napi_ok;
}
napi_status napi_open_handle_scope(napi_env, napi_handle_scope* result) {
    if (fault == 8) return napi_generic_failure;
    *result = reinterpret_cast<napi_handle_scope>(1); ++scopes; return napi_ok;
}
napi_status napi_close_handle_scope(napi_env, napi_handle_scope) { --scopes; return napi_ok; }
napi_status napi_create_async_work(napi_env, napi_value, napi_value,
        napi_async_execute_callback execute, napi_async_complete_callback complete, void* data, napi_async_work* result) {
    if (fault == 3) return napi_generic_failure;
    *result = new napi_async_work__{execute, complete, data}; ++works; return napi_ok;
}
napi_status napi_queue_async_work(napi_env, napi_async_work work) {
    if (fault == 4) return napi_generic_failure;
    queued = work; return napi_ok;
}
napi_status napi_delete_async_work(napi_env, napi_async_work work) { delete work; --works; return napi_ok; }
napi_status napi_call_function(napi_env, napi_value, napi_value, size_t, const napi_value*, napi_value*) {
    ++callbacks; return fault == 9 ? napi_pending_exception : napi_ok;
}
int OH_Ability_RegisterNativeChildProcessExitCallback(OH_Ability_OnNativeChildProcessExit) { ++registered; return 0; }
int OH_Ability_UnregisterNativeChildProcessExitCallback(OH_Ability_OnNativeChildProcessExit) { --registered; return 0; }
int OH_Ability_StartNativeChildProcess(const char*, NativeChildProcess_Args, NativeChildProcess_Options, int32_t*) {
    return 801; // 实际拒绝启动，不制造一个假 PID 或成功事件。
}
}
int main() {
    const int descriptors = fdCount();
    for (fault = 1; fault <= 5; ++fault) {
        stringCalls = 0;
        RunJdkPlatformProbeNapi(env, nullptr);
        assert(!queued && !refs && !works && !scopes && !registered);
        assert(fdCount() == descriptors);
    }
    // 先执行真正的 SDK 启动拒绝路径，再覆盖完成回调中的 NAPI 失败/异常和取消。
    for (int selected : {0, 6, 7, 8, 9, 10}) {
        fault = selected; stringCalls = 0;
        const int prior = callbacks;
        RunJdkPlatformProbeNapi(env, nullptr);
        assert(queued && refs == 1 && works == 1);
        auto* work = queued; queued = nullptr;
        if (fault != 10) work->execute(env, work->data);
        work->complete(env, fault == 10 ? napi_cancelled : napi_ok, work->data);
        assert(!refs && !works && !scopes && !registered);
        assert(callbacks - prior == ((fault == 0 || fault == 9) ? 1 : 0));
        assert(fdCount() == descriptors);
    }
    puts("PASS production JDK probe owner: 11 input/queue/completion/cancellation cases; refs/work/scopes/fds balanced");
}
