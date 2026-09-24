/**
 * 直接执行生产等待 helper 的故障注入回归。
 * 覆盖正常退出、信号状态透传、连续 EINTR、系统错误、错误 PID；不模拟出虚假的 wait 成功。
 */
#include "../../jvm/processor_wait.h"
#include <cstdlib>
#include <iostream>
#include <vector>

#define REQUIRE(x) do { if (!(x)) { std::cerr << "FAIL " << __LINE__ << ": " #x << '\n'; std::exit(1); } } while (0)

/** 每一步精确指定返回 PID、输出 status 和 errno；末尾继续调用属于等待协议错误。 */
struct WaitStep { int64_t pid; int status; int error; };
struct WaitFixture {
    std::vector<WaitStep> steps;
    size_t calls = 0;
    amcl::jvm::ProcessorWaitResult run(int64_t expected = 42) {
        return amcl::jvm::WaitForProcessor(expected, [&](int64_t requested, int* status, int* error) {
            REQUIRE(requested == 42 && calls < steps.size());
            const auto& step = steps[calls++];
            *status = step.status;
            *error = step.error;
            return step.pid;
        });
    }
};

int main() {
    WaitFixture success{{{42, 0, 0}}};
    auto result = success.run();
    REQUIRE(result.reaped && result.status == 0 && result.error == 0 && success.calls == 1);

    WaitFixture exited{{{42, 23 << 8, 0}}};
    result = exited.run();
    REQUIRE(result.reaped && result.status == (23 << 8));

    WaitFixture signaled{{{42, 9, 0}}};
    result = signaled.run();
    REQUIRE(result.reaped && result.status == 9);

    WaitFixture interrupted{{{-1, 0, EINTR}, {-1, 123, EINTR}, {42, 7 << 8, 0}}};
    result = interrupted.run();
    REQUIRE(result.reaped && result.status == (7 << 8) && result.error == 0 && interrupted.calls == 3);

    WaitFixture interruptedFailure{{{-1, 0, EINTR}, {-1, 0, ECHILD}}};
    result = interruptedFailure.run();
    REQUIRE(!result.reaped && result.error == ECHILD && interruptedFailure.calls == 2);

    WaitFixture systemFailure{{{-1, 0, ECHILD}}};
    result = systemFailure.run();
    REQUIRE(!result.reaped && result.error == ECHILD && result.actualPid == -1 && systemFailure.calls == 1);

    WaitFixture zero{{{0, 0, 0}}};
    result = zero.run();
    REQUIRE(!result.reaped && result.error == ECHILD && result.actualPid == 0);

    WaitFixture wrongPid{{{43, 0, 0}}};
    result = wrongPid.run();
    REQUIRE(!result.reaped && result.error == ECHILD && result.actualPid == 43);

    WaitFixture missingError{{{-1, 999, 0}}};
    result = missingError.run();
    REQUIRE(!result.reaped && result.error == EIO && result.status == 0);

    WaitFixture invalid{{}};
    result = invalid.run(0);
    REQUIRE(!result.reaped && result.error == EINVAL && invalid.calls == 0);
    std::cout << "PASS processor wait: 10 cases, EINTR retries, exact PID and failure status rejection\n";
}
