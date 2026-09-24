/**
 * napi_jvm.cpp — JVM / GPU / 下载引擎 probe NAPI 实现
 *
 * 本文件的 8 个 NAPI 包装函数与重构前 napi_entry.cpp 中
 * 同名 static 函数逐字节等价（仅命名空间从 file-local static
 * 改为 anonymous namespace）。
 */
#include "napi_jvm.h"
#include "napi_helpers.h"

#include <cstring>
#include <cstdlib>

#include "../platform/gpu_info.h"
#include "../platform/vulkan_probe.h"
// ⚰️ 2026-08-27（§S6）：曾 #include "../platform/osmesa_probe.h"，随 zink 退役移除。
#include "../jvm/jvm_launcher.h"
#include "../jvm/jvm_common_args.h"
#include "../download/probe.h"

namespace {

// --- P1: GPU 信息 ---
napi_value GetGpuInfo(napi_env env, napi_callback_info info) {
    return amcl::napi::WrapStringResult(env, getGpuInfo());
}

// --- Vulkan 能力探针（VULKAN_ADAPTATION_PLAN.md Phase 0）---
// 只读盘点本机 Vulkan：loader 版本 / 实例扩展（VK_KHR_surface + VK_OHOS_surface）/
// 物理设备 core 版本 / 关键设备扩展。供 DevTools 展示，决定官方 Vulkan 渲染路线是否可行。
napi_value GetVulkanInfo(napi_env env, napi_callback_info info) {
    return amcl::napi::WrapStringResult(env, getVulkanInfo());
}

// --- Vulkan 能力门控 JSON（VULKAN_ADAPTATION_PLAN.md §十）---
// 返回机器可读 JSON（available/reason/deviceName/hasDynamicRendering ...），供 ArkTS
// 在用户选 MC 26.2+ 时静默调用，据此显示"Vulkan 可用 / 不可用"。
napi_value GetVulkanCapabilityJson(napi_env env, napi_callback_info info) {
    return amcl::napi::WrapStringResult(env, getVulkanCapabilityJson());
}

napi_value GetGraphicsCapabilityJson(napi_env env, napi_callback_info info) {
    size_t count = 4;
    napi_value values[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &count, values, nullptr, nullptr);
    char profile[64] = {};
    char requirement[96] = {};
    char provider[32] = {};
    size_t length = 0;
    bool availabilityOnly = false;
    if (count >= 3) {
        napi_get_value_string_utf8(env, values[0], profile, sizeof(profile), &length);
        napi_get_value_string_utf8(env, values[1], requirement, sizeof(requirement), &length);
        napi_get_value_string_utf8(env, values[2], provider, sizeof(provider), &length);
    }
    if (count >= 4) napi_get_value_bool(env, values[3], &availabilityOnly);
    return amcl::napi::WrapStringResult(env, getGraphicsCapabilityJson(profile, requirement, provider, availabilityOnly));
}

// --- Vulkan 实战自检（VULKAN_ADAPTATION_PLAN.md Phase B · 端到端呈现链）---
// 真的建 instance→device→OHOS surface→swapchain→clear→present 跑一遍，逐步报告卡在哪。
// 可选参数 nativeWindowPtr（XComponent 的 OHNativeWindow 数值字符串）；缺省回退环境变量。
#ifdef MC_OHOS_BUILD_TESTS
napi_value RunVulkanSelfTest(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    unsigned long long nativeWindowPtr = 0;
    if (argc >= 1 && argv[0]) {
        // ArkTS 侧用字符串传 64-bit 指针（number 精度不足以承载完整指针值）。
        char buf[32] = {0};
        size_t len = 0;
        napi_valuetype vt = napi_undefined;
        napi_typeof(env, argv[0], &vt);
        if (vt == napi_string &&
            napi_get_value_string_utf8(env, argv[0], buf, sizeof(buf), &len) == napi_ok && len > 0) {
            nativeWindowPtr = std::strtoull(buf, nullptr, 10);
        }
    }
    return amcl::napi::WrapStringResult(env, runVulkanSelfTest(nativeWindowPtr));
}
#endif

// ⚰️ 2026-08-27（渲染后端治理 §S6）：这里曾有 `RunOSMesaSelfTest`
//   （NAPI 导出名 `runOSMesaSelfTest`，参数 logDir + driver，dlopen libOSMesa 建 GL4.6 上下文）。
// 随 zink 完全退役一并移除：`platform/osmesa_probe.*` 已从 CMakeLists 摘除，
// ArkTS 侧的 `VulkanPage.runOSMesaTest` 与 `index.d.ts` 的声明同批删除。
// ⚠️ 三处必须同批 —— 只删实现会留下一个声明存在但符号缺失的 NAPI 导出。
// 索引与恢复路径：prebuilt/mesa-zink/integration-archive/README.md

// --- JVM 初始化 ---
napi_value JvmInit(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    char filesDir[512] = {0};
    char jdkVersion[32] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], filesDir, sizeof(filesDir), &len);
    if (argc >= 2) {
        napi_get_value_string_utf8(env, argv[1], jdkVersion, sizeof(jdkVersion), &len);
    }

    int rc = jvmInit(filesDir, jdkVersion[0] ? jdkVersion : nullptr);
    return amcl::napi::MakeIntResult(env, rc);
}

