/**
 * 真实共享场景JSONL配合语法级设备包装器的宿主反例测试。
 * positive-scene来自Mesa reference的真实查询/像素输出，来源与摘要单独保留；本文件的
 * PID、函数地址和ELF包是受控解析夹具，不能作为真实MG/设备资格。每项负控只改一个
 * 必需身份或完整性事实，并要求验收器拒绝，而不复制共享场景的深度/像素算法。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { auditMgDepthEvidence, loadDepthEvidenceContract } from './check-mg-depth-evidence.mjs';
import { loadUniformInitializerContract } from './lib/uniform-initializer-evidence.mjs';

const contract = loadDepthEvidenceContract();
const scene = fs.readFileSync(new URL('./fixtures/mg-depth-evidence/positive-scene.jsonl', import.meta.url));
const source = JSON.parse(fs.readFileSync(new URL('./fixtures/mg-depth-evidence/source.json', import.meta.url), 'utf8'));
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
assert.equal(sha(scene), source.sha256, '真实共享场景夹具不得悄悄改写正文');
const image = '/data/storage/el1/bundle/libs/arm64/libamcl_gl_host.so';
const library = Buffer.alloc(64); Buffer.from('7f454c460201', 'hex').copy(library); library.writeUInt16LE(183, 18);

/** 构造最小标准stored ZIP，只用于独立包载荷身份反例；实际CLI共用生产ZIP reader。 */
function hap(payload = library) {
  const name = Buffer.from('libs/arm64-v8a/libamcl_gl_host.so'), local = Buffer.alloc(30), central = Buffer.alloc(46), end = Buffer.alloc(22);
  local.writeUInt32LE(0x04034b50); local.writeUInt32LE(payload.length, 18); local.writeUInt32LE(payload.length, 22); local.writeUInt16LE(name.length, 26);
  central.writeUInt32LE(0x02014b50); central.writeUInt32LE(payload.length, 20); central.writeUInt32LE(payload.length, 24); central.writeUInt16LE(name.length, 28);
  const blocks = Buffer.concat([local, name, payload]), directory = Buffer.concat([central, name]);
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(1, 8); end.writeUInt16LE(1, 10); end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(blocks.length, 16);
  return Buffer.concat([blocks, directory, end]);
}
const expected = { pid: 123, runId: '123-456', librarySha256: sha(library), imagePath: image };
const functions = contract.functions.map((name, i) => `FUNCTION name=${name} address=0x${(4096 + i).toString(16)} owned=1 image=${image} symbol=${name}`);
const report = Buffer.from([
  'PROBE_RUN runId=123-456 processPid=123 startUnixNs=789 startSteadyNs=456',
  'BEGIN MG_DEPTH_RANGE production-profile=mobileglues api=OPENGL',
  `PROVIDER image=${image} implementation=unit-fixture`,
  `IMAGE_COPY library=libamcl_gl_host.so bytes=${library.length} path=/data/storage/el2/base/haps/entry/files/mg-depth-range-probe/loaded-libamcl_gl_host.so`,
  'PASS legal-current-thread tid=123 actualMajor=3 actualMinor=2', ...functions,
  'GL_VERSION=4.6 MobileGlues fixture', 'GL_VENDOR=fixture', 'GL_RENDERER=fixture', 'GL_INTEGER_VERSION=3.2',
  scene.toString('utf8').trimEnd(), 'PASS context-owner-destroy error= permit=0',
  `MG_DEPTH_RANGE_RESULT completed=1 checks=${contract.counts.checks} queryChecks=${contract.counts.queryChecks} pixelChecks=${contract.counts.pixelChecks} failures=0 resolved=${functions.length} rejected=0 evidenceComplete=1 retired=1 verdict=PASS`,
  'PROBE_END runId=123-456 processPid=123 completed=1 exitCode=0 restartRequired=1 verdict=PASS', '',
].join('\n'));
const marker = bytes => Buffer.from(`hilog external observation PROBE_RETURN runId=123-456 processPid=123 reportBytes=${bytes.length} returned=1 verdict=PASS\n`);
assert.equal(auditMgDepthEvidence(report, marker(report), hap(), expected).ok, true);

