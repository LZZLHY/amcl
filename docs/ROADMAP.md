# MC-OHOS 路线图：待办 / 优化 / 新功能

> **版本**：2026-04-19
> **基线 commit**：`47cec6e fix(forge): 解决 Forge 1.20.4 启动黑屏` + P0-1 / P0-2 + P1-1 / P1-2 已落地 + 死代码清理 + 踩坑记录
> **代码质量评估**：**7 / 10**（Forge 启动链；P0-1 + P0-2 落地后上调 0.5）
>
> 本文档取代了下列老文档（已归档到 `archive/`）：
> `project-evaluation-and-optimization.md`、`refactoring-proposal.md`、`refactoring-test-plan.md`、
> `architecture_refactor_v3.md`、`forge-launch-issues-analysis.md`、`guides/implementation_guide.md`、
> `reports/p6_mc_launch_debug_log.md`、`reports/forge-remaining-issues-20260409.md`、
> `待优化项.md`、`技术概念手册.md`、`项目文档.md`
>
> 历史调试轨迹保留在 `archive/forge-analysis/` 和 `archive/forge-fix-2026-04-18/` 供考古参考，**不代表当前项目方向**。

---

## 一、当前状态快照


| 模块               | 状态              | 备注                                                                                                                                         |
| ---------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Vanilla（原版）      | ✅ 可进入主菜单        | 稳定                                                                                                                                         |
| Fabric           | ✅ 可进入主菜单        | 稳定                                                                                                                                         |
| **Forge 1.20.4** | ✅ 可进入主菜单 + 进入世界 | 2026-04-19 实测确认。但参数链**极脆弱**，见"踩坑记录：禁止加入的 JVM 参数"                                                                                           |
| Cacio AWT        | ✅ 默认启用          | `McGamePage.ensureCacioJars()` 每次启动前无条件从 `rawfile/` 抽 `cacio-shared.jar` + `cacio-tta.jar` 到 `filesDir/cacio/`；C 层检测到就启用全套 Cacio 参数。见 P1-2 |
| 音频（OpenAL）       | ❓               |                                                                                                                                            |
| 手势/触摸输入          | ✅ 基本可用          | 见 `guides/glfw_input_design.md`                                                                                                            |
| 下载/安装系统          | ✅ v6 + Phase 1~9 全落地 | 详见 `guides/download-system.md`（C++ 引擎 + 编排层 + UI + Forge/Fabric/MC 元数据全部走 NAPI；剩真机回归 + 性能对比） |
| **JDK 17**       | ✅ **唯一上线运行时** | `OpenJDK 17.0.13-internal v4`，4 个 patch，HAP 内 **policy lock**：`Constants.SUPPORTED_JDK_VERSION = '17'`、`JdkManager.listVersions()` 仅返回 17、`autoSelectVersion()` 永远返回 17、非 17 自动覆盖回退 |
| **JDK 21**       | ⚠️ **未上线（实验中）** | `prebuilt/jdk/21/`、`docker/build_jdk21_ohos.sh`、`patches/jdk21u/` 为研究产物，**未做真机充分回归**。代码层已锁死不会被走到。详见下方 §三 P2-NEW 待办项 |


---

## 二、Forge 启动链代码质量评估（7 / 10）

Forge 能跑起来 ≠ 代码健壮。本次定位 Forge 黑屏花了十几轮调试，过程暴露出四个结构性风险：

### 扣分项


