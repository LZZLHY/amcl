#!/usr/bin/env node
// scripts/check-log-export-budget.mjs
//
// 日志系统重构 · P5「导出配额」门禁。
//
// 钉的是调研 N-7：**上传出去的正文可能一行启动器日志都没有。**
//
// 旧做法是「把各 part 按固定顺序拼成一整段，再交给 truncateUtf8Tail **保尾**截断」，
// 而拼装顺序是 环境头 → 活动摘要 → LAUNCHER → GAME → …，且 GAME 段不传上限读到 16 MB。
// ⇒ 游戏日志一大，前面几段全部落在被丢掉的头部。而启动器日志正是
//   「AMCL 自己做了什么决定」（classpath / JDK / 渲染后端）的唯一记录。
//
// ⚠️ 为什么需要一道**静态**门禁：修复本体在 ArkTS 里，而 hypium 只能在设备上跑
//    （`entry/src/test/LogExportBudget.test.ets`）。提交前必然红的那一半只能落在这里。
//    这与 check-launch-generation-contract.mjs 的处境逐字相同。
//
// 本门禁管两件事：
//   1. **结构**：`ledgerExport` 必须先分配配额再读 part，且读的时候必须带上配额。
//      回归的典型形状是「有人为了省事把 ledgerRead 的 maxBytes 去掉」——
//      那会静默恢复成 16 MB 全读，配额形同虚设。
//   2. **数值**：用等价模型在 N-7 的真实形状上跑一遍，断言启动器日志与崩溃报告
//      拿得到配额、总量不超预算。
//
// 用法：
//   node scripts/check-log-export-budget.mjs
//   node scripts/test-check-log-export-budget.mjs

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const LEDGER = 'commons/src/main/ets/utils/ActivityLedger.ets';
const BUDGET = 'commons/src/main/ets/utils/LogExportBudget.ets';
const EXPORT = 'commons/src/main/ets/utils/LogExport.ets';

export function readSources() {
  const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');
  return { ledger: read(LEDGER), budget: read(BUDGET), logExport: read(EXPORT) };
}

/**
 * 等价模型：allocateExportBudget 的 Node 复刻。
 *
 * ⚠️ 这是**复刻**，不是同一份代码 —— ArkTS 跑在设备上，Node 跑在这里。
 * 防漂移靠两件事：① 下面的结构断言钉住 ArkTS 侧算法的形状；
 * ② ArkTS 单测与本门禁**跑同一组 N-7 语料并断言同样的结论**，
 *    任一侧改坏了，两处不会同时变绿。
 */
export function allocateExportBudget(demands, totalBudget) {
  const grants = demands.map((d) => ({ id: d.id, granted: 0, truncated: false }));
  if (demands.length === 0) return grants;

  const want = (d) => (d.bytes > 0 ? d.bytes : 0);
  const totalDemand = demands.reduce((s, d) => s + want(d), 0);
  if (totalBudget <= 0 || totalDemand <= totalBudget) {
    demands.forEach((d, i) => { grants[i].granted = want(d); });
    return grants;
  }

  const order = demands.map((_, i) => i)
    .sort((a, b) => (demands[a].priority - demands[b].priority) || (a - b));

  let remaining = totalBudget;
  for (const i of order) {
    const floor = demands[i].floorBytes > 0 ? demands[i].floorBytes : 0;
    let give = Math.min(want(demands[i]), floor);
    if (give > remaining) give = remaining;
    grants[i].granted = give;
    remaining -= give;
    if (remaining <= 0) break;
  }

  if (remaining > 0) {
    const unmetTotal = demands.reduce((s, d, i) => s + Math.max(0, want(d) - grants[i].granted), 0);
    if (unmetTotal > 0) {
      let handedOut = 0;
      for (const i of order) {
        const unmet = want(demands[i]) - grants[i].granted;
        if (unmet <= 0) continue;
        const share = Math.min(unmet, Math.floor(remaining * unmet / unmetTotal));
        grants[i].granted += share;
        handedOut += share;
      }
      let leftover = remaining - handedOut;
      for (const i of order) {
        if (leftover <= 0) break;
        const unmet = want(demands[i]) - grants[i].granted;
        if (unmet <= 0) continue;
        const give = Math.min(unmet, leftover);
        grants[i].granted += give;
        leftover -= give;
      }
    }
  }

  demands.forEach((d, i) => { grants[i].truncated = grants[i].granted < want(d); });
  return grants;
}

const KB = 1024;

/** N-7 的真实形状：游戏日志巨大，其余都很小。与 ArkTS 单测**同一组语料**。 */
export function n7Demands() {
  return [
    { id: 'LAUNCHER',     bytes: 300 * KB,   priority: 2, floorBytes: 48 * KB },
    { id: 'GAME',         bytes: 16000 * KB, priority: 3, floorBytes: 64 * KB },
    { id: 'MC_LATEST',    bytes: 800 * KB,   priority: 4, floorBytes: 16 * KB },
    { id: 'JVM',          bytes: 4 * KB,     priority: 5, floorBytes: 8 * KB },
    { id: 'CRASH_REPORT', bytes: 12 * KB,    priority: 1, floorBytes: 32 * KB },
  ];
}

