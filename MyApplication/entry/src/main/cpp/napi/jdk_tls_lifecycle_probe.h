/**
 * 固定 SDK CRT A/B 夹具的设备生命周期探针，仅由 TestHooks 原生子进程调用。
 * 事件驻留宿主固定数组；真实用户析构由系统线程退出队列调用，绝不手工模拟。
 * 每轮先释放等待条件并 join，再格式化可能分配的报告；异常不能遗留活动工作线程。
 */
#pragma once
#include "../jvm/elf_loader.h"
#include "../platform/jdk_install_io.h"
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <pthread.h>
#include <sstream>
#include <string>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

namespace amcl::jdkprobe::tls_lifecycle_detail {
constexpr int HostMarker = 0x13572468;
constexpr size_t EventCapacity = 128;
struct Event { int code = 0, detail = 0; long thread = 0; };
struct Snapshot { Event events[EventCapacity]{}; size_t size = 0; bool overflow = false; int error = 0; };

/** 进程寿命存储避免失败场景的迟到析构回调访问栈；成功且全部回调完成才进入下一场景。 */
inline pthread_mutex_t traceMutex = PTHREAD_MUTEX_INITIALIZER;
inline Snapshot trace;
inline std::atomic<int> traceLockError{0};
inline std::atomic_flag running = ATOMIC_FLAG_INIT;

inline void Record(int code, int detail) noexcept {
    const int error = pthread_mutex_lock(&traceMutex);
    if (error) { traceLockError.store(error); return; }
    if (trace.size == EventCapacity) trace.overflow = true;
    else trace.events[trace.size++] = Event{code, detail, syscall(SYS_gettid)};
    pthread_mutex_unlock(&traceMutex);
}
inline Snapshot ReadTrace(bool reset = false) noexcept {
    Snapshot result;
    const int error = pthread_mutex_lock(&traceMutex);
    if (error) { result.error = error; return result; }
    result = trace;
    result.error = traceLockError.load();
    if (reset) { trace = {}; traceLockError.store(0); }
    pthread_mutex_unlock(&traceMutex);
    return result;
}

/** 保留包含本头的普通 SDK 编译行为，不为宿主对象强制 TLS 模型。volatile 确保析构
 * 真正读取自己的存储；默认 emutls 若在此之前释放对象，会在目标呈现失败而非固定常量。 */
struct HostThreadValue {
    volatile int marker = HostMarker;
    HostThreadValue() noexcept { Record(90, marker); }
    ~HostThreadValue() noexcept { Record(91, marker); }
};
inline int TouchHostThreadValue() {
    static thread_local HostThreadValue value;
    return value.marker;
}

/** 一个公开引用只有一个所有者。Close先移出句柄，异常也不会在析构中重复消费引用。 */
struct Handle {
    elf_handle_t* value = nullptr;
    int closeError = 0;
    Handle() = default;
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
    ~Handle() { Close(); }
    void Close() noexcept {
        auto* closing = value;
        value = nullptr;
        if (!closing) return;
        try { closeError = elf_dlclose(closing); }
        catch (...) { closeError = -999; }
    }
};
struct Api {
    void (*configure)(void (*)(int, int)) = nullptr;
    int (*initial)() = nullptr;
    int (*live)() = nullptr;
    int (*touch)(int) = nullptr;
    void (*late)(int) = nullptr;
    int (*exception)(int) = nullptr;
    bool Bind(elf_handle_t* handle) {
        configure = reinterpret_cast<decltype(configure)>(elf_sym(handle, "amcl_sdk_tls_configure"));
        initial = reinterpret_cast<decltype(initial)>(elf_sym(handle, "amcl_sdk_tls_initial_value"));
        live = reinterpret_cast<decltype(live)>(elf_sym(handle, "amcl_sdk_tls_resource_live"));
        touch = reinterpret_cast<decltype(touch)>(elf_sym(handle, "amcl_sdk_tls_touch"));
        late = reinterpret_cast<decltype(late)>(elf_sym(handle, "amcl_sdk_tls_enable_late"));
        exception = reinterpret_cast<decltype(exception)>(elf_sym(handle, "amcl_sdk_tls_exception_roundtrip"));
        return configure && initial && live && touch && late && exception;
    }
};
enum class Scene { InitialAndEh, HeldTls, LateTls, InterleavedTls };

/** 线程状态只在 ready 的互斥同步后、或 join 后读；句柄只由约定的关闭方修改。 */
struct State {
    Scene scene;
    Api api;
    Handle handle;
    pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
    bool ready = false, released = false;
    int workerError = 0, waitError = 0;
    int initial = -999, exception = -999, first = -999, second = -999, host = -999;
    long workerTid = 0;
    explicit State(Scene value) : scene(value) {}
    ~State() { pthread_cond_destroy(&changed); pthread_mutex_destroy(&mutex); }
    State(const State&) = delete;
    State& operator=(const State&) = delete;
    void Release() noexcept {
        const int error = pthread_mutex_lock(&mutex);
        if (error) return;
        released = true;
        pthread_cond_broadcast(&changed);
        pthread_mutex_unlock(&mutex);
    }
    bool WaitReady() noexcept {
        timespec until{};
        if (clock_gettime(CLOCK_REALTIME, &until) != 0) { waitError = errno; return false; }
        until.tv_sec += 2;
        int error = pthread_mutex_lock(&mutex);
        if (error) { waitError = error; return false; }
        while (!ready && !error) error = pthread_cond_timedwait(&changed, &mutex, &until);
        const bool result = ready && !error;
        pthread_mutex_unlock(&mutex);
        waitError = error;
        return result;
    }
};

inline void* Worker(void* opaque) noexcept {
    auto& state = *static_cast<State*>(opaque);
    state.workerTid = syscall(SYS_gettid);
    try {
        state.initial = state.api.initial();
        if (state.scene == Scene::InitialAndEh) state.exception = state.api.exception(9041);
        else if (state.scene == Scene::LateTls) {
            // 创建线程失败时此开关尚未启用，父线程清理不会意外留下自己的晚 TLS 回调。
            state.api.late(1);
            state.handle.Close();
        } else {
            state.first = state.api.touch(1);
            if (state.scene == Scene::InterleavedTls) state.host = TouchHostThreadValue();
            state.second = state.api.touch(2);
        }
    } catch (...) { state.workerError = -999; }
    int error = pthread_mutex_lock(&state.mutex);
    if (error) { state.workerError = error; return nullptr; }
    state.ready = true;
    pthread_cond_broadcast(&state.changed);
    while (!state.released && !error) error = pthread_cond_wait(&state.changed, &state.mutex);
    if (error) state.workerError = error;
    pthread_mutex_unlock(&state.mutex);
    // 正常return触发真实系统TLS队列；这里没有调用任何夹具/宿主析构函数。
    return nullptr;
}

/** 父报告分配或任何C++异常展开时仍先release+join。成功创建的可join线程使用唯一
 * join所有者；异常OS状态下不能返回并让线程引用失效栈，隔离子进程明确失败退出。 */
struct JoinedWorker {
    State& state;
    pthread_t thread{};
    bool started = false;
    int startError = 0, joinError = 0;
    explicit JoinedWorker(State& value) : state(value) {}
    ~JoinedWorker() { Finish(); }
    void Start() noexcept {
        startError = pthread_create(&thread, nullptr, Worker, &state);
        started = startError == 0;
    }
    void Finish() noexcept {
        if (!started) return;
        state.Release();
        joinError = pthread_join(thread, nullptr);
        if (joinError) {
            static const char message[] = "AMCL TLS probe: cannot join owned worker\n";
            (void)write(STDERR_FILENO, message, sizeof(message) - 1);
            _exit(125);
        }
        started = false;
    }
};

inline size_t Count(const Snapshot& value, int code, int detail) noexcept {
    size_t count = 0;
    for (size_t i = 0; i < value.size; ++i)
        if (value.events[i].code == code && value.events[i].detail == detail) ++count;
    return count;
}
inline size_t Position(const Snapshot& value, int code, int detail) noexcept {
    for (size_t i = 0; i < value.size; ++i)
        if (value.events[i].code == code && value.events[i].detail == detail) return i;
    return EventCapacity;
}
inline bool HasCode(const Snapshot& value, int code) noexcept {
    for (size_t i = 0; i < value.size; ++i) if (value.events[i].code == code) return true;
    return false;
}
inline void WriteEvents(std::ostringstream& report, const Snapshot& value) {
    report << " count=" << value.size << " overflow=" << value.overflow << " traceError=" << value.error << " events=";
    for (size_t i = 0; i < value.size; ++i) {
        if (i) report << ',';
        const auto& event = value.events[i];
        report << event.code << ':' << event.detail << '@' << event.thread;
    }
    report << '\n';
}

/** 每场景返回前所有线程已join、公开handle已归还；失败保留所有实际事件，不由计时推定完成。 */
inline bool RunScene(const std::string& path, Scene scene, const char* name, std::ostringstream& report) {
    ReadTrace(true);
    State state(scene);
    state.handle.value = elf_open(path.c_str());
    if (!state.handle.value || !state.api.Bind(state.handle.value)) {
        state.handle.Close();
        report << "tlsLifecycle case=" << name << " passed=0 step=open-or-symbol error=" << elf_error() << '\n';
        WriteEvents(report, ReadTrace());
        return false;
    }
    state.api.configure(Record);
    const int live = state.api.live();
    const int loadingInitial = state.api.initial();
    const int loadingEh = scene == Scene::InitialAndEh ? state.api.exception(9041) : 0;
    JoinedWorker worker(state);
    worker.Start();
    const bool ready = worker.startError == 0 && state.WaitReady();
    if (ready && scene != Scene::InitialAndEh && scene != Scene::LateTls) state.handle.Close();
    const Snapshot beforeExit = ReadTrace();
    worker.Finish();
    state.handle.Close();
    const Snapshot final = ReadTrace();
    bool passed = ready && worker.startError == 0 && worker.joinError == 0 && state.waitError == 0 &&
        state.workerError == 0 && state.handle.closeError == 0 && state.workerTid > 0 && live == 1 && loadingInitial == 73 &&
        state.initial == 73 && !final.overflow && !final.error && !beforeExit.overflow && !beforeExit.error;
    passed = passed && Count(final, 10, 0) == 1 && Count(final, 11, 0) == 1 && Count(final, 30, 0) == 1 &&
        Position(final, 10, 0) < Position(final, 11, 0) && !HasCode(final, 31);
    if (scene == Scene::InitialAndEh) {
        passed = passed && loadingEh == 9041 && state.exception == 9041 &&
            final.size == 9 && Count(final, 40, 0) == 2 && Count(final, 41, 9041) == 2 && Count(final, 42, 0) == 2;
        for (size_t i = 0; i < 6 && i < final.size; ++i)
            passed = passed && final.events[i].code == 40 + static_cast<int>(i % 3);
    } else {
        passed = passed && !HasCode(beforeExit, 21) && !HasCode(beforeExit, 30) && Count(final, 20, 1) == 1 &&
            Count(final, 21, 1) == 1 && Position(final, 21, 1) < Position(final, 30, 0);
        if (scene == Scene::LateTls) {
            passed = passed && beforeExit.size == 3 && final.size == 5 &&
                beforeExit.events[0].code == 10 && beforeExit.events[1].code == 20 && beforeExit.events[1].detail == 1 &&
                beforeExit.events[2].code == 11;
        } else {
            passed = passed && state.first == 38 && state.second == 39 && Count(final, 20, 2) == 1 &&
                Count(final, 21, 2) == 1 && Position(final, 21, 2) < Position(final, 21, 1);
            if (scene == Scene::InterleavedTls) {
                passed = passed && state.host == HostMarker && final.size == 9 && Count(final, 90, HostMarker) == 1 &&
                    Count(final, 91, HostMarker) == 1 && Position(final, 21, 2) < Position(final, 91, HostMarker) &&
                    Position(final, 91, HostMarker) < Position(final, 21, 1);
            } else passed = passed && final.size == 7;
        }
        for (size_t i = 0; i < final.size; ++i) {
            const auto& event = final.events[i];
            if (event.code == 20 || event.code == 21 || event.code == 90 || event.code == 91)
                passed = passed && event.thread == state.workerTid;
        }
    }
    // 下面才可能因字符串流分配失败抛异常，此时已无活动worker或未归还的公开handle。
    report << "tlsLifecycle case=" << name << " passed=" << passed << " ready=" << ready
           << " createError=" << worker.startError << " joinError=" << worker.joinError
           << " waitError=" << state.waitError << " workerError=" << state.workerError
           << " closeError=" << state.handle.closeError << " workerTid=" << state.workerTid
           << " loadingInitial=" << loadingInitial << " threadInitial=" << state.initial
           << " loadingEh=" << loadingEh << " threadEh=" << state.exception
           << " first=" << state.first << " second=" << state.second << " hostMarker=" << state.host << '\n';
    report << "tlsLifecycle case=" << name << " phase=before-worker-exit";
    WriteEvents(report, beforeExit);
    report << "tlsLifecycle case=" << name << " phase=joined-and-closed";
    WriteEvents(report, final);
    return passed;
}
} // namespace amcl::jdkprobe::tls_lifecycle_detail

