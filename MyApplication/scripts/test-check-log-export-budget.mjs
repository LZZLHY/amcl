#!/usr/bin/env node
// scripts/test-check-log-export-budget.mjs
//
// check-log-export-budget.mjs 的定向自测。
//
// ⚠️ 本门禁一半是**结构断言**（源码里有没有某个形状），这正是最容易写成恒真的一类。
// §2 逐条制造回归，要求门禁真的红。其中 §2.2 是**最可能真实发生**的回归形状：
// 有人为了省事把 `ledgerRead` 的配额参数去掉 —— 那会静默恢复成 16 MB 全读，
// 配额形同虚设，而导出仍然「成功」。
//
// §4 用数字证明「不做保底分配」会发生什么：纯按比例分配时启动器日志会被饿死。
// 这条不是测实现，是测**这个设计有没有必要** —— 免得后来人觉得保底是多余的复杂度。

import { analyze, readSources, allocateExportBudget, n7Demands } from './check-log-export-budget.mjs';

let failed = 0;
function check(name, cond, extra) {
  if (cond) {
    console.log(`  ok   ${name}`);
  } else {
    failed += 1;
    console.error(`  FAIL ${name}${extra ? `\n       ${extra}` : ''}`);
  }
}

function mutate(s, key, from, to) {
  const before = s[key];
  const hit = typeof from === 'string' ? before.includes(from) : from.test(before);
  if (!hit) throw new Error(`fixture broken: ${key} 里找不到 ${from}`);
  const after = before.replace(from, to);
  if (after === before) throw new Error(`fixture broken: ${key} 替换没生效`);
  return { ...s, [key]: after };
}

const KB = 1024;
const real = readSources();
const get = (gs, id) => (gs.find((g) => g.id === id) || { granted: -1 }).granted;

// ── 1. 正向
{
  const r = analyze(real);
  check('real repo: 门禁通过', r.ok === true,
    JSON.stringify({ structure: r.structure, numeric: r.numeric }));
}

// ── 2. 结构回归
{
  const r = analyze(mutate(real, 'ledger', 'allocateExportBudget(', 'noAllocate('));
  check('2.1 去掉配额分配 ⇒ 红', r.ok === false && r.structure.length > 0,
    JSON.stringify(r.structure));
}
{
  // ⭐ 最可能真实发生的回归：把配额参数去掉，恢复成全读
  const r = analyze(mutate(real, 'ledger',
    'ledgerReadForExport_(filesDir, activityId, p, g.granted)', 'ledgerReadForExport_(filesDir, activityId, p)'));
  check('2.2 ⭐ 读取不带配额 ⇒ 红', r.ok === false);
  check('2.2 ⭐ 且必须明确指出「配额形同虚设」',
    r.structure.some((x) => x.includes('形同虚设') || x.includes('带着配额')),
    JSON.stringify(r.structure));
}
{
  // ⭐ 2026-09-06 自审抓出的那个缺陷的回归钉子：
  // 直接用 ledgerRead 看起来完全合理，但它是**保尾读** ⇒ 头部在返回前就没了。
  const r = analyze(mutate(real, 'ledger',
    'ledgerReadForExport_(filesDir, activityId, p, g.granted)',
    'ledgerRead(filesDir, activityId, p, g.granted)'));
  check('2.3 ⭐ 换回保尾的 ledgerRead ⇒ 红', r.ok === false);
  check('2.3 ⭐ 且必须点明「那是保尾读」',
    r.structure.some((x) => x.includes('保尾读')), JSON.stringify(r.structure));
}
{
  const r = analyze(mutate(real, 'ledger',
    'readLogFileHead(headPath, headBudget)', 'readLogFileTail(headPath, headBudget)'));
  check('2.3b 不再真的读文件头 ⇒ 红', r.ok === false && r.structure.length > 0,
    JSON.stringify(r.structure));
}
{
  const r = analyze(mutate(real, 'ledger',
    'truncateUtf8HeadTail(body, g.granted)', 'body'));
  check('2.3c 去掉字节钳制兜底 ⇒ 红', r.ok === false && r.structure.length > 0,
    JSON.stringify(r.structure));
}
{
  const r = analyze(mutate(real, 'logExport',
    'export function truncateUtf8HeadTail', 'function truncateUtf8HeadTail'));
  check('2.4 头尾截断不再导出 ⇒ 红', r.ok === false, JSON.stringify(r.structure));
}
{
  const r = analyze(mutate(real, 'ledger',
    'for (let i = 0; i < parts.length; i++)', 'for (let i = 0; i < parts.length; ++i)'));
  check('2.5 拼装循环认不出来 ⇒ 红（不许静默放行）',
    r.ok === false && r.structure.some((x) => x.includes('判据可能已失效')),
    JSON.stringify(r.structure));
}

