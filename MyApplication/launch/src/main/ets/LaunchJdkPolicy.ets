/**
 * LaunchJdkPolicy.ets — JDK 选择策略（纯函数，无 IO）
 *
 * 契约见 `docs/refactor/启动世代契约规范.md` §5；判定钉子在
 * `entry/src/test/LaunchJdkPolicy.test.ets`（含真机路线的等价矩阵）。
 *
 * ⭐ **一句话：JDK 的可用性是一个区间 `[min, max]`，而不是一个点。**
 *
 * | 边界 | 来自 | 违反的后果 |
 * |---|---|---|
 * | `min` | **清单 javaVersion** 的有效声明，缺失时按游戏纪元回退 | `UnsupportedClassVersionError`，报错能看懂 |
 * | `max` | **该版本自带的 ASM**（逐版本实读）：它能读到的最高 class file 版本 | **启动即崩**，且崩在指不到真因的地方 |
 *
 * 区间内的任何已装 JDK 都**可用**；纪元理想只是**推荐**，不是唯一解。
 *
 * ⛔⛔ **本文件的第一版（2026-09-04 早些时候）把 `max` 取成"纪元理想那个数"，被真机否证：**
 * 用户只装了 JDK 21、选自动，结果被告知"JDK 17 未安装"而拒启 —— 而 `1.19.4-forge`
 * 自带 ASM 9.7.1（≤ Java 24），**JDK 21 完全可用**（用户实测跑通）。
 * 那一版把"推荐"当成了"唯一"，于是把一个能跑的组合拦住了。
 * ⇒ 判据：**收紧一条判据时，先问"它会不会连合法的那些也一起拦掉"。**
 * 一条过严的判据与一条过宽的判据同样有害，只是前者的受害者会来投诉、后者不会。
 *
 * ⚠️ **世代判定不在这里**：本文件只消费 `LOADER_GENERATION_CONTRACTS` 与
 * `AsmJavaSupport`。判定唯一处是 `LoaderGenerationResolver`（规范 §1.1 纪律 1）。
 *
 * 创建日期：2026-09-04
 */

import { JdkCeiling, LoaderGenerationContract } from './LoaderGenerationRegistry';
import { resolveLoaderGeneration } from './LoaderGenerationResolver';
import { findAsmSupport, AsmSupportInfo } from './AsmJavaSupport';

/** 算区间要的事实。**只放事实，不放已经推导过的结论。** */
export interface JdkRangeInput {
  /** `version.json` 的 `mainClass`。空串 ⇒ 判成 `Unknown`。 */
  mainClass: string;
  /** `version.json` 的 `libraries`（相对路径形式）。ASM 上限从这里实读。 */
  libraryPaths: string[];
  /** 游戏纪元理想的 JDK 主版本（含"≤1.12 → 8"与 available 安全网）。 */
  eraIdealJdk: string;
  /** 清单没有有效声明时使用的游戏纪元下限（`minRuntimeJavaMajor`）；0 代表纪元未知。 */
  minRuntimeMajor: number;
  /** 已解析的清单 Java 下限；有效正整数优先，缺失/非法时才回退游戏纪元。 */
  manifestJavaMajor?: number;
  /** 本产品当前明确可提供下载的主版本集合；缺省仅兼容旧纯函数调用，生产必须传入。 */
  availableMajors?: string[];
}

/** 一个版本的 JDK 可用区间 + 归因。**路由与 Phase 0 自检都读这一份。** */
export interface JdkRange {
  /** 下限（含）。 */
  minMajor: number;
  /** 上限（含）；**0 = 无上限**。 */
  maxMajor: number;
  /** 区间内的发布推荐；空区间或没有可提供候选时为空，不能拿去创建下载任务。 */
  preferredJdk: string;
  /** 下限的事实来源；可选以兼容启动前尚未解析的 UI 占位对象。 */
  minimumSource?: string;
  /** 下限依据的人话，供矛盾区间的解释使用。 */
  minimumEvidence?: string;
  /** 发布候选快照，与已安装集合分开；停止发布不意味着磁盘上已有的合法运行时失效。 */
  availableMajors?: string[];
  /** 上限的来源：`asm:<ver>` / `pinned:<n>` / `generation-fallback` / `none`。 */
  ceilingSource: string;
  /** 上限依据的人话（进用户文案）。 */
  ceilingEvidence: string;
  generation: string;
  displayName: string;
}

