/** 父/子分别加载真实模块，共享的只有隔离临时目录；验证布局不经 child XML 回写。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const SNAPSHOT = '12345678-1234-4234-8234-123456789abc';
const ROOT_JOURNAL = 'entry/src/main/ets/runtime/GameLayoutJournal.ets';
const ROOT_SNAPSHOT = 'entry/src/main/ets/runtime/DesktopLaunchSnapshot.ets';

function fixture() {
  const disk = evidenceRuntime();
  // 只在测试边界将宿主 ENOENT 对应到 OHOS 明确的 13900002，其它 IO 错误不得吞掉。
  const originalList = disk.kitFs.listFileSync;
  disk.kitFs.listFileSync = directory => {
    try { return originalList(directory); }
    catch (error) { if (error.code === 'ENOENT') error.code = 13900002; throw error; }
  };
  const io = disk.load('commons/src/main/ets/utils/EvidenceIo.ets');
  const state = { lock: 0, failOwnerFlush: false, failOwnerFlushCount: 0, failOwnerMarkerPut: false };
  const ownerData = new Map();
  // 缓存与已 flush 数据分开，冷启动 fixture 不能把未成功持久化的内存冒充磁盘内容。
  const ownerDurable = new Map();
  const prefs = name => {
    if (!ownerData.has(name)) ownerData.set(name, new Map());
    const data = ownerData.get(name);
    return { getSync: (key, fallback) => data.get(key) ?? fallback,
      get: async (key, fallback) => data.get(key) ?? fallback,
      putSync: (key, value) => data.set(key, value), put: async (key, value) => {
        if (name === 'control_layout' && key.startsWith('game_layout_applied_') && state.failOwnerMarkerPut) {
          throw new Error('owner marker put failure');
        }
        data.set(key, value);
      },
      deleteSync: key => data.delete(key), getAllSync: () => Object.fromEntries(data),
      flush: async () => {
        if (name === 'control_layout' && (state.failOwnerFlush || state.failOwnerFlushCount > 0)) {
          if (state.failOwnerFlushCount > 0) state.failOwnerFlushCount--;
          throw new Error('owner disk failure');
        }
        ownerDurable.set(name, new Map(data));
      } };
  };
  function role(pid) {
    let xmlOpens = 0;
    let installedSink;
    const common = { AppLogger: { info() {}, warn() {}, error() {} }, LOG_DOMAIN_LAUNCH: 1,
      ensureDirSync: path => fs.mkdirSync(path, { recursive: true }), ...io };
    const gamecontrol = {};
    const account = { id: 'offline', type: 'offline', refresh: async () => {} };
    const dependencies = { 'commons': common, 'gamecontrol': gamecontrol,
      'libentry.so': { default: { desktopProcessId: () => pid, desktopGameProcessState: () => state.lock } },
      '@kit.CoreFileKit': { fileIo: disk.kitFs }, '@kit.AbilityKit': {},
      '@kit.ArkTS': { util: { generateRandomUUID: () => SNAPSHOT } },
      '@kit.ArkData': { preferences: { getPreferencesSync: (_context, options) => { xmlOpens++; return prefs(options.name); } } },
      '@kit.ArkUI': { display: { getDefaultDisplaySync: () => ({ width: 2400, height: 1600, densityPixels: 2 }) } },
      '@kit.BasicServicesKit': { deviceInfo: { marketName: 'host-test' } },
      '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {}, warn() {} } },
      'feature_system': { PreferenceManager: class { resolveLaunch() {} } },
      'account': { AccountType: { OFFLINE: 'offline' }, getAccountManager: () => ({ init: async () => {},
        getSelected: () => account, findById: () => account, persistOne: async () => {} }) },
      './DesktopFileDrop': { DesktopFileDrop: { clearPrevious: async () => {} } },
    };
    const load = makePureEtsLoader(dependencies);
    Object.assign(common, load('commons/src/main/ets/utils/PreferenceSnapshot.ets'),
      load('commons/src/main/ets/utils/ProcessPreferences.ets'));
    // 保留生产安装器，只捕获实际注入的 sink，供直接输入越权反例验证边界而不修改生产导出。
    const installSink = common.ProcessPreferences.installGameLayoutCommitSink;
    common.ProcessPreferences.installGameLayoutCommitSink = sink => { installedSink = sink; installSink(sink); };
    Object.assign(gamecontrol, load('gamecontrol/src/main/ets/ControlLayout.ets'),
      load('gamecontrol/src/main/ets/LayoutStore.ets'), load('gamecontrol/src/main/ets/LayoutMerge.ets'));
    return { load, store: gamecontrol.getLayoutStore(), process: common.ProcessPreferences,
      journal: load(ROOT_JOURNAL).GameLayoutJournal, snapshot: load(ROOT_SNAPSHOT).DesktopLaunchSnapshot,
      xmlOpens: () => xmlOpens, sink: () => installedSink };
  }
  const owner = role(100), child = role(200);
  const activity = Date.now() - 1000;
  return { disk, state, ownerData, owner, child, activity,
    path: disk.directory + '/game-layout-journal/' + SNAPSHOT + '.json',
    async launch() {
      const ref = await owner.snapshot.prepare(disk.context, 100, '1.16.5', activity);
      state.lock = 1;
      child.snapshot.consume(disk.context, ref.id, ref.account, 100, activity, 200);
      await child.store.init(disk.context);
      return ref;
    },
    async launchLegacy() {
      // 历史版本可能传入全量 control_layout。直接经过同一个 prepare/installGame 边界，
      // 而 owner 当前的常规 capture 已只输出两键；不可为构造旧数据反例而放宽常规快照。
      await owner.store.init(disk.context);
      ownerData.get('control_layout').set('legacy_touch_hint', '保留的旧值');
      ownerData.get('control_layout').set('legacy_scale', 1.5);
      const base = await owner.process.captureOwner(disk.context, 'control_layout');
      owner.journal.prepare(disk.context, SNAPSHOT, activity, 100, base);
      state.lock = 1;
      child.process.installGameSnapshots([base, { name: 'amcl_settings', values: {} },
        { name: 'amcl_accounts', values: {} }]);
      child.journal.installGame(disk.context, SNAPSHOT, activity, 100, 200, base);
      await child.store.init(disk.context);
      return base;
    },
    restartOwner() {
      ownerData.clear();
      for (const [name, values] of ownerDurable) ownerData.set(name, new Map(values));
      return role(300);
    } };
}

test('实际snapshot→child布局保存→journal→parent导入，child从不打开XML且保留父并行新增', async () => {
  const f = fixture();
  try {
    await f.launch();
    await f.child.store.createProfile('child-layout');
    assert.equal(f.child.xmlOpens(), 0);
    assert.equal(fs.existsSync(f.path), true);
    const childRecord = JSON.parse(fs.readFileSync(f.path, 'utf8'));
    assert.equal(childRecord.snapshotId, SNAPSHOT); assert.equal(childRecord.gamePid, 200);
    assert.equal(childRecord.parentPid, 100); assert.equal(childRecord.activityId, f.activity);
    assert.deepEqual(Object.keys(childRecord.proposed.values).sort(), ['active_profile', 'profiles']);
    await f.owner.store.createProfile('parent-layout');
    assert.equal((await f.owner.journal.importPending(f.disk.context)).deferred, true);
    assert.equal(f.owner.store.getProfileNames().includes('child-layout'), false);
    f.state.lock = 0;
    const result = await f.owner.journal.importPending(f.disk.context);
    assert.equal(result.imported, 1); assert.equal(result.pending, 0);
    assert.ok(f.owner.store.getProfileNames().includes('child-layout'));
    assert.ok(f.owner.store.getProfileNames().includes('parent-layout'));
    assert.equal(fs.existsSync(f.path), false, '只有owner持久化成功后才确认清理pending');
  } finally { f.disk.close(); }
});

test('child原子提交失败恢复内存及上一份已确认journal，失败不能声称保存成功', async () => {
  const f = fixture();
  try {
    await f.launch(); await f.child.store.createProfile('saved');
    const before = fs.readFileSync(f.path, 'utf8');
    f.disk.control.failWrite = path => String(path).includes(SNAPSHOT + '.json.tmp-');
    await assert.rejects(() => f.child.store.createProfile('failed'), /保存失败|synthetic disk failure/);
    assert.equal(f.child.store.getProfileNames().includes('failed'), false);
    assert.equal(f.child.store.getActiveProfile().name, 'saved');
    assert.equal(fs.readFileSync(f.path, 'utf8'), before);
    assert.equal(f.child.xmlOpens(), 0);
  } finally { f.disk.close(); }
});

test('parent编辑活跃时延后且下一prepare明确拒绝，关闭编辑后成功导入', async () => {
  const f = fixture();
  try {
    await f.launch(); await f.child.store.createProfile('child'); f.state.lock = 0;
    assert.equal(f.owner.store.beginEditorSession(), true);
    assert.equal((await f.owner.journal.importPending(f.disk.context)).deferred, true);
    assert.ok(fs.existsSync(f.path));
    await assert.rejects(() => f.owner.snapshot.prepare(f.disk.context, 100, 'next', f.activity + 1), /布局.*尚未同步/);
    assert.ok(fs.existsSync(f.path));
    assert.equal(await f.owner.store.restoreEditorTransaction(), true); f.owner.store.endEditorSession();
    assert.equal((await f.owner.journal.importPending(f.disk.context)).imported, 1);
  } finally { f.disk.close(); }
});

test('owner flush失败保留原文并可重试，同一pending重复入口共用Promise', async () => {
  const f = fixture();
  try {
    await f.launch(); await f.child.store.createProfile('child'); f.state.lock = 0;
    f.state.failOwnerFlushCount = 1;
    const first = f.owner.journal.importPending(f.disk.context);
    const same = f.owner.journal.importPending(f.disk.context);
    assert.equal(first, same);
    await assert.rejects(() => first, /owner disk failure/);
    assert.ok(fs.existsSync(f.path));
    assert.equal(f.owner.store.getProfileNames().includes('child'), false);
    assert.equal((await f.owner.journal.importPending(f.disk.context)).imported, 1);
  } finally { f.disk.close(); }
});

test('applied digest避免重放覆盖导入后的parent修改；成功后清除大基线但保留小回执', async () => {
  const f = fixture();
  try {
    await f.launch(); await f.child.store.createProfile('child'); f.state.lock = 0;
    const text = fs.readFileSync(f.path, 'utf8');
    assert.equal((await f.owner.journal.importPending(f.disk.context)).imported, 1);
    assert.equal(fs.existsSync(f.path.replace('.json', '.base.json')), false);
    assert.equal(fs.existsSync(f.path.replace('.json', '.applied.json')), true);
    await f.owner.store.deleteProfile('child');
    fs.writeFileSync(f.path, text);
    assert.equal((await f.owner.journal.importPending(f.disk.context)).imported, 0);
    assert.equal(f.owner.store.getProfileNames().includes('child'), false);
  } finally { f.disk.close(); }
});

test('历史额外键允许只读携带，磁盘只写两键且parent原值不受布局导入影响', async () => {
  const f = fixture();
  try {
    const base = await f.launchLegacy();
    assert.equal(base.values.legacy_touch_hint, '保留的旧值');
    const identity = JSON.parse(fs.readFileSync(f.path.replace('.json', '.base.json'), 'utf8'));
    assert.deepEqual(Object.keys(identity.base.values).sort(), ['active_profile', 'profiles']);
    await f.child.store.createProfile('legacy-compatible');
    const record = JSON.parse(fs.readFileSync(f.path, 'utf8'));
    assert.deepEqual(Object.keys(record.base.values).sort(), ['active_profile', 'profiles']);
    assert.deepEqual(Object.keys(record.proposed.values).sort(), ['active_profile', 'profiles']);
    // owner 在游戏运行期间更改非布局字段，导入不得回滚到 child 启动时的历史值。
    f.ownerData.get('control_layout').set('legacy_touch_hint', '父进程新值');
    f.state.lock = 0;
    assert.equal((await f.owner.journal.importPending(f.disk.context)).imported, 1);
    assert.equal(f.ownerData.get('control_layout').get('legacy_touch_hint'), '父进程新值');
    assert.equal(f.ownerData.get('control_layout').get('legacy_scale'), 1.5);
    assert.ok(f.owner.store.getProfileNames().includes('legacy-compatible'));
    assert.equal(f.child.xmlOpens(), 0);
  } finally { f.disk.close(); }
});

test('child历史字段增删改以及替换原始基线均拒绝，不产出伪成功journal', async () => {
  const f = fixture();
  try {
    const base = await f.launchLegacy();
    for (const change of [value => { value.values.legacy_touch_hint = '越权改值'; },
      value => { delete value.values.legacy_touch_hint; },
      value => { value.values.new_setting = true; }]) {
      const proposed = structuredClone(base); change(proposed);
      await assert.rejects(() => f.child.sink().commit(base, proposed), /non-layout preference key/);
      assert.equal(fs.existsSync(f.path), false);
    }
    const replaced = structuredClone(base); replaced.values.legacy_scale = 2;
    await assert.rejects(() => f.child.sink().commit(replaced, replaced), /替换本局启动基线/);
    assert.equal(fs.existsSync(f.path), false);
    await f.child.store.createProfile('still-usable');
    assert.equal(JSON.parse(fs.readFileSync(f.path, 'utf8')).revision, 1);
  } finally { f.disk.close(); }
});

test('未处理journal身份与磁盘额外字段错误均保留原文并拒绝，不能借投影静默接受', async () => {
  const f = fixture();
  try {
    await f.launch(); await f.child.store.createProfile('child'); f.state.lock = 0;
    const original = fs.readFileSync(f.path, 'utf8');
    for (const [change, expected] of [
      [record => { record.gamePid = 999; }, /归属不匹配/],
      [record => { record.proposed.values.account_token = 'not-allowed'; }, /未授权/],
      [record => { record.base.values.legacy_key = 'read-only-on-disk-is-still-invalid'; }, /未授权/],
      [record => { record.unrecognized = 'not-allowed'; }, /未授权/],
    ]) {
      const invalid = JSON.parse(original); change(invalid);
      const text = JSON.stringify(invalid); fs.writeFileSync(f.path, text);
      await assert.rejects(() => f.owner.journal.importPending(f.disk.context), expected);
      assert.equal(fs.readFileSync(f.path, 'utf8'), text);
      assert.equal(f.owner.store.getProfileNames().includes('child'), false);
    }
  } finally { f.disk.close(); }
});

test('receipt落盘失败保留pending与基线，重试不复制已导入方案', async () => {
  const f = fixture();
  try {
    await f.launch(); await f.child.store.createProfile('child'); f.state.lock = 0;
    f.disk.control.failWrite = path => String(path).includes('.applied.json.tmp-');
    await assert.rejects(() => f.owner.journal.importPending(f.disk.context), /synthetic disk failure/);
    assert.ok(fs.existsSync(f.path)); assert.ok(fs.existsSync(f.path.replace('.json', '.base.json')));
    assert.ok(f.owner.store.getProfileNames().includes('child'));
    f.disk.control.failWrite = undefined;
    assert.equal((await f.owner.journal.importPending(f.disk.context)).imported, 1);
    assert.equal(f.owner.store.getProfileNames().filter(name => name === 'child').length, 1);
    assert.equal(fs.existsSync(f.path), false);
  } finally { f.disk.close(); }
});

test('owner同flush完成标记跨冷启动保护父侧删除，不被缺失文件receipt的旧journal复活', async () => {
  const f = fixture();
  try {
    await f.launch(); await f.child.store.createProfile('child-added'); f.state.lock = 0;
    f.disk.control.failWrite = path => String(path).includes('.applied.json.tmp-');
    await assert.rejects(() => f.owner.journal.importPending(f.disk.context), /synthetic disk failure/);
    assert.ok(fs.existsSync(f.path));
    assert.match(f.ownerData.get('control_layout').get('game_layout_applied_' + SNAPSHOT), /^[0-9a-f]{64}$/);
    const restarted = f.restartOwner(); await restarted.store.init(f.disk.context);
    await restarted.store.deleteProfile('child-added');
    assert.equal(restarted.store.getProfileNames().includes('child-added'), false);
    f.disk.control.failWrite = undefined;
    const result = await restarted.journal.importPending(f.disk.context);
    assert.equal(result.imported, 1); assert.deepEqual(result.conflicts, []);
    assert.equal(restarted.store.getProfileNames().includes('child-added'), false);
    assert.equal(fs.existsSync(f.path), false);
    assert.deepEqual(Object.keys((await restarted.store.captureLaunchPreferences()).values).sort(), ['active_profile', 'profiles']);
  } finally { f.disk.close(); }
});

test('owner标记put失败连同两布局键回滚，失败journal重试仍完整导入', async () => {
  const f = fixture();
  try {
    await f.launch(); await f.child.store.createProfile('child'); f.state.lock = 0;
    const before = f.ownerData.get('control_layout').get('profiles') ?? '';
    f.state.failOwnerMarkerPut = true;
    await assert.rejects(() => f.owner.journal.importPending(f.disk.context), /marker put failure/);
    assert.equal(f.ownerData.get('control_layout').get('profiles'), before);
    assert.notEqual(f.ownerData.get('control_layout').get('game_layout_applied_' + SNAPSHOT)?.length, 64);
    assert.ok(fs.existsSync(f.path));
    f.state.failOwnerMarkerPut = false;
    assert.equal((await f.owner.journal.importPending(f.disk.context)).imported, 1);
  } finally { f.disk.close(); }
});

test('owner flush及回滚均失败时封锁本进程后续写入，冷启动从已落盘状态恢复', async () => {
  const f = fixture();
  try {
    await f.launch(); await f.child.store.createProfile('child'); f.state.lock = 0;
    f.state.failOwnerFlush = true;
    await assert.rejects(() => f.owner.journal.importPending(f.disk.context), /owner disk failure/);
    f.state.failOwnerFlush = false;
    await assert.rejects(() => f.owner.journal.importPending(f.disk.context), /重启启动器/);
    await assert.rejects(() => f.owner.store.createProfile('must-not-persist'), /重启启动器/);
    assert.ok(fs.existsSync(f.path));
    const restarted = f.restartOwner();
    assert.equal((await restarted.journal.importPending(f.disk.context)).imported, 1);
    assert.ok(restarted.store.getProfileNames().includes('child'));
    assert.equal(restarted.store.getProfileNames().includes('must-not-persist'), false);
  } finally { f.disk.close(); }
});

test('child第二次put失败同时恢复LayoutStore和overlay，下一次提交不携带半笔失败方案', async () => {
  const f = fixture();
  try {
    await f.launch(); await f.child.store.createProfile('confirmed');
    const saved = fs.readFileSync(f.path, 'utf8');
    const overlay = f.child.process.open(f.disk.context, 'control_layout');
    const put = overlay.put.bind(overlay);
    overlay.put = async (key, value) => {
      if (key === 'active_profile') throw new Error('second-put failure');
      return put(key, value);
    };
    await assert.rejects(() => f.child.store.createProfile('failed-half-write'), /second-put failure/);
    assert.equal(f.child.store.getProfileNames().includes('failed-half-write'), false);
    assert.equal(JSON.parse(overlay.getSync('profiles', '[]')).some(item => item.name === 'failed-half-write'), false);
    assert.equal(fs.readFileSync(f.path, 'utf8'), saved);
    overlay.put = put;
    await f.child.store.createProfile('next-confirmed');
    const record = JSON.parse(fs.readFileSync(f.path, 'utf8'));
    assert.equal(JSON.parse(record.proposed.values.profiles).some(item => item.name === 'failed-half-write'), false);
    assert.equal(record.revision, 2);
  } finally { f.disk.close(); }
});

test('child暂存撤销失败封锁后续mutation，owner不能借撤销接口改变偏好', async () => {
  const f = fixture();
  try {
    await f.launch(); await f.child.store.createProfile('confirmed');
    assert.throws(() => f.owner.process.discardGameLayoutChanges(), /Only the installed game layout/);
    const overlay = f.child.process.open(f.disk.context, 'control_layout');
    overlay.put = async () => { throw new Error('put failed'); };
    overlay.discardUncommitted = () => { throw new Error('discard failed'); };
    await assert.rejects(() => f.child.store.createProfile('failed'), /put failed/);
    await assert.rejects(() => f.child.store.createProfile('blocked'), /重启启动器/);
    assert.equal(f.child.store.getProfileNames().includes('failed'), false);
  } finally { f.disk.close(); }
});

test('pending清理失败仍由receipt防重放，parent后续编辑不会被覆盖', async () => {
  const f = fixture();
  try {
    await f.launch(); await f.child.store.createProfile('child'); f.state.lock = 0;
    const unlink = f.disk.kitFs.unlinkSync;
    f.disk.kitFs.unlinkSync = path => { if (path === f.path) throw new Error('unlink denied'); return unlink(path); };
    assert.equal((await f.owner.journal.importPending(f.disk.context)).imported, 1);
    assert.ok(fs.existsSync(f.path)); assert.ok(fs.existsSync(f.path.replace('.json', '.base.json')));
    await f.owner.store.deleteProfile('child');
    f.disk.kitFs.unlinkSync = unlink;
    assert.equal((await f.owner.journal.importPending(f.disk.context)).imported, 0);
    assert.equal(f.owner.store.getProfileNames().includes('child'), false);
    assert.equal(fs.existsSync(f.path), false);
    assert.equal(fs.existsSync(f.path.replace('.json', '.base.json')), false);
  } finally { f.disk.close(); }
});

test('目录不存在允许首装，目录无法读取则拒绝导入与下一prepare', async () => {
  const f = fixture();
  try {
    assert.equal((await f.owner.journal.importPending(f.disk.context)).pending, 0);
    const error = new Error('layout directory permission denied'); error.code = 13900013;
    f.disk.kitFs.listFileSync = () => { throw error; };
    await assert.rejects(() => f.owner.journal.importPending(f.disk.context), /permission denied/);
    await assert.rejects(() => f.owner.snapshot.prepare(f.disk.context, 100, 'next', f.activity), /permission denied/);
  } finally { f.disk.close(); }
});