// --- JVM 诊断测试 ---
#ifdef MC_OHOS_BUILD_TESTS
napi_value RunJvmEmbedTest(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    char filesDir[512] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], filesDir, sizeof(filesDir), &len);

    const char* result = jvmRunFullTest(filesDir);

    napi_value resultStr;
    if (result) {
        napi_create_string_utf8(env, result, std::strlen(result), &resultStr);
    } else {
        napi_create_string_utf8(env, "❌ 测试返回空结果", NAPI_AUTO_LENGTH, &resultStr);
    }

    // 如果有回调参数，调用回调
    if (argc >= 2) {
        napi_value global;
        napi_get_global(env, &global);
        napi_value retVal;
        napi_call_function(env, global, argv[1], 1, &resultStr, &retVal);

        return amcl::napi::MakeUndefined(env);
    }

    return resultStr;
}
#endif

// --- 查询测试是否在运行 ---
#ifdef MC_OHOS_BUILD_TESTS
napi_value IsJvmTestRunning(napi_env env, napi_callback_info info) {
    return amcl::napi::MakeBoolResult(env, jvmIsTestRunning());
}
#endif

// ============================================================
//  JIT 权限检测 (同步，极快)
// ============================================================
napi_value CheckJitAvailable(napi_env env, napi_callback_info info) {
    bool available = jvmCheckJitAvailable() != 0;
    return amcl::napi::MakeBoolResult(env, available);
}

// ============================================================
//  SSOT: 暴露 amcl::getCommonJvmArgs() 给 ArkTS（LaunchProfileBuilder 去重用）
//  见 entry/src/main/cpp/jvm/jvm_common_args.{h,cpp}
// ============================================================
napi_value GetCommonJvmArgs(napi_env env, napi_callback_info /*info*/) {
    const auto& args = amcl::getCommonJvmArgs();
    napi_value result = nullptr;
    napi_create_array_with_length(env, args.size(), &result);
    for (size_t i = 0; i < args.size(); ++i) {
        napi_value s = nullptr;
        napi_create_string_utf8(env, args[i].c_str(), args[i].size(), &s);
        napi_set_element(env, result, static_cast<uint32_t>(i), s);
    }
    return result;
}

// ============================================================
//  下载引擎 probe (P1-3 Stage 1a): 验证 libcurl.so 真机加载 + 符号解析
//  完整 DownloadEngine NAPI API 在 Stage 2 补齐
// ============================================================
napi_value DownloadEngineProbe(napi_env env, napi_callback_info /*info*/) {
    return amcl::napi::WrapStringResult(env, downloadEngineProbe());
}

#ifdef MC_OHOS_BUILD_TESTS
napi_value DownloadEngineSelfTest(napi_env env, napi_callback_info /*info*/) {
    int rc = downloadEngineSelfTest();
    return amcl::napi::MakeIntResult(env, rc);
}
#endif

#define NAPI_FUNC(name, fn) \
    { name, nullptr, fn, nullptr, nullptr, nullptr, napi_default, nullptr }

constexpr napi_property_descriptor kJvmDescriptors[] = {
    NAPI_FUNC("jvmInit",                 JvmInit),
    NAPI_FUNC("getGpuInfo",              GetGpuInfo),
    NAPI_FUNC("getVulkanInfo",           GetVulkanInfo),
    NAPI_FUNC("getVulkanCapabilityJson", GetVulkanCapabilityJson),
    NAPI_FUNC("getGraphicsCapabilityJson", GetGraphicsCapabilityJson),
#ifdef MC_OHOS_BUILD_TESTS
    NAPI_FUNC("runVulkanSelfTest",       RunVulkanSelfTest),
#endif
    // ⚰️ 2026-08-27（§S6）：曾有 NAPI_FUNC("runOSMesaSelfTest", RunOSMesaSelfTest)，随 zink 退役移除。
#ifdef MC_OHOS_BUILD_TESTS
    NAPI_FUNC("runJvmEmbedTest",         RunJvmEmbedTest),
#endif
#ifdef MC_OHOS_BUILD_TESTS
    NAPI_FUNC("isJvmTestRunning",        IsJvmTestRunning),
#endif
    NAPI_FUNC("checkJitAvailable",       CheckJitAvailable),
    NAPI_FUNC("getCommonJvmArgs",        GetCommonJvmArgs),
    NAPI_FUNC("downloadEngineProbe",     DownloadEngineProbe),
#ifdef MC_OHOS_BUILD_TESTS
    NAPI_FUNC("downloadEngineSelfTest",  DownloadEngineSelfTest),
#endif
};

#undef NAPI_FUNC

} // anonymous namespace

namespace amcl::napi {

void registerJvmNapi(napi_env env, napi_value exports) {
    napi_define_properties(env, exports,
                           sizeof(kJvmDescriptors) / sizeof(kJvmDescriptors[0]),
                           kJvmDescriptors);
}

} // namespace amcl::napi
