// 执行生产 C ABI 的首次故障锁存、常规轻量查询、并发呈现和 fork 隔离。
// EGL/窗口只替换只读身份入口；统计和描述符实现来自实际生产 translation unit。
#include "../../platform/graphics_runtime_binding.h"
#include "../../platform/graphics_observation.cpp"
#include "host_test_check.h"
#include <iostream>
#include <sys/wait.h>
#include <thread>
namespace amcl::graphics {
const GraphicsRuntimeBinding* BoundGraphicsRuntime() { return nullptr; }
std::string GraphicsFeaturesJson(const GraphicsRuntimeBinding&) { return "null"; }
}
extern "C" uint64_t amclWindowHostPeekGeneration() { return 7; }
int main(int argc, char** argv) {
    // 微基准只量化生产CPU回调路径，窗口peek是系统边界桩；不能外推手机GPU/FPS。
    if (argc == 2) {
        const std::string mode = argv[1];
        setenv("AMCL_GRAPHICS_OBSERVATION", mode == "off" ? "0" : "1", 1);
        setenv("AMCL_GRAPHICS_OBSERVATION_COST", mode == "cost" ? "1" : "0", 1);
        CHECK(amclGraphicsPublishObserverV1());
        constexpr unsigned count = 200000;
        const auto started = nowNs();
        for (unsigned i = 0; i < count; ++i) { amclGraphicsSwapV1("GLFW", 1000, 1, 0); amclGraphicsPresentedV1("GLFW"); }
        const auto elapsed = nowNs() - started;
        std::cout << "{\"mode\":\"" << mode << "\",\"iterations\":" << count << ",\"elapsedNs\":" << elapsed
            << ",\"snapshot\":" << amclGraphicsRuntimeJsonV1() << "}\n";
        return 0;
    }
    unsetenv(AMCL_GRAPHICS_OBSERVER_ENV);
    setenv("AMCL_GRAPHICS_OBSERVATION_COST", "1", 1);
    CHECK(std::string(amclGraphicsRuntimeJsonV1()).empty());
    CHECK(amclGraphicsPublishObserverV1());
    CHECK(std::string(amclGraphicsFailureJsonV1()).empty());
    amclGraphicsSwapV1("GLFW", 2000000, 1, 0);
    amclGraphicsPresentedV1("GLFW");
    CHECK(amclGraphicsObservationEnabledV1());
    CHECK(std::string(amclGraphicsRuntimeJsonV1()).find("\"swapP95Us\":2000") != std::string::npos);
    amclGraphicsFatalV1("window-create-failed", 0x3003, 7);
    amclGraphicsFatalV1("later-teardown-failure", 0x300e, 8);
    auto failure = std::string(amclGraphicsFailureJsonV1());
    CHECK(failure.find("\"failureStage\":\"window-create-failed\"") != std::string::npos);
    CHECK(failure.find("\"failurePresentCount\":1") != std::string::npos);
    CHECK(failure.find("\"failureGeneration\":7") != std::string::npos);
    CHECK(failure.find("later-teardown") == std::string::npos);
    std::thread a([] { for (int i = 0; i < 1000; ++i) amclGraphicsPresentedV1("GLFW"); });
    std::thread b([] { for (int i = 0; i < 1000; ++i) amclGraphicsPresentedV1("GLFW"); });
    a.join(); b.join();
    const std::string current = amclGraphicsRuntimeJsonV1();
    CHECK(current.find("\"presentCount\":2001") != std::string::npos);
    CHECK(current.find("\"gpuTimeUs\":null") != std::string::npos);
    CHECK(current.find("\"observerCostSamples\":2001") != std::string::npos);
    // 模拟采集端复制期间占锁。呈现回调必须立即返回、保留总帧数/失败事实、显式统计丢样。
    const auto lostBefore = local().dropped.load();
    local().mutex.lock();
    std::thread busy([] { amclGraphicsPresentedV1("GLFW"); amclGraphicsSwapV1("GLFW", 100, 0, 0x300d); });
    busy.join();
    local().mutex.unlock();
    CHECK(local().totalFrames.load() == 2002 && local().totalSwapFailures.load() == 1);
    CHECK(local().dropped.load() == lostBefore + 2);
    // 丢样后不能把间隔当成长帧；下一采样重开片段，暂停/代际逻辑复用生产核心。
    amclGraphicsPresentedV1("GLFW");
    CHECK(local().lossSeen == local().dropped.load());
    const pid_t child = fork(); CHECK(child >= 0);
    if (!child) {
        // env 中仍是父 PID；必须在解引用环境地址前拒绝，旧锁和故障都不能继承。
        setenv(AMCL_GRAPHICS_OBSERVER_ENV, ("1:" + std::to_string(getppid()) + ":0x1").c_str(), 1);
        CHECK(std::string(amclGraphicsRuntimeJsonV1()).empty());
        setenv("AMCL_GRAPHICS_OBSERVATION", "0", 1);
        CHECK(amclGraphicsPublishObserverV1());
        CHECK(!amclGraphicsObservationEnabledV1());
        CHECK(std::string(amclGraphicsFailureJsonV1()).empty());
        const auto clean = std::string(amclGraphicsRuntimeJsonV1());
        CHECK(clean.find("\"presentCount\":0") != std::string::npos);
        amclGraphicsSwapV1("SDL3", 999999999, 1, 0);
        amclGraphicsPresentedV1("SDL3");
        amclGraphicsFatalV1("window-create-failed", 1, 8);
        const auto off = std::string(amclGraphicsRuntimeJsonV1());
        CHECK(off.find("\"presentCount\":1") != std::string::npos);
        CHECK(off.find("\"failurePresentCount\":1") != std::string::npos);
        CHECK(off.find("\"samplesEnabled\":false") != std::string::npos);
        CHECK(off.find("\"swapSamples\":0") != std::string::npos);
        CHECK(off.find("\"intervalSamples\":0") != std::string::npos);
        _exit(0);
    }
    int status = 0; CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && !WEXITSTATUS(status));
    CHECK(std::string(amclGraphicsFailureJsonV1()).find("window-create-failed") != std::string::npos);
    std::cout << "graphics-observation-abi PASS: sticky failure, exact count, nonblocking loss, disabled safety, cost, PID isolation\n";
}
