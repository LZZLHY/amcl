#!/usr/bin/env node
// check-release-no-test-symbols.mjs 的定向自测。
//
// 这道门禁有三条最容易写成"不可能失败"的地方，每条都双向测：
//   ① 没有产物时的语义 —— CI 无产物必须放行、出货路径必须失败；
//   ② 整词匹配 —— 子串误命中会让它变成一个乱报的门禁（下一轮被忽略）；
//   ③ zip 中央目录解析 —— 解析不出条目名就等于"HAP 里什么都没有"，恒绿。
// 另外工具定位失败必须 fail-closed（当失败），不能跳过。

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';
import zlib from 'node:zlib';
import {
  parseTestNapiNames,
  readZipEntryNames,
  findTestNames,
  evaluate,
} from './check-release-no-test-symbols.mjs';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');

let failures = 0;
function check(label, ok, detail) {
  if (ok) { console.log(`[test-check-release-no-test-symbols] PASS: ${label}`); return; }
  failures += 1;
  console.error(`[test-check-release-no-test-symbols] FAIL: ${label}`);
  if (detail !== undefined) console.error(`  ${detail}`);
}

// ---- parseTestNapiNames：名单必须来自源码，不能是手抄副本 ----------------------
//
// ⚠️ 这条曾经是假的：标签写着"与 kTestsDescriptors 对齐"，实际只断言一个写死数组的
// length===14 —— 加第 15 个测试时门禁静默漏检而自测照旧 PASS。现在真的读那个文件。

check('从 kTestsDescriptors 现场解析出属性名',
  parseTestNapiNames(`
    constexpr napi_property_descriptor kTestsDescriptors[] = {
        NAPI_FUNC("runJitTests",  RunJitTests),
        NAPI_FUNC( "runSdl3WindowTest" , RunSdl3WindowTest),
    };`).join(',') === 'runJitTests,runSdl3WindowTest');

check('解析不出名字时返回空数组（由调用方 fail-closed，不得当成"没有测试符号"）',
  parseTestNapiNames('int main() { return 0; }').length === 0);

// 真的读仓库里那份 cpp —— 这是"名单与源码对齐"唯一不说谎的验法。
{
  const real = parseTestNapiNames(
    fs.readFileSync(path.join(ROOT, 'entry/src/main/cpp/napi/napi_tests.cpp'), 'utf8'));
  check('真实 napi_tests.cpp 能解析出一批名字且含已知项',
    real.length > 0 && real.includes('runJitTests') && real.includes('runSdl3WindowTest'),
    `${real.length}: ${real.join(',')}`);
}

// ---- findTestNames（子串，刻意不整词）-----------------------------------------
//
// 致命方向是**少报**。整词判据会在"字符串尾与相邻数据合并""前面紧接词字符"时漏判，
// 而实测 122 个 NAPI 名里没有任何一个是这 14 个的超串 ⇒ 超串误命中的风险不存在。
// 所以这里刻意用 includes：多报只需人工看一眼，少报会让测试代码溜进出货包。

check('命中真实存在的名字（\\n 分隔，与 llvm-strings 真实输出一致）',
  findTestNames('foo\nrunJitTests\nbar\n', ['runJitTests']).join(',') === 'runJitTests');

check('与相邻数据粘连时仍然命中（整词判据会在这里漏判）',
  findTestNames('xxrunJitTestsyy', ['runJitTests']).length === 1);

check('多个名字都能命中',
  findTestNames('runGl4Test\nrunMgTest\n', ['runGl4Test', 'runMgTest']).length === 2);

check('干净字符串表 → 零命中',
  findTestNames('downloadStart\nsetControlSchema\n', ['runJitTests']).length === 0);

