/**
 * 账号管理重设计的非布局行为回归。
 *
 * 直接装载生产组件的字段、生命周期和动作，仅替换账号管理器及 UIContext 弹窗边缘。
 * 本轮没有大型夹具或后台进程，成功只保存调用者指定的 E 盘小收据；不替代 SDK 编译、
 * ArkUI Builder 的实际渲染或真机视觉验证。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { environment } from './lib/ets-runtime-fixture.mjs';
import { PROJECT_ROOT, assertExternalOutputPath, resolveWorkspacePath } from './lib/workspace-paths.mjs';

const SOURCE = 'entry/src/main/ets/components/AccountListSheet.ets';
const outputIndex = process.argv.indexOf('--output');
const output = assertExternalOutputPath(outputIndex < 0
  ? resolveWorkspacePath('run', 'account-list-ui') : process.argv[outputIndex + 1]);
const files = [SOURCE, 'scripts/test-account-list-ui.mjs'];
const hashes = () => Object.fromEntries(files.map(file => [file,
  createHash('sha256').update(fs.readFileSync(path.join(PROJECT_ROOT, file))).digest('hex')]));
const before = hashes();
const startedAt = new Date().toISOString();
const groups = [];
const pass = label => { groups.push(label); console.log('PASS ' + label); };
const deferred = () => { let resolve; const promise = new Promise(yes => { resolve = yes; }); return { promise, resolve }; };
const settle = async () => { for (let i = 0; i < 16; i++) await Promise.resolve(); };

/** 每个 fixture 独立持有延后凭据结果、账号集合和原生弹窗回调，不共用模块缓存。 */
function fixture(sourceOverrides, recovery) {
  const one = deferred(), two = deferred();
  const account = (id, usable) => ({ id, uuid: 'uuid-' + id, type: 'msa',
    getDisplayName: () => 'Player-' + id, getSkinUrl: () => null, getSkinVariant: () => null,
    getCapeUrl: () => null, getCapeAlias: () => null, isUsable: () => usable.promise,
    serialize: () => { throw new Error('查看身份不能序列化秘密'); } });
  const state = { selected: 'one', accounts: [account('one', one), account('two', two)],
    selectCalls: [], removals: [], dialogs: [], notifications: 0 };
  const manager = { isReady: () => true, list: () => [...state.accounts], getSelectedId: () => state.selected,
    getAvailableSelection: () => state.accounts.find(item => item.id === state.selected),
    get hasUnavailableAccounts() { return recovery !== undefined && !recovery.ready; },
    async reload(onlyUnavailable) {
      assert.equal(onlyUnavailable, true);
      await recovery.promise;
      recovery.ready = true;
      state.selected = 'two';
    },
    findById: id => state.accounts.find(item => item.id === id),
    select: async id => { state.selectCalls.push(id); state.selected = id; },
    remove: async id => { state.removals.push(id); state.accounts = state.accounts.filter(item => item.id !== id); } };
  const env = environment({ sourceOverrides,
    commons: { DeviceForm: { PHONE: 'phone' }, Breakpoint: { SM: 'sm' } },
    imports: { feature_core: { getTaskActivityOwner: () => ({ recordSummary: async () => {} }) },
      account: { getAccountManager: () => manager,
      AccountType: { OFFLINE: 'legacy', MICROSOFT: 'msa', AUTHLIB_INJECTOR: 'mojang' } } } });
  const Subject = env.load(SOURCE, true).AccountListSheet;
  const subject = new Subject();
  subject.getUIContext = () => ({ showAlertDialog: options => { state.dialogs.push(options); } });
  subject.onAccountsChanged = () => { state.notifications++; };
  subject.aboutToAppear();
  return { subject, state, one, two };
}

/** 先选新账号再返回旧凭据结果，旧结果不得把当前账号改成需要重新登录。 */
async function loginRace(sourceOverrides) {
  const f = fixture(sourceOverrides);
  await f.subject.selectAccount('two');
  f.two.resolve(true); await settle();
  assert.equal(f.subject.currentLoginState, 'usable');
  assert.equal(f.subject.loginStateText_(), '可自动登录');
  f.one.resolve(false); await settle();
  assert.equal(f.subject.currentId, 'two');
  assert.equal(f.subject.currentLoginState, 'usable');
  f.subject.aboutToDisappear();
}
// 持久索引首项暂不可读，页面上的唯一可用账号必须仍是一行可选择的账号。
{
  const { subject, state } = fixture();
  state.selected = '';
  state.accounts.splice(0, 1);
  subject.refresh();
  assert.equal(subject.currentAcc, null);
  assert.deepEqual(Array.from(subject.otherAccs, account => account.id), ['two']);
  await subject.selectAccount('two');
  assert.equal(subject.currentId, 'two');
  assert.deepEqual(state.selectCalls, ['two']);
  subject.aboutToDisappear();
}
await loginRace();
pass('迟到的本地凭据状态不能覆盖新账号，文案不伪称远端令牌有效');

