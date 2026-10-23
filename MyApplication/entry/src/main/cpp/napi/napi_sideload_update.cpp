/**
 * sideload HDC的NAPI桥。启动等待真实bind/私有接入就绪，所有操作放异步worker。
 * 不重定向进程stdio，不接触网页登录令牌或签名密码；设备安装事实由启动恢复服务核验。
 */
#include "napi_sideload_update.h"
#include <string>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <unistd.h>
#include "../jvm/update_install_lease.h"

#if defined(AMCL_ENABLE_SIDELOAD_UPDATE) && AMCL_ENABLE_SIDELOAD_UPDATE
#include "../hdc/local_discovery.h"
extern "C" int amcl_hdc_core_start(const char*);
extern "C" int amcl_hdc_core_command(const char*);
extern "C" int amcl_hdc_core_command_to_file(const char*, const char*);
extern "C" int amcl_hdc_core_stop();
extern "C" int amcl_hdc_core_probe_port(int);
extern "C" int amcl_hdc_core_pow(const char*, const char*, int, char*, size_t, uint64_t);
extern "C" uint64_t amcl_hdc_core_next_pow();
#endif

namespace amcl::napi {
namespace {
/** 文件租约令牌只属于取得它的当前 PID；fork 子进程不能借旧 JS token 释放父 owner。 */
struct FileLeaseOwner { pid_t pid; std::shared_ptr<amcl::UpdateInstallReadLease> lease; };
std::mutex fileLeaseMutex;
std::map<uint32_t, FileLeaseOwner> fileLeases;
uint32_t nextFileLease = 1;
/** 每个请求独占参数和Promise，不保存JS缓冲区指针，完成后一次释放。 */
struct HdcWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string text;
    std::string outputPath;
    bool capture = false;
    bool start = false;
    bool stop = false;
    bool pow = false;
    bool discover = false;
    int iterations = 0;
    uint64_t powGeneration = 0;
    std::string solution;
    int result = -100;
};

/** UTF-8参数限制为64KiB；路径/命令的业务约束由受控更新服务进一步检查。 */
std::string ReadArgument(napi_env env, napi_value value) {
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok || length == 0 || length > 65536) return {};
    std::string text(length + 1, '\0');
    napi_get_value_string_utf8(env, value, text.data(), text.size(), &length);
    text.resize(length);
    if (text.find('\0') != std::string::npos) return {};
    return text;
}

/** Entry 在任何自动文件业务前固定 root；此能力在 store 同样存在，不授予 HDC 权限。 */
napi_value ConfigureRoot(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value argv[1]{}; napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    const bool configured = argc == 1 && amcl::ConfigureUpdateInstallFilesRoot(ReadArgument(env, argv[0]));
    napi_value result; napi_get_boolean(env, configured, &result); return result;
}
/** /proc/<pid>/stat 的 starttime 使用 sysconf 时钟滴答；不能用墙钟或猜固定100替代。 */
napi_value ClockTicks(napi_env env, napi_callback_info) {
    const long ticks = sysconf(_SC_CLK_TCK);
    napi_value result; napi_create_int32(env, ticks > 0 && ticks <= 1000000 ? static_cast<int>(ticks) : 0, &result);
    return result;
}

/** 获取到 SH 后再次读 fence；空字符串使用已固定 root，失败返回0且不留下句柄。 */
napi_value AcquireFileLease(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value argv[1]{}; napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc == 1) {
        const std::string root = ReadArgument(env, argv[0]);
        if (!root.empty() && !amcl::ConfigureUpdateInstallFilesRoot(root)) {
            napi_value zero; napi_create_uint32(env, 0, &zero); return zero;
        }
    }
    auto lease = amcl::AcquireConfiguredUpdateReadLease(); uint32_t token = 0;
    if (lease) {
        std::lock_guard<std::mutex> lock(fileLeaseMutex);
        if (fileLeases.size() < 512) {
            do { token = nextFileLease++; } while (!token || fileLeases.count(token));
            fileLeases.emplace(token, FileLeaseOwner{getpid(), std::move(lease)});
        }
    }
    napi_value result; napi_create_uint32(env, token, &result); return result;
}

/** 只有本 PID 的确切 owner 被移除；重复/旧 token 返回false，不解除其他租约。 */
napi_value ReleaseFileLease(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value argv[1]{}; napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint32_t token = 0; bool released = false;
    if (argc == 1 && napi_get_value_uint32(env, argv[0], &token) == napi_ok && token) {
        std::lock_guard<std::mutex> lock(fileLeaseMutex);
        const auto found = fileLeases.find(token);
        if (found != fileLeases.end() && found->second.pid == getpid()) { fileLeases.erase(found); released = true; }
    }
    napi_value result; napi_get_boolean(env, released, &result); return result;
}

