/** 实际capability原文+受控artifact/marker夹具的薄门反例，不作为设备资格。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { auditMobileGlLoadedEvidence } from './check-mobilegl-loaded-evidence.mjs';
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const capability = fs.readFileSync(new URL('./fixtures/mobilegl-loaded-evidence/capability.txt', import.meta.url));
const source = JSON.parse(fs.readFileSync(new URL('./fixtures/mobilegl-loaded-evidence/source.json', import.meta.url)));
assert.equal(sha(capability), source.sha256, '实际原文夹具不可悄改');
const library = Buffer.alloc(64); Buffer.from('7f454c460201', 'hex').copy(library); library.writeUInt16LE(183, 18);
// 最小stored ZIP仅供包reader身份控制，不伪造实际HAP资格。
const name = Buffer.from('libs/arm64-v8a/libmobilegl.so'), local = Buffer.alloc(30), central = Buffer.alloc(46), end = Buffer.alloc(22);
local.writeUInt32LE(0x04034b50); local.writeUInt32LE(64, 18); local.writeUInt32LE(64, 22); local.writeUInt16LE(name.length, 26);
central.writeUInt32LE(0x02014b50); central.writeUInt32LE(64, 20); central.writeUInt32LE(64, 24); central.writeUInt16LE(name.length, 28);
const blocks = Buffer.concat([local, name, library]), directory = Buffer.concat([central, name]);
end.writeUInt32LE(0x06054b50); end.writeUInt16LE(1, 8); end.writeUInt16LE(1, 10); end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(blocks.length, 16);
const hap = Buffer.concat([blocks, directory, end]);
const image = '/data/storage/el1/bundle/libs/arm64/libmobilegl.so';
const expected = { pid: 123, runId: '123-456', hapSha256: sha(hap), librarySha256: sha(library), imagePath: image };
const text = 'MOBILEGL_QUAL_RUN runId=123-456 processPid=123 startUnixNs=789 startSteadyNs=456\n' + capability.toString().replace(/\r\n/g, '\n') +
  `MOBILEGL_QUAL_IMAGE library=libmobilegl.so anchor=eglGetDisplay image=${image} imageBase=0x1000 bytes=64 path=/data/storage/el2/base/haps/entry/files/mobilegl-capability-probe/123-456/loaded-libmobilegl.so\n` +
  'MOBILEGL_QUAL_END runId=123-456 processPid=123 imageCopyComplete=1 verdict=COMPLETE\n';
const marker = bytes => Buffer.from(`MOBILEGL_QUAL_RETURN runId=123-456 processPid=123 reportBytes=${bytes.length} returned=1 verdict=COMPLETE\n`);
const report = Buffer.from(text);
const positive = auditMobileGlLoadedEvidence(report, marker(report), hap, library, expected);
assert.equal(positive.ok, true, positive.issues.join('\n'));
let controls = 0;
// 每次更新外部字节长度，确保各反例确实被对应事实拦截，而非全被一个长度差拦截。
function rejected(transform) {
  const changed = Buffer.from(transform(text));
  assert.equal(auditMobileGlLoadedEvidence(changed, marker(changed), hap, library, expected).ok, false);
  ++controls;
}
rejected(value => value.slice(0, -1));
rejected(value => value + '\n');
rejected(value => value.replace(/MOBILEGL_QUAL_END[^\n]+\n/, ''));
rejected(value => value.replace('imageCopyComplete=1', 'imageCopyComplete=0'));
rejected(value => value.replace('startSteadyNs=456', 'startSteadyNs=457'));
rejected(value => value.replace('anchor=eglGetDisplay', 'anchor=facade'));
rejected(value => value.replace('imageBase=0x1000', 'imageBase=0x0'));
rejected(value => value.replace('bytes=64', 'bytes=63'));
rejected(value => value.replace('/123-456/loaded-', '/123-455/loaded-'));
rejected(value => value.replace('cleanup_complete=1', 'cleanup_complete=0'));
rejected(value => value.replace('present_counter=3', 'present_counter=6'));
rejected(value => value.replace('admission=PASS', 'admission=FAIL'));
rejected(value => value.replace('mobilegl_present_success_2\n', ''));
rejected(value => value.replace('MOBILEGL_QUAL_END ', 'UNEXPECTED_PASS\nMOBILEGL_QUAL_END '));
rejected(value => value.replace('processPid=123', 'processPid=124'));
const incomplete = Buffer.from(text.replace(/MOBILEGL_QUAL_IMAGE[^\n]+\n/, 'MOBILEGL_QUAL_FAILURE reason=copy failed\n').replace('imageCopyComplete=1 verdict=COMPLETE', 'imageCopyComplete=0 verdict=INCOMPLETE'));
const isolated = auditMobileGlLoadedEvidence(incomplete, marker(incomplete), hap, library, expected);
assert.equal(isolated.ok, false); assert.equal(isolated.functionalPass, true, 'copy失败不能篡改production功能文本的PASS'); ++controls;
for (const [returned, loaded, wanted] of [[Buffer.from('force-stop'), library, expected],
  [Buffer.concat([marker(report), marker(report)]), library, expected],
  [Buffer.from(marker(report).toString().replace('returned=1', 'returned=0')), library, expected],
  [marker(report), Buffer.alloc(64), expected], [marker(report), library, { ...expected, hapSha256: 'a'.repeat(64) }],
  [marker(report), library, { ...expected, runId: '123-457' }], [marker(report), library, {}]]) {
  assert.equal(auditMobileGlLoadedEvidence(report, returned, hap, loaded, wanted).ok, false); ++controls;
}
console.log(`MobileGL loaded-evidence controls PASS positive=1 negative=${controls} scope=parser-only`);
