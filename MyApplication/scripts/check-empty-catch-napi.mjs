#!/usr/bin/env node
// scripts/check-empty-catch-napi.mjs
//
// ============================ 它挡的是什么 ============================
//
// `try { testNapi.foo() } catch (e) { /* 老 native 兼容 */ }` —— 空 catch 直接包住跨语言
// 调用。它是本项目**两次 release-only 事故共同的放大器**：把"这个接口被混淆改名了"
// 变成"什么都没发生"。
//   · 2026-08-22 事故一：三个帧率 NAPI 在所有开混淆的 release 包里从未工作过，
//     调用抛的 TypeError 被 `catch (e) { /* 老 native 兼容 */ }` 吞掉，整整若干个版本无人发现。
//   · 事故二（wire JSON）同型，只是受害者换成 JSON 字段。
//
// ⚠️ **那句"老 native 兼容"对当前代码 0 条成立**（2026-08-22 逐条核对）：这些 catch 覆盖的
// 31 个 NAPI 名，在 `entry/src/main/cpp/types/libentry/index.d.ts` 里 31/31 都有声明，
// native 侧 31/31 都真的注册了。libentry.so 随 HAP 一起打包，不存在"用户装了旧 native"的
// 运行期组合。⇒ 这些 catch 唯一能真正触发的场景就是**混淆改名**，也就是门禁要拦的东西本身。
// 注释宣称在防的东西不存在，实际在防的东西恰好是最该炸出来的那个。
//
// ============================ 为什么是棘轮 ============================
//
// 现存 51 处，一次性改完不现实（其中 14 处在每输入事件/每 250ms 的热路径上，无条件 warn
// 会刷爆日志，只能改成计数器或一次性标记）。"设成 0 然后 51 处全红"的门禁下一轮就会被
// 加进忽略名单 —— 那正是规范 §八.5 说的"计数器不可信比没有计数器更糟"。
// 所以以 `empty-catch-napi-baseline.json` 记录**每文件**条数，只在某个文件变多时失败。
//
// 偿还时的写法在仓里已有先例（都在 McGamePage.ets）：一次性探测 + 失败置位不再重试
// （`gate0TelemetryEnabled`）、有界日志（`heldButtonProbeCount < 30`）、
// native 侧计数器通道（`noteKeyRepeatSelfHealed` / `noteSourceReset` 这类）。
//
// 收紧基线（偿还完一个文件之后）：
//     node scripts/check-empty-catch-napi.mjs --update-baseline
//
// ============================ 它不能证明什么 ============================
//
// ❌ 不覆盖 HAR 模块的**注入桥**调用（`SystemNativeBridge` / `LaunchNativeBridge` /
//    `ForgelikeNative` 等）。那些调用同样会被混淆改名打中，但口径是 `testNapi.` 抓不到。
//    实测当前该类被空 catch 直接包住的有 0 处；**把逻辑挪进 HAR 就能绕过这道门禁**，
//    这是已知缺口而不是设计意图。
// ❌ 不判断 catch 里"写了日志"是否写对（比如 `AppLogger.info(TAG, msg, e)` 会把异常塞进
//    domain 参数 —— info 的第三参是 domain 不是 err）。有内容即放行。
// ❌ 不区分"该 fail-open 的清理路径"与"该报错的功能路径"。基线里 17 处
//    onDestroy/onBackground/aboutToDisappear 属于前者，理应永久豁免；本门禁只保证不变多，
//    分类判断留给偿还时的人。

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const BASELINE_PATH = 'scripts/empty-catch-napi-baseline.json';

const SOURCE_ROOTS = [
  'entry/src/main/ets',
  'entry/src/desktop',
  'gamecontrol/src/main/ets',
  'feature_core/src/main/ets',
  'feature_system/src/main/ets',
  'mods/src/main/ets',
  'account/src/main/ets',
  'update/src/main/ets',
  'launch/src/main/ets',
  'commons/src/main/ets',
];
const SKIP_DIRS = new Set(['build', 'oh_modules', '.preview', 'node_modules']);
const CODE_EXT = new Set(['.ets', '.ts']);

