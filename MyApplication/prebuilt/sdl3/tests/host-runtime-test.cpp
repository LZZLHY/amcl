/*
 * SDL host-runtime 的宿主可执行回归；生产函数由脚本从 pinned 基线+补丁抽取。
 * 桩只模拟 OS/SDL 基础设施和设备子系统，不重新实现被测状态机、递归入口或计数器。
 * 此测试证明入口和线程/会话规则，不冒充 OHOS 设备、窗口或 EGL 渲染验收。
 */
#include <atomic>
#include <cassert>
#include <cstdarg>
#include <cstdio>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#include <sys/syscall.h>
#endif
#define SDL_PLATFORM_OPENHARMONY 1
#include "SDL_amclhostruntime.h"

using Uint32 = uint32_t;
using Uint8 = uint8_t;
using SDL_ThreadID = uint64_t;
using SDL_InitFlags = uint32_t;
using SDL_SpinLock = std::mutex;
struct SDL_AtomicInt { std::atomic<int> value{0}; };
constexpr Uint32 SDL_INIT_EVENTS = 1u;
constexpr Uint32 SDL_INIT_VIDEO = 2u;
constexpr Uint32 SDL_INIT_AUDIO = 4u;
constexpr Uint32 SDL_INIT_JOYSTICK = 8u;
constexpr Uint32 SDL_INIT_GAMEPAD = 16u;
constexpr Uint32 SDL_INIT_HAPTIC = 32u;
constexpr Uint32 SDL_INIT_SENSOR = 64u;
constexpr Uint32 SDL_INIT_CAMERA = 128u;
#define SDL_AUDIO_DISABLED 1
#define SDL_JOYSTICK_DISABLED 1
#define SDL_HAPTIC_DISABLED 1
#define SDL_SENSOR_DISABLED 1
#define SDL_CAMERA_DISABLED 1
#define SDL_LOG_CATEGORY_SYSTEM 0
#define SDL_assert(value) assert(value)

/* 宿主真实 PID/TID 用于并发用例；不把 std::thread 名称或哈希当作 kernel TID。 */
static uint64_t TestPid()
{
#ifdef _WIN32
    return GetCurrentProcessId();
#else
    return static_cast<uint64_t>(getpid());
#endif
}
static uint64_t TestTid()
{
#ifdef _WIN32
    return GetCurrentThreadId();
#else
    return static_cast<uint64_t>(syscall(SYS_gettid));
#endif
}
/* 以下宏只适配生产代码的系统函数名；TestTid 已在宏定义之前编译。 */
#define getpid() TestPid()
#define syscall(number) TestTid()
#ifndef SYS_gettid
#define SYS_gettid 0
#endif

static bool SDL_MainIsReady = false;
static SDL_ThreadID SDL_MainThreadID = 0;
static SDL_ThreadID SDL_EventsThreadID = 0;
static SDL_ThreadID SDL_VideoThreadID = 0;
static bool SDL_bInMainQuit = false;
static Uint8 SDL_SubsystemRefCount[32];
static AMCL_SdlHostRuntime SDL_amclHostRuntime;
static SDL_SpinLock SDL_amclHostLock;
static SDL_AtomicInt SDL_amclHostMode;
static SDL_AtomicInt SDL_amclHostPumpObserved;
static std::string descriptor;
static bool hasDescriptor = true;
static thread_local std::string lastError;
static bool eventsFail = false;
static bool videoFail = false;
static int eventsCalls = 0;
static int videoCalls = 0;
static std::atomic<int> mainLogs{0};
static std::atomic<int> eventLogs{0};
static std::atomic<int> videoLogs{0};
static std::atomic<int> pumpLogs{0};

