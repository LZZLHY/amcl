#!/usr/bin/env node
// scripts/check-release-no-test-symbols.mjs
//
// ============================ 它挡的是什么 ============================
//
// 测试代码回到 release 出货产物里。
//
// 2026-08-22 产物级实测发现：release HAP 里**真的**带着测试代码 —— libentry.so 的 .rodata
// 里 14 个 run*Test 属性名 14/14 在场，libs/arm64-v8a/libfakejvm.so 也在场（5360B），
// 而后者只在 MC_OHOS_BUILD_TESTS 打开时才编译。成因不是有人写错，是
// `option(MC_OHOS_BUILD_TESTS ... ON)` 的默认值 + hvigor 生成的 cmake 配置命令里
// **根本没有这个宏**（既没传 OFF 也没传 ON）。入口是设置页「开发者工具」连点 6 次的彩蛋，
// 没有构建期开关、没有系统开发者模式校验 ⇒ 普通用户可触达。
//
// 现已在 entry/build-profile.json5 的 buildOptionSet[release] 显式传 -DMC_OHOS_BUILD_TESTS=OFF。
// 这道门禁负责"这个决定在产物上真的成立"。
//
// ⚠️ 为什么必须查产物而不是只查配置：cmake 配置命令带 `--no-warn-unused-cli`，
// **拼错的 -D 不会有任何告警**，静默退化成"没传"。只查 build-profile.json5 是查输入，
// 查 CMakeCache 是查 configure 结果，两者都可能与最终 HAP 脱钩（脏 .cxx 残留）。
//
// ============================ 它不能证明什么 ============================
//
// ❌ 不证明"测试代码在 debug 里仍然可用"（那是另一个方向，没有产物级判据能同时覆盖）。
// ❌ 不扫其它 .so：libfakejvm 与那 14 个名字是 MC_OHOS_BUILD_TESTS 的**充分**指纹，
//    不是全部。若将来有人把测试代码搬进别的 target，这里看不见。
// ❌ 没有 HAP 时默认放行（CI 无产物是正常的）；出货路径必须带 --require-artifact，
//    否则"查不到产物 ⇒ 判据空真"会让这半检查恰好在最需要它的地方沉默。

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import url from 'node:url';
import zlib from 'node:zlib';
import { execFileSync } from 'node:child_process';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');

// napi_tests.cpp 的 kTestsDescriptors 全部属性名。它们出现在 libentry.so 的 .rodata 里
// 就等于 registerTestsNapi 被编进去了。
const TESTS_CPP_REL = 'entry/src/main/cpp/napi/napi_tests.cpp';

/**
 * 从 napi_tests.cpp 的 kTestsDescriptors 现场解析属性名。
 *
 * ⚠️ **刻意不写死清单**：写死的副本在"有人加第 15 个测试"时会静默漏检，而自测若只断言
 * `length === 14` 就是在给一份手抄副本背书 —— 那正是"不可能失败的门禁"的形状。
 * 同仓 check-napi-obfuscation.mjs 已经用同样的"从 cpp 正则抽取"做法，这里复用它的口径。
 */
export function parseTestNapiNames(text) {
  const names = [];
  const re = /NAPI_FUNC\s*\(\s*"([^"]+)"/g;
  for (let m; (m = re.exec(text));) names.push(m[1]);
  return names;
}

function loadTestNapiNames() {
  const full = path.join(ROOT, TESTS_CPP_REL);
  const names = parseTestNapiNames(fs.readFileSync(full, 'utf8'));
  if (names.length === 0) {
    // 解析不出来不能当"没有测试符号"——那是空真。
    throw new Error(`${TESTS_CPP_REL} 里没解析出任何 NAPI_FUNC 名字；正则或文件结构变了`);
  }
  return names;
}

const TEST_ONLY_LIBS = ['libfakejvm.so'];

const LLVM_STRINGS_CANDIDATES = [
  process.env.OHOS_LLVM_STRINGS,
  'D:/Huawei/command-line-tools/sdk/default/openharmony/native/llvm/bin/llvm-strings.exe',
  'D:/Huawei/command-line-tools/sdk/default/hms/native/BiSheng/bin/llvm-strings.exe',
].filter(Boolean);

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

