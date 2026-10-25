# MobileGL × OHOS 适配与并入方案

> **架构定位补正（2026-09-11）**：MobileGL 是向 Minecraft 提供 OpenGL API 的独立 renderer profile；其 DirectVulkan 是底层 transport，不等同于 MC 26.2+ 原生 Vulkan。统一 profile、窗口所有权和回退规则以 [图形后端运行时契约](../guides/graphics-backend-contract.md) 为准。

> 入口补正（S20）：default 开发验证产品现提供“设置 → 游戏 → MobileGL”显式开关，
> 不再要求进入 DevTools；共享已有 profile 偏好，库缺失时禁止开启。MobileGL 与 MobileGlues
> 同属 OpenGL peer，生命周期为 optional；SDL3/版本/能力门禁仍独立生效。

> **手机闪烁补正（2026-09-06，S18/S19）**：右半屏闪烁已定位为 90° 场景横竖 extent
> 反馈振荡。修复包在手机菜单/世界复验，用户确认闪烁消失，稳态未再重建交换链。
> S17 的基础探针不能替代这种连续帧验收；新增交换链振荡日志检查，证据见 S19。

> **当前状态（2026-09-06）**：Phase 2b 的 SDL3/Minecraft 真机集成验证已落地，保持 candidate。
> Maleoon 920 上 26.3 Pre-Release 2 已进世界、退出并再次启动；Maleoon 910 上 Snapshot 10
> 已进菜单并正常退出，随后 S19 补齐手机世界与旋转闪烁修复验证；两机均通过 EGL 取址一致性、
> 双窗口和 GPU 像素跨切换保留验证。
> 完整证据与边界见施工记录 S17 及 `diagnostics/mobilegl-integration-20260906/verified-evidence.json`。
> Phase 2c（GLFW 提供者表）、Sodium/Iris、真实窗口 generation 变化和性能矩阵仍待实施/验收。
>
> 本轮顺序：A 修复探针负向判据、pin 自测和构建/HAP 产物治理；B 实测 SDL3 的
> pbuffer→window 同 context 路线及 Minecraft；C 统一 GLFW EGL/GL 提供者，并回归旧后端。
> 每步只在证据满足后记录完成，不用后续路线的预期替代验收。
>
> 旧前提修正：MC 26.3 Snapshot 9 起需要辅助 pbuffer，见 SDL3 window contract；
> 同名库在不同 linker namespace 中不保证同一实例，必须以 context/函数提供者实测；
> 把直接调用改成函数表后不可能要求整个 libglfw 位级不变，应验证默认符号归属与行为回归。
> 三臂性能比较只能形成待验证的归因假设，不能直接证明 GLES 驱动或 JVM 是唯一根因。
> 暂不升级 upstream 基线、不晋升默认后端、不对外发布；先让现有 pin 的集成可验证。

> 下一步：在独立批次完成 GLFW EGL/GL 提供者表和既有后端回归；候选库只进 default 验证包。
> 最后更新：2026-09-06（SDL3 真机接通，OHOS pbuffer、资源持久性与符号绑定修复）
> 证据：`diagnostics/mobilegl-probe-20260827/`（探针脚本 + 逐 TU 矩阵 + 四个补丁 + 工具链实测原始输出）
>
> **读序**：多后端那一层的规范在 **[guides/renderer-backend-governance.md](../guides/renderer-backend-governance.md)**，
> 本文只管 MobileGL 这一个依赖。**§4 的并入方案是对那份规范的具体化，不是另一套规则** ——
> 两处冲突时以规范为准，并把本文改掉。
>
> 关联（不在本文重复它们的内容）：
> - `guides/mobileglues-2.0-ohos-governance.md` — 现行默认后端 MobileGlues 的唯一权威来源治理文档
> - `adaptation/VULKAN_ADAPTATION_PLAN.md` — MC **官方** Vulkan（26.2+）。与本文是两条不同的路，§1.3 有对照
> - `adaptation/OLD_MC_RENDERER_PLAN.md` + `prebuilt/gl4es/README.md` — gl4es 落地记录，**引入第二个 GL 后端的成本参照**
> - `reports/2026-08-26_MG_CHUNK_BOUNDARY_STUTTER_INVESTIGATION.md` — §5.1 试点选题的来源
> - `prebuilt/mobileglues/integration-archive/README.md` — Zink「接了又退役」的墓碑

---

## 〇、结论先行

**MobileGL 不是 MobileGlues 的新版本，是同一组织（MobileGL-Dev）从零重写的下一代实现。**
两个仓库并存、都活跃。AMCL 现在用的是 MobileGlues。

Phase 0 只回答一个问题：**能不能在 HarmonyOS 上把 MobileGL 编出来。** 已实测：

| 判定项 | 结论 | 依据 |
|---|---|---|
| C++23 是否阻塞 | **不是** | `std::expected` 只有 **1 处 typedef + 5 处 return**；`print`/`flat_map`/`generator`/`mdspan`/`ranges::to`/`to_underlying`/`unreachable`/`byteswap` **全部 0 次** |
| `std::format`（真正的大头，205 次 / 24 文件） | **一个编译宏解决** | libc++ 15 的 `__format/` 实现完整存在（24 个文件），只被 `_LIBCPP_HAS_NO_INCOMPLETE_FORMAT` gate 掉；加 `-D_LIBCPP_ENABLE_EXPERIMENTAL` 后**编译与链接均实测通过** |
| 是否需要换编译器 / 自建 libc++ | **不需要** | OHOS SDK 自带 clang 15.0.4，**166 个 TU 中 165 个通过（99.4%）** |
| 源码改动量 | **43 insertions / 5 deletions / 5 files** | §3，三个补丁全部可回推上游，已验证能在原始 clone 上 `git apply --check` 干净重放 |
| 唯一剩下的失败 | **探针自身版本错位，不是兼容性问题** | `ShaderCompiler.cpp` 报 `spv::Op` 缺 `OpGraphARM`/`OpMemberDecorateIdEXT` —— 探针按 HEAD 独立取了 SPIRV-Headers，比 MobileGL vendored 的 `spirv.hpp11` 新 |

⇒ **主体工作量不在编译，在「OHOS 平台后端」+「与 libglfw 的 EGL/present 所有权划分」。**

⚠️ **本文不主张替换 MobileGlues。** 建议路径是**并存 + 一次归因实验**（§5），不是迁移。

### 0.1 三条被自己的实测推翻的判断

留在这里防止再犯。每条都曾被当作结论说出口：

1. ❌ **"MobileGL 没有 OHOS 平台分支，所以不可行"** —— 平台分支是**我们的工作项**，不是它的缺陷。
   MobileGlues / gl4es / SDL3 的 OHOS 支持全部由本项目自建，这是同一件事。
