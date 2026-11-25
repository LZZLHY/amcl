/** 完整生产帧率controller的公共入口行为探针。
 * SDK设置/显示查询、hilog、InputForeground/graphics发布是明确外部边界，分别记录真实
 * controller调用次数与原参数。测试不改写policy或cache算法，不链接完整XComponent，
 * 不能据此宣称OHOS调度/图形呈现、CPU收益或输入时延已经验证。
 */
#include "ohos_frame_rate_hint.h"
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_vsync/native_vsync.h>
#include <window_manager/oh_display_manager.h>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
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

/** VSync替身记录句柄、一次性回调和故障，不模拟调度策略。 */
struct VsyncSession {
    OH_NativeVSync handle;
    OH_NativeVSync_FrameCallback pendingFrame = nullptr;
    void* frameToken = nullptr;
    unsigned destroys = 0;
};

static std::deque<VsyncSession> vsyncSessions;
static std::vector<std::array<int, 3>> vsyncRanges;
static unsigned vsyncRequests = 0;
static int nextVsyncRangeResult = 0;
static int nextVsyncRequestResult = 0;
static bool failNextVsyncCreate = false;

static void dispatchVsyncFrame(VsyncSession& session) {
    auto callback = session.pendingFrame;
    session.pendingFrame = nullptr;
    if (callback != nullptr) {
        callback(0, session.frameToken);
    }
}

extern "C" OH_NativeVSync* OH_NativeVSync_Create(const char*, unsigned int) {
    if (failNextVsyncCreate) {
        failNextVsyncCreate = false;
        return nullptr;
    }
    const auto index = static_cast<int>(vsyncSessions.size());
    vsyncSessions.push_back({{index}});
    return &vsyncSessions.back().handle;
}

extern "C" void OH_NativeVSync_Destroy(OH_NativeVSync* vsync) {
    auto& session = vsyncSessions.at(vsync->identity);
    ++session.destroys;
    // 模拟SDK销毁等待在途回调；毁点若仍持控制器锁，宿主用例会超时。
    dispatchVsyncFrame(session);
}

extern "C" int32_t OH_NativeVSync_SetExpectedFrameRateRange(
    OH_NativeVSync*, OH_NativeVSync_ExpectedRateRange* range) {
    vsyncRanges.push_back({range->min, range->max, range->expected});
    const int result = nextVsyncRangeResult;
    nextVsyncRangeResult = 0;
    return result;
}

extern "C" int32_t OH_NativeVSync_RequestFrame(
    OH_NativeVSync* vsync, OH_NativeVSync_FrameCallback callback, void* token) {
    ++vsyncRequests;
    const int result = nextVsyncRequestResult;
    nextVsyncRequestResult = 0;
    if (result == 0) {
        auto& session = vsyncSessions.at(vsync->identity);
        session.pendingFrame = callback;
        session.frameToken = token;
    }
    return result;
}

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
    check(vsyncSessions.empty() && vsyncRequests == 0, "AUTO_MODE_NO_PINNER");
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
    check(SetRuntimeFrameRateCap(240, "legacy-cap-240"), "HIGH_LEGACY_CAP_ACCEPTED");
    expectRange(&first, 30, 90, 90);
    check(SetRuntimeFrameRateCap(60, "runtime-cap"), "CAP_CHANGE");
    expectRange(&first, 30, 60, 60);
    check(vsyncSessions.empty(), "LEGACY_CAP_NEVER_PINNED");
    const auto afterCap = applications.size();
    check(SetRuntimeFrameRateCap(60, "runtime-cap"), "SAME_CAP");
    check(applications.size() == afterCap, "SAME_CAP_QUIET");
    check(RefreshExpectedFrameRateHintForDisplayRate(90, "beyond-legacy-cap", 120),
          "FIXED_VALUE_RECORDED");
    expectRange(&first, 30, 60, 60);
    check(vsyncSessions.empty(), "LEGACY_HARD_CAP_BLOCKS_FIXED_REQUEST");
    check(RefreshExpectedFrameRateHintForDisplayRate(90, "clear-fixed", 0), "CLEAR_FIXED");
    check(SetRuntimeFrameRateCap(0, "clear-legacy-cap"), "CAP_CLEARED");

    // 显式 MAX 同时约束组件提示和面板投票，清除它以后恢复普通的固定档行为。
#ifdef _WIN32
    _putenv_s("AMCL_OHOS_FRAME_RATE_MAX", "60");
#else
    setenv("AMCL_OHOS_FRAME_RATE_MAX", "60", 1);
