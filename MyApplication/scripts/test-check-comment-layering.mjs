#!/usr/bin/env node
// check-comment-layering.mjs 的定向自测。
//
// 这道门禁写错的失败方式是**静默放行**：有人加了一段 60 行的内嵌变更日志，而检查说 PASS。
// 所以每条性质都双向测。另外它是**棘轮**，所以"变短"必须被识别为改善而不是问题 ——
// 否则偿还长注释的人会被自己的门禁挡住，那样没人会去偿还。

import { compareToBaseline, measureFile } from './check-comment-layering.mjs';

let failures = 0;
function check(label, ok, detail) {
  if (ok) { console.log(`[test-check-comment-layering] PASS: ${label}`); return; }
  failures += 1;
  console.error(`[test-check-comment-layering] FAIL: ${label}`);
  if (detail !== undefined) console.error(`  ${detail}`);
}

// ---- measureFile --------------------------------------------------------------

{
  const src = [
    '// a', '// b', '// c',        // 3 行块
    'int code = 0;',
    '// x',                        // 1 行块
    'int more = 1;',
  ].join('\n');
  const m = measureFile(src);
  check('consecutive line comments count as one block',
    m.worstBlock === 3, JSON.stringify(m));
  check('a blank code line ends the block',
    m.commentLines === 4, JSON.stringify(m));
  check('worst block start line is reported',
    m.worstBlockAt === 1, JSON.stringify(m));
}

{
  // 块注释按它跨的行数算 —— 否则把 60 行的 /* */ 写成一个 "1 行注释" 就绕过去了。
  const src = 'int a = 0;\n/*\n1\n2\n3\n4\n*/\nint b = 1;';
  const m = measureFile(src);
  check('a block comment counts every line it spans',
    m.worstBlock >= 5, JSON.stringify(m));
}

{
  // 字符串里的 // 不是注释（复用的切分器保证），否则会虚报块长。
  const src = 'const char* s = "// not a comment";\nint a = 0;';
  const m = measureFile(src);
  check('a `//` inside a string literal is not a comment block',
    m.worstBlock === 0, JSON.stringify(m));
}

{
  const src = ['// only', '// comments'].join('\n');
  const m = measureFile(src);
  check('percentage is computed against total lines',
    m.pct === 100, JSON.stringify(m));
}

// ---- compareToBaseline（棘轮语义）----------------------------------------------

const baseline = {
  recordedAt: '2026-08-21',
  worstBlockPerFile: { 'a.cpp': 10, 'b.cpp': 45 },
};
const mk = (perFile) => ({ perFile });

{
  const d = compareToBaseline(
    mk({ 'a.cpp': { worstBlock: 10, worstBlockAt: 1 } }), baseline);
  check('unchanged file is neither growth nor payback',
    d.grew.length === 0 && d.shrank.length === 0, JSON.stringify(d));
}

{
  const d = compareToBaseline(
    mk({ 'a.cpp': { worstBlock: 11, worstBlockAt: 7 } }), baseline);
  check('one extra comment line is reported as a regression',
    d.grew.length === 1 && d.grew[0].before === 10 && d.grew[0].now === 11,
    JSON.stringify(d));
}

{
  // 承重：偿还必须被识别为改善。若把它当成 diff 一律失败，没人会去偿还。
  const d = compareToBaseline(
    mk({ 'b.cpp': { worstBlock: 12, worstBlockAt: 1 } }), baseline);
  check('a shorter block is payback, not a failure',
    d.grew.length === 0 && d.shrank.length === 1 && d.shrank[0].before === 45,
    JSON.stringify(d));
}

{
  // 新文件：短的放行（新文件本来就要写文件头），超过"响亮"阈值才拦。
  const d = compareToBaseline(
    mk({ 'new.cpp': { worstBlock: 25, worstBlockAt: 1 } }), baseline);
  check('a new file with a moderate header is allowed',
    d.added.length === 0, JSON.stringify(d));
}

{
  const d = compareToBaseline(
    mk({ 'new.cpp': { worstBlock: 40, worstBlockAt: 1 } }), baseline);
  check('a new file with a 40-line block is reported',
    d.added.length === 1 && d.added[0].now === 40, JSON.stringify(d));
}

{
  // 没有基线时不得静默放行成 PASS —— 调用方必须能区分"没有基线"与"通过"。
  const d = compareToBaseline(
    mk({ 'a.cpp': { worstBlock: 99, worstBlockAt: 1 } }), { worstBlockPerFile: {} });
  check('with an empty baseline a huge new block is still reported',
    d.added.length === 1, JSON.stringify(d));
}

if (failures > 0) {
  console.error(`[test-check-comment-layering] ${failures} case(s) failed`);
  process.exitCode = 1;
} else {
  console.log('[test-check-comment-layering] ALL PASS');
}
