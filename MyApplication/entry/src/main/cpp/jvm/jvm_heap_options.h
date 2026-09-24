#pragma once

// JVM 堆参数的无副作用预检：同一实现供游戏、processor 和宿主测试使用。
// 本模块只解释最大/初始/最小堆，不选择 GC、不探测设备内存、不改写用户参数数组。
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

namespace amcl::jvm {

/** 最终堆事实及宿主需要注入的默认项；字符串由 jvmInit 的局部记录保留至 CreateJavaVM 返回。 */
struct HeapOptions {
    uint64_t maximumBytes = 0;
    uint64_t initialBytes = 0;
    uint64_t minimumBytes = 0;
    bool initialExplicit = false;
    std::string defaultMaximumOption;
    // 显式 -Xms/-XX:InitialHeapSize 已经提供初始值时为空，避免默认 Xms 改写最小堆语义。
    std::string automaticInitialOption;
};

/**
 * 解析 HotSpot 的非负堆大小语法：十进制或 0x 十六进制，末尾可有 K/M/G/T（不区分大小写）。
 * 不接受符号、空白、小数、额外尾缀或嵌入 NUL；所有乘加先检查 uint64_t/宿主 size_t 上限。
 * 返回值仅证明格式和表示范围，不承诺某个 GC、地址空间或物理内存能满足分配。
 */
inline bool ParseHeapBytes(const std::string& value, uint64_t& output) {
    if (value.empty()) return false;
    const uint64_t limit = static_cast<uint64_t>((std::numeric_limits<std::size_t>::max)());
    std::size_t index = 0;
    unsigned base = 10;
    if (value.size() >= 2 && value[0] == '0' && (value[1] == 'x' || value[1] == 'X')) {
        base = 16;
        index = 2;
    }
    const std::size_t firstDigit = index;
    uint64_t bytes = 0;
    for (; index < value.size(); ++index) {
        const unsigned char character = static_cast<unsigned char>(value[index]);
        const unsigned digit = character >= '0' && character <= '9' ? character - '0' :
            character >= 'a' && character <= 'f' ? character - 'a' + 10u :
            character >= 'A' && character <= 'F' ? character - 'A' + 10u : 16u;
        if (digit >= base) break;
        if (bytes > (limit - digit) / base) return false;
        bytes = bytes * base + digit;
    }
    if (index == firstDigit) return false;
    unsigned shifts = 0;
    if (index < value.size()) {
        if (index + 1 != value.size()) return false;
        switch (value[index]) {
            case 'k': case 'K': shifts = 1; break;
            case 'm': case 'M': shifts = 2; break;
            case 'g': case 'G': shifts = 3; break;
            case 't': case 'T': shifts = 4; break;
            default: return false;
        }
    }
    while (shifts-- != 0) {
        if (bytes > limit / 1024u) return false;
        bytes *= 1024u;
    }
    output = bytes;
    return true;
}

/**
 * 按最终 JVM 顺序评估堆设置。合法重复声明取最后值，语法错误即使稍后有覆盖也拒绝，
 * 与 HotSpot 逐项解析一致。-Xms 同时设初始/最小堆，InitialHeapSize 只设初始堆；
 * JDK8 没有 MinHeapSize flag，classicLayout 下它沿用 ignoreUnrecognized 的原行为。
 * 没有显式初始值时，从最终 Xmx 计算原有“一半、512–1024 MiB、不得超过 Xmx”策略；
 * 显式初始值（含 0 的 ergonomics 语义）不改写。initial/minimum 超过显式 maximum 的
 * 关系在支持的 HotSpot 世代中均于对齐前拒绝，故可在装载前报告；minimum 与 initial
 * 的关系却受 JDK/GC 对齐顺序影响，必须交还 JVM，不能用原始字节比较否决旧版合法输入。
 * 错误码只包含参数名/关系，不泄漏其他用户参数。失败不修改输出记录或传入参数。
 */
inline bool ResolveHeapOptions(int requestedMaximumMb, const std::vector<std::string>& arguments,
                               bool classicLayout, HeapOptions& output, std::string& error) {
    constexpr uint64_t mib = 1024u * 1024u;
    HeapOptions plan;
    const int defaultMb = requestedMaximumMb > 0 ? requestedMaximumMb : 128;
    plan.maximumBytes = static_cast<uint64_t>(defaultMb) * mib;
    plan.defaultMaximumOption = "-Xmx" + std::to_string(defaultMb) + "m";
    error.clear();
    const auto fail = [&](const std::string& reason) { error = reason; return false; };
    for (const auto& argument : arguments) {
        enum Kind { Unrelated, Maximum, InitialAndMinimum, Initial, Minimum } kind = Unrelated;
        std::size_t prefixLength = 0;
        const char* key = "";
        if (argument.compare(0, 4, "-Xmx") == 0) { kind = Maximum; prefixLength = 4; key = "Xmx"; }
        else if (argument.compare(0, 4, "-Xms") == 0) { kind = InitialAndMinimum; prefixLength = 4; key = "Xms"; }
        else if (argument.compare(0, 16, "-XX:MaxHeapSize=") == 0) { kind = Maximum; prefixLength = 16; key = "MaxHeapSize"; }
        else if (argument.compare(0, 20, "-XX:InitialHeapSize=") == 0) { kind = Initial; prefixLength = 20; key = "InitialHeapSize"; }
        else if (!classicLayout && argument.compare(0, 16, "-XX:MinHeapSize=") == 0) { kind = Minimum; prefixLength = 16; key = "MinHeapSize"; }
        if (kind == Unrelated) continue;
        uint64_t bytes = 0;
        if (!ParseHeapBytes(argument.substr(prefixLength), bytes)) return fail(std::string("heap_size_invalid:") + key);
        if (kind == Maximum) {
            if (bytes == 0) return fail(std::string("heap_size_zero:") + key);
            plan.maximumBytes = bytes;
        } else if (kind == Minimum) {
            plan.minimumBytes = bytes;
        } else {
            plan.initialBytes = bytes;
            plan.initialExplicit = true;
            if (kind == InitialAndMinimum) plan.minimumBytes = bytes;
        }
    }
    if (plan.minimumBytes > plan.maximumBytes) return fail("heap_minimum_exceeds_maximum");
    if (plan.initialExplicit) {
        if (plan.initialBytes > plan.maximumBytes) return fail("heap_initial_exceeds_maximum");
    } else {
        const uint64_t automatic = (std::min)(1024u * mib, (std::max)(512u * mib, plan.maximumBytes / 2u));
        plan.initialBytes = (std::max)(plan.minimumBytes, (std::min)(plan.maximumBytes, automatic));
        plan.automaticInitialOption = "-Xms" + std::to_string(plan.initialBytes);
    }
    output = plan;
    return true;
}
} // namespace amcl::jvm
