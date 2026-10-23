#ifndef AMCL_INPUT_LAUNCH_PLAN_H
#define AMCL_INPUT_LAUNCH_PLAN_H

/**
 * JVM 前的私有输入计划解码。与 launch/ResolvedInputPlan.ets 共用固定线协议，
 * 不依赖图形选择器、JNI、窗口、设备或实际消费者，不建立另一份 InputStateCore。
 * 新参数必须完整有效；只有明确缺失的新参数才能走旧入口的一次性兼容决议。
 */
#include <array>
#include <string>
#include <vector>

namespace amcl::input {

/** 只记录已核验的启动意图；绑定计划并不代表真实 consumer 已经 Ready。 */
struct LaunchPlan {
    std::string version;
    std::string abi;
    std::string slot;
    std::string window;
    std::string binding;
    std::string policy;
};

/**
 * 校验实际 ABI 与 Java/native 槽的封闭组合。LWJGL2 的 GLFW 仅是窗口提供者，
 * L2 仍然使用自己的 Next/read/poll 出口；禁止把该组合改成 GLFW 输入消费者。
 */
inline bool ValidLaunchPlan(const LaunchPlan& plan) {
    if (plan.version != "v1") return false;
    if (plan.abi == "LWJGL2") {
        return plan.slot == "LWJGL2" && plan.window == "GLFW"
            && plan.binding == "liblwjgl_v2.so" && plan.policy == "l2-pull";
    }
    if (plan.abi == "GLFW") {
        return (plan.slot == "LWJGL3" || plan.slot == "LWJGL322") && plan.window == "GLFW"
            && plan.binding == "libglfw.so" && plan.policy == "glfw-present-2";
    }
    return plan.abi == "SDL3" && plan.slot == "LWJGL3" && plan.window == "SDL3"
        && plan.binding == "libSDL3.so" && plan.policy == "sdl-present-1";
}

/**
 * 有界解析固定顺序的六个字段。未知/重复/缺失字段及尾随分号均拒绝；完整校验后
 * 才提交 output，失败保持旧输出原样，调用方不能拿部分解析结果继续启动。
 */
inline bool ParseLaunchPlan(const std::string& wire, LaunchPlan& output, std::string& error) {
    if (wire.empty() || wire.size() > 256) { error = "input_plan_size"; return false; }
    const std::array<std::string, 6> keys = {"v=", "abi=", "slot=", "window=", "binding=", "policy="};
    std::array<std::string, 6> values;
    size_t offset = 0;
    for (size_t index = 0; index < keys.size(); ++index) {
        const size_t end = wire.find(';', offset);
        const bool final = index + 1 == keys.size();
        if ((final && end != std::string::npos) || (!final && end == std::string::npos)) {
            error = "input_plan_fields"; return false;
        }
        const std::string field = wire.substr(offset, end == std::string::npos ? end : end - offset);
        if (field.compare(0, keys[index].size(), keys[index]) != 0) {
            error = "input_plan_field_order"; return false;
        }
        values[index] = field.substr(keys[index].size());
        offset = end == std::string::npos ? wire.size() : end + 1;
    }
    const LaunchPlan candidate {values[0], values[1], values[2], values[3], values[4], values[5]};
    if (!ValidLaunchPlan(candidate)) { error = "input_plan_combination"; return false; }
    output = candidate;
    error.clear();
    return true;
}

/** 两个子契约仅做组合一致性核对；图形计划没有修改输入计划的权限。 */
inline bool MatchesRuntime(const LaunchPlan& plan, const std::string& slot, const std::string& window) {
    return ValidLaunchPlan(plan) && plan.slot == slot && plan.window == window;
}

/** 只序列化已核验的封闭字段，供JVM前冻结及启动线程回读同一输入意图。 */
inline std::string SerializeLaunchPlan(const LaunchPlan& plan) {
    return "v=" + plan.version + ";abi=" + plan.abi + ";slot=" + plan.slot
        + ";window=" + plan.window + ";binding=" + plan.binding + ";policy=" + plan.policy;
}

/**
 * 兼容尚未发送新输入参数的旧调用者，保留原槽/窗口分流。新路径禁止调用本函数
 * 修复畸形参数；完成这一迁移后启动线程只使用此处已经冻结的独立输入计划。
 */
inline bool LegacyLaunchPlan(const std::string& slot, const std::string& window,
    LaunchPlan& output, std::string& error) {
    const std::string abi = slot == "LWJGL2" ? "LWJGL2" : (window == "SDL3" ? "SDL3" : "GLFW");
    const std::string binding = abi == "LWJGL2" ? "liblwjgl_v2.so"
        : (abi == "SDL3" ? "libSDL3.so" : "libglfw.so");
    const std::string policy = abi == "LWJGL2" ? "l2-pull"
        : (abi == "SDL3" ? "sdl-present-1" : "glfw-present-2");
    return ParseLaunchPlan("v=v1;abi=" + abi + ";slot=" + slot + ";window=" + window
        + ";binding=" + binding + ";policy=" + policy, output, error);
}

/**
 * 启动入口实际使用的参数裁决：只允许一个新marker；畸形marker不得降级旧路线。
 * 解析、与共享运行库组合对账全部成功后才提交output及legacy回执，且不产生外部副作用。
 */
inline bool ResolveLaunchArguments(const std::vector<std::string>& arguments,
    const std::string& slot, const std::string& window, LaunchPlan& output,
    bool& legacy, std::string& error) {
    static constexpr char marker[] = "-Damcl.input.plan=";
    std::string wire;
    size_t markers = 0;
    for (const auto& argument : arguments) {
        if (argument.compare(0, sizeof(marker) - 1, marker) == 0) {
            wire = argument.substr(sizeof(marker) - 1);
            ++markers;
        }
    }
    if (markers > 1) { error = "duplicate_input_plan"; return false; }
    LaunchPlan candidate;
    if (!(markers == 0 ? LegacyLaunchPlan(slot, window, candidate, error)
        : ParseLaunchPlan(wire, candidate, error))) return false;
    if (!MatchesRuntime(candidate, slot, window)) { error = "input_runtime_selection_conflict"; return false; }
    output = candidate;
    legacy = markers == 0;
    error.clear();
    return true;
}

} // namespace amcl::input
#endif
