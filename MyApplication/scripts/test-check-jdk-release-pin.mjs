#!/usr/bin/env node
/**
 * test-check-jdk-release-pin.mjs — 给 check-jdk-release-pin 的自测
 *
 * ⭐ 为什么必须有：AGENTS §二.8 ——「判定某样东西在不在的工具，本身要先在一个**已知含有它**
 * 的样本上验证过」。一个只会说 PASS 的门禁比没有门禁更糟：它会让人以为四处 SoT 已经对齐。
 *
 * 所以这里每条用例都是**先造一个已知有问题的输入，再断言它被抓住**，
 * 外加若干「已知正常的输入不许误报」的反向用例。
 */
import assert from 'node:assert';
import { parseDepsLock, parseConstants, parseJdkVersions, verify } from './check-jdk-release-pin.mjs';

let pass = 0;
function t(name, fn) {
  try {
    fn();
    console.log('[test-check-jdk-release-pin] PASS: ' + name);
    pass++;
  } catch (e) {
    console.error('[test-check-jdk-release-pin] FAIL: ' + name);
    console.error('  ' + (e && e.message ? e.message : String(e)));
    process.exit(1);
  }
}

const LOCK = `
# 注释里的 [假段名] 不许被当成段
[mc-ohos-resources]
repo      = LZZLHY/mc-ohos-resources
tag       = v17.0.13-ohos-5
asset     = jdk17-ohos-full-v5.zip
sizeBytes = 113762513
sha256    = 139c5e56d69a87e21c0bf87f9f1e7b1f358ceaba54a7173f06e07a70f2177374

[mc-ohos-resources-21]
tag       = v21.0.5-ohos-7
asset     = jdk21-ohos-full-v7.zip
sizeBytes = 114267146
sha256    = 1fd734c8bdb9b06b2cf85607440fae202de7d07bdf97c3412693991c54c5ece5

[cacert]
version  = 2026-02-11
`;

const CONSTS = `
export const JDK21_RELEASE_TAG = 'v21.0.5-ohos-7'
export const JDK21_RELEASE_ASSET = 'jdk21-ohos-full-v7.zip'
`;

// 17 用字面量，21 用 Constants 引用 —— 与真实文件的两种形状一致
function jdkText(o) {
  const d = Object.assign({
    tag17: "'v17.0.13-ohos-5'",
    asset17: "'jdk17-ohos-full-v5.zip'",
    size17: 113762513,
    sha17: '139c5e56d69a87e21c0bf87f9f1e7b1f358ceaba54a7173f06e07a70f2177374',
    parts17: "'jdk17-ohos-full-v5.zip.part01of03',\n      'jdk17-ohos-full-v5.zip.part02of03',\n      'jdk17-ohos-full-v5.zip.part03of03',",
    sizes17: '37920837, 37920837, 37920839',
  }, o);
  return `
const JDK_VERSIONS: Record<string, JdkVersionConfig> = {
  '17': {
    tag: ${d.tag17},
    dataFile: ${d.asset17},
    dataSizeMB: 108,
    sha256: '${d.sha17}',
    sizeBytes: ${d.size17},
    giteeParts: [
      ${d.parts17}
    ],
    giteePartSizes: [${d.sizes17}],
  },
  '21': {
    tag: JDK21_RELEASE_TAG,
    dataFile: JDK21_RELEASE_ASSET,
    dataSizeMB: 109,
    sha256: '1fd734c8bdb9b06b2cf85607440fae202de7d07bdf97c3412693991c54c5ece5',
    sizeBytes: 114267146,
    giteeParts: [
      'jdk21-ohos-full-v7.zip.part01of03',
      'jdk21-ohos-full-v7.zip.part02of03',
      'jdk21-ohos-full-v7.zip.part03of03',
    ],
    giteePartSizes: [38089048, 38089048, 38089050],
  },
}
`;
}

const README = {
  '17': 'tag v17.0.13-ohos-5 asset jdk17-ohos-full-v5.zip',
  '21': 'tag v21.0.5-ohos-7 资产 jdk21-ohos-full-v7.zip',
};

function run(jdkSrc, readmes = README) {
  const consts = parseConstants(CONSTS);
  return verify(parseDepsLock(LOCK), parseJdkVersions(jdkSrc, consts), readmes);
}

// ---------- 解析器本身 ----------

