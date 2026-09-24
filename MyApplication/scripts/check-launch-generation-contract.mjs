#!/usr/bin/env node
// scripts/check-launch-generation-contract.mjs
//
// ============================ 它挡的是什么 ============================
//
// `java.class.path` 是一条被**多个加载器世代以不同方式消费**的共享信道：
// 原版必须收窄（否则 AmclClassLoader 的字节码变换被 parent-first 绕过），
// Forge 新 bootstrap 与 Fabric Knot 必须完整（它们只认这一个来源）。
// 而在 2026-09-04 之前，代码里描述世代的只有 `isForge` / `isFabric` 两个布尔 ——
// `isForge` 对 ForgeBsl / ForgeBootstrap / NeoForge / ModlauncherLegacy 四代同时为真
// （`'neoforged'.indexOf('forge') >= 0`）。七元区分在二元模型里无法表达，于是
// `642edf87` 一次改动同时改了 7 条契约：Fabric 于 2026-08-29 倒下（CHANGELOG 1000576）、
// Forge 新 bootstrap 于 2026-09-04 倒下。同形状事故本仓至少 6 次（审计报告 §2.6）。
//
// ⭐ **本门禁是那两条不变量（方案 §1 的 G2/G3）唯一能在 CI 里跑的载体。**
//   ArkTS 的 hypium 测试**只能在设备上跑**（CI 没有 OHOS SDK，见
//   check-arkts-test-suite.mjs 的头注释），所以"提交前必然红"这件事只能落在这里。
//
// 它校验五组：
//   A. 结构完整性 —— 枚举里每个世代都必须在契约表里**有且仅有一行**（= G3）
//   B. 字段一致性 —— isolationAsserts 必须与 delivery==='amcl-loader-only' 严格同真
//   C. 主键卫生   —— mainClasses 跨行不得重复；除 Unknown 外不得为空
//   D. 棘轮钉住值 —— 由真机/反汇编取证确立的 delivery 不得被静默改掉（= G2）
//   E. 跨语言一致 —— 两个 delivery 字面量必须在 C++ 与 Java 侧逐字存在，
//                    且 C++ 必须真的消费 -Damcl.classpathDelivery= 这个 marker
//
// ============================ 它不能证明什么 ============================
//
// ❌ 不证明某个世代真的能启动（只有真机能证）。
// ❌ 不证明 JVM 里 java.class.path 的**实际值**对 —— 那只有
//    AmclLauncher.verifyClasspathDelivery（跑在 JVM 里的第 ③ 层）能观测。
//    ⇒ 本门禁全绿 + hypium 全绿 **仍然**需要五路线真机验收（方案 §3.4）。
// ❌ 不校验 D 组以外的字段取值是否"正确"（那是产品决策，不是可静态判定的事实）。
//
// 用法：
//   node scripts/check-launch-generation-contract.mjs
//   node scripts/check-launch-generation-contract.mjs --json

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

import { stripComments, langForPath } from './lib/source-noise.mjs';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');

export const SOURCES = {
  registry: 'launch/src/main/ets/LoaderGenerationRegistry.ets',
  resolver: 'launch/src/main/ets/LoaderGenerationResolver.ets',
  preflight: 'launch/src/main/ets/LaunchContractPreflight.ets',
  nativeLauncher: 'entry/src/main/cpp/jvm/mc_launcher.cpp',
  javaLauncher: 'JavaApp/src/com/amcl/launcher/AmclLauncher.java',
  // 批次 D：JDK 区间的**唯一策略**、上限的数据表，以及它取代的那个第二判定者。
  jdkPolicy: 'launch/src/main/ets/LaunchJdkPolicy.ets',
  asmTable: 'launch/src/main/ets/AsmJavaSupport.ets',
  jdkManager: 'launch/src/main/ets/JdkManager.ets',
};

