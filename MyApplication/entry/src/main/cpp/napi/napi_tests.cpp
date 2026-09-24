/**
 * napi_tests.cpp — 验证测试 NAPI 实现
 *
 * 整个文件以 #ifdef MC_OHOS_BUILD_TESTS 包裹；非测试构建下不产生符号。
 */
#include "napi_tests.h"

#ifdef MC_OHOS_BUILD_TESTS

#include "napi_helpers.h"

#include "../tests/tests.h"
#include "../download/tests/download_tests.h"
#include <thread>
#include <unistd.h>

namespace {

// --- P0: JIT 边界测试 ---
napi_value RunJitTests(napi_env env, napi_callback_info info) {
    char path[512] = {0};
    amcl::napi::ReadStringArg(env, info, path, sizeof(path));
    return amcl::napi::WrapStringResult(env, runAllJitTests(path));
}

// --- P0: JVM 可行性探测 ---
napi_value RunJvmTests(napi_env env, napi_callback_info info) {
    char path[512] = {0};
    amcl::napi::ReadStringArg(env, info, path, sizeof(path));
    return amcl::napi::WrapStringResult(env, runJvmFeasibilityTests(path));
}

// --- P2: GLFW 兼容层测试 ---
napi_value RunGlfwTest(napi_env env, napi_callback_info info) {
    return amcl::napi::WrapStringResult(env, runGlfwCompatTest());
}

// --- P3: Desktop GL 探测 ---
napi_value RunGl4Test(napi_env env, napi_callback_info info) {
    return amcl::napi::WrapStringResult(env, runGl4Test());
}

// --- P4: MobileGlues GL→GLES 翻译层测试 ---
napi_value RunMgTest(napi_env env, napi_callback_info info) {
    return amcl::napi::WrapStringResult(env, runMobileGluesTest());
}

// --- P5: LWJGL native 库测试 ---
napi_value RunLwjglTest(napi_env env, napi_callback_info info) {
    char path[512] = {0};
    amcl::napi::ReadStringArg(env, info, path, sizeof(path));
    if (path[0]) lwjglTestSetFilesDir(path);
    return amcl::napi::WrapStringResult(env, runLwjglTest());
}

// --- Phase 4: 增量 SHA1 一致性测试（无网络，纯内存） ---
napi_value RunDownloadSha1IncrementalTests(napi_env env, napi_callback_info /*info*/) {
    return amcl::napi::WrapStringResult(env, runSha1IncrementalTests());
}

// --- Phase 3: engine.fetchToBuffer 文本下载测试（依赖网络 + caBundle） ---
napi_value RunDownloadTextFetchTests(napi_env env, napi_callback_info info) {
    char path[512] = {0};
    amcl::napi::ReadStringArg(env, info, path, sizeof(path));
    return amcl::napi::WrapStringResult(env, runDownloadTextFetchTests(path));
}

// --- Phase 8: NetSource 评分滑动窗口 + pickBestSourceWeighted（无网络，纯内存） ---
napi_value RunDownloadSourceScoringTests(napi_env env, napi_callback_info /*info*/) {
    return amcl::napi::WrapStringResult(env, runSourceScoringTests());
}

// --- Phase 7: exception + NetSource 生命周期（recordFailure/recordSuccess） ---
napi_value RunDownloadErrorAndSourceLifecycleTests(napi_env env, napi_callback_info /*info*/) {
    return amcl::napi::WrapStringResult(env, runErrorAndSourceLifecycleTests());
}

// --- 2026-05-10: amcl_log 并发 stress test（验证 LOG-P0-1 修复） ---
napi_value RunAmclLogConcurrentTest(napi_env env, napi_callback_info info) {
    char path[512] = {0};
    amcl::napi::ReadStringArg(env, info, path, sizeof(path));
    return amcl::napi::WrapStringResult(env, runAmclLogConcurrentTest(path));
}

napi_value RunInputLedgerTests(napi_env env, napi_callback_info /*info*/) {
    return amcl::napi::WrapStringResult(env, runInputLedgerTests());
}

// --- SDL3 移植 C2 关卡真机探针（见 docs/adaptation/SDL3_MIGRATION_PLAN.md §四 C2） ---
// 可选参数：libSDL3.so 的绝对路径；不传则按名字 dlopen，走应用 namespace 默认搜索路径。
napi_value RunSdl3C2Test(napi_env env, napi_callback_info info) {
    char path[512] = {0};
    amcl::napi::ReadStringArg(env, info, path, sizeof(path));
    return amcl::napi::WrapStringResult(env, runSdl3C2Test(path));
}

// --- SDL3 窗口创建探针（见 SDL3_MIGRATION_PLAN.md §C1.3；验证 patches/0001）---
// ⚠️ 必须从**带 XComponent 的页面**调用（RenderPage / VulkanPage）：它依赖宿主
// OnSurfaceCreated 设的 AMCL_NATIVE_WINDOW 等三个环境变量。DevTools 页没有 surface。
napi_value RunSdl3WindowTest(napi_env env, napi_callback_info info) {
    char path[512] = {0};
    amcl::napi::ReadStringArg(env, info, path, sizeof(path));
    return amcl::napi::WrapStringResult(env, runSdl3WindowTest(path));
}

// --- JDK IPv6 能力探针（JDK_IPV6_ADAPTATION_PLAN.md §3 P0-a）---
// 无参数、无 surface 依赖，DevTools 页直接可跑。只观测，不安装任何插桩。
napi_value RunIpv6Probe(napi_env env, napi_callback_info info) {
    (void)info;
    return amcl::napi::WrapStringResult(env, runIpv6CapabilityProbe());
}

// --- Java 侧 IPv6 诊断驱动（JDK_IPV6_ADAPTATION_PLAN.md §3 P0-b / Q5）---
// 参数：filesDir（必填）、testAddr（可选，空则用 2001:db8::1）。
// ⚠️ 同步阻塞数秒：内部 fork 子进程并 JNI_CreateJavaVM。
napi_value RunIpv6JavaProbe(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    char filesDir[512] = {0};
    char testAddr[128] = {0};
    size_t len = 0;
    if (argc >= 1) {
        napi_get_value_string_utf8(env, argv[0], filesDir, sizeof(filesDir), &len);
    }
    if (argc >= 2) {
        napi_get_value_string_utf8(env, argv[1], testAddr, sizeof(testAddr), &len);
    }
    return amcl::napi::WrapStringResult(env, runIpv6JavaProbe(filesDir, testAddr));
}

// --- MobileGL DirectVulkan 出帧探针（MOBILEGL_ADAPTATION_PLAN.md §5.2 Phase 2a）---
// ⚠️ 必须从**带 XComponent 的页面**调用（RenderPage）：依赖 OnSurfaceCreated 设的
// AMCL_NATIVE_WINDOW 等三个环境变量；且 libmobilegl.so 需先 -DeployToLibs 部署。
napi_value RunMobileglProbe(napi_env env, napi_callback_info info) {
    (void)info;
    return amcl::napi::WrapStringResult(env, runMobileglProbe());
}

napi_value RunMobileglPbufferProbe(napi_env env, napi_callback_info info) {
    (void)info;
    return amcl::napi::WrapStringResult(env, runMobileglPbufferProbe());
}

#define NAPI_FUNC(name, fn) \
    { name, nullptr, fn, nullptr, nullptr, nullptr, napi_default, nullptr }

constexpr napi_property_descriptor kTestsDescriptors[] = {
    NAPI_FUNC("runJitTests",                              RunJitTests),
    NAPI_FUNC("runJvmTests",                              RunJvmTests),
    NAPI_FUNC("runGlfwTest",                              RunGlfwTest),
    NAPI_FUNC("runGl4Test",                               RunGl4Test),
    NAPI_FUNC("runMgTest",                                RunMgTest),
    NAPI_FUNC("runLwjglTest",                             RunLwjglTest),
    NAPI_FUNC("runDownloadSha1IncrementalTests",          RunDownloadSha1IncrementalTests),
    NAPI_FUNC("runDownloadTextFetchTests",                RunDownloadTextFetchTests),
    NAPI_FUNC("runDownloadSourceScoringTests",            RunDownloadSourceScoringTests),
    NAPI_FUNC("runDownloadErrorAndSourceLifecycleTests",  RunDownloadErrorAndSourceLifecycleTests),
    NAPI_FUNC("runAmclLogConcurrentTest",                 RunAmclLogConcurrentTest),
    NAPI_FUNC("runInputLedgerTests",                      RunInputLedgerTests),
    NAPI_FUNC("runSdl3C2Test",                            RunSdl3C2Test),
    NAPI_FUNC("runSdl3WindowTest",                        RunSdl3WindowTest),
    NAPI_FUNC("runMobileglProbe",                         RunMobileglProbe),
    NAPI_FUNC("runMobileglPbufferProbe",                  RunMobileglPbufferProbe),
    NAPI_FUNC("runIpv6Probe",                             RunIpv6Probe),
    NAPI_FUNC("runIpv6JavaProbe",                         RunIpv6JavaProbe),
};

#undef NAPI_FUNC

} // anonymous namespace

namespace amcl::napi {

void registerTestsNapi(napi_env env, napi_value exports) {
    napi_define_properties(env, exports,
                           sizeof(kTestsDescriptors) / sizeof(kTestsDescriptors[0]),
                           kTestsDescriptors);
    // Test builds only. A one-shot marker permits device regression without
    // relying on unrelated launcher UI state. It runs in its own disposable
    // child and is never part of store/sideload exports or startup behaviour.
    const char* marker = "/data/storage/el2/base/haps/entry/files/mg-render-probe.once";
    if (access(marker, F_OK) == 0 && unlink(marker) == 0) {
        std::thread([] { runMobileGluesTest(); }).detach();
    }
}

} // namespace amcl::napi

#endif // MC_OHOS_BUILD_TESTS