2. ❌ **"C++23 是硬墙，只能等 OpenHarmony 升 NDK"** —— 语言侧 clang 15 基本够用
   （`__cpp_concepts` / `__cpp_if_consteval` / `__cpp_multidimensional_subscript` / `__cpp_size_t_suffix`
   齐备，P0848R3 亦通过）；库侧唯一大头一个宏解锁。
3. ❌ **"给高版本引入新 GL 翻译层是在 Mojang 要删的路上投资"** —— 26.2 的 Vulkan 仍是实验性、
   OpenGL 仍默认、移除无时间表，而 **1.17 – 26.1 永远是 OpenGL-only**。GL 翻译层不是短命资产。

⇒ **判据：断言一个外部依赖"不可行"之前，先把它的墙实际量一遍。** 本轮三个否定结论有两个是错的，
纠正它们的成本是半天探针。

---

## 一、MobileGL 是什么

### 1.1 与 MobileGlues 的关系

| | MobileGlues（现行默认） | MobileGL（本文对象） |
|---|---|---|
| 仓库 | `MobileGL-Dev/MobileGlues` | `MobileGL-Dev/MobileGL`（默认分支 **dev**） |
| 定位 | "(on) Mobile, GL uses ES" —— 跑在 host GLES 3.x 之上 | 完整 desktop OpenGL 实现，状态管理层 + **多后端** |
| 架构 | GL 前端直接翻译到 GLES | `MG_State`（状态跟踪）/ `MG_Impl`（前端）/ `MG_Backend`（每后端**完全隔离**） |
| 后端 | GLES（+ 可选 ANGLE） | **DirectGLES**（代号 Espryt）与 **DirectVulkan**（代号 Magma）两个独立后端 |
| 短期目标 | MC Java 版，伪装 GL 4.0/4.6 | README 自述 4.2 Core；**代码实测 4.3 core + GLSL 4.6**（§1.4 ①） |
| 许可 | LGPL-2.1 | **LGPL-3.0-only**（逐文件 SPDX 标注，见 §6.3） |
| Release | 无（发布走 MobileGlues-release 仓） | **无 release、无预编译二进制** |
| 自述状态 | 2.0，AMCL 生产在用 | in development，部分代码不完整 |

### 1.2 工程质量信号（正面）

不是骨架项目。实测 `dev@0d2fceab`（2026-08-26）：

- **169 个 TU / 498 个源文件**；`MG_Backend/DirectVulkan/Renderer/` 下有完整的 swapchain /
  pipeline factory / program factory / VMA / buffer arena / texture·sampler·clear·renderpass manager / timer query
- **~40 个 SpirvPass**（`DemoteFloat64` / `LowerDrawParameters` / `EmulateSubgroups` / `EmulateNoPerspective` /
  `Lower1DArrayImages` / `WidenImageFormats` …）—— 走 GLSL → SPIR-V → pass → 目标，
  比 MobileGlues 的 GLSL→ES 文本转换深一层
- 测试与诊断齐：`MG_Test` / `MG_Benchmark` / `MG_IntegrationTest`（headless GPU）/
  `MG_Util/SelfTest/DriverBugProbes` + `DriverPost`（驱动缺陷探测 + 开机自检）/ `tools/trace_replay`（apitrace 回放）
- 📌 **`tools/trace_replay/fixtures/` 里有 `minecraft-26.3` 的 apitrace 采样** ⇒ 它正针对 MC 26.3 做回归，
  与 AMCL 当前最难的版本重合
- ⚠️ 纠正它 README 一处：**DiligentCore 实际未启用**（`add_subdirectory(3rdparty/DiligentCore)` 被注释掉）

### 1.3 三条路的区别（常被混为一谈）

| 路径 | 链路 | 覆盖版本 | 关键依赖 |
|---|---|---|---|
| MobileGlues / MobileGL **DirectGLES** | MC → GL → 翻译 → **Maleoon GLES 驱动** | 1.17+ | 现状 |
| MobileGL **DirectVulkan** | MC → GL → 翻译 → **Vulkan** → Maleoon | 1.17+ | Vulkan 基础能力 |
| **MC 官方 Vulkan** | MC → `libvulkan.so` → Maleoon，**零翻译层** | **仅 26.2+** | `VK_KHR_dynamic_rendering`（910 无 / 920 有）、lwjgl-shaderc/spvc native |

⭐ **MobileGL 真正的差异化价值是第二行，不是"支持高版本"**（MobileGlues 也支持且已跑通）。
第二行是本仓唯一一条**不经 Maleoon GLES 驱动**的现代管线路径 ——
而 chunk stutter 报告的怀疑对象正是它。

⭐⭐ **且第二行覆盖 Maleoon 910，官方 Vulkan 覆盖不了**（§1.4 ②）：DirectVulkan 明确以
**Vulkan 1.1 + 经典 render pass** 为可移植目标（`VkRenderPassManager.h:289` 注释原文
"Portable to Vulkan 1.1 (no dynamic_rendering / imageless FB needed)"），而 MC 官方 Vulkan
硬性要求 `VK_KHR_dynamic_rendering`（910 无 / 920 有，`VULKAN_ADAPTATION_PLAN.md` §八）。

| 路径 | MC 版本 | Maleoon 910 | Maleoon 920 |
|---|---|---|---|
| MobileGlues | ≥1.17 | ✅ | ✅ |
| **MobileGL DirectVulkan** | ≥1.17 | **✅（910 唯一的绕开 GLES 驱动路径）** | ✅ |
| MC 官方 Vulkan | 仅 26.2+ | ❌（缺 dynamic_rendering） | ✅ |

与历史 Zink 方案（同为 GL-on-Vulkan）的区别：Zink 走 OSMesa **离屏 + 回读 + blit**；
DirectVulkan 是原生 GL-on-Vulkan，**没有回读**。

### 1.4 上游源码深调（2026-08-27 晚实测，`dev@0d2fceab`）

> 这一节的每条都注了出处文件，是**读代码得到的**，不是转述 README。
> 它们改变了本方案三处判断：§3.3 选 B、§4.5.1 接缝模型、§5.1 实验设计。

**① GL 能力面是 4.3 + 全套 Sodium/Iris 热点扩展，§6.1 那条欠账正向关闭。**
两个后端都声明 `TargetGLVersion = {4,3,0}`、`TargetGLSLVersion = {4,6,0}`
（`MG_Backend/DirectVulkan/BackendObject_DirectVulkan.cpp:503`、`DirectGLES/BackendObject_DirectGLES.cpp:752`）。
DirectVulkan 声明的扩展含 `ARB_buffer_storage`（persistent mapping）/ `ARB_direct_state_access` /
`ARB_multi_draw_indirect` / `ARB_indirect_parameters` / `ARB_compute_shader` /
`ARB_shader_storage_buffer_object` / `ARB_shader_draw_parameters` / `ARB_multi_bind`
（同文件 :523-531）。测试直接引用 Sodium 的启用判据（`BackendLoaderTest.cpp:1161`），
persistent mapping 语义有专门测试（`TextureTest.cpp:2146`）。配置面有 Iris 光影包串行编译
（`AsyncOptimisticShaderStatus`）、Flywheel（`CoherentAsFlush`）、iterationRP 两个 bug 的指纹修复
pass（`Config.h`）—— **这是刻意针对 MC 生态设计的，不是碰巧覆盖**。
⇒ 残余风险从"能力面缺口"收窄为"in-development 代码的实现完整度"，那正是 Phase 4 实验回答的问题。