/**
 * 把注释与字符串**内容**换成等量空格，保留长度与换行 —— 于是掩码串与原文偏移一一对应，
 * 结构搜索在掩码上做、取文本按同偏移从原文取。
 *
 * ⚠️ 必须同时掩掉字符串：字符串里的 `//` 若被当成注释起点，后面整行结构都会读错。
 * ⚠️ 模板串里的 `${...}` **不能**掩掉 —— 那是真代码，掩掉就可能漏掉里面的 testNapi 调用，
 * 而少报是这道门禁唯一致命的失效方向。
 */
export function maskCode(text) {
  const out = Array.from(text);
  const blank = (from, to) => {
    for (let k = from; k < to && k < out.length; k += 1) {
      if (out[k] !== '\n' && out[k] !== '\r') out[k] = ' ';
    }
  };
  let i = 0;
  // 模板串栈：遇到 `${` 压栈回到代码模式，遇到配对 `}` 弹回模板串模式。
  const tmplStack = [];
  while (i < text.length) {
    const c = text[i];
    if (c === '/' && text[i + 1] === '/') {
      const nl = text.indexOf('\n', i);
      const end = nl < 0 ? text.length : nl;
      blank(i, end);
      i = end;
      continue;
    }
    if (c === '/' && text[i + 1] === '*') {
      const e = text.indexOf('*/', i + 2);
      const end = e < 0 ? text.length : e + 2;
      blank(i, end);
      i = end;
      continue;
    }
    if (c === "'" || c === '"') {
      let j = i + 1;
      while (j < text.length && text[j] !== c) {
        if (text[j] === '\\') j += 1;
        if (text[j] === '\n') break;
        j += 1;
      }
      blank(i + 1, j);
      i = Math.min(j + 1, text.length);
      continue;
    }
    if (c === '`') {
      let j = i + 1;
      while (j < text.length) {
        if (text[j] === '\\') { j += 2; continue; }
        if (text[j] === '`') break;
        if (text[j] === '$' && text[j + 1] === '{') { break; }
        j += 1;
      }
      blank(i + 1, j);
      if (text[j] === '$') {
        tmplStack.push('tmpl');
        i = j + 2;           // 进入 ${ 内部，按代码继续扫
        continue;
      }
      i = Math.min(j + 1, text.length);
      continue;
    }
    if (c === '}' && tmplStack.length > 0) {
      // ${...} 结束，回到模板串文本
      tmplStack.pop();
      let j = i + 1;
      while (j < text.length) {
        if (text[j] === '\\') { j += 2; continue; }
        if (text[j] === '`') break;
        if (text[j] === '$' && text[j + 1] === '{') break;
        j += 1;
      }
      blank(i + 1, j);
      if (text[j] === '$') { tmplStack.push('tmpl'); i = j + 2; continue; }
      i = Math.min(j + 1, text.length);
      continue;
    }
    i += 1;
  }
  return out.join('');
}

/** 从 openIdx（'{'）正向配对，返回闭合 '}' 的下标；找不到返回 -1。 */
function matchForward(masked, openIdx) {
  let depth = 0;
  for (let i = openIdx; i < masked.length; i += 1) {
    if (masked[i] === '{') depth += 1;
    else if (masked[i] === '}') { depth -= 1; if (depth === 0) return i; }
  }
  return -1;
}

/** 从 closeIdx（'}'）反向配对，返回对应 '{' 的下标；找不到返回 -1。 */
function matchBackward(masked, closeIdx) {
  let depth = 0;
  for (let i = closeIdx; i >= 0; i -= 1) {
    if (masked[i] === '}') depth += 1;
    else if (masked[i] === '{') { depth -= 1; if (depth === 0) return i; }
  }
  return -1;
}

function skipWsBack(masked, i) {
  let k = i;
  while (k >= 0 && /\s/.test(masked[k])) k -= 1;
  return k;
}

const NAPI_CALL_RE = /\btestNapi\s*\.\s*([A-Za-z_$][\w$]*)/g;

/**
 * 找出「try 块含 testNapi.* 且 catch 体为空」的位置。
 * 返回 [{ line, napiNames, bare, body }]，line = catch 关键字所在行。
 */
