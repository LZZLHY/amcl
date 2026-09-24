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

#include "../jvm/fork_run_java.h"

#undef LOG_TAG
#define LOG_TAG "NAPI_FORGE"

namespace {

#define NAPI_FUNC(name, fn) \
    { name, nullptr, fn, nullptr, nullptr, nullptr, napi_default, nullptr }

// ============================================================
//  RunJavaProcessor — 跑单个 Forge/NeoForge processor（任意 args + 显式 cwd）
//  签名：runJavaProcessor(filesDir, jdkVersion, xmxMb, classpath, mainClass,
//                         args: string[], workDir, logFile): Promise<number>
//  每个 processor 一个干净 classpath（只含其声明的 jar）的独立 JVM，杜绝 installer.jar
//  shaded 类（joptsimple/gson）泄漏（FCL/HMCL 同款思路）。
// ============================================================
struct ProcessorData {
    std::string filesDir;
    std::string jdkVersion = "17";
    int xmxMb = 2048;
    std::string classpath;
    std::string mainClass;
    std::vector<std::string> args;
    std::string workDir;
    std::string logFile;
    int result = -1;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
};

void ProcessorExecute(napi_env /*env*/, void* data) {
    auto* d = (ProcessorData*)data;
    OH_LOG_INFO(LOG_APP, "Processor[bg]: main=%{public}s args=%{public}zu jdk=%{public}s xmx=%{public}dMB",
        d->mainClass.c_str(), d->args.size(), d->jdkVersion.c_str(), d->xmxMb);
    std::vector<const char*> argv;
    argv.reserve(d->args.size());
    for (auto& a : d->args) argv.push_back(a.c_str());
    d->result = forkRunJavaCwd(
        d->filesDir.c_str(), d->jdkVersion.c_str(),
        d->classpath.c_str(), d->mainClass.c_str(),
        (int)argv.size(), argv.empty() ? nullptr : argv.data(),
        d->workDir.c_str(),
        d->logFile.empty() ? nullptr : d->logFile.c_str(), d->xmxMb);
    OH_LOG_INFO(LOG_APP, "Processor[bg]: fork child returned %{public}d", d->result);
}

void ProcessorComplete(napi_env env, napi_status /*status*/, void* data) {
    auto* d = (ProcessorData*)data;
    napi_value result;
    napi_create_int32(env, d->result, &result);
    napi_resolve_deferred(env, d->deferred, result);
    napi_delete_async_work(env, d->work);
    delete d;
}

napi_value RunJavaProcessor(napi_env env, napi_callback_info info) {
    size_t argc = 8;
    napi_value argv[8];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    auto* d = new ProcessorData();
    char buf[8192];
    size_t len = 0;
    if (argc >= 8) {
        if (napi_get_value_string_utf8(env, argv[0], buf, sizeof(buf), &len) == napi_ok) d->filesDir = buf;
        if (napi_get_value_string_utf8(env, argv[1], buf, sizeof(buf), &len) == napi_ok) d->jdkVersion = buf;
        int32_t xmx = d->xmxMb;
        if (napi_get_value_int32(env, argv[2], &xmx) == napi_ok) d->xmxMb = xmx;
        if (napi_get_value_string_utf8(env, argv[3], buf, sizeof(buf), &len) == napi_ok) d->classpath = buf;
        if (napi_get_value_string_utf8(env, argv[4], buf, sizeof(buf), &len) == napi_ok) d->mainClass = buf;
        // argv[5] = string[]
        bool isArray = false;
        napi_is_array(env, argv[5], &isArray);
        if (isArray) {
            uint32_t n = 0;
            napi_get_array_length(env, argv[5], &n);
            for (uint32_t i = 0; i < n; i++) {
                napi_value el;
                if (napi_get_element(env, argv[5], i, &el) == napi_ok &&
                    napi_get_value_string_utf8(env, el, buf, sizeof(buf), &len) == napi_ok) {
                    d->args.push_back(buf);
                }
            }
        }
        if (napi_get_value_string_utf8(env, argv[6], buf, sizeof(buf), &len) == napi_ok) d->workDir = buf;
        if (napi_get_value_string_utf8(env, argv[7], buf, sizeof(buf), &len) == napi_ok) d->logFile = buf;
    }
    if (d->jdkVersion.empty()) d->jdkVersion = "17";
    if (d->xmxMb < 512) d->xmxMb = 512;
    if (d->xmxMb > 8192) d->xmxMb = 8192;

    OH_LOG_INFO(LOG_APP, "RunJavaProcessor: scheduling... main=%{public}s args=%{public}zu jdk=%{public}s",
        d->mainClass.c_str(), d->args.size(), d->jdkVersion.c_str());

    napi_value promise;
    napi_create_promise(env, &d->deferred, &promise);
    napi_value resourceName;
    napi_create_string_utf8(env, "javaProcessor", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName,
                           ProcessorExecute, ProcessorComplete, d, &d->work);
    napi_queue_async_work(env, d->work);
    return promise;
}

constexpr napi_property_descriptor kForgeDescriptors[] = {
    NAPI_FUNC("runJavaProcessor", RunJavaProcessor),
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