**② DirectVulkan 不需要 `VK_KHR_dynamic_rendering`**（见 §1.3 表）。

**③ 生命周期契约：宿主经它自带的 EGL 前端驱动它。** `Init.cpp:152-163` 注释明确：
初始化由宿主 API 层（EGL/WGL/CGL）驱动，第一个入口点懒初始化，最后一个 `eglTerminate`
确定性销毁。它从 DSO 导出**真正的 `egl*` 符号**（`MG_Impl/EGLImpl/Exporting/Definitions.cpp`），
上游自己的 DriverBench 就把整个 `libMobileGL.so` 当作"一个可 dlopen 的 EGL provider"用。
后端选择经 **`MOBILEGL_BACKEND_TYPE` 环境变量**（`DirectGLES` 默认 / `DirectVulkan`），
初始化时闭锁一次、一进程一后端（`ConfigLoader.cpp:204`）—— 与本仓"决策 latch 一次 +
env 发布"的纪律天然同构。全部配置项经 `MOBILEGL_*` env，clamp 后有日志回读。
⇒ **这决定了 §4.5.1 的接缝形状：不是发明 present 转发，是置换 EGL 提供者。**

**④ DirectGLES 自己 dlopen 宿主 EGL/GLES**（`MG_Util/BackendLoaders/OpenGL/Loader.cpp`），
不依赖进程符号空间里的 `egl*`。⇒ 旧版 §4.5 "DirectGLES 会撞上 MobileGlues 那份 EGL"的排除
理由**不成立**（一次启动只有一个提供者被路由，MobileGlues 不被路由就不初始化）。
排除 DirectGLES 出货的理由修正为**范围纪律**；它作为归因实验臂反而有独立价值（§5.1）。

其余对工程有影响的实测事实：版本号 `{26,8,0}-dev`（`Config.h:17`）；`VulkanRenderer.cpp` 的
平台分支只有 ANDROID/WIN32/METAL/XLIB 四套 ⇒ OHOS 分支（`CreateInstance` 扩展名 +
`CreateSurface` 的 `vkCreateSurfaceOHOS`）是 Phase 2 的精确工作面，本仓 `runVulkanSelfTest`
已在真机验证过同一条链（instance→device→OHOS surface→swapchain→present）；Android 的离屏
pbuffer 回退用 AImageReader，OHOS 对应物（OH_NativeImage）**第一期不做**，显式 fail-fast —— MC
主路径不建 pbuffer surface；GLX 前端内部门是 `__linux__ && !__ANDROID__` ⇒ OHOS 会命中，
需要 CMake 侧排除（§3.1）；Vulkan 是**链接期**符号（Android 分支 `target_link_libraries(... vulkan)`），
OHOS 块要同样链 sysroot 的 `libvulkan.so`。

---

## 二、Phase 0 实测数据

### 2.1 方法

`diagnostics/mobilegl-probe-20260827/probe-compile.ps1`。**刻意不用 CMake** ——
它会在 configure 期就因 `find_package(Vulkan)` / `add_subdirectory(glslang)` 等宿主侧原因失败，
而那与"MobileGL 的代码能不能被 OHOS clang 编译"是两个问题；逐 TU `-fsyntax-only` 能把后者单独隔离。

- 编译器：**OHOS SDK 自带 clang 15.0.4**（`llvm-project 39bec79f`），未引入任何外部 toolchain
- 目标：`--target=aarch64-linux-ohos --sysroot=<SDK>/sysroot -std=c++2b`
- TU 清单从 `CMakeLists.txt` 的 `SOURCE_FILES` 块**自动解析**（避免手抄漏项），
  扣除 `MG_Impl/GLXImpl/` 3 个（GLX = OpenGL on X Window System，OHOS 无 X11，**不该编而非编不过**）→ 166
- SPIRV-Tools 的构建期生成表由 `gen-spirv-tables.ps1` 复刻其 `add_custom_command` 产出

### 2.2 逐轮收敛

| 轮 | 通过 / 总数 | 头号失败原因 | 处置 |
|---|---|---|---|
| 1 | 2 / 169 (1.2%) | `X11/Xlib.h` not found（133 TU） | `Includes.h` 落进 `__linux__` 选了 XLIB → 加 `__OHOS__` 分支 |
| 2 | 2 / 169 (1.2%) | `std::basic_stringstream` 未定义模板（133 TU） | libc++ 15 的 `<iostream>` 不传递包含 `<sstream>` |
| 3 | 120 / 166 (72.3%) | SPIRV-Tools 生成表缺失（36 TU） | 探针局限，跑 `ggt.py` 生成 |
| 4 | 130 / 166 (78.3%) | P0960R3 括号初始化聚合体（10 TU） | 3 个聚合体加显式构造函数 |
| 5 | 164 / 166 (98.8%) | P1091R3 lambda 捕获结构化绑定（1 TU） | 拷成局部变量再捕获 |
| **6（终）** | **165 / 166 (99.4%)** | 探针的 SPIRV-Headers pin 错位（1 TU） | **非兼容性问题，不修** |

### 2.3 C++ 特性使用量（实测计数）

```
std::format              205 hits / 24 files   ← 唯一大头，一个宏解决
std::unexpected            5 hits /  1 file
std::expected              1 hit  /  1 file    ← MG_Util/ShaderTranspiler/Types.h:115 一处 typedef
std::stacktrace            1 hit  /  1 file    ← 已被 __cplusplus>=202302L 双重 gate，天然关闭
std::bit_cast              9 hits /  6 files   ← C++20，clang 15 有
std::popcount 等           5 hits /  4 files   ← C++20 <bit>，clang 15 有

std::print / flat_map / generator / mdspan / ranges::to / to_underlying /
unreachable / byteswap / ranges / views / jthread / stop_token / coroutine /
source_location / span / barrier / latch / atomic_ref / chrono 日历
                          全部 0 hits
```

### 2.4 clang 15 真正缺的两项

| 特性 | 标准 | clang 实现版本 | 影响 | 处置 |
|---|---|---|---|---|
| **P0960R3** 括号初始化聚合体 | **C++20** | clang 16 | 10 TU / 3 个聚合体 | `patches/0002` |
| **P1091R3** lambda 捕获结构化绑定 | **C++20** | clang 16 | 1 TU / 1 个函数 | `patches/0003` |