/**
 * 算区间。三个来源按**收紧**方向合并（谁更严谁生效）：
 *   1. **契约钉死**（`pinnedJdkMajor`）⇒ 与下限求交，合法时区间退化成一个点。
 *      老 modlauncher = 8：那是 `URLClassLoader` 约束（`1000154`），与 ASM 无关，
 *      而且比 ASM 给的上限（7.2 ⇒ Java 14）更严。
 *   2. **该版本自带的 ASM**（实读 `libraries`）⇒ 上限 = 它能读到的最高 Java。
 *   3. **世代兜底**（`jdkCeiling`）⇒ 只在**没声明 ASM**时才用。
 */
export function resolveJdkRange(i: JdkRangeInput): JdkRange {
  const contract: LoaderGenerationContract = resolveLoaderGeneration({
    mainClass: i.mainClass,
  }).contract;
  const eraMajor: number = majorOf(i.eraIdealJdk);
  const declared: number = validJavaMajor(i.manifestJavaMajor);
  const minMajor: number = declared > 0 ? declared : validJavaMajor(i.minRuntimeMajor);
  const minimumSource: string = declared > 0 ? 'manifest-java-version'
    : (minMajor > 0 ? 'game-era-fallback' : 'unknown');
  const minimumEvidence: string = declared > 0
    ? `版本清单 javaVersion.majorVersion 声明最低 Java ${declared}`
    : (minMajor > 0 ? `游戏纪元回退要求最低 Java ${minMajor}` : '版本清单与纪元均未确定 Java 下限');

  // 1) 钉死与真实下限求交：合法时退化成点；冲突时保留空区间，不抹掉游戏要求。
  if (contract.pinnedJdkMajor.length > 0) {
    const pinned: number = majorOf(contract.pinnedJdkMajor);
    const pinnedMinimum: number = Math.max(minMajor, pinned);
    return {
      minMajor: pinnedMinimum, maxMajor: pinned,
      preferredJdk: preferredFromAvailable(contract.pinnedJdkMajor, pinnedMinimum, pinned, i.availableMajors),
      minimumSource: minimumSource, minimumEvidence: minimumEvidence,
      availableMajors: i.availableMajors !== undefined ? i.availableMajors.slice() : undefined,
      ceilingSource: `pinned:${contract.pinnedJdkMajor}`,
      ceilingEvidence: `「${contract.displayName}」只能跑在 Java ${pinned} 上`
        + `（它把系统类加载器当 URLClassLoader 用，更高的 JDK 上启动即崩）`,
      generation: contract.generation, displayName: contract.displayName,
    };
  }

  // 2) 实读该版本自带的 ASM。
  const asm: AsmSupportInfo = findAsmSupport(i.libraryPaths);
  let maxMajor: number = asm.maxJavaMajor;
  let source: string = asm.asmVersion.length > 0 ? `asm:${asm.asmVersion}` : 'none';
  let evidence: string = asm.asmVersion.length > 0
    ? `「${contract.displayName}」自带 ASM ${asm.asmVersion}，最高只能读 Java ${asm.maxJavaMajor} 的类文件`
    : '';

  // 3) 没声明 ASM 时才看世代兜底。原版天然落在这里且无上限 —— 它不用 ASM 读 JDK 类。
  if (maxMajor === 0 && contract.jdkCeiling === JdkCeiling.GameEra) {
    // 无 ASM 只是工具链上限未知，不能用较旧的“纪元推荐”否定加载器已声明的更高下限。
    // 这仍是保守兜底而非已验证的 ASM 能力；有明确 ASM 或 pinned 证据时绝不放宽。
    maxMajor = Math.max(eraMajor, minMajor);
    source = 'generation-fallback';
    evidence = `「${contract.displayName}」没有声明字节码工具链版本，`
      + `按纪元推荐与已声明下限保守取上限 Java ${maxMajor}`;
  }

  return {
    minMajor: minMajor,
    maxMajor: maxMajor,
    preferredJdk: preferredFromAvailable(i.eraIdealJdk, minMajor, maxMajor, i.availableMajors),
    minimumSource: minimumSource,
    minimumEvidence: minimumEvidence,
    availableMajors: i.availableMajors !== undefined ? i.availableMajors.slice() : undefined,
    ceilingSource: source,
    ceilingEvidence: evidence,
    generation: contract.generation,
    displayName: contract.displayName,
  };
}

