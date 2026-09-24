/**
 * PreLaunchValidator.ets — 启动前硬校验（在创建 JVM 之前）
 *
 * 背景：原先的 JIT 校验发生在 jvmInit 内部（JVM 创建途中），失败时已经进了启动
 * 流水线，用户点返回仍要杀一次进程才能脱身。本模块把所有"必须通过才允许启动"的
 * 校验前置到【点击启动游戏的那一刻、navigate / 创建 JVM 之前】，任一不过就不启动，
 * 用户停留在启动器、零进程开销。
 *
 * 校验项（顺序执行，任一失败即拦截）：
 *   1. JIT 可执行内存   —— testNapi.checkJitAvailable()（裸 mmap RWX 探测，不创建 JVM）
 *   2. JDK 版本匹配     —— 复用 JDK 路由区间，保留既有上限拒绝与低版本调试确认
 *   3. 运行时环境       —— JDK 完整性（libjvm/libjli/lib/modules，由调用方注入 isInstalled
 *                          结果）+ LWJGL OHOS jar 是否已部署
 *   4. 版本文件完整性   —— 复用 LaunchProfileBuilder.build()（version.json / 主 jar /
 *                          依赖库齐全性 + ZIP 头校验 + Forge 产物校验 + 损坏自动清理），
 *                          这是最重要的一项，直接拿启动真正要用的构建器来验
 *   5. 启动契约         —— 复用**同一次** build() 的契约留痕（加载器世代 / classpath
 *                          交付方式），不重新判定、不重新 build。见 runProfileChecks
 *   6. 游戏资源完整性   —— 核对 assets 索引与缺失比例，保留原有小量缺失容忍
 *   7. 模组安装状态     —— 仅等待安装完成、恢复 AMCL 中断的文件事务；模组依赖与
 *                          兼容性由实际加载器处理，不在启动器中再次解析或裁决
 *
 * 设计取向：纯逻辑、无 UI、无服务实例耦合——JDK 安装状态由调用方（持有 JdkManager 的
 * Index）以布尔值注入，便于单测与解耦。UI 编排（逐项点亮 / 失败拦截）在
 * components/PreLaunchCheckSheet.ets。
 *
 * 注：现有 jvmInit 里的 JIT 兜底校验【保留不删】——多一道防线总是好的（用户要求）。
 */

import { launchNative } from './LaunchNativeBridge';
import { modInstallationActive, normalizeModDirectory, recoverModTransaction, withModDirectoryLock } from 'mods';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LaunchProfileBuilder, LaunchProfile } from './LaunchProfileBuilder';
import { VersionFileVerifier, AssetsCheckResult, VersionParser } from 'feature_core';
import { fileIo as fs } from '@kit.CoreFileKit';
import { GraphicsGameFacts, graphicsGameFacts } from './GraphicsGameFacts';
import { verifyLwjglRuntimeSlot, LwjglSlotIntegrityResult } from './LwjglSlotIntegrity';
import { lwjglGenerationDirectory } from './RuntimeSlotGenerations';
import {
  LaunchContractReport, describeLaunchContractViolations, describeLaunchContractWarnings,
} from './LaunchContractPreflight';
// JDK 区间判据与文案。**与路由同源**（同一个 `JdkRange`），所以自检认可的
// 与路由选出来的不可能是两回事 —— 那正是 2026-09-04 那次全绿闪退的成因。
import {
  JdkRange, classifyJdkChoice, describeAboveMax, describeNotPreferred,
  isJdkRangeEmpty, describeEmptyJdkRange, hasJdkDownloadCandidate, describeUnavailableJdkRuntime,
} from './LaunchJdkPolicy';

const TAG = 'PreLaunchValidator';

/** 单项校验状态。pending=未开始，running=进行中，pass=通过，warn=警告（不阻断，需用户确认），fail=不通过。 */
export type PreLaunchStatus = 'pending' | 'running' | 'pass' | 'warn' | 'fail';