/* 最小底层桩：保留锁的非递归性质，错误和日志可观察，任何持锁递归会真实死锁。 */
static SDL_ThreadID SDL_GetCurrentThreadID() { return TestTid(); }
static void SDL_LockSpinlock(SDL_SpinLock *lock) { lock->lock(); }
static void SDL_UnlockSpinlock(SDL_SpinLock *lock) { lock->unlock(); }
static void SDL_SetAtomicInt(SDL_AtomicInt *value, int next) { value->value.store(next); }
static int SDL_GetAtomicInt(SDL_AtomicInt *value) { return value->value.load(); }
static bool SDL_CompareAndSwapAtomicInt(SDL_AtomicInt *value, int before, int after)
{
    return value->value.compare_exchange_strong(before, after);
}
static const char *SDL_getenv_unsafe(const char *) { return hasDescriptor ? descriptor.c_str() : nullptr; }
static bool SDL_SetError(const char *format, ...)
{
    char buffer[512];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    lastError = buffer;
    return false;
}
static bool SDL_ClearError() { lastError.clear(); return true; }
static void SDL_PushError() {}
static void SDL_PopError() {}
static void SDL_LogInfo(int, const char *format, ...)
{
    const std::string message(format);
    if (message.find("phase=main-ready") != std::string::npos) ++mainLogs;
    if (message.find("phase=events-ready") != std::string::npos) ++eventLogs;
    if (message.find("phase=video-ready") != std::string::npos) ++videoLogs;
    if (message.find("phase=event-pump") != std::string::npos) ++pumpLogs;
}
static int SDL_MostSignificantBitIndex32(Uint32 value)
{
    int result = -1;
    while (value) { ++result; value >>= 1; }
    return result;
}
static void SDL_InitMainThread() { assert(SDL_MainIsReady); }
static bool SDL_InitEvents() { ++eventsCalls; return !eventsFail; }
static bool SDL_VideoInit(const char *) { ++videoCalls; return !videoFail; }
static void SDL_QuitSubSystem(SDL_InitFlags flags)
{
    /* 测试只需要验证实际生产 InitSubSystem 失败分支确实撤销所领引用。 */
    for (int i = 0; i < 32; ++i) {
        if ((flags & (Uint32{1} << i)) && SDL_SubsystemRefCount[i]) --SDL_SubsystemRefCount[i];
    }
}
static void SDL_SetMainReady();
static bool SDL_InitSubSystem(SDL_InitFlags flags);
/* AMCL_PRODUCTION_FUNCTIONS */

/* 每个用例模拟一个全新 DSO/进程，不用于生产热重启；所有工作线程先 join 再重置。 */
static void Reset()
{
    SDL_amclHostRuntime = {};
    SDL_MainIsReady = false;
    SDL_MainThreadID = SDL_EventsThreadID = SDL_VideoThreadID = 0;
    SDL_amclHostMode.value = 0;
    SDL_amclHostPumpObserved.value = 0;
    for (auto &count : SDL_SubsystemRefCount) count = 0;
    eventsFail = videoFail = false;
    eventsCalls = videoCalls = 0;
    mainLogs = eventLogs = videoLogs = pumpLogs = 0;
    hasDescriptor = true;
    descriptor = "1:" + std::to_string(TestPid()) + ":" + std::to_string(TestTid()) + ":73";
    lastError.clear();
}

