/**
 * LoaderGenerationRegistry.ets — 加载器世代注册表（唯一事实源）
 *
 * 契约见 `docs/refactor/启动世代契约规范.md`；施工过程见
 * `docs/refactor/启动架构世代化施工记录.md` §S02。
 *
 * ⚠️ **本文件只有数据与类型，没有判定规则。** 判定规则在 `LoaderGenerationResolver.ets`，
 * 契约校验在 `LaunchContractPreflight.ets`。分开的理由与渲染后端注册表同源：
 * 本表的字段是**门禁可静态校验的**（`check-launch-generation-contract.mjs`），
 * 而判定规则含 libraries 扫描这类非声明式判据，门禁校验不了 ——
 * 混在一个文件里会让"哪些字段有门禁保护"变得不可见。
 *
 * ⭐ **为什么需要这张表**：`java.class.path` 是一条被多个世代以不同方式消费的共享信道，
 * 而在本表建立之前，代码里描述世代的只有 `isForge` / `isFabric` 两个布尔 ——
 * 而 `isForge` 对 ForgeBsl / ForgeBootstrap / NeoForge / ModlauncherLegacy **四代同时为真**
 * （`neoforged` 里含 `forge`）。七元区分在二元模型里无法表达，于是 `642edf87`
 * 一次改动同时改了 7 条契约：Fabric 于 2026-08-29 倒下（`1000576`）、
 * Forge 新 bootstrap 于 2026-09-04 倒下。同形状事故本仓至少 6 次。
 *
 * 创建日期：2026-09-04
 */

/**
 * 加载器世代。**主键是 `mainClass` 的精确匹配**，不是子串包含。
 *
 * ⚠️ 子串包含正是 `isForge` 塌缩的成因（`'neoforged'.indexOf('forge') >= 0`）。
 * 新增世代时若其 mainClass 是既有值的子串/超串，必须在此处显式记下区分依据。
 */
export enum LoaderGeneration {
  /** 原版。游戏类由 `AmclClassLoader` 直接定义 —— 全仓唯一需要收窄 classpath 的世代。 */
  Vanilla = 'vanilla',
  /** 老 FML（MC ≤1.12），`launchwrapper`。靠 context ClassLoader。 */
  FmlLegacy = 'fml-legacy',
  /** 老 modlauncher（MC 1.13–1.16）。对 system CL 调 `getURLs()`。 */
  ModlauncherLegacy = 'modlauncher-legacy',
  /** Forge BootstrapLauncher（MC 1.17–1.20.1）。读 `legacyClassPath` 优先。 */
  ForgeBsl = 'forge-bsl',
  /** Forge 新 bootstrap（MC 1.20.2+）。**只读 `java.class.path`，无旁路。** */
  ForgeBootstrap = 'forge-bootstrap',
  /** NeoForge。自有启动机制。 */
  NeoForge = 'neoforge',
  /** Fabric Knot。读 `java.class.path`，除非设 `fabric.gameLibraries`。 */
  FabricKnot = 'fabric-knot',
  /**
   * 认不出来的 mainClass（整合包自定义入口 / 未来的新加载器）。
   *
   * ⭐ **它不是错误状态，是一个必须有确定行为的合法状态。** 处理方式见
   * `UNKNOWN_GENERATION_DELIVERY` 的注释 —— 那里解释了为什么它 fail 向"能启动"一侧。
   */
  Unknown = 'unknown',
}

/** 游戏 classpath 经哪条信道交付给加载器。 */
export enum ClasspathDelivery {
  /**
   * `java.class.path` 只含 `amcl-launcher.jar`；游戏 classpath 仅挂在 `AmclClassLoader`。
   *
   * **只有原版用它。** 它是 `AmclClassLoader.findClass` 字节码变换能生效的**结构前提**：
   * 游戏 jar 一旦进 `java.class.path`，内建 AppClassLoader（`AmclClassLoader` 的 parent）
   * 会因 parent-first 抢先定义游戏类，变换静默失效。
   */
  AmclLoaderOnly = 'amcl-loader-only',
  /**
   * `java.class.path` = `amcl-launcher.jar` + 完整游戏 classpath。
   *
   * ⚠️ **这就是 `642edf87` 之前的形态**（`fullCp = launcherJar + ":" + classpath`），
   * 一个带着 Forge 与 Fabric 真机跑了数月的已知可用点；同时**逐字等于**桌面端官方启动器、
   * HMCL/FCL、PojavLauncher 的启动契约。**不是新设计。**
   */
  JvmClasspathFull = 'jvm-classpath-full',
}