/** 一项校验的结果（UI 直接渲染）。 */
export interface PreLaunchCheck {
  /** 稳定 id：'jit' | 'jdk' | 'runtime' | 'files' | 'contract' | 'assets' | 'mod_install_state' */
  id: string;
  /** 展示标题 */
  title: string;
  /** 当前状态 */
  status: PreLaunchStatus;
  /** 结果说明（通过的简述 / 失败的可读原因，可直接展示给用户） */
  detail: string;
  /**
   * 失败时关联的修复动作（由上层 Sheet → Index 路由）：
   *   - 'open_jdk_manager' → 设置 Tab / JDK 管理（下载或修复 JDK）
   *   - 'redownload'       → 下载 Tab（重新下载该版本文件）
   *   - ''                 → 无一键修复（仅文字提示，如 JIT 权限受限）
   */
  fixActionKey: string;
}

/** 校验所需的上下文（全是 primitive，便于 @Prop 传递）。 */
export interface PreLaunchInput {
  filesDir: string;
  mcDir: string;
  gameDir: string;
  version: string;
  jdkVersion: string;
  xmxMb: number;
}

/**
 * `files` 与 `contract` 两项的一次性产出。
 *
 * ⭐ **它们必须由同一次 `build()` 得出，所以只能一起返回。** 分成两个公开方法各调一次
 * `build()`，会让同一次启动做两遍完整的 version.json 解析 + classpath 组装 + ZIP 头校验。
 */
export interface LaunchProfileChecks {
  files: PreLaunchCheck;
  contract: PreLaunchCheck;
}

export class PreLaunchValidator {
  /** 各项校验的初始（pending）列表，供 UI 首次渲染占位。JDK 版本匹配紧跟 JIT 之后。 */
  static pendingChecks(): PreLaunchCheck[] {
    return [
      { id: 'jit',      title: 'JIT 可执行内存', status: 'pending', detail: '等待检查…', fixActionKey: '' },
      { id: 'jdk',      title: 'JDK 版本匹配',   status: 'pending', detail: '等待检查…', fixActionKey: '' },
      { id: 'runtime',  title: '运行时环境',     status: 'pending', detail: '等待检查…', fixActionKey: '' },
      { id: 'files',    title: '版本文件完整性', status: 'pending', detail: '等待检查…', fixActionKey: '' },
      // 契约紧跟文件之后：两项同源于一次 build()，而契约校验发生在文件校验**之后**
      // （文件不全时根本走不到它）⇒ 这个顺序就是因果顺序。
      {
        id: 'contract', title: PreLaunchValidator.CONTRACT_TITLE,
        status: 'pending', detail: '等待检查…', fixActionKey: '',
      },
      { id: 'assets',   title: '游戏资源完整性', status: 'pending', detail: '等待检查…', fixActionKey: '' },
      { id: 'mod_install_state', title: '模组安装状态', status: 'pending', detail: '等待检查…', fixActionKey: '' },
    ];
  }

  /** `contract` 项的展示标题。占位与各结论分支共用一处，避免同一项在 UI 上换名字。 */
  private static readonly CONTRACT_TITLE = '启动契约';

  /**
   * 在游戏启动前确认 AMCL 自己的模组文件事务已经结束。
   *
   * 输入只使用实例的 gameDir；不读取加载器环境，也不扫描 JAR 或求解依赖。真实加载器
   * 才掌握整合包覆盖配置、嵌套模组和自身版本规则，启动器不得用不完整规则提前拒启。
   * 原版与模组实例走同一恢复流程，避免切换加载器后遗留未提交的文件事务。
   *
   * 活动安装返回 fail，用户等待下载完成后重试；遗留事务在原有目录锁内恢复，恢复失败
   * 仍返回 fail 并完整保留原始原因，防止把半提交目录交给游戏。这里只复用事务模块的
   * 恢复/清理语义，不把“已有终态但暂存清理待重试”再次解释成兼容性或启动错误。
   */
  static async runModInstallState(input: PreLaunchInput): Promise<PreLaunchCheck> {
    const result: PreLaunchCheck = {
      id: 'mod_install_state', title: '模组安装状态', status: 'pass',
      detail: '模组安装状态正常', fixActionKey: '',
    };
    try {
      // 活动计数使用规范化路径；检查与加锁必须使用同一个 key，含尾斜杠的 gameDir
      // 也不能绕过正在进行的安装。加锁同步登记后才让出执行，沿用现有互斥边界。
      const dir = normalizeModDirectory(input.gameDir + '/mods');
      if (modInstallationActive(dir)) throw new Error('此版本正在安装或更新模组，请等待完成后启动');
      await withModDirectoryLock<void>(dir, async (): Promise<void> => {
        await recoverModTransaction(dir);
      });
    } catch (e) {
      result.status = 'fail';
      result.detail = (e as Error).message || '未能确认模组安装状态，请重试并检查启动器日志。';
    }
    return result;
  }

