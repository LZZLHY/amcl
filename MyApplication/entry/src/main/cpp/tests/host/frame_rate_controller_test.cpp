/** 完整生产帧率controller的公共入口行为探针。
 * SDK设置/显示查询、hilog、InputForeground/graphics发布是明确外部边界，分别记录真实
 * controller调用次数与原参数。测试不改写policy或cache算法，不链接完整XComponent，
 * 不能据此宣称OHOS调度/图形呈现、CPU收益或输入时延已经验证。
 */
#include "ohos_frame_rate_hint.h"
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <window_manager/oh_display_manager.h>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

struct Application { OH_NativeXComponent* component; OH_NativeXComponent_ExpectedRateRange range; int result; };
static std::vector<Application> applications;
static std::vector<std::string> logs;
static std::vector<uint32_t> inputForeground;
static std::vector<int> graphicsForeground;
static uint32_t displayRate = 60;
static unsigned displayQueries = 0;
static int nextSdkResult = 0;

/** 外部SDK真实声明接缝：仅记录调用及事先指定的一次结果，不实现生产去重算法。 */
extern "C" int32_t OH_NativeXComponent_SetExpectedFrameRateRange(
    OH_NativeXComponent* component, OH_NativeXComponent_ExpectedRateRange* range) {
    const int result = nextSdkResult; nextSdkResult = 0;
    applications.push_back({component, *range, result}); return result;
}
extern "C" NativeDisplayManager_ErrorCode OH_NativeDisplayManager_GetDefaultDisplayRefreshRate(uint32_t* output) {
    ++displayQueries; *output = displayRate; return DISPLAY_MANAGER_OK;
}
/** 日志仅保存实际controller选择的format，不主动触发任何刷新或改变状态。 */
void frameControllerRecordLog(const char* format) { logs.emplace_back(format); }
/** 保留输入/图形foreground通知的实际controller调用证据；未模拟XComponent发布算法。 */
namespace amcl::ohos {
void PublishInputForegroundGateForAbility(uint32_t mask, const char*) { inputForeground.push_back(mask); }
}
extern "C" void amclGraphicsForegroundV1(int visible) { graphicsForeground.push_back(visible); }

/** CHECK在Release优化配置中仍执行，避免验收表达式被裁掉；退出2是行为失败而非编译失败。 */
static void check(bool good, const char* reason) {
    if (!good) { std::cerr << "CHECK " << reason << '\n'; std::exit(2); }
}
/** 只改变本测试子进程环境，清除继承的rollback参数以固定此次验收条件。 */
static void clearEnvironment() {
    for (const char* name : {"AMCL_OHOS_FRAME_RATE_HINT", "AMCL_OHOS_FRAME_RATE_MIN",
        "AMCL_OHOS_FRAME_RATE_MAX", "AMCL_OHOS_FRAME_RATE_EXPECTED", "AMCL_OHOS_FRAME_RATE_CAP"}) {
#ifdef _WIN32
        _putenv_s(name, "");
#else
        unsetenv(name);
#endif
    }
}
/** 对实际日志边界原format计数，稳定分支不得重复发unchanged，异常日志仍可逐次核对。 */
static unsigned logCount(const char* part) {
    unsigned count = 0; for (const auto& text : logs) if (text.find(part) != std::string::npos) ++count;
    return count;
}
/** 核最后一次真实SDK接缝调用仍针对原component及政策；不从controller内部cache取期望。 */
static void expectRange(OH_NativeXComponent* component, int min, int max, int expected) {
    check(!applications.empty(), "SDK_CALLED"); const auto& last = applications.back();
    check(last.component == component && last.range.min == min && last.range.max == max &&
        last.range.expected == expected, "ORIGINAL_COMPONENT_AND_RANGE");
}

