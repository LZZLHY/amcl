import preferenceSnapshotTest from './PreferenceSnapshot.test';
import runtimeCompatibilityTest from './RuntimeCompatibility.test';
import gameLaunchGateTest from './GameLaunchGate.test';
import mavenUtilsTest from './MavenUtils.test';
import pathUtilsTest from './PathUtils.test';
import versionParserTest from './VersionParser.test';
import fabricServiceTest from './FabricService.test';
// Phase 1（ARCH-1，✅ 完成 2026-05-05）：Maven 库走 NAPI 引擎
import mavenSpecBuilderTest from './MavenSpecBuilder.test';
// Phase 2（ETag 缓存）：纯函数库
import metadataCacheTest from './MetadataCache.test';
// Phase 5（下载历史）：LRU + 序列化
import downloadHistoryTest from './DownloadHistory.test';
// Phase 6.1 — TDD red：PhaseRunner 仍是 stub
import phaseRunnerTest from './PhaseRunner.test';
// Phase 6.3 — 6 个 phase 类的契约 sanity 测试
import phasesContractTest from './Phases.test';
// Phase 7（S3-4）：覆盖补齐 — VersionJsonMerger / DownloadManager 工具函数 / McDownloader.filterLibraries
import versionJsonMergerTest from './VersionJsonMerger.test';
import downloadManagerTest from './DownloadManager.test';
import mcDownloaderTest from './McDownloader.test';
// M1（账户体系骨架）：纯函数 / 纯逻辑测试
import offlineAccountTest from './OfflineAccount.test';
// M2 Phase A（Microsoft 正版登录网络层）
import microsoftOAuthTest from './MicrosoftOAuth.test';
import xboxLiveAuthTest from './XboxLiveAuth.test';
import minecraftProfileApiTest from './MinecraftProfileApi.test';
import microsoftAccountTest from './MicrosoftAccount.test';
// M2 Phase B（加密 + 共享工具）
import base64UtilTest from './Base64Util.test';
import cryptoProviderTest from './CryptoProvider.test';
// 2026-05-10 (LOG-P0-2): 日志脱敏工具
import redactTest from './Redact.test';
// 2026-05-11 (P1-MODS Phase 1.1): 模组下载子系统纯函数 / 错误类
import modTypesTest from './ModTypes.test';
// 2026-05-11 (P1-MODS Phase 1.2): Modrinth URL 构造 / facets 编码 / 响应映射
import modrinthUrlsTest from './ModrinthUrls.test';
// 2026-05-11 (P1-MODS Phase 1.3): Modrinth 源偏好决策纯函数 + 模块级状态
import modSourceProberTest from './ModSourceProber.test';
// 2026-05-11 (P1-MODS Phase 1.5): 模组安装器纯函数（文件名切换 / DownloadFileSpec 构造 / 任务名）
import modInstallerTest from './ModInstaller.test';
// 2026-05-11 (P1-MODS Phase 1.6): 搜索控制器业务逻辑（分页 / epoch / 错误处理）
import modSearchControllerTest from './ModSearchController.test';
// 2026-05-11 (P1-MODS Phase 1.6): ModCard 纯函数（下载量 / emoji / 源标签）
import modCardTest from './ModCard.test';
// 2026-05-11 (P1-MODS Phase 2.1a): CurseForge URL/响应映射纯函数
import curseForgeUrlsTest from './CurseForgeUrls.test';
// 2026-05-11 (P1-MODS Phase 2.2): ModSourceRouter 双源合并 / 排序 / fallback
import modSourceRouterTest from './ModSourceRouter.test';
// 2026-05-11 (P1-MODS Phase 2.3a): ModDependencyResolver BFS / 防环 / 已装检测
import modDependencyResolverTest from './ModDependencyResolver.test';
import modInstallContractTest from './ModInstallContract.test';
// 2026-05-11 (P0 审查修复): 已装版本目录名解析（loader 推断 + game version 提取）
import versionIdUtilsTest from './VersionIdUtils.test';
// 2026-08-12 (实体键鼠重构 Phase 3.3): 按设备 held 追踪 + 平台锁存快照
import physicalHeldKeyTrackerTest from './PhysicalHeldKeyTracker.test';
// 2026-08-20（多输入端架构改进提案 B2-b）：摇杆八向扇区判定，与 native 侧同一份规格表
import joystickSectorTest from './JoystickSector.test';
import gamepadManagerTest from './GamepadManager.test';
// 2026-08-21（提案 B1 方案 A / 计划 §63）：逐设备手柄身份表的三值语义与竞态方向
import deviceGamepadIdentityTest from './DeviceGamepadIdentity.test';
// 2026-08-21（提案 D1 / 计划 §66）：物理键鼠端抽出的两个纯判定单元
import physicalKeyEdgeTest from './PhysicalKeyEdge.test';
import wheelChannelTest from './WheelChannel.test';
// 2026-08-22（提案 D1 第 2 步 / 计划 §72）：rawDelta 存在性判定（生产与两个探针共用）
import physicalMouseMotionTest from './PhysicalMouseMotion.test';
import productInputPolicyTest from './ProductInputPolicy.test';
import gameWindowRestorePolicyTest from './GameWindowRestorePolicy.test';
import downloadFabLayoutPolicyTest from './DownloadFabLayoutPolicy.test';
import inputSurfaceContextTest from './InputSurfaceContext.test';
import textInputSessionCoordinatorTest from './TextInputSessionCoordinator.test';
// 渲染后端治理 §S2：注册表结构不变量 + 选择规则等价性
import rendererBackendResolverTest from './RendererBackendResolver.test';
// 渲染后端治理 §S3：接线的逐位等价性（新旧链路产出的 -Damcl.gl.backend 全矩阵比对）
import rendererRouteEquivalenceTest from './RendererRouteEquivalence.test';
// 2026-08-29（JDK IPv6 方案 §四·五 R2）：IPv6 偏好护栏。失效形态既不抛异常也不打告警。
import ipv6PreferenceGuardTest from './Ipv6PreferenceGuard.test';
// 2026-08-29（JDK IPv6 方案 §四·五 R3）：IPv6 错误的人话化。分类器失效形态是静默退化。
import mcErrorIpv6Test from './McErrorIpv6.test';
// 2026-08-29（Fabric classpath 回归）：Fabric 定位不到游戏本体的分类 + 抢占顺序。
import mcErrorFabricGameProviderTest from './McErrorFabricGameProvider.test';
// 2026-08-29（JDK 更新系统）：已装 JDK 与期望版本的关系判定。两个方向坏掉都不报错。
import jdkUpdatePolicyTest from './JdkUpdatePolicy.test';
// 2026-09-02：应用自动更新 24h 节流、稍后提醒与缓存红点策略。
import updateCheckPolicyTest from './UpdateCheckPolicy.test';
// 2026-09-04（启动架构世代化 §S02）：加载器世代判定 + 启动契约。
// 一个布尔值曾承载七元区分，于是同一处改动先后崩掉 Fabric 与 Forge 新 bootstrap。
import loaderGenerationContractTest from './LoaderGenerationContract.test';
// 2026-09-04（诊断收口 B1 / §S07）：Forge 新 bootstrap 拿不到游戏 classpath 的分类。
import mcErrorForgeBootstrapTest from './McErrorForgeBootstrap.test';
// 2026-09-04（诊断收口 B2 / §S07）：契约结论 → Phase 0 检查列表的映射。
import launchContractCheckTest from './LaunchContractCheck.test';
// 2026-09-04（批次 C Phase C0 / §S08）：agent 探针的注入决策，默认关。
import launchAgentProbeTest from './LaunchAgentProbe.test';
// 2026-09-04（批次 D / §S11）：JDK 选择策略。含六条真机路线的等价矩阵。
import launchJdkPolicyTest from './LaunchJdkPolicy.test';
// 2026-09-06（日志系统重构 批次 A）：「这一行算不算错误」的判据。
// 1000591 只发出去了半批，另一半就是本套钉住的东西。
import logErrorSignalTest from './LogErrorSignal.test';
import productIdentityTest from './ProductIdentity.test';
import probeRegistryTest from './ProbeRegistry.test';
// 2026-09-06（日志系统重构 P5）：导出配额分配 + 头尾截断。
// 钉的是 N-7：上传出去的正文可能一行启动器日志都没有。
import logExportBudgetTest from './LogExportBudget.test';