两者都**不是 C++23**，是 clang 15 遗留的 C++20 缺口。`__cpp_aggregate_paren_init` 在 OHOS clang 15 上
直接缺失，**可直接当门禁判据**。

---

## 三、改动清单

### 3.1 构建侧（0 行源码）

| 项 | 内容 |
|---|---|
| 编译宏 | `-D_LIBCPP_ENABLE_EXPERIMENTAL` —— 解锁 libc++ 15 被 gate 的 `<format>`。**实测编译与链接均通过**，未定义符号全部由 SDK 自带 libc++ 运行时满足（含 `std::format_error` 析构） |
| 标准 | `-std=c++2b`（clang 15 不认 `c++23` 字面量；SDK 自带 CMake 3.28.2 会把 `CMAKE_CXX_STANDARD 23` 映射成 `-std=c++2b`，不需要改） |
| CMake 平台条件 | ⚠️ 2026-08-27 实测修正（施工记录 §S11）：OHOS toolchain 设 `CMAKE_SYSTEM_NAME=OHOS` + `OHOS` 变量 ⇒ `UNIX` **不会**置位 ⇒ 造 `libEGL.so` 符号链接的 POST_BUILD（`if(UNIX AND NOT APPLE AND NOT ANDROID)`）**天然跳过**，但仍显式加 `NOT OHOS` 自文档（防上游改条件或 toolchain 改行为）。其余：排除 `MG_Impl/GLXImpl/` 三个 TU（其内部门是 `__linux__ && !__ANDROID__`，OHOS 会命中；对齐已有 CGL/WGL 条件块的做法）；OHOS 块 `target_link_libraries(... vulkan)`（Vulkan 是链接期符号，对齐 ANDROID 块；sysroot 有 `libvulkan.so`） |
| 关闭 | `MOBILEGL_BUILD_TEST` / `_BENCHMARK`（OHOS 不是 `ANDROID`，这些默认 **ON**；在 OHOS 块 force-off，对齐 ANDROID 块）；`MOBILEGL_BUILD_INTEGRATION_TEST` 默认已 OFF |
| 静态目标 | `MobileGL_s`（`if(NOT ANDROID)` 默认会建）在 OHOS **关掉**：本方案的产物是独立 DSO（§4.4），静态目标没有消费者，白白让全量编译 ×2。~~"静态目标默认就有是个有利意外"~~ 的旧判断作废 —— 那是按 MobileGlues 的 OBJECT-target 形状推的，MobileGL 不走那个形状 |

### 3.2 源码侧（43 insertions / 5 deletions / 5 files）

| 补丁 | 文件 | 内容 | 可上游性 |
|---|---|---|---|
| `0001-ohos-platform-branch-and-portable-includes` | `MobileGL/Includes.h` | ① 在 `__linux__` **之前**加 `__OHOS__` 分支选 `VK_USE_PLATFORM_OHOS`（无 `_KHR` 后缀）；② 显式 `#include <sstream>` | ① 平台新增，正是上游想要的形状；② 对传递包含的隐式依赖，**任何标准库上都该显式写**，纯 bug fix |
| `0002-clang15-aggregate-paren-init` | `MG_Util/Types.h`(`Range1D`)、`MG_State/GLState/ErrorState/Error.h`(`Error`)、`MG_Impl/GLImpl/Framebuffer/GL_Framebuffer.h`(`DefaultFramebufferInfo`) | 加显式构造函数，语义与聚合初始化一致 | 对 clang 16+ 零副作用 |
| `0003-clang15-structured-binding-lambda-capture` | `.../SpirvPasses/FlattenAtomicCounterBlockPass.cpp` | 结构化绑定拷成局部变量再进 lambda | 同上 |

⚠️ **`__OHOS__` 必须排在 `__linux__` 之前** —— OHOS clang 同时预定义两者
（实测：`__OHOS__ 1`、`__OHOS_FAMILY__ 1`、`__linux__ 1`）。这与 gl4es 补丁 0001 是同一族坑。

### 3.3 `std::expected` 的产品方案不是垫片

探针里的 `shim-expected.h` 往 `namespace std` 里加东西，**是 UB，不可出货**。二选一：

- **A**：vendored `tl::expected`（TartanLlama，单头，C++11+，CC0/MIT），
  改 `MG_Util/ShaderTranspiler/Types.h:115` 的 typedef + `ShaderCompiler.cpp` 里 5 处
  `std::unexpected(r)` = 共 6 处 + 1 个 vendored 头。
  ⚠️ **注意有两个 `Types.h`**：`MG_Util/Types.h` 是 `Range1D` 所在（`patches/0003` 改的那个），
  `MG_Util/ShaderTranspiler/Types.h` 才是 `std::expected` 的 typedef 所在。两者无关
- **B（✅ 2026-08-27 选定，施工记录 §S11）**：`__cpp_lib_expected` 特性宏分流 ——
  有 `std::expected` 的工具链原样用 std，没有的落到 vendored `tl::expected`，
  别名收敛在 `ShaderTranspiler/Types.h` 一处（`Expected<T,E>` + `MakeUnexpected`）。
  比 A 多一层 `#if`，但 **clang 16+ 工具链上是零改动路径**，正是能直接回推上游的形状。
  选 B 而不是 A 的理由：这条改动会永久活在 fork 提交栈里、随每次 rebase 被重审 ——
  对上游审阅者，"你们的工具链缺件所以全换成 tl" 与 "缺件时才落 tl" 是两个提案，后者可合并

⚠️ **不要**把上游 libc++ 16+ 的 `<expected>` 头单独拷进来：它依赖同版本 `__config` 的一批内部宏，
混版会以难诊断的方式炸。

---

## 四、并入方案

> 本节是 `guides/renderer-backend-governance.md` 在 MobileGL 上的具体化。**规范优先。**

### 4.1 前置条件（不属于本适配，必须先做）

治理规范 §11 的 **G1 + G2 + G5** 是 MobileGL 集成的**前置条件**：后端注册表、
收敛 `AMCL_GL_BACKEND` 的死通道、两个后端中立门禁。

**理由是可归因性，不是洁癖**：这三项要动的是**现有三个后端**的路由代码。
和新后端混在同一批里做，一旦真机出问题，分不清是"注册表重构把现有后端弄坏了"
还是"新后端本身不行"—— 而这恰是 `1000546` 那条判据（推断出的成因不得直接拿去改代码）想避免的局面。

### 4.2 来源治理（对齐规范 §6）