// ── 3. 分配器性质
{
  const gs = allocateExportBudget(n7Demands(), 240 * KB);
  const sum = gs.reduce((s, g) => s + g.granted, 0);
  check('3.1 总量不超预算', sum <= 240 * KB, String(sum));
  check('3.2 启动器拿到保底', get(gs, 'LAUNCHER') >= 48 * KB, String(get(gs, 'LAUNCHER')));
  check('3.3 崩溃报告完整保留', get(gs, 'CRASH_REPORT') === 12 * KB, String(get(gs, 'CRASH_REPORT')));
  check('3.4 没有段被分到 0', gs.every((g) => g.granted > 0), JSON.stringify(gs));
  check('3.5 返回顺序等于传入顺序',
    gs[0].id === 'LAUNCHER' && gs[4].id === 'CRASH_REPORT', JSON.stringify(gs.map((g) => g.id)));
  check('3.6 预算充足时全给',
    allocateExportBudget(n7Demands(), 999 * 1024 * 1024).every((g, i) => g.granted === n7Demands()[i].bytes));
  check('3.7 预算为 0 视为不限',
    allocateExportBudget([{ id: 'A', bytes: 77, priority: 1, floorBytes: 1 }], 0)[0].granted === 77);
  check('3.8 空输入不炸', allocateExportBudget([], 100).length === 0);
}
{
  // 预算极小 ⇒ 优先级最高的先拿
  const gs = allocateExportBudget(n7Demands(), 20 * KB);
  check('3.9 预算极小时优先级决定谁活下来', get(gs, 'CRASH_REPORT') > 0, JSON.stringify(gs));
  check('3.10 预算极小时也不超预算',
    gs.reduce((s, g) => s + g.granted, 0) <= 20 * KB);
}

// ── 4. ⭐ 证明「保底分配」这个设计有必要：纯比例分配会饿死启动器日志
{
  const demands = n7Demands();
  const budget = 240 * KB;
  const total = demands.reduce((s, d) => s + d.bytes, 0);
  const naive = demands.map((d) => ({ id: d.id, granted: Math.floor(budget * d.bytes / total) }));
  const naiveLauncher = get(naive, 'LAUNCHER');
  const naiveCrash = get(naive, 'CRASH_REPORT');
  check('4.1 纯比例分配下启动器日志被饿死（远低于保底）',
    naiveLauncher < 48 * KB, `${naiveLauncher} B`);
  check('4.2 纯比例分配下崩溃报告几乎归零', naiveCrash < 1 * KB, `${naiveCrash} B`);

  const fixed = allocateExportBudget(demands, budget);
  check('4.3 保底分配把启动器日志从饿死救回来',
    get(fixed, 'LAUNCHER') >= 48 * KB && get(fixed, 'LAUNCHER') > naiveLauncher,
    `naive=${naiveLauncher} fixed=${get(fixed, 'LAUNCHER')}`);
}

// ── 5. 旧行为（拼完保尾）的等价对照
//
// ⚠️ 这一节顺带更正了调研 §5.2 的一处细节。调研写的是
//   「…启动器日志全部落在被截掉的头部，**剩下的是游戏日志的尾部**」。
// 后半句只在 GAME 是最后一段时成立。而实际拼装顺序是
//   LAUNCHER → GAME → MC_LATEST → JVM → CRASH_REPORT → SYSTEM_CRASH，
// GAME 后面还有三段（本语料合计 816 KB > 240 KB 配额）⇒
// **保尾 240 KB 连游戏日志都够不着**，LAUNCHER 与 GAME 双双整段消失。
// 结论方向不变（关键证据被丢），但被丢的东西比调研说的更多。
{
  const order = ['LAUNCHER', 'GAME', 'MC_LATEST', 'JVM', 'CRASH_REPORT'];
  const sizes = Object.fromEntries(n7Demands().map((d) => [d.id, d.bytes]));
  let offset = 0;
  const spans = order.map((id) => {
    const span = { id, start: offset, end: offset + sizes[id] };
    offset += sizes[id];
    return span;
  });
  const keepFrom = offset - 240 * KB;
  const survivors = spans.filter((s) => s.end > keepFrom).map((s) => s.id);

  check('5.1 旧行为下 LAUNCHER 整段消失', !survivors.includes('LAUNCHER'), JSON.stringify(survivors));
  check('5.2 旧行为下 GAME 也整段消失（调研说「剩下游戏日志尾部」是不准的）',
    !survivors.includes('GAME'), JSON.stringify(survivors));
  check('5.3 旧行为下只剩最后几段的尾部',
    survivors.length > 0 && survivors.every((id) => ['MC_LATEST', 'JVM', 'CRASH_REPORT'].includes(id)),
    JSON.stringify(survivors));

  // 新行为：同一组语料下，上面三段全部拿得到配额
  const fixed = allocateExportBudget(n7Demands(), 240 * KB);
  check('5.4 新行为下 LAUNCHER 与 GAME 都在', get(fixed, 'LAUNCHER') > 0 && get(fixed, 'GAME') > 0,
    JSON.stringify(fixed));
}

console.log(failed === 0 ? `\n✅ ALL PASS` : `\n❌ ${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
