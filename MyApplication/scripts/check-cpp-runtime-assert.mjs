#!/usr/bin/env node
// scripts/check-cpp-runtime-assert.mjs
//
// ============================ 它挡的是什么 ============================
//
// 首方 C++ 里出现**运行期** `assert(`。release 编译带 `-DNDEBUG`，`assert()` 整条被预处理
// 器删掉 —— 把有副作用的表达式写在里面（`assert(init() == 0)`），那个副作用在出货包里
// 就不存在，而 debug 一切正常。这是本项目已经付过两次学费的那个形状：**只在 release
// 产物里存在的失败面**。
//
// NDEBUG **不来自本仓**：`entry/src/main/cpp/CMakeLists.txt` 里没有任何 `CMAKE_BUILD_TYPE`
// 分支、没有 `-DNDEBUG`、没有 `-O` 等级（`CMAKE_BUILD_TYPE` 全文只出现一次，用来拼诊断
// 字符串）。它由 SDK 的 ohos.toolchain.cmake 在 release 档注入（release `-O2 -DNDEBUG`，
// debug `-O0 -g`）。⇒ 改本仓 CMakeLists 察觉不到这个差异，只能靠门禁。
//
// 首方目前 **0 命中**（含 `#include <assert.h>` / `<cassert>` / 任何 NDEBUG 字样），
// 所以这道门禁上线即绿、无需基线文件 —— 它是趁干净钉住，不是清债。
//
// ============================ 为什么只扫首方 ============================
//
// vendored 的 openal-soft 有 126 处运行期 assert（实际编译进产物 87 处）。它是
// `.gitignore` 里的可重克隆物（`setup_deps.sh` / `git clone kcat/openal-soft`），
// 逐条豁免清单每次上游更新就失配。目录级黑名单与"只扫首方"等价、维护成本为零。
// ⚠️ 这意味着门禁**不为第三方库的 assert 背书**；那是上游的工程判断，不是我们的。
//
// ============================ 它不能证明什么 ============================
//
// ❌ 不检查其它被 NDEBUG 影响的构造（自写的 `#ifndef NDEBUG` 块 —— 首方现在 0 处，
//    真要加的话这道门禁会因为 NDEBUG 字样命中而报出来，那是刻意的）。
// ❌ 不检查 `-O2` 相关的 UB 敏感代码（那需要 sanitizer，不是文本判据）。
// ❌ vendored 头文件混在首方目录里的三个 OpenJDK 头（jni.h / jni_md.h / jvmti.h）走
//    单文件豁免；若上游再塞进来新的头，这里会误报 —— 那时应当把它移出首方目录，
//    而不是往豁免表里加。

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const CPP_REL = 'entry/src/main/cpp';

// vendored：目录级黑名单。判据（子代理 2026-08-22 逐条核对）：
//   openal-soft/ 内有自己的 .git、COPYING、上游 README，且被 .gitignore:48 忽略；
//   third_party/curl/ 只有 12 个 curl 公开头，libcurl.so 以 IMPORTED 引入。
const VENDORED_DIRS = [
  'entry/src/main/cpp/openal/openal-soft',
  'entry/src/main/cpp/third_party',
];
// vendored 单文件（OpenJDK 头，混在首方 jvm/ 目录里；jni.h 头部有 Oracle GPLv2+CE 版权声明）
const VENDORED_FILES = new Set([
  'entry/src/main/cpp/jvm/jni.h',
  'entry/src/main/cpp/jvm/jni_md.h',
  'entry/src/main/cpp/jvm/jvmti.h',
]);

const CODE_EXT = new Set(['.c', '.cc', '.cpp', '.h', '.hpp']);

// 前置字符类天然排除 `static_assert(` / `AMCL_INPUT_STATIC_ASSERT(` / `FMT_ASSERT(`：
// 它们的 `assert` 前一个字符是 `_` 或字母。不需要额外的 negative lookbehind。
const RUNTIME_ASSERT_RE = /(^|[^_A-Za-z0-9])assert[ \t]*\(/;
const ASSERT_INCLUDE_RE = /^\s*#\s*include\s*[<"](?:assert\.h|cassert)[>"]/;
const NDEBUG_RE = /\bNDEBUG\b/;

export function isVendored(rel) {
  if (VENDORED_FILES.has(rel)) return true;
  return VENDORED_DIRS.some((d) => rel === d || rel.startsWith(`${d}/`));
}

/**
 * 逐行扫一份源码。刻意**不**做完整的注释/字符串剥离：首方当前 0 命中，宁可让
 * 「注释里写了 assert(」也报出来（人工确认一次成本极低），也不要为了消掉噪声引入
 * 一个可能把真命中一起吃掉的 masker。少报才是这道门禁唯一致命的失效方向。
 */
export function scanText(text) {
  const hits = [];
  text.split(/\r?\n/).forEach((line, i) => {
    if (RUNTIME_ASSERT_RE.test(line)) hits.push({ line: i + 1, kind: 'runtime-assert', text: line.trim() });
    if (ASSERT_INCLUDE_RE.test(line)) hits.push({ line: i + 1, kind: 'assert-include', text: line.trim() });
    if (NDEBUG_RE.test(line)) hits.push({ line: i + 1, kind: 'ndebug', text: line.trim() });
  });
  return hits;
}

function walk(dir, out = []) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    const rel = path.relative(ROOT, full).replace(/\\/g, '/');
    if (entry.isDirectory()) {
      if (isVendored(rel)) continue;
      walk(full, out);
    } else if (entry.isFile() && CODE_EXT.has(path.extname(entry.name)) && !isVendored(rel)) {
      out.push({ full, rel });
    }
  }
  return out;
}

function main() {
  const jsonOutput = process.argv.includes('--json');
  const files = walk(path.join(ROOT, CPP_REL));
  const hits = [];
  for (const f of files) {
    for (const h of scanText(fs.readFileSync(f.full, 'utf8'))) hits.push({ file: f.rel, ...h });
  }
  const ok = hits.length === 0;
  const result = {
    ok,
    scannedFiles: files.length,
    vendoredSkipped: [...VENDORED_DIRS, ...VENDORED_FILES],
    hits,
  };

  if (jsonOutput) {
    process.stdout.write(`${JSON.stringify(result)}\n`);
    process.exit(ok ? 0 : 1);
  }
  if (ok) {
    console.log(`cpp runtime assert OK: ${files.length} 个首方 TU，0 处运行期 assert / assert.h / NDEBUG`);
  } else {
    console.error(`cpp runtime assert FAIL: ${hits.length} 处`);
    for (const h of hits) console.error(`  ${h.file}:${h.line} [${h.kind}] ${h.text}`);
    console.error('  release 带 -DNDEBUG（SDK toolchain 注入），assert() 整条被删；');
    console.error('  写在里面的副作用在出货包里不存在，而 debug 一切正常。改用显式 if + 日志。');
  }
  process.exit(ok ? 0 : 1);
}

if (import.meta.url === url.pathToFileURL(process.argv[1] ?? '').href) {
  main();
}
