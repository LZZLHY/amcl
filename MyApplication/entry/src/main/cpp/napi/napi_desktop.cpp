#include "../platform/desktop_gamepad.h"
#include "napi_desktop.h"
#include "napi_helpers.h"
#include "../platform/native_gl.h"
#include "../platform/desktop_command_queue.h"
#include "../platform/desktop_event_signal.h"
#include <database/pasteboard/oh_pasteboard.h>
#include <database/udmf/udmf.h>
#include <database/udmf/uds.h>
#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <thread>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

namespace {
std::mutex hostMutex;
std::condition_variable completionChanged;
std::thread::id uiThread;
bool clipboardPermissionRequested = false;
amcl::desktop::CommandQueue commands;
amcl::desktop::EventSignal eventSignal;
std::deque<std::string> drops;
uint64_t EventEpoch() { return eventSignal.epoch(); }
int32_t WaitEvents(uint64_t observed, int64_t timeout) { return eventSignal.wait(observed, timeout); }
void WakeEvents() { eventSignal.wake(); }
int32_t TakeDrop(char* output, size_t size) {
    std::lock_guard<std::mutex> lock(hostMutex);
    if (!output || drops.empty()) return 0;
    if (drops.front().size() > size) return -1;
    const int32_t count = static_cast<int32_t>(drops.front().size());
    memcpy(output, drops.front().data(), count); drops.pop_front(); return count;
}
AmclDesktopSnapshot state{};
napi_threadsafe_function wake = nullptr;
napi_env ownerEnv = nullptr;
std::atomic<bool> published{false};

uint64_t Submit(int32_t kind, int32_t a, int32_t b, int32_t c, int32_t d, const char* text) {
    std::lock_guard<std::mutex> lock(hostMutex);
    if (!wake) return 0;
    amcl::desktop::Command command;
    command.kind = kind; command.a = a; command.b = b; command.c = c; command.d = d;
    if (text) command.text = text;
    const uint64_t sequence = commands.submit(std::move(command));
    if (!sequence) return 0;
    const napi_status rc = napi_call_threadsafe_function(wake, nullptr, napi_tsfn_nonblocking);
    if (rc != napi_ok && rc != napi_queue_full) { commands.detach(); return 0; }
    return sequence;
}
bool RequestClipboardPermission() {
    uint64_t generation;
    {
        std::lock_guard<std::mutex> lock(hostMutex);
        if (!commands.active() || clipboardPermissionRequested || std::this_thread::get_id() == uiThread) return false;
        clipboardPermissionRequested = true; generation = commands.generation();
    }
    const uint64_t sequence = Submit(AMCL_DESKTOP_CLIPBOARD_PERMISSION, 0, 0, 0, 0, nullptr);
    if (!sequence) return false;
    std::unique_lock<std::mutex> lock(hostMutex);
    return completionChanged.wait_for(lock, std::chrono::seconds(2), [generation, sequence] {
        return !commands.active() || commands.generation() != generation || commands.completed() >= sequence;
    }) && commands.active() && commands.generation() == generation && commands.completed() >= sequence;
}
void Snapshot(AmclDesktopSnapshot* output) {
    if (!output) return;
    std::lock_guard<std::mutex> lock(hostMutex);
    *output = state;
    output->active = commands.active(); output->generation = commands.generation();
    output->accepted = commands.accepted(); output->completed = commands.completed();
    output->failed = commands.failed(); output->lastError = commands.lastError();
}
void RequestClose(int32_t requested) {
    std::lock_guard<std::mutex> lock(hostMutex);
    state.closeRequested = requested != 0;
    WakeEvents();
}

int32_t ClipboardRead(char* target, size_t capacity) {
    if (!target || capacity < 1) return -1;
    target[0] = '\0';
    OH_Pasteboard* board = OH_Pasteboard_Create();
    if (!board) return -1;
    if (!OH_Pasteboard_HasType(board, "text/plain")) { OH_Pasteboard_Destroy(board); return 0; }
    int error = 0;
    OH_UdmfData* data = OH_Pasteboard_GetData(board, &error);
    if (error && RequestClipboardPermission()) {
        if (data) OH_UdmfData_Destroy(data);
        error = 0; data = OH_Pasteboard_GetData(board, &error);
    }
    int32_t result = error ? -error : 0;
    if (data && !error) {
        unsigned count = 0;
        OH_UdmfRecord** records = OH_UdmfData_GetRecords(data, &count);
        OH_UdsPlainText* plain = OH_UdsPlainText_Create();
        if (plain) {
            for (unsigned index = 0; records && index < count; ++index) {
                if (OH_UdmfRecord_GetPlainText(records[index], plain) != 0) continue;
                const char* text = OH_UdsPlainText_GetContent(plain);
                if (text) {
                    const size_t length = strlen(text);
                    if (length >= capacity) result = -2;
                    else { memcpy(target, text, length + 1); result = static_cast<int32_t>(length); }
                }
                break;
            }
            OH_UdsPlainText_Destroy(plain);
        } else result = -1;
    }
    if (data) OH_UdmfData_Destroy(data);
    OH_Pasteboard_Destroy(board);
    return result;
}
int32_t ClipboardWrite(const char* text) {
    if (!text || strlen(text) > 4 * 1024 * 1024) return -1;
    OH_Pasteboard* board = OH_Pasteboard_Create();
    OH_UdmfData* data = OH_UdmfData_Create();
    OH_UdmfRecord* record = OH_UdmfRecord_Create();
    OH_UdsPlainText* plain = OH_UdsPlainText_Create();
    int result = -1;
    if (board && data && record && plain && OH_UdsPlainText_SetContent(plain, text) == 0 &&
        OH_UdmfRecord_AddPlainText(record, plain) == 0 && OH_UdmfData_AddRecord(data, record) == 0)
        result = OH_Pasteboard_SetData(board, data);
    if (plain) OH_UdsPlainText_Destroy(plain);
    if (record) OH_UdmfRecord_Destroy(record);
    if (data) OH_UdmfData_Destroy(data);
    if (board) OH_Pasteboard_Destroy(board);
    return result;
}
}

