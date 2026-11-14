/** 确定性反例：Recheck 持registry锁时，另一Sweep在锁外报同一errno；旧成功观察
 * 不能清掉这次新失败。可指定真实旧header作负对照，不复制/改写被测算法。
 */
#ifdef AMCL_TLS_STORAGE_HEADER
#include AMCL_TLS_STORAGE_HEADER
#else
#include "../../entry/src/main/cpp/jvm/tls_thread_storage.h"
#endif
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <thread>

using namespace amcl::tlsstorage;
static thread_local bool recoveryThread = false;
struct State {
    std::atomic<int> error{0};
    std::atomic<bool> blocked{false}, release{false};
    static int observe(pid_t process, pid_t thread, void* opaque) noexcept {
        auto& state = *static_cast<State*>(opaque);
        const int captured = state.error.load();
        if (recoveryThread) {
            state.blocked.store(true);
            while (!state.release.load()) std::this_thread::yield();
        }
        return captured ? captured : detail::observe(process, thread, nullptr);
    }
};
int main() {
    State state; Functions functions; functions.context = &state; functions.observe = State::observe;
    Coordinator owner; assert(owner.Initialize(functions) == 0);
    state.error = EPERM; assert(owner.Sweep().error == EPERM); // 已有故障值。
    state.error = 0;
    int recovery = -1;
    std::thread recheck([&] { recoveryThread = true; recovery = owner.RecheckCapability(); });
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!state.blocked.load()) { assert(std::chrono::steady_clock::now() < deadline); std::this_thread::yield(); }
    state.error = EPERM; assert(owner.Sweep().error == EPERM); // 相同errno、不同失败事件，发生在旧观察之后。
    state.error = 0; state.release = true; recheck.join();
    const int remaining = owner.Snapshot().expansionError;
    const bool preserved = recovery == EPERM && remaining == EPERM;
    std::printf("RECOVERY_RACE recheck=%d remaining=%d expected=%d\n", recovery, remaining, EPERM);
    assert(owner.RecheckCapability() == 0 && owner.Snapshot().expansionError == 0);
    assert(owner.Shutdown() == 0);
    if (!preserved) {
        std::puts("REPRO stale recovery erased a newer same-errno failure");
        return 77;
    }
    std::puts("PASS newer same-errno failure survives stale recovery and only a fresh recheck clears it");
    return 0;
}
