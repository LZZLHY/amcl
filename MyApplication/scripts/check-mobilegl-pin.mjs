#!/usr/bin/env node
// scripts/check-mobilegl-pin.mjs
//
// ============================ 它挡的是什么 ============================
//
// MobileGL 的「三处一致」（治理规范 §6 / 方案 §4.7）：
//   deps.lock [mobilegl].commit == superproject gitlink == 子模块 HEAD
// 外加五条来源纪律：
//   ① 无 patches/ 参与构建（fork 模式，改动一律是分支上的 commit —— 规范 §6 判据）
//   ② base_commit 必须是 HEAD 的祖先（防 rebase 时把基线弄丢）
//   ③ HEAD 的 tree == lock.source_tree（内容寻址；同 commit 篡改 tree 是不可能的，
//      这条真正防的是「lock 只改了 commit 忘了改 tree」的半更新）
//   ④ vendored tl::expected 的 blob 哈希 == lock（⚠️ 用 git cat-file 取 blob，
//      不读工作区文件 —— Windows autocrlf 会把工作区转成 CRLF）
//   ⑤ glslang External 的 SPIRV-Tools/Headers 若已克隆，HEAD 必须等于 lock 的 pin
//      （未克隆只 warn：build-mobilegl.ps1 会在构建前 fail-fast）
// 以及（非 --offline 时）origin/amcl/ohos 的远端头 == lock.commit ——
// gitlink 指向没推送的 commit 正是 `1000498` 付过学费的形状。
//
// ============================ 它不能证明什么 ============================
//
// ❌ 不证明产物是从这份源码编出来的（那是 check-mobilegl-build-contract 一类产物级门禁的事，
//    Phase 2b 前落地）。❌ 不证明子模块工作区干净 —— 默认要求干净，--allow-dirty 放行
//    （施工期间子模块常有在飞改动；lock 更新时必须干净）。
//
// 用法：
//   node scripts/check-mobilegl-pin.mjs [--offline] [--allow-dirty] [--json]

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
export const LOCK_REL = 'deps.lock';
export const SUBMODULE_REL = 'prebuilt/mobilegl/src';
export const FORBIDDEN_PATCH_DIR_REL = 'prebuilt/mobilegl/patches';

export const REQUIRED_FIELDS = [
  'upstream', 'repo', 'branch', 'commit', 'base_commit', 'source_tree',
  'spirv_tools_commit', 'spirv_headers_commit',
  'tl_expected_tag', 'tl_expected_sha256',
];

/**
 * 从 deps.lock 文本抠出 [mobilegl] 节的 key=value。
 * 纯函数：负向自测直接喂构造文本。
 */
export function parseLockSection(lockText, section = 'mobilegl') {
  const problems = [];
  const fields = {};
  const lines = lockText.split(/\r?\n/);
  let inSection = false;
  for (const raw of lines) {
    const line = raw.trim();
    if (line.startsWith('[') && line.endsWith(']')) {
      inSection = line === `[${section}]`;
      continue;
    }
    if (!inSection || line === '' || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    // 行尾注释：值里不含 '#'（全是 SHA/URL/tag），直接截断即可。
    const value = line.slice(eq + 1).split('#')[0].trim();
    if (key) fields[key] = value;
  }
  if (!inSection && Object.keys(fields).length === 0 && !lockText.includes(`[${section}]`)) {
    problems.push(`deps.lock 里没有 [${section}] 节`);
  }
  for (const f of REQUIRED_FIELDS) {
    if (!fields[f]) problems.push(`[${section}] 缺字段: ${f}`);
  }
  for (const f of ['commit', 'base_commit', 'source_tree', 'spirv_tools_commit', 'spirv_headers_commit']) {
    if (fields[f] && !/^[0-9a-f]{40}$/.test(fields[f])) {
      problems.push(`[${section}].${f} 不是 40 位小写 SHA: '${fields[f]}'`);
    }
  }
  if (fields.tl_expected_sha256 && !/^[0-9a-f]{64}$/.test(fields.tl_expected_sha256)) {
    problems.push(`[${section}].tl_expected_sha256 不是 64 位小写 sha256`);
  }
  return { fields, problems };
}

function runGit(args, cwd) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8' });
  return { ok: r.status === 0, out: (r.stdout || '').trim(), err: (r.stderr || '').trim() };
}

/**
 * 主判定。git 交互集中在这里；`--offline` 跳过远端审计。
 * `lockText` 可注入 —— 自测用一份篡改过的 lock 对着真子模块跑，
 * 逐条验证「lock 漂了会红」（S5.3：门禁要先证明它会红）。
 */
