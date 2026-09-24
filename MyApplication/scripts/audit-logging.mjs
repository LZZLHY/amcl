#!/usr/bin/env node
// scripts/audit-logging.mjs
//
// 落盘渗透率自检：度量「有多少日志调用会进文件」并拦住反模式。
//
//   1. 不准新增裸 `hilog.*` / `OH_LOG_*` —— 这些只进 hilog 易失缓冲、不落盘；
//      应走落盘门面 `AppLogger.*` / `AMCL_LOG_*`。
//   2. 严禁占位 tag `'testTag'`。
//   3. 报告 ArkTS / Native 两层的渗透率与**按模块**的分布。
//
// ─────────────────────────────────────────────────────────────────────────────
// ⚠️ 2026-09-06 修复：本脚本此前的计数**不可用**，`--strict` 恒红且没接进任何地方。
//
// 成因：它原来是「遍历整个仓库 + 跳过一个 denylist」。denylist 里没有 `.tmp-build/`、
// `docker/output/`、`artifacts/`、`prebuilt/`，于是把构建脚手架与第三方 fork 也数了进去 ——
// 同一个 `glfw_compat.cpp` 被数了 5 遍（93/93/93/92/90），451 处 `testTag` **全部**在
// 那些目录里，实测 ArkTS 裸 hilog 1156 vs 真实的两三百，差一个数量级。
//
// ⇒ 改成 **allowlist（只走第一方模块根）**。理由与本方向的架构主张是同一条：
// denylist 的失效形态是「新目录出现 ⇒ 计数静默膨胀」，与「谁 fopen 就多一条日志通道」
// 是同一个形状的错。清单化的东西才管得住。
// 因果见 docs/refactor/日志系统重构施工记录.md §S01.3 / §S04。
// ─────────────────────────────────────────────────────────────────────────────
//
// 用法：
//   node scripts/audit-logging.mjs              # 报告
//   node scripts/audit-logging.mjs --baseline   # 记录当前计数为基线
//   node scripts/audit-logging.mjs --strict     # 提交前/CI：testTag 或超基线即失败

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const BASELINE_PATH = path.join(ROOT, 'scripts', '.logging-baseline.json');

/**
 * 第一方模块根 —— **唯一**被计入渗透率的范围。
 *
 * 新增一个业务模块时要在这里登记，否则它的日志不会被统计（也就管不住）。
 * 这是刻意的：漏登记会让渗透率**看起来变好**，所以下面有一条自检断言总量不会突然掉。
 */
const SOURCE_ROOTS = [
  'account', 'commons', 'entry', 'feature_core', 'feature_system',
  'gamecontrol', 'launch', 'mods', 'update', 'JavaApp',
];

/**
 * 模块内仍要跳过的子目录：测试与构建产物不是产品日志。
 * ⚠️ 带点的两个目录是自测抓出来的，不是想出来的：
 *   - `.test/`    —— hypium 的 `testability` 脚手架，只写 `test` 会漏掉（每模块多算 8 处裸 hilog）
 *   - `.preview/` —— DevEco 生成的预览脚手架，`FakeUIAbility.ets` 里带 `testTag` 占位，
 *                    会让 `--strict` 因为一份**生成代码**恒红
 */
const SKIP_DIRS = new Set([
  'build', '.hvigor', '.cxx', 'oh_modules', 'node_modules',
  'test', '.test', 'ohosTest', 'mock', '.preview',
]);

/** 允许出现裸调用的「门面内部实现」文件：这些就是封装裸 API 的地方。 */
const ARKTS_BARE_EXEMPT = [
  'commons/src/main/ets/utils/AppLogger.ets',
  'commons/src/main/ets/common/NativeLogSink.ets',
];
const NATIVE_BARE_EXEMPT = [
  'entry/src/main/cpp/utils/amcl_log.h',
  'entry/src/main/cpp/utils/amcl_log.cpp',
  // 产品诊断策略层：它按设计要拦截 OH_LOG_Print 本身。
  'entry/src/main/cpp/utils/product_hilog.h',
  'entry/src/main/cpp/utils/amcl_log_bridge.h',
];

