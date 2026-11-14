/**
 * 自有音频服务的宿主政策与寿命。这里唯一持有实际 owner；Java/OpenAL 只绑定其 ABI。
 * 原子事实与慢设备控制分开，UI 更新一发生，后续采集权限检查立即看见拒绝状态。
 */
#include "audio_host_policy.h"
#include "audio/audio_runtime.h"
#include <accesstoken/ability_access_control.h>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <fcntl.h>
#include <limits.h>
#include <cstdlib>
#include <unistd.h>

namespace {
std::atomic<bool> g_enabled{false};
std::atomic<bool> g_foreground{false};
std::mutex g_control;
uint64_t g_session = 0;
bool g_ended = false;
std::string g_policyPath;
std::atomic<uint64_t> g_epoch{0};
std::atomic<bool> g_captureRetired{false};
// 后台/关闭是必须执行的撤销边沿，不能被线程池晚到的前台true覆盖掉。
std::atomic<uint64_t> g_revokeRevision{0};
std::atomic<uint64_t> g_appliedRevoke{0};

/** 固定ASCII记录的有界解析；不可读、符号链接、截断、溢出和额外字节都拒绝采集。 */
uint64_t SharedEpoch(bool requireEnabled) {
    if (g_policyPath.empty()) return 0;
    const int fd = open(g_policyPath.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return 0;
    char bytes[96] = {};
    const ssize_t count = read(fd, bytes, sizeof(bytes));
    close(fd);
    if (count < 7 || count >= static_cast<ssize_t>(sizeof(bytes)) || bytes[0] != 'v' || bytes[1] != '1' || bytes[2] != ' ') return 0;
    uint64_t epoch = 0;
    size_t at = 3;
    for (; at < static_cast<size_t>(count) && bytes[at] >= '0' && bytes[at] <= '9'; ++at) {
        if (epoch > (UINT64_C(9007199254740991) - static_cast<unsigned>(bytes[at] - '0')) / 10u) return 0;
        epoch = epoch * 10u + static_cast<unsigned>(bytes[at] - '0');
    }
    if (!epoch || at == 3 || at + 3 != static_cast<size_t>(count) || bytes[at] != ' ' ||
        (bytes[at + 1] != '0' && bytes[at + 1] != '1') || bytes[at + 2] != '\n') return 0;
    return requireEnabled && bytes[at + 1] != '1' ? 0 : epoch;
}

/** 仅 Native 控制线程调用；不持有 ArkTS Context、napi_env 或可过期的授权快照。 */
int RecordPermission(void*) {
    if (!g_enabled.load(std::memory_order_acquire) || !g_foreground.load(std::memory_order_acquire) ||
        g_revokeRevision.load(std::memory_order_acquire) != g_appliedRevoke.load(std::memory_order_acquire) ||
        g_captureRetired.load(std::memory_order_acquire)) return 0;
    const uint64_t epoch = g_epoch.load(std::memory_order_acquire);
    if (!epoch || SharedEpoch(true) != epoch) {
        // 观察到跨进程撤销后即退休本局；文件修复/旧文件回退也不能重新授权旧会话。
        g_captureRetired.store(true, std::memory_order_release);
        return 0;
    }
    return OH_AT_CheckSelfPermission("ohos.permission.MICROPHONE") ? 1 : 0;
}
}

bool amclModAudioConfigureRoot(const char* filesDir) {
    if (!filesDir || filesDir[0] != '/') return false;
    char canonical[PATH_MAX] = {};
    if (!realpath(filesDir, canonical)) return false;
    const std::string path = std::string(canonical) + "/mod-audio-policy.v1";
    std::lock_guard<std::mutex> lock(g_control);
    if (!g_policyPath.empty()) return g_policyPath == path;
    if (g_session || g_ended) return false;
    g_policyPath = path;
    return true;
}

void amclModAudioSetPolicy(bool enabled, bool foreground) {
    if (!enabled || !foreground) g_revokeRevision.fetch_add(1, std::memory_order_acq_rel);
    g_enabled.store(enabled, std::memory_order_release);
    g_foreground.store(foreground, std::memory_order_release);
}

int amclModAudioApplyPolicy() {
    // 必须在锁内读取最新事实。排队较早的异步任务也应用新值，不把旧前台状态写回。
    std::lock_guard<std::mutex> lock(g_control);
    if (!g_session || g_ended) return AMCL_AUDIO_OK;
    const uint64_t revoke = g_revokeRevision.load(std::memory_order_acquire);
    if (revoke != g_appliedRevoke.load(std::memory_order_acquire)) {
        // 即使UI已经重新前台，也先使此前的采集句柄失败并实际停止设备。只在关闭完成后
        // 消费该撤销代次；随后可用的前台事实只允许模组显式新开，不复活原句柄。
        const int retired = amclAudioHostSetForegroundV1(g_session, 0);
        if (retired != AMCL_AUDIO_OK) return retired;
        g_appliedRevoke.store(revoke, std::memory_order_release);
    }
    int result = amclAudioHostSetForegroundV1(g_session,
        g_foreground.load(std::memory_order_acquire) ? 1 : 0);
    if (result != AMCL_AUDIO_OK) return result;
    return amclAudioHostRefreshPermissionV1(g_session);
}

int amclModAudioBegin() {
    std::lock_guard<std::mutex> lock(g_control);
    if (g_ended) return AMCL_AUDIO_UNAVAILABLE;
    if (g_session) return AMCL_AUDIO_OK;
    // 一个游戏进程只有一次 JVM。PID 加固定局号构成本进程会话，不借父进程指针或句柄。
    const uint64_t session = (static_cast<uint64_t>(getpid()) << 32u) | UINT64_C(1);
    g_epoch.store(SharedEpoch(false), std::memory_order_release);
    // 首次begin尚无设备/流，可以认领此前的关闭边沿；begin期间新边沿仍保持pending拒绝。
    g_appliedRevoke.store(g_revokeRevision.load(std::memory_order_acquire), std::memory_order_release);
    const int result = amclAudioHostBeginV1(session, RecordPermission, nullptr,
        g_foreground.load(std::memory_order_acquire) ? 1 : 0);
    if (result == AMCL_AUDIO_OK) g_session = session;
    return result;
}

void amclModAudioEnd() {
    std::lock_guard<std::mutex> lock(g_control);
    g_enabled.store(false, std::memory_order_release);
    if (!g_session || g_ended) return;
    g_ended = true;
    // 这里运行于结束游戏的 Native 工作线程；End 等待回调退出，不能在 UI 上同步调用。
    amclAudioHostEndV1(g_session);
}