/** store没有HDC核心且明确返回unsupported；普通更新worker不阻塞ArkUI。 */
void Execute(napi_env, void* data) {
    auto* work = static_cast<HdcWork*>(data);
    if (work->text.empty() && !work->stop && !work->discover) { work->result = -101; return; }
    if (work->capture && work->outputPath.empty()) { work->result = -101; return; }
#if defined(AMCL_ENABLE_SIDELOAD_UPDATE) && AMCL_ENABLE_SIDELOAD_UPDATE
    if (work->discover) { work->result = amcl::hdc::DiscoverLocalHdcPort(amcl_hdc_core_probe_port); return; }
    if (work->pow) {
        char output[769]{};
        work->result = amcl_hdc_core_pow(work->text.c_str(), work->outputPath.c_str(), work->iterations, output, sizeof(output), work->powGeneration);
        if (work->result == 0) work->solution = output;
        return;
    }
    work->result = work->stop ? amcl_hdc_core_stop() : work->start ? amcl_hdc_core_start(work->text.c_str()) :
        work->capture ? amcl_hdc_core_command_to_file(work->text.c_str(), work->outputPath.c_str()) : amcl_hdc_core_command(work->text.c_str());
#else
    work->result = -102;
#endif
}

/** 仅导出数字执行码/真实端口，不把命令文本、私有码或令牌带回UI或普通日志。 */
void Complete(napi_env env, napi_status status, void* data) {
    auto* work = static_cast<HdcWork*>(data);
    napi_value result;
    if (work->pow) napi_create_string_utf8(env, status == napi_ok ? work->solution.c_str() : "", NAPI_AUTO_LENGTH, &result);
    else napi_create_int32(env, status == napi_ok ? work->result : -103, &result);
    napi_resolve_deferred(env, work->deferred, result);
    napi_delete_async_work(env, work->work);
    delete work;
}

/** Native仅做异步资源管理，更新服务串行构造固定操作，不能让网页输入变成argv。 */
napi_value Schedule(napi_env env, napi_callback_info info, bool start, bool stop = false, bool discover = false) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    auto* work = new HdcWork();
    work->start = start;
    work->stop = stop;
    work->discover = discover;
    if (argc >= 1) work->text = ReadArgument(env, argv[0]);
    // 第二参数仅对查询命令有效；固定私有路径来自ArkTS服务，不能用空参数悄悄回退到stdout。
    if (argc >= 2 && !start && !stop) { work->capture = true; work->outputPath = ReadArgument(env, argv[1]); }
    napi_value promise, name;
    napi_create_promise(env, &work->deferred, &promise);
    napi_create_string_utf8(env, "SideloadHdcWork", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, Execute, Complete, work, &work->work);
    napi_queue_async_work(env, work->work);
    return promise;
}
napi_value Start(napi_env env, napi_callback_info info) { return Schedule(env, info, true); }
napi_value Command(napi_env env, napi_callback_info info) { return Schedule(env, info, false); }
napi_value Stop(napi_env env, napi_callback_info info) { return Schedule(env, info, false, true); }
/** 无 JS 输入的固定本机发现能力，异步返回端口提示，系统信任仍由后续 HDC 认证完成。 */
napi_value Discover(napi_env env, napi_callback_info info) { return Schedule(env, info, false, false, true); }
/** 严格三参数，仅复制公开挑战并异步计算；错误返回空串，由上层回退其他下载源。 */
napi_value SolvePow(napi_env env, napi_callback_info info) {
    size_t argc = 3; napi_value argv[3]{};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    auto* work = new HdcWork(); work->pow = true;
#if defined(AMCL_ENABLE_SIDELOAD_UPDATE) && AMCL_ENABLE_SIDELOAD_UPDATE
    work->powGeneration = amcl_hdc_core_next_pow();
#endif
    if (argc == 3) {
        work->text = ReadArgument(env, argv[0]); work->outputPath = ReadArgument(env, argv[1]);
        napi_get_value_int32(env, argv[2], &work->iterations);
    }
    napi_value promise, name; napi_create_promise(env, &work->deferred, &promise);
    napi_create_string_utf8(env, "SideloadMirrorChallenge", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, Execute, Complete, work, &work->work);
    napi_queue_async_work(env, work->work); return promise;
}
/** 只撤销公开挑战计算，不停止已有 HDC 会话或影响其他运行时。 */
napi_value CancelPow(napi_env env, napi_callback_info) {
#if defined(AMCL_ENABLE_SIDELOAD_UPDATE) && AMCL_ENABLE_SIDELOAD_UPDATE
    amcl_hdc_core_next_pow();
#endif
    napi_value result; napi_get_undefined(env, &result); return result;
}
}

/** 导出表为注册真相；类型契约在libentry/index.d.ts同步维护。 */
void registerSideloadUpdateNapi(napi_env env, napi_value exports) {
    const napi_property_descriptor properties[] = {
        {"configureSideloadInstallRoot", nullptr, ConfigureRoot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sideloadInstallClockTicks", nullptr, ClockTicks, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"acquireSideloadFileLease", nullptr, AcquireFileLease, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseSideloadFileLease", nullptr, ReleaseFileLease, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startSideloadHdc", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"discoverSideloadPort", nullptr, Discover, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runSideloadHdcCommand", nullptr, Command, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopSideloadHdc", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr}
        ,{"solveSideloadPow", nullptr, SolvePow, nullptr, nullptr, nullptr, napi_default, nullptr}
        ,{"cancelSideloadPow", nullptr, CancelPow, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
}
}
