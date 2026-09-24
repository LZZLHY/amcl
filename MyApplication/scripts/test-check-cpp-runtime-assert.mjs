#!/usr/bin/env node
// check-cpp-runtime-assert.mjs 的定向自测。
//
// 首方当前 0 命中 ⇒ 这道门禁是**最容易变成"不可能失败"的那一类**：正则写错、扫描面
// 圈错、vendored 判据写反，任意一条都会让它永远报 0 而没人发现。所以每条性质双向测：
// 既测"该报的报了"（真 assert / assert.h / NDEBUG），也测"不该报的没报"
// （static_assert 与自定义静态断言宏 —— 首方大量使用，误伤即全红）。

import { scanText, isVendored } from './check-cpp-runtime-assert.mjs';

let failures = 0;
function check(label, ok, detail) {
  if (ok) { console.log(`[test-check-cpp-runtime-assert] PASS: ${label}`); return; }
  failures += 1;
  console.error(`[test-check-cpp-runtime-assert] FAIL: ${label}`);
  if (detail !== undefined) console.error(`  ${detail}`);
}

// ---- 该报的 ------------------------------------------------------------------

check('裸 assert( 被报出',
  scanText('    assert(srcChan < srcStep);').some((h) => h.kind === 'runtime-assert'));

check('行首 assert( 被报出（前置字符类不能漏掉行首）',
  scanText('assert(x);').some((h) => h.kind === 'runtime-assert'));

check('assert( 前有空格/制表符仍被报出',
  scanText('\tassert (x);').some((h) => h.kind === 'runtime-assert'));

check('#include <assert.h> 被报出',
  scanText('#include <assert.h>').some((h) => h.kind === 'assert-include'));

check('#include <cassert> 被报出',
  scanText('  #  include <cassert>').some((h) => h.kind === 'assert-include'));

check('NDEBUG 字样被报出',
  scanText('#ifndef NDEBUG').some((h) => h.kind === 'ndebug'));

// ---- 不该报的（承重：首方大量使用，误伤即全红）--------------------------------

check('static_assert( 不报',
  scanText('static_assert(sizeof(T) == 16, "ABI changed");').length === 0,
  JSON.stringify(scanText('static_assert(sizeof(T) == 16, "ABI changed");')));

check('AMCL_INPUT_STATIC_ASSERT( 不报',
  scanText('AMCL_INPUT_STATIC_ASSERT(offsetof(S, f) == 8, "changed");').length === 0);

check('展开静态断言的宏定义本身不报',
  scanText('#define AMCL_INPUT_STATIC_ASSERT(c, m) static_assert((c), m)').length === 0);

check('FMT_ASSERT / alassert 这类带前缀的不报',
  scanText('FMT_ASSERT(x, "m"); alassert(y);').length === 0);

// ⚠️ 这条记录一个**刻意的取舍**：不做注释剥离，所以注释里的 assert( 会被报出来。
// 少报才是致命方向，误报一次人工确认成本极低。改这条行为前先读脚本头注释。
check('注释里的 assert( 会被报出（刻意：宁可误报不可少报）',
  scanText('// 例如 assert(x) 会被 NDEBUG 删掉').some((h) => h.kind === 'runtime-assert'));

// ---- vendored 判据 -----------------------------------------------------------

check('openal-soft 目录判为 vendored',
  isVendored('entry/src/main/cpp/openal/openal-soft/core/voice.cpp') === true);
check('third_party 目录判为 vendored',
  isVendored('entry/src/main/cpp/third_party/curl/include/curl/curl.h') === true);
check('OpenJDK 头单文件判为 vendored',
  isVendored('entry/src/main/cpp/jvm/jni.h') === true);

// 承重反向用例：首方 openal/ohaudio.cpp 与 openal-soft/ 只差一层，判据不能把它一起吃掉。
check('首方 openal/ohaudio.cpp 不算 vendored',
  isVendored('entry/src/main/cpp/openal/ohaudio.cpp') === false);
check('首方 jvm/*.cpp 不算 vendored',
  isVendored('entry/src/main/cpp/jvm/jvm_launcher.cpp') === false);
// 前缀相近的目录不得被误判（openal-soft-extra 这种）。
check('前缀相近但不同的目录不算 vendored',
  isVendored('entry/src/main/cpp/openal/openal-softx/a.cpp') === false);

if (failures > 0) {
  console.error(`[test-check-cpp-runtime-assert] ${failures} case(s) failed`);
  process.exitCode = 1;
} else {
  console.log('[test-check-cpp-runtime-assert] ALL PASS');
}
