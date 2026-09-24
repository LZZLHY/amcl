// joystick_sector_test.cpp
//
// 本文件与 `entry/src/test/JoystickSector.test.ets` 是**同一张规格表的两份断言**。
// 下面 `kSpec` 里的数值必须与那个文件里的表保持同步 —— 这正是抽出扇区判定的目的：
// 同一套八向逻辑此前在 native / 手柄端 / 触控端 ArkTS 兼容路径里写了三遍，
// 谁改一份另两份不会有任何提示，表现为"同一个八向摇杆在三端手感不同"。
//
// 用**角度**驱动而不是手写 (dx, dy)：扇区边界是角度定义的，用角度生成向量再断言，
// 边界值就能精确落在 22.5° + k·45° 上，而手写坐标只能近似。
#include "joystick_sector.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>

namespace {

int g_failures = 0;

void Check(bool ok, const char* what, int line) {
    if (ok) return;
    std::fprintf(stderr, "FAIL line %d: %s\n", line, what);
    ++g_failures;
}

#define CHECK(expr) Check((expr), #expr, __LINE__)

constexpr double kPi = 3.14159265358979323846;

// 由角度（度，dy 向下为正）与半径造一个偏移量。
AmclJoystickSector SectorAtDegrees(double deg, double radius = 0.8) {
    const double rad = deg * kPi / 180.0;
    return amcl_joystick_sector(std::cos(rad) * radius, std::sin(rad) * radius,
                                0.18);
}

bool Equals(const AmclJoystickSector& got, bool w, bool a, bool s, bool d) {
    return got.w == w && got.a == a && got.s == s && got.d == d;
}

struct SpecRow {
    double deg;
    bool w, a, s, d;
    const char* name;
};

// ============ 跨语言规格表（与 JoystickSector.test.ets 同步） ============
//
// 每个扇区取三个点：下边界内侧 +0.1°、中点、上边界内侧 −0.1°。
//
// ⚠️ **刻意不取精确边界值**（不写 202.5 这种）。原因不是宽松，而是那样测的是浮点而不是
// 逻辑：本测试用 `cos/sin` 造向量、实现再用 `atan2` 反解角度，这个往返在边界上会损失
// 精度 —— 实测 202.5° 反解出 202.49999999999997，落进相邻扇区。八个边界里只有这一个
// 恰好翻车，其余七个是浮点运气。而真实摇杆永远不会产生精确的 202.5000000°，
// 所以"边界点归哪一侧"不是一条有意义的契约。
//
// 有意义的契约是两条，分别由本表和 `TestSectorBoundariesAreAdjacent` 覆盖：
//   1. 每个扇区的**内部**映射到正确的方向；
//   2. 相邻扇区在 22.5° + k·45° 附近**确实换向**（边界位置正确，误差 < 0.1°）。
constexpr SpecRow kSpec[] = {
    // [337.5, 360) ∪ [0, 22.5) → D
    {   0.0, false, false, false, true,  "right-mid"      },
    {  22.4, false, false, false, true,  "right-upper"    },
    { 337.6, false, false, false, true,  "right-lower"    },
    { 359.9, false, false, false, true,  "right-wrap"     },
    // [22.5, 67.5) → D + S
    {  22.6, false, false, true,  true,  "downRight-lower"},
    {  45.0, false, false, true,  true,  "downRight-mid"  },
    {  67.4, false, false, true,  true,  "downRight-upper"},
    // [67.5, 112.5) → S
    {  67.6, false, false, true,  false, "down-lower"     },
    {  90.0, false, false, true,  false, "down-mid"       },
    { 112.4, false, false, true,  false, "down-upper"     },
    // [112.5, 157.5) → A + S
    { 112.6, false, true,  true,  false, "downLeft-lower" },
    { 135.0, false, true,  true,  false, "downLeft-mid"   },
    { 157.4, false, true,  true,  false, "downLeft-upper" },
    // [157.5, 202.5) → A
    { 157.6, false, true,  false, false, "left-lower"     },
    { 180.0, false, true,  false, false, "left-mid"       },
    { 202.4, false, true,  false, false, "left-upper"     },
    // [202.5, 247.5) → A + W
    { 202.6, true,  true,  false, false, "upLeft-lower"   },
    { 225.0, true,  true,  false, false, "upLeft-mid"     },
    { 247.4, true,  true,  false, false, "upLeft-upper"   },
    // [247.5, 292.5) → W
    { 247.6, true,  false, false, false, "up-lower"       },
    { 270.0, true,  false, false, false, "up-mid"         },
    { 292.4, true,  false, false, false, "up-upper"       },
    // [292.5, 337.5) → D + W
    { 292.6, true,  false, false, true,  "upRight-lower"  },
    { 315.0, true,  false, false, true,  "upRight-mid"    },
    { 337.4, true,  false, false, true,  "upRight-upper"  },
};

// 边界**位置**正确性：跨过 22.5° + k·45° 前后 0.1° 必须落在不同扇区。
// 这条与 kSpec 互补 —— kSpec 保证扇区内部映射对，这条保证换向发生在该发生的地方
// （若有人把 22.5 写成 25，kSpec 仍会全过，只有这条能抓住）。
void TestSectorBoundariesAreAdjacent() {
    for (int k = 0; k < 8; ++k) {
        const double boundary = 22.5 + k * 45.0;
        const AmclJoystickSector before = SectorAtDegrees(boundary - 0.1);
        const AmclJoystickSector after = SectorAtDegrees(boundary + 0.1);
        const bool differs = before.w != after.w || before.a != after.a ||
                             before.s != after.s || before.d != after.d;
        if (!differs) {
            std::fprintf(stderr,
                         "FAIL boundary at %.1f deg did not change direction\n",
                         boundary);
            ++g_failures;
        }
    }
}

void TestSpecTable() {
    for (const SpecRow& row : kSpec) {
        const AmclJoystickSector got = SectorAtDegrees(row.deg);
        if (Equals(got, row.w, row.a, row.s, row.d)) continue;
        std::fprintf(stderr,
                     "FAIL sector %s at %.1f deg: got w=%d a=%d s=%d d=%d, "
                     "want w=%d a=%d s=%d d=%d\n",
                     row.name, row.deg, got.w, got.a, got.s, got.d,
                     row.w, row.a, row.s, row.d);
        ++g_failures;
    }
}

// 屏幕坐标系约定：dy 向下为正 ⇒ dy 为负是"上" = W。
// 这条单独测，因为它最容易被"顺手修正成数学坐标系"的改动破坏，
// 而破坏后的表现是"摇杆上下颠倒"，三端会同时颠倒（现在共用一份实现）。
void TestScreenCoordinateConvention() {
    const AmclJoystickSector up = amcl_joystick_sector(0.0, -0.8, 0.18);
    CHECK(Equals(up, true, false, false, false));
    const AmclJoystickSector down = amcl_joystick_sector(0.0, 0.8, 0.18);
    CHECK(Equals(down, false, false, true, false));
    const AmclJoystickSector left = amcl_joystick_sector(-0.8, 0.0, 0.18);
    CHECK(Equals(left, false, true, false, false));
    const AmclJoystickSector right = amcl_joystick_sector(0.8, 0.0, 0.18);
    CHECK(Equals(right, false, false, false, true));
}

// 死区：严格小于才算松开（等于死区视为已出死区）。
void TestDeadZoneBoundary() {
    CHECK(Equals(amcl_joystick_sector(0.1, 0.0, 0.18), false, false, false, false));
    // 恰好等于死区 → 已出死区，判为向右。
    CHECK(Equals(amcl_joystick_sector(0.18, 0.0, 0.18), false, false, false, true));
    CHECK(Equals(amcl_joystick_sector(0.19, 0.0, 0.18), false, false, false, true));
}

// 归中必须松开。这条抓的是一个具体陷阱：atan2(0,0) 有定义且返回 0，
// 若不单独挡住长度为 0，死区传 0 的调用方（手柄端在死区重映射之后可能传 0）
// 会在摇杆归中时被判成"一直向右"，表现为角色自己往右走。
void TestZeroLengthReleasesEvenWithZeroDeadZone() {
    CHECK(Equals(amcl_joystick_sector(0.0, 0.0, 0.0), false, false, false, false));
    CHECK(Equals(amcl_joystick_sector(0.0, 0.0, 0.18), false, false, false, false));
    // 死区为 0 且有微小位移时应当正常判向（不能被上面那条误伤）。
    CHECK(Equals(amcl_joystick_sector(1e-9, 0.0, 0.0), false, false, false, true));
}

// 非有限输入一律松开：让 NaN 决定方向的后果是某个方向键永久按住，
// 在 MC 里表现为"角色自己一直走"，比丢一次输入严重得多。
void TestNonFiniteReleases() {
    const double nan = std::nan("");
    const double inf = std::numeric_limits<double>::infinity();
    CHECK(Equals(amcl_joystick_sector(nan, 0.0, 0.18), false, false, false, false));
    CHECK(Equals(amcl_joystick_sector(0.0, nan, 0.18), false, false, false, false));
    CHECK(Equals(amcl_joystick_sector(0.5, 0.5, nan), false, false, false, false));
    CHECK(Equals(amcl_joystick_sector(inf, 0.0, 0.18), false, false, false, false));
    CHECK(Equals(amcl_joystick_sector(0.0, -inf, 0.18), false, false, false, false));
}

// 任意方向都不会同时给出相反的两个键（W+S 或 A+D）—— 那会让 MC 里的移动互相抵消，
// 是一个"看起来像卡住"的典型表现。用 720 个采样点覆盖整圈。
void TestNeverEmitsOpposingPair() {
    for (int i = 0; i < 720; ++i) {
        const double deg = i * 0.5;
        const AmclJoystickSector got = SectorAtDegrees(deg);
        Check(!(got.w && got.s), "never W+S", __LINE__);
        Check(!(got.a && got.d), "never A+D", __LINE__);
        // 出了死区必然至少有一个方向。
        Check(got.w || got.a || got.s || got.d, "out of deadzone must move",
              __LINE__);
        // 最多两个方向（八向，不存在三键同时）。
        const int count = (got.w ? 1 : 0) + (got.a ? 1 : 0) + (got.s ? 1 : 0) +
                          (got.d ? 1 : 0);
        Check(count == 1 || count == 2, "at most two directions", __LINE__);
    }
}

// 半径不影响方向（只影响是否出死区）。抓的是"不小心把长度掺进角度计算"这类改动。
void TestRadiusDoesNotAffectDirection() {
    for (int i = 0; i < 16; ++i) {
        const double deg = i * 22.5 + 5.0;
        const AmclJoystickSector small = SectorAtDegrees(deg, 0.25);
        const AmclJoystickSector large = SectorAtDegrees(deg, 4.0);
        Check(Equals(large, small.w, small.a, small.s, small.d),
              "radius must not change direction", __LINE__);
    }
}

}  // namespace

int main() {
    TestSpecTable();
    TestSectorBoundariesAreAdjacent();
    TestScreenCoordinateConvention();
    TestDeadZoneBoundary();
    TestZeroLengthReleasesEvenWithZeroDeadZone();
    TestNonFiniteReleases();
    TestNeverEmitsOpposingPair();
    TestRadiusDoesNotAffectDirection();
    if (g_failures != 0) {
        std::fprintf(stderr, "joystick_sector_test: %d failure(s)\n", g_failures);
        return EXIT_FAILURE;
    }
    std::printf("joystick_sector_test: all checks passed\n");
    return EXIT_SUCCESS;
}
