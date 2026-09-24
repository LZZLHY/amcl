#pragma once

#include <string>

namespace amcl::graphics {
/**
 * 同步启动入口的图形失败快照。只描述已发生的阶段和后续进程边界，不推断驱动根因，
 * 也不授权自动降级。人类可读细节仍由 mcGetStatus 返回，避免调用方解析中文错误文案。
 */
struct LaunchFailure {
    int returnCode = 0;
    std::string stage;
    std::string code;
    std::string profile;
    bool restartRequired = false;
    bool diagnosticInjected = false;
};

/** 仅用已确认事实决定重启边界；计划锁存、JVM 已使用或资源污染任一成立即不可原地重试。 */
inline LaunchFailure BuildLaunchFailure(int rc, const std::string& stage, const std::string& code,
                                        const std::string& requestedProfile, const std::string& activeProfile,
                                        bool planActive, bool runtimeUsed, bool tainted) {
    return {rc, stage, code, requestedProfile.empty() ? activeProfile : requestedProfile,
        planActive || runtimeUsed || tainted};
}

/** JSON 字符串编码覆盖控制字符；profile/错误码可能来自被拒绝的计划，不能直接拼接。 */
inline std::string QuoteFailureValue(const std::string& value) {
    static constexpr char hex[] = "0123456789abcdef";
    std::string result = "\"";
    for (const unsigned char c : value) {
        if (c == '"' || c == '\\') { result += '\\'; result += static_cast<char>(c); }
        else if (c < 0x20) {
            result += "\\u00";
            result += hex[c >> 4];
            result += hex[c & 15];
        } else result += static_cast<char>(c);
    }
    return result + '"';
}

/** 无失败时返回空对象。此版本只适用于同步启动返回；不冒充运行中崩溃/退出协议。 */
inline std::string SerializeLaunchFailure(const LaunchFailure& failure) {
    if (failure.returnCode >= 0 || failure.stage.empty() || failure.code.empty()) return "{}";
    return "{\"schemaVersion\":1,\"returnCode\":" + std::to_string(failure.returnCode) +
        ",\"stage\":" + QuoteFailureValue(failure.stage) + ",\"code\":" + QuoteFailureValue(failure.code) +
        ",\"profile\":" + QuoteFailureValue(failure.profile) + ",\"restartRequired\":" +
        (failure.restartRequired ? "true" : "false") + ",\"diagnosticInjected\":" +
        (failure.diagnosticInjected ? "true" : "false") + "}";
}
}