/**
 * ⭐ **ASM 断点表的棘轮。** 每一条都在上游版本页上有原文
 * （<https://asm.ow2.io/versions.html>），而带 ⚑ 的两条还与真机行为直接对上：
 *
 * - `9.7.1 → 24`：`1.19.4-forge-45.4.5` 实读自带这一版 ⇒ 上限 Java 24 ⇒
 *   **JDK 21 可用（用户实测跑通）、JDK 25 崩**（`Unsupported class file major version 69`）。
 *   ⚑ 改小这一条会重新拦掉 JDK 21；改大会重新放过 JDK 25。
 * - `9.10 → 27`：`26.2-forge` / `26.2-neoforge` / `fabric 26.1.1` 实读自带 9.10.1 ⇒
 *   JDK 25 可用（三条路线真机跑通）。⚑ 改小会把这三条全部拦住。
 */
export const PINNED_ASM_MAX_JAVA = {
  '5.0': 8,
  '7.2': 14,
  '9.2': 18,
  '9.5': 21,
  '9.7.1': 24,
  '9.8': 25,
  '9.10': 27,
};

/** 两个 delivery 字面量。三种语言里必须逐字相同。 */
export const DELIVERY_AMCL_LOADER_ONLY = 'amcl-loader-only';
export const DELIVERY_JVM_CLASSPATH_FULL = 'jvm-classpath-full';

/** 下传 marker 的键。C++ 必须真的扫它，否则 delivery 决策等于没接上。 */
export const DELIVERY_ARG_KEY = '-Damcl.classpathDelivery=';

/**
 * ⭐ **D 组棘轮：由取证确立、不得静默改动的 delivery。**
 *
 * 每一行都注明出处。改这张表**不是**改代码风格 —— 它意味着一条真机/反汇编结论被推翻，
 * 必须同时：① 在施工记录里记下新证据；② 重跑该世代的真机验收。
 */
export const PINNED_DELIVERY = {
  // 实测：26.2 原版 jar 的 PlayerChunkSender 命中钉住哈希（chunk quota patch 活）；
  // 26.3-snapshot-10 的 terrain 三件套 3/3 命中 ⇒ 收窄在原版路线上确实保住了东西。
  vanilla: DELIVERY_AMCL_LOADER_ONLY,
  // 反汇编 bootstrap-2.1.8：findAllClassPathEntries() 只读 java.class.path，
  // 常量池里没有 legacyClassPath ⇒ 无旁路。
  'forge-bootstrap': DELIVERY_JVM_CLASSPATH_FULL,
  // CHANGELOG 1000576：Knot.init 只从 java.class.path 推导游戏查找路径。
  'fabric-knot': DELIVERY_JVM_CLASSPATH_FULL,
};

/**
 * ⭐ **`requiresLegacyClassPathProperty` 的棘轮。**
 *
 * 这一格曾是 `true`（依据"BSL 的官方 JSON 自带 `-DlegacyClassPath=${classpath}`"这个
 * **B 级推断**），后果是 2026-09-04 真机上 `1.19.4-forge-45.4.5` **两次启动都被
 * AMCL 自己的契约校验拒绝**（`fails=1 codes=legacy-classpath-missing`）——
 * 整代 Forge 1.17–1.20.1 不可启动。
 *
 * 取证（A 级）：设备上那份官方合并 JSON 里 `legacyClassPath` 出现 **0 次**
 * （实际用 `-p` / `--add-modules` / `--add-opens` / `-DmergeModules` /
 * `-DlibraryDirectory`，其余全靠 `-cp`），而 AMCL 全仓也从未注入该属性。
 *
 * ⇒ 改回 `true` 必须先拿出新的真机证据并记进施工记录。
 */
export const PINNED_LEGACY_CLASSPATH = {
  'forge-bsl': false,
};