| #   | 风险项                                                  | 严重度  | 备注                                                                                                            |
| --- | ---------------------------------------------------- | ---- | ------------------------------------------------------------------------------------------------------------- |
| 1   | ~~JavaApp 游离于 hvigor 之外~~ **已解决**                    | ✅ 🟢 | 2026-04-19 用 hvigor `registerTask` + `scripts/build-amcl-launcher.mjs` 修复，见 P0-1                              |
| 2   | ~~JVM 参数分散在 3 个位置~~ **已解决**                          | ✅ 🟢 | 2026-04-19 抽出 `jvm_common_args.{h,cpp}` 做 Single Source of Truth，NAPI `getCommonJvmArgs()` 给 ArkTS 去重用，见 P0-2 |
| 3   | **sigchain SIGSEGV handler 与 HotSpot safepoint 紧耦合** | 🔴 高 | 曾因多加一个 `mprotect` 导致 JVM 整体死锁；维护者必须懂 safepoint 机制                                                             |
| 4   | **调试期遗留物**（watchdog、LWJGL debug、多层日志）                | 🟡 低 | 已改成默认关闭+env/-D 开关，但代码路径仍在                                                                                     |
| 5   | **启动时序隐式依赖 `filesDir/cacio/` 等目录存在**                 | 🟠 中 | 用 if-exist 分支替代显式 contract                                                                                    |


### 加分项

- ✅ 正确区分 Vanilla / Fabric / Forge 的 JVM 参数集合
- ✅ `LaunchProfileBuilder` 对 C 层与 ArkTS 层参数去重，清单统一来源 NAPI `getCommonJvmArgs()`（SSOT，见 P0-2）
- ✅ JavaApp 编译纳入 hvigor 构建图（`buildAmclLauncher` task，见 P0-1）
- ✅ `JDK_ADAPTATION_GUIDE.md` 把调试教训沉淀成文档警示

---

## 三、路线图：按优先级的待办

### P0 — 稳定性底座（建议本迭代完成）

#### ~~P0-1. 把 JavaApp 纳入 hvigor 构建图~~（2026-04-19 ✅ 已解决）

**解决方案**：采用 **方案 A（hvigor 自定义插件）** —— 事后发现 API 并不稀缺（`pluginContext.registerTask` + `dependencies` / `postDependencies` 就够用）。实现要点：

- `entry/hvigorfile.ts` 注册 `buildAmclLauncher` task，`dependencies: ['default@BuildJS']`，`postDependencies: ['default@PackageHap']`，插到 BuildJS 和 PackageHap 之间。
- 实际编译逻辑拆到 `scripts/build-amcl-launcher.mjs`（跨平台 Node 脚本）：`JAVA_HOME` / PATH 定位 javac + jar → `javac -d JavaApp/build/classes ... -source 17 -target 17` → `jar cf entry/.../rawfile/amcl-launcher.jar` → 带增量检查（jar mtime vs 源文件 mtime，up-to-date 就跳过）。
- `build-hap.ps1` 简化为两步（预热 + hvigor）；DevEco Run ▶️、命令行 `hvigorw`、CI 一致触发。

方案对比（放在这里作为考古）：

