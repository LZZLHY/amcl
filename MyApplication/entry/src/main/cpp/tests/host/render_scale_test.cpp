// render_scale_test.cpp — 渲染分辨率缩放（-Damcl.render.scale）的契约钉子
//
// 钉住四件事（契约见 platform/render_scale.h）：
//   1. 解析域 [0.5, 1.0)：越界/垃圾/NaN 一律回 1.0 且 outValid=false ——
//      这是"非法输入绝不能把 buffer 几何改成怪值"的第一道闸；
//   2. real→scaled 的取整：round + 向下偶数对齐 + 下限保护；
//   3. scale==1 恒等零开销：恒等快照下 MapX/MapY 必须原样返回；
//   4. 映射用**精确比值 scaled/real** 而非用户 scale：MapX(real)==scaled 无漂移，
//      这正是输入坐标与 SET 生效几何保持一致的依据。
// 另外钉 launcher 的 "%.4f" env 规范化 round-trip：写出去再读回来不得改变几何。

#include "render_scale.h"

#include <cmath>
#include <cstdio>
#include <iostream>

namespace {

int g_failures = 0;

void require(bool condition, const char* message) {
    if (condition) return;
    std::cerr << "render_scale_test: FAIL: " << message << '\n';
    ++g_failures;
}

bool nearlyEqual(double a, double b) { return std::fabs(a - b) < 1e-9; }

}  // namespace

