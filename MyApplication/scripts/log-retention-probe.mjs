#!/usr/bin/env node
// scripts/log-retention-probe.mjs
//
// 日志系统重构 · P1「度量」。把「这条通道的保留预算实际能覆盖多久」变成一个可以数的数。
//
// 为什么先做度量再动手（AGENTS §二.1 / §二.2）：本方向已经因为「凭感觉排优先级」错过一次 ——
// N-4 被按「磁盘每小时涨 8 MB」排序，真机实测 2,240 B，差约 3.5 个数量级，而真正占 8 MB 的
// glsl_cache.tmp 是着色器缓存不是日志（施工记录 §S03.3）。
//
// 核心指标：
//     有效保留时长 = 通道保留预算 ÷ 字节速率
// 它的好处是**任何人刷屏它都会掉**，且能直接从产物算出来，不依赖任何声明。
//
// 本探针还回答方案 §八 留下的一个未决问题：
//   「SAMPLE 合并该按什么规范化？数字归一化会不会把不同 generation 的心跳压成一条、
//     从而掩盖真实的窗口重建？」
// 做法是**同时**报告两种口径 —— 逐字重复 与 数字归一化重复 —— 并对每个归一化形状给出
// 它底下有多少个 distinct 的逐字文本。两者差得越多，归一化就越危险。
//
// 用法：
//   node scripts/log-retention-probe.mjs <日志文件...> [--budget-bytes N] [--json 输出.json]
//   node scripts/log-retention-probe.mjs diagnostics/logging-architecture-20260906/amcl_launcher.log

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');

/**
 * tag → domain 映射（P4 的域注册表）。
 *
 * 这是 P4 的兑现点：没有它，「谁在刷屏」只能得到一个 tag 名，
 * 而 tag 有 155 个、还会随重构改名；有了它就能直接回答**哪个子系统**在刷屏，
 * 那才是能挂策略的粒度。读不到注册表时降级为「只按 tag 报」，不让探针本身失效。
 */
function loadDomains() {
  try {
    const doc = JSON.parse(fs.readFileSync(path.join(ROOT, 'config/log-domains.json'), 'utf8'));
    return doc.tags || {};
  } catch {
    return null;
  }
}

/** 启动器日志的保留预算：单文件 2 MiB × (当前 + 5 备份)。 */
const DEFAULT_BUDGET_BYTES = 12 * 1024 * 1024;

/** 出现次数达到这个值才算「重复形状」，低于它属于正常的偶发同类事件。 */
const REPEAT_THRESHOLD = 10;

/**
 * `[2026-09-06 20:49:31][I][MC_LAUNCHER] 正文`
 * 这是 amcl_log.cpp 的 writerThreadFunc 与 AppLogger 共同的行格式。
 */
const LINE_RE = /^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\[([A-Z])\]\[([^\]]+)\]\s?([\s\S]*)$/;

/** 数字归一化：把所有数值换成 #。这是「可能合并过头」的那一种口径。 */
function normalizeNumbers(s) {
  return s.replace(/-?\d+(?:\.\d+)?/g, '#');
}

