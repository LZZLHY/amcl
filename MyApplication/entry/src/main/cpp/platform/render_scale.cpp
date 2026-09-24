// render_scale.cpp — 渲染分辨率缩放的纯函数与运行时快照（契约见 render_scale.h）
//
// 本 TU 不含任何 OHOS 依赖：tests/host/render_scale_test.cpp 直接编译它。
// SET_BUFFER_GEOMETRY 的调用与快照发布时机在 xcomponent.cpp。

#include "render_scale.h"

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdlib>

namespace amcl::renderscale {
namespace {

// [63:48 realW][47:32 realH][31:16 scaledW][15:0 scaledH]；0 = 恒等/未发布。
std::atomic<uint64_t> g_snapshot{0};

constexpr int kMaxPackableDimension = 0xFFFF;

bool DimensionPackable(int v) { return v > 0 && v <= kMaxPackableDimension; }

}  // namespace

double ParseScale(const char* text, bool* outValid) {
    if (outValid != nullptr) *outValid = false;
    if (text == nullptr || text[0] == '\0') return 1.0;

    char* end = nullptr;
    const double parsed = std::strtod(text, &end);
    // 整串消费：尾随垃圾（"0.75x"）与前导空白以外的任何残留都按无效处理，
    // 避免"半个数字"被静默接受成一个看似合理的比例。
    if (end == text || *end != '\0') return 1.0;
    if (!std::isfinite(parsed)) return 1.0;
    if (parsed < kMinScale || parsed >= 1.0) return 1.0;

    if (outValid != nullptr) *outValid = true;
    return parsed;
}

int ScaledDimension(int real, double scale) {
    if (real <= 0) return real;
    if (!(scale >= kMinScale && scale < 1.0)) return real;

    long scaled = std::lround(static_cast<double>(real) * scale);
    scaled &= ~1L;  // 向下偶数对齐
    if (scaled < 2) scaled = 2;
    if (scaled > real) scaled = real;  // 防御：scale<1 时数学上不可达
    return static_cast<int>(scaled);
}

double MapAxis(double value, int real, int scaled) {
    if (real <= 0 || scaled <= 0 || scaled == real) return value;
    // 精确比值 scaled/real（而非用户输入的 scale）：SET 生效的几何经过取整，
    // 只有这个比值能保证 MapAxis(real) == scaled 无漂移。
    return value * (static_cast<double>(scaled) / static_cast<double>(real));
}

void PublishSnapshot(int realWidth, int realHeight, int scaledWidth,
                     int scaledHeight) {
    uint64_t packed = 0;
    const bool identity =
        (scaledWidth == realWidth && scaledHeight == realHeight);
    if (!identity && DimensionPackable(realWidth) &&
        DimensionPackable(realHeight) && DimensionPackable(scaledWidth) &&
        DimensionPackable(scaledHeight)) {
        packed = (static_cast<uint64_t>(realWidth) << 48) |
                 (static_cast<uint64_t>(realHeight) << 32) |
                 (static_cast<uint64_t>(scaledWidth) << 16) |
                 static_cast<uint64_t>(scaledHeight);
    }
    g_snapshot.store(packed, std::memory_order_release);
}

void ResetSnapshot() { g_snapshot.store(0, std::memory_order_release); }

bool MappingActive() {
    return g_snapshot.load(std::memory_order_acquire) != 0;
}

double MapX(double x) {
    const uint64_t packed = g_snapshot.load(std::memory_order_acquire);
    if (packed == 0) return x;
    const int real = static_cast<int>((packed >> 48) & 0xFFFF);
    const int scaled = static_cast<int>((packed >> 16) & 0xFFFF);
    return MapAxis(x, real, scaled);
}

double MapY(double y) {
    const uint64_t packed = g_snapshot.load(std::memory_order_acquire);
    if (packed == 0) return y;
    const int real = static_cast<int>((packed >> 32) & 0xFFFF);
    const int scaled = static_cast<int>(packed & 0xFFFF);
    return MapAxis(y, real, scaled);
}

}  // namespace amcl::renderscale
