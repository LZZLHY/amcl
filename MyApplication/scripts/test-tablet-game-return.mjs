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
// 派发和设置保存现经同一个惰性偏好 getter。使用 SDK AST 按真实成员边界提取，
// 保留 getter 的缓存及构造判据；各场景只把既有偏好端口放入真实缓存字段。
const indexAst = compiler.createSourceFile('Index.ets', index, compiler.ScriptTarget.Latest, true);
const indexComponent = indexAst.statements.find(node => node.members?.some(member => member.name?.getText(indexAst) === 'getPrefManager_'));
const prefGetter = indexComponent?.members.find(member => member.name?.getText(indexAst) === 'getPrefManager_');
assert.ok(prefGetter?.body, '必须提取生产偏好 getter，不能用夹具方法替代惰性访问');
const compiled = compiler.transpileModule('class Probe {\n' + prefGetter.getText(indexAst) + '\n' + index.slice(start, finish)
  + '\n}\nmodule.exports=Probe;', { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText;

for (const combination of [{ state: 0, desktop: false }, { state: 1, desktop: false },
  { state: 1, desktop: false, enabled: false }, { state: 0, desktop: true },
  { state: 0, desktop: false, ticketFailure: true }]) {
  let callback;
  let currentState = combination.state;
  const starts = [];
  const recoveryTickets = [];
  const intents = [];
  const module = { exports: {} };
  const values = { ProductInputProfile: { selection: () => ({ isolatedGameProcess: combination.enabled !== false, desktopWindow: combination.desktop }),
      canChooseTabletProcess: () => !combination.desktop },
    // default控制面没有商店门控；Host明确为空闲，保留原PID/锁状态组合的真实分支。
    getGameSessionHost: () => ({ isRunning: () => false }),
    GameRunAdmission: { assertToken() {}, installTicket() {} },
    // 系统UUID和父恢复登记是运输边界；冻结token并记录实际派发前的原活动身份。
    util: { generateRandomUUID: () => 'A1234567-1234-4123-8123-123456789ABC' },
    SessionRecoveryRuntime: { coordinator: () => ({ trackLaunch: async (activity, token) => intents.push({ activity, token }) }) },
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
  subject.prefManager_ = {};
  // 本回归观察可操作首页的启动/返回，开屏前输入门禁由启动专项验证。
  subject.startupFinished_ = true;
  subject.pendingRunAdmission_ = '';
  subject.graphicsPreferenceStamp_ = () => 'fixture-preference-stamp';
  subject.mcRoot = () => '/mc'; subject.mcVersion = '1.16.5'; subject.preLaunchGameDir = '/mc/game';
  subject.preLaunchJdkVersion = '8'; subject.preLaunchXmx = 1024;
  await subject.performLaunch();
  assert.equal(intents.length, combination.state === 0 ? 1 : 0);
  if (intents.length) {
    assert.equal(intents[0].activity, starts[0].parameters.activityId);
    assert.equal(intents[0].token, 'a1234567-1234-4123-8123-123456789abc');
  }
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
  subject.prefManager_ = { saveTabletIndependentGameProcess() {
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
// 正式商店与侧载均经过原游戏退出身份守卫；只有侧载产品消费更新恢复参数。
// 参数边界替身只记录真实调用，恢复结局仍由被抽取的生产onNewWant判定。
for (const storeChannel of [false, true]) for (const value of [55, 0, -1, '55', 1.5, undefined]) {
  const module = { exports: {} }; let recoveries = 0, updateRecoveries = 0, testWants = 0;
  const context = { filesDir: '/sandbox' };
  const want = { parameters: { gameExitActivityId: value,
    amclSideloadUpdateTransaction: 'fixture-transaction', amclSideloadUpdateNonce: 'fixture-nonce' } };
  const values = {
    isInputObservationTestWant: () => false,
    forwardInputObservationTestWant() { throw Error('ordinary game-return Want must not enter observation forwarding'); },
    runLogShareConnectivityWant() {}, AppLogger: { info() {} }, TAG: 'test', LOG_DOMAIN_LAUNCH: 1,
    AppStorage: { setOrCreate() {} }, ProductBuildProfile: { storeChannel },
    SideloadUpdateService: { get(actualContext) {
      assert.equal(actualContext, context);
      return { recover(id, nonce) { assert.equal(id, 'fixture-transaction'); assert.equal(nonce, 'fixture-nonce'); updateRecoveries++; } };
    } },
    // TestWant是受控诊断入口，本fixture仅验证热启动传入原context/want，不代替其内部许可测试。
    runSideloadUpdateTestWant(actualContext, actualWant) {
      assert.equal(actualContext, context); assert.equal(actualWant, want); testWants++;
    },
  };
  new Function('module', ...Object.keys(values), entryCompiled)(module, ...Object.values(values));
  const subject = new module.exports();
  subject.context = context;
  subject.consumeDesktopLaunchWant = () => {};
  subject.consumeNotificationWant = () => {};
  subject.extractImportUri = () => '';
  subject.recoverExitedGameSessions_ = () => { recoveries++; };
  subject.onNewWant(want, {});
  assert.equal(recoveries, value === 55 ? 1 : 0);
  assert.equal(updateRecoveries, storeChannel ? 0 : 1, '产品守卫必须实际隔离更新恢复');
  assert.equal(testWants, 1, '热启动传递真实Want到受控诊断边界');
}
console.log('PASS: production Entry return Want invokes the existing guarded recovery entry');