namespace amcl::jdkprobe {
/** 四场景仅接受已留存构建收据的SDK r3字节；夹具缺失/错误身份明确不可用，无自动PASS。 */
inline void TlsLifecycleProbe(const std::string& filesDir, std::ostringstream& report) {
    namespace test = tls_lifecycle_detail;
    if (test::running.test_and_set()) { report << "tlsLifecycle passed=0 busy=1\n"; return; }
    struct RunningGuard { ~RunningGuard() { test::running.clear(); } } runningGuard;
    const char* activeScene = "fixture";
    try {
        const std::string directory = filesDir + "/jdk-tls-crt";
        const std::string a = directory + "/libamcl_sdk_tls_a.so";
        const std::string b = directory + "/libamcl_sdk_tls_b.so";
        if (access(a.c_str(), R_OK) || access(b.c_str(), R_OK)) {
            report << "tlsLifecycle fixtureAvailable=0 passed=0 error=" << errno << '\n'; return;
        }
        auto root = amcl::jdk::io::Directory(directory);
        const auto hashA = amcl::jdk::io::Digest(amcl::jdk::io::SmallFile(root.get(), "libamcl_sdk_tls_a.so", 1024 * 1024));
        const auto hashB = amcl::jdk::io::Digest(amcl::jdk::io::SmallFile(root.get(), "libamcl_sdk_tls_b.so", 1024 * 1024));
        const bool identity = hashA == "52b6d80bf058571a852d7cd6ac908ebdd7a65b87879cd1919a2e7dc4e3c25ad4" &&
            hashB == "108b454b07aa77488b0e72df99b4a07510064c548382f80b770f8dabededf05d";
        report << "tlsLifecycle fixtureAvailable=1 identity=" << identity << " aSha=" << hashA << " bSha=" << hashB << '\n';
        if (!identity) { report << "tlsLifecycle passed=0 reason=fixture-identity\n"; return; }
        elf_set_search_path(directory.c_str());
        const test::Scene scenes[] = {test::Scene::InitialAndEh, test::Scene::HeldTls,
                                     test::Scene::LateTls, test::Scene::InterleavedTls};
        const char* names[] = {"initial-eh", "held-tls", "fini-first-touch", "system-queue-interleave"};
        for (size_t i = 0; i < 4; ++i) {
            activeScene = names[i];
            if (!test::RunScene(a, scenes[i], names[i], report)) {
                report << "tlsLifecycle passed=0 stoppedAfter=" << names[i] << " completedCases=" << i << '\n';
                return; // 未证实旧回调全部结束时不能重置事件缓存、污染下一场景的身份。
            }
        }
        report << "tlsLifecycle passed=1 completedCases=4 scope=SDK-CRT-TLSDESC-EH-lifecycle\n";
    } catch (const std::exception& error) {
        report << "tlsLifecycle passed=0 case=" << activeScene << " exception=" << error.what() << '\n';
        test::WriteEvents(report, test::ReadTrace());
    } catch (...) {
        report << "tlsLifecycle passed=0 case=" << activeScene << " exception=unknown\n";
        test::WriteEvents(report, test::ReadTrace());
    }
}
} // namespace amcl::jdkprobe