/** 为什么选了这个 JDK。稳定标识符，会进日志，**不要按心情改字面量**。 */
export type JdkPolicyReason =
  | 'pinned'            // 契约钉死（老 modlauncher = 8）
  | 'era-ideal'         // 纪元推导的发布推荐已安装且在区间内（保留既有日志标识）
  | 'user-pick'         // 用户选择已安装且在区间内
  | 'in-range'          // ⭐ 纪元理想没装，但区间内有别的已装 JDK ⇒ 直接用它，不阻塞
  | 'none-installed'    // 区间内一个都没装 ⇒ 返回推荐值让上层提示安装
  | 'empty-range'       // 下限超过已知上限 ⇒ 没有可推荐 JDK，必须先修正版本/加载器组合
  | 'runtime-unavailable'; // 区间非空，但没有合法已装运行时或当前可提供的下载候选

export interface JdkPolicyDecision {
  /** 空区间或没有可提供运行时时为 ''；消费方必须解释原因，不能创建空版本下载任务。 */
  jdk: string;
  installed: boolean;
  reason: JdkPolicyReason;
  range: JdkRange;
  logLine: string;
}

export interface JdkPolicyInput {
  range: JdkRange;
  /** 用户选择（全局或单版本覆盖）。空串 / `'auto'` = 无明确选择。 */
  userPreferred: string;
  /** 已安装**且完整**的 JDK 主版本（`isInstalled` 为真的那些）。 */
  installedMajors: string[];
}

/**
 * 选 JDK。**路由与自检共用同一份区间**，所以两者不可能给出不一致的结论。
 *
 * 前置条件：空区间直接返回约束冲突，不进入安装候选选择。
 * 优先级：① 钉死 → ② 纪元理想（在区间内且已装）→ ③ 用户选择（同上）→
 * ④ ⭐ **区间内任一已装 JDK（取最低）** → ⑤ 都没装 ⇒ 返回推荐值 + `installed=false`。
 *
 * ⭐ **第 ④ 条是本次修正的核心**：它让"只装了 JDK 21 + 版本推荐 17 + 加载器能吃到 24"
 * 这种组合**直接跑起来**，而不是拒启。取最低是保守取向（越接近模组编译时的那一代越安全），
 * 与 `commons.pickInstalledJdkMajor` 的既有语义一致。
 */
export function resolveJdkPolicy(i: JdkPolicyInput): JdkPolicyDecision {
  const r: JdkRange = i.range;
  if (isJdkRangeEmpty(r)) return decide(i, '', 'empty-range');
  if (r.ceilingSource.startsWith('pinned:')) {
    // pinned 的兼容性来自契约，不来自发布状态；已安装的 8 即使停止发布也继续可用。
    const pinnedJdk: string = r.maxMajor.toString();
    if (usable(r.maxMajor, r) && isInstalled(i, pinnedJdk)) return decide(i, pinnedJdk, 'pinned');
    if (!hasJdkDownloadCandidate(r)) return decide(i, '', 'runtime-unavailable');
    return decide(i, r.preferredJdk, 'pinned');
  }
  if (usable(majorOf(r.preferredJdk), r) && isInstalled(i, r.preferredJdk)) {
    return decide(i, r.preferredJdk, 'era-ideal');
  }
  const pick: number = majorOf(i.userPreferred);
  if (pick > 0 && usable(pick, r) && isInstalled(i, i.userPreferred)) {
    return decide(i, i.userPreferred, 'user-pick');
  }
  // ④ 区间内已装的最低那个。
  const sorted: number[] = [];
  for (let k = 0; k < i.installedMajors.length; k++) {
    const m: number = majorOf(i.installedMajors[k]);
    if (m > 0 && usable(m, r)) sorted.push(m);
  }
  sorted.sort((a: number, b: number) => a - b);
  if (sorted.length > 0) return decide(i, sorted[0].toString(), 'in-range');
  // 必须在扫描合法已装之后检查发布候选，避免把自编/停发但仍能运行的 JDK 拒之门外。
  if (!hasJdkDownloadCandidate(r)) return decide(i, '', 'runtime-unavailable');
  return decide(i, r.preferredJdk, 'none-installed');
}

/** 某个 Java 主版本是否落在区间内。 */
export function usable(jdkMajor: number, range: JdkRange): boolean {
  if (validJavaMajor(jdkMajor) === 0 || isJdkRangeEmpty(range)) return false;
  if (range.minMajor > 0 && jdkMajor < range.minMajor) return false;
  return range.maxMajor === 0 || jdkMajor <= range.maxMajor;
}