/**
 * ⭐ **`jdkCeiling` 的棘轮（批次 D）。**
 *
 * 取证（A 级，2026-09-04 真机）：`1.19.4-forge-45.4.5` 在 JDK 25 上
 * `Unsupported class file major version 69` @ `org.objectweb.asm@9.7.1/ClassReader`
 * ← `modlauncher@10.0.8/ClassTransformer.transform`；**换成 JDK 17 后同一个包启动成功**。
 * 上游事实（asm.ow2.io 版本页）：ASM 9.7→Java 23、9.7.1→Java 24、9.8→Java 25 ——
 * 加载器自带的 ASM 在计算类层次时要去读 JDK 自己的类文件，JDK 新一档整条链就崩。
 *
 * ⇒ 把某个世代改成 `none`（允许更新的 JDK）必须先拿出该世代的真机证据。
 * 原版是 `none`：它不用 ASM 读 JDK 类，且 26.3 原版在 JDK 25 上真机跑通。
 */
export const PINNED_JDK_CEILING = {
  vanilla: 'None',
  'forge-bsl': 'GameEra',
  'forge-bootstrap': 'GameEra',
  'fabric-knot': 'GameEra',
  'modlauncher-legacy': 'GameEra',
};

export function readAll(root = ROOT) {
  const out = {};
  for (const [key, rel] of Object.entries(SOURCES)) {
    const abs = path.join(root, rel);
    // 缺文件报 fatal，不静默当空 —— 那正好发生在有人搬了文件的时候。
    out[key] = fs.existsSync(abs) ? fs.readFileSync(abs, 'utf8') : null;
  }
  return out;
}

/**
 * 抠出 `enum LoaderGeneration` 的成员值（右侧字符串字面量）。
 *
 * ⚠️ 锚点要求 `{`，且在剥注释后的文本上跑：注释里有一整张世代表，
 * 不剥的话会把文档里的示例当成枚举成员 —— 这正是
 * `check-renderer-registry.mjs` §S5.1 踩过的坑（一道门禁如果不剥注释，
 * 就会开始禁止"解释为什么这么写"）。
 */
export function parseGenerationEnum(text) {
  const clean = stripComments(text, { lang: 'js' });
  const m = /export\s+enum\s+LoaderGeneration\s*\{/.exec(clean);
  if (!m) return null;
  const open = m.index + m[0].length - 1;
  const body = braceBody(clean, open);
  if (body === null) return null;
  const values = [];
  const re = /([A-Za-z0-9_]+)\s*=\s*'([^']*)'/g;
  let hit;
  while ((hit = re.exec(body)) !== null) values.push({ member: hit[1], value: hit[2] });
  return values;
}

/** 抠出契约表每一行的关键字段。 */
export function parseContracts(text) {
  const clean = stripComments(text, { lang: 'js' });
  const decl = /export const LOADER_GENERATION_CONTRACTS[^=]*=\s*\[/.exec(clean);
  if (!decl) return null;
  const open = decl.index + decl[0].length - 1;
  const body = braceBody(clean, open, '[', ']');
  if (body === null) return null;

  const rows = [];
  // 逐个顶层 `{ ... }` 取行。
  let i = 0;
  while (i < body.length) {
    const s = body.indexOf('{', i);
    if (s < 0) break;
    const inner = braceBody(body, s);
    if (inner === null) break;
    rows.push(parseRow(inner));
    i = s + inner.length + 2;
  }
  return rows;
}

function parseRow(inner) {
  const gen = /generation:\s*LoaderGeneration\.([A-Za-z0-9_]+)/.exec(inner);
  const delivery = /classpathDelivery:\s*(?:ClasspathDelivery\.([A-Za-z0-9_]+)|([A-Za-z0-9_]+))/
    .exec(inner);
  const isolation = /isolationAsserts:\s*(true|false)/.exec(inner);
  const legacyCp = /requiresLegacyClassPathProperty:\s*(true|false)/.exec(inner);
  const urlCl = /requiresUrlClassLoaderSystemLoader:\s*(true|false)/.exec(inner);
  const jdk = /pinnedJdkMajor:\s*'([^']*)'/.exec(inner);
  const ceiling = /jdkCeiling:\s*JdkCeiling\.([A-Za-z0-9_]+)/.exec(inner);
  const mainsBlock = /mainClasses:\s*\[([\s\S]*?)\]/.exec(inner);
  const mains = [];
  if (mainsBlock) {
    const re = /'([^']+)'/g;
    let h;
    while ((h = re.exec(mainsBlock[1])) !== null) mains.push(h[1]);
  }
  return {
    memberRef: gen ? gen[1] : null,
    deliveryRef: delivery ? (delivery[1] ?? delivery[2]) : null,
    isolationAsserts: isolation ? isolation[1] === 'true' : null,
    requiresLegacyClassPathProperty: legacyCp ? legacyCp[1] === 'true' : null,
    requiresUrlClassLoaderSystemLoader: urlCl ? urlCl[1] === 'true' : null,
    pinnedJdkMajor: jdk ? jdk[1] : null,
    jdkCeiling: ceiling ? ceiling[1] : null,
    mainClasses: mains,
  };
}

