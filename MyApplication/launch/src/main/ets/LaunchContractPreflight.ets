/**
 * LaunchContractPreflight.ets — 启动契约校验（纯函数，无副作用）
 *
 * 契约见 `docs/refactor/启动世代契约规范.md`；判据钉子在
 * `entry/src/test/LoaderGenerationContract.test.ets`。
 *
 * ⭐⭐ **先读这一段：本文件只是三层防线里的一层，而且不是最硬的那层。**
 *
 * 启动契约的核心命题是"`java.class.path` 的实际值符合本世代的要求"。
 * **ArkTS 层看不到那个实际值** —— 它由 C++ 的 `phase_initJvmWithClasspath` 写入。
 * 如果本文件把"表里声明的 delivery"与"表里声明的 delivery"对比，那是一条**恒真判据**，
 * 而恒真判据比没有判据更糟（本仓 `1000513`：产物那半判据在 CI 上恒真，
 * 于是"从不执行"与"全部通过"长得一模一样）。
 *
 * ⇒ 三层各自校验**自己真正观测得到**的东西：
 *
 * | 层 | 位置 | 观测到什么 | 强度 |
 * |---|---|---|---|
 * | ① 静态门禁 | `scripts/check-launch-generation-contract.mjs` | 契约表结构 + 钉住值 + C++ 是否真的消费该字段 | 提交前，无需设备 |
 * | ② 本文件 | ArkTS，构建 profile 之后 | jvmArgs / jdkMajor / classpath 条目数等**ArkTS 侧的独立事实** | 启动前，可归因 |
 * | ③ 运行期断言 | `AmclLauncher.verifyClasspathDelivery` | **真实的 `System.getProperty("java.class.path")`** | 唯一能否证"实际值"的一层 |
 *
 * 本文件里每条判据都标了它**能否被伪造**（`⚖️ 强` / `⚖️ 弱`）。
 * 标"弱"的不是废话 —— 它挡的是"调用方手搓了一个不一致的记录"，
 * 但它**不能**证明 JVM 里的实际值对。别把它当成那层。
 *
 * 创建日期：2026-09-04
 */

import {
  ClasspathDelivery, LoaderGeneration, LoaderGenerationContract,
} from './LoaderGenerationRegistry';

/**
 * 校验输入。**每个字段都必须是"将要真实生效的值"**，不是从契约表抄回来的。
 */
export interface LaunchContractInput {
  /** 判定出的世代及其契约。 */
  contract: LoaderGenerationContract;
  /**
   * 将写进 `LaunchProfile.classpathDelivery` 的值（C++ 侧照此执行）。
   *
   * ⚠️ 正常链路里它来自 `contract.classpathDelivery` ⇒ 与契约的比对是 ⚖️ 弱判据。
   * 真正的判据在第 ③ 层。
   */
  effectiveDelivery: ClasspathDelivery;
  /** 游戏 classpath 的条目数（`classpath.split(':')` 的长度）。 */
  gameClasspathEntries: number;
  /** 最终下传的 JVM 参数（SSOT 合并、用户参数合并之后）。 */
  jvmArgs: string[];
  /** 选中的 JDK 主版本，如 `'8'` / `'17'` / `'25'`。 */
  jdkMajor: string;
}

export enum LaunchContractSeverity {
  Warn = 'warn',
  Fail = 'fail',
}

/**
 * 一条违约。`code` 是稳定标识符 —— 它会进日志，且供 `McErrorClassifier` 对接，
 * **不要按心情改字面量**。
 */
export interface LaunchContractViolation {
  code: string;
  severity: LaunchContractSeverity;
  message: string;
}

export interface LaunchContractVerdict {
  /** 无任何 `Fail` 即为 true。**Warn 不阻断启动。** */
  ok: boolean;
  violations: LaunchContractViolation[];
  /** 一行摘要，供直接打进启动日志。 */
  logLine: string;
}

/**
 * 一次校验的留痕：判定 + 判定当时的输入摘要。
 *
 * ⭐ **存在的理由是"校验发生在 build() 内部，而结论要给 build() 的调用方看"。**
 * `PreLaunchValidator` 要把契约结论渲染成 Phase 0 检查列表里的一项，而它**不允许**
 * 为此再调一次 `LaunchProfileBuilder.build()`（那会让同一次启动做两遍完整解析）。
 *
 * ⚠️ `null` 与"通过"是两件事：契约失败时 `build()` 返回 null，但**文件校验其实已经全过了**；
 * 反过来，文件校验先失败时这份留痕根本不存在。调用方必须区分这两种 null
 * （否则"没校验"会被显示成"校验通过"—— 本仓 `1000544` 那一族）。
 */