| 项 | 取值 |
|---|---|
| upstream | `MobileGL-Dev/MobileGL`（**基于 upstream fork，不基于任何人的 fork**） |
| repo | `LZZLHY/MobileGL` |
| branch | `amcl/ohos` |
| 位置 | `prebuilt/mobilegl/src`（git submodule，**gitlink 从第一天登记**，规范 §9 第 1 条） |
| pin | `deps.lock [mobilegl]`：`upstream` / `repo` / `branch` / `commit` / `base_commit` / `source_tree` |
| **`patches/`** | ⛔ **从第一天就不建。** MobileGL 是我们 fork 得到的 ⇒ 按规范 §6 的判据走 commit（SDL3 用 patch 是因为基线是 `icculus/SDL`，我们不拥有它） |
| 提交栈 | 三个补丁 → 三个 commit，message 写成能直接当上游 PR 描述的形状。**0001 的两个 hunk 拆成两个 commit** —— `<sstream>` 是通用可移植性修复，OHOS 平台分支是平台新增，上游会分开审 |
| 源码身份 | 内容寻址，复用 `scripts/compute-mg-source-identity.mjs` 的做法（**参数化而非复制** —— 规范 §3.2 的同源纪律） |

⚠️ **`diagnostics/mobilegl-probe-20260827/patches/` 是证据，不是交付通道。**
不要 `git apply` 它们到 submodule 里 —— 那正是 MG 的 pin 门禁存在要防的漂移。
它们的用途是：① 复现 Phase 0；② 作为写 fork commit 时的内容参考。

⚠️⚠️ **补丁是 4 个不是 3 个，且本目录到 2026-08-27 12:5x 才真正存在。**
本文与 CHANGELOG `1000555` 曾按 3 个补丁描述，并声称证据"已入库" —— 而当时它们
只是探针 clone 工作区里未提交的一团改动，`patches/series` 从未存在为文件
（施工记录 §S10.0）。补落时按本节要求把 `Includes.h` 的两个 hunk 拆开 ⇒
0001（`<sstream>`，通用）/ 0002（`__OHOS__` 平台分支）/ 0003（聚合体）/ 0004（结构化绑定）。
重放已实测：4/4 干净 apply，且与 Phase 0 原始改动**逐字节相同**
（`git diff` SHA-256 `33dde8c0…3638a2df`）。

### 4.3 命名（对齐规范 §3）

- `id = mobilegl`，**全程不缩写**。禁止 `MGL` / `mgl` / `MG2`（规范 §3.2，由 `check-renderer-naming.mjs` 强制）
- `MG` / `mg` 前缀**继续独属 MobileGlues**，不动
- 目录 `prebuilt/mobilegl/`、lock section `[mobilegl]`、门禁 `check-mobilegl-*.mjs`、
  日志 `AMCL_RENDERER backend=mobilegl`、编译宏 `AMCL_MOBILEGL_*`

### 4.4 产物形态：独立 DSO，不并入 libglfw

**MobileGlues 是并入 `libglfw.so` 的（`MobileGlues::Core` OBJECT → 同一个 DSO）。MobileGL 不要这么做。**

三条理由：

1. **`egl*` 已被占。** `libglfw.so` 里的 `egl*` 被 `-Wl,-Bsymbolic-functions` 在**链接期**绑定到
   MobileGlues 的包装实现（`CMakeLists.txt` 注释：「渲染正确性依赖它」）。
   把第二个 EGL 实现塞进同一个 DSO ⇒ 两套 `egl*` 定义在同一个符号空间里争 ⇒ 链接期或加载期不确定。
2. **两者互斥且启动期就能定。** 一进程只跑一个 MC，一次只用一个 GL 后端 ⇒
   没有任何理由让它们共处一个 DSO。
3. **`org.lwjgl.opengl.libname` 这条接缝天生就是"换 DSO"。** gl4es 与 zink 都走它。

⇒ **产物 `libmobilegl.so`，走 `org.lwjgl.opengl.libname=libmobilegl.so`。**
`org.lwjgl.glfw.libname` 恒为 `libglfw.so`，**从不切换**（规范 §5.1）。

### 4.5 ⭐ 所有权划分：复用既有的 NativeWindow 租约

这是整个并入方案的技术核心。**不发明新机制。**

`MobileGL` 的 `windowAcquisition = native-window-lease`，与 zink 同类。而这条接缝**已经在生产中**：

```
glfwOHOS_AcquireNativeWindowSnapshot(...)   → 拿到 window + generation + leaseBroker
        ↓
vkCreateSurfaceOHOS / 后端自己的 present
        ↓
glfwOHOS_ReleaseNativeWindowLease(window, broker)   ← 必须在后端停止使用之后
```

`glfw_vulkan.cpp:325` 已经这么用（含 RAII `NativeWindowLeaseGuard`），`glfw_osmesa.cpp` 是第二个使用者。

**所有权分工：**

| 资源 | 归谁 |
|---|---|
| `glfw*`（窗口、输入、生命周期） | **libglfw.so**（恒定） |
| `gl*`（MC 看到的 GL） | **libmobilegl.so** |
| `egl*` | MC 侧不直接用它。**libglfw 内部**按 latch 选 EGL 提供者（§4.5.1）：默认仍是链接期绑定的 MobileGlues 那份（零变化）；backend=mobilegl 时换成从 libmobilegl.so dlsym 的那份 |
| present（`glfwSwapBuffers` 落到哪） | 提供者的 `eglSwapBuffers` —— MobileGlues 时走 EGL 上屏（现状），mobilegl 时它内部就是 `vkQueuePresentKHR` |
| `OHNativeWindow` | libglfw 拥有并出租；提供者的 surface 存活期由租约括住 |

### 4.5.1 ⭐⭐ 接缝的机械形状：EGL 提供者置换（2026-08-27 定形，取代"present 转发"的含糊表述）

上游深调 §1.4 ③ 给了决定性事实：**MobileGL 的对接面就是它自带的 EGL 前端**
（导出真 `egl*` 符号、`eglCreateWindowSurface` 吃 native window、`eglSwapBuffers` 内部 present、
最后一个 `eglTerminate` 确定性销毁）。于是集成不需要发明任何新机制：

```
决策 latch（启动期一次，既有机制）
   ├─ backend = mobileglues → EGL 提供者 = 链接期绑定的 egl*（现状，逐位不变）
   └─ backend = mobilegl    → EGL 提供者 = dlopen("libmobilegl.so", RTLD_LOCAL|RTLD_NOW)
                              后 dlsym 的 egl*（MOBILEGL_BACKEND_TYPE=DirectVulkan 已经
                              由宿主在 JVM 创建前 setenv 闭锁）

glfw_egl.cpp / glfw_compat.cpp 的全部 egl 调用（2026-08-27 实测 50 + 22 处）
   → 改经一张启动期闭锁的提供者函数表；surface 生命周期代码【单轨，一字不动】
```

四条收益，每条都对着一个付过学费的坑：

