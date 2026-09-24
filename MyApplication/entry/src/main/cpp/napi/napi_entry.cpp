/**
 * napi_entry.cpp — NAPI 模块入口 / Init() 调度器
 *
 * 联调以下各模块的 register* 函数完成 ArkTS 导出：
 *   § napi_jvm.cpp     — JVM / GPU / 下载引擎 probe
 *   § napi_mc.cpp      — Minecraft 启动器
 *   § napi_log.cpp     — AMCL 持久化日志
 *   § napi_input.cpp   — 输入事件 / 控件区域 / XComponent 尺寸
 *   § napi_forge.cpp   — Forge 安装器（fork+JVM 异步）
 *   § napi_tests.cpp   — #ifdef MC_OHOS_BUILD_TESTS 验证测试
 *
 * 重构历史：docs/guides/napi-layer-refactor-plan.md
 */

#include <napi/native_api.h>
#include <hilog/log.h>
#include <cstdlib>
#include <cstdio>
#include <cstdint>

#include "../platform/xcomponent.h"      // RegisterXComponent
#include "../platform/mg_config.h"       // prepareMobileGluesRuntime
#include "../download/probe.h"           // downloadEngineProbe (启动 banner)
#include "../download/download_napi.h"   // download::registerDownloadNapi
#include "../jvm/elf_loader.h"           // elf_dladdr / elf_sym_global（栈采样器钩子）
#include "../jvm/jvm_launcher.h"         // jvmGetJavaVM（栈采样器钩子）
#include "../utils/stack_sampler.h"      // glfwOHOS_samplerSetJvmHooks

#include "napi_jvm.h"
#include "napi_mc.h"
#include "napi_desktop.h"
#include "napi_log.h"
#include "napi_input.h"
#include "napi_forge.h"
#include "napi_tests.h"

#undef LOG_TAG
#define LOG_TAG "NAPI_ENTRY"

static napi_value GetDiagnosticCapabilities(napi_env env, napi_callback_info) {
    napi_value result = nullptr;
    napi_create_uint32(env, AMCL_DIAGNOSTICS_MASK, &result);
    return result;
}

// ============================================================
//  模块初始化 — Init() 调度器
//
//  【ORDERING CONTRACT — 调整顺序前请读 docs/guides/napi-layer-refactor-plan.md §2.R-1】
//    1. 非正式 desktop 产品在 LWJGL 加载前完成 prepareMobileGluesRuntime()
//    2. § napi_*.cpp register* 在中间注册，顺序本身不敏感
//    3. RegisterXComponent() 必须在所有 NAPI 后
//    4. download::registerDownloadNapi() 之后才能 downloadEngineProbe()
// ============================================================