/** 改报告后仍用匹配长度的外部包装，仅考察该关键缺陷，避免所有负控只被长度挡住。 */
function rejectReport(transform, pattern) {
  const changed = Buffer.from(transform(report.toString('utf8')));
  const result = auditMgDepthEvidence(changed, marker(changed), hap(), expected);
  assert.equal(result.ok, false); assert.match(result.issues.join('\n'), pattern);
}
assert.equal(auditMgDepthEvidence(report, marker(report), hap(), { ...expected, pid: 124 }).ok, false);
assert.equal(auditMgDepthEvidence(report, marker(report), hap(), { ...expected, runId: '123-457' }).ok, false);
assert.equal(auditMgDepthEvidence(report, marker(report), hap(), { ...expected, librarySha256: 'a'.repeat(64) }).ok, false);
assert.equal(auditMgDepthEvidence(report, marker(report), hap(Buffer.from('wrong-payload')), expected).ok, false);
assert.equal(auditMgDepthEvidence(report, Buffer.from('host force-stop before return'), hap(), expected).ok, false);
assert.equal(auditMgDepthEvidence(report, Buffer.from('PROBE_RETURN runId=123-456 processPid=123 reportBytes=1 returned=1 verdict=PASS'), hap(), expected).ok, false);
assert.equal(auditMgDepthEvidence(report, marker(report), hap(), {}).ok, false);
rejectReport(text => text.slice(0, -1), /Truncated/);
rejectReport(text => text.replace(/PROBE_END[^\n]+\n/, ''), /PROBE_END/);
rejectReport(text => text.replace('completed=1 exitCode=0 restartRequired=1', 'completed=0 exitCode=-1 restartRequired=1'), /Incomplete/);
rejectReport(text => text.replace('restartRequired=1', 'restartRequired=0'), /restartRequired/);
rejectReport(text => text.replace(/FUNCTION[^\n]*name=glDepthRange [^\n]+\n/, ''), /resolution completeness/);
rejectReport(text => text.replace('owned=1', 'owned=0'), /foreign function/);
rejectReport(text => text.replace('address=0x1000', 'address=0x0'), /foreign function/);
rejectReport(text => text.replace(/\{"kind":"float-query","case":"double-nondefault"[^\n]+\n/, ''), /Raw check|query/);
rejectReport(text => text.replace(/\{"kind":"gl-error","case":"object-owner-retire"[^\n]+\n/, ''), /Required shared check/);
rejectReport(text => text.replace('"pass":true', '"pass":false'), /Shared scene reported/);
rejectReport(text => text.replace('"sampledPixels":64', '"sampledPixels":63'), /partial raw pixel/);
rejectReport(text => text.replace('PROBE_END ', 'PROCESS_TERMINATED signal=9\nPROBE_END '), /Unknown/);
rejectReport(text => text.replace('{"kind":"scene-end"', '{"verdict":"NOT_RUN"}\n{"kind":"scene-end"'), /not-run|Unknown scene/);
rejectReport(text => text.replace(/IMAGE_COPY[^\n]+\n/, ''), /IMAGE_COPY/);
rejectReport(text => text.replace('IMAGE_COPY library=libamcl_gl_host.so bytes=64', 'IMAGE_COPY library=libamcl_gl_host.so bytes=63'), /loaded-image copy/);
rejectReport(text => text.replace('{"kind":"preexisting-errors","count":0}', '{"kind":"preexisting-errors","count":-1}'), /metadata/);
rejectReport(text => text.replace('evidenceComplete=1', 'evidenceComplete=0'), /summary failed/);
rejectReport(text => text.replace('PASS context-owner-destroy', 'FAIL context-owner-destroy'), /failure|retirement/);
rejectReport(text => text.replace('PROBE_END ', 'FAIL evidence close failed\nPROBE_END '), /I\/O error/);
rejectReport(text => text + 'PROBE_END runId=123-456 processPid=123 completed=1 exitCode=0 restartRequired=1 verdict=PASS\n', /exactly once/);
rejectReport(text => text.replace(/\{"kind":"scene-end"[^\n]+\n/, '{"kind":"scene-end"\n'), /JSON/);
// 新真实initializer JSONL另有原字节来源；下列wrapper地址/PID/HAP仍为解析夹具。
const initializerContract = loadUniformInitializerContract();
const initializerScene = fs.readFileSync(new URL('./fixtures/mg-initializer-evidence/positive-scene.jsonl', import.meta.url));
const initializerSource = JSON.parse(fs.readFileSync(new URL('./fixtures/mg-initializer-evidence/source.json', import.meta.url)));
assert.equal(sha(initializerScene), initializerSource.sha256);
const initializerFunctions = initializerContract.functions.map((name, i) => `FUNCTION name=${name} address=0x${(8192 + i).toString(16)} owned=1 image=${image} symbol=${name}`);
const combined = Buffer.from(report.toString().replace('PASS context-owner-destroy',
  'BEGIN MG_UNIFORM_INITIALIZER sceneVersion=1 shader=desktop330\n' + initializerFunctions.join('\n') + '\n' + initializerScene.toString() + 'PASS context-owner-destroy').replace('PROBE_END ',
  `MG_UNIFORM_INITIALIZER_RESULT sceneVersion=1 completed=1 checks=16 queryChecks=2 pixelChecks=2 failures=0 resolved=${initializerFunctions.length} rejected=0 evidenceComplete=1 retired=1 verdict=PASS\nPROBE_END `));
const required = { ...expected, requireInitializer: true };
const audited = auditMgDepthEvidence(combined, marker(combined), hap(), required);
assert.equal(audited.ok, true, audited.issues.join('\n'));
assert.equal(auditMgDepthEvidence(report, marker(report), hap(), required).ok, false, '旧完整depth不能借作新shader资格');
let initializerControls = 0;
function rejectInitializer(transform) {
  const changed = Buffer.from(transform(combined.toString()));
  assert.equal(auditMgDepthEvidence(changed, marker(changed), hap(), required).ok, false);
  ++initializerControls;
}
rejectInitializer(text => text.replace('sceneVersion=1 shader=desktop330', 'sceneVersion=2 shader=desktop330'));
rejectInitializer(text => text.replace(initializerScene.toString(), ''));
rejectInitializer(text => text.replace(/\{"kind":"uniform-query","case":"initializer-link-default"[^\n]+\n/, ''));
rejectInitializer(text => text.replace(/\{"kind":"gl-error","case":"initializer-owner-retire"[^\n]+\n/, ''));
rejectInitializer(text => text.replace('"expectedRgba":[64,128,191,255]', '"expectedRgba":[64,128,190,255]'));
rejectInitializer(text => text.replace('checks=16 queryChecks=2 pixelChecks=2', 'checks=17 queryChecks=2 pixelChecks=2'));
rejectInitializer(text => text.replace(/FUNCTION[^\n]*name=glGetUniformfv [^\n]+\n/, ''));
rejectInitializer(text => {
  const row = text.match(/FUNCTION[^\n]*name=glUniform4f [^\n]+\n/)[0];
  return text.replace(row, '').replace('BEGIN MG_UNIFORM_INITIALIZER ', row + 'BEGIN MG_UNIFORM_INITIALIZER ');
});
rejectInitializer(text => text.replace(/\{"kind":"initializer-scene-end"[^\n]+\n/, ''));
rejectInitializer(text => text.replace('"guards":[73,74],"tolerance":0.000002', '"guards":[73,0],"tolerance":0.000002'));
rejectInitializer(text => text.replace('"case":"initializer-link-default","pass":true', '"case":"initializer-link-default","pass":false'));
rejectInitializer(text => text.replace('{"kind":"initializer-scene-end"', '{"verdict":"NOT_RUN"}\n{"kind":"initializer-scene-end"'));
rejectInitializer(text => text.replace('BEGIN MG_UNIFORM_INITIALIZER ', 'BEGIN MG_UNIFORM_INITIALIZER sceneVersion=1 shader=desktop330\nBEGIN MG_UNIFORM_INITIALIZER '));
rejectInitializer(text => {
  const lines = text.split('\n');
  const before = lines.findIndex(line => line.startsWith('{"kind":"uniform-query","case":"initializer-link-default"'));
  const after = lines.findIndex(line => line.startsWith('{"kind":"pixels","case":"initializer-manual-setter"'));
  [lines[before], lines[after]] = [lines[after], lines[before]];
  return lines.join('\n');
});
console.log(`MG depth+initializer evidence PASS: historical depth preserved, new initializer required, actual 16/2/2, ${initializerControls} new completeness controls`);
