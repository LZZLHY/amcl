/** 直接执行生产 LayoutStore；只替代显示/偏好持久层，验证编辑 lease、串行提交和失败恢复。 */
import assert from 'node:assert/strict';
import test from 'node:test';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

function fixture() {
  const data = new Map([['profiles', ''], ['active_profile', '']]);
  let failures = 0, release, hold = false;
  const writes = [];
  const gate = new Promise(resolve => { release = resolve; });
  const pref = { get: async (key, fallback) => data.get(key) ?? fallback,
    getSync: (key, fallback) => data.get(key) ?? fallback,
    put: async (key, value) => { writes.push([key, value]); data.set(key, value); },
    // 该用例验证一次保存失败、随后回滚可确认的可重试路径；保存和回滚都失败的
    // 冷启动封锁边界由 transport 的独立用例覆盖，不能混为同一种恢复语义。
    flush: async () => {
      if (hold) await gate;
      if (failures > 0) { failures--; throw new Error('synthetic save failure'); }
    } };
  const deps = {
    'commons': { AppLogger: { error() {}, warn() {}, info() {} },
      ProcessPreferences: { open: () => pref, isGameProcess: () => false },
      utf8ByteLength: text => Buffer.byteLength(text),
    },
    '@kit.AbilityKit': {}, '@kit.CoreFileKit': { fileIo: {} }, '@kit.ArkTS': { util: {} },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {}, warn() {} } },
    '@kit.ArkUI': { display: { getDefaultDisplaySync: () => ({ width: 2400, height: 1600, densityPixels: 2 }) } },
    '@kit.BasicServicesKit': { deviceInfo: { marketName: 'test tablet' } },
  };
  const load = makePureEtsLoader(deps);
  Object.assign(deps.commons, load('commons/src/main/ets/utils/PreferenceSnapshot.ets'));
  const store = new (load('gamecontrol/src/main/ets/LayoutStore.ets').LayoutStore)();
  return { store, data, writes, load, failNextFlush: () => { failures = 1; },
    hold: () => { hold = true; }, release: () => { hold = false; release(); } };
}

test('真实编辑lease与普通mutation快照分离，嵌套lease不会重置编辑基线', async () => {
  const f = fixture(); await f.store.init({});
  const initial = f.store.getActiveProfile().name;
  const standalone = await f.store.cloneAsUser(initial);
  assert.equal(f.store.isEditorActive(), false, '普通mutation的snapshot不代表编辑页打开');
  assert.equal(f.store.beginEditorSession(), true);
  assert.equal(f.store.beginEditorSession(), true);
  const editing = await f.store.cloneAsUser(standalone.name);
  assert.notEqual(editing.name, standalone.name);
  assert.equal(await f.store.restoreEditorTransaction(), true);
  assert.equal(f.store.getActiveProfile().name, standalone.name, '取消不回滚到旧普通mutation之前');
  f.store.endEditorSession(); assert.equal(f.store.isEditorActive(), true);
  f.store.endEditorSession(); assert.equal(f.store.isEditorActive(), false);
});

test('保存失败恢复最后确认的布局/活跃方案，真实编辑原始快照保留用于重试', async () => {
  const f = fixture(); await f.store.init({});
  const before = JSON.stringify(f.store.getAllProfiles());
  const active = f.store.getActiveProfile().name;
  f.store.beginEditorSession(); f.failNextFlush();
  await assert.rejects(() => f.store.cloneAsUser(active), /synthetic save failure/);
  assert.equal(JSON.stringify(f.store.getAllProfiles()), before);
  assert.equal(f.store.getActiveProfile().name, active);
  assert.equal(f.store.isEditorActive(), true);
  assert.equal(await f.store.restoreEditorTransaction(), true);
  f.store.endEditorSession();
  assert.equal(f.store.isEditorActive(), false);
});

test('并行保存按完整mutation串行，不能在第一份flush未确认时把第二份混入提交', async () => {
  const f = fixture(); await f.store.init({});
  const active = f.store.getActiveProfile().name;
  f.hold();
  const first = f.store.cloneAsUser(active);
  await new Promise(resolve => setImmediate(resolve));
  const writesBeforeSecond = f.writes.length;
  const second = f.store.cloneAsUser(active);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.writes.length, writesBeforeSecond, '第二次mutation应等待首个完整提交');
  assert.equal(f.store.beginEditorSession(), false, '未确认写入期间不能开始新的编辑事务');
  f.release();
  const a = await first, b = await second;
  assert.notEqual(a.name, b.name);
  assert.ok(f.store.getProfileNames().includes(a.name));
  assert.ok(f.store.getProfileNames().includes(b.name));
});
