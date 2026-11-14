/**
 * 在线外观改版的账号命令回归。
 *
 * 装载实际生产组件的方法，仅替换Mojang/账号落库等外部边缘；不运行ArkUI布局。
 * 重点验证老记录只有当前披风URL时不会误判“不佩戴”，以及同步/切换互斥、
 * 明确持久化成功后才通知父页面、第三方不会调用微软同步。
 * 本测试只产生外置的小型收据，不创建可再生的大型夹具。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { environment } from './lib/ets-runtime-fixture.mjs';
import { assertExternalOutputPath, resolveWorkspacePath } from './lib/workspace-paths.mjs';

const arg = process.argv.indexOf('--output');
const output = assertExternalOutputPath(arg < 0
  ? resolveWorkspacePath('run', 'online-account-appearance') : process.argv[arg + 1]);
fs.mkdirSync(output, { recursive: true });
const file = 'entry/src/main/ets/components/SkinCapeDetailSheet.ets';
const groups = [];
const pass = name => { groups.push(name); console.log('PASS ' + name); };
const deferred = () => {
  let resolve;
  const promise = new Promise(accept => { resolve = accept; });
  return { promise, resolve };
};

/** 每组使用独立的生产组件和平台边缘，避免计时器或异步状态在用例间互相污染。 */
function fixture(type = 'msa') {
  const state = { capeUrl: 'https://textures.example/current', owned: [], writes: [],
    syncs: 0, persisted: 0, notified: 0, barrier: null, summaries: [] };
  const account = {
    id: 'account-one', uuid: '11111111-1111-1111-1111-111111111111', type,
    getDisplayName: () => 'Player', getOwnedCapes: () => state.owned,
    getSkinUrl: () => '', getSkinVariant: () => 'CLASSIC',
    getCapeUrl: () => state.capeUrl, getCapeAlias: () => 'Cached cape',
    async setActiveCape(id) {
      state.writes.push(id);
      if (state.barrier) await state.barrier.promise;
      state.capeUrl = id === null ? '' : 'https://textures.example/' + id;
      state.owned = id === null ? [] : [{ id, url: state.capeUrl, alias: id, isActive: true }];
    },
    async syncProfile() { state.syncs++; if (state.barrier) await state.barrier.promise; },
  };
  class AccountError extends Error {}
  const manager = { async persistOne() { state.persisted++; } };
  const env = environment({
    commons: { DiagnosticPolicy: { isDeveloperBuild: () => false } },
    imports: { feature_core: { getTaskActivityOwner: () => ({ recordSummary: async (...args) => { state.summaries.push(args); } }) },
      account: { AccountType: { OFFLINE: 'legacy', MICROSOFT: 'msa', AUTHLIB_INJECTOR: 'authlib' },
      AccountError, getAccountManager: () => manager } },
    globals: { RenderingContextSettings: class {}, CanvasRenderingContext2D: class {} },
  });
  const Subject = env.load(file, true).SkinCapeDetailSheet;
  const subject = new Subject();
  subject.account = account;
  subject.onChanged = () => { state.notified++; };
  subject.aboutToAppear();
  return { subject, account, state };
}

{
  const { subject, account, state } = fixture();
  assert.equal(subject.activeCapeId, '');
  assert.equal(subject.isNoCapeSelected(), false, '已知当前纹理但缺拥有列表，不能误判为未佩戴');
  await subject.applyCape(account, null);
  assert.deepEqual(state.writes, [null]);
  assert.equal(state.persisted, 1);
  assert.equal(state.notified, 1);
  assert.deepEqual(state.summaries.map(args => args.slice(0, 3)), [['skin', '切换披风', 'success']]);
  assert.equal(subject.isNoCapeSelected(), true);
  pass('旧披风缓存不误选不佩戴，明确脱下后持久化并通知');
}
{
  const { subject, account, state } = fixture();
  const barrier = deferred(); state.barrier = barrier;
  const switching = subject.applyCape(account, 'owned-one');
  await subject.syncProfileNow();
  await subject.applyCape(account, null);
  assert.deepEqual(state.writes, ['owned-one']);
  assert.equal(state.syncs, 0);
  assert.equal(state.persisted, 0);
  assert.equal(state.notified, 0);
  barrier.resolve(); await switching;
  assert.equal(subject.activeCapeId, 'owned-one');
  assert.equal(state.persisted, 1);
  assert.equal(state.notified, 1);
  pass('切换等待期间拒绝重复切换和同步，确认前不广播');
}
{
  const { subject, account, state } = fixture();
  const barrier = deferred(); state.barrier = barrier;
  const syncing = subject.syncProfileNow();
  await subject.applyCape(account, null);
  assert.deepEqual(state.writes, []);
  barrier.resolve(); await syncing;
  assert.equal(state.syncs, 1);
  assert.equal(state.persisted, 1);
  pass('同步等待期间不允许披风写命令交错');
}
{
  const { subject, state } = fixture('authlib');
  assert.equal(subject.canSync(), false);
  await subject.syncProfileNow();
  assert.equal(state.syncs, 0);
  assert.equal(state.persisted, 0);
  pass('第三方外观不进入微软同步与落库');
}

{
  const { subject, account, state } = fixture();
  const barrier = deferred(); state.barrier = barrier;
  const switching = subject.applyCape(account, 'late-cape');
  subject.aboutToDisappear();
  barrier.resolve(); await switching;
  assert.equal(state.persisted, 1, '已完成的远端修改仍须确认落库');
  assert.equal(state.notified, 1, '父owner仍需重读已确认的账号');
  assert.equal(subject.activeCapeId, '', '退役页面不发布新快照');
  assert.equal(subject.capeSuccessMsg, '', '退役页面不弹成功消息');
  subject.aboutToAppear();
  assert.equal(subject.activeCapeId, 'late-cape', '重新打开从确认账号恢复');
  pass('关闭期间已提交操作仍落库通知，退役页面不再发布状态');
}

fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify({
  at: new Date().toISOString(), source: file, groups, passed: true,
  boundary: 'production commands only; not ArkUI rendering or device validation',
}, null, 2) + '\n');
