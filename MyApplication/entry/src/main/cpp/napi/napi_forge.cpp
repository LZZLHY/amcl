/**
 * napi_forge.cpp — Forge/NeoForge 安装 NAPI 实现
 *
 * 核心逻辑：fork 子进程跑单个 processor（干净 classpath + 显式 cwd，详见 ../jvm/fork_run_java.h），
 * NAPI 层只负责协议解析 + 异步 worker 调度，避免阻塞 ArkTS 主线程。
 *
 * 历史：曾有 RunForgeInstaller（跑 bangbang93 bootstrapper 的同进程 ClientInstall）；该路径已被
 * 自实现的逐 processor 独立 JVM（RunJavaProcessor）取代并删除，见 NeoForge适配方案.md 附录 Z。
 */
#include "napi_forge.h"
#include "napi_helpers.h"

#include <hilog/log.h>

#include <string>
#include <vector>
#include <climits>
#include <memory>
#include <new>
#include <stdexcept>
#include <cmath>
#include <map>
#include <mutex>

#include "../jvm/fork_run_java.h"

#undef LOG_TAG
#define LOG_TAG "NAPI_FORGE"

namespace {

#define NAPI_FUNC(name, fn) \
    { name, nullptr, fn, nullptr, nullptr, nullptr, napi_default, nullptr }

// 仅主进程的控制API/异步完成访问此表；不持锁跨fork、wait、JNI或NAPI调用。
// weak_ptr 不延长任务寿命，完成/入队失败时按对象身份删除，防止旧回调删除同名新任务。
std::mutex processorRequestsMutex;
std::map<std::string, std::weak_ptr<amcl::jvm::ProcessorControl>> processorRequests;
void RemoveProcessorRequest(const std::string& id, const std::shared_ptr<amcl::jvm::ProcessorControl>& control) {
    if (id.empty()) return;
    std::lock_guard<std::mutex> lock(processorRequestsMutex);
    const auto found = processorRequests.find(id);
    if (found != processorRequests.end() && found->second.lock() == control) processorRequests.erase(found);
}

// ============================================================
//  RunJavaProcessor — 跑单个 Forge/NeoForge processor（任意 args + 显式 cwd）
//  签名：runJavaProcessor(filesDir, jdkVersion, xmxMb, classpath, mainClass,
//                         args: string[], workDir, logFile): Promise<number>
//  每个 processor 一个干净 classpath（只含其声明的 jar）的独立 JVM，杜绝 installer.jar
//  shaded 类（joptsimple/gson）泄漏（FCL/HMCL 同款思路）。
// ============================================================
/**
 * 任务只在 queue 成功后交给 complete；解析/建工作项失败仍由当前 NAPI 线程销毁。
 * 预先保留完成错误对象，使 execute 分配失败及完成时创建数值失败也能拒绝 Promise，
 * 不把取消或 NAPI 错误转换成默认 result=0 的成功。
 */
struct ProcessorData {
    napi_env env = nullptr;
    std::string filesDir, jdkVersion, classpath, mainClass, workDir, logFile;
    std::vector<std::string> args;
    int xmxMb = 2048;
    int result = -1;
    const char* nativeFailure = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    napi_ref completionError = nullptr;
    std::string requestId;
    std::shared_ptr<amcl::jvm::ProcessorControl> control;
    ~ProcessorData() {
        // 所有销毁均发生在输入/完成 NAPI 线程；execute 只借用对象，不释放它。
        if (work) napi_delete_async_work(env, work);
        if (completionError) napi_delete_reference(env, completionError);
        RemoveProcessorRequest(requestId, control);
    }
};

/** C 接口不能表示内嵌 NUL；完整动态读取之后准确拒绝，绝不截短成另一个路径或参数。 */
bool ReadProcessorString(napi_env env, napi_value value, std::string& target) {
    return amcl::napi::ReadStringValue(env, value, target) && target.find('\0') == std::string::npos;
}

void ProcessorExecute(napi_env, void* data) {
    auto& job = *static_cast<ProcessorData*>(data);
    try {
        std::vector<const char*> arguments;
        arguments.reserve(job.args.size());
        for (const auto& argument : job.args) arguments.push_back(argument.c_str());
        if (job.control) {
            job.result = amcl::jvm::RunControlledProcessor(job.filesDir.c_str(), job.jdkVersion.c_str(),
                job.classpath.c_str(), job.mainClass.c_str(), static_cast<int>(arguments.size()),
                arguments.empty() ? nullptr : arguments.data(), job.workDir.c_str(),
                job.logFile.empty() ? nullptr : job.logFile.c_str(), job.xmxMb, *job.control);
        } else {
            job.result = forkRunJavaCwd(job.filesDir.c_str(), job.jdkVersion.c_str(),
                job.classpath.c_str(), job.mainClass.c_str(), static_cast<int>(arguments.size()),
                arguments.empty() ? nullptr : arguments.data(), job.workDir.c_str(),
                job.logFile.empty() ? nullptr : job.logFile.c_str(), job.xmxMb);
        }
    } catch (const std::exception& error) {
        if (job.control) job.control->finish(-1);
        job.nativeFailure = "processor native execution failed";
        OH_LOG_ERROR(LOG_APP, "Processor native failure: %{public}s", error.what());
    } catch (...) {
        if (job.control) job.control->finish(-1);
        job.nativeFailure = "processor native execution failed with unknown exception";
        OH_LOG_ERROR(LOG_APP, "Processor native failure: unknown exception");
    }
}

/** 完成状态来自 NAPI 和真实进程结果；被取消且未执行的任务不会向 JavaScript 返回 exit0。 */
void ProcessorComplete(napi_env env, napi_status status, void* data) {
    std::unique_ptr<ProcessorData> job(static_cast<ProcessorData*>(data));
    napi_value result = nullptr;
    const bool succeeded = status == napi_ok && !job->nativeFailure &&
        napi_create_int32(env, job->result, &result) == napi_ok;
    napi_status settled = napi_generic_failure;
    if (succeeded) {
        settled = napi_resolve_deferred(env, job->deferred, result);
    } else {
        // 已挂起的 JS 异常优先交给调用者；没有异常时使用事先创建的资源错误。
        bool pending = false;
        if (napi_is_exception_pending(env, &pending) == napi_ok && pending) {
            napi_get_and_clear_last_exception(env, &result);
        }
        if (!result) napi_get_reference_value(env, job->completionError, &result);
        if (result) settled = napi_reject_deferred(env, job->deferred, result);
    }
    if (settled != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "Processor promise completion failed napi_status=%{public}d", static_cast<int>(settled));
        // NAPI 环境终止等异常状态下不能保证交付；仍配对清理，绝不日志写成任务成功。
    }
}

