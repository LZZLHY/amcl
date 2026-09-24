#!/usr/bin/env node
// scripts/check-log-coalesce-wiring.mjs
//
// 日志系统重构 · P2 的**接线**门禁。
//
// ⭐ 为什么单独有这一道：`tests/host/log_coalesce_test.cpp` 测的是**纯策略**
// （`amcl_log_coalesce.h`），它证明不了 `amcl_log.cpp` 把策略**接对了**。
// 而这次接线恰好出过一个让收益直接归零的缺陷：
//
//   writer 每轮末尾无条件调 `flushCoalescedLocked(false)`（本意是「轮转前收尾」），
//   但 `rotateLogFiles` 内部才判断大小、绝大多数周期是 no-op。
//   writer 每 500 ms 醒一次而心跳约 1 s 一条 ⇒ 游程长度恒为 1 ⇒ **合并完全失效**。
//   文件照常写、日志照常有、门禁照常绿 —— 唯一的症状是那 3.55× 从来没兑现。
//
// 这是「静默失效」的教科书形状，且**纯策略用例与宿主编译都看不见它**。
//
// 用法：
//   node scripts/check-log-coalesce-wiring.mjs
//   node scripts/test-check-log-coalesce-wiring.mjs

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const IMPL = 'entry/src/main/cpp/utils/amcl_log.cpp';
const POLICY = 'entry/src/main/cpp/utils/amcl_log_coalesce.h';

export function readSources() {
  const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');
  return { impl: read(IMPL), policy: read(POLICY) };
}

export function analyze(sources) {
  const r = { ok: false, fatal: null, checks: [] };
  const fail = (msg) => r.checks.push(msg);

  // ── 1. 策略与实现都在
  //
  // ⚠️ 判据一律用**正则 + 词边界**，不用 indexOf 子串匹配：
  //    `amclCoalesceMatches` 是 `amclCoalesceMatchesX` 的前缀，改名之后子串匹配依然命中
  //    ⇒ 门禁在符号被改名后仍然是绿的。自测第一版就是被这个骗过去的。
  for (const [text, re, label] of [
    [sources.policy, /\bamclCoalesceMatches\s*\(/, '策略：逐字比较'],
    [sources.policy, /\bamclCoalesceNoteRepeat\s*\(/, '策略：计数与上限'],
    [sources.policy, /\bamclCoalesceReset\s*\(/, '策略：状态清零'],
    [sources.policy, /\bamclCoalesceFormatBody\s*\(/, '策略：计数行正文'],
    // 必须是**没被注释掉**的 include：行首只允许空白
    [sources.impl, /^[ \t]*#include\s+"amcl_log_coalesce\.h"/m, '实现引用了纯策略头'],
    [sources.impl, /\bstatic\s+void\s+emitEntry\s*\(/, '实现：唯一的落盘出口'],
  ]) {
    if (!re.test(text)) fail(`${label} 缺失（判据 ${re}）`);
  }

  // ── 2. ⭐ 承重：轮转前的收尾必须**被条件保护**
  const rotateGuarded = /if\s*\(\s*willRotateLogFiles\(\)\s*\)\s*flushCoalescedLocked/.test(sources.impl);
  if (!rotateGuarded) {
    fail('轮转前的 flushCoalescedLocked 没有被 willRotateLogFiles() 保护 —— '
      + 'rotateLogFiles 绝大多数周期是 no-op，无条件收尾会让游程恒为 1、合并收益归零');
  }
  if (!/\bstatic\s+bool\s+willRotateLogFiles\s*\(\s*\)/.test(sources.impl)) {
    fail('缺 willRotateLogFiles() —— 没有它就无法只在真要轮转时收尾');
  }

  // ── 3. 反向：writer 主循环里不许出现**裸的**每周期收尾
  //    判据：主循环体内除了「被 if 保护的那一处」和「丢弃元日志那一处」，
  //    不该再有独立成句的 flushCoalescedLocked。
  const loopStart = sources.impl.indexOf('static void writerThreadFunc');
  if (loopStart < 0) {
    fail('找不到 writerThreadFunc —— 结构变了，本门禁的判据可能已失效');
  } else {
    const loopEnd = sources.impl.indexOf('// ==================== 公共 API', loopStart);
    const body = sources.impl.slice(loopStart, loopEnd > 0 ? loopEnd : loopStart + 4000);
    const calls = [...body.matchAll(/([^\n]*)flushCoalescedLocked\(/g)].map((m) => m[1].trim());
    for (const prefix of calls) {
      const guarded = prefix.startsWith('if (') || prefix.startsWith('//');
      // 丢弃元日志与关停收尾是允许的裸调用，它们各自只在条件分支里
      if (!guarded && prefix !== '' ) {
        fail(`writerThreadFunc 里出现可疑的 flushCoalescedLocked 调用：\`${prefix}flushCoalescedLocked(\``);
      }
    }
    // 裸调用（prefix 为空，即独立成句）应当恰好两处：丢弃元日志前 + 关停收尾
    const bare = calls.filter((p) => p === '').length;
    if (bare !== 2) {
      fail(`writerThreadFunc 里独立成句的 flushCoalescedLocked 有 ${bare} 处，期望 2 处`
        + '（丢弃元日志前、关停收尾）。多出来的那处极可能是每周期无条件收尾。');
    }
  }

  // ── 4. 生命周期：init 与 fork 之后必须清状态
  //    不清的话，下一个生命周期的第一条日志会被拿去与上一个生命周期的最后一行比较。
  // ⚠️ 必须锚到**定义**而不是前向声明：`static void onForkInChild();` 出现在文件上方，
  //    匹配到它会让下面的片段扫描落在完全无关的位置 ⇒ 假阳性。
  //    本门禁第一次运行就是这么误报的，而**误报会让门禁被摘掉**，比漏报更致命。
  const initIdx = sources.impl.indexOf('extern "C" void amclLogInit');
  const forkIdx = sources.impl.indexOf('static void onForkInChild() {');
  for (const [idx, where] of [[initIdx, 'amclLogInit'], [forkIdx, 'onForkInChild']]) {
    if (idx < 0) { fail(`找不到 ${where}`); continue; }
    const seg = sources.impl.slice(idx, idx + 2200);
    if (seg.indexOf('amclCoalesceReset(&g_coalesce)') < 0) {
      fail(`${where} 里没有 amclCoalesceReset —— 跨生命周期/跨 fork 的残留状态会造成静默吞行`);
    }
  }

  // ── 5. 关停必须收尾，否则最后一段游程的计数永久丢失
  const shutdownIdx = sources.impl.indexOf('// 关闭前最后刷新');
  if (shutdownIdx < 0) {
    fail('找不到关停排空段');
  } else if (sources.impl.slice(shutdownIdx, shutdownIdx + 900).indexOf('flushCoalescedLocked') < 0) {
    fail('关停排空之后没有收尾 —— 最后一段游程的计数会永久丢失');
  }

  r.ok = r.checks.length === 0;
  return r;
}

const isMain = process.argv[1]
  && path.resolve(process.argv[1]) === path.resolve(url.fileURLToPath(import.meta.url));

if (isMain) {
  const r = analyze(readSources());
  if (r.checks.length > 0) {
    console.error(`\n--- 合并接线问题（${r.checks.length}）---`);
    for (const c of r.checks) console.error(`  ${c}`);
  }
  if (r.ok) {
    console.log('✅ check-log-coalesce-wiring: 合并策略已正确接进 writer（轮转收尾有保护、生命周期已清零、关停有收尾）');
    process.exit(0);
  }
  console.error('\n❌ check-log-coalesce-wiring 未通过');
  process.exit(1);
}
