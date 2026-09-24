#!/usr/bin/env node
// check-hvigor-test-log.mjs — 判定一次 `hvigorw test` 的输出里有没有失败
//
// 为什么需要它（2026-08-21 实测，计划 §64.5）：
// `hvigorw test` 在 ArkTS 断言失败时打出
//     > hvigor <ESC>[91mERROR: Error in <用例名>, expect 2 equals 99
// 然后**仍然报 BUILD SUCCESSFUL 且退出码 0**。所以出货脚本里"只检查 $LASTEXITCODE"
// 这一步在此之前是 fail-open 的：它能证明"套件跑起来了"，证明不了"断言全过"。
// 一个永远为绿的门禁比没有门禁更糟（规范 §八 第五条）。
//
// ⚠️ 本脚本的三条设计都是被实测逼出来的，**三次都是"静默永绿"这同一个失败形状**：
//
//   1. **先剥 ANSI**。hvigor 即使输出被重定向仍然上色，`hvigor ` 与 `ERROR:` 之间夹着
//      `<ESC>[91m`。直接匹配字面量 `hvigor ERROR:` 一条都命中不到。
//   2. **按 BOM 解码，不能假定 UTF-8**。Windows PowerShell 5.1 的 `*>` 重定向写出的是
//      **UTF-16LE**。用 `utf8` 读会得到夹着 NUL 的乱码，正则同样一条都命中不到。
//   3. **要求正向证据**（`assertLooksLikeHvigorLog`）。前两条错误的共同点是"检查器读到了
//      一堆它不认识的东西，然后报告一切正常"。所以非空日志里必须至少出现一行 `hvigor`，
//      否则一律 fail-closed —— 这一条同时覆盖编码错、文件路径错、日志被截断三种情况。
//      **不要删掉它来让某个新场景通过。**
//
// 另一条刻意的设计：**匹配整个 `hvigor ERROR:` 级别，而不是更窄的 `Error in`**。测试步骤里
// 出现的任何 hvigor 级错误都应当让构建停下（Hypium 异常栈帧、套件加载失败等）。取宽 =
// fail-closed。若将来出现无害的 ERROR 行，正确处置是**具名放行那一条**，不是把检查删掉。
//
// 本脚本**不**判断：跑了几个用例、覆盖率、以及"套件是否整体没跑"。最后一条由
// check-arkts-test-suite.mjs 的结构检查负责，两者互补、都不能替代对方。

import { readFileSync } from 'node:fs';