int main() {
    using amcl::renderscale::MapAxis;
    using amcl::renderscale::MappingActive;
    using amcl::renderscale::MapX;
    using amcl::renderscale::MapY;
    using amcl::renderscale::ParseScale;
    using amcl::renderscale::PublishSnapshot;
    using amcl::renderscale::ResetSnapshot;
    using amcl::renderscale::ScaledDimension;

    // ── 1. ParseScale：域 [0.5, 1.0)，其余一律 1.0 + invalid ──────────────
    {
        bool valid = true;
        require(nearlyEqual(ParseScale(nullptr, &valid), 1.0) && !valid,
                "nullptr must fall back to 1.0/invalid");
        require(nearlyEqual(ParseScale("", &valid), 1.0) && !valid,
                "empty text must fall back to 1.0/invalid");

        require(nearlyEqual(ParseScale("0.5", &valid), 0.5) && valid,
                "0.5 is the inclusive lower bound");
        require(nearlyEqual(ParseScale("0.75", &valid), 0.75) && valid,
                "0.75 must parse");
        require(nearlyEqual(ParseScale("0.9999", &valid), 0.9999) && valid,
                "0.9999 is inside the domain");
        require(nearlyEqual(ParseScale("7.5e-1", &valid), 0.75) && valid,
                "strtod scientific notation stays accepted");

        require(nearlyEqual(ParseScale("1.0", &valid), 1.0) && !valid,
                "1.0 is outside the domain (exclusive upper bound)");
        require(nearlyEqual(ParseScale("1", &valid), 1.0) && !valid,
                "1 is outside the domain");
        require(nearlyEqual(ParseScale("0.4999", &valid), 1.0) && !valid,
                "below 0.5 must fall back");
        require(nearlyEqual(ParseScale("-0.75", &valid), 1.0) && !valid,
                "negative must fall back");
        require(nearlyEqual(ParseScale("0.75x", &valid), 1.0) && !valid,
                "trailing garbage must fall back");
        require(nearlyEqual(ParseScale("x0.75", &valid), 1.0) && !valid,
                "non-numeric prefix must fall back");
        require(nearlyEqual(ParseScale("nan", &valid), 1.0) && !valid,
                "NaN must fall back");
        require(nearlyEqual(ParseScale("inf", &valid), 1.0) && !valid,
                "inf must fall back");

        // outValid 可省略：解析器不得解引用空指针。
        require(nearlyEqual(ParseScale("0.75", nullptr), 0.75),
                "outValid=nullptr must be tolerated");
    }

    // ── 2. ScaledDimension：round + 向下偶数对齐 + 下限 ───────────────────
    {
        // 目标设备（Maleoon 920 平板 2800×1840）@0.75。
        require(ScaledDimension(2800, 0.75) == 2100, "2800@0.75 -> 2100");
        require(ScaledDimension(1840, 0.75) == 1380, "1840@0.75 -> 1380");

        require(ScaledDimension(2801, 0.75) == 2100,
                "2100.75 rounds to 2101 then even-aligns down to 2100");
        require(ScaledDimension(1841, 0.5) == 920,
                "920.5 rounds half-away to 921 then even-aligns down to 920");
        require(ScaledDimension(101, 0.5) == 50,
                "50.5 rounds to 51 then even-aligns down to 50");

        // 域外 scale 与非正 real：恒等（scale==1 路径零改动）。
        require(ScaledDimension(2800, 1.0) == 2800, "scale 1.0 is identity");
        require(ScaledDimension(2800, 0.4999) == 2800,
                "scale below domain is identity");
        require(ScaledDimension(0, 0.75) == 0, "zero real is identity");
        require(ScaledDimension(-100, 0.75) == -100,
                "negative real is identity");

        // 下限保护与"取整后落回 real"的边界。
        require(ScaledDimension(3, 0.5) == 2, "tiny dimensions clamp to 2");
        require(ScaledDimension(2, 0.5) == 2, "clamp result never exceeds real");
        require(ScaledDimension(2800, 0.999999) == 2800,
                "rounding may legitimately land back on real (identity)");

        // 缩放生效时结果必须是偶数。
        for (int real = 3; real <= 257; real += 2) {
            const int scaled = ScaledDimension(real, 0.75);
            require((scaled & 1) == 0, "scaled dimension must be even");
            require(scaled <= real, "scaled dimension must not exceed real");
        }
    }

    // ── 3. MapAxis：精确比值，无漂移 ───────────────────────────────────────
    {
        require(nearlyEqual(MapAxis(123.5, 2800, 2800), 123.5),
                "scaled==real is identity");
        require(nearlyEqual(MapAxis(123.5, 0, 2100), 123.5),
                "non-positive real is identity");
        require(nearlyEqual(MapAxis(123.5, 2800, 0), 123.5),
                "non-positive scaled is identity");

        require(nearlyEqual(MapAxis(2800.0, 2800, 2100), 2100.0),
                "MapAxis(real) must equal scaled exactly");
        require(nearlyEqual(MapAxis(1400.0, 2800, 2100), 1050.0),
                "midpoint maps proportionally");
        require(nearlyEqual(MapAxis(0.0, 2800, 2100), 0.0),
                "origin is a fixed point");
        require(nearlyEqual(MapAxis(1839.0, 1840, 1380), 1379.25),
                "fractional results are preserved (no premature rounding)");
    }

    // ── 4. 运行时快照：恒等零开销 + 双轴独立比值 ──────────────────────────
    {
        ResetSnapshot();
        require(!MappingActive(), "reset snapshot is inactive");
        require(nearlyEqual(MapX(123.5), 123.5) &&
                    nearlyEqual(MapY(77.25), 77.25),
                "inactive snapshot passes coordinates through");

        PublishSnapshot(2800, 1840, 2100, 1380);
        require(MappingActive(), "scaled snapshot is active");
        require(nearlyEqual(MapX(2800.0), 2100.0), "MapX(realW) == scaledW");
        require(nearlyEqual(MapY(1840.0), 1380.0), "MapY(realH) == scaledH");
        require(nearlyEqual(MapX(0.0), 0.0) && nearlyEqual(MapY(0.0), 0.0),
                "origin is preserved");
        require(nearlyEqual(MapY(920.0), 690.0), "MapY maps proportionally");

        // 有界 + 单调：菜单光标绝不能被映射出 MC 窗口。
        double previous = -1.0;
        bool boundedMonotonic = true;
        for (int x = 0; x <= 2800; x += 7) {
            const double mapped = MapX(static_cast<double>(x));
            if (mapped < previous || mapped > 2100.0) {
                boundedMonotonic = false;
                break;
            }
            previous = mapped;
        }
        require(boundedMonotonic, "MapX is monotonic and bounded by scaledW");

        // 仅单轴缩放时另一轴保持恒等（x 用 scaledW/realW，y 用 scaledH/realH）。
        PublishSnapshot(2800, 1840, 2100, 1840);
        require(MappingActive(), "single-axis scaling still activates");
        require(nearlyEqual(MapX(2800.0), 2100.0) &&
                    nearlyEqual(MapY(1839.0), 1839.0),
                "axes use independent exact ratios");

        // 恒等尺寸、非法尺寸、超 16bit 尺寸一律回恒等快照。
        PublishSnapshot(2800, 1840, 2800, 1840);
        require(!MappingActive(), "identity dimensions deactivate mapping");
        PublishSnapshot(0, 1840, 2100, 1380);
        require(!MappingActive(), "zero dimension deactivates mapping");
        PublishSnapshot(70000, 46000, 52500, 34500);
        require(!MappingActive(), "unpackable dimensions deactivate mapping");
        require(nearlyEqual(MapX(321.0), 321.0),
                "deactivated mapping passes through again");
    }

    // ── 5. launcher 的 "%.4f" env 规范化 round-trip ───────────────────────
    {
        const char* userInputs[] = {"0.5", "0.6", "0.7", "0.75", "0.8",
                                    "0.9", "0.95", "0.9999"};
        for (const char* text : userInputs) {
            bool valid = false;
            const double parsed = ParseScale(text, &valid);
            require(valid, "round-trip input must be valid");
            char normalized[16];
            std::snprintf(normalized, sizeof(normalized), "%.4f", parsed);
            bool validAgain = false;
            const double reparsed = ParseScale(normalized, &validAgain);
            require(validAgain, "normalized env text must stay valid");
            require(ScaledDimension(2800, reparsed) ==
                            ScaledDimension(2800, parsed) &&
                        ScaledDimension(1840, reparsed) ==
                            ScaledDimension(1840, parsed),
                    "env normalization must not change the effective geometry");
        }
    }

    if (g_failures != 0) {
        std::cerr << "render_scale_test: " << g_failures << " failure(s)\n";
        return 1;
    }
    std::cout << "render_scale_test: OK\n";
    return 0;
}