export function analyze({ root = ROOT, offline = false, allowDirty = false, lockText = null } = {}) {
  const problems = [];
  const notes = [];

  const lockPath = path.join(root, LOCK_REL);
  if (lockText === null && !fs.existsSync(lockPath)) {
    return { ok: false, problems: [`${LOCK_REL} 不存在`], notes, fields: {} };
  }
  const { fields, problems: lockProblems } = parseLockSection(lockText ?? fs.readFileSync(lockPath, 'utf8'));
  problems.push(...lockProblems);
  if (lockProblems.length > 0) return { ok: false, problems, notes, fields };

  // ── 三处一致 ──
  const gitlink = runGit(['ls-files', '-s', SUBMODULE_REL], root);
  const gitlinkMatch = gitlink.out.match(/^160000 ([0-9a-f]{40}) /);
  if (!gitlinkMatch) {
    problems.push(`superproject 索引里没有 ${SUBMODULE_REL} 的 gitlink（160000 条目）—— 1000498 的形状`);
  } else if (gitlinkMatch[1] !== fields.commit) {
    problems.push(`gitlink ${gitlinkMatch[1].slice(0, 12)} != lock.commit ${fields.commit.slice(0, 12)}`);
  }

  const sub = path.join(root, ...SUBMODULE_REL.split('/'));
  if (!fs.existsSync(path.join(sub, '.git'))) {
    problems.push(`${SUBMODULE_REL} 不是已初始化的 git 子模块`);
    return { ok: problems.length === 0, problems, notes, fields };
  }
  const head = runGit(['rev-parse', 'HEAD'], sub);
  if (head.out !== fields.commit) {
    problems.push(`子模块 HEAD ${head.out.slice(0, 12)} != lock.commit ${fields.commit.slice(0, 12)}`);
  }

  // ── tree 内容寻址 ──
  const tree = runGit(['show', '-s', '--format=%T', 'HEAD'], sub);
  if (tree.out !== fields.source_tree) {
    problems.push(`HEAD tree ${tree.out.slice(0, 12)} != lock.source_tree ${fields.source_tree.slice(0, 12)}`);
  }

  // ── 基线祖先关系 ──
  const anc = runGit(['merge-base', '--is-ancestor', fields.base_commit, 'HEAD'], sub);
  if (!anc.ok) {
    problems.push(`base_commit ${fields.base_commit.slice(0, 12)} 不是 HEAD 的祖先（rebase 丢基线？）`);
  }

  // ── 工作区洁净 ──
  const dirty = runGit(['status', '--porcelain'], sub);
  if (dirty.out !== '' && !allowDirty) {
    problems.push(`子模块工作区不干净（${dirty.out.split('\n').length} 条；施工期可用 --allow-dirty 放行）`);
  } else if (dirty.out !== '') {
    notes.push(`子模块工作区有 ${dirty.out.split('\n').length} 条未提交改动（--allow-dirty 放行中）`);
  }

  // ── patches/ 禁令 ──
  if (fs.existsSync(path.join(root, ...FORBIDDEN_PATCH_DIR_REL.split('/')))) {
    problems.push(`${FORBIDDEN_PATCH_DIR_REL} 不应存在：fork 模式一律走分支 commit（规范 §6）`);
  }

  // ── vendored tl::expected：blob 哈希（不读工作区，防 autocrlf） ──
  const blob = spawnSync('git', ['cat-file', 'blob', 'HEAD:include/tl/expected.hpp'], { cwd: sub });
  if (blob.status !== 0) {
    problems.push('HEAD:include/tl/expected.hpp 不存在（expected 分流 commit 被 rebase 掉了？）');
  } else {
    const sha = createHash('sha256').update(blob.stdout).digest('hex');
    if (sha !== fields.tl_expected_sha256) {
      problems.push(`tl/expected.hpp blob sha256 ${sha.slice(0, 12)}… != lock ${fields.tl_expected_sha256.slice(0, 12)}…`);
    }
  }

  // ── glslang External pin（存在才校验；缺失由构建脚本 fail-fast） ──
  const externals = [
    ['spirv_tools_commit', '3rdparty/glslang/External/spirv-tools'],
    ['spirv_headers_commit', '3rdparty/glslang/External/spirv-tools/external/spirv-headers'],
  ];
  for (const [key, rel] of externals) {
    const dir = path.join(sub, ...rel.split('/'));
    if (!fs.existsSync(path.join(dir, '.git'))) {
      notes.push(`${rel} 未克隆（build-mobilegl.ps1 会 fail-fast；本门禁不拦）`);
      continue;
    }
    const h = runGit(['rev-parse', 'HEAD'], dir);
    if (h.out !== fields[key]) {
      problems.push(`${rel} HEAD ${h.out.slice(0, 12)} != lock.${key} ${fields[key].slice(0, 12)}`);
    }
  }

  // ── 远端头（防「gitlink 指向没推送的 commit」） ──
  if (!offline) {
    const remote = runGit(['ls-remote', 'origin', `refs/heads/${fields.branch}`], sub);
    if (!remote.ok || remote.out === '') {
      problems.push(`ls-remote origin ${fields.branch} 失败或为空（离线环境用 --offline）`);
    } else {
      const remoteSha = remote.out.split('\t')[0];
      if (remoteSha !== fields.commit) {
        problems.push(`origin/${fields.branch} 远端头 ${remoteSha.slice(0, 12)} != lock.commit ${fields.commit.slice(0, 12)}（改了没推 / 推了没锁）`);
      }
    }
  } else {
    notes.push('offline：跳过远端头审计');
  }

  return { ok: problems.length === 0, problems, notes, fields };
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === url.fileURLToPath(import.meta.url);
if (isMain) {
  const args = process.argv.slice(2);
  const res = analyze({
    offline: args.includes('--offline'),
    allowDirty: args.includes('--allow-dirty'),
  });
  if (args.includes('--json')) {
    console.log(JSON.stringify(res, null, 2));
  } else {
    for (const n of res.notes) console.log(`  note: ${n}`);
    for (const p of res.problems) console.error(`  FAIL: ${p}`);
    console.log(res.ok
      ? `check-mobilegl-pin PASS (commit ${res.fields.commit?.slice(0, 12)}, branch ${res.fields.branch})`
      : `check-mobilegl-pin FAIL (${res.problems.length} 处)`);
  }
  process.exitCode = res.ok ? 0 : 1;
}
