/** 验证真实 preflight 调度器拒绝坏选择、执行依赖并准确区分失败与未执行。 */
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parsePreflightArguments, planPreflightChecks, preflightPlanReceipt, executePreflightPlan } from './lib/preflight-runner.mjs';

const pass = () => ({ ok: true, summary: 'executed' });
const gate = (id, fn = pass, dependencies = []) => ({ id, fn, dependencies });
const rejectsCode = (fn, code) => assert.throws(fn, error => error.code === code);

test('参数只接受明确接口；错名、空值、重复与冲突不能静默退化', () => {
  assert.deepEqual(parsePreflightArguments(['--only=java-tests,lf-eol', '--json', '--report', '/outside/result.json']),
    { only: ['java-tests', 'lf-eol'], skip: [], json: true, report: '/outside/result.json', plan: false, help: false });
  for (const [args, code] of [
    [['--strict'], 'UNKNOWN_ARGUMENT'], [['lf-eol'], 'UNKNOWN_ARGUMENT'],
    [['--only='], 'MISSING_VALUE'], [['--only=a,'], 'EMPTY_SELECTOR'],
    [['--only=a,a'], 'DUPLICATE_SELECTOR'], [['--json=true'], 'UNEXPECTED_VALUE'],
    [['--only=a', '--only=b'], 'DUPLICATE_OPTION'], [['--only=a', '--skip=b'], 'CONFLICTING_SELECTORS'],
    [['--report'], 'MISSING_VALUE'],
  ]) rejectsCode(() => parsePreflightArguments(args), code);
});

test('未知 only/skip 与排除全部检查均在调用任何执行器前拒绝', () => {
  let calls = 0;
  const checks = [gate('one', () => { calls++; return pass(); })];
  rejectsCode(() => planPreflightChecks(checks, { only: ['typo'] }), 'UNKNOWN_GATE');
  rejectsCode(() => planPreflightChecks(checks, { skip: ['typo'] }), 'UNKNOWN_GATE');
  rejectsCode(() => planPreflightChecks(checks, { skip: ['one'] }), 'EMPTY_SELECTION');
  rejectsCode(() => planPreflightChecks(checks, { only: [] }), 'EMPTY_SELECTOR');
  assert.equal(calls, 0);
});

test('注册表错误和循环不能被选择别的门隐藏', () => {
  rejectsCode(() => planPreflightChecks([]), 'EMPTY_REGISTRY');
  rejectsCode(() => planPreflightChecks([gate('one'), gate('one')]), 'DUPLICATE_GATE');
  rejectsCode(() => planPreflightChecks([gate('safe'), gate('broken', pass, ['missing'])], { only: ['safe'] }), 'MISSING_DEPENDENCY');
  rejectsCode(() => planPreflightChecks([gate('safe'), gate('one', pass, ['two']), gate('two', pass, ['one'])], { only: ['safe'] }), 'DEPENDENCY_CYCLE');
});

test('java-tests 选择补齐 java-build，并为收据记录补入原因', async () => {
  const trace = [];
  const checks = [gate('unrelated'), gate('java-tests', () => { trace.push('test'); return pass(); }, ['java-build']),
    gate('java-build', () => { trace.push('build'); return pass(); })];
  const plan = planPreflightChecks(checks, { only: ['java-tests'] });
  assert.deepEqual(plan.selectedIds, ['java-build', 'java-tests']);
  assert.deepEqual(plan.dependencyAddedIds, ['java-build']);
  const result = await executePreflightPlan(plan);
  assert.deepEqual(trace, ['build', 'test']);
  assert.equal(result.status, 'PARTIAL_PASS');
  assert.equal(result.coverage.complete, false);
  assert.deepEqual(result.coverage.deferredIds, ['unrelated']);
  assert.equal(result.checks.find(row => row.id === 'java-build').selectionReason, 'dependency');
});