const HILOG_CALL_RE = /\bhilog\.(debug|info|warn|error|fatal)\s*\(/g;
const APPLOGGER_RE  = /\bAppLogger\.(debug|info|warn|error|fatal)\s*\(/g;
const OHLOG_RE      = /\bOH_LOG_(DEBUG|INFO|WARN|ERROR|FATAL)\s*\(/g;
const AMCLLOG_RE    = /\bAMCL_(?:EXTERNAL_)?LOG_[DIWEF]\s*\(/g;
const TESTTAG_RE    = /['"]testTag['"]/g;

function relPath(abs) {
  return path.relative(ROOT, abs).replace(/\\/g, '/');
}

function walk(dir, exts, out) {
  let ents;
  try {
    ents = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const ent of ents) {
    if (ent.isDirectory()) {
      if (SKIP_DIRS.has(ent.name)) continue;
      walk(path.join(dir, ent.name), exts, out);
    } else if (ent.isFile() && exts.some((e) => ent.name.endsWith(e))) {
      out.push(path.join(dir, ent.name));
    }
  }
}

function countMatches(text, re) {
  re.lastIndex = 0;
  let n = 0;
  while (re.exec(text) !== null) n++;
  return n;
}

/** 一个文件属于哪个模块（用于按模块分布）。 */
function moduleOf(rel) {
  return rel.split('/')[0];
}

export function analyze(readFile = (p) => fs.readFileSync(p, 'utf8')) {
  const etsFiles = [];
  const nativeFiles = [];
  for (const root of SOURCE_ROOTS) {
    const abs = path.join(ROOT, root);
    if (!fs.existsSync(abs)) continue;
    walk(abs, ['.ets'], etsFiles);
    walk(abs, ['.cpp', '.h', '.hpp', '.cc', '.c'], nativeFiles);
  }

  const perModule = new Map();
  const bump = (mod, key, n) => {
    const m = perModule.get(mod) || { facadeArk: 0, bareArk: 0, facadeNative: 0, bareNative: 0 };
    m[key] += n;
    perModule.set(mod, m);
  };

  let arktsBare = 0, arktsFacade = 0, nativeBare = 0, nativeFacade = 0;
  const testTagHits = [];
  const arktsBareByFile = [];
  const nativeBareByFile = [];

  for (const f of etsFiles) {
    const rel = relPath(f);
    const text = readFile(f);
    const facade = countMatches(text, APPLOGGER_RE);
    arktsFacade += facade;
    bump(moduleOf(rel), 'facadeArk', facade);
    const bare = countMatches(text, HILOG_CALL_RE);
    if (!ARKTS_BARE_EXEMPT.includes(rel)) {
      arktsBare += bare;
      bump(moduleOf(rel), 'bareArk', bare);
      if (bare > 0) arktsBareByFile.push({ rel, n: bare });
    }
    const lines = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      TESTTAG_RE.lastIndex = 0;
      const m = TESTTAG_RE.exec(lines[i]);
      if (!m) continue;
      const before = lines[i].slice(0, m.index);
      const trimmed = lines[i].trim();
      const inComment = before.includes('//') || trimmed.startsWith('*') || trimmed.startsWith('/*');
      if (!inComment) testTagHits.push(`${rel}:${i + 1}`);
    }
  }

  for (const f of nativeFiles) {
    const rel = relPath(f);
    const text = readFile(f);
    const facade = countMatches(text, AMCLLOG_RE);
    nativeFacade += facade;
    bump(moduleOf(rel), 'facadeNative', facade);
    const bare = countMatches(text, OHLOG_RE);
    if (!NATIVE_BARE_EXEMPT.includes(rel)) {
      nativeBare += bare;
      bump(moduleOf(rel), 'bareNative', bare);
      if (bare > 0) nativeBareByFile.push({ rel, n: bare });
    }
  }

  return {
    scannedEts: etsFiles.length,
    scannedNative: nativeFiles.length,
    arktsBare, arktsFacade, nativeBare, nativeFacade,
    testTagHits,
    arktsBareByFile: arktsBareByFile.sort((a, b) => b.n - a.n),
    nativeBareByFile: nativeBareByFile.sort((a, b) => b.n - a.n),
    perModule: [...perModule.entries()]
      .map(([mod, v]) => ({ mod, ...v }))
      .sort((a, b) => (b.bareArk + b.bareNative) - (a.bareArk + a.bareNative)),
  };
}

const pct = (facade, bare) => {
  const total = facade + bare;
  return total === 0 ? '—' : ((facade / total) * 100).toFixed(1) + '%';
};

/**
 * `--strict` 的判定，抽出来是为了让自测能直接喂构造的输入。
 *
 * ⭐ 承重项是 `scannedEts` 那条**缩水守卫**：漏登记一个 SOURCE_ROOTS 会让裸调用计数变小，
 * 而「漏扫」与「真的改好了」在计数上长得一模一样。没有这条守卫，本门禁的失效形态就是
 * **静默变绿** —— 那比没有门禁更糟。
 */
export function evaluate(result, baseline, strict) {
  const reasons = [];
  if (!strict) return { fail: false, reasons };
  if (result.testTagHits.length > 0) {
    reasons.push(`testTag:${result.testTagHits.length}`);
  }
  if (baseline) {
    if (baseline.scannedEts && result.scannedEts < baseline.scannedEts * 0.9) {
      reasons.push(`scope-shrink:${result.scannedEts}<${baseline.scannedEts}`);
    }
    if (result.arktsBare > baseline.arktsBare) {
      reasons.push(`arktsBare:${result.arktsBare}>${baseline.arktsBare}`);
    }
    if (result.nativeBare > baseline.nativeBare) {
      reasons.push(`nativeBare:${result.nativeBare}>${baseline.nativeBare}`);
    }
  }
  return { fail: reasons.length > 0, reasons };
}

const isMain = process.argv[1]
  && path.resolve(process.argv[1]) === path.resolve(url.fileURLToPath(import.meta.url));

if (isMain) {
  const r = analyze();

  console.log('\n=== AMCL 日志渗透率自检 (audit-logging) ===\n');
  console.log(`范围：${SOURCE_ROOTS.length} 个第一方模块根，${r.scannedEts} 个 .ets / ${r.scannedNative} 个 native 文件`);
  console.log(`（构建脚手架、第三方 fork、测试目录均不计入 —— 详见文件头注释）\n`);
  console.log(`ArkTS : AppLogger ${r.arktsFacade}  |  裸 hilog ${r.arktsBare}  |  渗透率 ${pct(r.arktsFacade, r.arktsBare)}`);
  console.log(`Native: AMCL_LOG  ${r.nativeFacade}  |  裸 OH_LOG ${r.nativeBare}  |  渗透率 ${pct(r.nativeFacade, r.nativeBare)}`);

  console.log(`\n--- 按模块（渗透率 = 门面 / (门面 + 裸)）---`);
  console.log(`  ${'模块'.padEnd(16)} ${'ArkTS'.padStart(16)}  ${'Native'.padStart(16)}`);
  for (const m of r.perModule) {
    const a = (m.facadeArk + m.bareArk) > 0 ? `${m.facadeArk}/${m.bareArk} ${pct(m.facadeArk, m.bareArk)}` : '—';
    const n = (m.facadeNative + m.bareNative) > 0 ? `${m.facadeNative}/${m.bareNative} ${pct(m.facadeNative, m.bareNative)}` : '—';
    console.log(`  ${m.mod.padEnd(16)} ${a.padStart(16)}  ${n.padStart(16)}`);
  }

  console.log(`\n--- 裸 hilog Top 10 (ArkTS) ---`);
  for (const x of r.arktsBareByFile.slice(0, 10)) console.log(`  ${String(x.n).padStart(4)}  ${x.rel}`);
  console.log(`\n--- 裸 OH_LOG Top 10 (Native) ---`);
  for (const x of r.nativeBareByFile.slice(0, 10)) console.log(`  ${String(x.n).padStart(4)}  ${x.rel}`);

  if (r.testTagHits.length > 0) {
    console.log(`\n--- ⚠ testTag 占位 (${r.testTagHits.length}) ---`);
    for (const h of r.testTagHits) console.log(`  ${h}`);
  }

  if (process.argv.includes('--baseline')) {
    const data = {
      arktsBare: r.arktsBare,
      nativeBare: r.nativeBare,
      scannedEts: r.scannedEts,
      scannedNative: r.scannedNative,
      savedAt: new Date().toISOString(),
      note: 'allowlist 口径（只含第一方模块根）。2026-09-06 之前的基线是全仓遍历口径，不可比。',
    };
    fs.writeFileSync(BASELINE_PATH, JSON.stringify(data, null, 2) + '\n');
    console.log(`\n✅ 基线已写入 ${relPath(BASELINE_PATH)}: hilog=${r.arktsBare}, OH_LOG=${r.nativeBare}`);
    process.exit(0);
  }

  let baseline = null;
  if (fs.existsSync(BASELINE_PATH)) {
    try { baseline = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8')); } catch { /* ignore */ }
  }

  const strict = process.argv.includes('--strict');
  const verdict = evaluate(r, baseline, strict);
  const fail = verdict.fail;

  for (const reason of verdict.reasons) {
    const [kind] = reason.split(':');
    if (kind === 'testTag') {
      console.log(`\n❌ STRICT: 发现 ${r.testTagHits.length} 处 testTag 占位 tag，必须改为真实 tag。`);
    } else if (kind === 'scope-shrink') {
      console.log(`\n❌ STRICT: 扫描到的 .ets 文件数 ${r.scannedEts} 明显少于基线 ${baseline.scannedEts}。`);
      console.log(`   渗透率「变好」可能只是因为漏扫。检查 SOURCE_ROOTS 是否漏登记了模块。`);
    } else if (kind === 'arktsBare') {
      console.log(`\n❌ STRICT: 裸 hilog 计数 ${r.arktsBare} 超过基线 ${baseline.arktsBare}（新增裸日志，请改用 AppLogger）。`);
    } else if (kind === 'nativeBare') {
      console.log(`\n❌ STRICT: 裸 OH_LOG 计数 ${r.nativeBare} 超过基线 ${baseline.nativeBare}（新增裸日志，请改用 AMCL_LOG_*）。`);
    }
  }

  if (!fail && strict) console.log('\n✅ STRICT 通过');
  else if (!fail) console.log('\n（informational：默认不失败。--strict 接入提交前/CI；--baseline 记录基线。）');
  process.exit(fail ? 1 : 0);
}