t('deps.lock 只认真正的段头，不吃注释里的方括号', () => {
  const l = parseDepsLock(LOCK);
  assert.strictEqual(l['17'].tag, 'v17.0.13-ohos-5');
  assert.strictEqual(l['21'].asset, 'jdk21-ohos-full-v7.zip');
  assert.strictEqual(l['25'], undefined, '本 fixture 没有 25 段');
});

t('Constants 引用能被解引用（不是拿标识符名去比）', () => {
  const j = parseJdkVersions(jdkText({}), parseConstants(CONSTS));
  assert.strictEqual(j['21'].tag, 'v21.0.5-ohos-7');
  assert.strictEqual(j['21'].dataFile, 'jdk21-ohos-full-v7.zip');
});

t('分卷名与字节数都能解析出来', () => {
  const j = parseJdkVersions(jdkText({}), parseConstants(CONSTS));
  assert.strictEqual(j['17'].giteeParts.length, 3);
  assert.deepStrictEqual(j['17'].giteePartSizes, [37920837, 37920837, 37920839]);
});

// ---------- 反向：一致的输入不许误报 ----------

t('四处一致 ⇒ 零问题（不许误报）', () => {
  assert.deepStrictEqual(run(jdkText({})), []);
});

// ---------- 正向：每种漏改都必须被抓住 ----------

t('抓住 tag 漏改（JdkManager 还是旧 tag）', () => {
  const p = run(jdkText({ tag17: "'v17.0.13-ohos-4'" }));
  assert.ok(p.some((x) => x.includes('tag 不一致')), '应报 tag 不一致，实际: ' + JSON.stringify(p));
});

t('抓住 asset 漏改', () => {
  const p = run(jdkText({ asset17: "'jdk17-ohos-full-v4.zip'" }));
  assert.ok(p.some((x) => x.includes('asset 不一致')), JSON.stringify(p));
});

t('抓住 sizeBytes 漏改', () => {
  const p = run(jdkText({ size17: 114006672 }));
  assert.ok(p.some((x) => x.includes('sizeBytes 不一致')), JSON.stringify(p));
});

t('抓住 sha256 漏改', () => {
  const p = run(jdkText({ sha17: '0'.repeat(64) }));
  assert.ok(p.some((x) => x.includes('sha256 不一致')), JSON.stringify(p));
});

t('⭐ 抓住分卷字节数之和 ≠ sizeBytes（此前没有任何地方校验这条）', () => {
  const p = run(jdkText({ sizes17: '37920837, 37920837, 37920838' }));  // 少 1 字节
  assert.ok(p.some((x) => x.includes('分卷字节数之和')), JSON.stringify(p));
});

t('抓住 giteeParts 与 giteePartSizes 长度不等', () => {
  const p = run(jdkText({ sizes17: '37920837, 37920837' }));
  assert.ok(p.some((x) => x.includes('长度不等')), JSON.stringify(p));
});

t('抓住分卷名还带着旧 asset 名（换包最典型的漏改）', () => {
  const p = run(jdkText({
    parts17: "'jdk17-ohos-full-v4.zip.part01of03',\n      'jdk17-ohos-full-v4.zip.part02of03',\n      'jdk17-ohos-full-v4.zip.part03of03',",
  }));
  assert.ok(p.some((x) => x.includes("不以 asset")), JSON.stringify(p));
});

t('抓住 README 没跟着换 tag', () => {
  const p = run(jdkText({}), { '17': 'tag v17.0.13-ohos-4 …', '21': README['21'] });
  assert.ok(p.some((x) => x.includes('README.md 里没有出现当前 tag')), JSON.stringify(p));
});

t('抓住 tag 引用了不存在的常量（Constants 漏加）', () => {
  const j = parseJdkVersions(jdkText({}), {});   // 空 constants
  const p = verify(parseDepsLock(LOCK), j, README);
  assert.ok(p.some((x) => x.includes('不存在的常量')), JSON.stringify(p));
});

t('抓住 deps.lock 缺段', () => {
  const consts = parseConstants(CONSTS);
  const j = parseJdkVersions(jdkText({}), consts);
  const p = verify({ '17': parseDepsLock(LOCK)['17'] }, j, README);   // 故意去掉 21 段
  assert.ok(p.some((x) => x.includes('没有对应的')), JSON.stringify(p));
});

console.log('[test-check-jdk-release-pin] ALL PASS (' + pass + ')');