napi_value RunJavaProcessor(napi_env env, napi_callback_info info) try {
    size_t count = 10;
    napi_value arguments[10]{};
    if (napi_get_cb_info(env, info, &count, arguments, nullptr, nullptr) != napi_ok || count < 8) {
        napi_throw_type_error(env, "PROCESSOR_ARGS", "runJavaProcessor 需要 8 个完整参数");
        return nullptr;
    }
    std::unique_ptr<ProcessorData> job(new ProcessorData);
    job->env = env;
    int32_t memory = 0;
    if (!ReadProcessorString(env, arguments[0], job->filesDir) ||
        !ReadProcessorString(env, arguments[1], job->jdkVersion) ||
        napi_get_value_int32(env, arguments[2], &memory) != napi_ok ||
        !ReadProcessorString(env, arguments[3], job->classpath) ||
        !ReadProcessorString(env, arguments[4], job->mainClass) ||
        !amcl::napi::ReadStringArrayValue(env, arguments[5], job->args) ||
        !ReadProcessorString(env, arguments[6], job->workDir) ||
        !ReadProcessorString(env, arguments[7], job->logFile) ||
        job->filesDir.empty() || job->filesDir.front() != '/' || job->mainClass.empty() ||
        job->args.size() > INT_MAX) {
        napi_throw_type_error(env, "PROCESSOR_INPUT", "processor 路径、类名、参数数组或内存参数无效");
        return nullptr;
    }
    for (const auto& argument : job->args) {
        if (argument.find('\0') != std::string::npos) {
            napi_throw_type_error(env, "PROCESSOR_NUL", "processor 参数不能包含 NUL 字符");
            return nullptr;
        }
    }
    uint64_t timeoutMs = 0;
    if (count >= 9) {
        napi_valuetype type;
        if (napi_typeof(env, arguments[8], &type) != napi_ok ||
            (type != napi_undefined && (!ReadProcessorString(env, arguments[8], job->requestId) ||
                job->requestId.empty() || job->requestId.size() > 256))) {
            napi_throw_type_error(env, "PROCESSOR_REQUEST_ID", "可选 requestId 必须是1至256字节的非NUL字符串");
            return nullptr;
        }
    }
    if (count >= 10) {
        napi_valuetype type; double milliseconds = 0;
        if (napi_typeof(env, arguments[9], &type) != napi_ok ||
            (type != napi_undefined && (napi_get_value_double(env, arguments[9], &milliseconds) != napi_ok ||
                !std::isfinite(milliseconds) || milliseconds < 0 || milliseconds > 9007199254740991.0 ||
                std::floor(milliseconds) != milliseconds))) {
            napi_throw_type_error(env, "PROCESSOR_TIMEOUT", "可选 timeoutMs 必须是非负安全整数；0表示不限时");
            return nullptr;
        }
        timeoutMs = static_cast<uint64_t>(milliseconds);
    }
    if (!job->requestId.empty() || timeoutMs) {
        job->control = std::make_shared<amcl::jvm::ProcessorControl>(timeoutMs);
        if (!job->requestId.empty()) {
            bool duplicate = false;
            {
                std::lock_guard<std::mutex> lock(processorRequestsMutex);
                const auto found = processorRequests.find(job->requestId);
                duplicate = found != processorRequests.end() && !found->second.expired();
                if (!duplicate) processorRequests[job->requestId] = job->control;
            }
            if (duplicate) {
                napi_throw_error(env, "PROCESSOR_DUPLICATE_ID", "requestId 仍由另一个 processor 任务使用");
                return nullptr;
            }
        }
    }
    // 保留既有默认 JDK 与堆范围；不限制 classpath/参数为固定字节缓冲，合法长输入完整传递。
    if (job->jdkVersion.empty()) job->jdkVersion = "17";
    job->xmxMb = memory < 512 ? 512 : memory > 8192 ? 8192 : memory;
    napi_value resource = nullptr, errorText = nullptr, error = nullptr, promise = nullptr;
    napi_status status = napi_create_string_utf8(env, "javaProcessor", NAPI_AUTO_LENGTH, &resource);
    if (status == napi_ok) status = napi_create_string_utf8(env,
        "processor 被取消或原生任务/完成资源失败；没有报告成功退出", NAPI_AUTO_LENGTH, &errorText);
    if (status == napi_ok) status = napi_create_error(env, nullptr, errorText, &error);
    if (status == napi_ok) status = napi_create_reference(env, error, 1, &job->completionError);
    if (status == napi_ok) status = napi_create_async_work(env, nullptr, resource,
        ProcessorExecute, ProcessorComplete, job.get(), &job->work);
    if (status == napi_ok) status = napi_create_promise(env, &job->deferred, &promise);
    if (status != napi_ok) {
        napi_throw_error(env, "PROCESSOR_PREPARE", "无法准备 processor 异步任务");
        return nullptr;
    }
    status = napi_queue_async_work(env, job->work);
    if (status != napi_ok) {
        // Promise 已建立后必须走拒绝路径，工作项尚未接管，栈所有者负责释放。
        napi_reject_deferred(env, job->deferred, error);
        return promise;
    }
    job.release();
    return promise;
} catch (const std::exception& error) {
    napi_throw_error(env, "PROCESSOR_NATIVE_INPUT", error.what());
    return nullptr;
} catch (...) {
    napi_throw_error(env, "PROCESSOR_NATIVE_INPUT", "无法准备 processor 输入");
    return nullptr;
}