/** 从cold装配到稳定刷新、变更、失败重试及完整资源边界，全部调用原公共controller入口。 */
int main() {
    using namespace amcl::ohos;
    clearEnvironment(); OH_NativeXComponent first{1}, second{2};
    check(SetFrameRateForegroundSource(2, true, "ability-foreground"), "FOREGROUND_ACCEPTED");
    check(inputForeground == std::vector<uint32_t>{2} && graphicsForeground == std::vector<int>{1},
        "FOREGROUND_NOTIFICATIONS_RETAINED");
    check(applications.empty() && !RefreshExpectedFrameRateHintForDisplayRate(60, "cold"), "COLD_NO_SDK");
    RegisterFrameRateComponent(&first); SetFrameRateSurfaceReady(&first, true, "surface-created");
    check(applications.size() == 1, "FIRST_READY_APPLIED"); expectRange(&first, 30, 60, 60);
    for (unsigned i = 0; i < 100; ++i) check(RefreshExpectedFrameRateHintForDisplayRate(60, "display-change"), "REFRESH_ACCEPTED");
    check(applications.size() == 1, "STABLE_REFRESH_SINGLE_SDK");
    check(logCount("frame-rate-hint-unchanged") == 0, "STABLE_REFRESH_DIAGNOSTIC_QUIET");
    check(RefreshExpectedFrameRateHintForDisplayRate(120, "display-change"), "HZ_CHANGE_ACCEPTED");
    check(applications.size() == 2, "HZ_CHANGE_REAL_SDK"); expectRange(&first, 30, 120, 120);
    nextSdkResult = -1;
    check(!RefreshExpectedFrameRateHintForDisplayRate(90, "display-change"), "SDK_FAILURE_RETURNED");
    check(applications.size() == 3 && applications.back().result == -1, "FAILED_SDK_RECORDED");
    check(RefreshExpectedFrameRateHintForDisplayRate(90, "display-change"), "SAME_POLICY_FAILURE_RETRY");
    check(applications.size() == 4 && applications.back().result == 0, "FAILED_POLICY_NOT_CACHED"); expectRange(&first, 30, 90, 90);
    check(logCount("frame-rate-hint-failed") == 1, "FAILURE_DIAGNOSTIC_RETAINED");
    displayRate = 90;
    check(RefreshExpectedFrameRateHint("compat-default-display"), "COMPAT_QUERY_ACCEPTED");
    check(displayQueries > 0 && applications.size() == 4, "COMPAT_QUERY_STILL_RUNS");
    check(SetRuntimeFrameRateCap(60, "runtime-cap"), "CAP_CHANGE"); expectRange(&first, 30, 60, 60);
    const auto afterCap = applications.size();
    check(SetRuntimeFrameRateCap(60, "runtime-cap"), "SAME_CAP"); check(applications.size() == afterCap, "SAME_CAP_QUIET");
    SetFrameRateFocused(&first, false, "blur"); expectRange(&first, 30, 30, 30);
    const auto afterBlur = applications.size(); SetFrameRateFocused(&first, false, "blur");
    check(applications.size() == afterBlur, "SAME_BLUR_QUIET");
    SetFrameRateFocused(&first, true, "focus"); expectRange(&first, 30, 60, 60);
    check(SetFrameRateForegroundSource(2, false, "ability-background"), "BACKGROUND_ACCEPTED"); expectRange(&first, 30, 30, 30);
    check(inputForeground.back() == 0 && graphicsForeground.back() == 0, "BACKGROUND_NOTIFICATIONS_RETAINED");
    const auto afterBackground = applications.size(); check(SetFrameRateForegroundSource(2, false, "ability-background"), "SAME_BACKGROUND");
    check(applications.size() == afterBackground && inputForeground.back() == 0 && graphicsForeground.back() == 0,
        "SAME_BACKGROUND_ONLY_NOTIFICATIONS");
    check(SetFrameRateForegroundSource(2, true, "ability-foreground"), "RESTORE_FOREGROUND"); expectRange(&first, 30, 60, 60);
    const auto beforeReplacement = applications.size(); RegisterFrameRateComponent(&second);
    check(applications.size() == beforeReplacement + 1, "OLD_COMPONENT_INACTIVE_BEFORE_REPLACE"); expectRange(&first, 30, 30, 30);
    SetFrameRateSurfaceReady(&second, true, "new-surface"); expectRange(&second, 30, 60, 60);
    check(applications.size() == beforeReplacement + 2, "NEW_COMPONENT_SAME_POLICY_APPLIED");
    const auto beforeStale = applications.size();
    SetFrameRateFocused(&first, false, "stale-focus"); SetFrameRateSurfaceReady(&first, false, "stale-destroy");
    check(!ApplyExpectedFrameRateHint(&first, "stale-apply") && applications.size() == beforeStale, "STALE_COMPONENT_REJECTED");
    SetFrameRateSurfaceReady(&second, false, "surface-destroyed"); expectRange(&second, 30, 30, 30);
    const auto beforeReopen = applications.size();
    check(!RefreshExpectedFrameRateHintForDisplayRate(60, "surface-absent") && applications.size() == beforeReopen, "DETACHED_NO_REFRESH");
    SetFrameRateSurfaceReady(&second, true, "surface-recreated"); expectRange(&second, 30, 60, 60);
    check(applications.size() == beforeReopen + 1, "REOPEN_SAME_POLICY_FORCED");
    const auto beforeExplicit = applications.size(); check(ApplyExpectedFrameRateHint(&second, "surface-changed-idempotent"), "EXPLICIT_LIFECYCLE_APPLY");
    check(applications.size() == beforeExplicit + 1, "EXPLICIT_SAME_POLICY_STILL_FORCED");
    nextSdkResult = -1; check(!ApplyExpectedFrameRateHint(&second, "surface-change-failed"), "EXPLICIT_FAILURE");
    const auto beforeRetry = applications.size(); check(RefreshExpectedFrameRateHintForDisplayRate(60, "retry"), "ORIGINAL_POLICY_RETRY");
    check(applications.size() == beforeRetry + 1, "EXPLICIT_FAILURE_NOT_CACHED");
    check(inputForeground.size() == graphicsForeground.size(), "NOTIFICATION_COUNTS_MATCH");
    std::cout << "PASS actual frame-rate controller SDK-calls=" << applications.size()
        << " input/graphics-foreground-calls=" << inputForeground.size()
        << "; no device scheduling/input latency/CPU claim\n";
}