/** 抠出 `enum ClasspathDelivery` 的成员名 → 字面量映射。 */
export function parseDeliveryEnum(text) {
  const clean = stripComments(text, { lang: 'js' });
  const m = /export\s+enum\s+ClasspathDelivery\s*\{/.exec(clean);
  if (!m) return null;
  const body = braceBody(clean, m.index + m[0].length - 1);
  if (body === null) return null;
  const out = {};
  const re = /([A-Za-z0-9_]+)\s*=\s*'([^']*)'/g;
  let hit;
  while ((hit = re.exec(body)) !== null) out[hit[1]] = hit[2];
  return out;
}

/** 从 `open` 位置的括号开始，返回其内部文本（不含两端括号）。不平衡返回 null。 */
function braceBody(text, open, o = '{', c = '}') {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === o) depth++;
    else if (text[i] === c) {
      depth--;
      if (depth === 0) return text.slice(open + 1, i);
    }
  }
  return null;
}

export function analyze(files) {
  const errors = [];
  const notes = [];

  for (const [key, rel] of Object.entries(SOURCES)) {
    if (files[key] === null) errors.push(`源文件缺失：${rel}（key=${key}）`);
  }
  if (errors.length > 0) return { ok: false, errors, notes };

  const enumValues = parseGenerationEnum(files.registry);
  const contracts = parseContracts(files.registry);
  const deliveryEnum = parseDeliveryEnum(files.registry);

  if (!enumValues || enumValues.length === 0) {
    errors.push('解析不到 enum LoaderGeneration 的成员');
  }
  if (!contracts || contracts.length === 0) {
    errors.push('解析不到 LOADER_GENERATION_CONTRACTS 的条目');
  }
  if (!deliveryEnum || Object.keys(deliveryEnum).length === 0) {
    errors.push('解析不到 enum ClasspathDelivery 的成员');
  }
  if (errors.length > 0) return { ok: false, errors, notes };

  // ── A 组：结构完整性（G3）────────────────────────────────────────────
  const rowByMember = new Map();
  for (const r of contracts) {
    if (!r.memberRef) {
      errors.push('契约表里有一行解析不出 generation 字段');
      continue;
    }
    if (rowByMember.has(r.memberRef)) {
      errors.push(`契约表里 LoaderGeneration.${r.memberRef} 出现了多行`);
    }
    rowByMember.set(r.memberRef, r);
  }
  for (const e of enumValues) {
    if (!rowByMember.has(e.member)) {
      errors.push(`[G3] 世代 LoaderGeneration.${e.member}（'${e.value}'）在 `
        + 'LOADER_GENERATION_CONTRACTS 里没有对应行 —— 新增世代必须填契约表');
    }
  }
  for (const member of rowByMember.keys()) {
    if (!enumValues.some((e) => e.member === member)) {
      errors.push(`契约表里的 LoaderGeneration.${member} 不在枚举里`);
    }
  }

  const valueOf = (member) => (enumValues.find((e) => e.member === member) ?? {}).value ?? null;
  const deliveryLiteral = (ref) => {
    if (ref === null) return null;
    if (deliveryEnum[ref] !== undefined) return deliveryEnum[ref];
    // 允许经 UNKNOWN_GENERATION_DELIVERY 这类常量间接引用。
    const m = new RegExp(`export const ${ref}[^=]*=\\s*ClasspathDelivery\\.([A-Za-z0-9_]+)`)
      .exec(stripComments(files.registry, { lang: 'js' }));
    return m ? (deliveryEnum[m[1]] ?? null) : null;
  };

  // ── B 组：isolationAsserts ⟺ delivery === amcl-loader-only ──────────
  for (const [member, r] of rowByMember) {
    const lit = deliveryLiteral(r.deliveryRef);
    if (lit === null) {
      errors.push(`LoaderGeneration.${member} 的 classpathDelivery 解析不出字面量`
        + `（ref=${r.deliveryRef}）`);
      continue;
    }
    if (lit !== DELIVERY_AMCL_LOADER_ONLY && lit !== DELIVERY_JVM_CLASSPATH_FULL) {
      errors.push(`LoaderGeneration.${member} 的 delivery 字面量 '${lit}' 不是已知的两种之一`);
      continue;
    }
    const expectIsolation = lit === DELIVERY_AMCL_LOADER_ONLY;
    if (r.isolationAsserts !== expectIsolation) {
      errors.push(`LoaderGeneration.${member}: isolationAsserts=${r.isolationAsserts} 与 `
        + `delivery='${lit}' 不一致（必须严格同真；契约见规范 §3.4）`);
    }
  }

  // ── C 组：主键卫生 ─────────────────────────────────────────────────
  const seenMain = new Map();
  for (const [member, r] of rowByMember) {
    const isUnknown = valueOf(member) === 'unknown';
    if (r.mainClasses.length === 0 && !isUnknown) {
      errors.push(`LoaderGeneration.${member} 的 mainClasses 为空（只有 unknown 允许为空，`
        + '它由"没有任何一行命中"定义）');
    }
    if (r.mainClasses.length > 0 && isUnknown) {
      errors.push('LoaderGeneration.Unknown 不得声明 mainClasses');
    }
    for (const mc of r.mainClasses) {
      if (seenMain.has(mc)) {
        errors.push(`mainClass '${mc}' 同时出现在 ${seenMain.get(mc)} 与 ${member} 两行 —— `
          + '主键必须唯一（要共享契约请把两个世代并成一行）');
      }
      seenMain.set(mc, member);
    }
  }

  // ── D 组：棘轮钉住值（G2）───────────────────────────────────────────
  for (const [genValue, expected] of Object.entries(PINNED_DELIVERY)) {
    const member = (enumValues.find((e) => e.value === genValue) ?? {}).member ?? null;
    if (member === null) {
      errors.push(`[G2] 钉住表引用的世代 '${genValue}' 已不在枚举里 —— `
        + '删一个有真机取证的世代必须先更新 PINNED_DELIVERY 并记录新证据');
      continue;
    }
    const r = rowByMember.get(member);
    const lit = r ? deliveryLiteral(r.deliveryRef) : null;
    if (lit !== expected) {
      errors.push(`[G2] 世代 '${genValue}' 的 delivery 是 '${lit}'，钉住值是 '${expected}'。`
        + '这条钉住值由真机/反汇编取证确立（见本文件 PINNED_DELIVERY 的逐行出处）。'
        + '若改动是有意的，必须同时在 docs/refactor/启动架构世代化施工记录.md 记下新证据，'
        + '并重跑该世代的真机验收。');
    }
  }

  // ── D2 组：legacyClassPath 要求的棘轮 ───────────────────────────────
  for (const [genValue, expected] of Object.entries(PINNED_LEGACY_CLASSPATH)) {
    const member = (enumValues.find((e) => e.value === genValue) ?? {}).member ?? null;
    if (member === null) {
      errors.push(`[G2] 钉住表引用的世代 '${genValue}' 已不在枚举里`);
      continue;
    }
    const r = rowByMember.get(member);
    const actual = r ? r.requiresLegacyClassPathProperty : null;
    if (actual !== expected) {
      errors.push(`[G2] 世代 '${genValue}' 的 requiresLegacyClassPathProperty 是 ${actual}，`
        + `钉住值是 ${expected}。该值由 2026-09-04 真机取证确立（官方 JSON 里该属性 0 次`
        + '出现，而 AMCL 从未注入它；填 true 会让整代 Forge 1.17–1.20.1 无法启动）。'
        + '若改动是有意的，必须同时在 docs/refactor/启动架构世代化施工记录.md 记下新证据，'
        + '并重跑该世代的真机验收。');
    }
  }

  // ── D3 组：jdkCeiling —— 结构不变量 + 棘轮 + **必须有消费者** ────────
  // ⭐ 第三条是本轮新立的通用纪律（施工记录 §S09.4 ②）：契约表里一个"看起来像守卫"
  // 却没有任何产品代码读取的字段是**假保护**。`requiresUrlClassLoaderSystemLoader`
  // 至今就是这个状态；`pinnedJdkMajor` 在批次 D 之前也只有校验者没有消费者，
  // 而 JdkManager 用子串规则自己重算了一份 —— 那正是本次拒启/闪退的来源。
  for (const [member, r] of rowByMember) {
    if (r.jdkCeiling === null) {
      errors.push(`[D3] LoaderGeneration.${member} 缺 jdkCeiling 字段 —— `
        + '新增世代必须声明它能否跑在比游戏纪元更新的 JDK 上（默认应填 GameEra）');
      continue;
    }
    if (r.jdkCeiling !== 'None' && r.jdkCeiling !== 'GameEra') {
      errors.push(`[D3] LoaderGeneration.${member} 的 jdkCeiling='${r.jdkCeiling}' 不是已知取值`);
      continue;
    }
    // 结构不变量：None ⟺ 原版（与 isolationAsserts ⟺ delivery 同一形状）。
    const isVanilla = valueOf(member) === 'vanilla';
    if ((r.jdkCeiling === 'None') !== isVanilla) {
      errors.push(`[D3] LoaderGeneration.${member} 的 jdkCeiling=${r.jdkCeiling} 与"只有原版无上限"`
        + '这条结构不变量冲突。加载器自带的 ASM/Mixin 是按游戏纪元那一代的 Java 编的，'
        + '给它更新的 JDK 会崩在 Unsupported class file major version（2026-09-04 真机）。');
    }
  }
  for (const [genValue, expected] of Object.entries(PINNED_JDK_CEILING)) {
    const member = (enumValues.find((e) => e.value === genValue) ?? {}).member ?? null;
    if (member === null) {
      errors.push(`[D3] 钉住表引用的世代 '${genValue}' 已不在枚举里`);
      continue;
    }
    const r = rowByMember.get(member);
    const actual = r ? r.jdkCeiling : null;
    if (actual !== expected) {
      errors.push(`[D3] 世代 '${genValue}' 的 jdkCeiling 是 ${actual}，钉住值是 ${expected}。`
        + '该值由 2026-09-04 真机取证确立（1.19.4-forge 在 JDK 25 上 ASM 9.7.1 崩、'
        + '换 17 后启动成功）。若改动是有意的，必须同时在施工记录里记下新证据并重跑真机。');
    }
  }
  // 消费者断言：字段必须被产品代码真的读到，且**只在唯一那处策略里**。
  const jdkPolicy = stripComments(files.jdkPolicy, { lang: langForPath(SOURCES.jdkPolicy) });
  // ⚠️ **必须带词边界。** 第一版写的是 `includes('JdkCeiling.GameEra')`，而自测把它改成
  // `JdkCeiling.GameEraX` —— 前者是后者的子串，判据在"消费者被改名"这个**唯一要挡的形态**
  // 上恒真。这已经是同一族缺陷的第三次（§S02.4 的 `amcl-loader-onlyX`、本节两条），
  // 判据：**子串包含不能用来断言"某个精确记号存在"。**
  if (!/\bJdkCeiling\.GameEra\b/.test(jdkPolicy)) {
    errors.push(`[D3] ${SOURCES.jdkPolicy} 没有消费 jdkCeiling —— `
      + '一个没有消费者的契约字段是假保护（它看起来像守卫，实际什么都不守）');
  }
  if (!/\bpinnedJdkMajor\b/.test(jdkPolicy)) {
    errors.push(`[D3] ${SOURCES.jdkPolicy} 没有消费 pinnedJdkMajor —— `
      + '批次 D 之前它只有校验者没有消费者，路由自己用子串规则重算了一份');
  }
  // ⭐ 上限的**主来源**是逐版本实读 ASM，世代兜底只是数据缺失时的退路。
  // 丢掉实读就等于退回"按纪元收紧"，而那一版被真机否证过（把 JDK 21 这种合法组合拦掉）。
  if (!/\bfindAsmSupport\s*\(/.test(jdkPolicy)) {
    errors.push(`[D3] ${SOURCES.jdkPolicy} 没有调用 findAsmSupport —— `
      + '上限会退回"按世代纪元收紧"，而那一版把 JDK 21 这种合法组合也拦掉了（§S12）');
  }

  // ── D4 组：ASM 断点表的棘轮 ────────────────────────────────────────
  // 这张表是上限的全部数据来源。改动它意味着推翻一条上游事实或一条真机对照。
  const asmTable = stripComments(files.asmTable, { lang: langForPath(SOURCES.asmTable) });
  for (const [asmVersion, expected] of Object.entries(PINNED_ASM_MAX_JAVA)) {
    const re = new RegExp(
      `asm:\\s*'${asmVersion.replace(/\./g, '\\.')}'\\s*,\\s*maxJavaMajor:\\s*(\\d+)`);
    const hit = re.exec(asmTable);
    if (hit === null) {
      errors.push(`[D4] ${SOURCES.asmTable} 里缺 ASM ${asmVersion} 这条断点 —— `
        + '它由上游版本页确立，其中 9.7.1 / 9.10 两条还与真机行为直接对上');
      continue;
    }
    if (Number(hit[1]) !== expected) {
      errors.push(`[D4] ASM ${asmVersion} 的上限是 Java ${hit[1]}，钉住值是 ${expected}。`
        + '这张表是 JDK 上限的全部数据来源：改小会拦掉能跑的组合（用户已因此被拒启一次），'
        + '改大会放过必崩的组合（1.19.4-forge + JDK 25）。改它必须同时给出上游依据与真机复验。');
    }
  }
  // ⚠️ 第二判定者不得复活：JdkManager 只许消费契约表，不许自己用版本名子串判世代。
  // 作用域刻意只到这一个文件（`LaunchProfileBuilder.isForgeProfile` 驱动 fml.toml /
  // splash 写入，"是不是 Forge 家族"在那里确实是个布尔问题，与 classpath/JDK 契约正交）。
  const jdkManager = stripComments(files.jdkManager, { lang: langForPath(SOURCES.jdkManager) });
  for (const needle of ["indexOf('forge')", 'indexOf("forge")',
    "indexOf('fabric')", 'indexOf("fabric")']) {
    if (jdkManager.includes(needle)) {
      errors.push(`[D3] ${SOURCES.jdkManager} 里出现了 ${needle} —— `
        + '世代判定只有一处（LoaderGenerationResolver）。子串判定曾让 isForge 对四代同时为真，'
        + '而它的第五份副本正好决定 JDK 路由（施工记录 §S09.4 ①）。');
    }
  }
  if (!/resolveJdkPolicy\s*\(/.test(jdkManager)) {
    errors.push(`[D3] ${SOURCES.jdkManager} 没有调用 resolveJdkPolicy —— 路由没接上契约表`);
  }

  // ── E 组：跨语言一致 ───────────────────────────────────────────────
  const cpp = stripComments(files.nativeLauncher, { lang: langForPath(SOURCES.nativeLauncher) });
  const java = stripComments(files.javaLauncher, { lang: langForPath(SOURCES.javaLauncher) });

  // ⚠️ **必须找带引号的完整字面量，不能用子串包含。**
  // 第一版写的是 `cpp.includes('amcl-loader-only')`，而自测把字面量改成
  // `amcl-loader-onlyX` 之后它**仍然为真**（前者是后者的子串）⇒ 这条判据在
  // "字面量被改坏"这个**唯一要挡的形态**上恒真。是本门禁自测第一次运行时抓到的
  // （施工记录 §S02.4）。讽刺的是：本次重构要消灭的正是子串匹配那一族缺陷。
  const quoted = (lit) => `"${lit}"`;
  if (!cpp.includes(quoted(DELIVERY_AMCL_LOADER_ONLY))) {
    errors.push(`[E] ${SOURCES.nativeLauncher} 的代码里没有 ${quoted(DELIVERY_AMCL_LOADER_ONLY)} `
      + '字面量 —— C 层判不出该走收窄还是完整 classpath');
  }
  if (!cpp.includes(DELIVERY_ARG_KEY)) {
    errors.push(`[E] ${SOURCES.nativeLauncher} 没有扫 '${DELIVERY_ARG_KEY}' —— `
      + 'delivery 决策没有接上执行者，等于 ArkTS 那半白算');
  }
  if (!java.includes(quoted(DELIVERY_AMCL_LOADER_ONLY))) {
    errors.push(`[E] ${SOURCES.javaLauncher} 的代码里没有 ${quoted(DELIVERY_AMCL_LOADER_ONLY)} `
      + '字面量 —— 隔离断言的作用域判据与运行期校验都依赖它');
  }
  // ArkTS 侧必须真的把 marker 追加进 jvmArgs（否则 C++ 永远扫不到）。
  const preflight = stripComments(files.preflight, { lang: 'js' });
  if (!preflight.includes(DELIVERY_ARG_KEY)) {
    errors.push(`[E] ${SOURCES.preflight} 里没有定义 marker 键 '${DELIVERY_ARG_KEY}'`);
  }

  notes.push(`世代数=${enumValues.length} 契约行数=${rowByMember.size} `
    + `钉住 delivery=${Object.keys(PINNED_DELIVERY).length} `
    + `钉住 legacyClassPath=${Object.keys(PINNED_LEGACY_CLASSPATH).length} `
    + `钉住 jdkCeiling=${Object.keys(PINNED_JDK_CEILING).length} `
    + `钉住 asm 断点=${Object.keys(PINNED_ASM_MAX_JAVA).length}`);
  return { ok: errors.length === 0, errors, notes };
}

function main() {
  const asJson = process.argv.includes('--json');
  const result = analyze(readAll());
  if (asJson) {
    console.log(JSON.stringify(result, null, 2));
  } else {
    for (const n of result.notes) console.log(`[info]  ${n}`);
    for (const e of result.errors) console.error(`[FAIL]  ${e}`);
    console.log(result.ok
      ? '[PASS]  launch generation contract: 结构 / 一致性 / 棘轮 / 跨语言 全部通过'
      : '[FAIL]  launch generation contract 校验未通过');
  }
  process.exit(result.ok ? 0 : 1);
}

if (import.meta.url === url.pathToFileURL(process.argv[1] ?? '').href) main();
