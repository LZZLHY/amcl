/** 执行真实 McGamePage 退出方法，验证前台归还窗口先于 native ACK，不碰设备/JVM。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';

const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/McGamePage.ets', import.meta.url), 'utf8');
const match = source.match(/  private (?:async )?doExit\([^)]*\)(?:[^\{]*)\{/);
assert.ok(match);
const start = match.index;
const end = source.indexOf('\n  /**', start + match[0].length);
assert.ok(end > start);
const compiled = compiler.transpileModule('class Probe {\n' + source.slice(start, end)
  + '\n}\nmodule.exports=Probe;', { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText;

function fixture(isolated, behavior = 'resolve', forceError = false) {
  const events = [];
  let finish, reject;
  const deferred = new Promise((resolve, fail) => { finish = resolve; reject = fail; });
  const module = { exports: {} };
  new Function('module', 'AppStorage', 'testNapi', 'appRecovery', 'TAG', 'LOG_DOMAIN_LAUNCH', compiled)(
    module, { get: key => key === 'desktopGameProcess' && isolated },
    { mcForceExit: () => { events.push('ack'); if (forceError) throw new Error('ack failure'); } },
    { restartApp: () => events.push('restart') }, 'test', 1);
  const subject = new module.exports();
  subject.navigatedAway = false;
  subject.launchStartedAt_ = 55;
  // 图形失败协议由独立生产行为测试覆盖，此处只验证终局的前台交还与 ACK 顺序。
  subject.pollGraphicsFailure_ = () => {};
  subject.collectGraphicsMetrics_ = () => {};
  subject.launchLogger_ = () => ({ info() {}, warn: (_tag, text) => events.push('warn:' + text) });
  subject.context = { startAbility: want => {
    events.push(want);
    if (behavior === 'throw') throw new Error('start failure');
    if (behavior === 'reject') return Promise.reject(new Error('permission denied'));
    if (behavior === 'defer') return deferred;
    return Promise.resolve();
  } };
  return { subject, events, finish, reject };
}

{
  const f = fixture(true, 'defer');
  const pending = f.subject.doExit();
  assert.equal(typeof pending?.then, 'function');
  assert.equal(f.events[0].abilityName, 'EntryAbility');
  assert.equal(f.events[0].parameters.gameExitActivityId, 55);
  assert.equal(f.events.includes('ack'), false, '窗口交还完成前不能提前ACK杀死前台调用者');
  await f.subject.doExit();
  assert.equal(f.events.length, 1, '重复请求不能再次发起前台切换或提前ACK');
  f.finish(); await pending;
  assert.equal(f.events.filter(event => event === 'ack').length, 1);
  assert.equal(f.events.includes('restart'), false);
}
for (const mode of ['resolve', 'reject', 'throw']) {
  const f = fixture(true, mode);
  await f.subject.doExit();
  assert.equal(f.events.filter(event => event === 'ack').length, 1, mode);
  assert.equal(f.events.includes('restart'), false, mode);
  if (mode !== 'resolve') assert.ok(f.events.some(event => typeof event === 'string' && event.startsWith('warn:')));
}
{
  const f = fixture(true, 'resolve', true);
  await assert.doesNotReject(() => f.subject.doExit());
  assert.equal(f.events.includes('restart'), false);
}
{
  const f = fixture(false);
  await f.subject.doExit();
  assert.deepEqual(f.events, ['ack', 'restart'], '非隔离保留旧退出兜底，不请求另一个Entry');
}
assert.match(source, /private requestExit_\(\): void[\s\S]*?this\.doExit\(\)\.catch/);
assert.equal((source.match(/this\.requestExit_\(\)/g) ?? []).length, 4, '按钮、既有轮询和同步/异步图形失败均经过Promise兜底');
console.log('PASS: foreground Entry handoff before ACK; async failure/duplicate handling; shared-process behavior retained');