/**
 * 该世代**在没有声明字节码工具链版本时**的兜底取向。
 *
 * ⚠️⚠️ **这只是兜底，不是主判据。** JDK 上限的主来源是**版本自己 `libraries` 里声明的
 * ASM 版本**（逐版本实读，见 `AsmJavaSupport`）—— 实测七个版本全部声明了它，
 * 而且实读值与真机行为逐条吻合（`1.19.4-forge` 的 ASM 9.7.1 ⇒ 上限 Java 24 ⇒
 * JDK 21 可用、25 不可用，两者都是真机实证）。
 *
 * ⛔ **本字段的第一版语义是"上限 = 纪元理想那个数"，已被真机否证**：那样会把
 * "只装了 JDK 21 + 版本推荐 17 + 加载器能吃到 24"这种**合法组合**也拦掉
 * （用户实测：只装 21 选自动 ⇒ 被告知"JDK 17 未安装"而拒启）。
 * 现在它只在"该版本没声明 ASM"时生效。
 *
 * ⭐ **这个维度本身是 2026-09-04 真机崩溃逼出来的**（施工记录 §S09.3）：
 * `1.19.4-forge-45.4.5` 在 JDK 25 上启动即崩 —— 换成 JDK 17 后同一个包启动成功。
 * 因果链（A 级，日志逐字）：
 *
 * ```
 * Unsupported class file major version 69            ← major 69 = Java 25
 *   at org.objectweb.asm@9.7.1/ClassReader.<init>
 *   at modlauncher@10.0.8/ClassTransformer.transform
 *   at TransformerClassWriter.computeHierarchyFromFile ← 它要读 java.base 里的父类字节
 * ```
 *
 * 上游事实（asm.ow2.io 版本页）：ASM **9.7→Java 23**、**9.7.1→Java 24**、**9.8→Java 25**。
 * 加载器自带的 ASM 是按它发布时的 Java 编的，而它在计算类层次时**要去读 JDK 自己的
 * 类文件** ⇒ JDK 比那个 ASM 新一档，整条变换链就崩。原版没有这个问题：
 * 它不用 ASM 读 JDK 类。
 *
 * ⚠️ **刻意不记"每个 Forge 版本自带哪个 ASM"这张表** —— 那是会腐烂的数字，
 * 且无法穷举。这里只声明"该世代有没有这个约束"，上限由**游戏纪元**给出
 * （纪元要求的那个 Java 就是加载器构建时的那个 Java）。
 */
export enum JdkCeiling {
  /** 无上限：更新的 JDK 也能跑（向后兼容）。**只有原版** —— 它不用 ASM 读 JDK 类。 */
  None = 'none',
  /**
   * 没声明 ASM 时收紧到游戏纪元那一档。**所有自带字节码工具链的加载器**都是这一档。
   * ⚠️ 正常情况下走不到它（加载器版本都会声明 ASM）；它挡的是"声明缺失"这种异常数据。
   */
  GameEra = 'game-era',
}

/**
 * ⭐ **认不出世代时的交付方式：完整 classpath。**
 *
 * 这是一条**刻意 fail-open 的决策**，理由是两侧的最坏后果不对称：
 *
 * | 选 | 若猜错（其实是原版） | 若猜错（其实是某个读 java.class.path 的加载器） |
 * |---|---|---|
 * | `AmclLoaderOnly` | 正确 | **启动即崩**（本次 Forge 故障的形状） |
 * | `JvmClasspathFull` | terrain 变换静默失效 ⇒ 掉帧/卡顿 | 正确 |
 *
 * 用户的要求是"不希望单模组加载器和原版无法启动"⇒ **崩溃比掉帧严重得多**，
 * 所以未知世代倒向"能启动"。
 *
 * ⚠️ 代价必须被看见：`Unknown` 会由 preflight 产出一条 **Warn**（不是 Fail），
 * 且日志里必须能 grep 到 —— 否则"认不出来"与"认出来了"在真机上无法区分。
 */
export const UNKNOWN_GENERATION_DELIVERY: ClasspathDelivery = ClasspathDelivery.JvmClasspathFull;