/** ANSI CSI 序列。hvigor 用 `<ESC>[91m` 上色，不剥掉会让下面的匹配永远为空。 */
const ANSI_CSI = /\u001b\[[0-9;]*[A-Za-z]/g;

/** hvigor 的错误级别行。前缀 `> hvigor ` 与冒号之间可能有任意空白。 */
const HVIGOR_ERROR = /hvigor\s+ERROR:/;

/** 任意一行 hvigor 输出。用来证明"我们确实读到了一份 hvigor 日志"。 */
const HVIGOR_ANY = /hvigor/i;

export function stripAnsi(line) {
  return String(line).replace(ANSI_CSI, '');
}

/**
 * 按 BOM 解码。PowerShell 5.1 的 `*>` 写 UTF-16LE，Node 默认 utf8 会读成乱码。
 * @param {Buffer} buffer
 * @returns {{ text: string, encoding: string }}
 */
export function decodeLogBuffer(buffer) {
  if (buffer.length >= 2 && buffer[0] === 0xff && buffer[1] === 0xfe) {
    return { text: buffer.slice(2).toString('utf16le'), encoding: 'utf16le-bom' };
  }
  if (buffer.length >= 2 && buffer[0] === 0xfe && buffer[1] === 0xff) {
    // UTF-16BE：Node 没有 utf16be 解码器，先做字节对交换再按 LE 读。
    const swapped = Buffer.from(buffer.slice(2));
    swapped.swap16();
    return { text: swapped.toString('utf16le'), encoding: 'utf16be-bom' };
  }
  if (buffer.length >= 3 && buffer[0] === 0xef && buffer[1] === 0xbb && buffer[2] === 0xbf) {
    return { text: buffer.slice(3).toString('utf8'), encoding: 'utf8-bom' };
  }
  // 无 BOM 的 UTF-16LE（ASCII 内容表现为每个字符后跟一个 NUL）也要认出来，
  // 否则"读到乱码却报告一切正常"这个形状会从 BOM 缺失的缝里回来。
  const probe = buffer.slice(0, Math.min(buffer.length, 512));
  let nulCount = 0;
  for (const byte of probe) if (byte === 0x00) nulCount++;
  if (probe.length >= 4 && nulCount * 4 >= probe.length) {
    return { text: buffer.toString('utf16le'), encoding: 'utf16le-sniffed' };
  }
  return { text: buffer.toString('utf8'), encoding: 'utf8' };
}

/**
 * 正向证据门：一份非空日志里必须至少有一行 hvigor 输出。
 * 读到别的东西时**不得**报告通过 —— 那正是本脚本被否证过两次的形状。
 * @returns {string | null} null = 看起来是 hvigor 日志；否则返回拒绝理由
 */
export function assertLooksLikeHvigorLog(text) {
  const trimmed = String(text).trim();
  if (trimmed.length === 0) return 'log is empty (hvigor produced no output?)';
  const hasHvigorLine = trimmed.split(/\r?\n/).some((line) => HVIGOR_ANY.test(stripAnsi(line)));
  if (!hasHvigorLine) return 'log contains no `hvigor` line (wrong file, wrong encoding, or truncated)';
  return null;
}

/**
 * 找出输出里所有 hvigor 错误行（已剥 ANSI）。
 * @param {string} text 一次 `hvigorw test` 的完整 stdout+stderr
 * @returns {string[]} 命中的行，原顺序
 */
export function findHvigorErrorLines(text) {
  return String(text)
    .split(/\r?\n/)
    .map(stripAnsi)
    .filter((line) => HVIGOR_ERROR.test(line));
}

function main(argv) {
  const path = argv[0];
  if (!path) {
    console.error('usage: node scripts/check-hvigor-test-log.mjs <hvigor-test-output.log>');
    return 2;
  }
  let buffer;
  try {
    buffer = readFileSync(path);
  } catch (e) {
    // 读不到日志不能当成通过：那正是"门禁静默失效"的形状。
    console.error(`[check-hvigor-test-log] FAIL  cannot read ${path}: ${e.message}`);
    return 2;
  }
  const { text, encoding } = decodeLogBuffer(buffer);
  const rejection = assertLooksLikeHvigorLog(text);
  if (rejection) {
    console.error(`[check-hvigor-test-log] FAIL  ${rejection}`);
    console.error(`  path=${path} bytes=${buffer.length} decodedAs=${encoding}`);
    console.error('  ⚠️ 这道检查存在的理由就是不让"读不懂日志"表现为通过。不要放宽它。');
    return 2;
  }
  const hits = findHvigorErrorLines(text);
  if (hits.length === 0) {
    console.log(`[check-hvigor-test-log] PASS  no hvigor ERROR lines (decodedAs=${encoding})`);
    return 0;
  }
  console.error(`[check-hvigor-test-log] FAIL  ${hits.length} hvigor ERROR line(s):`);
  for (const line of hits) console.error(`  ${line.trim()}`);
  console.error('');
  console.error('  ⚠️ hvigor 在断言失败时仍会报 BUILD SUCCESSFUL / exit 0，所以这些行是');
  console.error('     唯一的失败信号。不要通过放宽本检查来"修"它。');
  return 1;
}

const invokedDirectly = process.argv[1] && import.meta.url.endsWith(
  process.argv[1].replace(/\\/g, '/').split('/').pop());
if (invokedDirectly) {
  process.exit(main(process.argv.slice(2)));
}