{
  const recovery = deferred();
  const { subject, state } = fixture(undefined, recovery);
  assert.equal(subject.currentId, 'one');
  recovery.resolve(); await settle();
  assert.equal(subject.currentId, 'two');
  assert.equal(state.notifications, 1);
  subject.aboutToDisappear();
  pass('重开账号页后等待密钥恢复结果，并按重新读到的原选择同步首页');
}

await assert.rejects(() => loginRace({ [SOURCE]: source => source.replaceAll(
  'if (this.alive && epoch === this.loginStateEpoch && acc.id === this.currentId)', 'if (this.alive)') }),
assert.AssertionError);
pass('撤回凭据状态世代和身份屏障的负控会被真实组件断言识别');

{
  const { subject, one } = fixture();
  subject.aboutToDisappear();
  one.resolve(false); await settle();
  assert.equal(subject.currentLoginState, 'checking');
  pass('关闭后的本地凭据结果不再发布页面状态');
}

{
  const { subject, state } = fixture();
  subject.armDelete('one');
  assert.equal(state.removals.length, 0);
  const cancelled = state.dialogs.at(-1);
  cancelled.primaryButton.action(); cancelled.secondaryButton.action(); await settle();
  assert.deepEqual(state.removals, []);
  subject.armDelete('one');
  const replaced = state.dialogs.at(-1);
  subject.armDelete('one');
  const stale = state.dialogs.at(-1);
  replaced.secondaryButton.action(); await settle();
  assert.deepEqual(state.removals, [], '旧弹窗不能借用同账号的新确认世代');
  await subject.selectAccount('two');
  stale.secondaryButton.action(); await settle();
  assert.deepEqual(state.removals, []);
  subject.armDelete('one');
  const retired = state.dialogs.at(-1);
  subject.aboutToDisappear(); retired.secondaryButton.action(); await settle();
  assert.deepEqual(state.removals, []);
  pass('取消、切换账号及关闭后原删除确认均不能派发删除');
}

{
  const { subject, state } = fixture();
  subject.armDelete('one'); state.dialogs.at(-1).secondaryButton.action(); await settle();
  assert.deepEqual(state.removals, ['one']);
  assert.equal(state.notifications, 1);
  assert.equal(subject.accounts.length, 1);
  subject.aboutToDisappear();
  pass('明确第二次确认才进入原删除队列并通知父页面一次');
}

{
  const { subject, state } = fixture();
  subject.refreshingId = 'one';
  await subject.selectAccount('two');
  subject.armDelete('two');
  assert.deepEqual(state.selectCalls, []);
  assert.equal(state.dialogs.length, 0);
  subject.refreshingId = '';
  subject.showAccountInformation_();
  assert.match(state.dialogs.at(-1).message, /uuid-one/);
  assert.doesNotMatch(state.dialogs.at(-1).message, /token|encrypted|ciphertext/);
  subject.aboutToDisappear();
  pass('刷新忙态阻止切换和移除，完整身份查看不触碰账号秘密序列化');
}

/**
 * 登录刷新和角色切换使用独立延后门；生产方法本身控制互斥、持久化与页面发布。
 * 所有门都是内存Promise，fixture没有真实网络、计时器或需要回收的大文件。
 */
function operationFixture() {
  const state = { refreshCalls: 0, roleCalls: [], persistCalls: 0, notifications: 0,
    name: 'Player-one', refreshError: null, roleError: null, persistError: null,
    refreshGate: deferred(), roleGate: deferred(), persistGate: deferred() };
  const account = { id: 'one', uuid: 'uuid-one', type: 'mojang',
    getDisplayName: () => state.name, getSkinUrl: () => null, getSkinVariant: () => null,
    getCapeUrl: () => null, getCapeAlias: () => null, isUsable: async () => true,
    getServerName: () => 'Example', getAvailableProfiles: () => [],
    refresh: async () => {
      state.refreshCalls++; await state.refreshGate.promise;
      if (state.refreshError) throw state.refreshError;
      state.name = 'Refreshed';
    },
    switchProfile: async id => {
      state.roleCalls.push(id); await state.roleGate.promise;
      if (state.roleError) throw state.roleError;
      state.name = 'Switched';
    } };
  const manager = { isReady: () => true, list: () => [account], getSelectedId: () => 'one', getAvailableSelection: () => account,
    persistOne: async () => {
      state.persistCalls++; await state.persistGate.promise;
      if (state.persistError) throw state.persistError;
    } };
  const env = environment({ commons: { DeviceForm: { PHONE: 'phone' }, Breakpoint: { SM: 'sm' } },
    imports: { feature_core: { getTaskActivityOwner: () => ({ recordSummary: async () => {} }) },
      account: { getAccountManager: () => manager,
      AccountType: { OFFLINE: 'legacy', MICROSOFT: 'msa', AUTHLIB_INJECTOR: 'mojang' } } } });
  const Subject = env.load(SOURCE, true).AccountListSheet;
  const subject = new Subject();
  subject.onAccountsChanged = () => { state.notifications++; };
  subject.aboutToAppear();
  return { subject, state, account, env };
}

