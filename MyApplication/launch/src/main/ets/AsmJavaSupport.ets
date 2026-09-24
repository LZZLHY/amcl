/**
 * AsmJavaSupport.ets — ASM 版本 → 它能读到的最高 Java class file 版本（数据表 + 纯查表）
 *
 * 契约见 `docs/refactor/启动世代契约规范.md` §5。
 *
 * ⭐ **为什么需要它**：模组加载器自带一份 ASM，而它在建类层次时**要去读 JDK 自己的
 * 类文件**。ASM 读不了比它发布时更新的 class file 版本，于是
 * "JDK 比加载器自带的 ASM 新一档" ⇒ 启动即崩：
 *
 * ```
 * Unsupported class file major version 69            ← major 69 = Java 25
 *   at org.objectweb.asm@9.7.1/ClassReader.<init>
 *   at modlauncher@10.0.8/ClassTransformer.transform
 * ```
 *
 * ⭐⭐ **上限是逐 loader 构建的事实，不是逐世代的。** 同属 `forge-bsl` 世代：
 * `1.19.4-forge-45.4.5` 自带 ASM **9.7.1**（≤ Java 24 ⇒ JDK 21 可用、25 不可用），
 * 而 `1.18.2-forge-40.2.0` 自带 ASM 9.2（≤ Java 18 ⇒ **连 JDK 21 都读不了**）。
 * ⇒ 任何"按世代填一个数"的模型都必然对其中一半错。
 *
 * ⇒ **本模块不维护"哪个 Forge 带哪个 ASM"那张表**（会腐烂且无法穷举）。
 * ASM 坐标由**版本自己的 `libraries` 声明**，逐版本实读即得（实测七个版本全部声明了它）。
 * 本模块只放一张**上游权威、只增不改**的小表：ASM 发布 → 新增的 class file 版本常量。
 *
 * 数据来源：<https://asm.ow2.io/versions.html>（ASM 官方版本页，逐条摘录）。
 *
 * 创建日期：2026-09-04
 */

/** 一条上游断点：从该 ASM 版本起，支持到 Java `maxJavaMajor`。 */
interface AsmBreakpoint {
  /** ASM 版本号（点分，与 maven 坐标里的一致）。 */
  asm: string;
  /** 该版本能读到的最高 Java 主版本。 */
  maxJavaMajor: number;
  /** 上游页面上的原文依据（写下来免得下一个人回去重查）。 */
  evidence: string;
}

/**
 * ⭐ **只增不改的断点表**（按 ASM 版本升序）。每一条都在上游版本页上有原文。
 *
 * ⚠️ **查表规则是"取 ≤ 目标版本的最后一条"**（阶梯函数），因此**不必**为每个 ASM 发布
 * 都写一行 —— 上游只在"新增了一个 class file 版本常量"时才算断点。
 * 没有单独列出的版本（如 8.0 / 9.0）会落到前一条，**方向偏保守**（低估上限），
 * 这正是我们要的：宁可提示用户装一个更老的 JDK，也不要放过一个会崩的组合。
 *
 * ⚠️ **新 ASM 发布时只在末尾追加一行**，不要改动已有行 —— 已有行是历史事实。
 */
const ASM_BREAKPOINTS: AsmBreakpoint[] = [
  { asm: '5.0', maxJavaMajor: 8, evidence: 'ASM 5.0 起支持 Java 8 的 invokespecial/static on interfaces' },
  { asm: '6.0', maxJavaMajor: 9, evidence: 'ASM 6.0: Support for modules (JSR 376)' },
  { asm: '7.0', maxJavaMajor: 11, evidence: 'ASM 7.0: support of JDK 11 features now official' },
  { asm: '7.1', maxJavaMajor: 13, evidence: 'ASM 7.1: new Opcodes.V13 constant for Java 13' },
  { asm: '7.2', maxJavaMajor: 14, evidence: 'ASM 7.2: add support for Java 14' },
  { asm: '7.3.1', maxJavaMajor: 15, evidence: 'ASM 7.3.1: new Opcodes.V15 constant for Java 15' },
  { asm: '9.1', maxJavaMajor: 17, evidence: 'ASM 9.1: JDK 17 support' },
  { asm: '9.2', maxJavaMajor: 18, evidence: 'ASM 9.2: JDK 18 support' },
  { asm: '9.3', maxJavaMajor: 19, evidence: 'ASM 9.3: new Opcodes.V19 constant for Java 19' },
  { asm: '9.4', maxJavaMajor: 20, evidence: 'ASM 9.4: new Opcodes.V20 constant for Java 20' },
  { asm: '9.5', maxJavaMajor: 21, evidence: 'ASM 9.5: new Opcodes.V21 constant for Java 21' },
  { asm: '9.6', maxJavaMajor: 22, evidence: 'ASM 9.6: new Opcodes.V22 constant for Java 22' },
  { asm: '9.7', maxJavaMajor: 23, evidence: 'ASM 9.7: new Opcodes.V23 constant for Java 23' },
  { asm: '9.7.1', maxJavaMajor: 24, evidence: 'ASM 9.7.1: new Opcodes.V24 constant for Java 24' },
  { asm: '9.8', maxJavaMajor: 25, evidence: 'ASM 9.8: new Opcodes.V25 constant for Java 25' },
  { asm: '9.9', maxJavaMajor: 26, evidence: 'ASM 9.9: new Opcodes.V26 constant for Java 26' },
  { asm: '9.10', maxJavaMajor: 27, evidence: 'ASM 9.10: new Opcodes.V27 constant for Java 27' },
];

