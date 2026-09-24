#!/usr/bin/env node
// scripts/check-launch-agent-probe.mjs
//
// ============================ 它挡的是什么 ============================
//
// 批次 C（字节码变换 agent 化）的 **Phase C0 探针**必须满足四条纪律，而这四条
// **一条都不会在运行期报错**：
//
//   1. **默认关。** 探针默认开启就等于把一个未验证的机制放进产品路径（C0-A2）。
//      而"默认关"是个声明，声明与产品实际值是两个事实（AGENTS.md §二.5）⇒
//      本门禁只管声明这一半，另一半由 `AMCL_AGENT_PROBE` 日志行与真机 `[AMCL-AGENT]` 行反查。
//   2. **C0 不变换任何字节。** 方案 §5.3 的排期纪律：C1 只证明"transformer 被调用到了
//      目标类"，变换要到 C2 才搬进去。混批之后真机一出问题就无法归因是哪一半。
//   3. **transformer 自己 catch (Throwable) 并计数。** C0-3 要量的就是"transform 抛异常时
//      JVM 是否静默"；若结论是静默（JPLIS 规范如此），不自己 catch + 计数就会让
//      "探针挂了"与"探针没命中"完全不可区分（本仓 1000544 那一族）。
//   4. **快路径名字过滤。** transformer 对**每一个**类都会被调用（方案 §6 风险 4）。
//
// 另外两条来自方案 §7 的"明确不做"：
//   5. ⛔ 不引入 ASM（会与 Forge 模块层里的 org.objectweb.asm 具体版本纠缠）。
//   6. ⛔ 不用 retransform/redefine（会让 JVM 为目标类保留更多元数据）。
//
// 以及两条"声明与实际配对"：
//   7. `Premain-Class` 声明的类必须真的存在且有 premain 方法 —— 否则 `-javaagent:`
//      会直接**终止 JVM 启动**（"Failed to find Premain-Class manifest attribute"），
//      表现是"开了探针就起不来"，而那与探针本身的结论无关。
//   8. marker 键在 ArkTS 与 Java 两侧必须逐字相同，否则一侧开、另一侧不认，
//      日志里长成"注入了 agent 但 premain 说 marker 缺失"。
//
// ============================ 它不能证明什么 ============================
//
// ❌ 不证明 agent 在真机上真的 premain 成功（那要看 `[AMCL-AGENT] phase=premain`）。
// ❌ 不证明 C0 的三个未知量的答案（那三条**只能**由真机回答，写在施工记录里）。
// ❌ 不解压 jar 校验清单里的 Premain-Class（node 侧不引 zip 依赖）——
//    只按 zip 目录里的明文条目名断言 class 进了包；清单那一半由真机是否出现
//    `phase=premain` 来证明，那是比解压更强的证据。
//
// 用法：
//   node scripts/check-launch-agent-probe.mjs
//   node scripts/check-launch-agent-probe.mjs --json

import fs from 'node:fs';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';
import path from 'node:path';
import url from 'node:url';

import { stripComments, langForPath } from './lib/source-noise.mjs';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');

export const SOURCES = {
  arkts: 'launch/src/main/ets/LaunchAgentProbe.ets',
  wiring: 'launch/src/main/ets/LaunchProfileBuilder.ets',
  probe: 'JavaApp/src/com/amcl/launcher/AmclAgentProbe.java',
  patcher: 'JavaApp/src/com/amcl/launcher/TerrainCompatibilityPatcher.java',
  javaLauncher: 'JavaApp/src/com/amcl/launcher/AmclLauncher.java',
  builder: 'scripts/build-amcl-launcher.mjs',
};

/** 产物（可缺失：CI 上没有构建过）。 */
const LAUNCHER_JAR = 'entry/src/main/resources/rawfile/amcl-launcher.jar';

/** 两侧必须逐字对应的 marker。ArkTS 侧带 `-D` 与 `=`，Java 侧是裸属性名。 */
export const PROBE_ARG_KEY = '-Damcl.agentProbe=';
export const PROBE_PROP = 'amcl.agentProbe';
/** 跨局结论文件的路径键。两侧同样必须逐字对应。 */
export const PROBE_LOG_ARG_KEY = '-Damcl.agentProbe.log=';
export const PROBE_LOG_PROP = 'amcl.agentProbe.log';
export const PREMAIN_CLASS = 'com.amcl.launcher.AmclAgentProbe';