/**
 * 一个世代的声明式启动契约。
 *
 * ⚠️ **这里没有"怎么判定是这个世代"** —— 那在 `LoaderGenerationResolver.ets`。
 */
export interface LoaderGenerationContract {
  generation: LoaderGeneration;
  /**
   * 判定主键：该世代的 mainClass 全集，**精确匹配**（大小写敏感）。
   * `Unknown` 是空数组（它由"没有任何一行命中"定义，不由自己的键定义）。
   */
  mainClasses: string[];
  /** 日志与诊断用名。 */
  displayName: string;
  classpathDelivery: ClasspathDelivery;
  /**
   * 是否启用 `AmclLauncher.requireIsolatedGameMain` / `AmclClassLoader.requireOwnedGameMain`。
   *
   * ⚠️ **必须与 `classpathDelivery === AmclLoaderOnly` 严格同真**（由结构不变量钉住）：
   * `JvmClasspathFull` 下游戏主类**必然**由 AppClassLoader 定义（这正是桌面端行为），
   * 两条断言在那里恒失败。⇒ 它们不是被"删掉"，是被限定到唯一成立的作用域。
   */
  isolationAsserts: boolean;
  /**
   * 是否要求 `-DlegacyClassPath=<完整 cp>` 存在且非空。
   *
   * ⚠️⚠️ **当前没有任何世代为真，这是 2026-09-04 真机取证的结果，不是遗漏。**
   * 本字段建立时给 `ForgeBsl` 填了 `true`，依据是"它的官方 JSON 自带该参数"——
   * 那是 B 级推断，**已被否证**：设备上安装的官方 `1.19.4-forge-45.4.5` 合并 JSON 里
   * `legacyClassPath` 出现 **0 次**（它用 `-p` / `--add-modules` / `-DmergeModules` /
   * `-DlibraryDirectory`，其余全靠 `-cp`），而 AMCL 自己也从未注入过它。
   * 于是这条判据把**整代 Forge 1.17–1.20.1 拒之门外**（施工记录 §S08.1）。
   *
   * 字段与判据 C4 **保留**：`legacyClassPath` 确实是 BSL 的一条真实通道（BSL README），
   * 将来若某个分发自带它、或 AMCL 自己开始注入，这条判据就是对的。
   * 当前的"全 false"由 `check-launch-generation-contract.mjs` 的
   * `PINNED_LEGACY_CLASSPATH` 棘轮钉住 —— 想改回 true 必须先拿出新的真机证据。
   *
   * ⛔ **不要给 `ForgeBootstrap` 设这个。** bootstrap 2.x 的常量池里没有
   * `legacyClassPath`（反汇编实测），设了是纯无操作。
   */
  requiresLegacyClassPathProperty: boolean;
  /**
   * 是否要求 system class loader 是 `URLClassLoader` 子类。
   *
   * 只有 `ModlauncherLegacy` 为真：modlauncher 4.x–8.x 把 system CL 当
   * `URLClassLoader` 调 `getURLs()`，JDK 9+ 的内建 AppClassLoader 不是 ⇒ 返回 null ⇒
   * 启动即崩（`1000154`）。本仓 `AmclClassLoader extends URLClassLoader` 恰好满足它。
   */
  requiresUrlClassLoaderSystemLoader: boolean;
  /**
   * 固定 JDK 主版本；空串 = 无固定要求（由既有纪元路由决定）。
   *
   * 只有 `ModlauncherLegacy` 是 `'8'`（`1000154`：路由给 17 会崩，且**回退无效**）。
   *
   * ⚠️ **消费者是 `LaunchJdkPolicy.resolveJdkPolicy`**（2026-09-04 起）。在那之前
   * 它**只有校验者没有消费者** —— `JdkManager` 自己用 `versionId.indexOf('forge')`
   * 子串规则重算了一遍，那是本仓第五份 `isForge`（施工记录 §S09.4）。
   */
  pinnedJdkMajor: string;
  /**
   * **没声明 ASM 时**的 JDK 上限兜底。见 `JdkCeiling` 的注释（那里有真机因果链与否证记录）。
   *
   * 结构不变量：**`None` ⟺ 该世代是原版**。新增世代默认必须填 `GameEra`
   * （fail-closed 方向：猜错的代价是"提示装 JDK N"，反向猜错的代价是启动即崩）。
   */
  jdkCeiling: JdkCeiling;
  /** 写给下一个读表的人，不是给 UI 的。 */
  rationale: string;
}

