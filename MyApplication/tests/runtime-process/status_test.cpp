/** 生产状态存储的并发快照与 fork 同步：读者只见完整发布值，子进程可继续读写。 */
#include "../../entry/src/main/cpp/jvm/jvm_status.h"
#include <atomic>
#include <cassert>
#include <cstdio>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {
amcl::jvm::StatusText text;
void before() { text.beforeFork(); }
void after() { text.afterFork(); }
void check(const std::string& value) {
    assert(value.size() == 8192 && value.front() >= 'A' && value.front() <= 'E');
    for (char byte : value) assert(byte == value.front());
}
}
int main() {
    assert(pthread_atfork(before, after, after) == 0);
    text = std::string(8192, 'A');
    std::atomic<bool> start{false}, running{true};
    std::atomic<unsigned> reads{0};
    std::vector<std::thread> threads;
    for (unsigned writer = 0; writer < 4; ++writer) threads.emplace_back([&, writer] {
        while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
        for (unsigned count = 0; count < 3000; ++count) text = std::string(8192, 'B' + writer);
    });
    for (unsigned reader = 0; reader < 2; ++reader) threads.emplace_back([&] {
        while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
        while (running.load(std::memory_order_acquire)) { check(text.snapshot()); reads.fetch_add(1); }
    });
    start.store(true, std::memory_order_release);
    for (unsigned round = 0; round < 16; ++round) {
        const pid_t child = fork(); assert(child >= 0);
        if (child == 0) {
            alarm(5); // 未正确释放继承的锁会被外部 OS 截止抓住，不能无限挂住测试。
            check(text.snapshot()); text = std::string(8192, 'A'); check(text.snapshot()); _exit(0);
        }
        int status = 0; assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    }
    for (unsigned i = 0; i < 4; ++i) threads[i].join();
    running.store(false, std::memory_order_release);
    threads[4].join(); threads[5].join();
    assert(reads.load() > 0); check(text.snapshot());
    std::printf("PASS status snapshot: 12000 atomic text publications, %u coherent snapshots, 16 concurrent fork children\n", reads.load());
}
