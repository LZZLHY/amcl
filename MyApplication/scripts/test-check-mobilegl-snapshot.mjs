#!/usr/bin/env node
// scripts/test-check-mobilegl-snapshot.mjs — check-mobilegl-snapshot 的定向自测
//
// 门禁本体用注入的假源码树（临时目录）测正负两向 —— 自测用自己控制的输入，
// 上游一改就分不清"门禁坏了"还是"上游变了"（施工记录 §S9.4 的判据）。

// 临时夹具及其清理边界统一使用外部宿主测试区，不修改系统 TEMP，也不回退到源码目录。
import { workspaceTempRoot } from './lib/workspace-paths.mjs';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { analyze, listFromCMake, renderSnapshot } from './check-mobilegl-snapshot.mjs';

let failed = 0;
function check(name, cond, extra) {
  if (cond) console.log(`  ok   ${name}`);
  else { failed += 1; console.error(`  FAIL ${name}${extra ? `\n       ${extra}` : ''}`); }
}

// ── 1. listFromCMake 纯函数 ──
{
  const text = [
    'set(SOURCE_FILES',
    '    MobileGL/A.cpp',
    '    MobileGL/B.cpp # 行尾注释不影响',
    '#    MobileGL/Commented.cpp  ← 注释行必须被剥掉',
    '    MobileGL/A.cpp',   // 重复 ⇒ 去重
    ')',
  ].join('\n');
  const got = listFromCMake(text);
  check('提取 + 去重 + 排序', JSON.stringify(got) === JSON.stringify(['MobileGL/A.cpp', 'MobileGL/B.cpp']), JSON.stringify(got));
  check('注释行里的文件不被提取', !got.includes('MobileGL/Commented.cpp'));
}

// ── 2. 假树端到端：正向 + 漂移红 + 快照缺失红 ──
{
  const tmp = fs.mkdtempSync(path.join(workspaceTempRoot(), 'mobilegl-snap-'));
  const src = path.join(tmp, 'src');
  fs.mkdirSync(path.join(src, 'MobileGL', 'MG_Test'), { recursive: true });
  fs.writeFileSync(path.join(src, 'CMakeLists.txt'), 'set(SOURCE_FILES\n    MobileGL/A.cpp\n)\n');
  fs.writeFileSync(path.join(src, 'MobileGL', 'A.cpp'), '// a');
  fs.writeFileSync(path.join(src, 'MobileGL', 'MG_Test', 'T.cpp'), '// t');
  const snapPath = path.join(tmp, 'cmake-snapshot.txt');

  const missing = analyze({ srcRoot: src, snapshotPath: snapPath });
  check('快照不存在 ⇒ 红', missing.ok === false && missing.problems.some(p => p.includes('快照不存在')));

  fs.writeFileSync(snapPath, missing.current, 'utf8');
  const pass = analyze({ srcRoot: src, snapshotPath: snapPath });
  check('快照就位 ⇒ PASS', pass.ok === true, JSON.stringify(pass.problems));
  check('测试域与产品域分开计数', pass.counts.product === 1 && pass.counts.test === 1, JSON.stringify(pass.counts));

  // 上游"悄悄加一个 TU"
  fs.writeFileSync(path.join(src, 'MobileGL', 'New.cpp'), '// new');
  const drift = analyze({ srcRoot: src, snapshotPath: snapPath });
  check('磁盘加文件 ⇒ 漂移红', drift.ok === false && drift.problems.some(p => p.includes('漂移')));
  check('漂移明细列出新文件', drift.problems.some(p => p.includes('MobileGL/New.cpp')));

  // CRLF 快照（Windows 检出）不误报
  fs.rmSync(path.join(src, 'MobileGL', 'New.cpp'));
  fs.writeFileSync(snapPath, missing.current.replaceAll('\n', '\r\n'), 'utf8');
  const crlf = analyze({ srcRoot: src, snapshotPath: snapPath });
  check('CRLF 快照不误报', crlf.ok === true, JSON.stringify(crlf.problems));

  fs.rmSync(tmp, { recursive: true, force: true });
}

// ── 3. renderSnapshot 计数头 ──
{
  const s = renderSnapshot({ cmake: ['a'], product: ['a', 'b'], test: [] });
  check('分节计数正确', s.includes('# cmake-sources (1)') && s.includes('# disk-product-sources (2)') && s.includes('# disk-test-sources (0)'));
}

// ── 4. 真树：当前快照必须绿（快照文件已提交在 prebuilt/mobilegl/） ──
{
  const real = analyze({});
  check('real tree: PASS', real.ok === true, JSON.stringify(real.problems));
}

console.log(failed === 0 ? 'test-check-mobilegl-snapshot: all passed' : `test-check-mobilegl-snapshot: ${failed} FAILED`);
process.exitCode = failed === 0 ? 0 : 1;