test('显式跳过仍被需要的依赖会失败；默认成功路径保留原注册执行顺序', async () => {
  const trace = [];
  const checks = [gate('java-build', () => { trace.push('build'); return pass(); }),
    gate('java-tests', () => { trace.push('test'); return pass(); }, ['java-build']),
    gate('independent', () => { trace.push('independent'); return pass(); })];
  rejectsCode(() => planPreflightChecks(checks, { skip: ['java-build'] }), 'SKIPPED_DEPENDENCY');
  const result = await executePreflightPlan(planPreflightChecks(checks));
  assert.deepEqual(trace, ['build', 'test', 'independent']);
  assert.equal(result.status, 'PASS');
  assert.equal(result.coverage.complete, true);
});

test('计划不调用执行器，也不产生 PASS 或已执行资格', () => {
  let calls = 0;
  const receipt = preflightPlanReceipt(planPreflightChecks([gate('one', () => { calls++; return pass(); })]));
  assert.equal(calls, 0);
  assert.equal(receipt.status, 'PLANNED');
  assert.equal(receipt.ok, null);
  assert.equal(receipt.coverage.complete, false);
  assert.deepEqual(receipt.coverage.executedIds, []);
  assert.deepEqual(receipt.coverage.passedIds, []);
  assert.equal(receipt.checks[0].status, 'PLANNED');
});

test('依赖失败后不调用依赖方，仍执行无关检查并记录完整失败覆盖', async () => {
  const trace = [];
  const result = await executePreflightPlan(planPreflightChecks([
    gate('build', () => { trace.push('build'); return { ok: false, summary: 'compile failed' }; }),
    gate('test', () => { trace.push('test'); return pass(); }, ['build']),
    gate('independent', () => { trace.push('independent'); return pass(); }),
  ]));
  assert.deepEqual(trace, ['build', 'independent']);
  assert.equal(result.ok, false);
  assert.equal(result.status, 'FAILED');
  assert.deepEqual(result.coverage.failedIds, ['build']);
  assert.deepEqual(result.coverage.blockedIds, ['test']);
  assert.deepEqual(result.checks[1].blockedBy, ['build']);
  assert.equal(result.checks[1].executed, false);
});

test('缺工具 SKIPPED 即使返回 ok:true 也不能冒充 PASS 或解除依赖阻断', async () => {
  let dependentRan = false;
  const result = await executePreflightPlan(planPreflightChecks([
    gate('tool', () => ({ status: 'SKIPPED', ok: true, reason: 'MISSING_TOOL', missingTools: ['bash'], summary: 'not executed' })),
    gate('consumer', () => { dependentRan = true; return pass(); }, ['tool']),
  ]));
  assert.equal(dependentRan, false);
  assert.equal(result.status, 'FAILED');
  assert.deepEqual(result.coverage.passedIds, []);
  assert.deepEqual(result.coverage.skippedIds, ['tool']);
  assert.deepEqual(result.coverage.blockedIds, ['consumer']);
  assert.equal(result.checks[0].attempted, true);
  assert.equal(result.checks[0].executed, false);
  assert.deepEqual(result.coverage.executedIds, []);
});

test('异常、空结果与矛盾结果都留下 FAIL，不让后续独立门消失', async () => {
  const result = await executePreflightPlan(planPreflightChecks([
    gate('throws', () => { throw new Error('fixture exception'); }), gate('empty', () => undefined),
    gate('contradictory', () => ({ status: 'PASS', ok: false })), gate('independent'),
  ]));
  assert.equal(result.status, 'FAILED');
  assert.deepEqual(result.coverage.failedIds, ['throws', 'empty', 'contradictory']);
  assert.deepEqual(result.coverage.passedIds, ['independent']);
  assert.equal(result.checks[0].reason, 'EXCEPTION');
});

test('收据记录逐门时长、时间与依赖，能够无丢失地序列化为 JSON', async () => {
  let elapsed = 0;
  let ticks = 0;
  const result = await executePreflightPlan(planPreflightChecks([gate('first'), gate('second', async () => pass(), ['first'])]),
    { clock: () => elapsed += 7, now: () => new Date(1700000000000 + ticks++).toISOString() });
  assert.ok(result.durationMs >= result.checks.reduce((sum, row) => sum + row.durationMs, 0));
  assert.ok(result.checks.every(row => row.durationMs > 0 && row.startedAt < row.finishedAt));
  assert.deepEqual(result.checks[1].dependencies, ['first']);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), result);
});