  /**
   * 资源缺失容忍阈值：缺失对象占比超过此值才判失败。
   * 取值理由：缺一两个 asset（某个音效/语言文件）不影响进游戏，强行拦截反而扰民；
   * 但"assets 整个没下载/索引丢失/大面积缺失"必须拦。5% 是经验阈值（PCL 这类启动器
   * 也是"缺太多才提示补全"）。索引文件本身缺失则无条件失败。
   */
  private static readonly ASSETS_MISSING_FAIL_RATIO = 0.05;

  /**
   * 校验 2（紧跟 JIT）：JDK 版本匹配。
   *
   * ⭐ **判据是一个区间 `[min, max]`，四种结论各有各的处置**（施工记录 §S09.3 / §S12）：
   *
   * | 结论 | 判据 | 处置 |
   * |---|---|---|
   * | `ok` | 等于推荐值 | pass |
   * | `ok-not-preferred` | 在区间内但不是推荐值 | **pass + 说明，绝不阻塞** |
   * | `above-max` | 越过加载器自带 ASM 能读的上限 | **fail**（`accepted` 也不放行） |
   * | `below-min` | 低于游戏字节码要求 | warn（保留调试通道） |
   *
   * 两处非对称都是被真机逼出来的：
   * ① **过高必须 fail** —— 后果是启动即崩且崩在指不到真因的地方
   * （`Unsupported class file major version` 出现在 modlauncher 建类层次时）；
   * ② **可用但非推荐必须 pass** —— 第一版把"推荐"当成"唯一"，于是
   * "只装了 JDK 21 + 版本推荐 17 + 加载器能吃到 24"这种合法组合被拒启（用户实测）。
   *
   * @param jdkVersion 本次将使用的 JDK 版本号（已路由出的具体版本）
   * @param range      该版本的 JDK 可用区间（`JdkManager.jdkRangeFor`，与路由**同源**）
   * @param accepted   用户是否已点击"保留并继续"（只对 `below-min` 生效，**不能**放行 fail）
   */
  static runJdk(jdkVersion: string, range: JdkRange, accepted: boolean): PreLaunchCheck {
    // 空区间是游戏下限与加载器能力冲突，不是“缺一个可下载的 JDK”。
    // 必须在空字符串/非数字宽容路径之前判断，也不能被调试确认 accepted 放行。
    // 返回空修复动作以避免引导用户下载一个仍违反另一端约束的运行时。
    if (isJdkRangeEmpty(range)) {
      return { id: 'jdk', title: 'JDK 版本匹配', status: 'fail',
        detail: describeEmptyJdkRange(range), fixActionKey: '' };
    }
    // 没有合法已装候选且产品没有对应发布槽时，自动选择返回空。
    // 只拒绝该“没有选择”的状态；已选中的合法自编/停发运行时不因发布集合为空被误拒。
    if (jdkVersion.length === 0 && !hasJdkDownloadCandidate(range)) {
      return { id: 'jdk', title: 'JDK 版本匹配', status: 'fail',
        detail: describeUnavailableJdkRuntime(range), fixActionKey: '' };
    }
    let major = parseInt(jdkVersion, 10);
    // 无法判定（jdk 非数字）→ 通过，不打扰
    if (isNaN(major)) {
      return { id: 'jdk', title: 'JDK 版本匹配', status: 'pass', detail: 'JDK ' + jdkVersion, fixActionKey: '' };
    }
    let verdict = classifyJdkChoice(major, range);
    // ⭐ 越上限：**fail 且不受 accepted 影响** —— 没有"我知道风险，继续"的合理场景，
    // 越界必崩且崩在指不到真因的地方（Unsupported class file major version）。
    if (verdict === 'above-max') {
      return {
        id: 'jdk', title: 'JDK 版本匹配', status: 'fail',
        detail: describeAboveMax(range, major),
        fixActionKey: 'jdk_mismatch',
      };
    }
    // ⭐⭐ **可用但不是推荐值 ⇒ pass + 说明，绝不阻塞。**
    // 这一条是被真机否证过一次的地方：第一版把"推荐"当成"唯一"，于是
    // "只装了 JDK 21 + 版本推荐 17 + 加载器能吃到 24"这种**合法组合**被拒启。
    if (verdict === 'ok-not-preferred') {
      return {
        id: 'jdk', title: 'JDK 版本匹配', status: 'pass',
        detail: describeNotPreferred(range, major),
        fixActionKey: '',
      };
    }
    if (verdict === 'ok') {
      let upper = range.maxMajor > 0 ? ('，上限 Java ' + range.maxMajor) : '';
      return {
        id: 'jdk', title: 'JDK 版本匹配', status: 'pass',
        detail: 'JDK ' + jdkVersion + ' 适配当前版本（要求 ≥ Java '
          + range.minMajor + upper + '）',
        fixActionKey: '',
      };
    }
    // 以下是 below-min。沿用旧语义：warn（保留"我知道风险，继续"的调试通道）。
    let requiredMajor = range.minMajor;
    // 不匹配：为该版本强制指定了过低的 JDK
    if (accepted) {
      return {
        id: 'jdk', title: 'JDK 版本匹配', status: 'warn',
        detail: '已确认以 JDK ' + jdkVersion + ' 启动（低于该版本建议的 JDK ' + requiredMajor
          + '，可能无法正常运行，仅供调试）。',
        fixActionKey: '',
      };
    }
    return {
      id: 'jdk', title: 'JDK 版本匹配', status: 'warn',
      detail: '此版本为其单独指定了 JDK ' + jdkVersion + '，但它建议 JDK ≥ ' + requiredMajor
        + '。可一键改用自动选择，或坚持以此 JDK 启动（调试用，可能崩溃）。',
      fixActionKey: 'jdk_mismatch',
    };
  }