/** 取消只提交不可逆的控制意图；Promise 仍等唯一worker真实回收目标进程后才完成。 */
napi_value CancelJavaProcessor(napi_env env, napi_callback_info info) try {
    size_t count = 1; napi_value arguments[1]{}; std::string id;
    if (napi_get_cb_info(env, info, &count, arguments, nullptr, nullptr) != napi_ok || count != 1 ||
        !ReadProcessorString(env, arguments[0], id) || id.empty() || id.size() > 256) {
        napi_throw_type_error(env, "PROCESSOR_REQUEST_ID", "cancelJavaProcessor 需要有效 requestId"); return nullptr;
    }
    bool accepted = false;
    {
        std::lock_guard<std::mutex> lock(processorRequestsMutex);
        const auto found = processorRequests.find(id);
        if (found != processorRequests.end()) {
            const auto control = found->second.lock();
            if (control) accepted = control->cancel();
        }
    }
    napi_value result = nullptr;
    if (napi_get_boolean(env, accepted, &result) != napi_ok) return nullptr;
    return result;
} catch (...) {
    napi_throw_error(env, "PROCESSOR_CANCEL", "无法提交 processor 取消请求"); return nullptr;
}

constexpr napi_property_descriptor kForgeDescriptors[] = {
    NAPI_FUNC("runJavaProcessor", RunJavaProcessor),
    NAPI_FUNC("cancelJavaProcessor", CancelJavaProcessor),
};

#undef NAPI_FUNC

} // anonymous namespace

namespace amcl::napi {

void registerForgeNapi(napi_env env, napi_value exports) {
    napi_define_properties(env, exports,
                           sizeof(kForgeDescriptors) / sizeof(kForgeDescriptors[0]),
                           kForgeDescriptors);
}

} // namespace amcl::napi