/**
 * 各世代的当前契约。
 *
 * ⚠️ **每一行的取值都在代码、上游产物或历史记录里有出处。**
 * 证据等级：`Vanilla` / `ForgeBootstrap` / `FabricKnot` 三行经 2026-09-04 实测（A 级）；
 * 其余行由代码与 CHANGELOG 机械推出（B 级），落地时应逐行复核（方案 §5 已记该风险）。
 */
export const LOADER_GENERATION_CONTRACTS: LoaderGenerationContract[] = [
  {
    generation: LoaderGeneration.Vanilla,
    mainClasses: ['net.minecraft.client.main.Main'],
    displayName: '原版',
    // ⭐ 全仓唯一需要收窄的世代。实测依据：26.2 原版 jar 的 PlayerChunkSender 命中
    // 钉住哈希（chunk quota patch 活）、26.3-snapshot-10 的 terrain 三件套 3/3 命中。
    classpathDelivery: ClasspathDelivery.AmclLoaderOnly,
    isolationAsserts: true,
    requiresLegacyClassPathProperty: false,
    requiresUrlClassLoaderSystemLoader: false,
    pinnedJdkMajor: '',
    jdkCeiling: JdkCeiling.None,
    rationale: '游戏类由 AmclClassLoader 定义 ⇒ 字节码变换的结构前提要求游戏 jar 不进 java.class.path',
  },
  {
    generation: LoaderGeneration.FmlLegacy,
    mainClasses: ['net.minecraft.launchwrapper.Launch'],
    displayName: '老 FML (≤1.12)',
    classpathDelivery: ClasspathDelivery.JvmClasspathFull,
    isolationAsserts: false,
    requiresLegacyClassPathProperty: false,
    requiresUrlClassLoaderSystemLoader: false,
    pinnedJdkMajor: '',
    jdkCeiling: JdkCeiling.GameEra,
    rationale: '靠 context ClassLoader 取游戏类；不读 java.class.path，给完整值与桌面端一致',
  },
  {
    generation: LoaderGeneration.ModlauncherLegacy,
    mainClasses: ['cpw.mods.modlauncher.Launcher'],
    displayName: '老 modlauncher (1.13–1.16)',
    classpathDelivery: ClasspathDelivery.JvmClasspathFull,
    isolationAsserts: false,
    requiresLegacyClassPathProperty: false,
    // modlauncher 4.x–8.x 调 ((URLClassLoader) getSystemClassLoader()).getURLs()。
    requiresUrlClassLoaderSystemLoader: true,
    // 1000154：纪元路由给 JDK 17 会崩 `urls is null`，且回退到更高 JDK 照样崩。
    pinnedJdkMajor: '8',
    jdkCeiling: JdkCeiling.GameEra,
    rationale: '对 system CL 调 getURLs() 取 classpath ⇒ 要求 URLClassLoader + JDK 8（1000154）',
  },
  {
    generation: LoaderGeneration.ForgeBsl,
    mainClasses: ['cpw.mods.bootstraplauncher.BootstrapLauncher'],
    displayName: 'Forge BSL (1.17–1.20.1)',
    // BSL 按 legacyClassPath.file > legacyClassPath > java.class.path 取值（README）。
    // AMCL 走第三条：给完整 java.class.path —— 这正是 642edf87 之前的已知可用形态。
    classpathDelivery: ClasspathDelivery.JvmClasspathFull,
    isolationAsserts: false,
    // ⛔ 曾是 true（依据"官方 JSON 自带该参数"这个 B 级推断），2026-09-04 真机否证：
    // 官方 1.19.4-forge-45.4.5 的 JSON 里该属性 0 次出现，而 AMCL 从未注入它 ⇒
    // 这条判据当时把整代 Forge 1.17–1.20.1 拒之门外（fails=1 codes=legacy-classpath-missing）。
    requiresLegacyClassPathProperty: false,
    requiresUrlClassLoaderSystemLoader: false,
    pinnedJdkMajor: '',
    jdkCeiling: JdkCeiling.GameEra,
    rationale: '读 legacyClassPath > legacyClassPath.file > java.class.path（BSL README）；'
      + 'AMCL 走第三条通道（完整 java.class.path），官方 JSON 不带前两条（2026-09-04 真机取证）',
  },
  {
    generation: LoaderGeneration.ForgeBootstrap,
    mainClasses: ['net.minecraftforge.bootstrap.ForgeBootstrap'],
    displayName: 'Forge 新 bootstrap (1.20.2+)',
    // ⭐ 本次故障的主角。反汇编 bootstrap-2.1.8：findAllClassPathEntries() 的全部实现是
    // System.getProperty("java.class.path").split(pathSeparator)，无任何其它入口；
    // selectBootModules() 只挑六个模块名，挑不到 ⇒ 模块层为空 ⇒
    // bootstrapMain:123 的 Optional.get() 抛 NoSuchElementException。
    classpathDelivery: ClasspathDelivery.JvmClasspathFull,
    isolationAsserts: false,
    // ⛔ 常量池里没有 legacyClassPath —— 设它是纯无操作，不要打开这一项。
    requiresLegacyClassPathProperty: false,
    requiresUrlClassLoaderSystemLoader: false,
    pinnedJdkMajor: '',
    jdkCeiling: JdkCeiling.GameEra,
    rationale: '只认 java.class.path 一个来源（反汇编实测），无旁路 ⇒ 必须给完整 classpath',
  },
  {
    generation: LoaderGeneration.NeoForge,
    mainClasses: ['net.neoforged.fml.startup.Client'],
    displayName: 'NeoForge',
    classpathDelivery: ClasspathDelivery.JvmClasspathFull,
    isolationAsserts: false,
    requiresLegacyClassPathProperty: false,
    requiresUrlClassLoaderSystemLoader: false,
    pinnedJdkMajor: '',
    jdkCeiling: JdkCeiling.GameEra,
    // FML 11.0.16 的 bootstrap 从 java.class.path 建立 early-service/plugin/content
    // 层；early 图形服务可能先于游戏主类消费 LWJGL。保留完整输入与上游委派边界，
    // 不能因“不读 classpath”的旧注释收窄输入或把 LWJGL 强行归到最后的游戏层。
    rationale: 'FML bootstrap 读取完整 java.class.path 建立分层加载器；保留上游公共库与 early-service 委派关系',
  },
  {
    generation: LoaderGeneration.FabricKnot,
    mainClasses: [
      'net.fabricmc.loader.impl.launch.knot.KnotClient',
      'net.fabricmc.loader.launch.knot.KnotClient',
    ],
    displayName: 'Fabric Knot',
    // 1000576 的根因：Knot.init 逐条读 java.class.path 建内部 classPath 后调
    // createGameProvider；MinecraftGameProvider.locateGame 取不到 MC_CLIENT 就 return false。
    classpathDelivery: ClasspathDelivery.JvmClasspathFull,
    isolationAsserts: false,
    requiresLegacyClassPathProperty: false,
    requiresUrlClassLoaderSystemLoader: false,
    pinnedJdkMajor: '',
    jdkCeiling: JdkCeiling.GameEra,
    rationale: '只认 java.class.path（1000576）；fabric.gameLibraries 是它的第二条通道，幂等保留',
  },
  {
    generation: LoaderGeneration.Unknown,
    // 刻意为空：Unknown 由"没有任何一行命中"定义。
    mainClasses: [],
    displayName: '未识别',
    classpathDelivery: UNKNOWN_GENERATION_DELIVERY,
    isolationAsserts: false,
    requiresLegacyClassPathProperty: false,
    requiresUrlClassLoaderSystemLoader: false,
    pinnedJdkMajor: '',
    jdkCeiling: JdkCeiling.GameEra,
    rationale: 'fail-open 到"能启动"一侧：猜错的代价是掉帧，反向猜错的代价是启动即崩',
  },
];

/** 按世代查契约。**找不到返回 undefined，调用方不得静默兜底** —— 由结构不变量保证不会发生。 */
export function loaderGenerationContract(
  generation: LoaderGeneration): LoaderGenerationContract | undefined {
  for (let i = 0; i < LOADER_GENERATION_CONTRACTS.length; i++) {
    if (LOADER_GENERATION_CONTRACTS[i].generation === generation) {
      return LOADER_GENERATION_CONTRACTS[i];
    }
  }
  return undefined;
}
