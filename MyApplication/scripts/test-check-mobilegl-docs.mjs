#!/usr/bin/env node
// scripts/test-check-mobilegl-docs.mjs — check-mobilegl-docs 的定向自测
//
// gitLog 注入：不碰真子模块历史就能测"README 提交栈与实际不符 ⇒ 红"的全部方向。

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';
import { analyze, commitTableHashes, README_REL } from './check-mobilegl-docs.mjs';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
let failed = 0;
function check(name, cond, extra) {
  if (cond) console.log(`  ok   ${name}`);
  else { failed += 1; console.error(`  FAIL ${name}${extra ? `\n       ${extra}` : ''}`); }
}

// ── 1. commitTableHashes 纯函数 ──
{
  const md = [
    '| # | commit | 内容 |',
    '|---|---|---|',
    '| 1 | `2dfebe20` | x |',
    '| 2 | `984aa40f` | y |',
    '不是表的行 `deadbeef` 不算',
  ].join('\n');
  const got = commitTableHashes(md);
  check('只取表行的短哈希、保序', JSON.stringify(got) === JSON.stringify(['2dfebe20', '984aa40f']), JSON.stringify(got));
}

// ── 2. 真树 + 真 git log ──
{
  const r = analyze({});
  check('real tree: PASS', r.ok === true, JSON.stringify(r.problems));
}

// ── 3. gitLog 注入负向（以真 README 的表为基准合成完整哈希） ──
const readme = fs.readFileSync(path.join(ROOT, ...README_REL.split('/')), 'utf8');
const table = commitTableHashes(readme);
const synth = table.map(h => h + 'f'.repeat(40 - h.length));
{
  const ok = analyze({ gitLog: synth });
  check('合成一致 gitLog ⇒ PASS（README 其余事实照常校验）', ok.ok === true, JSON.stringify(ok.problems));

  const extra = analyze({ gitLog: [...synth, 'e'.repeat(40)] });
  check('实际多一个 commit ⇒ 行数红', extra.ok === false && extra.problems.some(p => p.includes('行')));

  const reordered = analyze({ gitLog: [...synth].reverse() });
  check('顺序不符 ⇒ 红', reordered.ok === false && reordered.problems.some(p => p.includes('不符')));

  const swapped = [...synth];
  swapped[0] = 'a'.repeat(40);
  const mismatch = analyze({ gitLog: swapped });
  check('第 1 行哈希不符 ⇒ 红', mismatch.ok === false && mismatch.problems.some(p => p.includes('第 1 行')));
}

console.log(failed === 0 ? 'test-check-mobilegl-docs: all passed' : `test-check-mobilegl-docs: ${failed} FAILED`);
process.exitCode = failed === 0 ? 0 : 1;
