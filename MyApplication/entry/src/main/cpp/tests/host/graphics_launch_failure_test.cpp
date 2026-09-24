#include "../../jvm/graphics_launch_failure.h"
#include <cstdlib>
#include <iostream>

/** 编译生产纯核心，穷举计划/JVM/污染状态；失败退出码不受发布优化或调试宏影响。 */
static void require(bool ok, const char* message) {
    if (!ok) { std::cerr << message << '\n'; std::exit(1); }
}

int main() {
    using namespace amcl::graphics;
    require(SerializeLaunchFailure({}) == "{}", "clean launch cannot expose stale failure");
    for (int state = 0; state < 8; ++state) {
        const auto failure = BuildLaunchFailure(-5, "admission", "probe_failed", "nativegl", "mobileglues",
            (state & 1) != 0, (state & 2) != 0, (state & 4) != 0);
        require(failure.restartRequired == (state != 0), "unsafe state must require a new process");
        require(failure.profile == "nativegl", "requested profile retains its own failure identity");
    }
    const auto inherited = BuildLaunchFailure(-7, "runtime", "runtime_used", "", "mobileglues", true, true, false);
    require(inherited.profile == "mobileglues", "runtime failure identifies the latched profile");
    const auto rejected = BuildLaunchFailure(-5, "plan", "quote\"\\\n\r\t\x01", "坏计划", "", false, false, false);
    const std::string wire = SerializeLaunchFailure(rejected);
    require(wire.find("\\u000d") != std::string::npos && wire.find("\\u0001") != std::string::npos,
        "wire escapes control characters");
    // Python 调用方对真实输出做 JSON 解码，验证编码与中文值保真，而非只比对源码字面量。
    std::cout << wire << '\n';
}
