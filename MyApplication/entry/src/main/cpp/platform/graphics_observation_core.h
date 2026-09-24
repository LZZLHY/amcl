#pragma once
#include <algorithm>
#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace amcl::graphics {
/** 后端无关的有界帧观测核心。时间来自调用者的单调时钟，测试可注入时间。
 * presented 只在真正成功呈现后调用；swap 记录调用耗时，不冒称 GPU 或纯 CPU 帧时间。
 * 前后台/窗口代际边界重置间隔起点，避免将后台暂停摊入游戏长帧分布。
 */
struct GraphicsObservationCore {
    static constexpr std::size_t capacity = 1024;
    std::array<uint64_t, capacity> intervals{};
    std::array<uint64_t, capacity> swapTimes{};
    uint64_t frames = 0, intervalCount = 0, swapCount = 0, swapFailures = 0;
    uint64_t boundaries = 0, long50 = 0, long100 = 0, long1000 = 0;
    uint64_t previousNs = 0, generation = 0;
    uint64_t segment = 1;
    bool foreground = true;
    std::string provider;
    void resetSegment() {
        previousNs = 0; intervalCount = 0; swapCount = 0; swapFailures = 0;
        long50 = 0; long100 = 0; long1000 = 0; ++segment; ++boundaries;
    }
    void setForeground(bool value) {
        if (foreground != value) { foreground = value; resetSegment(); }
    }
    void presented(uint64_t now, uint64_t epoch, const std::string& source) {
        ++frames;
        if (foreground && previousNs && epoch == generation && source == provider && now >= previousNs) {
            const uint64_t us = (now - previousNs) / 1000;
            intervals[intervalCount++ % capacity] = us;
            if (us > 50000) ++long50;
            if (us > 100000) ++long100;
            if (us > 1000000) ++long1000;
        } else if (generation && (generation != epoch || source != provider)) resetSegment();
        previousNs = foreground ? now : 0; generation = epoch; provider = source;
    }
    void swapped(uint64_t durationNs, bool success) {
        swapTimes[swapCount++ % capacity] = durationNs / 1000;
        if (!success) ++swapFailures;
    }
    static uint64_t percentile(const std::array<uint64_t, capacity>& data, uint64_t count, unsigned percent) {
        const std::size_t length = static_cast<std::size_t>(std::min<uint64_t>(count, capacity));
        if (!length) return 0;
        std::vector<uint64_t> sorted(data.begin(), data.begin() + length);
        std::sort(sorted.begin(), sorted.end());
        return sorted[(length * percent + 99) / 100 - 1];
    }
};
}