1. **surface 生命周期保持单轨。** `InitEGL` / `SuspendEGLSurface` / attach/Lost/Replaced/generation
   处理原样复用，只是 `egl*` 经表调用。zink 需要 17 处 `if(zink){A}else{B}`（§S7 刚摘干净）的根因
   是 OSMesa **不是 EGL 形状的 API**；MobileGL 恰恰是。**不重演 17 处分叉。**
2. **present 转发不再是独立机制。** `glfwSwapBuffers` → 提供者 `eglSwapBuffers`。
   `observePresentedFrame()` 那个"唯一 present 记账入口"天然继续成立（§S7.3 预告过它是下一个落点）。
3. **MobileGlues 路径逐位不变可证。** 默认提供者表的每个条目就是链接期绑定的那批符号本身
   ⇒ Phase 3 的"产物 SHA-256 对比"判据可直接执行。
4. **MC/LWJGL 侧与 glfw 侧拿到同一个模块实例。** `org.lwjgl.opengl.libname=libmobilegl.so` 的
   dlopen 与 glfw 内部的 dlopen 引用计数共享同一 DSO ⇒ 状态一致。这与 gl4es 今天的形状
   （liblwjgl 拿 `gl*`，libglfw 持 context）同构，有生产先例。

⚠️ 两个必须核对的点（Phase 2c 验收项）：① 提供者表必须覆盖 glfw 内**全部** egl 调用点，
漏一处就是"一半 MobileGlues 一半 mobilegl"的混合状态 —— 用词法门禁断言
`glfw_egl.cpp`/`glfw_compat.cpp` 无裸 `egl*` 调用（`lib/source-noise.mjs` 已有能力）；
② MobileGlues 的 egl 包装除了 EGL 语义还带 AMCL 诊断（frame_stats 挂点等），
换提供者后这些挂点要么随表走、要么明确声明只在 mobileglues 路径存在。

⚠️ **DirectGLES 的排除理由修正**（旧文说"会撞上 MobileGlues 那份 EGL"）：§1.4 ④ 实测
它在 libmobilegl.so **内部自己 dlopen 系统 EGL/GLES**，而 MobileGlues 未被路由时不初始化 ——
不存在互斥。真正的排除理由是**范围纪律**：出货路径只认 DirectVulkan（差异化价值所在），
DirectGLES 仅作为 §5.1 实验臂（零额外集成成本，`MOBILEGL_BACKEND_TYPE=DirectGLES` 即得）。

三条必须遵守的租约约束（写在 API 注释里的）：
1. `Acquire` 成功即持有一个 NativeWindow 引用，必须在后端停止使用**之后**才 Release；
2. `Update`/`Clear` 必须同时匹配 pointer + expected generation，不匹配则整体不生效；
3. 借用视图 `glfwOHOS_GetNativeWindow` 不得跨 XComponent 回调保留、不得用于异步渲染。

⚠️ **必须自己处理 generation 变化。** `GameAbility` 禁分屏把该路径可达性降到接近零，
但折叠屏形态切换、2in1 自由窗口、键盘避让都不受那个字段约束。

### 4.6 观测契约（对齐规范 §7）

**不要把 MobileGlues 的 `frame_stats` 移植进 MobileGL。** 那是重复劳动，而且会把 AMCL 的诊断代码
塞进一个要回推上游的树里。规范 §7 规定的是**必须能回答的 5 个问题**，实现方式由后端自己选。

MobileGL 手里现成的实现材料：`MG_Util/SelfTest/DriverPost`（开机自检）、`DriverBugProbes`、
tracy 接入（`MOBILEGL_ENABLE_TRACY`）、`tools/trace_replay`（apitrace 回放，**fixtures 里已有 MC 26.3**）。

需要新写的只有**AMCL 侧的身份行与 present 计数**（规范 §7 第 1、2 条）——
它们描述的是"AMCL 用的是哪个后端、上屏了多少帧"，属于宿主而非后端。

### 4.7 门禁（对齐规范 §8）

| 脚本 | 说明 |
|---|---|
| `check-mobilegl-pin.mjs` | 三处 SHA 一致；**禁本地补丁**（从第一天） |
| `check-mobilegl-snapshot.mjs` | 源码清单快照 |
| `check-mobilegl-build-contract.mjs` | 产物级：编译行数 / LTO / 可见性 / 单一 DSO / HAP 内与未剥离中间件 SHA-256 一致 |
| `check-mobilegl-docs.mjs` | 文档与 lock 不漂移，**从 lock 解析、不硬编码 SHA**（规范 §8.1 那条判据） |
| **产物级证据断言** | 规范 §8.3。MobileGL 侧的判据候选：`AMCL_RENDERER backend=mobilegl` 那行字面量 + DirectVulkan 后端选择的字面量。**用 `.rodata` 字面量而非符号名**（内部链接 + ThinLTO 会内联掉符号） |
| 各自的 `test-check-*.mjs` | 门禁自己得先被测过 |
| **新增**：`check-mobilegl-cxx-gaps.mjs` | ⭐ 断言 `__cpp_aggregate_paren_init` 缺失时，fork 提交栈里对应的显式构造函数与局部变量拷贝**仍在源码树里**。这条防的是"升级 submodule 时把两个 clang 15 绕行改动 rebase 掉了，而本机 CI 用的是 clang 16+ 所以不报错" —— 与 `1000548` 同族 |

### 4.8 ⭐ 第二维度：窗口路径 × GL 提供者（本方案此前漏掉的一半）

施工记录 §S8.1 的真机取证已经出现第二维：**26.3+ 走 SDL3 窗口路径，libglfw 只当 GL 提供者**。
多渲染端整合真正的矩阵是二维的：

| | GLFW 窗口路径（1.12–26.2） | SDL3 窗口路径（26.3+） |
|---|---|---|
| mobileglues | ✅ 现状默认 | ✅ 现状默认（`SDL_OPENGL/EGL_LIBRARY=libglfw.so`） |
| gl4es | ✅ 强制 ≤1.16.5 | —（该世代没有 SDL3） |
| **mobilegl** | 需 §4.5.1 提供者表手术 | **只需把三个值指向 `libmobilegl.so`**（接缝已存在） |
| MC 官方 Vulkan | `glfw_vulkan.cpp` 已给 VkSurface | SDL3 的 Vulkan 面（另案，`VULKAN_ADAPTATION_PLAN.md`） |

SDL3 那格为什么薄：`sdl3_c2_test.cpp` 逐行核实过 SDL 的 GL 函数解析只有两个来源，
都由 `SDL_OPENGL_LIBRARY` / `SDL_EGL_LIBRARY` 决定（env 优先级高于应用 SetHint）。
把它们与 `org.lwjgl.opengl.libname` 一起指向 `libmobilegl.so`，SDL 的 openharmony 驱动会把
native window 递进 MobileGL 的 `eglCreateWindowSurface` —— **libglfw 一行不用改**。

