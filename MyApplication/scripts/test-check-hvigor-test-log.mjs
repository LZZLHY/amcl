#!/usr/bin/env node
// test-check-hvigor-test-log.mjs — check-hvigor-test-log.mjs 的自测
//
// 这份自测的重点不是"能不能抓到失败"，而是**三条会导致静默永绿的前提**：
//   1. ANSI 必须被剥掉（hvigor 上色）；
//   2. UTF-16LE 必须被解码（PowerShell 5.1 的 `*>` 就是这个编码）；
//   3. 读到不认识的内容必须 fail-closed，不能报告通过。
// 三条都被真实构建否证过一次，fixture 用的是实测原样字节。

import {
  assertLooksLikeHvigorLog, decodeLogBuffer, findHvigorErrorLines, stripAnsi,
} from './check-hvigor-test-log.mjs';

let failures = 0;
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (ok) {
    console.log(`[test-check-hvigor-test-log] PASS: ${name}`);
  } else {
    failures++;
    console.error(`[test-check-hvigor-test-log] FAIL: ${name}`);
    console.error(`  expected: ${JSON.stringify(expected)}`);
    console.error(`  actual:   ${JSON.stringify(actual)}`);
  }
}

const ESC = '\u001b';

// 2026-08-21 实测原样（`> hvigor <ESC>[91mERROR: Error in <用例名>, expect 1 equals 1234`）
const REAL_FAILURE_LINE =
  `> hvigor ${ESC}[91mERROR: Error in 枚举值数值稳定：Unknown=0 Gamepad=1 NotGamepad=2, expect 1 equals 1234`;
const REAL_STACK_LINE =
  `> hvigor ${ESC}[91mERROR:     at asyncRunSpecs (oh_modules/.ohpm/@ohos+hypium@1.0.24/...)`;
const REAL_GREEN_LOG = [
  '> hvigor Finished :entry:default@UnitTestArkTS... after 9 s 513 ms',
  '> hvigor BUILD SUCCESSFUL in 26 s 644 ms',
].join('\n');

// ---- 前提 1：ANSI ----
check('ANSI CSI 被剥掉', stripAnsi(`a${ESC}[91mb${ESC}[0mc`), 'abc');
check('带颜色的断言失败行被抓到', findHvigorErrorLines(REAL_FAILURE_LINE).length, 1);
check('未上色的 ERROR 行同样被抓到', 
  findHvigorErrorLines('> hvigor ERROR: Error in foo, expect 1 equals 2').length, 1);

// ---- 前提 2：编码 ----
check('UTF-16LE + BOM 被正确解码（PowerShell 5.1 `*>` 的实际编码）',
  decodeLogBuffer(Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(REAL_FAILURE_LINE, 'utf16le')])).encoding,
  'utf16le-bom');
check('UTF-16LE 日志里的失败行能被抓到（这一条曾经漏过一次真实失败）',
  findHvigorErrorLines(
    decodeLogBuffer(Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(REAL_FAILURE_LINE, 'utf16le')])).text
  ).length, 1);
check('无 BOM 的 UTF-16LE 也要被嗅出来',
  decodeLogBuffer(Buffer.from(REAL_FAILURE_LINE, 'utf16le')).encoding, 'utf16le-sniffed');
check('UTF-16BE + BOM 解码后同样能抓到',
  (() => {
    const body = Buffer.from(REAL_FAILURE_LINE, 'utf16le');
    body.swap16();
    return findHvigorErrorLines(
      decodeLogBuffer(Buffer.concat([Buffer.from([0xfe, 0xff]), body])).text).length;
  })(), 1);
check('UTF-8 + BOM 解码正常', 
  decodeLogBuffer(Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(REAL_GREEN_LOG, 'utf8')])).encoding,
  'utf8-bom');
check('纯 UTF-8 无 BOM 走默认路径',
  decodeLogBuffer(Buffer.from(REAL_GREEN_LOG, 'utf8')).encoding, 'utf8');

// ---- 前提 3：正向证据门 ----
check('全绿 hvigor 日志通过正向证据门', assertLooksLikeHvigorLog(REAL_GREEN_LOG), null);
check('空日志 fail-closed', 
  assertLooksLikeHvigorLog('   \n  ') !== null, true);
check('不含任何 hvigor 行的内容 fail-closed（覆盖编码错/文件错/被截断）',
  assertLooksLikeHvigorLog('some unrelated text\nanother line') !== null, true);
check('乱码（把 UTF-16 当 utf8 读）fail-closed —— 这正是漏过真实失败的那一次',
  assertLooksLikeHvigorLog(Buffer.from(REAL_FAILURE_LINE, 'utf16le').toString('utf8')) !== null, true);

// ---- 取宽 / 取窄边界 ----
check('栈帧行也算失败信号（刻意取宽以 fail-closed）',
  findHvigorErrorLines(REAL_STACK_LINE).length, 1);
check('BUILD SUCCESSFUL 不是通过的依据 —— 同一份输出里两者共存时仍算失败',
  findHvigorErrorLines([REAL_FAILURE_LINE, '> hvigor BUILD SUCCESSFUL in 11 s'].join('\n')).length, 1);
check('全绿输出零命中', findHvigorErrorLines(REAL_GREEN_LOG).length, 0);
check('WARN 不是失败',
  findHvigorErrorLines(`WARN: ArkTS:WARN File: X.ets:1:1\n> hvigor Finished`).length, 0);
check('CRLF 输出按行切分正确',
  findHvigorErrorLines(`ok\r\n${REAL_FAILURE_LINE}\r\nok`).length, 1);
check('多条失败全部报出，不是只报第一条',
  findHvigorErrorLines([REAL_FAILURE_LINE, REAL_STACK_LINE].join('\n')).length, 2);

if (failures > 0) {
  console.error(`[test-check-hvigor-test-log] ${failures} FAILURE(S)`);
  process.exit(1);
}
console.log('[test-check-hvigor-test-log] ALL PASS');
