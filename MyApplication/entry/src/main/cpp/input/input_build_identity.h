#ifndef AMCL_INPUT_BUILD_IDENTITY_H
#define AMCL_INPUT_BUILD_IDENTITY_H

#include "adapters/glfw_input_mode.h"
#ifndef AMCL_GATE0_EVIDENCE_IDS
#define AMCL_GATE0_EVIDENCE_IDS "none"
#endif

// 两个实际DSO各自按本TU编译宏生成只读标记，不能在发布时从另一份库借用。
// HAP门禁同时检查两个导出getter与完整字串；它证明编译能力一致，不宣称设备raw可用。
namespace amcl::input {
inline constexpr const char* InputBuildIdentityV1() {
    return "AMCL_INPUT_BUILD_V1|typed="
#if AMCL_GLFW_TYPED_PHYSICAL_DEFAULT
        "1"
#else
        "0"
#endif
        "|relative="
#if AMCL_GLFW_RAW_RELATIVE_VERIFIED
        "1"
#else
        "0"
#endif
        "|absolute="
#if AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED
        "1"
#else
        "0"
#endif
        "|monotonic="
#if AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED
        "1"
#else
        "0"
#endif
        "|api26Raw="
#if AMCL_GLFW_API26_RAW_MOUSE_MOTION
        "1"
#else
        "0"
#endif
        "|evidence=" AMCL_GATE0_EVIDENCE_IDS "|END";
}
} // namespace amcl::input
#endif
