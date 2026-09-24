#!/usr/bin/env node
// scripts/check-mobilegl-snapshot.mjs — MobileGL 源文件清单快照
//
// 与 check-mg-snapshot 同一个目的（方案 §4.7）：**上游增删 TU 必须是一个被看见的事件**，
// 而不是默认行为 —— 升级 submodule 时清单变了，本门禁红，人来决定接受与否（--update）。
//
// 三个域分开快照（漂移的含义不同）：
//   cmake-sources        CMakeLists.txt 引用的源文件（真正会进产物的清单）
//   disk-product-sources 磁盘上的产品源码census（MG_Test/MG_Benchmark/MG_IntegrationTest 除外）
//   disk-test-sources    上面三个测试目录的census（上游加测试也值得知道，但不和产品混）
// cmake 与 disk-product 的差集**不必为空**（平台条件文件在别的平台不编），
// 快照锁的是"变化"本身，不是两个域的相等。
//
// 用法：
//   node scripts/check-mobilegl-snapshot.mjs            # check
//   node scripts/check-mobilegl-snapshot.mjs --update   # 人工 review 后更新快照

import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(SCRIPT_DIR, '..');
export const SRC_ROOT = join(PROJECT_ROOT, 'prebuilt', 'mobilegl', 'src');
export const SNAPSHOT_PATH = join(PROJECT_ROOT, 'prebuilt', 'mobilegl', 'cmake-snapshot.txt');
const TEST_DIRS = ['MG_Test', 'MG_Benchmark', 'MG_IntegrationTest'];

/** CMake 文本 → 引用的 MobileGL/ 源文件集合。纯函数（自测喂构造文本）。 */
export function listFromCMake(cmakeText) {
  const noComments = cmakeText.split(/\r?\n/).map(l => l.replace(/#.*$/, '')).join('\n');
  const hits = noComments.match(/MobileGL\/[A-Za-z0-9_./]+\.(?:cpp|c|def)/g) || [];
  return [...new Set(hits)].sort();
}

function walk(dir, out) {
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, ent.name);
    if (ent.isDirectory()) walk(p, out);
    else if (ent.isFile() && /\.(cpp|c)$/.test(ent.name)) out.push(p);
  }
}

export function listFromDisk(srcRoot = SRC_ROOT) {
  const mobileglDir = join(srcRoot, 'MobileGL');
  if (!existsSync(mobileglDir)) return { product: null, test: null };
  const all = [];
  walk(mobileglDir, all);
  const rel = all.map(p => 'MobileGL/' + relative(mobileglDir, p).split(sep).join('/')).sort();
  const isTest = (r) => TEST_DIRS.some(d => r.startsWith(`MobileGL/${d}/`));
  return {
    product: rel.filter(r => !isTest(r)),
    test: rel.filter(isTest),
  };
}

export function renderSnapshot({ cmake, product, test }) {
  const section = (name, arr) => [`# ${name} (${arr.length})`, ...arr];
  return [
    '# MobileGL source manifest snapshot — check-mobilegl-snapshot.mjs',
    '# 变更流程：升级 submodule → 本门禁红 → 人工 review 差异 → --update',
    ...section('cmake-sources', cmake),
    ...section('disk-product-sources', product),
    ...section('disk-test-sources', test),
    '',
  ].join('\n');
}

export function analyze({ srcRoot = SRC_ROOT, snapshotPath = SNAPSHOT_PATH } = {}) {
  const problems = [];
  const cmakePath = join(srcRoot, 'CMakeLists.txt');
  if (!existsSync(cmakePath)) return { ok: false, problems: [`缺 ${cmakePath}`], current: null };
  const cmake = listFromCMake(readFileSync(cmakePath, 'utf8'));
  const { product, test } = listFromDisk(srcRoot);
  if (product === null) return { ok: false, problems: ['缺 MobileGL/ 源码目录'], current: null };
  const current = renderSnapshot({ cmake, product, test });

  if (!existsSync(snapshotPath)) {
    problems.push(`快照不存在：${relative(PROJECT_ROOT, snapshotPath)}（首次用 --update 生成）`);
    return { ok: false, problems, current };
  }
  const committed = readFileSync(snapshotPath, 'utf8').replace(/\r\n/g, '\n');
  if (committed !== current) {
    const a = new Set(committed.split('\n'));
    const b = new Set(current.split('\n'));
    const added = [...b].filter(x => !a.has(x) && !x.startsWith('#'));
    const removed = [...a].filter(x => !b.has(x) && !x.startsWith('#'));
    problems.push(`清单漂移：+${added.length} / -${removed.length}`);
    for (const x of added.slice(0, 10)) problems.push(`  + ${x}`);
    for (const x of removed.slice(0, 10)) problems.push(`  - ${x}`);
  }
  return { ok: problems.length === 0, problems, current, counts: { cmake: cmake.length, product: product.length, test: test.length } };
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const res = analyze({});
  if (process.argv.includes('--update')) {
    if (res.current === null) {
      console.error('无法生成快照（源码树缺失）');
      process.exitCode = 1;
    } else {
      writeFileSync(SNAPSHOT_PATH, res.current, 'utf8');
      console.log(`快照已更新: ${SNAPSHOT_PATH}`);
    }
  } else {
    for (const p of res.problems) console.error(`  FAIL: ${p}`);
    console.log(res.ok
      ? `check-mobilegl-snapshot PASS (cmake ${res.counts.cmake} / product ${res.counts.product} / test ${res.counts.test})`
      : 'check-mobilegl-snapshot FAIL');
    process.exitCode = res.ok ? 0 : 1;
  }
}