{
  const { subject, state, account } = operationFixture();
  const refreshing = subject.refreshAccount(account);
  const rejectedRole = subject.switchToProfile('profile-two'); await settle();
  assert.deepEqual(state.roleCalls, [], '刷新期间排队的角色点击不能进入服务');
  await rejectedRole;
  state.refreshGate.resolve(); state.persistGate.resolve(); await refreshing;
  assert.equal(state.notifications, 1);
  assert.equal(subject.refreshingId, '');
  const switching = subject.switchToProfile('profile-two');
  const rejectedRefresh = subject.refreshAccount(account); await settle();
  assert.equal(state.refreshCalls, 1, '角色切换期间排队的刷新点击不能进入服务');
  await rejectedRefresh;
  state.roleGate.resolve(); await switching;
  assert.equal(state.notifications, 2);
  assert.equal(subject.switchingProfileId, '');
  subject.aboutToDisappear();
  pass('登录刷新与角色切换共享busy屏障，互相排队的旧点击均被拒绝');
}

for (const kind of ['refresh', 'role']) {
  const { subject, state, account } = operationFixture();
  await settle();
  const pending = kind === 'refresh' ? subject.refreshAccount(account) : subject.switchToProfile('profile-two');
  const gate = kind === 'refresh' ? state.refreshGate : state.roleGate;
  gate.resolve(); await settle();
  assert.equal(state.persistCalls, 1);
  subject.aboutToDisappear();
  const snapshot = { name: subject.currentName, error: subject.refreshErrorMsg,
    refreshing: subject.refreshingId, switching: subject.switchingProfileId };
  state.persistGate.resolve(); await pending;
  assert.deepEqual({ name: subject.currentName, error: subject.refreshErrorMsg,
    refreshing: subject.refreshingId, switching: subject.switchingProfileId }, snapshot);
  assert.equal(state.notifications, 1, '持久化已确认，退休页面仍须通知原父owner');
  await subject.refreshAccount(account); await subject.switchToProfile('profile-three');
  assert.equal(state.refreshCalls, kind === 'refresh' ? 1 : 0);
  assert.equal(state.roleCalls.length, kind === 'role' ? 1 : 0);
}
pass('刷新和角色保存完成时退休页不发布本地状态，但各通知父owner一次');

for (const kind of ['refresh', 'role']) {
  const { subject, state, account } = operationFixture();
  await settle();
  const pending = kind === 'refresh' ? subject.refreshAccount(account) : subject.switchToProfile('profile-two');
  subject.currentId = 'two'; subject.currentName = 'Other player';
  const gate = kind === 'refresh' ? state.refreshGate : state.roleGate;
  gate.resolve(); state.persistGate.resolve(); await pending;
  assert.equal(subject.currentName, 'Other player');
  assert.equal(state.notifications, 1);
  subject.aboutToDisappear();
}
pass('异步操作对象已变化时不重读覆盖新身份，仍通知已确认持久化结果');

{
  const { subject, state, account, env } = operationFixture();
  state.refreshError = new Error('same failure');
  const first = subject.refreshAccount(account); state.refreshGate.resolve(); await first;
  const oldTimer = [...env.timer.values()][0].fn;
  const second = subject.refreshAccount(account); await second;
  assert.equal(subject.refreshErrorMsg, '刷新失败：same failure');
  oldTimer();
  assert.equal(subject.refreshErrorMsg, '刷新失败：same failure', '上一轮同名错误计时器不能清除新错误');
  const currentTimer = [...env.timer.values()].at(-1).fn;
  subject.aboutToDisappear(); currentTimer();
  assert.equal(subject.refreshErrorMsg, '刷新失败：same failure', '退休后计时器不能写本地状态');
  pass('错误计时器按操作世代及页面存活围栏，旧同名错误不误清新错误');
}

{
  const { subject, state, account } = operationFixture();
  state.persistError = new Error('disk rejected');
  const pending = subject.refreshAccount(account);
  state.refreshGate.resolve(); state.persistGate.resolve(); await pending;
  assert.equal(state.notifications, 0);
  assert.match(subject.refreshErrorMsg, /刷新失败：disk rejected/);
  assert.equal(subject.refreshingId, '');
  subject.aboutToDisappear();
  pass('刷新凭据持久化失败不广播成功，原页面显示失败并释放忙态');
}

assert.deepEqual(hashes(), before, '运行期间源码保持稳定');
fs.mkdirSync(output, { recursive: true });
fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify({ schemaVersion: 1, startedAt,
  completedAt: new Date().toISOString(), status: 'PASS', groups, sourceHashes: before,
  limitations: ['未执行ArkUI Builder', '未执行SDK编译或设备视觉验证'] }, null, 2) + '\n');
console.log('PASS account list UI host regressions; receipt=' + path.join(output, 'receipt.json'));