export interface LaunchContractReport {
  verdict: LaunchContractVerdict;
  /** 判定出的世代 id（如 `forge-bootstrap`）。 */
  generation: string;
  /** 该世代的展示名（如 `Forge 新 bootstrap (1.20.2+)`）。 */
  displayName: string;
  /** 本次实际下传的交付方式。 */
  delivery: string;
  /** 判定时的游戏 classpath 条目数。 */
  gameClasspathEntries: number;
}

/** `-DlegacyClassPath=` 前缀。BSL 那条通道的键。 */
const LEGACY_CLASSPATH_PREFIX: string = '-DlegacyClassPath=';

/**
 * 下传给 native 与 Java 的 delivery marker 键。
 *
 * ⭐ **为什么用 JVM 参数而不是加一个 NAPI 形参**：`phase_initJvmWithClasspath` 在
 * **JVM 创建之前**执行，那时读不到系统属性，只能扫参数向量 —— 与 `-Damcl.sdl3`
 * 走同一条既有通道（`LaunchProfileBuilder` 里那条注释写了同样的理由）。
 *
 * 附带收益：它同时成为一个系统属性 ⇒ Java 侧（第 ③ 层）可以读它，
 * 并与**真实的** `java.class.path` 比对。一个 marker 同时服务执行者与验证者。
 *
 * ⚠️ **必须在 `mergeUserJvmArgs` 之后追加。** 该合并允许用户的同 `-Dkey` 覆盖，
 * 而用户若覆盖了它就能把自己的 Forge 启动弄坏 —— 那正是本次重构要消灭的故障类。
 */
export const CLASSPATH_DELIVERY_ARG_KEY: string = '-Damcl.classpathDelivery=';
/** 世代 marker 键。只用于诊断归因，不参与任何决策。 */
export const LOADER_GENERATION_ARG_KEY: string = '-Damcl.loaderGeneration=';

/**
 * 校验启动契约。
 *
 * 返回 `ok=false` 时调用方**应当阻断启动并把 `violations` 展示给用户** ——
 * 一条指名道姓的失败远好于让加载器在几百毫秒后抛一个
 * `NoSuchElementException: No value present`（本次 Forge 故障的用户可见形态）。
 */
export function evaluateLaunchContract(i: LaunchContractInput): LaunchContractVerdict {
  const v: LaunchContractViolation[] = [];
  const c: LoaderGenerationContract = i.contract;

  // ── C1 ⚖️ 弱：delivery 与契约一致 ───────────────────────────────────
  // 挡的是"调用方手搓了一个与表不符的值"。**不能**证明 JVM 里的实际值对（见文件头）。
  if (i.effectiveDelivery !== c.classpathDelivery) {
    v.push({
      code: 'delivery-mismatch',
      severity: LaunchContractSeverity.Fail,
      message: `世代 ${c.generation} 要求 classpath 交付方式为 ${c.classpathDelivery}，`
        + `实际为 ${i.effectiveDelivery}`,
    });
  }

  // ── C2 ⚖️ 弱：isolationAsserts 与 delivery 同真 ─────────────────────
  // 同样是内部一致性。真正钉住这条关系的是结构不变量测试与静态门禁。
  const expectIsolation: boolean = c.classpathDelivery === ClasspathDelivery.AmclLoaderOnly;
  if (c.isolationAsserts !== expectIsolation) {
    v.push({
      code: 'isolation-asserts-inconsistent',
      severity: LaunchContractSeverity.Fail,
      message: `世代 ${c.generation} 的 isolationAsserts=${c.isolationAsserts} 与 `
        + `delivery=${c.classpathDelivery} 不一致（必须严格同真）`,
    });
  }

  // ── C3 ⚖️ 强：classpath 不能是空的 ─────────────────────────────────
  // 独立事实（来自 buildClasspath 的产物）。0 条意味着没有任何东西可启动。
  if (i.gameClasspathEntries <= 0) {
    v.push({
      code: 'empty-game-classpath',
      severity: LaunchContractSeverity.Fail,
      message: '游戏 classpath 为空 —— 版本文件可能缺失或解析失败',
    });
  }

  // ── C4 ⚖️ 强：legacyClassPath 通道没被弄丢 ──────────────────────────
  // 独立事实（来自 jvmArgs 实际内容）。
  //
  // ⚠️ **当前没有任何世代打开这一项**（2026-09-04 真机取证，见注册表该字段的注释）⇒
  // 这段判据在产品里**从不执行**。刻意保留而不是删掉：它挡的是一条真实存在的上游通道
  // （BSL README），且"全 false"这个事实本身已由静态门禁的 PINNED_LEGACY_CLASSPATH
  // 棘轮钉住 —— 判据是否执行由契约表决定，而契约表的那一格改不动。
  if (c.requiresLegacyClassPathProperty) {
    let found: boolean = false;
    for (let k = 0; k < i.jvmArgs.length; k++) {
      const a: string = i.jvmArgs[k];
      if (a.length > LEGACY_CLASSPATH_PREFIX.length
        && a.startsWith(LEGACY_CLASSPATH_PREFIX)) {
        found = true;
        break;
      }
    }
    if (!found) {
      v.push({
        code: 'legacy-classpath-missing',
        severity: LaunchContractSeverity.Fail,
        message: `世代 ${c.generation} 要求 ${LEGACY_CLASSPATH_PREFIX}<完整 classpath>，`
          + '但最终 JVM 参数里没有它（或它的值为空）',
      });
    }
  }

  // ── C5 ⚖️ 强：固定 JDK 主版本 ──────────────────────────────────────
  // 独立事实（来自 JdkManager 的路由结果）。1000154：老 modlauncher 给 17 会崩，
  // 且回退到更高版本照样崩 ⇒ 这条必须是 Fail 而不是 Warn。
  if (c.pinnedJdkMajor.length > 0 && i.jdkMajor !== c.pinnedJdkMajor) {
    v.push({
      code: 'jdk-major-mismatch',
      severity: LaunchContractSeverity.Fail,
      message: `世代 ${c.generation} 必须用 JDK ${c.pinnedJdkMajor}，实际为 `
        + `${i.jdkMajor.length > 0 ? i.jdkMajor : '(未解析)'}（1000154）`,
    });
  }

  // ── C6 ⚖️ 强：未识别世代要留痕 ─────────────────────────────────────
  // **Warn 不 Fail**：注册表的 UNKNOWN_GENERATION_DELIVERY 刻意 fail-open 到"能启动"，
  // 在这里改成 Fail 会把那条设计意图反过来。但它必须能在日志里 grep 到 ——
  // 否则"认不出来"与"认出来了"在真机上无法区分。
  if (c.generation === LoaderGeneration.Unknown) {
    v.push({
      code: 'unknown-generation',
      severity: LaunchContractSeverity.Warn,
      message: '未识别的 mainClass —— 已按完整 classpath 启动（fail-open）。'
        + '若该版本可正常启动，请把它的 mainClass 补进 LOADER_GENERATION_CONTRACTS',
    });
  }

  let fails: number = 0;
  let warns: number = 0;
  for (let k = 0; k < v.length; k++) {
    if (v[k].severity === LaunchContractSeverity.Fail) fails++; else warns++;
  }
  return {
    ok: fails === 0,
    violations: v,
    logLine: `AMCL_LAUNCH_CONTRACT schema=1 generation=${c.generation}`
      + ` delivery=${i.effectiveDelivery} entries=${i.gameClasspathEntries}`
      + ` jdk=${i.jdkMajor} fails=${fails} warns=${warns}`
      + (v.length > 0 ? ` codes=${codesOf(v)}` : ''),
  };
}