export function analyzeText(text, opts = {}) {
  const budget = opts.budgetBytes || DEFAULT_BUDGET_BYTES;
  const lines = text.split('\n').filter((l) => l.length > 0);
  const totalBytes = Buffer.byteLength(text, 'utf8');

  const byTag = new Map();
  const byLevel = new Map();
  const exact = new Map();
  const norm = new Map();
  let parsed = 0;
  let firstTs = null;
  let lastTs = null;

  for (const line of lines) {
    const bytes = Buffer.byteLength(line, 'utf8') + 1;
    const m = LINE_RE.exec(line);
    if (!m) {
      // 续行（Java 堆栈等）算进它所属 tag 的开销并不容易，这里单列，避免悄悄归零。
      const u = byTag.get('(unparsed)') || { lines: 0, bytes: 0 };
      u.lines++; u.bytes += bytes; byTag.set('(unparsed)', u);
      continue;
    }
    parsed++;
    const [, ts, level, tag, body] = m;
    const t = Date.parse(ts.replace(' ', 'T') + 'Z');
    if (!Number.isNaN(t)) {
      if (firstTs === null || t < firstTs) firstTs = t;
      if (lastTs === null || t > lastTs) lastTs = t;
    }

    const tg = byTag.get(tag) || { lines: 0, bytes: 0 };
    tg.lines++; tg.bytes += bytes; byTag.set(tag, tg);
    byLevel.set(level, (byLevel.get(level) || 0) + 1);

    const ek = tag + '\u0000' + body;
    const e = exact.get(ek) || { tag, body, count: 0, bytes: 0 };
    e.count++; e.bytes += bytes; exact.set(ek, e);

    const nk = tag + '\u0000' + normalizeNumbers(body);
    const n = norm.get(nk) || { tag, shape: normalizeNumbers(body), count: 0, bytes: 0, distinct: new Set() };
    n.count++; n.bytes += bytes; n.distinct.add(body); norm.set(nk, n);
  }

  const spanHours = (firstTs !== null && lastTs !== null && lastTs > firstTs)
    ? (lastTs - firstTs) / 3600000 : 0;
  const bytesPerHour = spanHours > 0 ? totalBytes / spanHours : 0;

  // ⚠️ 上面两种口径都是**全局去重**，它们是理论上界，不是 writer 能做到的事。
  // writer 看到的是一条流，它只能合并「连续相同」的行（或带一个有界的回看窗口）。
  // 所以必须再算一个**连续游程**口径 —— 这才是实现的真实上界。
  // 不算这一个，就会拿理论值去承诺工程收益，那正是本方向已经犯过一次的错。
  let runs = 0;
  let collapsedRuns = 0;
  let prevKey = null;
  let runBytes = 0;
  let pendingLen = 0;          // 当前游程已累计的行数
  let pendingHeadBytes = 0;    // 当前游程首行的字节
  const closeRun = () => {
    if (pendingLen === 0) return;
    // 计数后缀（形如 " (×7491, 22.6h)"）只在真的合并了才付，游程长度为 1 时不付。
    runBytes += pendingHeadBytes + (pendingLen > 1 ? 24 : 0);
    if (pendingLen > 1) collapsedRuns++;
    pendingLen = 0;
  };
  for (const line of lines) {
    const bytes = Buffer.byteLength(line, 'utf8') + 1;
    const m = LINE_RE.exec(line);
    if (!m) { closeRun(); prevKey = null; runBytes += bytes; continue; }
    // 合并键必须与 native 实现一致：amcl_log_coalesce.h 比的是
    // level + activityId + tag + message。行里没有 activityId（它只决定分流到哪个账本），
    // 但 level 与 tag 必须参与，否则这里会比实现**多合并**，估算就偏乐观了。
    const key = m[2] + '\u0000' + m[3] + '\u0000' + m[4];
    if (key !== prevKey) {
      closeRun();
      runs++;
      prevKey = key;
      pendingHeadBytes = bytes;
      pendingLen = 1;
    } else {
      pendingLen++;
    }
  }
  closeRun();

  const repeatedExact = [...exact.values()].filter((x) => x.count >= REPEAT_THRESHOLD);
  const repeatedNorm = [...norm.values()].filter((x) => x.count >= REPEAT_THRESHOLD);
  const exactRepeatBytes = repeatedExact.reduce((s, x) => s + x.bytes, 0);
  const normRepeatBytes = repeatedNorm.reduce((s, x) => s + x.bytes, 0);

  // 合并之后每个形状只留一行（正文 + 计数后缀），估个保守值。
  const coalescedResidual = (arr) => arr.reduce((s, x) => s + Math.ceil(x.bytes / x.count) + 24, 0);
  const afterExact = totalBytes - exactRepeatBytes + coalescedResidual(repeatedExact);
  const afterNorm = totalBytes - normRepeatBytes + coalescedResidual(repeatedNorm);

  const retention = (bytes) => (bytes > 0 && spanHours > 0) ? budget / (bytes / spanHours) : 0;

  return {
    budgetBytes: budget,
    totalBytes,
    totalLines: lines.length,
    parsedLines: parsed,
    spanHours,
    bytesPerHour,
    effectiveRetentionHours: retention(totalBytes),
    byLevel: Object.fromEntries([...byLevel.entries()].sort((a, b) => b[1] - a[1])),
    byTag: [...byTag.entries()]
      .map(([tag, v]) => ({ tag, lines: v.lines, bytes: v.bytes, sharePct: v.bytes / totalBytes * 100 }))
      .sort((a, b) => b.bytes - a.bytes),
    byDomain: (() => {
      const tagToDomain = opts.domains !== undefined ? opts.domains : loadDomains();
      if (!tagToDomain) return null;
      const agg = new Map();
      for (const [tag, v] of byTag) {
        // 未登记的 tag 单列出来，而不是塞进「其它」—— 它意味着域注册表落后于源码，
        // 那本身是个要修的信号，不该被聚合掩盖。
        const d = tagToDomain[tag] !== undefined ? tagToDomain[tag] : `(未登记:${tag})`;
        const cur = agg.get(d) || { lines: 0, bytes: 0, tags: 0 };
        cur.lines += v.lines; cur.bytes += v.bytes; cur.tags++;
        agg.set(d, cur);
      }
      return [...agg.entries()]
        .map(([domain, v]) => ({ domain, tags: v.tags, lines: v.lines, bytes: v.bytes,
          sharePct: v.bytes / totalBytes * 100 }))
        .sort((a, b) => b.bytes - a.bytes);
    })(),
    repetition: {
      threshold: REPEAT_THRESHOLD,
      // 连续游程：writer 真正能做到的那一档。上面两档是理论上界。
      consecutiveRuns: {
        runs,
        collapsedRuns,
        bytes: runBytes,
        sharePct: runBytes / totalBytes * 100,
        retentionAfterCoalesceHours: retention(runBytes),
      },
      exact: {
        shapes: repeatedExact.length,
        bytes: exactRepeatBytes,
        sharePct: exactRepeatBytes / totalBytes * 100,
        retentionAfterCoalesceHours: retention(afterExact),
      },
      normalized: {
        shapes: repeatedNorm.length,
        bytes: normRepeatBytes,
        sharePct: normRepeatBytes / totalBytes * 100,
        retentionAfterCoalesceHours: retention(afterNorm),
      },
      // ⭐ 方案 §八 那个未决问题的判据：每个归一化形状底下有多少种逐字文本。
      // distinct == 1 ⇒ 归一化没有多合并任何东西，安全。
      // distinct 很大 ⇒ 归一化正在吃掉真实变化，合并键必须更精细。
      topShapes: repeatedNorm
        .sort((a, b) => b.bytes - a.bytes)
        .slice(0, 12)
        .map((x) => ({
          tag: x.tag,
          count: x.count,
          bytes: x.bytes,
          sharePct: x.bytes / totalBytes * 100,
          distinctExact: x.distinct.size,
          shape: x.shape.slice(0, 100),
        })),
    },
  };
}