/** 表里最老那条的 ASM 版本之前（如 4.x）也按它取值 —— 那些都是 Java 8 之前的世界。 */
const OLDEST_MAX_JAVA: number = 8;

/** 版本 JSON 的 `libraries` 里，承载字节码工具链的那个 maven group 的路径前缀。 */
const ASM_PATH_PREFIX: string = 'org/ow2/asm/';

export interface AsmSupportInfo {
  /** 实读到的 ASM 版本；空串 = 该版本没声明 ASM。 */
  asmVersion: string;
  /** 它能读到的最高 Java 主版本；**0 = 没声明 ASM ⇒ 无 ASM 侧上限**。 */
  maxJavaMajor: number;
  /** 命中的断点原文（进日志与文案，便于复核）。 */
  evidence: string;
}

/**
 * 从 `libraries`（相对路径形式，如 `org/ow2/asm/asm/9.7.1/asm-9.7.1.jar`）里实读 ASM 版本。
 *
 * ⚠️ **取最老的那个**：一个版本会声明 `asm` / `asm-tree` / `asm-commons` 等五六个
 * 同版本制品，正常情况下版本一致；万一不一致，**最老的那个才是约束**
 * （任何一个组件读不了新 class file，整条链就崩）。
 */
export function findAsmSupport(libraryPaths: string[]): AsmSupportInfo {
  let oldest: string = '';
  for (let i = 0; i < libraryPaths.length; i++) {
    const version: string = asmVersionOf(libraryPaths[i]);
    if (version.length === 0) continue;
    if (oldest.length === 0 || compareVersions(version, oldest) < 0) oldest = version;
  }
  if (oldest.length === 0) {
    return { asmVersion: '', maxJavaMajor: 0, evidence: 'no org.ow2.asm library declared' };
  }
  const hit: AsmBreakpoint | null = breakpointFor(oldest);
  return {
    asmVersion: oldest,
    maxJavaMajor: hit !== null ? hit.maxJavaMajor : OLDEST_MAX_JAVA,
    evidence: hit !== null ? hit.evidence : `ASM ${oldest} 早于表内最老断点，按 Java ${OLDEST_MAX_JAVA} 取值`,
  };
}

/** `org/ow2/asm/<artifact>/<version>/…` → `<version>`；不是 ASM 制品返回空串。 */
function asmVersionOf(libraryPath: string): string {
  if (!libraryPath.startsWith(ASM_PATH_PREFIX)) return '';
  const rest: string = libraryPath.substring(ASM_PATH_PREFIX.length);
  const parts: string[] = rest.split('/');
  // 期望形状：<artifact>/<version>/<file>.jar
  if (parts.length < 3) return '';
  return parts[1];
}

/** 取 ≤ 目标版本的最后一条断点；比最老断点还老返回 null。 */
function breakpointFor(asmVersion: string): AsmBreakpoint | null {
  let hit: AsmBreakpoint | null = null;
  for (let i = 0; i < ASM_BREAKPOINTS.length; i++) {
    if (compareVersions(ASM_BREAKPOINTS[i].asm, asmVersion) <= 0) hit = ASM_BREAKPOINTS[i];
  }
  return hit;
}

/**
 * 点分版本号比较。`9.7.1` > `9.7` > `9.10`？**不是** —— 逐段按数字比，
 * 所以 `9.10` > `9.7.1`（这正是 2026 年 ASM 的真实序：9.8 → 9.9 → 9.10）。
 * 字符串比较会把 `9.10` 排在 `9.7` 前面，那会让最新的 ASM 被当成最老的。
 */
function compareVersions(a: string, b: string): number {
  const pa: string[] = a.split('.');
  const pb: string[] = b.split('.');
  const n: number = Math.max(pa.length, pb.length);
  for (let i = 0; i < n; i++) {
    const va: number = i < pa.length ? toInt(pa[i]) : 0;
    const vb: number = i < pb.length ? toInt(pb[i]) : 0;
    if (va !== vb) return va < vb ? -1 : 1;
  }
  return 0;
}

function toInt(s: string): number {
  const n: number = parseInt(s, 10);
  return isNaN(n) ? 0 : n;
}
