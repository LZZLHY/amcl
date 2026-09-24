#!/usr/bin/env node
// scripts/check-comment-layering.mjs
//
// ============================ 它挡的是什么 ============================
//
// 注释**过长**导致的可读性崩塌。这不是审美问题，是一个已经发生的、可测量的事实：
// 2026-08-21 实测输入子系统 124 个文件 42487 行，注释 9859 行（23%），其中
// **连续注释块 ≥ 20 行的有 62 处、≥ 40 行的 7 处**。最极端的
// `ImeActivationGate.ets` 是 115 行里 87 行注释、单块 68 行 —— 打开文件看不见代码。
//
// 成因不是有人偷懒，恰恰相反：规范 §八.6「注释说谎比没有注释更贵」要求删机制时连注释
// 一起改、要求写祈使句时把前提一起写下。按字面执行的结果就是注释不断累积成**内嵌变更
// 日志**：同一套因果在计划文档、规范文档、代码注释里各写一遍，而代码里那份最长。
//
// ============================ 注释三层分工（本门禁要维护的秩序）============================
//
//   第一层 · 贴代码：**只写现在成立的契约**与"改它会坏什么"。目标 ≤ 5 行。
//   第二层 · 文件头：职责边界、锁序、它在三端/两轴模型里的位置，**指向规范章节**。≤ 25 行。
//   第三层 · 文档：因果、被推翻的结论、真机证据、墓碑叙事。用 §N 引用。
//
// 墓碑（§八.6 要求它存在，所以**不能删**，只能压缩）的规定形式是**一行**：
//
//     // ⚠️ 墓碑: <标识符> 已删除（<一句话为什么>），详见计划 §NN.N
//
// 那一行仍然完成墓碑的全部职责（防止有人按名字去找、防止把已删机制当现存），
// 而叙事搬进文档。⚠️ 顺带解决 §60.4 盲区 5：`⚠️ 墓碑:` 这个显式前缀正是
// `check-comment-identifiers.mjs` 需要的"逃生阀"，可以把历史标记的作用域从整块收紧到该行。
//
// ============================ 为什么是棘轮，而不是硬上限 ============================
//
// 现存 61 个 ≥20 行的块，一次性改完不现实，而"设一个上限然后 61 处全红"的门禁下一轮
// 就会被加进忽略名单 —— 那正是规范 §八.5 说的"计数器不可信比没有计数器更糟"。
// 所以本门禁是**棘轮**：以 `comment-layering-baseline.json` 记录每个文件当前的最长块，
// 只在某个文件**变得更长**时失败。新写的长篇被挡住，旧的可以按批偿还。
//
// 收紧基线（改完一个文件之后）：
//     node scripts/check-comment-layering.mjs --update-baseline
//
// ============================ 它不能证明什么 ============================
//
// ❌ 注释**内容**是否正确、是否说谎（那是 `check-comment-identifiers.mjs` 的一部分职责，
//    而"陈述正确性"至今没有机械手段，见 §60.4 盲区 7）。
// ❌ 短注释不等于好注释。把承重前提删掉换来的"短"是负收益 —— 本门禁**无法**区分
//    "搬进文档了" 与 "直接删了"。所以偿还长块时必须同时给出文档落点。

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

import {
  resolveCommentScopeFiles,
  splitCommentsAndCode,
} from './check-comment-identifiers.mjs';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const BASELINE_PATH = 'scripts/comment-layering-baseline.json';

// 这两个只用于报告分级，不参与成败判定（判定完全由棘轮基线决定）。
const BLOCK_WARN = 20;
const BLOCK_LOUD = 40;

