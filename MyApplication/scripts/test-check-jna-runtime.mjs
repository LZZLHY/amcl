/** 对实际锁定JNA制品运行门禁正反例：错误架构、内容篡改与剥离差异分别处理。 */
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {verifyJnaNative, jnaAllocatedSections, verifyJnaWiring} from './check-jna-runtime.mjs';
const root = new URL('../', import.meta.url);
const manifestBytes = fs.readFileSync(new URL('prebuilt/jna/manifest.json', root));
const manifest = JSON.parse(manifestBytes.toString('utf8'));
// 来源清单的工作树字节必须等于Git规范化后的正文，不能在Windows按CRLF锁定、
// Linux checkout却只剩LF。此检查不依赖当前HEAD是否已提交本次清单修改。
const rawBlob = createHash('sha1').update(`blob ${manifestBytes.length}\0`).update(manifestBytes).digest('hex');
const filteredBlob = execFileSync('git', ['hash-object', '--path=prebuilt/jna/manifest.json', '--stdin'],
  {cwd: root, input: manifestBytes, encoding: 'utf8'}).trim();
assert.equal(rawBlob, filteredBlob, 'JNA manifest bytes must survive Git checkout unchanged');
assert.match(fs.readFileSync(new URL('.gitattributes', root), 'utf8'),
  /^prebuilt\/jna\/manifest\.json text eol=lf$/m, 'JNA manifest must explicitly preserve LF');
for (const slot of manifest.slots) {
  const bytes = fs.readFileSync(new URL('prebuilt/jna/' + slot.filename, root));
  verifyJnaNative(bytes, slot, true);
  assert.throws(() => verifyJnaNative(Buffer.alloc(64), slot));
  const wrongArch = Buffer.from(bytes); wrongArch.writeUInt16LE(62, 18);
  assert.throws(() => verifyJnaNative(wrongArch, slot), /AArch64/);
  const altered = Buffer.from(bytes);
  const offset = Number(bytes.readBigUInt64LE(40));
  const count = bytes.readUInt16LE(60);
  for (let i = 0; i < count; ++i) {
    const p = offset + i * 64;
    if ((bytes.readBigUInt64LE(p + 8) & 4n) && bytes.readBigUInt64LE(p + 32) > 0) {
      altered[Number(bytes.readBigUInt64LE(p + 24))] ^= 1; break;
    }
  }
  assert.throws(() => verifyJnaNative(altered, slot), /allocated section/);
  const noSections = Buffer.from(bytes); noSections.writeUInt16LE(0, 60);
  assert.throws(() => jnaAllocatedSections(noSections), /section table/);
}
const launcher = fs.readFileSync(new URL('entry/src/main/cpp/jvm/mc_launcher.cpp', root), 'utf8');
verifyJnaWiring(launcher);
for (const anchor of ['ResolveJnaBootstrap(classpath, hapNativeDir)', ', jnaBootstrap);',
  'if (!jnaBootstrap.ok)', 'recordGraphicsLaunchFailure(-5, "bootstrap", "jna_runtime_artifact_missing"']) {
  assert.throws(() => verifyJnaWiring(launcher.replace(anchor, 'removed-jna-wiring')), /wiring missing/);
}
const failureStart = launcher.indexOf('if (!jnaBootstrap.ok)');
const failureReturn = launcher.indexOf('return -5;', failureStart);
assert.ok(failureReturn > failureStart);
assert.throws(() => verifyJnaWiring(launcher.slice(0, failureReturn) +
  launcher.slice(failureReturn).replace('return -5;', '/* missing failure return */')), /wiring missing/);
console.log('JNA artifact gate PASS: three actual protocol binaries, missing/invalid/altered negative controls');