  /**
   * 校验：JIT / 可执行内存（RWX mmap）。
   * 直接调 native 的裸 mmap 探测，不创建 JVM。失败 = 设备/系统不允许可写可执行内存
   * （缺 ohos.permission.ALLOW_WRITABLE_CODE_MEMORY），HotSpot 无法运行。
   */
  static runJit(): PreLaunchCheck {
    let ok = false;
    try {
      ok = launchNative().checkJitAvailable();
    } catch (e) {
      hilog.warn(0x0000, TAG, 'checkJitAvailable threw: %{public}s', (e as Error).message);
      ok = false;
    }
    return {
      id: 'jit',
      title: 'JIT 可执行内存',
      status: ok ? 'pass' : 'fail',
      detail: ok
        ? '可分配 RWX 内存，HotSpot JIT 可用'
        : '无法分配可读写可执行内存（RWX）。当前设备/系统缺少 ALLOW_WRITABLE_CODE_MEMORY 权限，JVM 无法创建，因此不启动游戏。',
      fixActionKey: '',
    };
  }

  /**
   * 校验 3：运行时环境完整性。
   * @param input        启动上下文
   * @param jdkInstalled 调用方（Index）用 JdkManager.isInstalled(jdkVersion) 算好注入，
   *                     避免本纯函数耦合服务实例。
   */
  static async runRuntime(input: PreLaunchInput, jdkInstalled: boolean): Promise<PreLaunchCheck> {
    // 3a. JDK 完整性（isInstalled 已含 marker + libjvm.so/libjli.so/lib/modules 探针）
    if (!jdkInstalled) {
      return {
        id: 'runtime',
        title: '运行时环境',
        status: 'fail',
        detail: 'JDK ' + input.jdkVersion + ' 未安装或不完整。该版本运行需要它，可在此一同下载并安装（JDK ' + input.jdkVersion + ' 由当前 MC 版本自动匹配）。',
        fixActionKey: 'download_jdk',
      };
    }
    // 从同一份已安装合并清单取得与 builder 相同的世代事实，不按目录显示名猜测。
    // 未选中的槽完全不参与本局校验；缺失/未合并清单不得被当成现代槽已准入。
    const parsed = VersionParser.parse(input.mcDir + '/versions/' + input.version + '/' + input.version + '.json');
    if (parsed === null || parsed.inheritsFrom.length > 0) {
      return { id: 'runtime', title: '运行时环境', status: 'fail',
        detail: '无法从完整的已安装版本清单确定 LWJGL 运行槽，请先修复版本清单。', fixActionKey: 'redownload' };
    }
    const facts: GraphicsGameFacts = graphicsGameFacts(parsed.libraries, input.version);
    const directory: string = facts.lwjglVersion === 2 ? 'lwjgl-ohos-2'
      : (facts.needsLwjgl322Slot ? 'lwjgl-ohos-322' : 'lwjgl-ohos');
    const integrity: LwjglSlotIntegrityResult = await verifyLwjglRuntimeSlot(lwjglGenerationDirectory(input.mcDir, directory));
    if (!integrity.ok) {
      return { id: 'runtime', title: '运行时环境', status: 'fail',
        detail: integrity.detail, fixActionKey: '' };
    }
    return {
      id: 'runtime',
      title: '运行时环境',
      status: 'pass',
      detail: 'JDK ' + input.jdkVersion + ' 已安装 · ' + integrity.detail,
      fixActionKey: '',
    };
  }

