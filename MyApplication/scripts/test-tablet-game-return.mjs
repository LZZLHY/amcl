/** 平板派发/返回控制面和活动行更新的宿主回归；不把 AbilityResult 当 JVM 退出码。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';

const index = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const start = index.indexOf('  private desktopPreparing: boolean = false');
const end = index.indexOf('\n  /**\n   * 统一跳转', start);
// 源文件可能使用 CRLF，边界按原始位置定位而非重写生产代码。
const endCrLf = index.indexOf('\r\n  /**\r\n   * 统一跳转', start);
const finish = end > start ? end : endCrLf;
assert.ok(start > 0 && finish > start);
const compiled = compiler.transpileModule('class Probe {\n' + index.slice(start, finish)
  + '\n}\nmodule.exports=Probe;', { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText;

for (const combination of [{ state: 0, desktop: false }, { state: 1, desktop: false },
  { state: 1, desktop: false, enabled: false }, { state: 0, desktop: true },
  { state: 0, desktop: false, ticketFailure: true }]) {
  let callback;
  let currentState = combination.state;
  const starts = [];
  const recoveryTickets = [];
  const module = { exports: {} };
  const values = { ProductInputProfile: { selection: () => ({ isolatedGameProcess: combination.enabled !== false, desktopWindow: combination.desktop }),
      canChooseTabletProcess: () => !combination.desktop },
    GameLayoutJournal: { importPending: async () => ({ imported: 0, pending: 0, deferred: false, conflicts: [] }) },
    DesktopLaunchSnapshot: { pending: () => false, prepare: async () => ({ id: 'snapshot', account: 'account' }), discard() {} },
    GraphicsRecoveryStore: { create: (_files, ticket) => {
      recoveryTickets.push(ticket); if (combination.ticketFailure) throw Error('injected ticket write failure');
    } },
    testNapi: { desktopProcessId: () => 100, desktopGameProcessState: () => {
      if (currentState === 'throw') throw new Error('lock query failed'); return currentState;
    } },
    AppLogger: { info() {}, warn() {}, error() {} }, TAG: 'test', LOG_DOMAIN_LAUNCH: 1,
    AppStorage: { setOrCreate() {} } };
  new Function('module', ...Object.keys(values), compiled)(module, ...Object.values(values));
  const subject = new module.exports();
  subject.context = { filesDir: '/sandbox', startAbility: async want => { starts.push(want); },
    startAbilityForResult: (want, fn) => { callback = fn; starts.push({ ...want, mode: 'for-result' }); } };
  subject.prefManager = {};
  subject.graphicsPreferenceStamp_ = () => 'fixture-preference-stamp';
  subject.mcRoot = () => '/mc'; subject.mcVersion = '1.16.5'; subject.preLaunchGameDir = '/mc/game';
  subject.preLaunchJdkVersion = '8'; subject.preLaunchXmx = 1024;
  await subject.performLaunch();
  assert.equal(subject.desktopPreparing, false, '派发不能等待游戏终局才释放准备态');
  assert.equal(recoveryTickets.length, combination.state === 0 ? 1 : 0);
  if (recoveryTickets.length) {
    assert.equal(recoveryTickets[0].attempt, 0);
    assert.equal(recoveryTickets[0].parentPid, 100);
    assert.equal(recoveryTickets[0].preferenceStamp, 'fixture-preference-stamp');
  }
  if (combination.ticketFailure) {
    assert.equal(subject.pendingGraphicsRecoveryId_, '', '可选恢复不可用仍须正常派发首次启动');
    const startCount = starts.length;
    await assert.rejects(() => subject.performLaunch({ rootActivityId: 100, attempt: 1, profile: 'mobileglues' }),
      /injected ticket write/, '重试票据丢失必须拒绝，不能重选原自动后端');
    assert.equal(starts.length, startCount);
  }
  if (combination.state === 0 && !combination.desktop) {
    assert.equal(typeof callback, 'function', '真正新建平板游戏必须登记结果callback');
    assert.equal(starts[0].mode, 'for-result');
    callback({ code: 0 }, { resultCode: -1 });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(starts[1].abilityName, 'EntryAbility');
    assert.equal(starts[1].parameters.gameExitActivityId, starts[0].parameters.activityId);
    for (const blocked of [1, -1, -2, -3, 'throw']) {
      currentState = blocked;
      callback({ code: 0 }, { resultCode: -1 });
      await new Promise(resolve => setImmediate(resolve));
      assert.equal(starts.length, 2, '锁活跃或查询不可靠时，不因旧回调抢前台：' + blocked);
    }
  } else {
    assert.equal(callback, undefined, '桌面和聚焦既有游戏仍用普通startAbility');
    assert.equal(starts[0].abilityName, 'GameAbility');
  }
}
console.log('PASS: production tablet dispatch returns immediately; result callback requests host, never classifies JVM outcome');

// 真实保存方法不改变当前路线，必须等到持久化确认；并发点击和失败不可留下假“已保存”。
{
  let resolveSave, rejectSave, saves = 0;
  const module = { exports: {} };
  const values = { ProductInputProfile: { canChooseTabletProcess: () => true },
    AppLogger: { warn() {} }, TAG: 'test', LOG_DOMAIN_LAUNCH: 1 };
  new Function('module', ...Object.keys(values), compiled)(module, ...Object.values(values));
  const subject = new module.exports();
  subject.tabletIndependentGameProcess = true;
  subject.prefManager = { saveTabletIndependentGameProcess() {
    saves++;
    return new Promise((resolve, reject) => { resolveSave = resolve; rejectSave = reject; });
  } };
  const first = subject.changeTabletProcess_(false);
  assert.equal(subject.tabletProcessSaving, true);
  await subject.changeTabletProcess_(true);
  assert.equal(saves, 1);
  rejectSave(new Error('disk failure'));
  await first;
  assert.equal(subject.tabletIndependentGameProcess, true);
  assert.equal(subject.tabletProcessSaving, false);
  assert.match(subject.tabletProcessMessage, /保存失败/);
  const second = subject.changeTabletProcess_(false);
  resolveSave();
  await second;
  assert.equal(subject.tabletIndependentGameProcess, false);
  assert.match(subject.tabletProcessMessage, /重启启动器/);
}
console.log('PASS: setting persistence waits, concurrent saves excluded, failures restore visible choice');

const home = fs.readFileSync(new URL('../entry/src/main/ets/pages/tabs/HomeTab.ets', import.meta.url), 'utf8');
const keys = [...home.matchAll(/\(rec: ActivityRecord, idx: number\) => ([^\r\n]+)\)/g)];
assert.equal(keys.length, 2, '横竖屏各一条最近活动ForEach');
for (const match of keys) {
  const key = new Function('rec', 'idx', 'return ' + match[1]);
  assert.notEqual(key({ startedAt: 55, status: 'aborted' }, 0), key({ startedAt: 55, status: 'success' }, 0),
    '同一活动从RUNNING回退显示取消后，终态成功必须更新builder身份');
  assert.notEqual(key({ startedAt: 55, status: 'success' }, 0), key({ startedAt: 55, status: 'crashed' }, 0));
}
console.log('PASS: both production activity row keys change for canceled/success/crashed transitions');

// 确认返回 Want 接上 Entry 的同一恢复入口；参数只用于唤醒，不传递成功/失败结局。
const entry = fs.readFileSync(new URL('../entry/src/main/ets/entryability/EntryAbility.ets', import.meta.url), 'utf8');
const entryStart = entry.indexOf('  onNewWant(want: Want,');
const entryEnd = entry.indexOf('\n  /**', entryStart);
assert.ok(entryStart > 0 && entryEnd > entryStart);
const entryCompiled = compiler.transpileModule('class Probe {\n' + entry.slice(entryStart, entryEnd)
  + '\n}\nmodule.exports=Probe;', { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText;
for (const value of [55, 0, -1, '55', 1.5, undefined]) {
  const module = { exports: {} }; let recoveries = 0;
  new Function('module', 'runLogShareConnectivityWant', 'AppLogger', 'TAG', 'LOG_DOMAIN_LAUNCH', 'AppStorage', entryCompiled)(
    module, () => {}, { info() {} }, 'test', 1, { setOrCreate() {} });
  const subject = new module.exports();
  subject.consumeDesktopLaunchWant = () => {};
  subject.consumeNotificationWant = () => {};
  subject.extractImportUri = () => '';
  subject.recoverExitedGameSessions_ = () => { recoveries++; };
  subject.onNewWant({ parameters: { gameExitActivityId: value } }, {});
  assert.equal(recoveries, value === 55 ? 1 : 0);
}
console.log('PASS: production Entry return Want invokes the existing guarded recovery entry');