function fmtH(h) { return h > 0 ? h.toFixed(1) + ' h' : '—'; }

function report(name, r) {
  console.log(`\n=== ${name} ===`);
  console.log(`  字节 ${r.totalBytes}  行 ${r.totalLines}（可解析 ${r.parsedLines}）  覆盖 ${fmtH(r.spanHours)}`);
  console.log(`  级别 ${JSON.stringify(r.byLevel)}`);
  console.log(`  字节速率 ${(r.bytesPerHour / 1024).toFixed(1)} KiB/h`);
  console.log(`  保留预算 ${(r.budgetBytes / 1024 / 1024).toFixed(0)} MiB`);
  console.log(`  ⭐ 有效保留时长 ${fmtH(r.effectiveRetentionHours)}`);

  if (r.byDomain) {
    console.log(`\n  --- ⭐ 按**域**的字节份额（P4 域注册表）---`);
    for (const d of r.byDomain.slice(0, 8)) {
      console.log(`   ${d.sharePct.toFixed(1).padStart(5)}%  ${String(d.lines).padStart(6)} 行  ${d.domain}（${d.tags} 个 tag）`);
    }
  } else {
    console.log(`\n  （读不到 config/log-domains.json，按域聚合已跳过）`);
  }

  console.log(`\n  --- 按 tag 的字节份额（前 10）---`);
  for (const t of r.byTag.slice(0, 10)) {
    console.log(`   ${t.sharePct.toFixed(1).padStart(5)}%  ${String(t.lines).padStart(6)} 行  ${t.tag}`);
  }

  const rep = r.repetition;
  console.log(`\n  --- 合并能回收多少（三种口径）---`);
  console.log(`   ⭐ 连续游程（writer 真能做到）  ${rep.consecutiveRuns.runs} 段（其中 ${rep.consecutiveRuns.collapsedRuns} 段真的被合并）  →  有效保留 ${fmtH(rep.consecutiveRuns.retentionAfterCoalesceHours)}`);
  console.log(`      逐字全局去重（理论上界）     ${rep.exact.shapes} 形状 ${rep.exact.sharePct.toFixed(1)}% 字节  →  ${fmtH(rep.exact.retentionAfterCoalesceHours)}`);
  console.log(`      数字归一化（理论上界，有害） ${rep.normalized.shapes} 形状 ${rep.normalized.sharePct.toFixed(1)}% 字节  →  ${fmtH(rep.normalized.retentionAfterCoalesceHours)}`);

  console.log(`\n  --- 最占字节的重复形状 ---`);
  console.log(`   ${'字节%'.padStart(6)} ${'次数'.padStart(6)} ${'逐字种数'.padStart(8)}  tag / 形状`);
  for (const s of rep.topShapes) {
    const risk = s.distinctExact === 1 ? ' ' : (s.distinctExact > s.count * 0.5 ? '!' : '~');
    console.log(`  ${risk}${s.sharePct.toFixed(1).padStart(6)}% ${String(s.count).padStart(6)} ${String(s.distinctExact).padStart(8)}  ${s.tag}: ${s.shape}`);
  }
  console.log(`\n   逐字种数 = 该归一化形状底下有多少种不同的原文。`);
  console.log(`   1 ⇒ 归一化没多合并任何东西；接近次数（标 !）⇒ 归一化正在吃掉真实变化。`);
}

const isMain = process.argv[1]
  && path.resolve(process.argv[1]) === path.resolve(url.fileURLToPath(import.meta.url));

if (isMain) {
  const argv = process.argv.slice(2);
  const files = argv.filter((a) => !a.startsWith('--'));
  const budgetArg = argv.find((a) => a.startsWith('--budget-bytes='));
  const jsonArg = argv.find((a) => a.startsWith('--json='));
  if (files.length === 0) {
    console.error('用法: node scripts/log-retention-probe.mjs <日志文件...> [--budget-bytes=N] [--json=out.json]');
    process.exit(2);
  }
  const budgetBytes = budgetArg ? Number(budgetArg.split('=')[1]) : DEFAULT_BUDGET_BYTES;
  const out = {};
  for (const f of files) {
    const r = analyzeText(fs.readFileSync(f, 'utf8'), { budgetBytes });
    out[f.replace(/\\/g, '/')] = r;
    report(f, r);
  }
  if (jsonArg) {
    const p = jsonArg.split('=')[1];
    fs.writeFileSync(p, JSON.stringify(out, null, 2) + '\n');
    console.log(`\n证据已写入 ${p}`);
  }
}
