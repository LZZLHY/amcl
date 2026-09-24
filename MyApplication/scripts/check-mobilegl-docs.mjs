#!/usr/bin/env node
// scripts/check-mobilegl-docs.mjs — 文档与 deps.lock/[mobilegl] 及子模块实态不漂移
//
// ============================ 它挡的是什么 ============================
//
// `prebuilt/mobilegl/README.md` 的提交栈表、分支名、External pin、tl tag 都是**事实陈述**；
// 升级 submodule / rebase 后忘改 README，就是治理规范 §1 缺陷 2（声称一个不存在的机制）
// 的文档版。本门禁把 README 的每条事实和两处权威（deps.lock、子模块 git）对账。
//
// ⚠️ 规范 §8.1 判据：**一切基准值从 lock / git 解析，本脚本零硬编码 SHA** ——
// 硬编码会让它「在正确的树上失败、在已漂移的树上通过」，恰是它存在目的的反面。
//
// 用法：node scripts/check-mobilegl-docs.mjs [--json]

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

import { parseLockSection, SUBMODULE_REL } from './check-mobilegl-pin.mjs';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
export const README_REL = 'prebuilt/mobilegl/README.md';
export const PLAN_REL = 'docs/adaptation/MOBILEGL_ADAPTATION_PLAN.md';

/** README 提交栈表 → 短哈希序列（表序 = 旧→新）。纯函数。 */
export function commitTableHashes(readmeText) {
  const rows = readmeText.match(/^\|\s*\d+\s*\|\s*`([0-9a-f]{6,12})`/gm) || [];
  return rows.map(r => r.match(/`([0-9a-f]{6,12})`/)[1]);
}

/**
 * 主判定。`gitLog`（旧→新的 40 位哈希数组）可注入，自测不需要真仓库。
 */
export function analyze({ root = ROOT, gitLog = null } = {}) {
  const problems = [];

  const lockPath = path.join(root, 'deps.lock');
  const readmePath = path.join(root, ...README_REL.split('/'));
  const planPath = path.join(root, ...PLAN_REL.split('/'));
  for (const [rel, p] of [['deps.lock', lockPath], [README_REL, readmePath], [PLAN_REL, planPath]]) {
    if (!fs.existsSync(p)) return { ok: false, problems: [`缺 ${rel}`] };
  }
  const { fields, problems: lockProblems } = parseLockSection(fs.readFileSync(lockPath, 'utf8'));
  if (lockProblems.length > 0) return { ok: false, problems: lockProblems };

  const readme = fs.readFileSync(readmePath, 'utf8');
  const plan = fs.readFileSync(planPath, 'utf8');

  // ── 提交栈表 == git log base..commit（旧→新） ──
  let actual = gitLog;
  if (actual === null) {
    const sub = path.join(root, ...SUBMODULE_REL.split('/'));
    const r = spawnSync('git', ['log', '--format=%H', '--reverse', `${fields.base_commit}..${fields.commit}`],
      { cwd: sub, encoding: 'utf8' });
    if (r.status !== 0) return { ok: false, problems: [`子模块 git log 失败: ${r.stderr.trim()}`] };
    actual = r.stdout.trim().split('\n').filter(Boolean);
  }
  const table = commitTableHashes(readme);
  if (table.length !== actual.length) {
    problems.push(`README 提交栈表 ${table.length} 行 != 实际 fork 提交 ${actual.length} 个`);
  } else {
    table.forEach((shortHash, i) => {
      if (!actual[i].startsWith(shortHash)) {
        problems.push(`README 提交栈第 ${i + 1} 行 \`${shortHash}\` 与实际 ${actual[i].slice(0, 12)} 不符`);
      }
    });
  }

  // ── 分支名 / base / External pin / tl tag ──
  if (!readme.includes(`\`${fields.branch}\``)) {
    problems.push(`README 未陈述分支名 ${fields.branch}`);
  }
  if (!readme.includes(fields.base_commit.slice(0, 8))) {
    problems.push(`README 未陈述 base_commit 前缀 ${fields.base_commit.slice(0, 8)}`);
  }
  for (const key of ['spirv_tools_commit', 'spirv_headers_commit']) {
    if (!readme.includes(fields[key].slice(0, 8))) {
      problems.push(`README 未陈述 ${key} 前缀 ${fields[key].slice(0, 8)}`);
    }
  }
  if (!readme.includes(fields.tl_expected_tag)) {
    problems.push(`README 未陈述 tl::expected tag ${fields.tl_expected_tag}`);
  }

  // ── 方案文档的基线陈述与 lock 一致（方案多处写 dev@<base 前缀>） ──
  if (!plan.includes(fields.base_commit.slice(0, 8))) {
    problems.push(`${PLAN_REL} 没有出现 base_commit 前缀 ${fields.base_commit.slice(0, 8)}（基线陈述漂移？）`);
  }

  return { ok: problems.length === 0, problems, table, actualCount: actual.length };
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === url.fileURLToPath(import.meta.url);
if (isMain) {
  const res = analyze({});
  if (process.argv.includes('--json')) {
    console.log(JSON.stringify(res, null, 2));
  } else {
    for (const p of res.problems) console.error(`  FAIL: ${p}`);
    console.log(res.ok
      ? `check-mobilegl-docs PASS (提交栈 ${res.actualCount} 条对上)`
      : `check-mobilegl-docs FAIL (${res.problems.length} 处)`);
  }
  process.exitCode = res.ok ? 0 : 1;
}
