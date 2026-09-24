#!/usr/bin/env node
// scripts/test-check-mobilegl-cxx-gaps.mjs — check-mobilegl-cxx-gaps 的定向自测
//
// 核心负向：**逐条**把 REQUIRED_SNIPPETS 的锚从对应文件内容里抠掉，断言恰好那一条红 ——
// 这道门禁存在的目的就是"rebase 掉任何一个 clang15 绕行都会响"，所以自测必须逐条证明。

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';
import { analyze, checkOhosBeforeLinux, REQUIRED_SNIPPETS, SUB_REL } from './check-mobilegl-cxx-gaps.mjs';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
let failed = 0;
function check(name, cond, extra) {
  if (cond) console.log(`  ok   ${name}`);
  else { failed += 1; console.error(`  FAIL ${name}${extra ? `\n       ${extra}` : ''}`); }
}

function realRead(rel) {
  const abs = path.join(ROOT, ...SUB_REL.split('/'), ...rel.split('/'));
  return fs.existsSync(abs) ? fs.readFileSync(abs, 'utf8') : null;
}

// ── 1. 真树基线 ──
{
  const r = analyze({});
  check('real tree: PASS', r.ok === true, JSON.stringify(r.problems));
}

// ── 2. 逐条抠锚 ⇒ 恰好那条红 ──
for (const snip of REQUIRED_SNIPPETS) {
  const r = analyze({
    readFile: (rel) => {
      const text = realRead(rel);
      if (text === null) return null;
      return rel === snip.file ? text.replaceAll(snip.needle, '/* mutated */') : text;
    },
  });
  const hitSelf = r.problems.some(p => p.startsWith(`${snip.id}:`));
  // 抠掉一个锚可能连带触发顺序断言（如抠 __OHOS__ 分支）——只要求"自己那条必红"。
  check(`抠掉 ${snip.id} ⇒ 红`, r.ok === false && hitSelf, JSON.stringify(r.problems));
}

// ── 3. 文件整个消失 ⇒ 红 ──
{
  const r = analyze({ readFile: (rel) => (rel === 'CMakeLists.txt' ? null : realRead(rel)) });
  check('CMakeLists.txt 消失 ⇒ 红', r.ok === false && r.problems.some(p => p.includes('文件不存在')));
}

// ── 4. __OHOS__ / __linux__ 顺序断言（纯函数直测） ──
{
  check('顺序正确 ⇒ null',
    checkOhosBeforeLinux('#elif defined(__OHOS__)\n#elif defined(__linux__)\n') === null);
  check('顺序颠倒 ⇒ 红',
    checkOhosBeforeLinux('#elif defined(__linux__)\n#elif defined(__OHOS__)\n') !== null);
  check('缺 __OHOS__ ⇒ 红',
    checkOhosBeforeLinux('#elif defined(__linux__)\n') !== null);
  // 上游把 __linux__ 分支整个改走（结构变化）⇒ 也要有人来看
  check('缺 __linux__ ⇒ 红（结构变化要人工复核）',
    checkOhosBeforeLinux('#elif defined(__OHOS__)\n') !== null);
}

console.log(failed === 0 ? 'test-check-mobilegl-cxx-gaps: all passed' : `test-check-mobilegl-cxx-gaps: ${failed} FAILED`);
process.exitCode = failed === 0 ? 0 : 1;