/** zip 中央目录里的条目名。不解压、不引第三方依赖。 */
export function readZipEntryNames(buf) {
  const names = [];
  // End of central directory: 签名 0x06054b50，从尾部倒着找（注释最长 64KB）
  let eocd = -1;
  for (let i = buf.length - 22; i >= 0 && i >= buf.length - 22 - 65535; i -= 1) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) return names;
  let offset = buf.readUInt32LE(eocd + 16);
  const count = buf.readUInt16LE(eocd + 10);
  for (let n = 0; n < count; n += 1) {
    if (offset + 46 > buf.length || buf.readUInt32LE(offset) !== 0x02014b50) break;
    const nameLen = buf.readUInt16LE(offset + 28);
    const extraLen = buf.readUInt16LE(offset + 30);
    const commentLen = buf.readUInt16LE(offset + 32);
    names.push(buf.toString('utf8', offset + 46, offset + 46 + nameLen));
    offset += 46 + nameLen + extraLen + commentLen;
  }
  return names;
}

/**
 * 子串匹配，**刻意不做整词**。
 *
 * 这道门禁唯一致命的方向是**少报**（漏掉一个 = 测试代码溜进出货包而检查说没事）。
 * 第一版用整词正则防 `runJitTestsExtra` 这类超串误命中，但实测 122 个 NAPI 名里
 * **没有任何一个是这 14 个的超串**，也就是说那个风险不存在，而整词判据引入了真实的
 * fail-open 面：字符串尾部与相邻数据合并、或前面紧接词字符时就会漏判。
 * ⇒ 宁可多报（多报只需人工看一眼），不可少报。
 */
export function findTestNames(stringsOutput, names) {
  return names.filter((n) => stringsOutput.includes(n));
}

export function evaluate({ hapPresent, requireArtifact, testLibs, mangledNames }) {
  if (!hapPresent) return { ok: !requireArtifact, reason: requireArtifact ? 'artifact-missing' : 'no-artifact' };
  if (testLibs.length > 0) return { ok: false, reason: 'test-lib-present' };
  if (mangledNames.length > 0) return { ok: false, reason: 'test-napi-present' };
  return { ok: true, reason: 'clean' };
}