static napi_value Init(napi_env env, napi_value exports) {
    // Read-only build identity. No runtime interface can enable diagnostics.
    napi_property_descriptor diagnostics = { "getDiagnosticCapabilities", nullptr,
        GetDiagnosticCapabilities, nullptr, nullptr, nullptr, napi_default, nullptr };
    napi_define_properties(env, exports, 1, &diagnostics);
    OH_LOG_INFO(LOG_APP, "%{public}s", AMCL_DIAGNOSTICS_MARKER);
    // Formal desktop has no MobileGlues configuration or migration side effects.
#if !AMCL_NATIVE_DESKTOP_ONLY
    prepareMobileGluesRuntime();
#endif

#ifdef AMCL_STACK_SAMPLER
    // 给渲染线程栈采样器（libglfw.so 内）注入 libentry 独占可见的函数指针。
    // OHOS 命名空间隔离下 libglfw 可能存在两份 copy（libentry 依赖 / LWJGL dlopen），
    // 各自 globals 不共享：① 直接调用 glfwOHOS_samplerSetJvmHooks 命中 libentry 依赖的那份；
    // ② 同时把指针写进进程级共享的环境变量（单一 libc），让另一份 copy 也能 getenv 取到。
    // 仅诊断构建（-DAMCL_STACK_SAMPLER=ON）启用。
    glfwOHOS_samplerSetJvmHooks(
        reinterpret_cast<void*>(&elf_dladdr),
        reinterpret_cast<void*>(&elf_sym_global),
        reinterpret_cast<void*>(&jvmGetJavaVM));
    {
        char hooksBuf[160];
        snprintf(hooksBuf, sizeof(hooksBuf), "%lx:%lx:%lx",
                 (unsigned long)reinterpret_cast<uintptr_t>(&elf_dladdr),
                 (unsigned long)reinterpret_cast<uintptr_t>(&elf_sym_global),
                 (unsigned long)reinterpret_cast<uintptr_t>(&jvmGetJavaVM));
        setenv("AMCL_SMPL_HOOKS", hooksBuf, 1);
        OH_LOG_INFO(LOG_APP, "sampler hooks env set: %{public}s", hooksBuf);
    }
#endif

    // § napi_jvm.cpp：jvmInit / getGpuInfo / runJvmEmbedTest / isJvmTestRunning
    //                  / checkJitAvailable / getCommonJvmArgs
    //                  / downloadEngineProbe / downloadEngineSelfTest
    amcl::napi::registerJvmNapi(env, exports);

    // § napi_mc.cpp：mcLaunchWithProfile / mcLaunchWithProfileV2
    //                 / mcGetStatus / mcCheckFiles / mcIsRunning / mcForceExit / mcReadLog
    //                 / getDeviceMemoryMB / getRecommendedXmx
    amcl::napi::registerMcNapi(env, exports);
    amcl::napi::registerDesktopNapi(env, exports);

    // § napi_log.cpp：amclLogInit / amclLogShutdown / amclLogRead / amclLogFlush
    //                  / amclLogGetPath / amclLogWrite
    amcl::napi::registerLogNapi(env, exports);

    // § napi_input.cpp：输入相关的全部入口（当前 51 项）。
    // ⚠️ 这里曾抄一份方法名清单，其中 `registerButton` / `registerJoystick` 已在 §38.3
    // 整体删除。清单式注释需要手工同步，而它注定漂移 —— `napi_input.h` 文件头那份就漂到了
    // 15/55。权威只有两处：`napi_input.cpp` 末尾的 `kInputDescriptors`（注册真相）与
    // `cpp/types/libentry/index.d.ts`（ArkTS 类型契约）。不要在这里重建第三份。
    amcl::napi::registerInputNapi(env, exports);

    // § napi_forge.cpp：runJavaProcessor（fork+JVM 跑单个 processor，返回 Promise）
    amcl::napi::registerForgeNapi(env, exports);

#ifdef MC_OHOS_BUILD_TESTS
    // § napi_tests.cpp：runJitTests / runJvmTests / runGlfwTest / runGl4Test / runMgTest
    //                    / runLwjglTest / runDownloadSha1IncrementalTests
    //                    / runDownloadTextFetchTests / runDownloadSourceScoringTests
    //                    / runDownloadErrorAndSourceLifecycleTests
    amcl::napi::registerTestsNapi(env, exports);
#endif

    RegisterXComponent(env, exports);

    // P1-3 Stage 2: 注册下载引擎 NAPI 方法
    //   downloadCreateTask / downloadStart / downloadCancel
    //   downloadOnProgress / downloadOnComplete / downloadListActive / downloadShutdown
    download::registerDownloadNapi(env, exports);

    // P1-3 Stage 1a: 启动时打一次 libcurl banner 到 hilog，让真机启动日志直接
    // 看到"libcurl 已被 ELF loader 成功加载且符号 resolve 正常"。只读
    // curl_version_info() 的静态表，无全局副作用，开销 < 1ms。
    // selfTest（会触发 curl_global_init）不自动调用，仅通过 NAPI 按需触发。
    (void)downloadEngineProbe();

    OH_LOG_INFO(LOG_APP, "MC-OHOS NAPI module initialized");
    return exports;
}

NAPI_MODULE(entry, Init)