export function analyze(sources) {
  const r = { ok: false, fatal: null, structure: [], numeric: [], grants: null };

  // ── 1. 结构：修复的形状必须还在
  const need = [
    [sources.ledger, 'allocateExportBudget(', 'ledgerExport 必须先分配配额'],
    [sources.ledger, 'ledgerReadForExport_(filesDir, activityId, p, g.granted)',
      'part 必须**带着配额**读 —— 去掉 maxBytes 会静默恢复成 16 MB 全读'],
    // ⚠️ 2026-09-06 自审抓出：直接用 ledgerRead(part, maxBytes) 是**保尾读**，
    // 头部在返回之前就没了，再调 truncateUtf8HeadTail 是死代码。
    // 所以这里钉的是「导出走的是那个会读头的专用函数」，而不是「调过头尾截断」。
    [sources.ledger, 'readLogFileHead(headPath, headBudget)',
      '导出必须真的去读**文件头部**，否则保头是空话'],
    [sources.ledger, 'truncateUtf8HeadTail(body, g.granted)',
      '最终仍要有一道字节钳制兜底'],
    [sources.ledger, 'ledgerPartExportPriority_', '导出优先级表必须存在'],
    [sources.ledger, 'ledgerPartExportFloor_', '保底配额表必须存在'],
    [sources.logExport, 'export function truncateUtf8HeadTail', '头尾截断函数必须存在'],
    [sources.logExport, 'export function exportLimitOf', '预算查询必须是公开的'],
    [sources.logExport, 'if (target === LogExportTarget.LOGSHARE) return 10 * 1024 * 1024',
      'LogShare 必须使用服务端 10 MiB 预算，不能回退到 2 MiB'],
    [sources.budget, 'export function allocateExportBudget', '分配器必须存在'],
  ];
  for (const [text, needle, label] of need) {
    if (text.indexOf(needle) < 0) r.structure.push(`${label}（找不到 \`${needle}\`）`);
  }

  // ⚠️ 反向结构判据：拼装循环里不许再出现「不带配额的 ledgerRead」。
  // 这是回归最可能的形状 —— 改的人未必意识到 maxBytes 是承重的。
  const loopStart = sources.ledger.indexOf('for (let i = 0; i < parts.length; i++)');
  if (loopStart < 0) {
    r.structure.push('找不到 ledgerExport 的拼装循环 —— 结构变了，本门禁的判据可能已失效');
  } else {
    const loop = sources.ledger.slice(loopStart, loopStart + 1600);
    if (/ledgerRead\(filesDir,\s*activityId,\s*p\s*\)/.test(loop)) {
      r.structure.push('拼装循环里出现了**不带配额**的 ledgerRead —— 配额会形同虚设');
    }
    // 回归形状之二：直接用 ledgerRead 而不是导出专用读取。
    // 两者签名很像，改的人未必知道前者是保尾读、会把「保头」变成死代码。
    if (/\bledgerRead\(filesDir,\s*activityId,\s*p,\s*g\.granted\)/.test(loop)) {
      r.structure.push('拼装循环直接用了 ledgerRead —— 那是**保尾读**，头部会在返回前就丢掉');
    }
  }

  // ── 2. 数值：在 N-7 语料上跑等价模型
  const demands = n7Demands();
  const budget = 240 * KB;
  const grants = allocateExportBudget(demands, budget);
  r.grants = grants;
  const get = (id) => (grants.find((g) => g.id === id) || { granted: -1 }).granted;

  const sum = grants.reduce((s, g) => s + g.granted, 0);
  if (sum > budget) r.numeric.push(`分配总量 ${sum} 超过预算 ${budget}`);
  if (get('LAUNCHER') < 48 * KB) {
    r.numeric.push(`启动器日志只分到 ${get('LAUNCHER')} B，低于保底 ${48 * KB} B —— N-7 回归了`);
  }
  if (get('CRASH_REPORT') !== 12 * KB) {
    r.numeric.push(`崩溃报告只有 12 KB 却没被完整保留（分到 ${get('CRASH_REPORT')} B）`);
  }
  if (get('GAME') >= budget) {
    r.numeric.push(`游戏日志吃掉了全部预算（${get('GAME')} B）`);
  }
  for (const g of grants) {
    if (g.granted <= 0) r.numeric.push(`${g.id} 分到 0 字节 —— 整段被静默丢掉`);
  }

  r.ok = r.structure.length === 0 && r.numeric.length === 0;
  return r;
}

const isMain = process.argv[1]
  && path.resolve(process.argv[1]) === path.resolve(url.fileURLToPath(import.meta.url));

if (isMain) {
  const r = analyze(readSources());
  const dump = (label, arr) => {
    if (arr.length === 0) return;
    console.error(`\n--- ${label}（${arr.length}）---`);
    for (const x of arr) console.error(`  ${x}`);
  };
  dump('结构', r.structure);
  dump('数值（N-7 语料）', r.numeric);

  if (r.ok) {
    const line = r.grants.map((g) => `${g.id}=${(g.granted / KB).toFixed(0)}KB`).join(' ');
    console.log(`✅ check-log-export-budget: 结构完整；240KB 预算下的分配 ${line}`);
    process.exit(0);
  }
  console.error('\n❌ check-log-export-budget 未通过');
  process.exit(1);
}