  /**
   * 校验 3 + 4：版本文件完整性与启动契约，**由同一次 `build()` 产出**。
   *
   * 文件那半直接拿启动真正要用的 `LaunchProfileBuilder` 来验——它内部会做：
   *   version.json 解析 → classpath 组装 → 缺失/空 jar 检测 → ZIP 头(PK)校验拦截
   *   CDN 错误页伪装的 jar → Forge processor 产物校验（并自动清理损坏文件）→
   *   **加载器世代判定 + 启动契约校验**（规范 §1.1、§3.3）。
   * 主 jar 的 SHA1 是额外一道（对齐成熟启动器）：hash 一个几十 MB 的文件开销可控，
   * 足以抓出"ZIP 合法但内容错配"的主 jar；version.json 没声明期望 sha1 时跳过，
   * 不因"无元数据可验"而误判失败。
   *
   * 注：`build()` 不依赖账户信息（username/uuid/token 有默认占位），文件与契约校验都与
   * 账户无关，因此这里用占位账户即可；真正启动时 McGamePage 会带真实账户再 build 一次。
   */
  static async runProfileChecks(input: PreLaunchInput): Promise<LaunchProfileChecks> {
    let builder = new LaunchProfileBuilder()
      .setFilesDir(input.filesDir)
      .setMcDir(input.mcDir)
      .setGameDir(input.gameDir)
      .setVersion(input.version)
      .setJdkVersion(input.jdkVersion)
      .setXmxMb(input.xmxMb);
    let profile: LaunchProfile | null = builder.build();
    let report: LaunchContractReport | null = builder.getLastContractReport();

    let files = PreLaunchValidator.versionFilesCheck(
      profile, builder.getLastBuildError(), report);
    if (files.status !== 'fail') {
      files = await PreLaunchValidator.withMainJarSha1(input, files);
    }
    return {
      files: files,
      contract: PreLaunchValidator.contractCheck(report, files.status !== 'fail'),
    };
  }