int main()
{
    /* ABI 严格解析和无副作用拒绝；格式无效不能先把状态绑定到某个调用者。 */
    const std::vector<std::string> malformed = {
        "", "0:1:2:3", "2:1:2:3", "01:1:2:3", "1:0:2:3", "1:1:0:3", "1:1:2:0",
        "1:+1:2:3", "1: 1:2:3", "1:1:2:3 ", "1:1:2:3:4", "1:1:2", "1:1:2:",
        "1:1:2:18446744073709551616", "1:1:2:99999999999999999999999999999999999"
    };
    for (const auto &value : malformed) {
        AMCL_SdlHostRuntime runtime{};
        assert(AMCL_SdlHostPrepare(&runtime, value.c_str(), 1, 2) == AMCL_SDL_HOST_MALFORMED);
        assert(runtime.state == 0);
    }
    AMCL_SdlHostRuntime maximum{};
    assert(AMCL_SdlHostPrepare(&maximum, "1:1:2:18446744073709551615", 1, 2) == AMCL_SDL_HOST_FIRST);
    assert(maximum.session == UINT64_MAX);

    /* 缺描述符完全保留上游 main-ready 失败；显式 SetMainReady 后 standalone 可 Init。 */
    Reset();
    hasDescriptor = false;
    assert(!SDL_Init(SDL_INIT_VIDEO));
    assert(lastError.find("Application didn't initialize") != std::string::npos);
    assert(mainLogs == 0 && eventsCalls == 0 && videoCalls == 0);
    SDL_SetMainReady();
    assert(SDL_Init(SDL_INIT_VIDEO));
    assert(SDL_AMCL_RetireHostRuntime());
    assert(SDL_Init(0));
    hasDescriptor = true;
    assert(!SDL_Init(0));

    /* 真实 video -> InitOrIncrementSubsystem(EVENTS) -> InitSubSystem 递归不能死锁。 */
    Reset();
    assert(SDL_Init(SDL_INIT_VIDEO));
    assert(eventsCalls == 1 && videoCalls == 1 && mainLogs == 1 && eventLogs == 1 && videoLogs == 1);
    assert(SDL_MainThreadID == TestTid() && SDL_EventsThreadID == TestTid() && SDL_VideoThreadID == TestTid());
    assert(SDL_Init(SDL_INIT_VIDEO));
    assert(mainLogs == 1 && eventsCalls == 1 && videoCalls == 1);
    assert(SDL_AMCL_ValidateEventThread(false) && pumpLogs == 0);
    assert(SDL_AMCL_ValidateEventThread(true) && SDL_AMCL_ValidateEventThread(true) && pumpLogs == 1);
    std::thread rejected([] {
        assert(!SDL_Init(SDL_INIT_EVENTS));
        assert(!SDL_AMCL_ValidateEventThread(false));
        assert(!SDL_AMCL_ValidateEventThread(true));
        assert(!SDL_AMCL_RetireHostRuntime());
    });
    rejected.join();
    assert(SDL_amclHostRuntime.state == 2 && mainLogs == 1);
    assert(SDL_AMCL_RetireHostRuntime() && SDL_AMCL_RetireHostRuntime());
    assert(!SDL_Init(0) && !SDL_AMCL_ValidateEventThread(true));
    descriptor.back() = '4';
    assert(!SDL_Init(0));
    hasDescriptor = false;
    assert(!SDL_Init(0));

    /* 错误 PID、错误初始线程和已被其他线程认领的 SDL 主线程都不能抢占 owner。 */
    Reset();
    descriptor = "1:" + std::to_string(TestPid() + 1) + ":" + std::to_string(TestTid()) + ":73";
    assert(!SDL_Init(0) && SDL_amclHostRuntime.state == 0);
    Reset();
    std::thread firstRejected([] { assert(!SDL_Init(0)); });
    firstRejected.join();
    assert(SDL_amclHostRuntime.state == 0 && !SDL_MainIsReady);
    SDL_MainThreadID = TestTid() + 1;
    assert(!SDL_Init(0) && !SDL_MainIsReady);
    assert(SDL_amclHostRuntime.state == 3);
    SDL_MainThreadID = TestTid();
    assert(!SDL_Init(0) && !SDL_MainIsReady);

    /* 仅发布身份不主动绑定 SDL；此用例不冒充多动态库加载顺序的设备验收。 */
    Reset();
    assert(SDL_amclHostRuntime.state == 0 && !SDL_MainIsReady && mainLogs == 0);
    assert(SDL_Init(0) && mainLogs == 1);
    descriptor.back() = '4';
    assert(!SDL_Init(SDL_INIT_VIDEO) && eventsCalls == 0);

    /* main-ready 与子系统成功是不同事实；保留真实 Init 的失败传播及引用计数回滚。 */
    Reset();
    eventsFail = true;
    assert(!SDL_Init(SDL_INIT_VIDEO));
    assert(SDL_MainIsReady && mainLogs == 1 && eventLogs == 0 && videoLogs == 0);
    assert(SDL_SubsystemRefCount[0] == 0 && SDL_SubsystemRefCount[1] == 0 && videoCalls == 0);
    Reset();
    videoFail = true;
    assert(!SDL_Init(SDL_INIT_VIDEO));
    assert(mainLogs == 1 && eventLogs == 1 && videoLogs == 0);
    assert(SDL_SubsystemRefCount[0] == 0 && SDL_SubsystemRefCount[1] == 0);
    assert(SDL_AMCL_RetireHostRuntime());
    videoFail = false;
    assert(!SDL_Init(SDL_INIT_VIDEO));

    /* 多个真正并发工作线程均被拒绝，不能污染允许线程的幂等 Init。 */
    Reset();
    std::vector<std::thread> workers;
    for (int i = 0; i < 16; ++i) workers.emplace_back([] { assert(!SDL_Init(0)); });
    assert(SDL_Init(0));
    for (auto &worker : workers) worker.join();
    assert(mainLogs == 1 && SDL_MainThreadID == TestTid());
    std::puts("SDL host-runtime compiled production entrypoints: PASS");
    return 0;
}