export default function testsuite() {
  preferenceSnapshotTest();
  gameLaunchGateTest();
  // 2026-05-04 新增：纯函数单元测试
  mavenUtilsTest();
  pathUtilsTest();
  versionParserTest();
  fabricServiceTest();

  // Phase 1（ARCH-1）：Maven 库走 NAPI 引擎 — 详见 download-system-implementation-plan.md
  mavenSpecBuilderTest();

  // Phase 2（ETag 缓存）：元数据条件请求缓存
  metadataCacheTest();

  // Phase 5（下载历史）：LRU + 序列化
  downloadHistoryTest();

  // Phase 6（PhaseRunner 抽象）
  phaseRunnerTest();
  phasesContractTest();

  // Phase 7（S3-4）：覆盖补齐
  versionJsonMergerTest();
  downloadManagerTest();
  mcDownloaderTest();

  // M1（2026-05-09）：账户体系骨架
  offlineAccountTest();

  // M2 Phase A（2026-05-09）：Microsoft 正版登录网络层
  microsoftOAuthTest();
  xboxLiveAuthTest();
  minecraftProfileApiTest();
  microsoftAccountTest();

  // M2 Phase B（2026-05-09）：加密 + 共享工具
  base64UtilTest();
  cryptoProviderTest();

  // 2026-05-10 (LOG-P0-2)：日志脱敏工具
  redactTest();

  // 2026-05-11 (P1-MODS Phase 1.1)：模组下载子系统纯函数 / 错误类
  modTypesTest();

  // 2026-05-11 (P1-MODS Phase 1.2)：Modrinth URL / 响应映射
  modrinthUrlsTest();

  // 2026-05-11 (P1-MODS Phase 1.3)：Modrinth 源偏好决策
  modSourceProberTest();

  // 2026-05-11 (P1-MODS Phase 1.5)：模组安装器纯函数
  modInstallerTest();

  // 2026-05-11 (P1-MODS Phase 1.6)：搜索控制器业务逻辑
  modSearchControllerTest();

  // 2026-05-11 (P1-MODS Phase 1.6)：ModCard 纯函数
  modCardTest();

  // 2026-05-11 (P1-MODS Phase 2.1a)：CurseForge URL / 响应映射
  curseForgeUrlsTest();

  // 2026-05-11 (P1-MODS Phase 2.2)：ModSourceRouter 双源合并 / 排序 / fallback
  modSourceRouterTest();

  // 2026-05-11 (P1-MODS Phase 2.3a)：ModDependencyResolver BFS / 防环 / 已装检测
  modDependencyResolverTest();
  modInstallContractTest();

  // 2026-05-11 (P0 审查修复)：已装版本目录名解析
  versionIdUtilsTest();

  // 2026-08-12（实体键鼠重构 Phase 3.3）：按设备 held owner + 平台锁存快照契约
  physicalHeldKeyTrackerTest();

  // 2026-08-20（提案 B2-b）：摇杆八向扇区判定。本用例与 cpp/tests/host/joystick_sector_test.cpp
  // 断言同一张规格表，任一侧偏离都会失败 —— 那套逻辑此前在三处各写一遍且无人保证一致。
  joystickSectorTest();

  // 2026-09-01：GamepadManager 离线可确定的状态安全契约。真机轴符号/型号矩阵不在此声称。
  gamepadManagerTest();

  // 2026-08-21（提案 B1 方案 A）：逐设备手柄身份表。钉住的是**方向性**契约 ——
  // Unknown 与 NotGamepad 的正确处置相反，压成两值就会漏放（用户可感知的卡键）。
  deviceGamepadIdentityTest();

  // 2026-08-21（提案 D1）：物理键鼠端的两个纯判定单元。
  // 前者钉住链路⑤ 的真实安全边界（repeat 分类错 ⇒ 修饰键**静默**失效，不是卡键）；
  // 后者钉住"两条滚轮通道符号相反"这条契约 —— 顺手统一它现在会是测试失败。
  physicalKeyEdgeTest();
  wheelChannelTest();

  // 2026-08-22（提案 D1 第 2 步）：rawDelta 存在性。它此前在 McGamePage 写了三遍，
  // 而其中两遍是**用来测这件事的探针** —— 漂移就等于探针在自己的题目上说谎。
  physicalMouseMotionTest();
  productInputPolicyTest();
  gameWindowRestorePolicyTest();
  downloadFabLayoutPolicyTest();
  inputSurfaceContextTest();
  textInputSessionCoordinatorTest();

  // 2026-08-27（渲染后端治理 §S2）：后端注册表结构不变量 + 选择规则的**等价性**钉子。
  // 钉住的不是"解析器能跑"，而是"它与被替换掉的三个带顺序依赖的 if 块在全判定矩阵上逐项相同"。
  // ⚠️ zink 相关用例是**刻意保留**的：D1 已决定它完全退役，但退役是语义变更、排在施工记录 §S6；
  // 本批是等价性重构。混批之后真机回归失败就分不清是哪一半造成的。
  rendererBackendResolverTest();
  // 2026-08-27（渲染后端治理 §S3）：接线的**逐位等价性**。它与上一条分工不同、不要合并 ——
  // 上一条钉解析器判定对不对，这一条钉"解析器 + 注入逻辑合起来产出的 jvmArgs 与改造前逐位相同"。
  // 上一条能全绿而这一条失败的典型情形：默认后端也注入了 marker（判定对、参数多了一个）。
  rendererRouteEquivalenceTest();

  // 2026-08-29（JDK IPv6 §四·五 R2）：IPv6 偏好护栏。
  // 钉的是"只补能力、不改偏好"这条取舍 —— 能力层修好之后，Mojang manifest 自带的
  // -Djava.net.preferIPv6Addresses=system 会**开始生效**，而本平台已实证存在
  // 「有 IPv6 路由但该主机 IPv6 不通」（CHANGELOG 1000467），MC/Netty 没有回退。
  // 护栏丢了不会抛异常、不会打告警，只会变成无法归因的"连服务器变慢"。
  ipv6PreferenceGuardTest();
  // 2026-08-29（JDK IPv6 §四·五 R3）：IPv6 错误的人话化。与上一条分工不同 ——
  // 上一条钉"修复本体的取舍"，这一条钉"修复之前/之外的用户看到什么"。
  // 分类器的失效形态是**静默退化**：匹配不上就落到"游戏意外退出 / 复制日志"，
  // 一条永不失败也永无信息量的结论 ⇒ 门禁全绿、真机看不出差别，只有当事用户吃亏。
  // 反向用例同等重要：形态 3 的特征（getMessage() 为 null）本身很泛，
  // 认领过宽会把无关 NPE 全吞进来，比不分类更糟。
  mcErrorIpv6Test();
  // 2026-08-29（Fabric classpath 回归）：Fabric 的 Knot 定位不到游戏本体。
  // 与上一条同属"分类器静默退化"，但这一条的代价方向不同：上一版**根本没有**这条规则，
  // 真机四次崩溃全部落到兜底「游戏意外退出」——零信息量。
  // 本套里最承重的是**抢占顺序**那三条：lwjgl_module_missing / missing_file / mod_conflict 的
  // 判据形状都能吃掉它，会分别错报成“运行时少模块”/“版本文件损坏”/“模组冲突”；
  // 后两条还会让用户重下或删模组。顺序错了不报错、门禁全绿。另有“不许过宽”用例，
  // 防止这些规则反过来把彼此的错误吞掉。
  mcErrorFabricGameProviderTest();
  // 2026-08-29（JDK 更新系统）：已装 JDK 的 release tag 与期望 tag 的关系判定。
  // 钉的是一条**双向**都会静默失效的判定：
  //   往严了坏 ⇒ 任何 tag 变更又回到「判定未安装 + 拒绝启动 + 强制重下 110 MB」，
  //             并且会让「新 HAP 先于 JDK Release 发布」直接锁死所有已装用户；
  //   往松了坏 ⇒ 已知有害的旧包（JDK 8 那个 C2 会崩的 -ohos-1）永远不被强制换掉。
  // 两个方向都不抛异常、不打告警。另含两条防手滑用例（把新 tag 误填进 harmfulTags、
  // 用户导入包恰好撞进 harmfulTags）——那两种情形会覆盖掉用户自己的包，属数据破坏。
  jdkUpdatePolicyTest();
  // 自动检查与用户「稍后」是两只独立时钟；红点不随弹窗延后而清除。
  updateCheckPolicyTest();
  // 2026-09-04（启动架构世代化 §S02）：加载器世代判定 + 启动契约校验。
  // 钉的是一条**分辨率**不变量：`java.class.path` 被 7 个世代以 7 种方式消费，
  // 而旧代码只有 isForge/isFabric 两个布尔 —— isForge 对 ForgeBsl / ForgeBootstrap /
  // NeoForge / ModlauncherLegacy 四代同时为真（'neoforged' 含 'forge'）⇒
  // "BSL 有 legacyClassPath 旁路、新 bootstrap 没有"这件事写不下来，
  // 于是 642edf87 一次改动同时改了 7 条契约（Fabric 崩于 1000576、Forge 崩于 2026-09-04）。
  // 本套里最承重的是**反向用例**：给只认 java.class.path 的世代发收窄 delivery 必须失败。
  // ⚠️ 契约表的**结构**不变量另由 scripts/check-launch-generation-contract.mjs 守 ——
  // 那道门禁不需要设备，是"提交前必然红"的唯一载体（本套只在 hvigorw test 里跑）。
  loaderGenerationContractTest();
  // 2026-09-04（诊断收口 B1）：Forge 新 bootstrap 建不出模块层的分类。
  // 与上面 mcErrorFabricGameProviderTest 是**同一根因的两条路线**（启动器把游戏
  // classpath 的交付方式弄错了），但报错形态完全不同，所以规则与用例都必须各有一份。
  // ⚠️ 本套最承重的**不是**正向那条，而是"正常 Forge 会话里模组抛的
  // NoSuchElementException 不许被认领"：`no value present` 与
  // `net.minecraftforge.bootstrap` 两个字样在任何一份该世代的日志里都在
  // （启动器每局都打一行 Loading net.minecraftforge.bootstrap.ForgeBootstrap...），
  // 只靠"全文同时命中"会把该路线上的任何 Optional 故障都吞成"启动器的错"。
  mcErrorForgeBootstrapTest();
  // 2026-09-04（诊断收口 B2）：契约结论进 Phase 0 检查列表的映射。
  // 钉的是一条**归属**错误：契约类失败此前只能从「版本文件完整性」那一项冒出来，
  // 而那一项的修复动作是删版本重下几百 MB —— 这类失败里文件是完好的。
  // 另两条方向：Warn（未识别世代）不许压成 fail（注册表刻意 fail-open 到"能启动"）；
  // 文件先失败时契约那一项必须显示"未执行"而不是绿的。
  launchContractCheckTest();
  // 2026-09-04（批次 C Phase C0）：agent 探针的注入决策。
  // 钉的是"默认关"这条声明的**行为**那一半 —— 声明值由 check-launch-agent-probe.mjs 断言、
  // 产品实际值只能从真机日志反查，三者缺一这条判据就不成立（AGENTS §二.5）。
  // 另一条：`requested=1 injected=0`（开了但拿不到 jar）必须是看得见的状态，
  // 否则真机上会出现"开关放上去了没反应"且无从归因。
  launchAgentProbeTest();
  // 2026-09-04（批次 D）：JDK 选择策略 —— 路由与 Phase 0 自检共用的那一份。
  // 起因是一条**没有被跳过、只是判据缺了一维**的自检：Phase 0 只有下限
  // （25 ≥ 17 ⇒ pass），而加载器自带的 ASM 读不了比它更新的 class file ⇒
  // `1.19.4-forge` 自检全绿然后闪退（换 JDK 17 即成功，A 级）。
  // ⭐ 本套最承重的是**等价矩阵**：改路由这种核心路径时，"新逻辑更对"不算证据，
  // "对六条已在真机上跑通的路线逐条不变"才算 —— 与渲染后端那次的
  // RendererRouteEquivalence 同一条纪律。反向那几条钉的是"上限不许被绕过"
  // （用户硬覆盖 / accepted=true / 钉住值与纪元不一致）。
  launchJdkPolicyTest();
  // 2026-09-06（日志系统重构 批次 A）：「这一行算不算错误」。
  // 起因是一个**半批**：调研 §6.4 写明「收缩帧遥测」与「收紧错误判据」必须同批做，
  // 而 1000591 只做了前一半 —— 遥测消失后，同样的 32 KB 尾窗会装进真实 MC 输出，
  // 其中就有那 7 行「剥完噪声仍被判成真实错误、但一行都不是错误」的行 ⇒
  // 健康会话被判 CRASHED（1000451 那族误报的复活）。
  // ⭐ 本套最承重的是**反向**用例：本批是在收紧判定，收紧的失效形态是**静默漏报** ——
  // 真崩溃被判成 not_diagnosable，用户看到「上次游戏已结束」，门禁全绿、无告警。
  // 另一条容易读反的是 ERROR 级那条噪声：它**确实**带级别标记，级别判定救不了它，
  // 只能靠噪声规则 —— 两个机制各管一半，删掉任一半都会让健康会话重新被判成崩溃。
  // ⚠️ 判据**数据**是否漂移由 scripts/check-log-noise-rules.mjs 守（离线、提交前必然红）；
  // 本套跑的是真实运行时，两者不可互相替代。
  logErrorSignalTest();
  // 2026-09-06（日志系统重构 P5）：导出配额与头尾截断。
  // 与上一条分工不同：上一条管「要不要判成崩溃」，这一条管「判完之后用户能拿到什么证据」。
  // 钉的是 N-7 —— 旧做法把各段拼成一整段再**保尾**截断，而拼装顺序里环境头、
  // 活动摘要、启动器日志都在前面 ⇒ 游戏日志一大它们就全被丢掉，
  // 上传出去的正文可能一行启动器日志都没有，而那是「AMCL 自己做了什么决定」的唯一记录。
  // ⭐ 两条承重：① 小而关键的段（崩溃报告几 KB）不许被 16 MB 的游戏日志挤掉；
  // ② 超配额的段保**头 + 尾** —— 启动期根因在头部、失败现场在尾部，只保一端必丢一半。
  // 失效形态是静默的：导出成功、看起来正常、只是少了最关键的那一段。
  logExportBudgetTest();
  // 2026-09-07（测试自动化 D8）：产品身份 banner 的纯函数层。
  // 钉的是"日志里能不能反查出这个包是哪条产品轨、诊断能力位实际是几"——
  // 真机探针 A7 判为不通过的那一条。承重用例是**反向**的两条：
  // 带空格的机型名不得把 `key=value` 切分冲垮、被截断的 banner 必须报出缺了哪些字段
  // （否则"解析成功但少一半"与"完整"不可区分）。
  // ⚠️ 位置约束（banner 必须在 setNativeLogSink 之后）由 check-product-identity-banner.mjs
  // 守 —— 那是源码顺序，运行时测不出来；两者不可互相替代。
  productIdentityTest();
  // 2026-09-07（测试自动化 D4）：native 探针注册表的纯模型层。
  // 承重的是"不为统一签名而包装"这条的可执行形态：`() => number` 的探针若被裹成
  // `() => string`，`0` 与 `"0"` 的区别就没了，而调用方要判的正是"是不是 0"。
  // 另两条反向用例钉住形状与运行体错配 —— 那种错配是运行期才炸，而探针"偶尔跑一次"，
  // 可能几个月都没人碰到。
  probeRegistryTest();
  runtimeCompatibilityTest();
}