⚠️ 由此发现一个未登记的决策消费点（已登记为治理规范 §11 **G9**）：
`mc_launcher.cpp` SDL3 准备段把两个 env **硬编码**成 `libglfw.so` —— 今天恰好等于
mobileglues 行的 `glLibName`，mobilegl 一来就是漂移点。修法：查
`renderer_backend_ids.h` 的行值（`glLibName` 就是提供者 DSO 名，零新字段）。

⇒ 分期顺序因此重排（§5.2）：**先走 SDL3 路由（P2b，只加新路由不动共用路径），
再动 GLFW 提供者表（P2c，三后端共用的上屏路径）** —— 把最危险的手术排在已有一条
真机可跑的 mobilegl 路径之后，出问题时二分空间小得多。

---

## 五、落地路径

### 5.1 试点选题：不是"高版本换 MobileGL"，而是一次归因实验

> **用 MobileGL 的 DirectVulkan 做一次 chunk boundary stutter 的归因实验。**

这个选题**双向都有产出**，而"高版本换 MobileGL"只有单向（成了才有价值）。

⭐ **2026-08-27 升级为 2×2 设计**（§1.4 ④ 使 DirectGLES 臂免费可得）：
只跑 DirectVulkan 臂改变了**翻译层与驱动路径两个变量**，结果无论好坏都归因模糊。
DirectGLES 臂（同一 DSO，`MOBILEGL_BACKEND_TYPE=DirectGLES`，零额外集成）把两个变量拆开：

| | Maleoon GLES 驱动 | Vulkan 驱动 |
|---|---|---|
| MobileGlues 翻译 | 现状（stutter 基线） | — |
| MobileGL 翻译 | **DirectGLES 臂** | **DirectVulkan 臂** |

| 实验结果 | 结论 |
|---|---|
| DirectVulkan 好、DirectGLES 差 | 优先排查 GLES 路径及两后端的实现差异；仍需 CPU/GPU 时间线才能定位驱动 |
| 两臂都好 | 优先比较 MobileGlues 的上传、拷贝及同步行为；该结果本身不证明唯一根因 |
| 两臂都差 | 同时检查应用/JVM、共享翻译逻辑与后端实现；不能因此排除渲染路径，仍需同时间轴 trace |

⚠️ 两条实验纪律：① 两臂与基线必须钉**同一套 JVM/GC 参数**（stutter 报告 §14 已证 GC 停顿
参与跨区块掉帧，不钉住就是第三个变量）；② Espryt 的 quirk 表覆盖 Adreno/Mali，Maleoon 属
未知水域 —— DirectGLES 臂只做实验，不做产品承诺。

`reports/2026-08-26_MG_CHUNK_BOUNDARY_STUTTER_INVESTIGATION.md` 自己的结论是
"**没有已证明的单一共同根因**"并列了证据边界。这个实验补的正是那条边界。

### 5.2 分期与验收判据

| 阶段 | 内容 | 量级 | 验收判据（不是"看起来能用了"） | 状态 |
|---|---|---|---|---|
| **0 判定** | 逐 TU 编译探针 | 1 天 | 逐 TU 矩阵 + 失败原因归类可复现 | ✅ **2026-08-27 完成** |
| **P 前置** | 治理规范 G1/G2/G5：注册表 + 纯函数路由 + 两个中立门禁 | 3–5 天 | 三个**现有**后端的真机回归无变化；host 测试覆盖路由判定 | ✅ **2026-08-27 完成**（CHANGELOG `1000557`）。三世代真机回归通过、路由字面量吻合；⭐ 顺带把 zink **完全**退役（`libglfw.so` 的 `osmesa*` 符号 19→0），判据比原计划的"zink 仍 fail closed"更强 |
| **1 可构建** | fork + pin + gitlink + §3 的 commit 栈 + CMake 平台条件，产出可链接的 `libmobilegl.so` | 3–5 天 | 全部产品 TU 编译**且链接**通过；`check-mobilegl-pin/snapshot/docs/cxx-gaps` 全绿（各带负向对照）；产物 `readelf -d` 无意外 NEEDED、无 `libc++` | ✅ **2026-08-27 完成**（CHANGELOG `1000566`，施工记录 §S12）。fork `LZZLHY/MobileGL@amcl/ohos` 8 commit（`0d2fceab..aafa3711`）；166 自有 TU 与探针逐一对上；NEEDED 仅 vulkan+libc；导出面收敛 14093→3030；strip 后 12.9 MB。⚠️ 比计划多出两个真修复：`libc++experimental.a`（`<format>` 运行时）与 `--exclude-libs,ALL`（符号泄漏防插桩），都已进 fork 栈 |
| **2a OHOS 后端最小面** | OHOS WSI、hilog、consumer pbuffer；同 context 切 surface 保留 device/GPU 资源 | 已实施 | 独立出帧、同窗口重建、pbuffer/window 纹理回读与清理；真实宿主 generation 变化另列恢复压力矩阵 | ✅ 双设备基础验证；恢复压力待验 |
| **2b SDL3 路由试点** | 表驱动库路由、profile 选择、GL/EGL 函数自绑定、产物隔离与身份/计数检查 | 已实施 | 26.3 本体出图、退出资源平衡；注册表/负向门禁通过；普通 HAP 排除 MobileGL 库 | ✅ S17 范围内通过，当前为 optional peer；完整 provider/性能矩阵待补 |
| **2c GLFW 提供者表** | 默认函数归属保持，新增 provider 表统一 GL 取址与 EGL 生命周期，再接 mobilegl | 独立后续批次 | 三世代真机回归；26.2+Sodium 出图；无漏接的裸 EGL 调用；不再以整个 DSO 位级相同作为判据 | ⬜ |
| **3 观测 + 2×2 实验** | 满足规范 §7 五条；跑 §5.1 的 2×2 归因实验 | 2–3 周 | 五条观测项在真机日志里齐全；同机同存档同 JVM 参数；**结论写进 stutter 报告并结项或转向**；据此走 §5.3 晋升或退役 | ⬜ |

合计 **2–3 个月量级**。比 gl4es 那次（计划估 3–4 周，实际拖过 `1000132`–`1000145` 十几轮）大一档，
差别就在 §4.5 那段所有权。

📌 **2b 排在 2c 前面的理由**（顺序即风险控制）：2b 只动 `mc_launcher` 的路由发布（新增路由，
不碰共用路径），2c 才动三后端共用的 EGL 上屏路径 —— 把最危险的手术排在已有一条真机可跑的
mobilegl 路径之后，出问题时"是新后端不行还是提供者表弄坏了现有后端"可以直接二分。

### 5.3 退出条件（引入前就写好怎么退）

Phase 4 数据不支持时，按治理规范 §10 的 **A（完全退役）** 处理：
注册表 `lifecycle=retired`、DevTools 入口移除、实现移进 `prebuilt/mobilegl/integration-archive/` 留墓碑指针、
连注释一起删。