/** Phase 0 自检的区间结论；空区间先于具体选择判定，“非推荐但可用”仍不得阻塞。 */
export type JdkChoiceVerdict = 'ok' | 'ok-not-preferred' | 'above-max' | 'below-min' | 'empty-range';

/**
 * 判定一个**已选定**的 JDK 相对区间的位置。Phase 0 与路由共用同一区间，
 * 所以自检认可的与路由选出来的不可能是两回事。
 */
export function classifyJdkChoice(jdkMajor: number, range: JdkRange): JdkChoiceVerdict {
  if (isJdkRangeEmpty(range)) return 'empty-range';
  if (range.maxMajor > 0 && jdkMajor > range.maxMajor) return 'above-max';
  if (range.minMajor > 0 && jdkMajor < range.minMajor) return 'below-min';
  return jdkMajor === majorOf(range.preferredJdk) ? 'ok' : 'ok-not-preferred';
}

/**
 * 越上限时给用户看的原因（一句话说清机制，不只说"不兼容"）。
 *
 * ⚠️ 文案里的 ASM 版本号是**从该版本自己的 libraries 实读**的，不是硬编码的常量，
 * 所以它不会腐烂。
 */
export function describeAboveMax(range: JdkRange, jdkMajor: number): string {
  if (isJdkRangeEmpty(range)) return describeEmptyJdkRange(range);
  const why: string = range.ceilingEvidence.length > 0
    ? range.ceilingEvidence
    : `「${range.displayName}」最高只能跑在 Java ${range.maxMajor} 上`;
  return why + ` —— 用 JDK ${jdkMajor} 启动会在加载游戏类时崩溃`
    + '（Unsupported class file major version）。'
    + (hasJdkDownloadCandidate(range) ? `请改用 JDK ${range.preferredJdk}。`
      : '请检查是否有区间内已安装的兼容 JDK；当前产品没有可提供的下载候选。');
}

/** "可用但不是推荐值"的说明。**这条刻意不阻塞** —— 它只是告诉用户还有更贴合的选择。 */
export function describeNotPreferred(range: JdkRange, jdkMajor: number): string {
  if (isJdkRangeEmpty(range)) return describeEmptyJdkRange(range);
  const upper: string = range.maxMajor > 0 ? `Java ${range.maxMajor}` : '更高';
  return `JDK ${jdkMajor} 可用：该版本要求 ≥ Java ${range.minMajor}，`
    + `而「${range.displayName}」最高能吃到 ${upper}`
    + (range.ceilingSource.startsWith('asm:')
      ? `（实读它自带的 ASM ${range.ceilingSource.substring(4)}）` : '')
    + (hasJdkDownloadCandidate(range)
      ? `。当前可下载的推荐是 JDK ${range.preferredJdk}，不影响继续使用已安装的兼容版本。`
      : '。继续使用这份已安装的兼容运行时；当前产品没有该区间内的可下载推荐。');
}

/**
 * 是否有真实可下载推荐。它只回答发布可用性，不回答某个已安装 JDK 是否能运行。
 * UI 应仅在没有合法已选运行时且该函数为 false 时显示“运行时暂未提供”。
 */
export function hasJdkDownloadCandidate(range: JdkRange): boolean {
  if (isJdkRangeEmpty(range) || !usable(majorOf(range.preferredJdk), range)) return false;
  return range.availableMajors === undefined || range.availableMajors.indexOf(range.preferredJdk) >= 0;
}

/**
 * 没有合法已装运行时及发布候选时的说明；区别于数学上的空区间，不建议下载不存在的槽。
 * 消费方须先保留合法已安装 JDK 的运行机会，不能仅因当前停发就套用该阻断说明。
 */
export function describeUnavailableJdkRuntime(range: JdkRange): string {
  const upper: string = range.maxMajor > 0 ? range.maxMajor.toString() : '无上限';
  return `当前没有可用的 JDK：兼容区间为 [${range.minMajor}, ${upper}]，`
    + '没有符合要求的已安装运行时，当前产品也未提供该区间内的 JDK 下载。'
    + '请核对版本要求，或等待相应运行时适配；不会创建不存在版本的下载任务。';
}

/** 空区间不等于没有安装 JDK；任何安装、自动选择或手动覆盖都不能消除上下限冲突。 */
export function isJdkRangeEmpty(range: JdkRange): boolean {
  return range.maxMajor > 0 && range.minMajor > range.maxMajor;
}

