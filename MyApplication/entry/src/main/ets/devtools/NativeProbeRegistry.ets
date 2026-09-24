/**
 * NativeProbeRegistry.ets — native 探针注册表的**绑定层**（批次 D4）
 *
 * 分工（与 D8 的 ProductIdentity 同形）：
 *   - `ProbeRegistryModel.ets`：形状、声明、校验、纯分派 —— 不碰 NAPI，可单独喂样本；
 *   - 本文件：唯一 import `libentry.so` 的地方，只做"哪个 id 绑哪个 NAPI 函数"。
 *
 * ⭐ 本表**大于** DevTools 页面的工具列表（契约 §3.10）：`hasUiEntry: false` 的那批
 * 今天没有任何界面入口，但 NAPI 上就有。把它们一并登记，自动化因此能覆盖
 * UI 覆盖不到的部分，而不需要先给它们做界面。
 *
 * ⚠️ **零 `DiagnosticPolicy` 引用**（契约 §7.5 第 12 条）：本表要能被未来的 L1a 能力门面
 * 直接消费，而 L1a 是产品中立的。"这个产品准不准跑探针"是**调用方**的门控，不是本表的事。
 * 这条也让本批的依赖闭包保持干净（契约 §10.5）——
 * 一旦这里 import 了 `DiagnosticPolicy`，整张表就会跟着那条未合并的方向一起卡住。
 *
 * ⚠️ 本表**不含**下列 DevTools 条目，它们不是"一次 NAPI 调用"：
 *   - `fs` / `storage` / `phoneStorage`：涉及 picker 与多步页面流程（契约 §3.9 的边界）；
 *   - `mobileglOverride`：写偏好的**开关**，不是探针（它 mutating，语义上属命令）；
 *   - `download`：页面自带的端到端 smoke，走 DownloadManager 而非单条 NAPI；
 *   - `gles` / `vulkan` / `inputProbe`：导航到独立页面。
 * 把它们塞进"探针注册表"会让这张表不再是同一类东西。
 *
 * ⚠️ **一处显式缺口**（写下来，避免下一轮把它当"忘了"）：契约 §3.10 列的
 * `runDownloadTextFetchTests(caBundlePath)` 需要一个 CA bundle 路径 ——
 * 那个值由下载引擎的初始化链持有，不是 `filesDir` 的函数。等 L1a 有了统一的
 * 参数编排面再登记它；**现在硬塞一个猜出来的路径会让它静默测错东西**。
 */

import testNapi from 'libentry.so';
import { NativeProbeDef, ProbeShape } from './ProbeRegistryModel';

/**
 * 全部可寻址的 native 探针。
 *
 * 每条的 `shape` 必须与它提供的运行体一致 —— 由 `validateProbeRegistry` 机械保证，
 * 单测里对**真实这张表**跑一遍（不是对复制品）。
 */
