// surface_republish_policy_test.cpp — platform/surface_republish_policy.h 的宿主回归（I27-04）。
//
// 钉住四类主情形：身份与几何全等（不推进代次）、真实尺寸变化、发布（缩放后）尺寸变化、
// 渲染缩放变化；外加边界：窗口指针变化、没有已发布窗口、0x0 暂停的重复回调、取整后发布尺寸
// 不变但真实尺寸变了。判定是纯 constexpr 函数，所以同时用 static_assert 在编译期钉一遍。
// 负对照：旧行为等价于“永远重新发布”。回调序列重放里，旧判据必须多推进代次，新判据只在
// 几何确实变化时推进 —— 若两者计数相同，说明测试没有覆盖到 I27-04 的那条路径。
#include "../../platform/surface_republish_policy.h"
#include "../../platform/render_scale.h"

#include <cstdio>

using amcl::ohos::SurfacePublicationGeometry;
using amcl::ohos::SurfacePublicationUnchanged;

namespace {

int failures = 0;

void check(bool value, const char* message) {
    if (!value) {
        ++failures;
        std::fprintf(stderr, "FAIL: %s\n", message);
    }
}

// 两个互不相同的假窗口身份。只比较地址，从不解引用。
int windowA = 0;
int windowB = 0;

constexpr SurfacePublicationGeometry kNull{nullptr, 0, 0, 0, 0};

// 按 xcomponent.cpp ApplyRenderScaleGeometry 的做法构造一次回调的几何：发布尺寸直接用生产的
// renderscale::ScaledDimension（四舍五入后向下偶数对齐；scale 不在 [0.5, 1.0) 时恒等）。
SurfacePublicationGeometry Geometry(const void* window, int width, int height, double scale) {
    return SurfacePublicationGeometry{window, width, height,
                                      amcl::renderscale::ScaledDimension(width, scale),
                                      amcl::renderscale::ScaledDimension(height, scale)};
}

// 回调序列重放：返回推进的代次数。policyAware=false 模拟旧行为（每次回调都重新发布）。
struct Replay {
    SurfacePublicationGeometry current{};
    int generations = 0;
    int idempotent = 0;
    void Changed(const SurfacePublicationGeometry& next, bool policyAware) {
        if (policyAware && SurfacePublicationUnchanged(current, next)) {
            ++idempotent;
            return;
        }
        current = next;
        ++generations;
    }
};

void FourPrimaryCases() {
    const SurfacePublicationGeometry current = Geometry(&windowA, 1920, 1080, 1.0);
    check(SurfacePublicationUnchanged(current, Geometry(&windowA, 1920, 1080, 1.0)),
          "identity, real size and published size equal -> unchanged");
    check(!SurfacePublicationUnchanged(current, Geometry(&windowA, 1280, 720, 1.0)),
          "real size changed -> republish");
    SurfacePublicationGeometry scaledOnly = current;
    scaledOnly.publishedWidth = 1600;
    check(!SurfacePublicationUnchanged(current, scaledOnly),
          "published (scaled) width changed with same real size -> republish");
    scaledOnly = current;
    scaledOnly.publishedHeight = 900;
    check(!SurfacePublicationUnchanged(current, scaledOnly),
          "published (scaled) height changed with same real size -> republish");
    check(!SurfacePublicationUnchanged(current, Geometry(&windowA, 1920, 1080, 0.5)),
          "render scale changed -> published geometry changed -> republish");
}

void Boundaries() {
    const SurfacePublicationGeometry current = Geometry(&windowA, 1920, 1080, 1.0);
    check(!SurfacePublicationUnchanged(current, Geometry(&windowB, 1920, 1080, 1.0)),
          "different native window with equal sizes -> republish");
    check(!SurfacePublicationUnchanged(kNull, Geometry(&windowA, 1920, 1080, 1.0)),
          "no published window -> never treated as unchanged");
    check(!SurfacePublicationUnchanged(kNull, kNull), "null current and null next -> not unchanged");
    const SurfacePublicationGeometry paused = Geometry(&windowA, 0, 0, 1.0);
    check(SurfacePublicationUnchanged(paused, Geometry(&windowA, 0, 0, 1.0)),
          "repeated 0x0 pause callback on the same window -> unchanged");
    check(!SurfacePublicationUnchanged(paused, current), "resume from 0x0 -> republish");
    // 取整边界：真实尺寸变了 1 像素而 0.5 缩放后的发布尺寸相同，映射比值已变，必须发布。
    const SurfacePublicationGeometry halfA = Geometry(&windowA, 1921, 1080, 0.5);
    const SurfacePublicationGeometry halfB = Geometry(&windowA, 1920, 1080, 0.5);
    check(halfA.publishedWidth == halfB.publishedWidth, "fixture: rounding keeps the published width");
    check(!SurfacePublicationUnchanged(halfA, halfB), "real size changed under equal published size -> republish");
    // 缩放系数变了但取整后发布尺寸完全相同：对外可见的几何没有变化，不推进代次。
    const SurfacePublicationGeometry scaleA = Geometry(&windowA, 1000, 1000, 0.5001);
    const SurfacePublicationGeometry scaleB = Geometry(&windowA, 1000, 1000, 0.5004);
    check(scaleA.publishedWidth == scaleB.publishedWidth, "fixture: nearby scales round to the same size");
    check(SurfacePublicationUnchanged(scaleA, scaleB), "scale nudge with identical published geometry -> unchanged");
}

// 编译期同样成立：判定没有隐藏状态，调用方在 gate 锁内调用也不会引入额外副作用。
constexpr int kProbe = 0;
constexpr SurfacePublicationGeometry kSame{&kProbe, 10, 20, 5, 10};
static_assert(SurfacePublicationUnchanged(kSame, kSame), "constexpr identity case");
static_assert(!SurfacePublicationUnchanged(kSame, SurfacePublicationGeometry{&kProbe, 11, 20, 5, 10}),
              "constexpr real-size case");
static_assert(!SurfacePublicationUnchanged(kSame, SurfacePublicationGeometry{&kProbe, 10, 20, 6, 10}),
              "constexpr published-size case");
static_assert(!SurfacePublicationUnchanged(kNull, kNull), "constexpr null case");

// 回调序列：create → 同尺寸 changed ×3 → 真实尺寸变化 → 同尺寸 changed → 缩放变化 → 同尺寸 changed。
void ReplayAgainstLegacy() {
    const SurfacePublicationGeometry sequence[] = {
        Geometry(&windowA, 1920, 1080, 1.0), Geometry(&windowA, 1920, 1080, 1.0),
        Geometry(&windowA, 1920, 1080, 1.0), Geometry(&windowA, 1920, 1080, 1.0),
        Geometry(&windowA, 1080, 1920, 1.0), Geometry(&windowA, 1080, 1920, 1.0),
        Geometry(&windowA, 1080, 1920, 0.5), Geometry(&windowA, 1080, 1920, 0.5)};
    Replay policy;
    Replay legacy;
    for (const SurfacePublicationGeometry& next : sequence) {
        policy.Changed(next, true);
        legacy.Changed(next, false);
    }
    check(policy.generations == 3, "policy advances only for create, resize and scale change");
    check(policy.idempotent == 5, "policy counts every same-geometry callback as idempotent");
    check(legacy.generations == 8, "negative control: legacy republish advances on every callback");
    check(legacy.generations > policy.generations, "negative control differs from the policy");
}

}  // namespace

int main() {
    FourPrimaryCases();
    Boundaries();
    ReplayAgainstLegacy();
    if (failures) {
        std::fprintf(stderr, "surface_republish_policy_test: %d failure(s)\n", failures);
        return 1;
    }
    std::printf("surface_republish_policy_test: PASS\n");
    return 0;
}
