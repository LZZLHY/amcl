/** 完整 proc stat 解析与严格 X/Z 判据；Linux 的 ESRCH 特意保持 Unknown，不冒充目标资格。 */
#include "../../entry/src/main/cpp/jvm/thread_terminal_token.h"
#include <cassert>
#include <atomic>
#include <string>
#include <thread>
using namespace amcl::threadterminal;
static std::string fixture(char state = 'S', const std::string& start = "12345") {
    std::string text = std::string("17 (name with ) and ( spaces) ") + state;
    for (int field = 4; field <= 52; ++field) text += " " + (field == 22 ? start : field == 19 ? std::string("-20") : std::string("0"));
    return text + "\n";
}
int main() {
    uint32_t group = 0, thread = 0;
    for (const auto path : {"17/task/18", "/proc/17/task/18"}) {
        assert(parseSelfPath(path, std::strlen(path), group, thread));
        assert(group == 17 && thread == 18);
    }
    for (const auto path : {"/other/17/task/18", "/proc/../17/task/18", "17/task/18/stat", "-17/task/18", "17/task/0"})
        assert(!parseSelfPath(path, std::strlen(path), group, thread));
    for (char state : {'S', 'R', 'X', 'Z'}) {
        const auto input = fixture(state); Stat result;
        assert(parseStat(input.data(), input.size(), result));
        assert(result.tid == 17 && result.startTime == 12345 && result.state == state);
    }
    for (auto input : {fixture('S', "0"), fixture('S', "-1"), fixture('S', "18446744073709551616"),
                       fixture('S') + "junk", std::string("17 (name) X 1 2 3\n"), fixture('!')}) {
        Stat result; assert(!parseStat(input.data(), input.size(), result));
    }
    auto embedded = fixture(); embedded[10] = 0;
    Stat result; assert(!parseStat(embedded.data(), embedded.size(), result));
    auto noOpen = fixture(); noOpen[3] = '[';
    assert(!parseStat(noOpen.data(), noOpen.size(), result));
    Token token;
    std::atomic<bool> ready{false}, finish{false};
    std::thread worker([&] {
        assert(token.openCurrent() == 0);
        ready.store(true, std::memory_order_release);
        while (!finish.load(std::memory_order_acquire)) std::this_thread::yield();
    });
    while (!ready.load(std::memory_order_acquire)) std::this_thread::yield();
    int error = 0;
    assert(token.observe(error) == Observation::Live && error == 0);
    finish.store(true, std::memory_order_release); worker.join();
    const auto after = token.observe(error);
    assert(after == Observation::Terminal || (after == Observation::Unknown && error == ESRCH));
    std::printf("PASS strict thread token parser/live identity; after-thread=%d errno=%d (Linux reference only)\n", int(after), error);
}