export function nativeProbeRegistry(): NativeProbeDef[] {
  return [
    // ── 有 UI 入口的（DevToolsPage 的按钮走同一条实现，契约 §1.1）
    {
      id: 'jit', title: 'JIT / mmap', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: true, needsFilesDir: true,
      runSyncText: (filesDir: string) => testNapi.runJitTests(filesDir),
    },
    {
      id: 'jvm', title: 'JVM 可行性', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: true, needsFilesDir: true,
      runSyncText: (filesDir: string) => testNapi.runJvmTests(filesDir),
    },
    {
      id: 'jvmEmbed', title: 'JVM 嵌入', shape: ProbeShape.CALLBACK_TEXT,
      hasUiEntry: true, needsFilesDir: true,
      runCallbackText: (filesDir: string, done: (text: string) => void) =>
        testNapi.runJvmEmbedTest(filesDir, done),
    },
    {
      id: 'glfw', title: 'GLFW', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: true, needsFilesDir: false,
      runSyncText: (_filesDir: string) => testNapi.runGlfwTest(),
    },
    {
      id: 'gl4', title: 'OpenGL 4.x', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: true, needsFilesDir: false,
      runSyncText: (_filesDir: string) => testNapi.runGl4Test(),
    },
    {
      id: 'mg', title: 'MobileGlues', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: true, needsFilesDir: false,
      runSyncText: (_filesDir: string) => testNapi.runMgTest(),
    },
    {
      id: 'lwjgl', title: 'LWJGL', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: true, needsFilesDir: true,
      runSyncText: (filesDir: string) => testNapi.runLwjglTest(filesDir),
    },
    {
      // 传空串 → native 侧按名字 dlopen("libSDL3.so")，走应用 namespace 默认搜索路径。
      id: 'sdl3c2', title: 'SDL3 C2 关卡', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: true, needsFilesDir: false,
      runSyncText: (_filesDir: string) => testNapi.runSdl3C2Test(''),
    },
    {
      id: 'ipv6', title: 'IPv6 能力探针', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: true, needsFilesDir: false,
      runSyncText: (_filesDir: string) => testNapi.runIpv6Probe(),
    },
    {
      // 传空串 → native 侧用默认地址 2001:db8::1（RFC 3849 文档前缀，不可路由）。
      id: 'ipv6java', title: 'IPv6 · Java 侧', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: true, needsFilesDir: true,
      runSyncText: (filesDir: string) => testNapi.runIpv6JavaProbe(filesDir, ''),
    },

    // ── 无 UI 入口（契约 §3.10）。今天只有自动化能到达它们。
    {
      id: 'sdl3Window', title: 'SDL3 窗口自检', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: false, needsFilesDir: false,
      runSyncText: (_filesDir: string) => testNapi.runSdl3WindowTest(''),
    },
    {
      id: 'mobileglProbe', title: 'MobileGL 探针', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: false, needsFilesDir: false,
      runSyncText: (_filesDir: string) => testNapi.runMobileglProbe(),
    },
    {
      id: 'mobileglPbuffer', title: 'MobileGL pbuffer 探针', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: false, needsFilesDir: false,
      runSyncText: (_filesDir: string) => testNapi.runMobileglPbufferProbe(),
    },
    {
      id: 'vulkanSelfTest', title: 'Vulkan 自检', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: false, needsFilesDir: false,
      runSyncText: (_filesDir: string) => testNapi.runVulkanSelfTest(''),
    },
    {
      id: 'vulkanCapability', title: 'Vulkan 能力', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: false, needsFilesDir: false,
      runSyncText: (_filesDir: string) => testNapi.getVulkanCapabilityJson(),
    },
    {
      id: 'downloadSha1', title: '增量 sha1', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: false, needsFilesDir: false,
      runSyncText: (_filesDir: string) => testNapi.runDownloadSha1IncrementalTests(),
    },
    {
      id: 'downloadSourceScoring', title: '下载源打分', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: false, needsFilesDir: false,
      runSyncText: (_filesDir: string) => testNapi.runDownloadSourceScoringTests(),
    },
    {
      id: 'downloadErrorLifecycle', title: '下载错误与源生命周期', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: false, needsFilesDir: false,
      runSyncText: (_filesDir: string) => testNapi.runDownloadErrorAndSourceLifecycleTests(),
    },
    {
      id: 'downloadEngineProbe', title: 'libcurl 版本与 feature', shape: ProbeShape.SYNC_TEXT,
      hasUiEntry: false, needsFilesDir: false,
      runSyncText: (_filesDir: string) => testNapi.downloadEngineProbe(),
    },
    {
      // ⚠️ 返回码而不是文本。刻意**不**把它裹成 `() => string`：
      // 那样 `0` 与字符串 `"0"` 的区别就没了，而调用方要判的正是"是不是 0"。
      id: 'downloadEngineSelfTest', title: '下载引擎链路自检', shape: ProbeShape.SYNC_CODE,
      hasUiEntry: false, needsFilesDir: false,
      runSyncCode: () => testNapi.downloadEngineSelfTest(),
    },
    {
      // ⚠️ 返回结构化对象的 Promise。同样不裹成文本。
      id: 'nativeGlCapability', title: '原生 GL 能力', shape: ProbeShape.ASYNC_JSON,
      hasUiEntry: false, needsFilesDir: false,
      runAsyncJson: () => testNapi.getNativeGlCapability() as Promise<object>,
    },
  ];
}