export function readAll(root = ROOT) {
  const out = {};
  for (const [key, rel] of Object.entries(SOURCES)) {
    const abs = path.join(root, rel);
    out[key] = fs.existsSync(abs) ? fs.readFileSync(abs, 'utf8') : null;
  }
  const jar = path.join(root, LAUNCHER_JAR);
  out.jarBytes = fs.existsSync(jar) ? fs.readFileSync(jar) : null;
  // Standalone Java tests may clean JavaApp/build. Read the inspected JAR's
  // own identity instead of trusting a separate, possibly stale sidecar.
  const manifest = out.jarBytes ? readUniqueZipEntry(out.jarBytes, 'META-INF/MANIFEST.MF').toString() : '';
  out.developerProduct = out.jarBytes ? manifest.includes('Premain-Class:') : true;
  return out;
}

/**
 * 抠出一个方法/函数的体（从签名后的第一个 `{` 起花括号配平）。
 * 剥注释之后再调用 —— 注释里的花括号会让配平失效。
 */
export function methodBody(text, signatureNeedle) {
  const at = text.indexOf(signatureNeedle);
  if (at < 0) return null;
  const open = text.indexOf('{', at);
  if (open < 0) return null;
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === '{') depth++;
    else if (text[i] === '}') {
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
    if (files[key] === null || files[key] === undefined) {
      errors.push(`源文件缺失：${rel}（key=${key}）`);
    }
  }
  if (errors.length > 0) return { ok: false, errors, notes };

  // 逐文件问语言模式（源码噪声模块的纪律）：`.java` 走 C 家族规则，`.ets`/`.mjs` 走 js。
  const strip = (key) => stripComments(files[key], { lang: langForPath(SOURCES[key]) });
  const arkts = strip('arkts');
  const wiring = strip('wiring');
  const probe = strip('probe');
  const patcher = strip('patcher');
  const launcher = strip('javaLauncher');
  const builder = strip('builder');

  // ── A 组：跨语言 marker 一致 ────────────────────────────────────────
  // 带定界符找完整字面量。子串包含不能用来断言"某个精确记号存在"
  // （施工记录 §S02.4：`amcl-loader-onlyX` 曾让同类判据恒真）。
  if (!arkts.includes(`'${PROBE_ARG_KEY}'`)) {
    errors.push(`[A] ${SOURCES.arkts} 里没有 '${PROBE_ARG_KEY}' 这个完整字面量`);
  }
  if (!probe.includes(`"${PROBE_PROP}"`)) {
    errors.push(`[A] ${SOURCES.probe} 里没有 "${PROBE_PROP}" 这个完整字面量 —— `
      + 'ArkTS 侧开、Java 侧不认，日志会长成"注入了 agent 但 premain 说 marker 缺失"');
  }
  if (PROBE_ARG_KEY !== `-D${PROBE_PROP}=`) {
    errors.push(`[A] 本门禁自己的两个常量不配对：${PROBE_ARG_KEY} vs ${PROBE_PROP}`);
  }
  // 结论文件路径键同理两侧对齐。它承载的是**跨局**证据：mc_output.log 每局截断重写，
  // 一次性探针结论只写那里等于会丢（2026-09-04 真机丢过一整轮）。
  if (!arkts.includes(`'${PROBE_LOG_ARG_KEY}'`)) {
    errors.push(`[A] ${SOURCES.arkts} 里没有 '${PROBE_LOG_ARG_KEY}' 这个完整字面量`);
  }
  if (!probe.includes(`"${PROBE_LOG_PROP}"`)) {
    errors.push(`[A] ${SOURCES.probe} 里没有 "${PROBE_LOG_PROP}" —— `
      + '探针结论就只会写进每局被覆盖的 mc_output.log');
  }
  if (PROBE_LOG_ARG_KEY !== `-D${PROBE_LOG_PROP}=`) {
    errors.push(`[A] 本门禁自己的两个常量不配对：${PROBE_LOG_ARG_KEY} vs ${PROBE_LOG_PROP}`);
  }

  // ── B 组：默认关 ───────────────────────────────────────────────────
  if (!/AGENT_PROBE_DEFAULT_ON\s*:\s*boolean\s*=\s*false/.test(arkts)) {
    errors.push('[B] ArkTS 侧的 AGENT_PROBE_DEFAULT_ON 不是 false —— '
      + '探针默认开启等于把未验证的机制放进产品路径（C0-A2）');
  }
  // 注入必须挂在 injected 这个条件上，不允许无条件构造 -javaagent。
  if (!/injected\s*\?\s*\[\s*'-javaagent:'\s*\+\s*launcherJarPath\s*\]\s*:\s*\[\s*\]/.test(arkts)) {
    errors.push('[B] ArkTS 侧没有"仅在 injected 为真时才产出 -javaagent"这个形状');
  }
  if (!/resolveAgentProbe\s*\(/.test(wiring)) {
    errors.push(`[B] ${SOURCES.wiring} 没有调用 resolveAgentProbe —— 判定没接上`);
  }
  // Java 侧第二道门：premain 必须先比 marker 再 addTransformer。
  const premain = methodBody(probe, 'static void premain(');
  if (premain === null) {
    errors.push(`[B] ${SOURCES.probe} 里找不到 premain 的方法体`);
  } else {
    const guardAt = premain.indexOf('PROBE_ON.equals');
    const installAt = premain.indexOf('addTransformer');
    if (guardAt < 0) {
      errors.push('[B] premain 里没有 marker 判断 —— Java 侧的第二道门没了');
    } else if (installAt < 0 || guardAt > installAt) {
      errors.push('[B] premain 先 addTransformer 再判 marker（顺序反了，等于没有第二道门）');
    }
  }

  // ── C 组：C0 不变换 ────────────────────────────────────────────────
  const transform = methodBody(probe, 'public byte[] transform(');
  if (transform === null) {
    errors.push(`[C] ${SOURCES.probe} 里找不到 transform 的方法体`);
  } else {
    for (const match of transform.matchAll(/return\s+([^;]*);/g)) {
      const value = match[1].trim();
      if (value !== 'null') {
        errors.push(`[C] transform 有一条非 null 的 return（'${value}'）—— `
          + 'C0 不得变换任何字节（方案 §5.3）');
      }
    }
    for (const forbidden of ['patchKnownClass', 'patchInvocation', 'patchFieldRead',
      'patchLongConstantLoads', 'applySubmitDepthTransform', 'applyUploadTimingTransform']) {
      if (transform.includes(forbidden)) {
        errors.push(`[C] transform 调用了变换入口 ${forbidden} —— C0 只读`);
      }
    }

    // ── D 组：显式 catch + 计数 ──────────────────────────────────────
    if (!/catch\s*\(\s*Throwable/.test(transform)) {
      errors.push('[D] transform 没有显式 catch (Throwable) —— '
        + 'JPLIS 会静默吞掉 transformer 的异常，"探针挂了"与"没命中"将不可区分');
    }
    if (!/FAILED\.incrementAndGet\s*\(/.test(transform)) {
      errors.push('[D] transform 的失败路径没有单调计数（AGENTS §二.3）');
    }

    // ── E 组：快路径在贵活之前 ──────────────────────────────────────
    const fastAt = transform.indexOf('isProbeTarget(');
    const workAt = transform.indexOf('probeTarget(loader');
    if (fastAt < 0) {
      errors.push('[E] transform 里没有快路径过滤（方案 §6 风险 4：它对每个类都会被调用）');
    } else if (workAt >= 0 && fastAt > workAt) {
      errors.push('[E] 快路径过滤排在贵活之后，等于没有快路径');
    }
  }

  // ── F 组：方案 §7 的两条"明确不做" ──────────────────────────────────
  for (const forbidden of ['org.objectweb.asm', 'retransformClasses', 'redefineClasses']) {
    if (probe.includes(forbidden)) {
      errors.push(`[F] ${SOURCES.probe} 里出现了 ${forbidden} —— 方案 §7 明确不做`);
    }
  }
  // ⚠️ 不能用 `[^)]*` 收敛实参：真实调用里就有 `new AmclAgentProbe()`，
  // 那个右括号会让判据永远匹配不上 —— 自测第一次运行时正是这样红的。
  if (/addTransformer\s*\([\s\S]{0,160}?,\s*true\s*\)/.test(probe)) {
    errors.push('[F] addTransformer 开了 canRetransform（方案 §7.2 明确不做）');
  }
  if (builder.includes('Can-Retransform-Classes')) {
    errors.push('[F] jar 清单里声明了 Can-Retransform-Classes（方案 §7.2 明确不做）');
  }

  // ── G 组：Premain-Class 的声明与实际配对 ────────────────────────────
  if (!builder.includes(`'${PREMAIN_CLASS}'`)) {
    errors.push(`[G] ${SOURCES.builder} 没有把 Premain-Class 定成 '${PREMAIN_CLASS}'`);
  }
  if (!/Premain-Class:\s*\$\{PREMAIN_CLASS\}/.test(builder)) {
    errors.push('[G] jar 清单文本里没有 Premain-Class 行 —— '
      + '-javaagent 会直接终止 JVM 启动（Failed to find Premain-Class manifest attribute）');
  }
  if (!/jar,\s*\n?\s*\[\s*'cfm'/.test(builder) && !builder.includes("'cfm'")) {
    errors.push("[G] 打包命令不是 jar cfm —— 不带清单的 jar 装不上 agent");
  }
  if (!/public\s+static\s+void\s+premain\s*\(/.test(probe)) {
    errors.push(`[G] ${PREMAIN_CLASS} 没有 public static void premain(...) —— `
      + 'JPLIS 找不到入口');
  }
  if (!launcher.includes('AmclAgentProbe.reportAfterRedirect()')) {
    errors.push(`[G] ${SOURCES.javaLauncher} 没有在换流之后复述 premain 结论 —— `
      + 'premain 期的 stdout 会被 OHOS 丢弃（施工记录 §S05.5），结论看不到等于没有结论');
  }

  // ── H 组：只读判据不得复制一份，且必须在 clone 上跑 ──────────────────
  if (!patcher.includes('static String probeStructuralCriteria(')) {
    errors.push(`[H] ${SOURCES.patcher} 里没有 probeStructuralCriteria —— `
      + '探针若自己抄一份判据，它报告的就是另一套判据');
  }
  for (const helper of ['countInvocations', 'countFieldReads']) {
    const body = methodBody(patcher, `private static int ${helper}(`);
    if (body === null) {
      errors.push(`[H] ${SOURCES.patcher} 里找不到 ${helper} 的方法体`);
      continue;
    }
    if (!body.includes('bytes.clone()')) {
      errors.push(`[H] ${helper} 没有在 clone 上工作 —— 探针必须无副作用`);
    }
  }

  // ── I 组：产物级（jar 存在时才查）─────────────────────────────────
  const entryName = 'com/amcl/launcher/AmclAgentProbe.class';
  if (files.jarBytes === null) {
    notes.push(`产物未构建，跳过产物级断言（${LAUNCHER_JAR}）`);
  } else if (files.developerProduct === false) {
    if (files.jarBytes.includes(entryName)) errors.push('[I] non-default jar contains agent probe');
    else notes.push('non-default jar excludes the agent probe');
  } else if (!files.jarBytes.includes(entryName)) {
    errors.push(`[I] ${LAUNCHER_JAR} 里没有 ${entryName} 这个条目 —— `
      + '门禁全绿但探针类没进出货 jar（AGENTS §二.4）');
  } else {
    notes.push(`产物含 ${entryName}（jar ${files.jarBytes.length} B）`);
  }

  notes.push(`marker=${PROBE_ARG_KEY}1 premain=${PREMAIN_CLASS} 默认=off`);
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
      ? '[PASS]  launch agent probe: 默认关 / 只读 / 显式 catch / 快路径 / 清单配对 全部通过'
      : '[FAIL]  launch agent probe 校验未通过');
  }
  process.exit(result.ok ? 0 : 1);
}

if (import.meta.url === url.pathToFileURL(process.argv[1] ?? '').href) main();
