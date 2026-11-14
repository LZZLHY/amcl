/** 用真实broker/平台后端测试请求、线程、窗口及fork生命周期，不模拟其内部状态机。 */
#include "game_dialog.h"
#include "tinyfiledialogs.h"
#include <cassert>
#include <chrono>
#include <future>
#include <string>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

/** 测试等待有独立硬期限；没有请求不能靠无限睡眠掩盖传输失效。 */
static AmclGameDialogRequestV1 Take(uint64_t generation) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    AmclGameDialogRequestV1 request{}; request.size = sizeof(request);
    while (AmclGameDialogTakeV1(generation, &request) == 0) {
        assert(std::chrono::steady_clock::now() < deadline);
        std::this_thread::yield();
    }
    assert(request.requestId > 0);
    return request;
}

int main() {
    assert(!AmclGameDialogAvailableV1());
    assert(tinyfd_messageBox("tinyfd_query", "", "ok", "info", 1) == 0);
    assert(std::string(tinyfd_response) == "no_solution");
    const auto generation = AmclGameDialogAttachV1(1234);
    assert(generation && !AmclGameDialogAttachV1(1234));
    assert(tinyfd_messageBox("tinyfd_query", "", "ok", "info", 1) == 1);
    // 同一事件线程同步调用必须立即失败，不能冻结UI导致永远等不到按钮。
    assert(tinyfd_messageBox("ui", "message", "ok", "info", 1) == 0);
    for (int kind = 1; kind <= 4; ++kind) {
        const char* types[] = {"", "ok", "okcancel", "yesno", "yesnocancel"};
        const int result = kind == 4 ? 2 : 1;
        auto caller = std::async(std::launch::async, [=] {
            return tinyfd_messageBox("真实中文标题", "正文\n第二行", types[kind], "info", 1);
        });
        const auto request = Take(generation);
        assert(std::string(request.title) == "真实中文标题" && request.kind == static_cast<unsigned>(kind));
        assert(caller.wait_for(std::chrono::milliseconds(10)) == std::future_status::timeout);
        assert(!AmclGameDialogReplyV1(generation + 1, request.requestId, result));
        assert(!AmclGameDialogReplyV1(generation, request.requestId + 1, result));
        assert(!AmclGameDialogReplyV1(generation, request.requestId, 3));
        auto foreign = std::async(std::launch::async, [=] {
            return AmclGameDialogReplyV1(generation, request.requestId, result);
        });
        assert(foreign.get() == 0);
        assert(AmclGameDialogReplyV1(generation, request.requestId, result));
        assert(!AmclGameDialogReplyV1(generation, request.requestId, result));
        assert(caller.get() == result);
    }
    // 队列容量由通知填满验证；溢出不覆盖原请求，FIFO顺序由真实标题核对。
    for (int i = 0; i < 8; ++i) assert(AmclGameDialogNotifyV1(std::to_string(i).c_str(), "x") == 1);
    assert(!AmclGameDialogNotifyV1("overflow", "x"));
    for (int i = 0; i < 8; ++i) {
        const auto request = Take(generation);
        assert(std::string(request.title) == std::to_string(i));
        assert(!AmclGameDialogReplyV1(generation, request.requestId, 1));
        assert(AmclGameDialogReplyV1(generation, request.requestId, 0));
    }
    std::string huge(32768, 'x');
    assert(!AmclGameDialogNotifyV1("too-long", huge.c_str()));
    auto waiting = std::async(std::launch::async, [] { return tinyfd_messageBox("retire", "", "yesno", "", 1); });
    const auto retired = Take(generation);
    AmclGameDialogDetachV1(generation);
    assert(waiting.get() == 0 && !AmclGameDialogAvailableV1());
    assert(!AmclGameDialogAttachV1(5678));
    const auto second = AmclGameDialogAttachV1(1234);
    assert(second > generation);
    assert(!AmclGameDialogAttachV1(1234));
    AmclGameDialogDetachV1(generation);
    assert(AmclGameDialogAvailableV1());
    assert(!AmclGameDialogReplyV1(second, retired.requestId, 1));
    // fork继承库实例在触碰mutex前拒绝；不能借父窗口，也不能自挂成新会话。
    const pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        const bool safe = !AmclGameDialogAvailableV1() && !AmclGameDialogAttachV1(1234) &&
            !AmclGameDialogMessageV1("child", "", 1, 1);
        _exit(safe ? 0 : 9);
    }
    int status = 0; assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    unsigned char rgb[3] = {23, 45, 67};
    assert(!tinyfd_colorChooser("test", "#ffffff", rgb, rgb) && rgb[0] == 23 && rgb[1] == 45 && rgb[2] == 67);
    assert(!tinyfd_openFileDialog("tinyfd_query", "", 0, nullptr, "", 1));
    assert(std::string(tinyfd_response) == "no_solution");
    assert(!tinyfd_inputBox("tinyfd_query", "", nullptr));
    tinyfd_setGlobalInt("tinyfd_forceConsole", 1);
    assert(!tinyfd_messageBox("tinyfd_query", "", "ok", "", 1));
    tinyfd_setGlobalInt("tinyfd_forceConsole", 0);
    AmclGameDialogDetachV1(second);
    std::puts("PASS: actual broker/UTF-8/buttons/FIFO/retirement/fork/UI thread/unsupported controls");
}
