/** 安装 CPU/文件 I/O 放在 async-work；事务切换是无 await 的同步边界，锁由 ArkTS owner 持有。 */
#include "napi_jdk_install.h"
#include "../platform/jdk_font_resources.h"
#include "../platform/jdk_install_store.h"
#include "napi_helpers.h"
#include <array>
#include <cmath>
#include <memory>
#include <stdexcept>

namespace amcl::napi {
namespace {
napi_value Failure(napi_env env, const std::string &error) {
    napi_throw_error(env, "JDK_INSTALL", error.c_str());
    return nullptr;
}
std::string String(napi_env env, napi_value value) {
    std::string text;
    if (!ReadStringValue(env, value, text) || text.size() > 8192 || text.find('\0') != std::string::npos)
        throw std::runtime_error("JDK 安装参数不是有界字符串");
    return text;
}
int Number(napi_env env, napi_value value) {
    double number = 0;
    if (napi_get_value_double(env, value, &number) != napi_ok || !std::isfinite(number) || number < -1 ||
        number > 2147483647 || number != static_cast<int>(number))
        throw std::runtime_error("JDK 安装整数参数无效");
    return static_cast<int>(number);
}
/** 同一接口只分派已知操作；路径/锁 inode/同槽约束仍由 native 存储实现验证。 */
napi_value Operation(napi_env env, napi_callback_info info) {
    try {
        size_t count = 6;
        std::array<napi_value, 6> args{};
        if (napi_get_cb_info(env, info, &count, args.data(), nullptr, nullptr) != napi_ok || count != args.size())
            throw std::runtime_error("JDK 安装操作参数数量错误");
        const auto op = String(env, args[0]), files = String(env, args[1]), major = String(env, args[2]),
                   stage = String(env, args[3]);
        const int writer = Number(env, args[4]), use = Number(env, args[5]);
        std::string result;
        if (op == "create")
            result = jdk::CreateInstallStage(files, major, writer);
        else if (op == "discard")
            jdk::DiscardInstallStage(files, major, stage, writer);
        else if (op == "publish")
            jdk::PublishInstallStage(files, major, stage, writer, use);
        else if (op == "recover")
            jdk::RecoverInstallSlot(files, major, writer, use);
        else if (op == "collect")
            jdk::CollectAbandonedInstallStage(files, major, writer);
        else if (op == "pending")
            result = jdk::InstallRecoveryRequired(files, major) ? "yes" : "no";
        else if (op == "delete")
            jdk::DeleteInstallSlot(files, major, writer, use);
        else if (op == "fonts") {
            std::string config, properties, error;
            if (!jdk::PrepareFontResources(files, config, properties, error))
                throw std::runtime_error(error);
        } else
            throw std::runtime_error("未知 JDK 安装操作");
        return WrapStringResult(env, result.c_str());
    } catch (const std::exception &error) {
        return Failure(env, error.what());
    }
}
struct Job {
    napi_async_work work{};
    napi_deferred deferred{};
    bool seal{};
    std::string first, second, sha, error;
    int timeout = 300000;
};
void Execute(napi_env, void *data) {
    auto &job = *static_cast<Job *>(data);
    try {
        if (job.seal)
            jdk::SealInstallStage(job.first, job.second, job.sha);
        else
            jdk::ExtractInstallArchive(job.first, job.second, job.sha, job.timeout);
    } catch (const std::exception &error) {
        job.error = error.what();
    } catch (...) {
        job.error = "JDK 安装原生操作失败";
    }
}
/** complete 只能在 execute 返回且全部 fd 已释放后 settle；调用方 finally 才获准清理 staging。 */
void Complete(napi_env env, napi_status status, void *data) {
    std::unique_ptr<Job> job(static_cast<Job *>(data));
    if (status != napi_ok && job->error.empty())
        job->error = "JDK 安装异步工作未完成";
    napi_value value{};
    if (job->error.empty()) {
        if (napi_get_boolean(env, true, &value) == napi_ok)
            napi_resolve_deferred(env, job->deferred, value);
    } else {
        napi_value message{};
        if (napi_create_string_utf8(env, job->error.c_str(), job->error.size(), &message) == napi_ok &&
            napi_create_error(env, nullptr, message, &value) == napi_ok)
            napi_reject_deferred(env, job->deferred, value);
    }
    napi_delete_async_work(env, job->work);
}
napi_value Queue(napi_env env, napi_callback_info info, bool seal) {
    try {
        size_t count = seal ? 3 : 4;
        std::array<napi_value, 4> args{};
        if (napi_get_cb_info(env, info, &count, args.data(), nullptr, nullptr) != napi_ok || count != (seal ? 3u : 4u))
            throw std::runtime_error("JDK 异步安装参数数量错误");
        auto job = std::make_unique<Job>();
        job->seal = seal;
        job->first = String(env, args[0]);
        job->second = String(env, args[1]);
        job->sha = String(env, args[2]);
        if (!seal)
            job->timeout = Number(env, args[3]);
        napi_value promise{}, name{};
        if (napi_create_promise(env, &job->deferred, &promise) != napi_ok ||
            napi_create_string_utf8(env, "JdkInstallStorage", NAPI_AUTO_LENGTH, &name) != napi_ok)
            return Failure(env, "无法建立 JDK 安装 Promise");
        if (napi_create_async_work(env, nullptr, name, Execute, Complete, job.get(), &job->work) != napi_ok)
            return Failure(env, "无法建立 JDK 安装 worker");
        if (napi_queue_async_work(env, job->work) != napi_ok) {
            napi_delete_async_work(env, job->work);
            return Failure(env, "无法调度 JDK 安装 worker");
        }
        job.release();
        return promise;
    } catch (const std::exception &error) {
        return Failure(env, error.what());
    }
}
napi_value Extract(napi_env env, napi_callback_info info) {
    return Queue(env, info, false);
}
napi_value Seal(napi_env env, napi_callback_info info) {
    return Queue(env, info, true);
}
} // namespace
void RegisterJdkInstall(napi_env env, napi_value exports) {
    const napi_property_descriptor descriptors[] = {
        {"jdkInstallOperation", nullptr, Operation, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"jdkInstallExtract", nullptr, Extract, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"jdkInstallSeal", nullptr, Seal, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    if (napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors) != napi_ok)
        napi_throw_error(env, "JDK_INSTALL", "无法注册 JDK 安装端口");
}
} // namespace amcl::napi
