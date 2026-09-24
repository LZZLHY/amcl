#ifndef AMCL_GLFW_INPUT_MODE_H
#define AMCL_GLFW_INPUT_MODE_H

#include "../amcl_input_api.h"

#include <cstdlib>
#include <cstring>

namespace amcl::input {

#ifndef AMCL_GLFW_RAW_RELATIVE_VERIFIED
#define AMCL_GLFW_RAW_RELATIVE_VERIFIED 0
#endif

// Independent public Raw Input declaration.  The compatibility SDK/build keeps
// this at zero even when its display-scaled relative movement is usable.
#ifndef AMCL_GLFW_API26_RAW_MOUSE_MOTION
#define AMCL_GLFW_API26_RAW_MOUSE_MOTION 0
#endif

#ifndef AMCL_GLFW_TYPED_PHYSICAL_DEFAULT
#define AMCL_GLFW_TYPED_PHYSICAL_DEFAULT 0
#endif

#ifndef AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED
#define AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED 0
#endif

#ifndef AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED
#define AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED 0
#endif

// Which Gate 0 evidence authorized the assertions above. Gate0Evidence.cmake
// injects it after validating gate0-evidence.lock; "none" means nothing was
// authorized.
#ifndef AMCL_GATE0_EVIDENCE_IDS
#define AMCL_GATE0_EVIDENCE_IDS "none"
#endif

// Compile-time cross-check between "capability asserted" and "evidence recorded".
//
// Why this is needed even though CMake already gates the options: the options are
// not the only way to define these macros. `-DCMAKE_CXX_FLAGS=-DAMCL_GLFW_..._
// VERIFIED=1`, a toolchain file, or a stale cache all reach the compiler without
// passing through Gate0Evidence.cmake. Such a build would claim an unverified
// platform capability while the artifact's own evidence field still says "none" —
// silently, because nothing crashes. Binding the two together here means the only
// way to assert a capability is to also carry the evidence id that authorized it.
//
// Host tests legitimately assert capabilities without device evidence, so they
// declare an explicit fixture id instead of being exempted; that keeps the
// requirement unconditional and makes every pretend-evidence build greppable.
//
// Strength boundary — read this before relying on it: the assertion proves that
// *something* claimed authorship, not that the claim is genuine. The id is not
// cross-checked against gate0-evidence.lock at compile time (the compiler cannot
// read the manifest), so a determined bypass can define both the capability and
// an arbitrary id together. What this does buy: a single stray `-D<cap>=1` no
// longer compiles, the artifact can never assert a capability while reporting no
// author, and every forged build carries a greppable non-empty marker. The
// manifest-backed check lives in Gate0Evidence.cmake and the source gates.
constexpr bool Gate0EvidenceIdsRecorded() {
    const char* value = AMCL_GATE0_EVIDENCE_IDS;
    // Empty is rejected as well as "none". Reason: CMake deliberately injects the
    // literal "none" so that "nothing authorized" is distinguishable from "the
    // definition was forgotten"; accepting "" here would reintroduce exactly that
    // ambiguity on the C++ side and leave nothing to grep for.
    if (value[0] == '\0') return false;
    // Compare "none" without <cstring> so this stays a constant expression on
    // every toolchain.
    return !(value[0] == 'n' && value[1] == 'o' && value[2] == 'n' &&
             value[3] == 'e' && value[4] == '\0');
}

static_assert(
    (AMCL_GLFW_RAW_RELATIVE_VERIFIED == 0 &&
     AMCL_GLFW_API26_RAW_MOUSE_MOTION == 0 &&
     AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED == 0 &&
     AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED == 0) ||
        Gate0EvidenceIdsRecorded(),
    "A Gate 0 capability is asserted but AMCL_GATE0_EVIDENCE_IDS is \"none\". "
    "Enable the capability through its CMake option so gate0-evidence.lock is "
    "validated, or declare a fixture evidence id for a host-test target.");

// Bit 13 asserts only that the platform delta is usable as relative look input.
// On API 22-25 it is scaled by the system display-size ratio and therefore is
// explicitly not the GLFW Raw Input capability.  The build macro keeps its old
// name for compatibility with existing build profiles; new C++ code uses the
// relative-only constant below.

// This is deliberately a build-time assertion, not an environment switch.
// Device evidence cannot become true because a user or process mutates runtime
// configuration. The owning host publishes the assertion through its immutable
// capability table, and every producer DSO consumes that single decision.
inline constexpr bool kGlfwRelativeVerifiedByBuild =
    AMCL_GLFW_RAW_RELATIVE_VERIFIED != 0;
inline constexpr bool kGlfwRawRelativeVerifiedByBuild =
    kGlfwRelativeVerifiedByBuild;

inline constexpr bool kGlfwApi26RawMouseMotionByBuild =
    AMCL_GLFW_API26_RAW_MOUSE_MOTION != 0;
static_assert(!kGlfwApi26RawMouseMotionByBuild ||
                  kGlfwRelativeVerifiedByBuild,
              "API 26 raw mouse motion requires the relative input route");

inline bool GlfwApi26RawMouseMotionSupported(
        const AmclInputHostApiV1* api) {
    if (!api) return false;
    constexpr uint32_t required =
        AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE |
        AMCL_INPUT_CAP_VERIFIED_POINTER_RELATIVE |
        AMCL_INPUT_CAP_GLFW_API26_RAW_MOUSE_MOTION;
    return (api->capabilityBits & required) == required;
}

// Native absolute routing requires two independent Gate 0 facts: x/y are
// surface-local physical pixels, and MouseEvent.timestamp is comparable with a
// CLOCK_MONOTONIC nanosecond publication boundary. The SDK header specifies
// neither timestamp unit nor clock, so coordinate evidence alone cannot expose
// bit14. Runtime configuration cannot manufacture either fact.
inline constexpr bool kGlfwNativeMouseMonotonicNsVerifiedByBuild =
    AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED != 0;
inline constexpr bool kGlfwNativeAbsoluteVerifiedByBuild =
    AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED != 0 &&
    kGlfwNativeMouseMonotonicNsVerifiedByBuild;

// Backend selection and platform evidence are deliberately independent. This
// build default only chooses typed ownership when no startup override exists;
// it cannot manufacture either verified coordinate capability.
inline constexpr bool kGlfwTypedPhysicalDefaultByBuild =
    AMCL_GLFW_TYPED_PHYSICAL_DEFAULT != 0;

// Desktop contract: focus is a backend fact, not only a held-state reset.  The
// adapter still clears held controls before this notification, preserving the
// old-epoch release ordering required by core.
inline constexpr bool kGlfwNotifyBackendFocusChange = true;

inline constexpr const char* kGlfwInputBackendEnv =
    "AMCL_GLFW_INPUT_BACKEND";

// Startup-only parser behind one function-static latch in the owning host
// image. Core construction and function-table construction may both call the
// accessor, but the environment is parsed exactly once. Producers and a
// namespace-duplicated GLFW consumer read the immutable capability bit from the
// published table instead, preventing DOWN/UP from splitting source planes.
inline bool IsGlfwTypedInputRequested(const char* value) {
    return value != nullptr &&
           (std::strcmp(value, "typed") == 0 ||
            std::strcmp(value, "TYPED") == 0 ||
            std::strcmp(value, "1") == 0);
}

// ⚠️ **空串（`AMCL_GLFW_INPUT_BACKEND=`）的语义：显式要求 legacy，会压掉 ON 的编译默认值。**
//
// 2026-09-01 记录，**刻意不改**。三条依据：
//  1. **它已经是可观测的。** `glfw_compat.cpp` 的 `AMCL_GATE0 build …` 一行同时打
//     `typedPhysicalDefault=`（编译默认值）与 `typedRouteLatched=`（latch 的实际决定）。
//     空串会让这两个数不一致，而那正是判读"开关被谁改了"需要的信息 ——
//     符合 AGENTS.md §二.5「声明默认值与产品实际值是两个事实」，两个事实都在日志里。
//  2. **它从未实际发生过。** 仓内无任何写入点（`scripts/typed-validation-overrides.h` 明写
//     "不需要 env"），而真机上应用进程不继承 `hdc shell` 的环境变量（AGENTS.md §三.5）
//     ⇒ 只有构建/包装脚本能设它，而没有脚本设。
//  3. **改它会掩盖一个我依赖的平台行为。** host 测试用 `_putenv_s(name, "")` 关 typed，
//     而 MSVC 上那等于**删除**变量（POSIX 侧对应 `unsetenv`）⇒ 测试走的是 `nullptr` 分支，
//     不是空串分支。若把空串改成"等同于未设置"，那条测试在 MSVC 行为哪天变化时会静默
//     继续通过 —— 用一个偏好换掉一个真实的观测点，方向是错的。
//
// ⇒ 要关 typed 请显式写一个不匹配的值（`legacy` 是仓内既有约定，
// `platform_input_shadow_disabled_test` 就是这么写的），不要依赖空串。

struct GlfwInputRouteConfig {
    bool typedPhysical = false;
};

inline GlfwInputRouteConfig ResolveGlfwInputRouteConfig(
        const char* startupValue,
        bool buildDefault = kGlfwTypedPhysicalDefaultByBuild) {
    return GlfwInputRouteConfig{
        startupValue ? IsGlfwTypedInputRequested(startupValue) : buildDefault};
}

// One function-local immutable object is shared by every translation unit in
// the host image (inline-function static identity is merged by the linker).
// Both the published capability table and InputStateCore consult this exact
// object, so environment changes cannot make the producer bit and core gate
// disagree within an owning DSO.
inline const GlfwInputRouteConfig& LatchedGlfwInputRouteConfig() {
    static const GlfwInputRouteConfig config = []() {
#ifdef _WIN32
        char* value = nullptr;
        size_t length = 0u;
        if (_dupenv_s(&value, &length, kGlfwInputBackendEnv) != 0 || !value) {
            return ResolveGlfwInputRouteConfig(nullptr);
        }
        const GlfwInputRouteConfig resolved =
            ResolveGlfwInputRouteConfig(value);
        std::free(value);
        return resolved;
#else
        return ResolveGlfwInputRouteConfig(
            std::getenv(kGlfwInputBackendEnv));
#endif
    }();
    return config;
}

}  // namespace amcl::input

#endif