function locateStrings() {
  for (const c of LLVM_STRINGS_CANDIDATES) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

function main() {
  const jsonOutput = process.argv.includes('--json');
  const requireArtifact = process.argv.includes('--require-artifact');
  const testNames = loadTestNapiNames();
  // 必须按 product/target 拼路径：build-hap.ps1 支持 -Product store|sideload|desktop，
  // 写死 default 会让另外三条轨空真通过。
  const product = arg('product', 'default');
  const target = arg('target', 'default');
  const hapKind = arg('hap-kind', 'signed');
  const hapRel = `entry/build/${product}/outputs/${target}/entry-${target}-${hapKind}.hap`;
  const hapAbs = path.join(ROOT, hapRel);

  const hapPresent = fs.existsSync(hapAbs);
  let testLibs = [];
  let foundNames = [];
  let toolError = null;

  if (hapPresent) {
    const buf = fs.readFileSync(hapAbs);
    const entries = readZipEntryNames(buf);
    testLibs = entries.filter((e) => TEST_ONLY_LIBS.some((l) => e.endsWith(`/${l}`) || e === l));

    const strings = locateStrings();
    if (!strings) {
      // fail-closed：定位不到工具不能当"通过"。
      toolError = `找不到 llvm-strings（试过 ${LLVM_STRINGS_CANDIDATES.join(', ')}）；可设 OHOS_LLVM_STRINGS`;
    } else {
      const soEntry = entries.find((e) => e.endsWith('/libentry.so'));
      if (!soEntry) {
        toolError = `HAP 里找不到 libentry.so（${hapRel}）`;
      } else {
        // 用 os.tmpdir() 而不是 `process.env.TEMP || '.'`：回退到 '.' 会把临时 .so 落进仓库根，
        // Ctrl-C 打断就留下未跟踪文件，绊倒 build-hap.ps1 -Release 的 dirty fail-closed。
        const tmp = path.join(os.tmpdir(), `amcl-libentry-${process.pid}.so`);
        try {
          extractEntry(buf, soEntry, tmp);
          const out = execFileSync(strings, [tmp], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
          foundNames = findTestNames(out, testNames);
        } catch (e) {
          toolError = `llvm-strings 失败：${e.message}`;
        } finally {
          try { fs.unlinkSync(tmp); } catch { /* 临时文件清理失败不影响判定 */ }
        }
      }
    }
  }

  const verdict = toolError
    ? { ok: false, reason: 'tool-error' }
    : evaluate({ hapPresent, requireArtifact, testLibs, mangledNames: foundNames });

  const result = {
    ok: verdict.ok,
    reason: verdict.reason,
    hap: hapRel,
    hapPresent,
    testLibsFound: testLibs,
    testNapiNamesFound: foundNames,
    toolError,
  };

  if (jsonOutput) {
    process.stdout.write(`${JSON.stringify(result)}\n`);
    process.exit(verdict.ok ? 0 : 1);
  }
  if (verdict.ok) {
    console.log(hapPresent
      ? `release no-test-symbols OK: ${hapRel} 无 ${TEST_ONLY_LIBS.join('/')}，`
        + `libentry.so 无 ${testNames.length} 个测试属性名（从 ${TESTS_CPP_REL} 现场解析）`
      : `release no-test-symbols OK: 未构建（${hapRel} 不存在），出货路径请带 --require-artifact`);
  } else {
    console.error('release no-test-symbols FAIL');
    if (toolError) console.error(`  ${toolError}`);
    if (verdict.reason === 'artifact-missing') {
      console.error(`  --require-artifact 但找不到 ${hapRel}`);
      console.error('  出货路径上"查不到产物"必须当失败 —— 否则这半判据在最需要它的地方沉默。');
    }
    if (testLibs.length) console.error(`  HAP 里有仅测试构建才产出的库：${testLibs.join(', ')}`);
    if (foundNames.length) {
      console.error(`  libentry.so 的字符串里有 ${foundNames.length} 个测试 NAPI 属性名：${foundNames.join(', ')}`);
    }
    if (!toolError) {
      console.error('  应传 -DMC_OHOS_BUILD_TESTS=OFF（entry/build-profile.json5 的 buildOptionSet[release]）。');
      console.error('  ⚠️ cmake 带 --no-warn-unused-cli，拼错的 -D 不会告警 —— 同时查 metadata_generation_command.txt 与 CMakeCache.txt。');
    }
  }
  process.exit(verdict.ok ? 0 : 1);
}

/** 从 zip buffer 里解出单个 stored/deflate 条目。HAP 里的 .so 实测是 stored。 */
function extractEntry(buf, name, destPath) {
  let eocd = -1;
  for (let i = buf.length - 22; i >= 0; i -= 1) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  let offset = buf.readUInt32LE(eocd + 16);
  const count = buf.readUInt16LE(eocd + 10);
  for (let n = 0; n < count; n += 1) {
    const nameLen = buf.readUInt16LE(offset + 28);
    const extraLen = buf.readUInt16LE(offset + 30);
    const commentLen = buf.readUInt16LE(offset + 32);
    const entryName = buf.toString('utf8', offset + 46, offset + 46 + nameLen);
    if (entryName === name) {
      const method = buf.readUInt16LE(offset + 10);
      const compSize = buf.readUInt32LE(offset + 20);
      const localOff = buf.readUInt32LE(offset + 42);
      const localNameLen = buf.readUInt16LE(localOff + 26);
      const localExtraLen = buf.readUInt16LE(localOff + 28);
      const dataStart = localOff + 30 + localNameLen + localExtraLen;
      const raw = buf.subarray(dataStart, dataStart + compSize);
      fs.writeFileSync(destPath, method === 0 ? raw : zlib.inflateRawSync(raw));
      return;
    }
    offset += 46 + nameLen + extraLen + commentLen;
  }
  throw new Error(`zip entry not found: ${name}`);
}

if (import.meta.url === url.pathToFileURL(process.argv[1] ?? '').href) {
  main();
}