/** 给自检/启动入口共用的冲突解释，不给出任何落在矛盾区间外的安装建议。 */
export function describeEmptyJdkRange(range: JdkRange): string {
  const lower: string = range.minimumEvidence && range.minimumEvidence.length > 0
    ? range.minimumEvidence : `此版本要求最低 Java ${range.minMajor}`;
  const upper: string = range.ceilingEvidence.length > 0
    ? range.ceilingEvidence : `加载器允许的最高 Java 为 ${range.maxMajor}`;
  return `JDK 要求冲突：${lower}；${upper}。可用区间 [${range.minMajor}, ${range.maxMajor}] 为空，`
    + '没有可推荐的 JDK。请核对版本清单与加载器/字节码工具链组合；安装或切换 JDK 不能解决该冲突。';
}

/** 统一输出选择结果；空版本永远不能因外部安装列表含空串而被报告为已安装。 */
function decide(i: JdkPolicyInput, jdk: string, reason: JdkPolicyReason): JdkPolicyDecision {
  const installed: boolean = isInstalled(i, jdk);
  const r: JdkRange = i.range;
  return {
    jdk: jdk,
    installed: installed,
    reason: reason,
    range: r,
    logLine: `AMCL_JDK_POLICY schema=2 generation=${r.generation}`
      + ` jdk=${jdk} installed=${installed ? 1 : 0} reason=${reason}`
      + ` range=[${r.minMajor},${r.maxMajor > 0 ? r.maxMajor.toString() : 'inf'}]`
      + ` preferred=${r.preferredJdk} ceiling=${r.ceilingSource}`
      + ` minimum=${r.minimumSource || 'unknown'}`
      + ` available=${r.availableMajors === undefined ? 'unspecified' : r.availableMajors.join(',')}`
      + ` pick=${i.userPreferred.length > 0 ? i.userPreferred : '(none)'}`,
  };
}

function isInstalled(i: JdkPolicyInput, version: string): boolean {
  if (version.length === 0) return false;
  for (let k = 0; k < i.installedMajors.length; k++) {
    if (i.installedMajors[k] === version) return true;
  }
  return false;
}

/** 仅把推荐值夹入非空区间；真实下限高于上限时返回空，不伪造一个可下载的解。 */
function clampToRange(eraIdealJdk: string, minMajor: number, maxMajor: number): string {
  if (maxMajor > 0 && minMajor > maxMajor) return '';
  const era: number = majorOf(eraIdealJdk);
  if (era <= 0) return eraIdealJdk;
  if (maxMajor > 0 && era > maxMajor) return maxMajor.toString();
  if (minMajor > 0 && era < minMajor) return minMajor.toString();
  return eraIdealJdk;
}

/**
 * 推荐必须属于已声明的发布集合与兼容区间的交集，不能把数值上限 24 误当作发布槽。
 * 优先不低于纪元推荐的最低候选；该方向没有候选时用区间内最高的较低候选。
 * 发布集合缺省仅保留旧纯函数契约；Manager 的实际启动路径始终传入明确快照。
 */
function preferredFromAvailable(eraIdealJdk: string, minMajor: number, maxMajor: number,
  availableMajors: string[] | undefined): string {
  const preferred: string = clampToRange(eraIdealJdk, minMajor, maxMajor);
  if (maxMajor > 0 && minMajor > maxMajor) return '';
  if (availableMajors === undefined) return preferred;
  const candidates: number[] = [];
  for (const version of availableMajors) {
    const major: number = validJavaMajor(Number(version));
    if (major > 0 && major.toString() === version && major >= minMajor
      && (maxMajor === 0 || major <= maxMajor)) candidates.push(major);
  }
  candidates.sort((a: number, b: number) => a - b);
  if (candidates.length === 0) return '';
  const desired: number = majorOf(preferred);
  for (const candidate of candidates) {
    if (candidate >= desired) return candidate.toString();
  }
  return candidates[candidates.length - 1].toString();
}

function majorOf(version: string): number {
  const n: number = parseInt(version, 10);
  return isNaN(n) ? 0 : n;
}

/** 接受清单与区间输入的有限正整数；不靠 parseInt 将畸形值悄悄变成合法硬约束。 */
function validJavaMajor(value: number | undefined): number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0
    && Math.floor(value) === value ? value : 0;
}