// ---- readZipEntryNames -------------------------------------------------------
// 造一个最小 zip（两个 stored 条目），验证中央目录解析真的能列出条目名。
function buildZip(files) {
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const f of files) {
    const name = Buffer.from(f.name, 'utf8');
    const data = Buffer.from(f.data, 'utf8');
    const crc = zlib.crc32 ? zlib.crc32(data) : 0;
    const lh = Buffer.alloc(30);
    lh.writeUInt32LE(0x04034b50, 0); lh.writeUInt16LE(20, 4); lh.writeUInt16LE(0, 8);
    lh.writeUInt32LE(crc, 14); lh.writeUInt32LE(data.length, 18); lh.writeUInt32LE(data.length, 22);
    lh.writeUInt16LE(name.length, 26); lh.writeUInt16LE(0, 28);
    const ch = Buffer.alloc(46);
    ch.writeUInt32LE(0x02014b50, 0); ch.writeUInt16LE(20, 6); ch.writeUInt16LE(0, 10);
    ch.writeUInt32LE(crc, 16); ch.writeUInt32LE(data.length, 20); ch.writeUInt32LE(data.length, 24);
    ch.writeUInt16LE(name.length, 28); ch.writeUInt32LE(offset, 42);
    locals.push(lh, name, data);
    centrals.push(ch, name);
    offset += lh.length + name.length + data.length;
  }
  const localPart = Buffer.concat(locals);
  const centralPart = Buffer.concat(centrals);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(files.length, 8); eocd.writeUInt16LE(files.length, 10);
  eocd.writeUInt32LE(centralPart.length, 12); eocd.writeUInt32LE(localPart.length, 16);
  return Buffer.concat([localPart, centralPart, eocd]);
}

const zipNames = readZipEntryNames(buildZip([
  { name: 'libs/arm64-v8a/libentry.so', data: 'x' },
  { name: 'libs/arm64-v8a/libfakejvm.so', data: 'y' },
]));
check('zip 中央目录能列出全部条目名',
  zipNames.length === 2 && zipNames.includes('libs/arm64-v8a/libfakejvm.so'),
  JSON.stringify(zipNames));

// 这条比"16 字节的短 buffer"更有力：长度足够、内容却不是 zip，
// 短 buffer 那种连循环都不进，任何不崩的实现都能过。
check('长度足够但不是 zip → 空数组（而不是抛异常）',
  readZipEntryNames(Buffer.alloc(4096, 0x41)).length === 0);

// 条目名带非 ASCII，验证按 nameLen 取 utf8 的边界算对了（算错会截断成乱码）。
{
  const names = readZipEntryNames(buildZip([{ name: 'libs/中文/libentry.so', data: 'x' }]));
  check('utf8 条目名按 nameLen 正确取出',
    names.join(',') === 'libs/中文/libentry.so', JSON.stringify(names));
}

// ---- evaluate（三条语义双向）--------------------------------------------------

check('CI（无产物 + 不要求）→ 放行',
  evaluate({ hapPresent: false, requireArtifact: false, testLibs: [], mangledNames: [] }).ok === true);

check('出货路径（无产物 + 要求）→ 失败',
  evaluate({ hapPresent: false, requireArtifact: true, testLibs: [], mangledNames: [] }).ok === false);

check('产物干净 → 放行',
  evaluate({ hapPresent: true, requireArtifact: true, testLibs: [], mangledNames: [] }).ok === true);

const withLib = evaluate({
  hapPresent: true, requireArtifact: true, testLibs: ['libs/arm64-v8a/libfakejvm.so'], mangledNames: [],
});
check('HAP 里有 libfakejvm.so → 失败',
  withLib.ok === false && withLib.reason === 'test-lib-present', JSON.stringify(withLib));

const withNames = evaluate({
  hapPresent: true, requireArtifact: true, testLibs: [], mangledNames: ['runJitTests'],
});
check('libentry.so 里有测试属性名 → 失败',
  withNames.ok === false && withNames.reason === 'test-napi-present', JSON.stringify(withNames));

if (failures > 0) {
  console.error(`[test-check-release-no-test-symbols] ${failures} case(s) failed`);
  process.exitCode = 1;
} else {
  console.log('[test-check-release-no-test-symbols] ALL PASS');
}
