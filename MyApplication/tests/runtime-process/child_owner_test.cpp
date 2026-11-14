/** 生产PID owner的外部syscall故障序列：已reap/ECHILD后禁止信号，未知错误先等待身份。 */
#include "../../entry/src/main/cpp/jvm/processor_child_owner.h"
#include <cassert>
#include <cstdio>
#include <initializer_list>

struct Step { int result, error, flags; };
struct System {
    Step steps[8]{}; unsigned size = 0, cursor = 0, stops = 0, pauses = 0;
    bool interruptStop = false, denyStop = false;
    int64_t wait(int64_t pid, int*, int flags, int* error) noexcept {
        assert(pid == 42 && cursor < size); const Step step = steps[cursor++]; assert(flags == step.flags);
        *error = step.error; return step.result;
    }
    int stop(int64_t pid) noexcept {
        assert(pid == 42); ++stops;
        if (interruptStop && stops == 1) { errno = EINTR; return -1; }
        if (denyStop) { errno = EPERM; return -1; }
        return 0;
    }
    void pause() noexcept { ++pauses; }
};

int main() {
    using amcl::jvm::ProcessorChildOwner;
    { System system;
      { ProcessorChildOwner<System> owner(42, system); owner.observe({true, 0, 0, 42}); }
      assert(!system.cursor && !system.stops); }
    { System system;
      { ProcessorChildOwner<System> owner(42, system); owner.observe({false, 0, ECHILD, -1}); }
      assert(!system.cursor && !system.stops); }
    for (bool exited : {false, true}) {
        System system; system.size = 1; system.steps[0] = {exited ? 42 : -1, exited ? 0 : ECHILD, WNOHANG};
        { ProcessorChildOwner<System> owner(42, system); }
        assert(system.cursor == 1 && !system.stops);
    }
    { System system; system.size = 5; system.interruptStop = true;
      system.steps[0] = {-1, EINTR, WNOHANG}; system.steps[1] = {-1, EIO, WNOHANG};
      system.steps[2] = {0, 0, WNOHANG}; system.steps[3] = {-1, EINTR, 0}; system.steps[4] = {42, 0, 0};
      errno = E2BIG; { ProcessorChildOwner<System> owner(42, system); }
      assert(system.cursor == 5 && system.stops == 2 && system.pauses == 1 && errno == E2BIG); }
    { System system; system.size = 2; system.denyStop = true;
      system.steps[0] = {0, 0, WNOHANG}; system.steps[1] = {42, 0, 0};
      { ProcessorChildOwner<System> owner(42, system); }
      assert(system.cursor == 2 && system.stops == 1); } // kill被拒也不能跳过实际wait。
    puts("PASS child PID owner: reaped/lost identities never signalled, unknown wait retried, EINTR/kill refusal still require real wait");
}
