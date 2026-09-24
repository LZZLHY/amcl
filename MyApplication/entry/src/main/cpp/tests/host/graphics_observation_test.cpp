// 固定单调时钟输入验证计数、分位数和生命周期边界；只执行真实观测核心，无 GPU 桩推断。
#include "../../platform/graphics_observation_core.h"
#include <iostream>
#include <stdexcept>
#define CHECK(x) do { if (!(x)) throw std::runtime_error(#x); } while(false)
int main() try {
    amcl::graphics::GraphicsObservationCore stats;
    uint64_t clock = 1000000000;
    stats.presented(clock, 1, "GLFW");
    for (int i = 0; i < 100; ++i) {
        clock += (i == 99 ? 150000000 : 16000000);
        stats.swapped(2000000, true); stats.presented(clock, 1, "GLFW");
    }
    CHECK(stats.frames == 101 && stats.intervalCount == 100 && stats.swapCount == 100);
    CHECK(stats.percentile(stats.intervals, stats.intervalCount, 50) == 16000);
    CHECK(stats.percentile(stats.intervals, stats.intervalCount, 95) == 16000);
    CHECK(stats.long50 == 1 && stats.long100 == 1 && stats.long1000 == 0);
    stats.setForeground(false); clock += 20000000000ULL;
    stats.presented(clock, 1, "GLFW"); stats.setForeground(true);
    stats.presented(clock + 10000000000ULL, 1, "GLFW");
    CHECK(stats.intervalCount == 0 && stats.frames == 103 && stats.long1000 == 0);
    stats.presented(clock + 10016000000ULL, 1, "GLFW");
    CHECK(stats.intervalCount == 1);
    stats.presented(clock + 10032000000ULL, 2, "GLFW");
    CHECK(stats.intervalCount == 0 && stats.previousNs != 0);
    stats.swapped(7000000, false);
    CHECK(stats.swapFailures == 1 && stats.frames == 105);
    stats.presented(clock + 10048000000ULL, 2, "SDL3");
    CHECK(stats.intervalCount == 0 && stats.provider == "SDL3");
    for (int i = 0; i < 3000; ++i) stats.swapped(5000000, true);
    CHECK(stats.percentile(stats.swapTimes, stats.swapCount, 99) == 5000);
    std::cout << "Graphics observation: success-only frames, quantiles, bounded samples and lifecycle segments PASS\n";
    return 0;
} catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
