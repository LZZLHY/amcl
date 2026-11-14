/**
 * UI 向音频 owner 发布政策的薄桥。原子政策先更新，慢 Stop/Release 在异步工作线程执行。
 * 返回的 Promise 只证明控制操作完成，不代表真实设备、模型或任何 AI 模组已经通过验收。
 */
#include "napi_audio.h"
#include "../audio_host_policy.h"
#include "napi_helpers.h"
#include <new>

namespace {
struct PolicyWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    int result = 0;
};

/** 工作线程仅调用 Native 政策接点；异常转具名失败，不能跨 NAPI C 回调边界传播。 */
void Execute(napi_env, void* raw) {
    auto* task = static_cast<PolicyWork*>(raw);
    try { task->result = amclModAudioApplyPolicy(); }
    catch (...) { task->result = -4; }
}

/** ArkTS 事件线程完成回执和任务释放，不在这里停止设备或等待音频回调。 */
void Complete(napi_env env, napi_status status, void* raw) {
    auto* task = static_cast<PolicyWork*>(raw);
    napi_value result = nullptr;
    napi_create_int32(env, status == napi_ok ? task->result : -4, &result);
    napi_resolve_deferred(env, task->deferred, result);
    napi_delete_async_work(env, task->work);
    delete task;
}

/** 严格读取两个布尔事实，先原子发布再安排慢收敛；排队失败保持拒绝并向调用方报错。 */
napi_value SetPolicy(napi_env env, napi_callback_info info) {
    size_t count = 2;
    napi_value args[2] = {nullptr, nullptr};
    bool enabled = false, foreground = false;
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    if (count != 2 || napi_get_value_bool(env, args[0], &enabled) != napi_ok ||
        napi_get_value_bool(env, args[1], &foreground) != napi_ok) {
        napi_throw_type_error(env, nullptr, "audioSetPolicy requires enabled and foreground booleans");
        return nullptr;
    }
    // 后台/关闭的拒绝事实无需等待线程池；后台线程只做设备和阻塞等待的收敛。
    amclModAudioSetPolicy(enabled, foreground);
    auto* task = new(std::nothrow) PolicyWork;
    if (!task) {
        napi_throw_error(env, nullptr, "Cannot allocate audio policy work");
        return nullptr;
    }
    napi_value promise = nullptr, name = nullptr;
    if (napi_create_promise(env, &task->deferred, &promise) != napi_ok ||
        napi_create_string_utf8(env, "amclAudioPolicy", NAPI_AUTO_LENGTH, &name) != napi_ok ||
        napi_create_async_work(env, nullptr, name, Execute, Complete, task, &task->work) != napi_ok) {
        delete task;
        napi_throw_error(env, nullptr, "Cannot prepare audio policy work");
        return nullptr;
    }
    if (napi_queue_async_work(env, task->work) != napi_ok) {
        napi_value reason = nullptr;
        napi_create_string_utf8(env, "Cannot queue audio policy work", NAPI_AUTO_LENGTH, &reason);
        napi_reject_deferred(env, task->deferred, reason);
        napi_delete_async_work(env, task->work);
        delete task;
    }
    return promise;
}

/** 根路径只在装配时冻结，不接受相对路径或在本局开始后切换到另一用户政策文件。 */
napi_value ConfigureRoot(napi_env env, napi_callback_info info) {
    char directory[4096] = {};
    const bool valid = amcl::napi::ReadStringArg(env, info, directory, sizeof(directory)) &&
        amclModAudioConfigureRoot(directory);
    return amcl::napi::MakeBoolResult(env, valid);
}
}

namespace amcl::napi {
/** 只登记接口，模块加载本身不会获得麦克风权限或启动音频流。 */
void registerAudioNapi(napi_env env, napi_value exports) {
    const napi_property_descriptor descriptors[] = {
        {"audioSetPolicy", nullptr, SetPolicy, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"audioConfigurePolicyRoot", nullptr, ConfigureRoot, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, 2, descriptors);
}
}
