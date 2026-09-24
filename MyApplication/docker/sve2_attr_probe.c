// sve2_attr_probe.c —— 最小复现：区分「编译器支持 -march=armv8-a+sve2 命令行 flag」
// 与「编译器支持函数级 __attribute__((target("arch=armv8-a+sve2")))」这两件事。
//
// 为什么需要这个探针：
//   上游 SDL 的 CMakeLists.txt（约 L935-952）用 check_c_source_compiles 配
//   CMAKE_REQUIRED_FLAGS " -march=armv8-a+sve2" 来判定 COMPILER_SUPPORTS_ARMSVE2。
//   那段测试代码里**没有**函数级 target 属性，所以它只验证了前者。
//   而 src/video/arm/SDL_sve2_*.c 里的函数全部带 SDL_TARGETING("arch=armv8-a+sve2")
//   （= __attribute__((target(...)))）。若编译器不认识 target 字符串里的 "arch=" 语法，
//   属性会被静默忽略并产生 -Wignored-attributes —— 实测在 OHOS 工具链上有 210 个，
//   使 -DSDL_WERROR=ON 不可能通过。
//
// 用法（见 build_sve2_attr_probe.sh）：分别只编 PART_A / 只编 PART_B，对比警告。
//   PART_A = 上游 check_c_source_compiles 的等价物（无函数级属性）
//   PART_B = SDL_sve2_*.c 的等价物（有函数级属性）

#include <arm_sve.h>
#include <stdint.h>

#ifdef PART_A
// 与上游 check_c_source_compiles 的测试代码等价：只靠命令行 -march 提供 SVE2，
// 函数上没有任何 target 属性。
svuint32_t sve2_test_plain(svuint32_t a, svuint32_t b)
{
    return svadd_u32_z(svptrue_b32(), a, b);
}
#endif

#ifdef PART_B
// 与 SDL_sve2_blit_A.c / SDL_sve2_blit_N.c 里的函数等价：带 SDL_TARGETING。
// SDL_TARGETING(x) 展开就是 __attribute__((target(x)))，见 include/SDL3/SDL_intrin.h:385。
__attribute__((target("arch=armv8-a+sve2"))) svuint32_t sve2_test_targeted(svuint32_t a, svuint32_t b)
{
    return svadd_u32_z(svptrue_b32(), a, b);
}
#endif

#ifdef PART_C
// 对照：换成 clang 在 AArch64 上确实认识的 target 语法（特性名而非 "arch=")，
// 用来确认「不是 target 属性本身不支持，而是 arch= 这种写法不支持」。
__attribute__((target("+sve2"))) svuint32_t sve2_test_feature(svuint32_t a, svuint32_t b)
{
    return svadd_u32_z(svptrue_b32(), a, b);
}
#endif

int main(void)
{
    return 0;
}
