/**
 * 执行生产输入计划解析/启动参数裁决；不启动JVM或图形，明确与真实ABI测试的边界。
 * 覆盖合法L2+GLFW、三槽四路线、畸形/重复marker和共享运行库冲突，失败必须零提交。
 */
#include "input_launch_plan.h"
#include <cstdlib>
#include <iostream>

/** 失败立即终止，不依赖release编译可能关闭的assert。 */
static void Require(bool condition, const char* message) {
    if (!condition) { std::cerr << message << '\n'; std::exit(1); }
}

int main() {
    using namespace amcl::input;
    const std::vector<std::string> wires = {
        "v=v1;abi=GLFW;slot=LWJGL3;window=GLFW;binding=libglfw.so;policy=glfw-present-2",
        "v=v1;abi=GLFW;slot=LWJGL322;window=GLFW;binding=libglfw.so;policy=glfw-present-2",
        "v=v1;abi=LWJGL2;slot=LWJGL2;window=GLFW;binding=liblwjgl_v2.so;policy=l2-pull",
        "v=v1;abi=SDL3;slot=LWJGL3;window=SDL3;binding=libSDL3.so;policy=sdl-present-1",
    };
    for (const auto& wire : wires) {
        LaunchPlan parsed; std::string error;
        Require(ParseLaunchPlan(wire, parsed, error), "合法输入计划被拒绝");
        Require(SerializeLaunchPlan(parsed) == wire, "计划往返身份变化");
        bool legacy = true; LaunchPlan prepared;
        Require(ResolveLaunchArguments({"-Damcl.input.plan=" + wire}, parsed.slot, parsed.window,
            prepared, legacy, error) && !legacy, "新计划被改走兼容路线");
        Require(prepared.abi == parsed.abi, "真实输入ABI被图形窗口覆盖");
        Require(ResolveLaunchArguments({}, parsed.slot, parsed.window, prepared, legacy, error)
            && legacy && prepared.abi == parsed.abi, "旧入口兼容行为回归");
        const std::string before = SerializeLaunchPlan(prepared);
        Require(!ResolveLaunchArguments({"-Damcl.input.plan=" + wire, "-Damcl.input.plan=" + wire},
            parsed.slot, parsed.window, prepared, legacy, error) && error == "duplicate_input_plan",
            "重复输入marker未拒绝");
        Require(SerializeLaunchPlan(prepared) == before, "失败裁决污染已冻结计划");
        Require(!ResolveLaunchArguments({"-Damcl.input.plan=" + wire}, "LWJGL2", "SDL3",
            prepared, legacy, error) && error == "input_runtime_selection_conflict", "运行库冲突未拒绝");
    }
    const std::vector<std::string> invalid = {
        "", wires[0] + ";", wires[0] + ";extra=1", "v=v2" + wires[0].substr(4),
        "v=v1;abi=GLFW;slot=LWJGL2;window=GLFW;binding=libglfw.so;policy=glfw-present-2",
        "v=v1;abi=SDL3;slot=LWJGL322;window=SDL3;binding=libSDL3.so;policy=sdl-present-1",
        "v=v1;abi=SDL3;slot=LWJGL3;window=SDL3;binding=libglfw.so;policy=sdl-present-1",
        "v=v1;abi=LWJGL2;slot=LWJGL2;window=GLFW;binding=liblwjgl_v2.so;policy=glfw-present-2",
        "v=v1;abi=GLFW;abi=GLFW;slot=LWJGL3;window=GLFW;binding=libglfw.so;policy=glfw-present-2",
        std::string(257, 'x'),
    };
    for (const auto& wire : invalid) {
        LaunchPlan old; std::string error;
        Require(ParseLaunchPlan(wires[2], old, error), "负例准备失败");
        const std::string before = SerializeLaunchPlan(old);
        bool legacy = false;
        Require(!ResolveLaunchArguments({"-Damcl.input.plan=" + wire}, "LWJGL2", "GLFW",
            old, legacy, error), "畸形新计划被当作旧入口");
        Require(SerializeLaunchPlan(old) == before && !legacy, "拒绝后状态发生变化");
    }
    std::cout << "PASS input launch plan: four routes, L2 owner, malformed/duplicate/conflicting plans, legacy boundary\n";
}