export function measureFile(text) {
  const { comments } = splitCommentsAndCode(text);
  const blocks = [];
  let current = 0;
  let prev = -5;
  let startLine = 0;
  for (const entry of comments) {
    if (entry.line <= prev + 1) {
      current += 1;
    } else {
      if (current > 0) blocks.push({ lines: current, startLine });
      current = 1;
      startLine = entry.line;
    }
    prev = entry.line;
  }
  if (current > 0) blocks.push({ lines: current, startLine });
  const totalLines = text.split('\n').length;
  const commentLines = comments.length;
  const worst = blocks.reduce(
    (a, b) => (b.lines > a.lines ? b : a), { lines: 0, startLine: 0 });
  return {
    totalLines,
    commentLines,
    pct: totalLines ? Math.round((commentLines * 100) / totalLines) : 0,
    worstBlock: worst.lines,
    worstBlockAt: worst.startLine,
    blocksOverWarn: blocks.filter(b => b.lines >= BLOCK_WARN).length,
    blocksOverLoud: blocks.filter(b => b.lines >= BLOCK_LOUD).length,
  };
}

export function measureScope(root = ROOT) {
  const files = resolveCommentScopeFiles();
  const perFile = {};
  let totalLines = 0;
  let commentLines = 0;
  let blocksOverWarn = 0;
  let blocksOverLoud = 0;
  for (const file of files) {
    let text;
    try { text = fs.readFileSync(file, 'utf8'); } catch { continue; }
    const rel = path.relative(root, file).replace(/\\/g, '/');
    const m = measureFile(text);
    perFile[rel] = m;
    totalLines += m.totalLines;
    commentLines += m.commentLines;
    blocksOverWarn += m.blocksOverWarn;
    blocksOverLoud += m.blocksOverLoud;
  }
  return {
    fileCount: Object.keys(perFile).length,
    totalLines,
    commentLines,
    pct: totalLines ? Math.round((commentLines * 100) / totalLines) : 0,
    blocksOverWarn,
    blocksOverLoud,
    perFile,
  };
}

function loadBaseline() {
  const full = path.join(ROOT, BASELINE_PATH);
  if (!fs.existsSync(full)) return null;
  return JSON.parse(fs.readFileSync(full, 'utf8'));
}

function writeBaseline(measured) {
  const worst = {};
  for (const [rel, m] of Object.entries(measured.perFile)) {
    if (m.worstBlock > 0) worst[rel] = m.worstBlock;
  }
  const payload = {
    purpose:
      '注释分层棘轮基线：每个文件当前最长的连续注释块行数。门禁只在某个文件变得更长时失败。',
    howToUpdate:
      '偿还了某个文件的长注释之后跑 node scripts/check-comment-layering.mjs --update-baseline。' +
      '⚠️ 两条纪律：(1) 收紧基线之前先确认承重内容真的搬进了文档，而不是被删了 —— ' +
      '本门禁分不出这两者；(2) 若某个文件的数字是**变大**的，不得默默重记基线 —— ' +
      '必须在计划文档里写下理由，否则棘轮退化成"每次失败就重置"，等于没有棘轮。',
    recordedAt: new Date().toISOString().slice(0, 10),
    totals: {
      files: measured.fileCount,
      lines: measured.totalLines,
      commentLines: measured.commentLines,
      commentPct: measured.pct,
      blocksOver20: measured.blocksOverWarn,
      blocksOver40: measured.blocksOverLoud,
    },
    worstBlockPerFile: Object.fromEntries(
      Object.entries(worst).sort((a, b) => b[1] - a[1])),
  };
  fs.writeFileSync(
    path.join(ROOT, BASELINE_PATH),
    JSON.stringify(payload, null, 2) + '\n', 'utf8');
  return payload;
}

export function compareToBaseline(measured, baseline) {
  const grew = [];
  const shrank = [];
  const added = [];
  const recorded = baseline?.worstBlockPerFile ?? {};
  for (const [rel, m] of Object.entries(measured.perFile)) {
    const before = recorded[rel];
    if (before === undefined) {
      // 新文件：只有超过"响亮"阈值才当问题，否则允许（新文件本来就要写文件头）。
      if (m.worstBlock >= BLOCK_LOUD) {
        added.push({ file: rel, now: m.worstBlock, at: m.worstBlockAt });
      }
      continue;
    }
    if (m.worstBlock > before) {
      grew.push({ file: rel, before, now: m.worstBlock, at: m.worstBlockAt });
    } else if (m.worstBlock < before) {
      shrank.push({ file: rel, before, now: m.worstBlock });
    }
  }
  return { grew, shrank, added };
}

