/**
 * 离线资格解析器的身份借用及假PASS反例。
 * 夹具借用真实B0的MobileGL源码/库摘要表达结构，其余固定字段明确只用于单元测试，
 * 不产生目标GPU、游戏或CTS验收证据。所有反例从同一完整报告改变一个关键事实。
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parseGraphicsRegistry } from './lib/graphics-profile-registry.mjs';
import { auditGraphicsQualification } from './lib/graphics-qualification.mjs';

const profiles = parseGraphicsRegistry(readFileSync(fileURLToPath(new URL('../launch/src/main/ets/GraphicsProfileRegistry.ets', import.meta.url)), 'utf8'));
const hash = 'a'.repeat(64);
const identity = value => ({ identity: value });
const absent = reason => ({ notApplicable: true, reason });
const record = {
  schemaVersion: 1, id: 'unit-fixture-not-device-evidence', capturedAt: '2026-10-08T01:06:23+08:00',
  stage: 'host', implementationState: 'present',
  implementation: {
    sources: [{ repository: 'LZZLHY/MobileGL', commit: '920894cdcb360e359689fac39901d9785741edd6', treeSha256: hash }],
    patches: [], buildOptionsSha256: hash, toolchainSha256: hash,
  },
  payload: { libraries: [{ name: 'libmobilegl.so', sha256: '157c6f15da4bbe6a5df68d0975b0a6b03dfa395ed59e8c1eb9ad288efc2aef27', buildId: 'unit-fixture-build-id' }], package: absent('Host fixture; no HAP is loaded') },
  call: { profileId: 'mobilegl', api: 'OPENGL', provider: 'GLFW', jdk: absent('No JVM'), lwjglSlot: absent('No LWJGL'), classloader: absent('No Java class loading') },
  platform: { os: identity('Windows host fixture'), apiLevel: absent('No OHOS API'), gpu: absent('Driver substitute'), driver: absent('Driver substitute'), surface: absent('No window'), context: absent('Production function fixture'), optionsSha256: hash },
  test: { runner: 'unit-report-fixture', version: '1', sourceSha256: hash, caseListSha256: hash, oracle: 'Explicit presented sequence obligations; fixture only', trace: absent('No replay'), tolerance: { definition: 'Exact integer equality' } },
  execution: { runId: 'fresh-fixture-run', pid: 2001, startedAt: '2026-10-08T01:06:17+08:00', finishedAt: '2026-10-08T01:06:23+08:00', completed: true, termination: 'normal', exitCode: 0, logSha256: hash },
  cases: [{ id: 'presented', result: 'PASS', evidence: 'Fixture-only sequence assertion' }, { id: 'deferred', result: 'PASS', evidence: 'Fixture-only zero sequence assertion' }],
};
const expected = Object.fromEntries(['implementation', 'payload', 'call', 'platform', 'test', 'execution'].map(key => [key, structuredClone(record[key])]));
expected.requiredCases = ['presented', 'deferred'];
expected.stage = 'host';
assert.equal(auditGraphicsQualification(JSON.stringify(record), expected, profiles).qualified, true);

/** 单字段反例必须丢失资格；同时要求错误路径匹配，防止以无关结构错误通过负控。 */
function reject(mutate, path) {
  const broken = structuredClone(record);
  mutate(broken);
  const result = auditGraphicsQualification(broken, expected, profiles);
  assert.equal(result.qualified, false);
  assert.ok(result.issues.some(item => item.path.startsWith(path)), JSON.stringify(result));
}
reject(item => item.implementation.sources[0].commit = 'b'.repeat(40), 'implementation');
reject(item => item.payload.libraries[0].sha256 = 'b'.repeat(64), 'payload');
reject(item => item.call.provider = 'SDL3', 'call'); // 同profile合法provider仍不可借另一provider证据。
reject(item => item.call.api = 'VULKAN', 'call');
reject(item => item.platform.driver = identity('Another GPU driver'), 'platform');
reject(item => item.test.version = 'old-runner', 'test');
reject(item => item.cases.pop(), 'cases');
reject(item => item.execution.pid = 1999, 'execution.pid');
reject(item => item.execution.runId = 'old-pid-reused-run', 'execution.runId');
reject(item => item.execution.logSha256 = 'b'.repeat(64), 'execution.logSha256');
reject(item => item.execution.startedAt = '2026-10-07T01:06:17+08:00', 'execution.startedAt');
reject(item => item.execution.finishedAt = '2026-10-08T01:06:24+08:00', 'execution.finishedAt');
reject(item => item.execution.termination = 'force-stop', 'execution.termination');
reject(item => item.execution.completed = false, 'execution.completed');
reject(item => item.execution.exitCode = 9, 'execution.termination');
reject(item => item.cases.push(structuredClone(item.cases[0])), 'cases');
reject(item => item.cases[0] = { id: 'presented', result: 'NOT_APPLICABLE', reason: 'Cannot omit core behavior', evidence: 'Fixture only' }, 'cases');
reject(item => delete item.platform, 'platform');
reject(item => item.stage = 'target-gpu', 'platform');
assert.equal(auditGraphicsQualification(JSON.stringify(record).slice(0, -12), expected, profiles).qualified, false);
assert.equal(auditGraphicsQualification(record, undefined, profiles).qualified, false);
assert.equal(auditGraphicsQualification(record, { requiredCases: {} }, profiles).qualified, false);
assert.equal(auditGraphicsQualification(null, expected, profiles).qualified, false);
// 缺失/污染的expected不能让audit抛异常或从自己的报告取得阳性。
for (const badExpected of [null, [], {}, { ...expected, execution: undefined },
  { ...expected, execution: null }, { ...expected, execution: 'not-a-process' },
  { ...expected, requiredCases: ['presented', 'presented'] },
  { ...expected, implementation: record.implementation }]) {
  assert.equal(auditGraphicsQualification(record, badExpected, profiles).qualified, false);
}
const selfExpected = { ...record, requiredCases: expected.requiredCases };
assert.equal(auditGraphicsQualification(selfExpected, selfExpected, profiles).qualified, false);
assert.equal(auditGraphicsQualification(record, expected, [null]).qualified, false);
assert.equal(auditGraphicsQualification(record, expected, [{ id: 'mobilegl', api: 'OPENGL', windowProviders: {} }]).qualified, false);
const brokenExecution = structuredClone(record); delete brokenExecution.execution;
assert.equal(auditGraphicsQualification(brokenExecution, expected, profiles).qualified, false);
for (const status of ['NOT_RUN', 'UNSUPPORTED', 'FAIL']) {
  const incomplete = structuredClone(record);
  incomplete.cases[0].result = status;
  incomplete.cases[0].reason = 'Explicit fixture negative verdict';
  const result = auditGraphicsQualification(incomplete, expected, profiles);
  assert.equal(result.valid, true);
  assert.equal(result.qualified, false);
  assert.equal(result.verdict, status);
}
// 实现缺失/未知即使case字段写PASS，也不能取得资格；结构状态仍可如实保存。
for (const [state, verdict] of [['missing', 'UNSUPPORTED'], ['unknown', 'NOT_RUN']]) {
  const unavailable = structuredClone(record); unavailable.implementationState = state;
  const result = auditGraphicsQualification(unavailable, expected, profiles);
  assert.equal(result.valid, true); assert.equal(result.qualified, false); assert.equal(result.verdict, verdict);
}
reject(item => item.implementationState = 'limited', 'implementationScope');
const limited = structuredClone(record); limited.implementationState = 'limited';
limited.implementationScope = { basis: 'Fixture covers the two scoped present obligations only',
  limitations: 'No GPU, context isolation or full OpenGL qualification', coveredCases: ['presented', 'deferred'] };
const scopedExpected = { ...expected, implementationScope: structuredClone(limited.implementationScope) };
assert.equal(auditGraphicsQualification(limited, scopedExpected, profiles).qualified, true);
limited.implementationScope.coveredCases.pop();
assert.equal(auditGraphicsQualification(limited, scopedExpected, profiles).qualified, false);
console.log('Graphics qualification PASS: full identity binding, mandatory verdicts, malformed/truncated reports, fresh PID/run and normal termination controls');