⚠️ **不允许停在"选了会回落"**——那是 zink 现在的形态，也是治理规范 §10 认定的最坏状态。

### 5.4 与官方 Vulkan 那条路不冲突

`VULKAN_ADAPTATION_PLAN.md` 解决 26.2+ 的长期问题（OpenGL 被移除后的唯一出路）；
本文解决 **1.17 – 26.1 那一大段**的驱动绕行问题。两件事不抢工作面，只抢工程预算。

---

## 六、风险（Phase 0 没有消除它们）

### 6.1 上游成熟度

无 release、无预编译二进制、自述 in development。
~~短期目标只到 OpenGL 4.2 Core Profile，Sodium/Iris 热点覆盖未查~~ ——
✅ **该欠账已于 2026-08-27 以源码实测正向关闭**（§1.4 ①）：GL 4.3 + GLSL 4.6 +
全套热点扩展（buffer_storage / DSA / MDI / indirect_parameters / compute / SSBO），
且是刻意针对 MC 生态设计。**残余风险收窄为 in-development 代码的实现完整度**
（接口面齐 ≠ 每条路径都对），这正是 Phase 3 实验要回答的问题，不再阻塞 Phase 1。

### 6.2 诊断设施归零

MobileGlues 侧的既有资产在新后端上全部不存在：`gl/frame_stats.h` 的 selective 观测、
`[MG-STORAGE]` 日志、四个 host 单测、`check-mg-build-contract.mjs` 的 37/47/6 编译行审计、真机能力矩阵。
按 §4.6，不是照搬而是各自满足契约，但那仍是 Phase 4 那 2–3 周的主要内容，**不是可选项**。

### 6.3 许可：LGPL-2.1 → LGPL-3.0-only

MobileGL 是 **LGPL-3.0-only**（`SPDX-License-Identifier: LGPL-3.0-only`，逐文件标注），
相对 MobileGlues 的 LGPL-2.1 多了反规避条款与专利条款。本项目已有 LGPL 发布材料政策
（`guides/mobileglues-release-evidence.md` + `guides/mobileglues-2.0-ohos-governance.md` 的相应章节），
**引入前必须让那套政策覆盖 LGPL-3.0**，并单独评估应用市场上架影响。

### 6.4 Phase 0 自身的边界（不要过度解读）

- `-fsyntax-only` 只证明**编译前端**通过：没有链接、没有产出 `.so`、没有跑过一行代码。
  把 99.4% 读成"MobileGL 在鸿蒙上能用"是错的 —— 它只说明"编译侧不是阻塞点"。
- 探针用的 `shim-expected.h` 是 UB，不可出货（§3.3）。
- 探针独立取了 SPIRV-Tools / SPIRV-Headers 的 HEAD，与 MobileGL 实际 pin 不同 ——
  最后那 1 个失败 TU 就是这个错位，**不能反过来当"MobileGL 有 bug"的证据**。
- `MG_Test` / `MG_Benchmark` / `MG_IntegrationTest` / `tools/trace_replay` 的 TU **未纳入**探针。
- 3 个 `GLXImpl` TU 被排除是判断而非实测：X11 前端在 OHOS 上不该存在。

### 6.5 本轮新增的风险登记（2026-08-27）

| # | 风险 | 处置 |
|---|---|---|
| 1 | **HAP 体积**：libmobilegl.so 静态含 glslang + SPIRV-Tools + SPIRV-Cross，预估比 MobileGlues（strip 后 ~5 MB）大数倍。zink 退役刚省下 15.7 MB，candidate 阶段把它加回发布 HAP 需要显式决策 | ⚠️ **待产品决策 D3**：candidate 阶段产物只进验证包 / DevTools 侧载，不进发布 HAP；晋升 experimental 时再评估。P1.5 先量出实际 strip 后体积再谈 |
| 2 | **shader 编译卡顿混淆实验**：MobileGL 走 GLSL→SPIR-V（glslang）运行期编译，翻译缓存是**进程内**三级 memo（`TranslationCache.h`），无持久盘缓存 ⇒ 每次启动首个 chunk 波会有编译峰 | 实验设计规避：进世界后先原地转一圈让稳态建立，再开始跨区块采样；异步编译（`MOBILEGL_ASYNC_SHADER_COMPILE`）默认值随上游 |
| 3 | **Maleoon 驱动 quirk 覆盖为零**：上游 quirk 表针对 Adreno/Mali/ANGLE/llvmpipe，Maleoon 上 DirectVulkan 的行为属未知水域（`robustBufferAccess` 默认开、subgroup 派生等每条 quirk 都可能有 Maleoon 版本） | 这就是 Phase 2a 探针 + Phase 3 实验的内容；`MOBILEGL_*` 开关全部经 env 可控，出问题时有 A/B 杠杆 |
| 4 | **上游 LFS 配额已耗尽**：`tools/trace_replay/fixtures` 的 LFS 对象拉不下来 | clone 纪律：`GIT_LFS_SKIP_SMUDGE=1` + 仓库本地 `filter.lfs` skip 配置（fixtures 只服务上游自己的回放回归，本仓不消费） |

---

## 七、复现 Phase 0

```powershell
# 1. 取源码（LFS fixture 会因上游 LFS 配额失败，跳过即可，不影响源码）
git clone --depth 1 --branch dev --filter=blob:none --no-recurse-submodules `
    https://github.com/MobileGL-Dev/MobileGL.git MobileGL
cd MobileGL
git config --local filter.lfs.smudge "git-lfs smudge --skip -- %f"
git config --local filter.lfs.process "git-lfs filter-process --skip"
git submodule update --init --depth 1 -- include/ska 3rdparty/xxHash `
    3rdparty/Vulkan-Headers 3rdparty/VulkanMemoryAllocator `
    3rdparty/Vulkan-Utility-Libraries 3rdparty/SPIRV-Reflect 3rdparty/asio
# include/ 已 vendored glslang 与 SPIRV-Cross 的头，不需要取那两个 submodule

# 2. 打补丁（⚠️ 仅用于复现 Phase 0；正式集成走 fork commit，见 §4.2）
Get-Content ../patches/series | ForEach-Object { git apply ../patches/$_ }

# 3. SPIRV-Tools 的构建期生成表（探针不跑 CMake，需手工复刻）
cd ..; pwsh -File gen-spirv-tables.ps1

# 4. 逐 TU 编译
pwsh -File probe-compile.ps1 -Jobs 6
# → results/compile-probe-summary.txt / -matrix.csv / -failures.log
```

脚本、补丁、逐 TU 矩阵与工具链实测原始输出都在 `diagnostics/mobilegl-probe-20260827/`；
`toolchain-probe.md` 里有各 SDK 版本的 clang 版本号、预定义平台宏与 C++ 特性宏的原始输出。