export function findEmptyNapiCatches(text) {
  const masked = maskCode(text);
  const hits = [];
  const catchRe = /\bcatch\b/g;
  for (let m; (m = catchRe.exec(masked));) {
    // catch (...) { body }
    let k = m.index + 5;
    while (k < masked.length && /\s/.test(masked[k])) k += 1;
    if (masked[k] === '(') {
      let depth = 0;
      while (k < masked.length) {
        if (masked[k] === '(') depth += 1;
        else if (masked[k] === ')') { depth -= 1; if (depth === 0) { k += 1; break; } }
        k += 1;
      }
      while (k < masked.length && /\s/.test(masked[k])) k += 1;
    }
    if (masked[k] !== '{') continue;
    const close = matchForward(masked, k);
    if (close < 0) continue;

    // 空 = 掩码后的 body 去空白为空（注释与字符串都已成空格）
    const maskedBody = masked.slice(k + 1, close);
    if (maskedBody.trim() !== '') continue;
    const rawBody = text.slice(k + 1, close);

    // 关联 try：catch 之前紧邻 `}`，反向配对到 `{`，再往前应是 `try`
    const prev = skipWsBack(masked, m.index - 1);
    if (prev < 0 || masked[prev] !== '}') continue;           // .catch() 之类
    const tryOpen = matchBackward(masked, prev);
    if (tryOpen < 0) continue;
    const beforeTry = skipWsBack(masked, tryOpen - 1);
    if (beforeTry < 2 || masked.slice(beforeTry - 2, beforeTry + 1) !== 'try') continue;

    const tryBody = masked.slice(tryOpen + 1, prev);
    const names = new Set();
    NAPI_CALL_RE.lastIndex = 0;
    for (let n; (n = NAPI_CALL_RE.exec(tryBody));) names.add(n[1]);
    if (names.size === 0) continue;

    hits.push({
      line: text.slice(0, m.index).split(/\r?\n/).length,
      napiNames: [...names].sort(),
      bare: rawBody.trim() === '',
      body: rawBody.trim().slice(0, 120),
    });
  }
  return hits;
}

/** 棘轮比对。语义与 check-comment-layering 一致：只禁变多，变少算偿还。 */
export function compareToBaseline(perFile, baseline) {
  const grew = [];
  const shrank = [];
  const added = [];
  const recorded = baseline?.emptyCatchPerFile ?? {};
  for (const [rel, now] of Object.entries(perFile)) {
    const before = recorded[rel];
    if (before === undefined) {
      // 新文件：一处都不许有。空 catch 包 NAPI 调用没有"新文件本来就需要"的情形，
      // 与注释块长度那道棘轮不同（那边新文件允许写文件头）。
      added.push({ file: rel, now });
      continue;
    }
    if (now > before) grew.push({ file: rel, before, now });
    else if (now < before) shrank.push({ file: rel, before, now });
  }
  return { grew, shrank, added };
}

function walk(dir, out = []) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      walk(full, out);
    } else if (entry.isFile() && CODE_EXT.has(path.extname(entry.name))) {
      out.push(full);
    }
  }
  return out;
}

function measure() {
  const files = SOURCE_ROOTS.flatMap((rel) => walk(path.join(ROOT, rel)));
  const perFile = {};
  const sites = [];
  for (const full of files) {
    const rel = path.relative(ROOT, full).replace(/\\/g, '/');
    const hits = findEmptyNapiCatches(fs.readFileSync(full, 'utf8'));
    if (hits.length === 0) continue;
    perFile[rel] = hits.length;
    for (const h of hits) sites.push({ file: rel, ...h });
  }
  return { fileCount: files.length, total: sites.length, perFile, sites };
}