- **A. hvigor 自定义 task（采用）**：纯 hvigor，三端一致。
- **B. `oh-package.json5` prebuild 钩子**：`scripts` 字段不是 npm 的 `scripts`，DevEco Run 时不一定触发，弃用。
- **C. 搬 .java 进 entry/src/main/java/**：HarmonyOS NEXT HAP 模块不识别 Java 源集，hvigor-ohos-plugin 不是 Gradle，不会自动 javac；`amcl-launcher.jar` 本身也不是 HAP 应用代码，放进去语义混乱。弃用。

#### ~~P0-2. JVM 参数 Single Source of Truth~~（2026-04-19 ✅ 已解决）

**最终方案**：SSOT 归属放在 **C 层**（不是 ArkTS），因为：

- 消费者里有两个 C 层进程（主 JVM `jvm_launcher.cpp` + Forge installer 子 JVM `fork_run_java.cpp`），ArkTS 层只是一个消费者（做 version.json 去重）。
- Cacio 参数是否启用依赖运行时目录检查（`filesDir/cacio/*.jar` 是否存在），ArkTS 侧决策链路更长。
- 避免 ArkTS → NAPI 往返构造字符串数组的开销（虽然启动期只调 1 次，但体系更简单）。

**实现**（落地于 commit `WIP-P0-2`）：

- 新增 `entry/src/main/cpp/jvm/jvm_common_args.{h,cpp}`：`amcl::getCommonJvmArgs()` 返回静态 `vector<string>&`（function-local static，C++11 线程安全），清单覆盖所有 "OHOS 兼容性修复" 参数（add-opens/add-exports/add-reads/egd/基础 `-XX:`）；不含运行时生成的 `-Xmx`、路径、classpath、loader 专属的 log4j2 / Cacio 条件参数。
- `jvm_launcher.cpp` 和 `fork_run_java.cpp` 都通过 `for (auto& s : amcl::getCommonJvmArgs()) { ... }` 追加，原硬编码字面量全部删除。
- NAPI 暴露 `getCommonJvmArgs(): string[]`（`napi_entry.cpp` + `types/libentry/index.d.ts`），`LaunchProfileBuilder.filterJvmArgs()` 从 NAPI 取清单构成去重 Set，替换原来和 C 层重复的字面量黑名单。

**验收**：

- ✅ `jvm_launcher.cpp`、`fork_run_java.cpp`、`LaunchProfileBuilder.ets` 三处字面量全部删除
- ✅ `hvigorw clean assembleHap` 一次过（HAP 29.5 MB 签名成功，`entry/build/default/outputs/default/entry-default-signed.hap`）
- ✅ 真机跑 Forge 1.20.4 主菜单 + 进入世界一轮，参数清单无缺失

---

### ⚠️ 踩坑记录：禁止加入的 JVM 参数 / 启动期操作

> 新成员在借鉴 Amethyst-iOS / PojavLauncher 时高概率想抄的"保险"操作，**在鸿蒙上会让 MC 启动失败**。加一条记一条，下次不要再来一遍。


| 改动                                                                     | 抄来自                                       | 实际表现（鸿蒙）                                                                                                                                                                                             | 定论                                                                                                           |
| ---------------------------------------------------------------------- | ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `-Dorg.lwjgl.system.allocator=system`（**JVM 启动参数 `-D` 形式**）             | Amethyst-iOS `JavaLauncher.m:242`         | MC Render thread 进 Minecraft 主循环后静默卡死（"Forge Initialized" 之后无任何输出、窗口黑屏、无异常栈）。疑似 OHOS libc `malloc` 在 LWJGL 小对象高并发分配下与 JDK 分配器锁竞争。                                                                    | **禁止作为 `-D` 启动参数加**（`JavaVMOption.optionString`）。2026-04-19 实测验证。详见 `jvm_launcher.cpp:499-508` 注释。          |
| `phase_initJvm` 里 `mmap(xmx+256MB, PROT_NONE) + munmap` 做 xmx 虚拟地址空间预检 | Amethyst-iOS `validateVirtualMemorySpace` | MC Render thread 卡在 JVM 模块系统初始化阶段（mc_output.log 停在 `Opening jdk.naming.dns ... to java.naming`）。理论上"mmap+立即 munmap"应零副作用，但在 OHOS 上会干扰后续 HotSpot 的 heap reservation / `elf_loader` 已映射的 JDK .so 地址布局。 | **禁止加**。OHOS 内核的虚拟地址空间语义与 Linux/iOS 不同，"先占用再释放"的技巧不通用。2026-04-19 实测验证。详见 `mc_launcher.cpp:phase_initJvm` 注释。 |


> **通用原则**：Amethyst-iOS 的参数集基于 iOS 沙箱 + `JLI_Launch` + 单 JVM 进程假设，和我们（鸿蒙 + `JNI_CreateJavaVM` + 主/子双 JVM + 自定义 sigchain + `elf_loader`）**根本不是同一类运行时环境**。任何新参数 / 新启动期操作都必须走一轮"真机 Vanilla + Forge 各一次"的回归验证，**不允许仅靠"理论无副作用"就 ship**。

---

### 📝 关于 `org.lwjgl.system.allocator=system` 的重要澄清（2026-05-07）

上表只禁止 **`-D` 启动参数形式**。项目当前**确实设置了该属性**，但路径不同，不冲突：

| 路径                                                                 | 时机                             | 当前状态         |
|---------------------------------------------------------------------|--------------------------------|------------------|
| `-Dorg.lwjgl.system.allocator=system`（`JavaVMOption.optionString`） | `JNI_CreateJavaVM` 前写入 JVM args | ❌ **禁止**（黑屏） |
| `System.setProperty("org.lwjgl.system.allocator","system")`         | JVM 起来后、MC `main()` 调用前       | ✅ **允许**（已在用） |

**✅ 调查结论**（2026-05-07 真机三组对照 C 组实测）：

**两处运行时 `setProperty` 都不必要**——LWJGL 默认 allocator (rpmalloc) 在 HarmonyOS Vanilla 1.20.4 与 Forge 1.20.4 均可正常进世界，无黑屏 / 无崩溃。已永久删除两处代码：

- ~~C 层 `@entry/src/main/cpp/jvm/mc_launcher.cpp:phase_setProperties`~~（已删，REGION 留作历史 tombstone）
- ~~Java 层 `@JavaApp/src/com/amcl/launcher/AmclLauncher.java:setupSystemProperties`~~（已删，REGION 留作历史 tombstone）

**历史背景**（2026-03-28 引入的原因）：当时 Forge 运行期 LWJGL Java/native 组合一致性需要靠 `system` allocator 修复；后续 LWJGL/MobileGlues/Forge 工具链演进使该绕路不再必要。详见 `@docs/archive/forge-analysis/forge-runtime-lwjgl-mismatch-20260328.md` 第 3 节。

**为什么 `-D` 路径和 `setProperty` 路径结果不同**（仅作为参考解释，今已不需要 setProperty）：
- `-D` 写入 JavaVMOption 会在 `JNI_CreateJavaVM` 阶段就被 HotSpot 内部解析、传给 JDK 的 `java.lang.System.initProperties`，可能影响 JVM 初始化顺序或早期 JDK native 库（jemalloc stubs）的加载 / 符号解析；
- `System.setProperty()` 只是写入 JVM 已经建好的 `Properties` 对象，LWJGL 读取时拿到的值相同但早期 native 侧不受影响。

**调查与防回归**：

- 完整调查记录：`@docs/archive/allocator-investigation-202605.md`
- 防回归测试：`@JavaApp/test/com/amcl/launcher/AmclLauncherTest.java:testSystemPropertiesLwjglAllocatorLocked` 现在锁定"必须**不**设置该属性"，任何回归会被立即捕获。

---

### P1 — 关键功能闭环

#### ~~P1-1. 验证 Forge 进入世界~~（2026-04-19 ✅ 已解决）

Forge 1.20.4 实测可进入世界。进入世界的渲染 / 数据包 / 区块线程调度路径已经跑通，未发现崩溃。遗留隐患：**参数链极其脆弱**，本日加一个 `-Dorg.lwjgl.system.allocator=system` 就把 Render thread 卡死在主循环，见上方"踩坑记录"。

#### ~~P1-2. Cacio AWT 默认启用~~（2026-04-19 ✅ 已解决）

**发现**：通读代码后确认 Cacio 其实早就默认启用了，ROADMAP 原始描述基于过时理解，已实际落地的工作如下：

- `@entry/src/main/ets/pages/McGamePage.ets:171-194` `ensureCacioJars(filesDir)`：每次 `launchGame()` 前无条件从 `rawfile/` 抽 `cacio-shared.jar` + `cacio-tta.jar` 到 `filesDir/cacio/`（不限 Forge 版本）。
- `@entry/src/main/cpp/jvm/jvm_launcher.cpp:446-522` 主进程：检测到 jar 存在就启用完整 Cacio 参数集（`-Xbootclasspath/a:` + `-Djava.awt.headless=false` + `-Dawt.toolkit=CTCToolkit` + `-Djava.awt.graphicsenv=CTCGraphicsEnvironment` + `-Dcacio.*` + metal LAF）。
- `@entry/src/main/cpp/jvm/fork_run_java.cpp:208-225` Forge installer 子进程：**固定启用** Cacio（不做条件判断），让 installer 走 GUI 模式跑 processors 以保证 SHA1 校验通过。

**保留的"条件分支"设计是正确的**：C 层 `if cacioAvailable` 这个分支不是"默认不启用"，而是"用户万一手动删除 jar 的 fallback 安全阀"，继续保留即可。

**ROADMAP 原描述错误点**：

- ~~"把 Cacio 参数从条件改为默认"~~ —— Cacio 相关 JVM 参数本来就不在 ArkTS 层，都在 C 层 `jvm_launcher.cpp`；ArkTS 层没有"条件"可改。
- ~~"首次启动抽 jar"~~ —— 当前是**每次**启动前抽一遍（有 size 检查，只写一次，开销可忽略）。

**剩余可选优化**（不阻塞，留给未来）：

- 在 UI 层显示 Cacio 启用状态（`isCacioAvailable` NAPI），方便用户确认 AWT mod 支持已就绪。
- 写一份 AWT mod 兼容性测试矩阵（JEI / Create / Jade 等），纳入真机回归。

#### ~~P1-3. 下载系统 v3 重构~~（2026-04-19 ~ 2026-05-06 ✅ 已落地）

**最终落地**：经过 v3 / v4.1 / v4.5 / v5 / v5.1 / v5.2 / v6 共 7 轮迭代 + Phase 1~8 收尾，下载系统已建立完整的三层架构：

- **C++ 引擎**：libcurl + 64 multi 并发 + 8 worker 大文件分段 + 断点续传 + 坏主机黑名单 + SHA1 校验（`entry/src/main/cpp/download/`，30 个文件）
- **ArkTS 编排**：`DownloadManager` / `DownloadTask` / `SourceProber` / `McDownloader` / `JdkManager`，含 6 阶段编排（PhaseRunner 抽象）+ retry/pause/resume/cancelAndAwait + 字节级加权进度
- **UI 重构**：`DownloadFab`（浮动圆 + 拖动吸附）+ `DownloadSheet`（半屏弹层）+ `DownloadPhaseCard`（阶段卡片）+ `DownloadHistoryPage`（LRU 20 条历史）
- **Forge 沙箱化**（2026-05-05）：installer 在 `filesDir/forge-install-sandbox/<sid>/` 跑，patches libraries 用 `fs.renameSync` O(1) 迁入真实 mcDir

**Phase 1~9 收尾（2026-05-05 ~ 2026-05-06，✅ 全部完成）**：
- Phase 1（ARCH-1）：Forge / Fabric 依赖库走 NAPI 引擎 — `MavenSpecBuilder` + `MavenUtils.downloadMavenLibraries` 委托 `DownloadManager.createAndWait`
- Phase 2（ETag/条件请求缓存）：`MetadataCache` 纯函数 + `MetadataCacheStore` 持久化 + 引擎层 304 短路（`fetchToBufferEx`）
- Phase 3（元数据走 NAPI）：`engine.fetchToBuffer` + `downloadFetchText` NAPI + `McDownloader.httpGet` 三段式（TTL → 304 → GET）
- Phase 4（增量 SHA1）：`NetThread::onWrite` 边写边 hash + `NetFile` 单段命中 `checkFast` 跳过 re-read
- Phase 5（下载历史页）：`DownloadHistoryStore` LRU 20 + `DownloadHistoryPage` UI + `Index.recordHistory` 三态终态写入
- Phase 6（PhaseRunner 抽象）：6 个 `IDownloadPhase` 实现 + `DownloadFlowState` 共享状态 + `DownloadTask.doStart` 重构
- Phase 7（自动化测试 ~37%）：12 个 ArkTS `.test.ets` + 4 个 C++ `_test.cpp`，覆盖纯函数 + 算法核心 + 异常生命周期
- Phase 8（源加权打分）：`NetSource::computeScore`（RTT/吞吐量滑动窗 + 失败惩罚）+ `pickBestSourceWeighted`，已集成到 `NetFile::pickBestSource`
- Phase 9（元数据 + installer 全面 NAPI 化，方案 C，2026-05-06）：
  - 删除 `MavenUtils.httpGetText` / `decodeArrayBufferAsUtf8`（共 55 行旧实现）
  - 删除 `ForgeService.httpDownloadFile` / `McVersionService.httpGet`（共 45 行旧实现）
  - `ForgeService` / `FabricService` / `ForgeInstallerUtils` / `McVersionService` 共 11 处 `httpGetText` 调用迁移到 `DownloadManager.fetchText`（含 5 处合并为单次多源 fallback 调用）
  - Forge installer.jar 改走 `DownloadManager.createAndWait` 多源 + 引擎 SHA1 + 后置 ZIP/EOCD 防御性校验
  - 仅剩 `SourceProber.ets`（RTT 探测必须主动测延时）+ `MavenUtils.httpDownloadFile`（CA bundle 未初始化的 legacy fallback）保留 ArkTS http，已注释说明
- Phase 9 收尾审计（R1~R11，2026-05-06）：基于全面代码审查 + self-inspection 报告复查，处理所有未修的代码重复 + 资源管理边界 bug：
  - **P0 实锤重复（4 项）**：ForgeService.rmDirRecursive → FileUtils.removeDirRecursive；VersionParser.mavenNameToPath → MavenUtils.mavenToRelativePath；DownloadManager.formatBytes/formatSpeed 改为 re-export from PathUtils；writeTextFile 三份副本（**新发现**）抽到 FileUtils.writeTextFile
  - **P1 结构重构（3 项）**：fontconfig 候选路径双份 → 新建 utils/FontconfigUtils.ets；fileExistsAndNonEmpty 模块归属（modloader → utils）；createAndWait 终态自动 purgeTask（防 Map 累积）
  - **P2 边界（4 项）**：hasValidZipEocd close 后置 null；McGamePage poll 加 navigatedAway 守卫；copyDirRecursive 加 32 层深度限制；McVersionService 轮询 → Promise waiter list
  - 净 -95 行，自检报告标 ✅ 共 11 项（D5-2/D5-9/D6-1/D7-4/D8-2/D9-3/D12-4/D13-1/D26-1/D2-5/D25-1）

**剩余长尾**（非阻塞，详见 `guides/download-system.md` §4）：
- 真机端到端回归（Vanilla / Forge / Fabric 各 1 次，需物理设备）
- 性能对比：BMCLAPI vs Mojang 实测胜率（Phase 8.4 deferred）

**权威文档**：`guides/download-system.md`（取代了 9 份 v2~v6 设计稿，全部归档到 `archive/download-history/`）

---

### P2 — 工程化改进

#### P2-1. 真正的 CI 烟雾测试

`build-hap.ps1` + `hdc install` + `aa start` + 拉 10 秒日志 + grep `Setting user.dir`。一条命令知道基本启动是否 OK。

#### P2-2. 崩溃归因报告

现在闪退只能事后看 `hilog`。方案：C++ 层装 `SIGSEGV/SIGBUS/SIGABRT` 兜底 handler，把寄存器 + unwind stack 写到 `filesDir/crash-<ts>.log`，UI 层开机检查有没有新文件并弹出"上次崩溃"按钮。

#### P2-3. 性能基线

抽出三个核心指标（冷启动到主菜单、进入单人世界、稳定帧率）并在 `docs/reports/` 留下历史数据，防止后续改动悄悄拖慢启动。

#### P2-NEW. **JDK 21 上线（2026-05-08 加，currently blocked）**

**当前状态**：
- 编译产物存在：`prebuilt/jdk/21/natives/` 36 个 .so（带 21 后缀）、`docker/build_jdk21_ohos.sh`、`docker/patches/jdk21u/series` 5 patches
- ArkTS 端**已锁死 JDK 17**：`Constants.SUPPORTED_JDK_VERSION = '17'`、`JdkManager.listVersions()` 仅返回 17、`autoSelectVersion()` 永远 17、UI 层（Index / McGamePage / SettingsTab）非 17 都自动覆盖回退
- C++ 端无 21 硬编码分支（`mc_launcher.cpp` / `jvm_launcher.cpp` / `napi_forge.cpp` 都接收字符串参数）
- ⚠️ **未做真机回归**：未确认 JDK 21 + Vanilla 1.20.5+ / Forge 50.x / Fabric 0.16.x 可启动 + 进世界

**上线步骤（需按顺序完成）**：
1. **真机回归**：JDK 21 + Vanilla 1.20.5、1.21、1.21.4 三档至少各跑一次进世界
2. **ForgeService 兼容矩阵**：当前 `getForgeInstallerJdkVersion()` 硬返回 17 + `checkJdk17Compatibility()` 名字写死 17，需扩展为版本矩阵（Forge 47+ MC 1.20.4 用 17；Forge 50+ MC 1.20.5+ 用 21）
3. **解锁 SSOT**：`Constants.SUPPORTED_JDK_VERSION` 改单值为支持矩阵；`JdkManager.listVersions()` 暴露 17 + 21；`autoSelectVersion(mcVer)` 按 MC 版本路由
4. **UI 加可选项**：JDK 选择下拉重新启用 21 选项；非支持矩阵给警告
5. **下载源**：`jdk21-ohos-full-vN.zip` 上传到 release 仓 + SHA-256 写到 `JdkManager.JDK_VERSIONS['21']`

**风险**：
- musl libc / dlvsym / utmpx 兼容补丁（jdk21u 系列）只在编译期验证过，**运行期未知**
- ELF loader 是否能正确加载 25MB libjvm21.so（vs 23MB libjvm17.so）未实测
- HotSpot safepoint sigchain 在 JDK 21 与 JDK 17 行为差异未知

**前置条件**：在 P0-3（如未来加入）/ Forge 兼容矩阵 / 下载源就位之前不应启用。

---

### P3 — 新功能建议（可作为长线 roadmap）


| 代号      | 想法                                  | 价值                                      |
| ------- | ----------------------------------- | --------------------------------------- |
| **F-1** | 多版本并行（MC 1.16.5 / 1.20.4 / 1.21 切换） | 现在 JDK 和 classpath 已有 profile 概念，扩展成本不大 |
| **F-2** | 手柄/外设（鸿蒙 2.4G/蓝牙手柄）                 | 填补纯触摸操作缺口                               |
| **F-3** | 资源包/光影包导入 UI                        | 走 ArkTS 文件选择器，复用现有下载系统进度条               |
| **F-4** | MCL 账号体系（离线 + 微软 OAuth）             | 微软 OAuth 在 OHOS 需要原生 WebView 对接         |
| **F-5** | Mrpack / CurseForge 整合包一键安装         | 复用 v2 下载系统 + sha1 校验                    |
| **F-6** | Shaders 支持（Iris on Forge）           | 需要 LWJGL-OHOS 侧补 GL 4.0+ 翻译能力           |


---

## 四、重构建议（长期）

1. **C++ 层"去业务化"**：目前 `mc_launcher.cpp` 还在构建 classpath、写 stub jar。长期应该让 C++ 只负责"启动一个参数由 JSON 给出的 JVM"，业务完全下沉到 ArkTS 或 Java 侧。
  - 第一步已完成：JVM 兼容性参数清单已抽到 `jvm_common_args.cpp`（P0-2）。
  - 下一步：把路径生成（`-Djava.home=...`、`-Dsun.boot.library.path=...`）也交给 `LaunchProfileBuilder`，C 层纯粹透传。
2. `**sigchain.cpp` 文档化 + 单元测试**：极危险的代码不能只有口头经验。建议写一个"哪些信号交回 HotSpot、哪些自己处理"的矩阵表。
3. **统一 logging tag**：现在 `OH_LOG_`* 的 tag 混杂 `AMCL` / `AmclLauncher` / `JVM-LAUNCHER`，grep 成本高。

---

## 五、如何使用本文档

- 新需求进来前，先 check P0 有没有未完成项 —— **底座塌了做啥都是白费**。
- 每完成一项，把它从这里挪到 `archive/`（或 commit message 里提一笔）。
- P3 新功能想法，讨论清楚 DoD 再开 issue，不要直接在 main 分支摸索。