/**
 * 校验并连同输入摘要一起留痕。
 *
 * ⚠️ **`report.delivery` 等字段刻意从同一个 `i` 抄，不由调用方另传一份。**
 * 让调用方自己组装这个对象，就等于允许"留痕说 full、实际校验的是 narrow"这种漂移，
 * 而那种漂移的表现是 UI 上一切正常。
 */
export function reportLaunchContract(i: LaunchContractInput): LaunchContractReport {
  return {
    verdict: evaluateLaunchContract(i),
    generation: i.contract.generation,
    displayName: i.contract.displayName,
    delivery: i.effectiveDelivery,
    gameClasspathEntries: i.gameClasspathEntries,
  };
}

function codesOf(v: LaunchContractViolation[]): string {
  let out: string = '';
  for (let k = 0; k < v.length; k++) {
    if (out.length > 0) out += ',';
    out += v[k].code;
  }
  return out;
}

/** 把违约列表渲染成给用户看的多行文本。`ok` 时返回空串。 */
export function describeLaunchContractViolations(verdict: LaunchContractVerdict): string {
  return describeBySeverity(verdict, LaunchContractSeverity.Fail);
}

/**
 * 同上，但只渲染 `Warn`。
 *
 * ⚠️ **两者必须分开，不许合并成一个"把所有 violation 都列出来"的函数。**
 * `Warn` 不阻断启动（`unknown-generation` 是刻意 fail-open 的），把它和 `Fail`
 * 混在一条文本里，会让"能启动、只是没认出世代"在用户眼里长得和"启动被拒"一样。
 */
export function describeLaunchContractWarnings(verdict: LaunchContractVerdict): string {
  return describeBySeverity(verdict, LaunchContractSeverity.Warn);
}

function describeBySeverity(
  verdict: LaunchContractVerdict, severity: LaunchContractSeverity): string {
  let out: string = '';
  for (let k = 0; k < verdict.violations.length; k++) {
    const it: LaunchContractViolation = verdict.violations[k];
    if (it.severity !== severity) continue;
    if (out.length > 0) out += '\n';
    out += `· ${it.message}`;
  }
  return out;
}