function writeBaseline(measured) {
  const payload = {
    purpose:
      '空 catch 直接包住 testNapi.* 调用的每文件条数棘轮基线。门禁只在某个文件变多时失败。',
    howToUpdate:
      '偿还了某个文件之后跑 node scripts/check-empty-catch-napi.mjs --update-baseline。' +
      '⚠️ 三条纪律：(1) 偿还的意思是让失败可被观测（记日志 / 一次性标记 / native 计数器），' +
      '不是把 try/catch 整个删掉 —— 本门禁分不出这两者；(2) 热路径上不要无条件 warn，' +
      '照 McGamePage 既有的 gate0TelemetryEnabled 一次性置位或 heldButtonProbeCount 有界日志写；' +
      '(3) 若某个文件的数字是**变多**的，不得默默重记基线 —— 必须在计划文档里写下理由，' +
      '否则棘轮退化成"每次失败就重置"，等于没有棘轮。',
    recordedAt: new Date().toISOString().slice(0, 10),
    totals: { scannedFiles: measured.fileCount, emptyCatchWithNapi: measured.total },
    emptyCatchPerFile: Object.fromEntries(
      Object.entries(measured.perFile).sort((a, b) => b[1] - a[1])),
  };
  fs.writeFileSync(path.join(ROOT, BASELINE_PATH),
    `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return payload;
}

function loadBaseline() {
  const full = path.join(ROOT, BASELINE_PATH);
  if (!fs.existsSync(full)) return null;
  try { return JSON.parse(fs.readFileSync(full, 'utf8')); } catch { return null; }
}

function main() {
  const args = process.argv.slice(2);
  const measured = measure();

  if (args.includes('--update-baseline')) {
    const payload = writeBaseline(measured);
    console.log('[check-empty-catch-napi] baseline updated');
    console.log(`  files scanned: ${payload.totals.scannedFiles}`);
    console.log(`  empty catch around testNapi: ${payload.totals.emptyCatchWithNapi}`);
    return;
  }

  const baseline = loadBaseline();
  const diff = baseline ? compareToBaseline(measured.perFile, baseline) : null;

  if (args.includes('--json')) {
    process.stdout.write(`${JSON.stringify({
      ok: diff !== null && diff.grew.length === 0 && diff.added.length === 0,
      hasBaseline: baseline !== null,
      total: measured.total,
      bare: measured.sites.filter((s) => s.bare).length,
      scannedFiles: measured.fileCount,
      diff,
    })}\n`);
    process.exit(diff !== null && diff.grew.length === 0 && diff.added.length === 0 ? 0 : 1);
  }

  console.log('[check-empty-catch-napi]');
  console.log(`  files scanned: ${measured.fileCount}`);
  console.log(`  empty catch around testNapi.*: ${measured.total}` +
    ` (bare {}: ${measured.sites.filter((s) => s.bare).length}` +
    `, comment-only: ${measured.sites.filter((s) => !s.bare).length})`);
  if (args.includes('--list')) {
    for (const s of measured.sites) {
      console.log(`  ${s.file}:${s.line}  ${s.napiNames.join(',')}  ${s.bare ? '{}' : s.body}`);
    }
  }
  if (!baseline) {
    console.log('\n  no baseline recorded yet — run with --update-baseline');
    return;
  }
  if (diff.shrank.length > 0) {
    console.log(`  paid down: ${diff.shrank.length} file(s)`);
    for (const s of diff.shrank) console.log(`    ${s.file}: ${s.before} -> ${s.now}`);
    console.log('    (run --update-baseline to lock the improvement in)');
  }
  if (diff.grew.length === 0 && diff.added.length === 0) {
    console.log('  PASS  no file gained an empty catch around a NAPI call');
    return;
  }
  for (const g of diff.grew) {
    console.error(`  REGRESSION  ${g.file}: empty catch around testNapi ${g.before} -> ${g.now}`);
  }
  for (const a of diff.added) {
    console.error(`  NEW FILE with ${a.now} empty catch(es) around testNapi: ${a.file}`);
  }
  console.error(
    '\n  空 catch 会把"接口被混淆改名"变成"什么都没发生" —— 本项目两次 release-only 事故\n' +
    '  的共同放大器。让失败可被观测：记日志 / 一次性置位 / native 计数器（McGamePage 有现成写法）。\n' +
    '  ⚠️ 不要靠删掉 try/catch 来过这道门禁 —— 本门禁分不出"改成可观测"与"整段删了"。');
  process.exitCode = 1;
}

if (import.meta.url === url.pathToFileURL(process.argv[1] ?? '').href) {
  main();
}
