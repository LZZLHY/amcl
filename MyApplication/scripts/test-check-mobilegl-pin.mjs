#!/usr/bin/env node
// scripts/test-check-mobilegl-pin.mjs — check-mobilegl-pin 的定向自测
//
// 负向对照全部**实做**（AGENTS.md §2 #8：判定工具先在已知含缺陷的样本上验证过）：
// lock 注入篡改 / patches 目录临时创建。⚠️ 全程 --offline —— 自测不许依赖网络。

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';
import { analyze, parseLockSection, FORBIDDEN_PATCH_DIR_REL } from './check-mobilegl-pin.mjs';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
let failed = 0;
function check(name, cond, extra) {
  if (cond) console.log(`  ok   ${name}`);
  else { failed += 1; console.error(`  FAIL ${name}${extra ? `\n       ${extra}` : ''}`); }
}

const realLock = fs.readFileSync(path.join(ROOT, 'deps.lock'), 'utf8');
const realFields = parseLockSection(realLock).fields;

// ── 1. 真树基线（offline；施工期允许子模块 dirty） ──
{
  const r = analyze({ offline: true, allowDirty: true });
  check('real tree: PASS', r.ok === true, JSON.stringify(r.problems));
}

// ── 2. parseLockSection 负向 ──
{
  check('无 [mobilegl] 节 ⇒ 红',
    parseLockSection('[other]\ncommit = abc\n').problems.length > 0);
  const noCommit = realLock.replace(/(\[mobilegl\][\s\S]*?)^commit\s*=.*$/m, '$1');
  check('负向样本确实删除了 mobilegl.commit', noCommit !== realLock);
  check('缺 commit 字段 ⇒ 红',
    parseLockSection(noCommit).problems.some(p => p.includes('commit')));
  const badSha = realLock.replace(realFields.commit, 'ZZZZ');
  check('commit 不是 40 位 SHA ⇒ 红',
    parseLockSection(badSha).problems.some(p => p.includes('40 位')));
  check('行尾注释被剥掉',
    parseLockSection('[mobilegl]\nbranch = amcl/ohos # trailing\n').fields.branch === 'amcl/ohos');
}

// ── 3. lock 漂移 ⇒ 三处一致必红（对着真子模块跑） ──
{
  const fakeSha = 'a'.repeat(40);
  const drifted = realLock.replace(new RegExp(realFields.commit, 'g'), fakeSha);
  const r = analyze({ offline: true, allowDirty: true, lockText: drifted });
  check('lock.commit 漂移 ⇒ gitlink 不一致红',
    r.problems.some(p => p.includes('gitlink')), JSON.stringify(r.problems));
  check('lock.commit 漂移 ⇒ 子模块 HEAD 不一致红',
    r.problems.some(p => p.includes('子模块 HEAD')));
}
{
  const fakeTree = 'b'.repeat(40);
  const drifted = realLock.replace(realFields.source_tree, fakeTree);
  const r = analyze({ offline: true, allowDirty: true, lockText: drifted });
  check('lock.source_tree 漂移 ⇒ 红',
    r.problems.some(p => p.includes('source_tree')));
}
{
  // base_commit 换成一个不在历史里的假 SHA ⇒ 祖先检查红
  const drifted = realLock.replace(realFields.base_commit, 'c'.repeat(40));
  const r = analyze({ offline: true, allowDirty: true, lockText: drifted });
  check('base_commit 不是祖先 ⇒ 红',
    r.problems.some(p => p.includes('祖先')));
}
{
  const drifted = realLock.replace(realFields.tl_expected_sha256, 'd'.repeat(64));
  const r = analyze({ offline: true, allowDirty: true, lockText: drifted });
  check('tl_expected_sha256 漂移 ⇒ blob 哈希红',
    r.problems.some(p => p.includes('tl/expected.hpp')));
}

// ── 4. patches/ 禁令（实建实删） ──
{
  const dir = path.join(ROOT, ...FORBIDDEN_PATCH_DIR_REL.split('/'));
  check('前置：patches/ 当前不存在', !fs.existsSync(dir));
  fs.mkdirSync(dir, { recursive: true });
  const r = analyze({ offline: true, allowDirty: true });
  fs.rmSync(dir, { recursive: true, force: true });
  check('临时创建 patches/ ⇒ 红', r.problems.some(p => p.includes('patches')));
  check('清理后恢复 PASS', analyze({ offline: true, allowDirty: true }).ok === true);
}

console.log(failed === 0 ? `test-check-mobilegl-pin: all passed` : `test-check-mobilegl-pin: ${failed} FAILED`);
process.exitCode = failed === 0 ? 0 : 1;
