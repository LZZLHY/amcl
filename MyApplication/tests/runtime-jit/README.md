# CompletableFuture 编译策略专项

本目录包含独立 Java8/class52 夹具和只读验证器。生产自动项由 `jvmInit` 在既有 JDK
共享租约内有界读取实际 `release` 后选择：可靠的 8/17/21 不再自动排除 outer-CF，25、
未知版本、歧义字段或数字槽冲突保留原 broad。缺少 release 不新增启动失败；所有 manifest
和用户显式编译规则按原顺序保留，不自动追加 `exclude=false` 或 C2-only directive。
现有原机证据支持 JDK25 C2-dependent / CF-related 的 B+ 强关联，未闭合具体误编译
nmethod/IR/机器码；不同 major 的真实游戏与性能仍分别验收，不能从测试夹具外推。
历史依据见 [原始报告及更正](../../docs/reports/render-thread-spin-c2-completablefuture-202606.md)
和 [跨版本报告 §79、§84](../../docs/reports/2026-08-29_MC_RENDER_ARCH_ACROSS_VERSIONS.md#79-全局-completablefuture-编译排除旧版地形热路可达现代边界图仍可达)。

## 固定工作量与真实编译证明

`CompletableFutureQualification` 的 `main` 接受六个字符串：

```text
<已存在的独占证据目录> <broad|c2-only|full> 4 50000 1000000 1200
```

每个 driver 先预热 50,000 个同步依赖图，再测量 1,000,000 个相同图。四个 driver 的
测量总量为 4,000,000，checksum 由独立闭式公式核对。图实际执行
`thenApply → thenCompose → thenCombine → whenComplete → complete/join`，不是无关的算术热循环。

随后每个 driver 执行 1,200 个交错压力场景：同步图、真实线程池异步扇出与 `anyOf/allOf`、
异常身份/恢复、取消传播、128 级 compose 加 48 层回调递归 complete、三个线程竞争正常/
异常/取消终态。每图另分配保留环中的 64 KiB 数组，要求压力阶段有真实完成的 GC。
线程池在成功返回前正常终止，夹具不调用 `System.exit` 或 `Runtime.halt`。

Java 每秒写 `cf-progress.log`，仅将真正完成的图发布为单调计数，包含每个 driver 的值。
主线程 15 秒无完成进展即报告失败；这不能取代进程外监督。宿主 runner 根据真实完成计数
实施 25 秒停滞与 180 秒总 deadline，超时时仅终止自己 `Popen` 的进程，保留原件。
停滞时持续打印 heartbeat 不会重置完成进展期限。

三个编译臂：

| arm | 原 broad CompileCommand | 当前固定策略 v2 | 必须观察到的事实 |
| --- | --- | --- | --- |
| `broad` | 固定夹具显式添加 | 无 | outer-CF 全程无 nmethod，也没有进入其他 C2 编译图 |
| `c2-only` | 保留后以精确 false 覆盖（现代） | 新 v2 JSON 禁止 CF 的 C2 独立编译及进入其他 C2 图，C1 回落正常默认 | 实际 CF C1 完成方法及外部 C1 内联；无残留 C1 阻断、无 CF C2 nmethod/内联 |
| `full` | 现代追加精确 false；8在Fresh资格进程省略原条 | 现代不加载旧 full JSON | 至少三种 outer-CF 方法实际 C2 编译，含完成传播方法；测量期间有效的外部 CF C2 内联且无 legacy 残留阻断 |

旧两个JSON和历史收据保留原字节。旧full只恢复CF作为编译根的C1/C2，非CF调用者仍受原Exclude约束；旧c2-only也保留外部C1内联限制，不能按新v2含义解读旧耗时。当前`cf_policy.py`固定现代bool覆盖和新JSON，`cf_evidence.py`核VM版本、最终参数、Oracle解析结果、directive stack及每个真实nmethod的内联图。C1发码后正常晋升不被当作失败，不限制优化以维持C1存活。

`cf_evidence.py` 同时检查 VM 打印的有效 directive、完整 `LogCompilation` XML、PID、
真实 JAR SHA、预期操作数/checksum、GC、CPU/墙上时间与进展。只出现 `hotLoop` 或业务 lambda
的 C2 不算通过。保存所有 CF compile_id、入口地址、编译时间、退役和内联记录，以便失败时
继续关联 nmethod；本夹具本身不宣称已找到历史 Forge 误编译根因。

v2仅限制outer-CF的C2独立编译和内联目标；为覆盖非CF调用者，第二条匹配所有C2编译根，但inline列表只排除outer-CF，没有扩大到`$UniCompose`等嵌套类或关闭其他方法的C2。
机制依据为 [Oracle Compiler Control](https://docs.oracle.com/en/java/javase/25/vm/compiler-control1.html)。
JDK8 的固定 [CompilerOracle 源码](https://github.com/openjdk/jdk8u-dev/blob/35c254f58c70663df28cc7d15c9545c88250b6ce/hotspot/src/share/vm/compiler/compilerOracle.cpp)
使用 exclude predicate 列表，不支持这里的现代 directive；不能追加一个虚构的覆盖参数。

## 宿主入口与拒绝反例

```powershell
python tests/runtime-jit/run-cf-host.py `
  --java-home E:/Minecraft/java/jdk-17.0.12 `
  --output E:/AMCL/.workspace/run/jdk-impl-preview/cf-jit/new-host17 `
  --rounds 3
```

需要 JDK21 时可另传 `--java-home E:/Minecraft/java/jdk21`，并指定
`--javac-home E:/Minecraft/java/jdk-17.0.12`，使两个宿主执行完全相同的 class/JAR 字节。
runner 固定 class52、ZIP 条目时间与顺序，记录实际 `jvm.dll/libjvm.so`、JAR、源码 SHA。
每个 block 随机化三臂顺序，seed 和每次原始数值留在收据。JDK8 宿主只提供 broad/full 两臂，
full 在启动前不添加 broad；不会把全局 C1 当成等价的 C2-only。

所有臂使用同样的便携生产配置：ParallelGC、关闭 CompressedOops/PerfData/Attach、固定
ActiveProcessorCount=8、Xms64m/Xmx256m。不同平台不支持的 SVE/线程栈专用参数不套到宿主。
这些参数在本专项中固定，不把多项变更混进 CF 对照。CPU 指标来自实际进程管理计数，
测量墙上时间与 CPU 时间都至少 50 ms，否则该轮不提供可用性能结论。

```powershell
python tests/runtime-jit/test-cf-evidence.py `
  --full <已通过的一轮full目录> --broad <已通过的一轮broad目录> `
  --c2-only <v2的c2-only目录> --legacy-full <原full目录> `
  --legacy-c2-only <原c2-only目录> `
  --output <新的仓外反例目录>
```

派生反例保留原件并验证准确拒绝理由：没有 CF C2、C2 仅在测量后出现、测量前退役、
错 PID、错完成数、错 JAR、结果和进展冲突、XML 截断、把真实 broad 材料改标为 full。
宿主吞吐/CPU 只能描述此图和此机器，不能换算成 OHOS FPS，也不能代替 Forge 稳定性门。
v2还拒绝原真实full/C2-only的残留内联限制、缺false、伪装经典VM版本、缺外部C1/C2内联、混入实际C2图及错误directive。

## 接入现有隔离 NCP 的最小接口

由 `jdk_java_qualification.cpp` 所有者接入，本目录不修改它或主 JAR 生成器。

1. 把该 Java 源码加入现有资格 JAR 的 class52 构建，保持内嵌 JAR SHA 校验。`main` 会从
   CodeSource 读取实际合并后 JAR 的 SHA，不能传入预设成功 hash。每个 arm 必须是新的 nonce、
   新 NCP 和独占目录，不能在已建 JVM 中切换编译策略。
2. 在 `jvmInit` 前，由固定资格 profile 选择 arm，追加
   `-XX:+LogCompilation`、`-XX:LogFile=<runPath>/compilation.xml`；现代全部臂打印directive，非broad追加精确`-XX:CompileCommand=exclude,java/util/concurrent/CompletableFuture.*,false`，仅c2-only写入固定v2 JSON并追加`-XX:CompilerDirectivesFile=<runPath>/directives.json`。full不加载旧JSON。
   所有臂保持相同的 `-Xcheck:jni`、GC、堆和其他参数。不能接受 Want 任意 JVM 参数或任意路径。
3. 三个固定测试臂均在 Fresh 工具进程通过 TestHooks 省略生产自动 CF 项，再显式组装上表
   的完整规则；JDK8 full 不添加 broad。这样生产默认按 major 改变时，旧实验仍保持同一含义。
   8 的 C2-only 明确 `NOT-SUPPORTED`，不退回 `TieredStopAtLevel=1` 冒充。
4. 调 `jvmCallMain("CompletableFutureQualification", 6, args)`，要求返回 0；现有 RuntimeQualification
   可继续执行，但完整资格必须等待真实 `DestroyJavaVM` 和子进程退出。XML 只在 JVM 正常关闭后
   验收，不拼接超时截断文件。NCP 的官方 KillChildProcess/退出事件拥有者承担硬超时；安装、
   解压与本专项的总预算应显式记录，不能因为 Java heartbeat 活跃而无限延期。
5. 回收 `cf-progress.log`、`cf-result.properties`、`stdout.log`、`compilation.xml`、实际资格 JAR，
   以及现有 native archive/JVM/退出身份收据。校验器默认找 `cf-qualification.jar`；合并 JAR
   可在收集目录中以该名字保存同一字节副本，SHA 必须等于实际 `qualification.jar`，不是重打包。

```powershell
python tests/runtime-jit/cf_evidence.py --evidence <回收目录> `
  --arm full --report <新的报告路径>
```

同 JDK 的 broad/c2-only/full 每臂至少三个交错 block，实际设备、JVM SHA、HAP SHA、JAR SHA、
工作量与其他 JVM 参数必须匹配。先通过计数/终态/编译门，再比较 `wallNanos/operations` 和
`cpuNanos/operations`。新旧 JDK 是另一个因子，不能把不同 JDK 的一轮数据直接归因于 CF 开关。

## 已核实的真实游戏 A/B 接口和缺口

从版本详情设置“单版本自定义 JVM 参数”，沿正常 UI 启动游戏并执行约定路线。
本目录的 `capture-runtime-process.mjs` 可采集 5–300 秒的 PID 与 hilog 作为运行时旁证。
帧率和各臂工作量分别按下面的游戏内计量步骤记录。

具体链路已读源码：`PreferenceManager.getVersionOverride/setVersionOverride` 保存在
`verLaunch.<versionId>`；`resolveLaunch` 将全局参数置前、单版本参数置后；
`McGamePage` 调 `LaunchProfileBuilder.setCustomJvmArgs`，后者 `mergeUserJvmArgs` 合入
`extraJvmArgs`，Native 在 common args 后追加。只修改测试版本的 `customJvmArgs` 并保存原值，
不要覆盖 xmx/JDK/语言字段。现代 JDK 的 directive 可走该已有路径，不需要产品新开关。

同一个实际验证过的绝对证据路径下，各臂均追加以下观察参数：

```text
-XX:+CompilerDirectivesPrint
-XX:+LogCompilation
-XX:LogFile=<本轮独占可写路径>/compilation.xml
-Damcl.graphics.observation=1
```

broad保留原规避；现代full另追加精确`-XX:CompileCommand=exclude,java/util/concurrent/CompletableFuture.*,false`，不加载directive；现代c2-only在该false之后追加`-XX:CompilerDirectivesFile=<应用已验证可读路径>/directives.json`，正文必须为本目录固定v2文件。所有臂其余诊断相同。该C2-only固定inline列表仅用于已确认没有额外用户inline/dontinline/CompileOnly规则的测试实例，不能悄悄覆盖用户规则。观测参数在
`jvm/mc_launcher.cpp` 转为 `AMCL_GRAPHICS_OBSERVATION`，由 `platform/graphics_observation.cpp`
消费；不要向 hdc shell 设置环境变量冒充应用已启用。`McGamePage.collectGraphicsMetrics_`
每五秒记录 `graphics_frame_stats` 和 `graphics_present`，包含 PID、profile、presentCount、
P50/P95/P99、长帧、丢样和窗口/前后台边界。它明确只测 present interval/swap call，
GPU 时间、CPU render 时间、upload 时间字段为 null，不能填成已有数据。

有界游戏验收按下面的实际边界执行：

- 原回归场景是 MC1.21.8 + Forge58.1.18 + JDK25；先从目标设备确认版本/模组/资源实际存在并冻结
  hash，不能根据历史文档声称当前平板已安装。原失败设备为 Mate70/API20，当前 API26 平板通过
  仍不能替代后续手机门。至少重复穿过 parallel mod lifecycle、标题画面和正常退出，不把进程存活
  或 EarlyDisplay 有帧单独视为 lifecycle 完成。
- broad 与 C2-only 先做相同版本十组交错启动；full 作为受监督诊断臂。固定总启动期限，首次
  进入真实游戏呈现后的 30 秒无新增 present 判停滞，同时保留 lifecycle 日志与对应线程 CPU。
  早期 mod 加载不能仅因还未首帧判失败；EarlyDisplay 帧也不能代替 Render thread 的完成事实。
  在执行候选前必须由负责人验证进程外终止路径、PID身份/退出观察，并使用独立 QA 世界；
  当前只读采集器不具备这条能力，未接好监督时 full 游戏臂记 `NOT-RUN`。
- 旧版 terrain 性能分别跑1.18.2/1.20.1，明确 vanilla/Fabric/Sodium 实际渲染实现，不混用静态
  vanilla callsite 与 Sodium 运行结果。固定 world 副本、route、options、渲染后端、HAP/JDK、
  缓存冷热状态、分辨率与温度窗口；同一个配对 block 只改变 CF 策略。现无固定路线非 UI 自动化，
  应由人工执行并留输入/视频证据，路线或温度不匹配的 block 不用于因果比较。
- 同步采已存在的真实 present 指标和 OS 进程/线程 CPU。section admitted/completed/cancelled、
  upload queue、边界 full-update 的逐事件计数并非上述现有观测器提供；缺失时明确记录，
  不能声称已闭合具体 terrain 机制。强制结束是失败/监督退出，不是正常关闭。

只有实际 Forge 稳定性与设备性能两个门都通过，才讨论默认策略收窄。夹具通过不会自动移除
规避；若 full 失败，保存实际进展停止点、完整或截断编译日志、compile_id/PC 与产物 SHA，
继续定位具体 nmethod，而不是继续扩大解释执行范围。

## 其他固定 VM 开关：只读盘点

| 当前参数 | 已读到的依据与缺口 | 后续最小独立验证 |
| --- | --- | --- |
| `ActiveProcessorCount=8` | 生产注释仍称修好饥饿黑屏；报告明确8核没有修好该黑屏。固定8不代表所有设备实际可用并行度 | 同设备记录实际 affinity/核数、Java availableProcessors、负载与线程池吞吐，再单独比较默认探测/明确配置 |
| `-UseCompressedOops` | 当前注释仅称简化 safepoint；本轮未取得必须全局关闭的精确运行证据 | 新JDK单独做对象/GC/内存布局压力与真实游戏比较，读取实际启用状态；不能和CF同时改 |
| `-UsePerfData` | 原因为默认临时目录不可写；不等于所有应用可写临时路径均不可用 | 明确 HotSpot 实际 perf 路径、权限/文件生命周期与开销；不能只改 java.io.tmpdir 就声称已解决 |
| `+DisableAttachMechanism` | 当前为减少临时路径依赖；attach影响诊断能力，尚无本轮实际可用性证明 | 独立资格进程先验证实际socket/文件权限和完整请求响应，不先打开产品默认 |
| processor `TieredStopAtLevel=1` | `fork_run_java.cpp` 明确暂保留；历史 safepoint 夹具已指出此路径不能证明C2 | 经修复JDK，用真实Forge processors比较C2正确性、退出与耗时；CF夹具不能替代安装事务/processor门 |

以上非 CF 默认没有随本次条件策略修改；仍须各自核实，不把不同开关的效果混入 CF 比较。
