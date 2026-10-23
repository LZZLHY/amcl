/**
 * 当前共享MGL薄门的原始证据回归。固定样本来自真实final4，先校准三条实际分支，
 * 再污染独立副本；这里只测parser，绝不从producer pass授予GPU/完整Core/设备资格。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { auditMobileGlProgramRows, loadMobileGlProgramContract } from './lib/mobilegl-program-evidence.mjs';

const directory = new URL('./fixtures/mobilegl-program-evidence/', import.meta.url);
const source = JSON.parse(fs.readFileSync(new URL('source.json', directory)));
const contract = loadMobileGlProgramContract();
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const fixture = name => {
  const bytes = fs.readFileSync(new URL(name + '.jsonl', directory));
  assert.equal(sha(bytes), source.fixtures[name].sha256, '固定原始JSONL字节漂移');
  assert.equal(bytes.length, source.fixtures[name].bytes, '固定原始JSONL长度漂移');
  return bytes.toString('utf8').trimEnd().split(/\r?\n/).map(line => JSON.parse(line));
};
let count = 0;
function check(name, rows, expectation, accepted) {
  const result = auditMobileGlProgramRows(rows, expectation, contract);
  assert.equal(result.ok, accepted, name + ': ' + result.issues.join('; '));
  assert.equal(result.fullCoreQualified, false, '薄门不得升级完整Core资格');
  ++count;
  console.log('PASS ' + name);
  return result;
}
function alter(name, mutate, baseline = 'gles', expectation = 'Unsupported', accepted = false) {
  // 每例重读冻结raw并只变副本，producer pass/footer默认保持，以检查原字段独立判据。
  const rows = fixture(baseline);
  const at = caseName => {
    const row = rows.find(value => value.case === caseName);
    assert.ok(row, '控制须绑定真实case: ' + caseName);
    return row;
  };
  mutate(rows, at);
  return check(name, rows, expectation, accepted);
}

assert.equal(source.schema, 'amcl-mobilegl-program-fixture-source/v1');
assert.equal(source.handoff.sourceFiles['mobilegl_program_cases.json'], contract.contractSha256);
assert.equal(source.handoff.sourceFiles['mobilegl_program_scene.cpp'], contract.loaderSha256);
// 预期取自调用方固定的独立driver事实，不读取JSONL中的float64Expectation来选分支。
check('actual-gles-unsupported', fixture('gles'), 'Unsupported', true);
check('actual-native-supported', fixture('native'), 'Supported', true);
check('actual-vulkan-supported', fixture('vulkan'), 'Supported', true);
check('actual-old-gles-rejected', fixture('old-gles'), 'Unsupported', false);
check('actual-old-vulkan-rejected', fixture('old-vulkan'), 'Supported', false);

// 14个已保存坏report的可移植字段差异，原文件路径/SHA写在source.json；不需要D路径。
assert.equal(source.fabricatedControls.length, 14);
for (const control of source.fabricatedControls) {
  assert.ok(control.changes.length > 0, '阴性必须真正污染输入');
  alter('saved-bad-report-' + control.name, (_rows, at) => {
    for (const change of control.changes) {
      const row = at(change.case);
      Object.assign(row, change.set);
      for (const field of change.delete) delete row[field];
    }
  });
}

// 8191是未截断上界正控；8192恰好缓冲边界必须拒绝，即使producer声明Complete/Pass。
const logLength = (at, size) => {
  const row = at('program-vertex-compile');
  row.log = 'x'.repeat(size); row.logBytes = size; row.returnedLogLength = size;
  row.declaredLogLength = size + 1; row.logComplete = true;
};
alter('log-8191-complete-boundary', (_rows, at) => logLength(at, 8191), 'gles', 'Unsupported', true);
alter('log-8192-buffer-boundary-rejected', (_rows, at) => logLength(at, 8192));
alter('log-utf8-byte-length-cannot-use-character-count', (_rows, at) => {
  const row = at('program-vertex-compile'); row.log = '汉'; row.logBytes = 1;
  row.returnedLogLength = 1; row.declaredLogLength = 2;
});
alter('log-complete-flag-missing', (_rows, at) => delete at('program-vertex-compile').logComplete);

alter('raw-pixel-value-disagrees-with-golden', (_rows, at) => {
  const row = at('program-resource-pixel'); row.rgba8x8Hex = 'ff0000ff' + row.rgba8x8Hex.slice(8);
});
alter('raw-pixels-missing-even-with-pass-and-matching-count', (_rows, at) => delete at('program-resource-pixel').rgba8x8Hex);
alter('raw-pixel-byte-report-truncated', (_rows, at) => { const row = at('program-resource-pixel'); row.rgba8x8Hex = row.rgba8x8Hex.slice(0, -2); });
alter('pixel-expected-and-readback-cannot-redefine-golden', (_rows, at) => {
  const row = at('program-resource-pixel'); row.expectedRgba = [255,0,0,255]; row.rgba8x8Hex = 'ff0000ff'.repeat(64);
});
alter('pixel-draw-error-not-hidden-by-producer-pass', (_rows, at) => { at('program-resource-pixel').drawError = 1282; });
alter('uint-actual-input-changed', (_rows, at) => { at('float32-inputs-gap1').actual[0] = 16777216; });
alter('uint-producer-cannot-redefine-both-input-and-golden', (_rows, at) => {
  const row = at('float32-inputs-gap1'); row.actual = [1,1,1]; row.expected = [1,1,1];
});
alter('uint-guard-missing', (_rows, at) => delete at('float32-inputs-gap1').guardsIntact);
alter('uint-query-component-count-short', (_rows, at) => { at('float32-inputs-gap1').queryComponents = 2; });
alter('managed-gain-query-value-wrong', (_rows, at) => { at('program-gain-query').actual = 0; });
alter('managed-sampler-query-guard-corrupt', (_rows, at) => { at('program-sampler-query').guards[0] = 0; });
alter('managed-resource-location-missing', (_rows, at) => delete at('program-resource-setup').gainLocation);
alter('current-executable-zero-not-valid-identity', (_rows, at) => { const row = at('program-failed-current'); row.expected = 0; row.actual = 0; });
alter('failed-location-query-reopened', (_rows, at) => { at('program-failed-location-error').actual = 3; });
alter('terminal-summary-query-count-wrong', rows => { rows.at(-1).queryChecks += 1; });
alter('terminal-summary-failure-count-wrong', rows => { rows.at(-1).failures = 1; });
alter('terminal-not-completed', rows => { rows.at(-1).completed = false; });
alter('terminal-missing', rows => { rows.pop(); });
alter('terminal-duplicate', rows => { rows.push(structuredClone(rows.at(-1))); });
alter('terminal-not-last', rows => { [rows[rows.length-1],rows[rows.length-2]] = [rows.at(-2),rows.at(-1)]; });
alter('required-case-missing', rows => { rows.splice(2,1); });
alter('required-case-duplicated', rows => { rows.splice(3,0,structuredClone(rows[2])); });
alter('required-case-order-wrong', rows => { [rows[2],rows[3]] = [rows[3],rows[2]]; });
alter('producer-precision-branch-cannot-replace-caller-fact', rows => { rows[1].float64Expectation = 'Supported'; });
alter('full-core-claim-rejected', rows => { rows.at(-2).fullCoreQualified = true; });
alter('unrun-domain-upgraded-without-evidence', rows => { rows[1].computeDispatch = 'PASS'; });
alter('unknown-record-inserted', rows => { rows.splice(2,0,{kind:'foreign-evidence',pass:true}); });
alter('supported-fresh-use-error', (_rows, at) => { at('float64-use').useError = 1282; }, 'vulkan', 'Supported');
alter('supported-fresh-use-drain-missing', (_rows, at) => delete at('float64-use').useErrorDrainComplete, 'native', 'Supported');

console.log(`MobileGL program evidence: ${count} controls passed (parser only)`);
