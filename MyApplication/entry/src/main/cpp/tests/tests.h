// tests.h — 所有验证测试模块的统一头文件
#ifndef MC_OHOS_TESTS_H
#define MC_OHOS_TESTS_H

#ifdef __cplusplus
extern "C" {
#endif

// P0-Step1: JIT/mmap 边界测试
const char* runAllJitTests(const char* sandboxPath);

// P0-Step2A: JVM 嵌入可行性探测
const char* runJvmFeasibilityTests(const char* appDir);

// P2: GLFW 兼容层验证
const char* runGlfwCompatTest();

// P3: Desktop GL 探测
const char* runGl4Test();

// P4: MobileGlues GL→GLES 翻译层验证
const char* runMobileGluesTest();

// P5: LWJGL native 库验证
void lwjglTestSetFilesDir(const char* filesDir);
const char* runLwjglTest();

// 2026-05-10: amcl_log 多生产者并发 stress test（验证 LOG-P0-1 修复）
const char* runAmclLogConcurrentTest(const char* logDir);

// InputLedger owner/refcount and re-entry tests.
const char* runInputLedgerTests();

// SDL3 移植 C2 关卡真机探针：验证 SDL_GL_GetProcAddress 与 dlsym(libglfw.so) 同址。
// 必须跑在应用进程里——HarmonyOS 的 linker namespace 是按应用配置的，hdc shell 域
// 测不出 MC 的实际行为（且 shell 域被 SELinux 禁止执行推送的 ELF）。
// 见 docs/adaptation/SDL3_MIGRATION_PLAN.md §四 C2。
// sdl3PathHint 可传空字符串，则按名字 dlopen("libSDL3.so")。
const char* runSdl3C2Test(const char* sdl3PathHint);

// SDL3 窗口创建真机探针：验证 prebuilt/sdl3/patches/0001（宿主注入 native window）。
// 走通 SDL_CreateWindow → SDL_GL_CreateContext → SDL_GL_MakeCurrent → glGetString。
// ⚠️ 必须跑在**有活跃 XComponent surface** 的页面上（RenderPage / VulkanPage），
// 因为它依赖 platform/xcomponent.cpp 的 OnSurfaceCreated 设的
// AMCL_NATIVE_WINDOW / AMCL_WINDOW_WIDTH / AMCL_WINDOW_HEIGHT；DevTools 页没有 surface。
// 见 docs/adaptation/SDL3_MIGRATION_PLAN.md §C1.3。
const char* runSdl3WindowTest(const char* sdl3PathHint);

// JDK IPv6 能力探针（docs/adaptation/JDK_IPV6_ADAPTATION_PLAN.md §3 P0-a）。
// 逐条复现 libnet `IPv6_supported()` 的判据（JDK 17 四条、21/25 三条），把
// "JDK 会不会把 IPv6 判成不可用"从推断变成一个可以数的值。
// ⚠️ 必须在应用进程内跑：hdc shell 域（u:r:sh:s0）与应用域是两套 SELinux 上下文，
//   而这里要测的恰恰是沙箱能不能读 /proc/net/if_inet6。
// 只观测：不安装插桩、不改 JDK、不写任何文件。DevTools 页即可触发（不需要 surface）。
const char* runIpv6CapabilityProbe(void);

// Java 侧 IPv6 诊断驱动（JDK_IPV6_ADAPTATION_PLAN.md §3 P0-b / Q5）。
// fork 子进程建 JVM 跑 com.amcl.launcher.Ipv6Diagnostics，把输出取回来。
// 回答 native 探针答不了的那一半：Java 层观测到的通道地址族、连 IPv6 字面量的
// **第一条**异常原文、NetworkInterface 的 IPv6 条数。
// ⚠️ 需要 filesDir/amcl-launcher.jar（装完新版后先启动过一次游戏才有）。
// ⚠️ 同步阻塞数秒（fork + JNI_CreateJavaVM）。只观测，不改 JDK。
// testAddr 传空则用 2001:db8::1（RFC 3849 文档前缀，永不可路由）。
const char* runIpv6JavaProbe(const char* filesDir, const char* testAddr);

// MobileGL DirectVulkan 端到端出帧探针（MOBILEGL_ADAPTATION_PLAN.md §5.2 Phase 2a 收口判据）：
// dlopen libmobilegl.so → 经其 EGL 前端建面出帧（vkQueuePresentKHR）→ 重建一轮 → Terminate。
// ⚠️ 同样必须跑在有活跃 XComponent surface 的页面（RenderPage）。
// ⚠️ libmobilegl.so 不在发布 HAP：先 build-mobilegl.ps1 -DeployToLibs 再装机（D3 未决）。
const char* runMobileglProbe(void);
const char* runMobileglPbufferProbe(void);

#ifdef __cplusplus
}
#endif

#endif // MC_OHOS_TESTS_H