  /**
   * 由一次 `build()` 的产物推导「版本文件完整性」这一项（纯函数，无 IO）。
   *
   * ⭐ **承重分支：`build()` 返回 null 但契约留痕说是契约失败 ⇒ 这一项是 `pass`。**
   * 契约校验排在 `build()` 的最后，走到它就意味着 version.json、主 jar、依赖库、
   * ZIP 头、Forge 产物**全部已经通过**。旧实现把这种失败一律写成"版本文件校验失败"
   * 并给 `redownload` —— 用户会删掉版本重下几百 MB，而文件本来就是好的，
   * 重下之后一模一样。契约类失败由 `contract` 那一项指名道姓地报。
   */
  static versionFilesCheck(profile: LaunchProfile | null, buildError: string,
                           report: LaunchContractReport | null): PreLaunchCheck {
    let entries = 0;
    if (profile) {
      entries = profile.classpath.length > 0 ? profile.classpath.split(':').length : 0;
    } else if (report && !report.verdict.ok) {
      entries = report.gameClasspathEntries;
    } else {
      return {
        id: 'files',
        title: '版本文件完整性',
        status: 'fail',
        detail: (buildError && buildError.length > 0)
          ? buildError
          : '版本文件校验失败（version.json / 主 jar / 依赖库不完整）。',
        fixActionKey: 'redownload',
      };
    }
    return {
      id: 'files',
      title: '版本文件完整性',
      status: 'pass',
      detail: '主 jar / version.json / 依赖库齐全（classpath ' + entries + ' 项）',
      fixActionKey: '',
    };
  }

  /**
   * 由**同一次** `build()` 的契约留痕推导「启动契约」这一项。
   *
   * 纯函数：这里只做 verdict → UI 的映射，**判定不在这里** ——
   * 它在 `LaunchContractPreflight.evaluateLaunchContract`，重新实现一份就等于允许两份判定漂移。
   *
   * @param report      `LaunchProfileBuilder.getLastContractReport()`；null = 没走到契约校验
   * @param filesPassed 文件那一项是否通过（用于区分两种 null，见下）
   *
   * 五种情形，**`pending` / `warn` / `pass` 刻意不合并**：
   *   - 有 Fail                    ⇒ `fail`，detail 逐条列出违约（阻断启动）
   *   - 只有 Warn（unknown-generation）⇒ `warn`，**不阻断**（注册表刻意 fail-open 到"能启动"）
   *   - 无违约                     ⇒ `pass`，写明世代与交付方式
   *   - null 且文件校验失败        ⇒ `pending`（"没校验"不是"校验通过"，本仓 `1000544` 那一族）
   *   - null 但文件校验通过        ⇒ `warn`（结构上不该发生；不阻断，但必须看得见）
   */
  static contractCheck(report: LaunchContractReport | null,
                       filesPassed: boolean): PreLaunchCheck {
    if (!report) {
      return filesPassed
        ? {
            id: 'contract', title: PreLaunchValidator.CONTRACT_TITLE, status: 'warn',
            detail: '未取得启动契约校验结果（内部不一致：版本文件已通过，却没有契约留痕）。'
              + '启动不受阻断，但请把日志反馈给开发者。',
            fixActionKey: '',
          }
        : {
            id: 'contract', title: PreLaunchValidator.CONTRACT_TITLE, status: 'pending',
            detail: '版本文件校验未通过，本次未进行启动契约校验。',
            fixActionKey: '',
          };
    }
    const verdict = report.verdict;
    if (!verdict.ok) {
      return {
        id: 'contract',
        title: PreLaunchValidator.CONTRACT_TITLE,
        status: 'fail',
        // ⚠️ fixActionKey 刻意留空：这一类失败**没有**用户侧的修复动作。
        // 给 redownload 是有害的（文件是好的），给 open_jdk_manager 只对
        // jdk-major-mismatch 这一条成立。指名道姓 + 重试/取消才是诚实的界面。
        detail: '启动契约校验失败（' + report.displayName + '）：\n'
          + describeLaunchContractViolations(verdict),
        fixActionKey: '',
      };
    }
    let warnText = describeLaunchContractWarnings(verdict);
    if (warnText.length > 0) {
      return {
        id: 'contract',
        title: PreLaunchValidator.CONTRACT_TITLE,
        status: 'warn',
        // 措辞刻意与具体 warn 无关：今天只有 unknown-generation 这一条，
        // 但把"已按完整 classpath 启动"写死会在下一条 warn 出现时变成假话。
        detail: warnText + '\n启动不阻断（本次 classpath 交付方式 ' + report.delivery + '）。',
        fixActionKey: '',
      };
    }
    return {
      id: 'contract',
      title: PreLaunchValidator.CONTRACT_TITLE,
      status: 'pass',
      detail: '已识别为「' + report.displayName + '」· classpath 交付方式 '
        + report.delivery + '（' + report.gameClasspathEntries + ' 项）',
      fixActionKey: '',
    };
  }