function main() {
  const args = process.argv.slice(2);
  const measured = measureScope();

  if (args.includes('--update-baseline')) {
    const payload = writeBaseline(measured);
    console.log('[check-comment-layering] baseline updated');
    console.log(`  files: ${payload.totals.files}`);
    console.log(`  comment lines: ${payload.totals.commentLines} (${payload.totals.commentPct}%)`);
    console.log(`  blocks >=${BLOCK_WARN}: ${payload.totals.blocksOver20}`);
    console.log(`  blocks >=${BLOCK_LOUD}: ${payload.totals.blocksOver40}`);
    return;
  }

  if (args.includes('--json')) {
    const baseline = loadBaseline();
    console.log(JSON.stringify(
      { measured, diff: baseline ? compareToBaseline(measured, baseline) : null },
      null, 2));
    return;
  }

  console.log('[check-comment-layering]');
  console.log(`  files scanned:  ${measured.fileCount}`);
  console.log(`  lines:          ${measured.totalLines}`);
  console.log(`  comment lines:  ${measured.commentLines} (${measured.pct}%)`);
  console.log(`  blocks >=${BLOCK_WARN}:    ${measured.blocksOverWarn}`);
  console.log(`  blocks >=${BLOCK_LOUD}:    ${measured.blocksOverLoud}`);

  if (args.includes('--worst')) {
    const rows = Object.entries(measured.perFile)
      .filter(([, m]) => m.worstBlock >= BLOCK_WARN)
      .sort((a, b) => b[1].worstBlock - a[1].worstBlock);
    console.log('\n  --- files with a comment block >= ' + BLOCK_WARN + ' lines ---');
    for (const [rel, m] of rows) {
      console.log(
        `  ${String(m.worstBlock).padStart(3)} lines @ L${m.worstBlockAt}` +
        `  (${m.pct}% of ${m.totalLines})  ${rel}`);
    }
  }

  const baseline = loadBaseline();
  if (!baseline) {
    console.log('\n  no baseline recorded yet — run with --update-baseline');
    return;
  }
  const { grew, shrank, added } = compareToBaseline(measured, baseline);
  console.log(`\n  baseline recorded ${baseline.recordedAt}`);
  if (shrank.length > 0) {
    console.log(`  paid down: ${shrank.length} file(s)`);
    for (const s of shrank.slice(0, 10)) {
      console.log(`    ${s.file}: ${s.before} -> ${s.now}`);
    }
    console.log('    (run --update-baseline to lock the improvement in)');
  }
  if (grew.length === 0 && added.length === 0) {
    console.log('  PASS  no file grew a longer comment block');
    return;
  }
  for (const g of grew) {
    console.error(
      `  REGRESSION  ${g.file}: worst comment block ${g.before} -> ${g.now}` +
      ` lines (starts L${g.at})`);
  }
  for (const a of added) {
    console.error(
      `  NEW FILE with a ${a.now}-line comment block: ${a.file} (starts L${a.at})`);
  }
  console.error(
    '\n  注释三层分工见本脚本头注释。因果与历史属**文档**，代码里留契约 + 一行墓碑指针：\n' +
    '    // ⚠️ 墓碑: <标识符> 已删除（<一句话为什么>），详见计划 §NN.N\n' +
    '  ⚠️ 不要靠删掉承重前提来过这道门禁 —— 本门禁分不出"搬进文档"与"直接删了"。');
  process.exitCode = 1;
}

if (import.meta.url === url.pathToFileURL(process.argv[1] ?? '').href) {
  main();
}