extern "C" __attribute__((visibility("default")))
const AmclDesktopHostV1* amclDesktopHostGetV1() {
    static const AmclDesktopHostV1 api = { AMCL_DESKTOP_HOST_MAGIC,
        sizeof(AmclDesktopHostV1), static_cast<uint32_t>(getpid()),
        Submit, Snapshot, RequestClose, ClipboardRead, ClipboardWrite, amcl::desktop::ReadGamepad,
        EventEpoch, WaitEvents, WakeEvents, TakeDrop };
    return published.load(std::memory_order_acquire) ? &api : nullptr;
}

namespace {
bool PublishDescriptor() {
    char path[160]{};
    snprintf(path, sizeof(path), "/data/storage/el2/base/files/.amcl_desktop_host_%d.lock", getpid());
    const int fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return false;
    bool ok = false;
    if (flock(fd, LOCK_EX) == 0) {
        const uintptr_t getter = reinterpret_cast<uintptr_t>(&amclDesktopHostGetV1);
        ok = pwrite(fd, &getter, sizeof(getter), 0) == sizeof(getter) && ftruncate(fd, sizeof(getter)) == 0;
        if (ok) published.store(true, std::memory_order_release);
        flock(fd, LOCK_UN);
    }
    close(fd); return ok;
}
void WakeJs(napi_env env, napi_value callback, void*, void*) {
    if (!env || !callback) return;
    napi_value receiver, result;
    napi_get_undefined(env, &receiver);
    napi_call_function(env, receiver, callback, 0, nullptr, &result);
}
void Cleanup(void* data) {
    napi_threadsafe_function old = nullptr;
    {
        std::lock_guard<std::mutex> lock(hostMutex);
        if (ownerEnv != static_cast<napi_env>(data)) return;
        old = wake; wake = nullptr; ownerEnv = nullptr; commands.detach();
        drops.clear(); WakeEvents();
        completionChanged.notify_all();
    }
    if (old) napi_release_threadsafe_function(old, napi_tsfn_abort);
}
bool Number(napi_env env, napi_value value, double& number) {
    return napi_get_value_double(env, value, &number) == napi_ok && std::isfinite(number);
}
bool Integer(napi_env env, napi_value value, double& number, double minimum, double maximum) {
    return Number(env, value, number) && number >= minimum && number <= maximum && std::trunc(number) == number;
}
void setNum(napi_env env, napi_value object, const char* key, double number) {
    napi_value value; napi_create_double(env, number, &value); napi_set_named_property(env, object, key, value);
}

struct NativeGlTask {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    amcl::desktop::NativeGlCapability capability;
    bool detailed = false;
    bool availabilityOnly = false;
};
void setBoolProp(napi_env env, napi_value object, const char* name, bool flag) {
    napi_value value; napi_get_boolean(env, flag, &value); napi_set_named_property(env, object, name, value);
}
void setStringProp(napi_env env, napi_value object, const char* name, const std::string& text) {
    napi_value value; napi_create_string_utf8(env, text.c_str(), text.size(), &value); napi_set_named_property(env, object, name, value);
}
napi_value NativeGlValidation(napi_env env, napi_callback_info) {
    return amcl::napi::MakeBoolResult(env, amcl::desktop::NativeGlValidationEnabled());
}
napi_value NativeGlCapability(napi_env env, napi_callback_info info) {
    auto* task = new NativeGlTask();
    size_t count = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    if (count >= 1) napi_get_value_bool(env, args[0], &task->detailed);
    if (count >= 2) napi_get_value_bool(env, args[1], &task->availabilityOnly);
    napi_value promise, name;
    napi_create_promise(env, &task->deferred, &promise);
    napi_create_string_utf8(env, "native-gl-capability", NAPI_AUTO_LENGTH, &name);
    const auto execute = [](napi_env, void* data) {
        auto* task = static_cast<NativeGlTask*>(data);
        task->capability = amcl::desktop::QueryNativeGlCapability(task->detailed, task->availabilityOnly);
    };
    const auto complete = [](napi_env env, napi_status status, void* data) {
        auto* task = static_cast<NativeGlTask*>(data);
        const auto& cap = task->capability; napi_value result; napi_create_object(env, &result);
        setBoolProp(env, result, "ready", status == napi_ok && cap.ready);
        setBoolProp(env, result, "systemLibrary", cap.systemLibrary);
        // 启动能力、首错和清理结果分别跨ABI传递，不把清理失败覆盖成一个含糊的stage。
        setBoolProp(env, result, "bootstrapConfigured", cap.bootstrapConfigured);
        setBoolProp(env, result, "cleanupComplete", cap.cleanupComplete);
        setBoolProp(env, result, "restartRequired", cap.restartRequired);
        setNum(env, result, "cleanupError", cap.cleanupError);
        setStringProp(env, result, "cleanupStage", cap.cleanupStage);
        setStringProp(env, result, "errorDomain", cap.errorDomain);
        setBoolProp(env, result, "requiredByProduct", amcl::desktop::NativeGlRequired());
        setBoolProp(env, result, "queryAvailable", cap.queryAvailable);
        setBoolProp(env, result, "querySupported", cap.querySupported);
        setBoolProp(env, result, "contextCreated", cap.contextCreated);
        setBoolProp(env, result, "pixelVerified", cap.pixelVerified);
        setNum(env, result, "error", cap.error);
        setStringProp(env, result, "stage", cap.stage);
        setStringProp(env, result, "version", cap.version);
        setStringProp(env, result, "vendor", cap.vendor);
        setStringProp(env, result, "renderer", cap.renderer);
        setStringProp(env, result, "renderDiagnostics", cap.renderDiagnostics);
        napi_resolve_deferred(env, task->deferred, result);
        napi_delete_async_work(env, task->work); delete task;
    };
    napi_status rc = napi_create_async_work(env, nullptr, name, execute, complete, task, &task->work);
    if (rc == napi_ok) rc = napi_queue_async_work(env, task->work);
    if (rc != napi_ok) {
        napi_value message, error; napi_create_string_utf8(env, "Native GL capability worker unavailable", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error); napi_reject_deferred(env, task->deferred, error);
        if (task->work) napi_delete_async_work(env, task->work); delete task;
    }
    return promise;
}

napi_value Attach(napi_env env, napi_callback_info info) {
    size_t count = 1; napi_value callback; napi_valuetype type;
    napi_get_cb_info(env, info, &count, &callback, nullptr, nullptr);
    if (count != 1 || napi_typeof(env, callback, &type) != napi_ok || type != napi_function)
        return amcl::napi::MakeIntResult(env, 0);
    napi_value name; napi_create_string_utf8(env, "desktop-window-commands", NAPI_AUTO_LENGTH, &name);
    napi_threadsafe_function next = nullptr;
    if (napi_create_threadsafe_function(env, callback, nullptr, name, 1, 1,
        nullptr, nullptr, nullptr, WakeJs, &next) != napi_ok) return amcl::napi::MakeIntResult(env, 0);
    napi_unref_threadsafe_function(env, next);
    napi_threadsafe_function old;
    uint64_t generation;
    {
        std::lock_guard<std::mutex> lock(hostMutex);
        old = wake; wake = next; ownerEnv = env; generation = commands.attach();
        uiThread = std::this_thread::get_id(); clipboardPermissionRequested = false;
        state = {}; state.decorated = 1; state.resizable = 1;
        drops.clear(); WakeEvents();
    }
    if (old) napi_release_threadsafe_function(old, napi_tsfn_abort);
    if (!PublishDescriptor()) { Cleanup(env); generation = 0; }
    napi_value result; napi_create_double(env, generation, &result); return result;
}
napi_value Detach(napi_env env, napi_callback_info info) {
    size_t count = 1; napi_value arg; double generation = 0;
    napi_get_cb_info(env, info, &count, &arg, nullptr, nullptr);
    if (count != 1 || !Number(env, arg, generation)) return amcl::napi::MakeUndefined(env);
    napi_threadsafe_function old = nullptr;
    {
        std::lock_guard<std::mutex> lock(hostMutex);
        if (ownerEnv == env && generation == commands.generation()) {
            old = wake; wake = nullptr; commands.detach();
            drops.clear(); WakeEvents();
            completionChanged.notify_all();
        }
    }
    if (old) napi_release_threadsafe_function(old, napi_tsfn_abort);
    return amcl::napi::MakeUndefined(env);
}
napi_value Take(napi_env env, napi_callback_info) {
    amcl::desktop::Command command;
    { std::lock_guard<std::mutex> lock(hostMutex);
      if (ownerEnv != env || !commands.take(command)) return amcl::napi::MakeUndefined(env); }
    napi_value result, text; napi_create_object(env, &result);
    setNum(env, result, "sequence", command.sequence); setNum(env, result, "generation", command.generation);
    setNum(env, result, "kind", command.kind); setNum(env, result, "a", command.a); setNum(env, result, "b", command.b);
    setNum(env, result, "c", command.c); setNum(env, result, "d", command.d);
    napi_create_string_utf8(env, command.text.c_str(), command.text.size(), &text);
    napi_set_named_property(env, result, "text", text); return result;
}
napi_value Complete(napi_env env, napi_callback_info info) {
    size_t count = 3; napi_value args[3]; double gen = 0, seq = 0, error = 0;
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    if (count != 3 || !Integer(env, args[0], gen, 1, 9007199254740991.0) ||
        !Integer(env, args[1], seq, 1, 9007199254740991.0) || !Integer(env, args[2], error, INT32_MIN, INT32_MAX))
        return amcl::napi::MakeBoolResult(env, false);
    std::lock_guard<std::mutex> lock(hostMutex);
    const bool accepted = ownerEnv == env && commands.complete(gen, seq, error);
    completionChanged.notify_all();
    return amcl::napi::MakeBoolResult(env, accepted);
}
napi_value GamepadMode(napi_env env, napi_callback_info info) {
    size_t count=1; napi_value value; bool enabled=false;
    napi_get_cb_info(env,info,&count,&value,nullptr,nullptr);
    if(count!=1 || napi_get_value_bool(env,value,&enabled)!=napi_ok) return amcl::napi::MakeBoolResult(env,false);
    return amcl::napi::MakeBoolResult(env,amcl::desktop::SetNativeGamepadMode(enabled));
}
napi_value GamepadFocus(napi_env env, napi_callback_info info) {
    size_t count=1; napi_value value; bool focused=false;
    napi_get_cb_info(env,info,&count,&value,nullptr,nullptr);
    if(count==1 && napi_get_value_bool(env,value,&focused)==napi_ok) amcl::desktop::SetGamepadFocus(focused);
    return amcl::napi::MakeUndefined(env);
}
napi_value CloseRequested(napi_env env, napi_callback_info info) {
    size_t count = 1; napi_value value; bool requested = false;
    napi_get_cb_info(env, info, &count, &value, nullptr, nullptr);
    if (count == 1 && napi_get_value_bool(env, value, &requested) == napi_ok) RequestClose(requested);
    return amcl::napi::MakeUndefined(env);
}
bool ReadNumbers(napi_env env, napi_value array, std::vector<double>& output) {
    bool isArray = false; uint32_t count = 0;
    if (napi_is_array(env, array, &isArray) != napi_ok || !isArray ||
        napi_get_array_length(env, array, &count) != napi_ok || count > 256) return false;
    for (uint32_t i = 0; i < count; ++i) {
        napi_value value; double number;
        if (napi_get_element(env, array, i, &value) != napi_ok || !Number(env, value, number) ||
            std::abs(number) > INT32_MAX) return false;
        output.push_back(number);
    }
    return true;
}
napi_value PublishState(napi_env env, napi_callback_info info) {
    size_t count = 4; napi_value args[4]; double generation;
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    std::vector<double> window, displays; std::vector<std::string> names;
    if (count != 4 || !Number(env, args[0], generation) || !ReadNumbers(env, args[1], window) ||
        !ReadNumbers(env, args[2], displays) || !amcl::napi::ReadStringArrayValue(env, args[3], names) ||
        window.size() != 13 || displays.size() % 13 || names.size() != displays.size() / 13 ||
        names.size() > AMCL_DESKTOP_MAX_DISPLAYS) return amcl::napi::MakeBoolResult(env, false);
    std::lock_guard<std::mutex> lock(hostMutex);
    if (ownerEnv != env || !commands.active() || generation != commands.generation())
        return amcl::napi::MakeBoolResult(env, false);
    state.windowId = window[0]; state.displayId = window[1]; state.x = window[2]; state.y = window[3];
    state.width = window[4]; state.height = window[5]; state.status = window[6];
    state.decorated = window[7]; state.resizable = window[8]; state.displayCount = names.size();
    state.frameLeft=window[9]; state.frameTop=window[10]; state.frameRight=window[11]; state.frameBottom=window[12];
    for (size_t i = 0; i < names.size(); ++i) {
        const double* v = displays.data() + i * 13; auto& d = state.displays[i];
        d.id=v[0]; d.x=v[1]; d.y=v[2]; d.width=v[3]; d.height=v[4];
        d.workX=v[5]; d.workY=v[6]; d.workWidth=v[7]; d.workHeight=v[8];
        d.scale=v[9]; d.refreshRate=v[10]; d.widthMM=v[11]; d.heightMM=v[12];
        snprintf(d.name, sizeof(d.name), "%s", names[i].c_str());
    }
    WakeEvents();
    return amcl::napi::MakeBoolResult(env, true);
}

napi_value PublishDrop(napi_env env, napi_callback_info info) {
    size_t count=1; napi_value arg; std::vector<std::string> paths;
    napi_get_cb_info(env,info,&count,&arg,nullptr,nullptr);
    if(count!=1 || !amcl::napi::ReadStringArrayValue(env,arg,paths) || paths.empty() || paths.size()>32)
        return amcl::napi::MakeBoolResult(env,false);
    std::string packet;
    for(const auto& path:paths) {
        if(path.empty() || path[0]!='/' || path.find('\0')!=std::string::npos || path.size()>4096)
            return amcl::napi::MakeBoolResult(env,false);
        packet.append(path); packet.push_back('\0');
    }
    if(packet.size()>65536) return amcl::napi::MakeBoolResult(env,false);
    std::lock_guard<std::mutex> lock(hostMutex);
    if(ownerEnv!=env || !commands.active() || drops.size()>=8) return amcl::napi::MakeBoolResult(env,false);
    drops.push_back(std::move(packet)); WakeEvents(); return amcl::napi::MakeBoolResult(env,true);
}
}
namespace amcl::napi {
void registerDesktopNapi(napi_env env, napi_value exports) {
    const napi_property_descriptor methods[] = {
        {"desktopPublishDrop", nullptr, PublishDrop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"desktopSetGamepadNativeMode", nullptr, GamepadMode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"desktopGamepadFocus", nullptr, GamepadFocus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getNativeGlCapability", nullptr, NativeGlCapability, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeGlValidationEnabled", nullptr, NativeGlValidation, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"desktopAttach", nullptr, Attach, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"desktopDetach", nullptr, Detach, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"desktopTakeCommand", nullptr, Take, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"desktopCompleteCommand", nullptr, Complete, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"desktopPublishState", nullptr, PublishState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"desktopRequestClose", nullptr, CloseRequested, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(methods)/sizeof(methods[0]), methods);
    napi_add_env_cleanup_hook(env, Cleanup, env);
}
}

extern "C" void amclDesktopNotifyHostEvent() { WakeEvents(); }