  /**
   * 给已通过的「版本文件完整性」再叠一道主 jar SHA1（异步，需要读文件）。
   * hash 计算异常（极少见）时不阻断启动，沿用存在性校验的结论。
   */
  private static async withMainJarSha1(input: PreLaunchInput,
                                       base: PreLaunchCheck): Promise<PreLaunchCheck> {
    let meta = VersionFileVerifier.readMeta(input.mcDir, input.version);
    if (meta.clientSha1.length === 0) {
      return base;   // 无期望 sha1，保持存在性校验的通过结论
    }
    let jarPath = input.mcDir + '/versions/' + input.version + '/' + input.version + '.jar';
    try {
      let actual = (await VersionFileVerifier.sha1File(jarPath)).toLowerCase();
      if (actual !== meta.clientSha1.toLowerCase()) {
        return {
          id: 'files',
          title: '版本文件完整性',
          status: 'fail',
          detail: '主 jar 的 SHA1 与官方记录不一致（可能是下载损坏或版本错配）。\n请在下载页重新下载该版本。',
          fixActionKey: 'redownload',
        };
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'main jar sha1 failed: %{public}s', (e as Error).message);
      return base;
    }
    return {
      id: 'files',
      title: '版本文件完整性',
      status: 'pass',
      detail: base.detail + ' · 主 jar SHA1 校验通过',
      fixActionKey: '',
    };
  }

  /**
   * 校验 6：游戏资源（assets）完整性。
   * 读 assets/indexes/<id>.json，逐对象检查 assets/objects/<2>/<hash> 存在 + size
   * （资源文件名即 sha1，存在+size 等价于内容校验，无需再 hash）。
   *
   * 判定：
   *   - 无 assetIndex（极旧/无资源版本）→ 视为通过（无可校验项）。
   *   - 索引文件缺失 → 失败（assets 没下载，redownload）。
   *   - 缺失占比 > ASSETS_MISSING_FAIL_RATIO → 失败；否则通过（少量缺失只在 detail 提示）。
   */
  static runAssets(input: PreLaunchInput): PreLaunchCheck {
    let meta = VersionFileVerifier.readMeta(input.mcDir, input.version);
    if (meta.assetIndexId.length === 0) {
      return { id: 'assets', title: '游戏资源完整性', status: 'pass', detail: '该版本无独立资源索引，跳过', fixActionKey: '' };
    }
    let r: AssetsCheckResult = VersionFileVerifier.checkAssets(input.mcDir, meta.assetIndexId);
    if (!r.indexExists) {
      return {
        id: 'assets',
        title: '游戏资源完整性',
        status: 'fail',
        detail: '资源索引缺失（assets/indexes/' + meta.assetIndexId + '.json）。游戏资源未下载完整，请在下载页补全该版本。',
        fixActionKey: 'redownload',
      };
    }
    if (r.total > 0 && r.missing > r.total * PreLaunchValidator.ASSETS_MISSING_FAIL_RATIO) {
      return {
        id: 'assets',
        title: '游戏资源完整性',
        status: 'fail',
        detail: '游戏资源大量缺失（' + r.missing + '/' + r.total + '）。请在下载页重新补全该版本资源。',
        fixActionKey: 'redownload',
      };
    }
    let detail = r.missing > 0
      ? '资源基本齐全（缺 ' + r.missing + '/' + r.total + '，不影响进入游戏）'
      : '资源齐全（' + r.total + ' 项）';
    return { id: 'assets', title: '游戏资源完整性', status: 'pass', detail: detail, fixActionKey: '' };
  }
}