#endif
    check(RefreshExpectedFrameRateHintForDisplayRate(120, "explicit-maximum", 120), "MAX_APPLIED");
    expectRange(&first, 30, 60, 60);
    check(vsyncSessions.empty(), "MAX_BLOCKS_PANEL_VOTE");
    clearEnvironment();
    check(RefreshExpectedFrameRateHintForDisplayRate(90, "reset-explicit-maximum", 0), "MAX_CLEARED");

    for (int invalid : {-1, 29, 145, 165, 240}) {
        check(!RefreshExpectedFrameRateHintForDisplayRate(120, "invalid-fixed", invalid),
              "NATIVE_FIXED_RANGE_REJECTED");
    }
    check(vsyncSessions.empty(), "INVALID_VALUES_NEVER_REACH_NATIVE_VSYNC");

    failNextVsyncCreate = true;
    check(RefreshExpectedFrameRateHintForDisplayRate(60, "create-failure", 144),
          "CREATE_FAILURE_KEEPS_LEGACY_HINT");
    expectRange(&first, 30, 60, 60);
    check(vsyncSessions.empty(), "CREATE_FAILURE_HAS_NO_HANDLE");

    nextVsyncRangeResult = -1;
    check(RefreshExpectedFrameRateHintForDisplayRate(60, "range-failure", 144),
          "RANGE_FAILURE_KEEPS_LEGACY_HINT");
    expectRange(&first, 30, 60, 60);
    check(vsyncSessions.size() == 1 && vsyncSessions.back().destroys == 1 && vsyncRequests == 0,
          "RANGE_FAILURE_DESTROYS_CREATED_HANDLE");

    nextVsyncRequestResult = -1;
    check(RefreshExpectedFrameRateHintForDisplayRate(60, "request-failure", 144),
          "REQUEST_FAILURE_KEEPS_LEGACY_HINT");
    expectRange(&first, 30, 60, 60);
    check(vsyncSessions.size() == 2 && vsyncSessions.back().destroys == 1 &&
          vsyncRanges.back() == std::array<int, 3>{0, 0, 0},
          "REQUEST_FAILURE_RESETS_VOTE_AND_DESTROYS_HANDLE");

    check(RefreshExpectedFrameRateHintForDisplayRate(60, "retry-fixed", 144), "FIXED_RETRY");
    expectRange(&first, 144, 144, 144);
    check(vsyncSessions.size() == 3 && vsyncRanges.back() == std::array<int, 3>{144, 144, 144},
          "EXACT_SUPPORTED_FIXED_RATE_CAN_EXCEED_INSTANTANEOUS_REFRESH");
    auto& firstVote = vsyncSessions.back();
    const auto beforeCallback = vsyncRequests;
    dispatchVsyncFrame(firstVote);
    check(vsyncRequests == beforeCallback + 1, "CALLBACK_REARMS_ONLY_ONE_NATIVE_REQUEST");

    nextVsyncRequestResult = -1;
    dispatchVsyncFrame(firstVote);
    check(firstVote.destroys == 0 && vsyncRanges.back() == std::array<int, 3>{0, 0, 0},
          "REARM_FAILURE_RESETS_VOTE_WITHOUT_DESTROYING_FROM_CALLBACK");
    const auto beforeRearm = applications.size();
    check(RefreshExpectedFrameRateHintForDisplayRate(60, "rearm-retry", 144), "REARM_RETRIED");
    check(vsyncSessions.size() == 4 && firstVote.destroys == 1 && applications.size() == beforeRearm,
          "SAME_XCOMPONENT_POLICY_DOES_NOT_SKIP_VSYNC_RECOVERY");

    auto& focusedVote = vsyncSessions.back();
    const auto beforeBlur = vsyncRequests;
    SetFrameRateFocused(&first, false, "blur");
    expectRange(&first, 30, 30, 30);
    check(focusedVote.destroys == 1 && vsyncRequests == beforeBlur &&
          vsyncRanges.back() == std::array<int, 3>{0, 0, 0},
          "BLUR_DESTROYS_AFTER_UNLOCK_WITHOUT_REARMING_STALE_CALLBACK");
    const auto afterBlur = applications.size();
    SetFrameRateFocused(&first, false, "blur");
    check(applications.size() == afterBlur, "SAME_BLUR_QUIET");
    SetFrameRateFocused(&first, true, "focus");
    expectRange(&first, 144, 144, 144);
    check(vsyncSessions.size() == 5, "PINNER_RESTARTED_ON_FOCUS");

    check(SetFrameRateForegroundSource(2, false, "ability-background"), "BACKGROUND_ACCEPTED");
    expectRange(&first, 30, 30, 30);
    check(vsyncSessions.back().destroys == 1 &&
          inputForeground.back() == 0 && graphicsForeground.back() == 0,
          "BACKGROUND_STOPS_PINNER_AND_RETAINS_NOTIFICATIONS");
    const auto afterBackground = applications.size();
    check(SetFrameRateForegroundSource(2, false, "ability-background"), "SAME_BACKGROUND");
    check(applications.size() == afterBackground && inputForeground.back() == 0 && graphicsForeground.back() == 0,
          "SAME_BACKGROUND_ONLY_NOTIFICATIONS");
    check(SetFrameRateForegroundSource(2, true, "ability-foreground"), "RESTORE_FOREGROUND");
    expectRange(&first, 144, 144, 144);
    check(vsyncSessions.size() == 6, "PINNER_RESTARTED_ON_FOREGROUND");

    auto& previousDisplay = vsyncSessions.back();
    auto delayedCallback = previousDisplay.pendingFrame;
    auto delayedToken = previousDisplay.frameToken;
    check(RefreshExpectedFrameRateHintForDisplayRate(60, "screen-change-unavailable", 0),
          "UNSUPPORTED_DISPLAY_WITHDRAWS_FIXED_REQUEST");
    expectRange(&first, 30, 60, 60);
    check(previousDisplay.destroys == 1, "OLD_DISPLAY_SESSION_DESTROYED");

    check(RefreshExpectedFrameRateHintForDisplayRate(90, "new-display-supported", 90),
          "NEW_DISPLAY_CONFIRMS_RATE");
    expectRange(&first, 90, 90, 90);
    const auto beforeStaleCallback = vsyncRequests;
    delayedCallback(0, delayedToken);
    check(vsyncRequests == beforeStaleCallback, "STALE_CALLBACK_CANNOT_REARM_REPLACEMENT");

    const auto beforeReplacement = applications.size();
    RegisterFrameRateComponent(&second);
    check(applications.size() == beforeReplacement + 1, "OLD_COMPONENT_INACTIVE_BEFORE_REPLACE");
    expectRange(&first, 30, 30, 30);
    check(vsyncSessions.back().destroys == 1, "PINNER_STOPPED_ON_COMPONENT_REPLACE");
    SetFrameRateSurfaceReady(&second, true, "new-surface");
    expectRange(&second, 30, 90, 90);
    check(vsyncSessions.size() == 7, "NEW_SURFACE_REQUIRES_FRESH_WINDOW_CONFIRMATION");
    check(applications.size() == beforeReplacement + 2, "NEW_COMPONENT_POLICY_APPLIED");
    const auto beforeStale = applications.size();
    SetFrameRateFocused(&first, false, "stale-focus");
    SetFrameRateSurfaceReady(&first, false, "stale-destroy");
    check(!ApplyExpectedFrameRateHint(&first, "stale-apply") && applications.size() == beforeStale,
          "STALE_COMPONENT_REJECTED");

    check(RefreshExpectedFrameRateHintForDisplayRate(90, "second-surface-confirmed", 90),
          "SECOND_COMPONENT_FIXED_REQUEST_ACCEPTED");
    SetFrameRateSurfaceReady(&second, false, "surface-destroyed");
    expectRange(&second, 30, 30, 30);
    check(vsyncSessions.back().destroys == 1, "PINNER_STOPPED_ON_SURFACE_DESTROYED");
    const auto beforeReopen = applications.size();
    check(!RefreshExpectedFrameRateHintForDisplayRate(60, "surface-absent", 60) &&
          applications.size() == beforeReopen, "DETACHED_NO_REFRESH");
    SetFrameRateSurfaceReady(&second, true, "surface-recreated");
    expectRange(&second, 30, 90, 90);
    check(vsyncSessions.size() == 8, "RECREATED_SURFACE_REQUIRES_FRESH_WINDOW_CONFIRMATION");
    check(applications.size() == beforeReopen + 1, "REOPEN_SAME_POLICY_FORCED");
    for (const auto& session : vsyncSessions) {
        check(session.destroys == 1, "ALL_SUCCESSFUL_CREATES_DESTROYED_EXACTLY_ONCE");
    }
    const auto beforeExplicit = applications.size();
    check(ApplyExpectedFrameRateHint(&second, "surface-changed-idempotent"), "EXPLICIT_LIFECYCLE_APPLY");
    check(applications.size() == beforeExplicit + 1, "EXPLICIT_SAME_POLICY_STILL_FORCED");
    nextSdkResult = -1;
    check(!ApplyExpectedFrameRateHint(&second, "surface-change-failed"), "EXPLICIT_FAILURE");
    const auto beforeRetry = applications.size();
    check(RefreshExpectedFrameRateHintForDisplayRate(90, "retry"), "ORIGINAL_POLICY_RETRY");
    check(applications.size() == beforeRetry + 1, "EXPLICIT_FAILURE_NOT_CACHED");
    check(inputForeground.size() == graphicsForeground.size(), "NOTIFICATION_COUNTS_MATCH");
    std::cout << "PASS actual frame-rate controller SDK-calls=" << applications.size()
        << " input/graphics-foreground-calls=" << inputForeground.size()
        << "; no device scheduling/input latency/CPU claim\n";
}
