#!/usr/bin/env node
// scripts/test-check-log-coalesce-wiring.mjs
//
// check-log-coalesce-wiring.mjs 的定向自测。
//
// §2 是本门禁存在的全部理由：**复现我真的犯过的那个缺陷**。
// writer 每轮无条件收尾（本意「轮转前收尾」，但 rotateLogFiles 绝大多数周期是 no-op）
// ⇒ 游程恒为 1 ⇒ 合并收益归零，而文件照常写、宿主用例照常绿、编译照常过。
// 这条一旦变绿，说明那 3.55× 又悄悄没了。

import { analyze, readSources } from './check-log-coalesce-wiring.mjs';

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

const real = readSources();

// ── 1. 正向
{
  const r = analyze(real);
  check('real repo: 接线正确', r.ok === true, JSON.stringify(r.checks));
}

// ── 2. ⭐ 承重：复现真实缺陷 —— 每周期无条件收尾
{
  const r = analyze(mutate(real, 'impl',
    'if (willRotateLogFiles()) flushCoalescedLocked(/*keepRun=*/false);',
    'flushCoalescedLocked(/*keepRun=*/false);'));
  check('2.1 ⭐ 轮转收尾去掉条件保护 ⇒ 红', r.ok === false);
  check('2.1 ⭐ 且必须点明「收益归零」',
    r.checks.some((x) => x.includes('收益归零') || x.includes('恒为 1')), JSON.stringify(r.checks));
}
{
  // 把 willRotateLogFiles 整个删掉
  const r = analyze(mutate(real, 'impl',
    'static bool willRotateLogFiles', 'static bool willRotateLogFilesRenamed'));
  check('2.2 willRotateLogFiles 改名 ⇒ 红', r.ok === false, JSON.stringify(r.checks));
}

// ── 3. 生命周期清零
{
  const s = { ...real };
  // 只删 onForkInChild 里那一处（init 里的保留），验证两处是分别检查的
  const forkIdx = s.impl.indexOf('static void onForkInChild() {');
  s.impl = s.impl.slice(0, forkIdx)
    + s.impl.slice(forkIdx).replace('amclCoalesceReset(&g_coalesce);', '/* removed */');
  const r = analyze(s);
  check('3.1 fork 后不清状态 ⇒ 红',
    r.ok === false && r.checks.some((x) => x.includes('onForkInChild')), JSON.stringify(r.checks));
}
{
  const s = { ...real };
  const initIdx = s.impl.indexOf('extern "C" void amclLogInit');
  s.impl = s.impl.slice(0, initIdx)
    + s.impl.slice(initIdx).replace('amclCoalesceReset(&g_coalesce);', '/* removed */');
  const r = analyze(s);
  check('3.2 init 时不清状态 ⇒ 红',
    r.ok === false && r.checks.some((x) => x.includes('amclLogInit')), JSON.stringify(r.checks));
}

// ── 4. 关停收尾
{
  const s = { ...real };
  const idx = s.impl.indexOf('// 关闭前最后刷新');
  s.impl = s.impl.slice(0, idx)
    + s.impl.slice(idx).replace('flushCoalescedLocked(/*keepRun=*/false);', '/* removed */');
  const r = analyze(s);
  check('4.1 关停不收尾 ⇒ 红',
    r.ok === false && r.checks.some((x) => x.includes('永久丢失')), JSON.stringify(r.checks));
}

// ── 5. 策略头与实现的连接
{
  const r = analyze(mutate(real, 'impl',
    '#include "amcl_log_coalesce.h"', '// #include "amcl_log_coalesce.h"'));
  check('5.1 实现不再引用纯策略头 ⇒ 红', r.ok === false, JSON.stringify(r.checks));
}
{
  const r = analyze(mutate(real, 'policy', 'amclCoalesceMatches', 'amclCoalesceMatchesX'));
  check('5.2 策略函数改名 ⇒ 红', r.ok === false, JSON.stringify(r.checks));
}
{
  const r = analyze(mutate(real, 'impl', 'static void emitEntry', 'static void emitEntryX'));
  check('5.3 唯一落盘出口改名 ⇒ 红', r.ok === false, JSON.stringify(r.checks));
}

// ── 6. 结构认不出来时必须硬失败，不许静默放行
{
  const r = analyze(mutate(real, 'impl', 'static void writerThreadFunc', 'static void writerLoop'));
  check('6.1 writerThreadFunc 认不出来 ⇒ 红',
    r.ok === false && r.checks.some((x) => x.includes('判据可能已失效')), JSON.stringify(r.checks));
}

// ── 7. ⚠️ 防误报：门禁第一版把**前向声明**当成了定义，导致真实仓库被误判。
//    误报会让门禁被摘掉，比漏报更致命 —— 所以这条单独钉住。
{
  check('7.1 前向声明不会被当成定义',
    real.impl.indexOf('static void onForkInChild();') >= 0
    && analyze(real).ok === true,
    '仓库里确实存在前向声明，且门禁仍然通过');
}

console.log(failed === 0 ? `\n✅ ALL PASS` : `\n❌ ${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
