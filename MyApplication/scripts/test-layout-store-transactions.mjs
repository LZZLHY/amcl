/**
 * 直接执行生产 LayoutStore；只替代显示/偏好持久层，验证编辑 lease、串行提交和失败恢复，
 * 以及加载修复：改名 trim、新建唯一名、逐方案 salvage、隔离记录（只追加/去重/上限）、
 * 控件 id 保守修复、隔离写失败的写入封锁、游戏进程不写盘，和启动快照可通过布局合并。
 */
import assert from 'node:assert/strict';
import test from 'node:test';
import { randomUUID } from 'node:crypto';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const SESSION = '12345678-1234-4234-8234-123456789abc';
const QUARANTINE = 'profiles_quarantine';

/**
 * 内存 Preferences：data 是进程缓存，durable 只在 flush 成功时整体复制（与真实 Preferences
 * “flush 把整份缓存写盘”的语义一致）。durableHistory 记录每次落盘后的状态，用来证明
 * “profiles 被改写的第一刻，隔离记录已经在盘上”。
 */
function fixture(options = {}) {
  const data = new Map([['profiles', ''], ['active_profile', ''], ...Object.entries(options.initial ?? {})]);
  let durable = new Map(data);
  const durableHistory = [];
  let failures = 0, release, hold = false, pendingKeys = [];
  const writes = [], flushes = [], logs = [];
  const control = { failFlush: null, failPut: null, gameProcess: options.gameProcess === true };
  const gate = new Promise(resolve => { release = resolve; });
  const put = (key, value) => {
    if (control.failPut && control.failPut(key)) throw new Error('synthetic put failure');
    writes.push([key, value]); pendingKeys.push(key); data.set(key, value);
  };
  const pref = { get: async (key, fallback) => data.get(key) ?? fallback,
    getSync: (key, fallback) => data.get(key) ?? fallback,
    put: async (key, value) => { put(key, value); },
    putSync: (key, value) => { put(key, value); },
    // 该用例验证一次保存失败、随后回滚可确认的可重试路径；保存和回滚都失败的
    // 冷启动封锁边界由 transport 的独立用例覆盖，不能混为同一种恢复语义。
    flush: async () => {
      if (hold) await gate;
      const keys = pendingKeys; pendingKeys = [];
      flushes.push(keys);
      if (failures > 0) { failures--; throw new Error('synthetic save failure'); }
      if (control.failFlush && control.failFlush(keys)) throw new Error('synthetic flush failure');
      durable = new Map(data);
      durableHistory.push({ quarantine: durable.has(QUARANTINE), profiles: durable.get('profiles') });
    } };
  const log = level => (tag, message) => { logs.push([level, String(message)]); };
  const deps = {
    'commons': { AppLogger: { error: log('error'), warn: log('warn'), info: log('info') },
      ProcessPreferences: { open: () => pref, isGameProcess: () => control.gameProcess,
        discardGameLayoutChanges: () => {} },
      OwnerLayoutSourceRepository: { open: () => null, openOrMigrate: () => { throw Error('source filesystem not provided by this memory fixture'); } },
      utf8ByteLength: text => Buffer.byteLength(text),
    },
    '@kit.AbilityKit': {}, '@kit.CoreFileKit': { fileIo: {} }, '@kit.ArkTS': { util: { generateRandomUUID: randomUUID } },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {}, warn() {} } },
    '@kit.ArkUI': { display: { getDefaultDisplaySync: () => options.display ?? ({ width: 2400, height: 1600, densityPixels: 2 }) } },
    '@kit.BasicServicesKit': { deviceInfo: { marketName: 'test tablet' } },
  };
  const load = makePureEtsLoader(deps);
  Object.assign(deps.commons, load('commons/src/main/ets/utils/PreferenceSnapshot.ets'));
  const Store = load('gamecontrol/src/main/ets/LayoutStore.ets').LayoutStore;
  const layout = load('gamecontrol/src/main/ets/ControlLayout.ets');
  const { mergeLayoutPreferences } = load('gamecontrol/src/main/ets/LayoutMerge.ets');
  const presetNames = load('gamecontrol/src/main/ets/LayoutPresets.ets').getAllPresets().map(p => p.name);
  const store = new Store();
  return { store, data, writes, flushes, logs, load, layout, presetNames, control, durableHistory,
    durable: () => durable,
    failNextFlush: () => { failures = 1; },
    hold: () => { hold = true; }, release: () => { hold = false; release(); },
    // 冷启动：缓存丢弃未落盘内容，用同一份“磁盘”新建生产 Store。
    restart: () => {
      data.clear(); for (const [key, value] of durable) data.set(key, value);
      pendingKeys = []; return new Store();
    },
    merge: snapshot => mergeLayoutPreferences(snapshot, snapshot, snapshot, SESSION),
    user: (name, mutate) => {
      const profile = layout.getDefaultLayout(); profile.name = name; profile.isPreset = false;
      if (mutate) mutate(profile);
      return profile;
    } };
}

test('收敛编辑：读取预设/非活跃目标和取消没有写盘，也不留下编辑锁',async()=>{
  const f=fixture();await f.store.init({});
  const active=f.store.getActiveProfile().profileId,writes=f.writes.length;
  assert.equal(f.store.beginEditorSession(),true);
  const other=f.store.getProfile(f.presetNames.find(name=>name!==f.store.getActiveProfile().name));
  assert.ok(other);assert.equal(f.store.getActiveProfile().profileId,active);
  assert.equal(await f.store.restoreEditorTransaction(),true);f.store.endEditorSession();
  assert.equal(f.writes.length,writes);assert.equal(f.store.isEditorActive(),false);
});

test('收敛编辑：预设最终草稿一次提交为独立副本，完整重映射组图',async()=>{
  const f=fixture();await f.store.init({});
  const preset=f.store.getProfile(f.presetNames[0]);
  const draft=f.layout.enableLayoutControlGroups(preset);
  draft.controlGroups.push({id:'extra',name:'工具',initialVisible:false});
  const button=draft.controls.find(item=>!item.systemAction&&item.type===0);
  button.groupActions=[{phase:'press',operation:'toggle',targets:['extra','extra']}];
  button.xPct=.3;draft.touch={joystickAutoWalk:true,gestureMode:'combat'};
  const names=f.store.getProfileNames(),flushes=f.flushes.length;
  assert.equal(f.store.beginEditorSession(),true);
  const saved=await f.store.saveEditedProfile(draft);assert.ok(saved);
  assert.equal(f.flushes.length,flushes+1);assert.equal(f.store.getProfileNames().length,names.length+1);
  assert.notEqual(saved.profileId,preset.profileId);assert.equal(saved.profileRevision,1);assert.equal(saved.isPreset,false);
  assert.equal(saved.version,5);assert.notEqual(saved.controlGroups[1].id,'extra');
  assert.deepEqual(saved.controls.find(item=>item.groupActions?.length).groupActions[0].targets,
    [saved.controlGroups[1].id,saved.controlGroups[1].id]);
  assert.equal(saved.touch.joystickAutoWalk,true);assert.equal(saved.touch.gestureMode,'combat');
  assert.deepEqual(f.store.getProfile(preset.name),preset);
  f.store.commitEditorTransaction();f.store.endEditorSession();assert.equal(f.store.isEditorActive(),false);
});

test('收敛编辑：原子副本写失败不留下半成品，恢复后可重试且旧用户revision被拒绝',async()=>{
  const f=fixture();await f.store.init({});
  const preset=f.store.getProfile(f.presetNames[0]),names=f.store.getProfileNames();
  const durable=new Map(f.durable());assert.equal(f.store.beginEditorSession(),true);
  f.failNextFlush();await assert.rejects(()=>f.store.saveEditedProfile(preset),/failure/);
  assert.deepEqual(f.store.getProfileNames(),names);assert.deepEqual(f.durable(),durable);
  const saved=await f.store.saveEditedProfile(preset);assert.ok(saved);
  f.store.commitEditorTransaction();f.store.endEditorSession();
  const changed=await f.store.saveEditedProfile(saved);assert.equal(changed.profileRevision,saved.profileRevision+1);
  assert.equal(await f.store.saveEditedProfile(saved),null);
});

function quarantineDoc(f) {
  const text = f.durable().get(QUARANTINE);
  assert.equal(typeof text, 'string', '隔离记录必须已落盘');
  return JSON.parse(text);
}

function allIds(controls, out = []) {
  for (const item of controls) { out.push(item.id); if (item.children) allIds(item.children, out); }
  return out;
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

test('I27-02：改名写入trim后的活动名，启动快照可通过布局合并（旧行为的未trim活动名会被合并拒绝）', async () => {
  const f = fixture(); await f.store.init({});
  assert.equal((await f.store.createProfile('A')).name, 'A');
  assert.equal(await f.store.renameProfile('A', '  B  '), true);
  assert.equal(f.store.getActiveProfile().name, 'B');
  assert.equal(f.durable().get('active_profile'), 'B', '磁盘活动名与方案名一致');
  const snapshot = await f.store.captureLaunchPreferences();
  assert.deepEqual(Object.keys(snapshot.values).sort(), ['active_profile', 'profiles']);
  f.merge(snapshot);
  // 负向对照：旧实现写下的未 trim 名正是合并判为“活动方案不存在”的输入。
  const legacy = { name: snapshot.name, values: { ...snapshot.values, active_profile: '  B  ' } };
  assert.throws(() => f.merge(legacy), /Active layout does not exist/);
});

test('I27-02：旧存档的未trim活动名按trim匹配，只在启动器回写一次且不需要隔离', async () => {
  const f = fixture({ initial: { profiles: JSON.stringify([fixture().user('B')]), active_profile: ' B ' } });
  await f.store.init({});
  assert.equal(f.store.getActiveProfile().name, 'B');
  assert.equal(f.durable().get('active_profile'), 'B');
  assert.equal(f.writes.filter(([key]) => key === 'active_profile').length, 1, '修复只回写一次');
  assert.equal(f.data.has(QUARANTINE), false, 'trim 修复不产生隔离记录');
  f.merge(await f.store.captureLaunchPreferences());
  assert.ok(f.logs.some(([level, message]) => level === 'warn' && message.includes('active=trimmed')));
});

test('X1：新建方案不产生重名（含预设名），返回值是实际创建的名字', async () => {
  const f = fixture(); await f.store.init({});
  const first = await f.store.createProfile('方案3');
  const second = await f.store.createProfile('方案3');
  const third = await f.store.createProfile(f.presetNames[0]);
  assert.equal(first.name, '方案3');
  assert.equal(second.name, '方案3 副本');
  assert.notEqual(third.name, f.presetNames[0]);
  assert.equal(f.store.getActiveProfile().name, third.name);
  const names = f.store.getProfileNames();
  assert.equal(new Set(names).size, names.length, '方案名全表唯一');
  f.merge(await f.store.captureLaunchPreferences());
});

test('I27-08：逐方案salvage保留全部合法方案、重名改名、旧预设副本不连坐，非法项与活动名原样隔离', async () => {
  const seed = fixture();
  const presetCopy = seed.user(seed.presetNames[0], p => { p.isPreset = true; p.controls[0].type = 99; });
  const unknownPreset = seed.user('★ 已下线的旧预设', p => { p.isPreset = true; });
  const raw = JSON.stringify([
    seed.user('A'),
    seed.user('秘密方案XYZ', p => { p.controls[0].type = 99; }),
    presetCopy,
    seed.user('A'),
    seed.user(seed.presetNames[0]),
    unknownPreset,
  ]);
  const f = fixture({ initial: { profiles: raw, active_profile: '秘密方案XYZ' } });
  await f.store.init({});
  const names = f.store.getProfileNames();
  assert.ok(names.includes('A') && names.includes('A 副本') && names.includes(f.presetNames[0] + ' 副本'));
  assert.equal(names.includes('秘密方案XYZ'), false);
  assert.equal(names.includes('★ 已下线的旧预设'), false);
  assert.equal(new Set(names).size, names.length);
  assert.ok(f.store.getAllProfiles().every(p => f.layout.validateAndNormalizeLayout(p) !== null));
  assert.ok(f.presetNames.includes(f.store.getActiveProfile().name), '被隔离的活动方案回退到设备预设');

  const doc = quarantineDoc(f);
  assert.equal(doc.schema, 1); assert.equal(doc.entries.length, 1);
  assert.equal(doc.entries[0].raw, raw, '隔离记录逐字节保存完整原文');
  assert.deepEqual(doc.entries[0].invalidIndexes, [1]);
  assert.equal(doc.entries[0].activeAtCapture, '秘密方案XYZ');
  assert.ok(doc.entries[0].reasons.includes('profile[1]:control[0].type'));
  assert.match(doc.entries[0].digest, /^[0-9a-f]{16}$/);
  // 隔离记录先单独落盘，profiles 才被改写：任何一次落盘都不存在“原文已覆盖而备份缺失”的状态。
  const firstRewrite = f.durableHistory.findIndex(state => state.profiles !== raw);
  assert.ok(firstRewrite >= 0 && f.durableHistory[firstRewrite].quarantine, '覆盖 profiles 前隔离已落盘');
  assert.deepEqual(f.flushes[0], [QUARANTINE], '第一次 flush 只包含隔离键');

  const issues = f.store.getLoadIssues();
  assert.equal(issues.quarantinedProfiles, 1); assert.equal(issues.renamedProfiles, 2);
  assert.equal(issues.activeFallback, true); assert.equal(issues.writeBlocked, false);
  f.merge(await f.store.captureLaunchPreferences());

  // 日志只含下标、原因码、字节数与摘要；不得出现方案名或原文。
  assert.ok(f.logs.some(([, message]) => message.includes('index=1 reason=control[0].type')));
  assert.ok(f.logs.some(([, message]) => message.includes('active=fallback-quarantined')));
  assert.equal(f.logs.some(([, message]) => message.includes('秘密方案XYZ') || message.includes(raw)), false);

  // 后续普通写入只改 profiles，隔离记录逐字不变。
  const before = f.durable().get(QUARANTINE);
  await f.store.createProfile('之后新建');
  assert.equal(f.durable().get(QUARANTINE), before);
});

test('I27-08：重名改名不抢占后面方案的原名，且无需隔离备份', async () => {
  const seed = fixture();
  const raw = JSON.stringify([seed.user('A', p => { p.globalOpacity = 0.9; }), seed.user('A'), seed.user('A 副本')]);
  const f = fixture({ initial: { profiles: raw, active_profile: 'A' } });
  await f.store.init({});
  const users = f.store.getAllProfiles().filter(p => p.isPreset !== true);
  assert.deepEqual(users.map(p => p.name), ['A', 'A 副本 2', 'A 副本'], '首个出现者与后面的原名都保留');
  assert.equal(f.store.getActiveProfile().globalOpacity, 0.9, '活动名精确匹配首个同名方案');
  assert.equal(f.data.has(QUARANTINE), false, '只改名不改内容，不需要隔离备份');
  assert.equal(f.store.getLoadIssues().renamedProfiles, 1);
  f.merge(await f.store.captureLaunchPreferences());
});

test('I27-08：旧编辑器生成的超长/重复控件id保守修复，原文照样备份；混有其它错误的方案仍隔离', async () => {
  const seed = fixture();
  const longId = 'btn_123456_dup1234_dup12';   // 24 字节，超过 23 字节 ABI 上限
  const repairable = seed.user('可修复', p => { p.controls[1].id = longId; p.controls[3].id = p.controls[2].id; });
  const mixed = seed.user('混合错误', p => { p.controls[1].id = longId; p.controls[5].type = 99; });
  assert.equal(seed.layout.validateAndNormalizeLayout(repairable), null, '负向对照：不修复时整份方案被拒');
  const raw = JSON.stringify([repairable, mixed]);
  const f = fixture({ initial: { profiles: raw, active_profile: '可修复' } });
  await f.store.init({});
  const kept = f.store.getAllProfiles().find(p => p.name === '可修复');
  assert.ok(kept, '修复后的方案保留');
  const ids = allIds(kept.controls);
  assert.equal(new Set(ids).size, ids.length, '全树 id 唯一');
  assert.ok(ids.every(id => Buffer.byteLength(id) <= 23));
  assert.equal(ids.includes(longId), false);
  assert.equal(kept.controls[2].id, repairable.controls[2].id, '首个合法出现者保留原 id');
  assert.equal(kept.controls[1].keyOrMouse, repairable.controls[1].keyOrMouse, '只改 id 不改其它字段');
  assert.equal(f.store.getActiveProfile().name, '可修复');
  assert.equal(f.store.getProfileNames().includes('混合错误'), false);
  const doc = quarantineDoc(f);
  assert.equal(doc.entries[0].raw, raw);
  assert.deepEqual(doc.entries[0].invalidIndexes, [1]);
  assert.ok(doc.entries[0].reasons.includes('profile[0]:repaired-control-id'));
  assert.ok(doc.entries[0].reasons.includes('profile[1]:control[5].type'));
  const issues = f.store.getLoadIssues();
  assert.equal(issues.repairedProfiles, 1); assert.equal(issues.quarantinedProfiles, 1);
  f.merge(await f.store.captureLaunchPreferences());
});

test('I27-08：文档级损坏整串隔离，只保留系统预设并回退活动方案', async () => {
  const f = fixture({ initial: { profiles: '[{"name":"截断', active_profile: '截断' } });
  await f.store.init({});
  assert.deepEqual(f.store.getProfileNames(), f.presetNames);
  const doc = quarantineDoc(f);
  assert.equal(doc.entries[0].raw, '[{"name":"截断');
  assert.deepEqual(doc.entries[0].reasons, ['document:json-parse']);
  assert.deepEqual(doc.entries[0].invalidIndexes, []);
  const issues = f.store.getLoadIssues();
  assert.equal(issues.documentQuarantined, true); assert.equal(issues.activeFallback, true);
  f.merge(await f.store.captureLaunchPreferences());
});

test('I27-08：隔离写失败时init不抛错、内存照常可用、覆盖写入被封锁且原文不动；恢复后先落盘隔离再改写', async () => {
  const seed = fixture();
  const raw = JSON.stringify([seed.user('A'), seed.user('坏', p => { p.controls[0].type = 99; })]);
  const f = fixture({ initial: { profiles: raw, active_profile: 'A' } });
  f.control.failPut = key => key === QUARANTINE;
  await f.store.init({});
  assert.equal(f.store.isReady(), true);
  assert.ok(f.store.getProfileNames().includes('A'));
  assert.equal(f.store.getActiveProfile().name, 'A');
  assert.equal(f.durable().get('profiles'), raw);
  assert.equal(f.durable().has(QUARANTINE), false);
  const issues = f.store.getLoadIssues();
  assert.equal(issues.writeBlocked, true); assert.match(issues.writeBlockMessage, /暂不能保存布局修改/);
  await assert.rejects(() => f.store.createProfile('被封锁'), /暂不能保存布局修改/);
  await assert.rejects(() => f.store.setActiveProfile(f.presetNames[0]), /暂不能保存布局修改/);
  assert.equal(f.durable().get('profiles'), raw, '封锁期间原文从未被覆盖');
  assert.equal(f.store.getProfileNames().includes('被封锁'), false);
  assert.ok(f.logs.some(([level, message]) => level === 'error' && message.includes('reason=quarantine-write-failed')));

  f.control.failPut = null;
  assert.equal((await f.store.createProfile('恢复后')).name, '恢复后');
  assert.equal(f.store.getLoadIssues().writeBlocked, false);
  assert.equal(quarantineDoc(f).entries[0].raw, raw);
  const firstRewrite = f.durableHistory.findIndex(state => state.profiles !== raw);
  assert.ok(f.durableHistory[firstRewrite].quarantine, '覆盖 profiles 前隔离已落盘');
  f.merge(await f.store.captureLaunchPreferences());
});

test('I27-08：隔离flush失败只进了缓存时，下一次保存先单独确认隔离落盘，再改写profiles', async () => {
  const seed = fixture();
  const raw = JSON.stringify([seed.user('A'), seed.user('坏', p => { p.controls[0].type = 99; })]);
  const f = fixture({ initial: { profiles: raw, active_profile: 'A' } });
  let failed = false;
  f.control.failFlush = keys => { if (!failed && keys.includes(QUARANTINE)) { failed = true; return true; } return false; };
  await f.store.init({});
  assert.equal(f.store.getLoadIssues().writeBlocked, true);
  assert.equal(f.durable().has(QUARANTINE), false, '缓存里的隔离值不等于已落盘');
  await f.store.createProfile('重试');
  const confirmed = f.durableHistory.findIndex(state => state.quarantine);
  assert.equal(f.durableHistory[confirmed].profiles, raw, '隔离先单独落盘，此刻 profiles 仍是原文');
  assert.notEqual(f.durable().get('profiles'), raw);
  assert.equal(f.store.getLoadIssues().writeBlocked, false);
});

test('I27-08：隔离区达到条数或字节上限时拒绝追加并封锁写入，旧条目逐字保留', async () => {
  const seed = fixture();
  const raw = JSON.stringify([seed.user('坏', p => { p.controls[0].type = 99; })]);
  const entry = (text, index) => ({ digest: String(index).padStart(16, '0'), capturedAt: 1, reasons: ['document:json-parse'],
    invalidIndexes: [], activeAtCapture: '', raw: text });
  for (const existing of [Array.from({ length: 8 }, (_, index) => entry('old-' + index, index)),
    [entry('x'.repeat(4 * 1024 * 1024 - 200), 1)]]) {
    const text = JSON.stringify({ schema: 1, entries: existing });
    const f = fixture({ initial: { profiles: raw, active_profile: '', [QUARANTINE]: text } });
    await f.store.init({});
    assert.equal(f.store.getLoadIssues().writeBlocked, true);
    assert.match(f.store.getLoadIssues().writeBlockMessage, /上限/);
    assert.equal(f.durable().get(QUARANTINE), text, '旧隔离条目逐字保留，从不淘汰');
    await assert.rejects(() => f.store.createProfile('新'), /上限/);
    assert.equal(f.durable().get('profiles'), raw);
  }
});

test('I27-08：已有其它摘要的隔离条目只追加不覆盖；第二步失败后冷启动按摘要去重', async () => {
  const seed = fixture();
  const raw = JSON.stringify([seed.user('A'), seed.user('坏', p => { p.controls[0].type = 99; })]);
  const old = { digest: '0000000000000000', capturedAt: 7, reasons: ['document:not-array'], invalidIndexes: [],
    activeAtCapture: '旧', raw: '{"legacy":true}' };
  const f = fixture({ initial: { profiles: raw, active_profile: 'A', [QUARANTINE]: JSON.stringify({ schema: 1, entries: [old] }) } });
  f.control.failFlush = keys => keys.includes('profiles');
  await f.store.init({});
  let doc = quarantineDoc(f);
  assert.equal(doc.entries.length, 2);
  assert.deepEqual(doc.entries[0], old);
  assert.equal(f.durable().get('profiles'), raw, '第二步失败：原文仍在，隔离已落盘');
  f.control.failFlush = null;
  const restarted = f.restart();
  await restarted.init({});
  doc = quarantineDoc(f);
  assert.equal(doc.entries.length, 2, '同一原文按摘要+原文去重，不重复追加');
  assert.notEqual(f.durable().get('profiles'), raw, '冷启动完成迁移写');
  f.merge(await restarted.captureLaunchPreferences());
});

test('I27-08：游戏进程只在内存salvage，从不写盘（含隔离键），需要备份时保存被封锁', async () => {
  const seed = fixture();
  const raw = JSON.stringify([seed.user('A'), seed.user('坏', p => { p.controls[0].type = 99; })]);
  const f = fixture({ gameProcess: true, initial: { profiles: raw, active_profile: ' A ' } });
  await f.store.init({});
  assert.deepEqual(f.writes, [], '游戏进程 init 不写任何键');
  assert.equal(f.store.getActiveProfile().name, 'A');
  await assert.rejects(() => f.store.createProfile('游戏内新建'), /游戏内不能备份/);
  assert.equal(f.writes.some(([key]) => key === QUARANTINE), false);
  assert.equal(f.data.get('profiles'), raw);
  // 只需改写活动名（无隔离项）的修复在游戏进程同样不能写：overlay 只接受启动器准备好的快照。
  const trimOnly = fixture({ gameProcess: true,
    initial: { profiles: JSON.stringify([seed.user('A')]), active_profile: ' A ' } });
  await trimOnly.store.init({});
  assert.equal(trimOnly.store.getActiveProfile().name, 'A');
  assert.deepEqual(trimOnly.writes, [], '游戏进程 init 从不回写修复');
});

test('I27-08：二轮注入失败只回退该方案，不再整表换成单个默认布局', async () => {
  // 7680x4320、density 1 下自动档 guiScale=17，hotbar 宽 3060px；globalScale 0.5 的方案对齐后
  // baseWidth=6120 超过 4096 上限。旧实现会因此把整张表换成一份默认布局。
  const seed = fixture();
  const wide = seed.user('宽屏小缩放', p => { p.globalScale = 0.5; });
  const normal = seed.user('普通');
  const storedSelector = wide.controls.find(item => item.id === 'hotbar_sel');
  const f = fixture({ display: { width: 7680, height: 4320, densityPixels: 1 },
    initial: { profiles: JSON.stringify([wide, normal]), active_profile: '普通' } });
  await f.store.init({});
  const names = f.store.getProfileNames();
  assert.ok(names.includes('宽屏小缩放') && names.includes('普通'));
  const revertedSelector = f.store.getAllProfiles().find(p => p.name === '宽屏小缩放').controls.find(item => item.id === 'hotbar_sel');
  assert.equal(revertedSelector.baseWidth, storedSelector.baseWidth, '失败方案回退到首轮规范化结果');
  assert.ok(f.logs.some(([, message]) => message.includes('target=profile[0]') && message.includes('reason=control[')));
  assert.equal(f.store.getActiveProfile().name, '普通');
});

test('getActiveProfile回退仍返回合法方案，每个无法解析的名字只记一次日志且不含名字原文', async () => {
  const f = fixture(); await f.store.init({});
  f.store.activeName = '幽灵方案QQ';
  const first = f.store.getActiveProfile();
  f.store.activeName = '幽灵方案QQ';
  const second = f.store.getActiveProfile();
  assert.equal(first.name, second.name);
  const hits = f.logs.filter(([, message]) => message.includes('活动布局名无法解析'));
  assert.equal(hits.length, 1);
  assert.equal(hits.some(([, message]) => message.includes('幽灵方案QQ')), false);
});

test('R2：删除后排队的旧使用请求拒绝，磁盘与活动引用保持存在', async () => {
  const f = fixture(); await f.store.init({}); await f.store.createProfile('待删除');
  const deletion = f.store.deleteProfile('待删除');
  const selection = f.store.setActiveProfile('待删除');
  await deletion; await assert.rejects(() => selection, /TargetMissing/);
  const snapshot = await f.store.captureLaunchPreferences();
  assert.ok(JSON.parse(snapshot.values.profiles).some(p => p.name === snapshot.values.active_profile));
});

test('R2：独立同名导入队内命名，两份内容守恒；重复同一预览只新增一次', async () => {
  const f = fixture(); await f.store.init({});
  const first = f.user('并行导入', p => { p.lookSensitivity = .7; });
  const second = f.user('并行导入', p => { p.lookSensitivity = 1.7; });
  const results = await Promise.all([f.store.importFromJson(JSON.stringify(first)), f.store.importFromJson(JSON.stringify(second))]);
  assert.deepEqual(results.map(p => p.name), ['并行导入', '并行导入 副本']);
  assert.deepEqual(f.store.getAllProfiles().filter(p => !p.isPreset).map(p => p.lookSensitivity), [.7, 1.7]);
  const review = f.store.analyzeImport(JSON.stringify(f.user('预览')));
  const commit = f.store.commitReviewedImport(review.reviewId);
  assert.equal(f.store.commitReviewedImport(review.reviewId), commit);
  const saved = await commit;
  assert.equal((await f.store.commitReviewedImport(review.reviewId)).profileId, saved.profileId);
  assert.equal(f.store.getProfileNames().filter(name => name === '预览').length, 1);
});

test('R2：超过32次独立导入继续可用，有效请求重复幂等，过期请求只拒绝不新增', async () => {
  const f = fixture(); await f.store.init({});
  let oldest;
  for (let index = 0; index < 40; index++) {
    const review = f.store.analyzeImport(JSON.stringify(f.user('持续导入' + index)));
    assert.equal(review.ok, true);
    if (index === 0) oldest = review.reviewId;
    const promise = f.store.commitReviewedImport(review.reviewId);
    assert.equal(f.store.commitReviewedImport(review.reviewId), promise);
    const saved = await promise;
    assert.equal((await f.store.commitReviewedImport(review.reviewId)).profileId, saved.profileId);
  }
  assert.equal(f.store.getProfileNames().filter(name => name.startsWith('持续导入')).length, 40);
  await assert.rejects(() => f.store.commitReviewedImport(oldest), /StaleCandidate/);
  assert.equal(f.store.getProfileNames().filter(name => name.startsWith('持续导入')).length, 40);
  assert.ok(f.store.importReviews.size <= 32 && f.store.importCommits.size <= 32);
});

test('R2：旧editor在rename、delete重建或版本推进后不得覆盖新实体', async () => {
  const f = fixture(); await f.store.init({});
  const stale = await f.store.createProfile('旧名字');
  await f.store.renameProfile('旧名字', '新名字');
  assert.equal(await f.store.saveProfile(stale), false);
  assert.equal(f.store.getProfileNames().includes('旧名字'), false);
  const deleted = f.store.getActiveProfile();
  await f.store.deleteProfile('新名字'); const recreated = await f.store.createProfile('新名字');
  assert.notEqual(deleted.profileId, recreated.profileId);
  assert.equal(await f.store.saveProfile(deleted), false);
  const a = f.store.getActiveProfile(), b = f.store.getActiveProfile();
  a.lookSensitivity = .9; assert.equal(await f.store.saveProfile(a), true);
  b.lookSensitivity = 1.9; assert.equal(await f.store.saveProfile(b), false);
  assert.equal(f.store.getActiveProfile().lookSensitivity, .9);
});

test('R2：公共读取是完整副本，嵌套修改不能绕过提交', async () => {
  const f = fixture(); await f.store.init({}); const saved = await f.store.createProfile('独立副本');
  saved.controls[0].xPct = .99;
  const all = f.store.getAllProfiles(); all.length = 0;
  const active = f.store.getActiveProfile(); active.controls[0].style.opacity = .12;
  assert.notEqual(f.store.getActiveProfile().controls[0].xPct, .99);
  assert.notEqual(f.store.getActiveProfile().controls[0].style.opacity, .12);
  assert.ok(f.store.getProfileNames().length > 0);
});

test('R2：系统补齐避让子控件ID，注入后满预算不能假成功或删用户控件', async () => {
  const f = fixture(); await f.store.init({});
  const profile = f.user('ID冲突', p => {
    p.controls = [{ ...p.controls.find(c => c.type === f.layout.ControlType.BUTTON), id: 'drawer',
      type: f.layout.ControlType.DRAWER, children: [{ ...p.controls[1], id: f.layout.SYS_EDIT_ID, type: f.layout.ControlType.BUTTON }] }];
    p.hotbarAutoAdded = true;
  });
  const saved = await f.store.importFromJson(JSON.stringify(profile));
  assert.ok(saved); const ids = allIds(saved.controls); assert.equal(new Set(ids).size, ids.length);
  const crowded = f.user('满预算', p => {
    const button = p.controls.find(c => c.type === f.layout.ControlType.BUTTON && !c.systemAction);
    p.controls = Array.from({ length: 256 }, (_, i) => ({ ...button, id: 'user_' + i, systemAction: undefined }));
    p.hotbarAutoAdded = true;
  });
  const review = f.store.analyzeImport(JSON.stringify(crowded));
  assert.equal(review.ok, false); assert.match(review.reason, /BudgetExceeded/);
  assert.equal(await f.store.importFromJson(JSON.stringify(crowded)), null);
  assert.equal(f.store.getProfileNames().includes('满预算'), false);
  assert.equal(crowded.controls.length, 256);
});

test('R2：不支持子摇杆导入拒绝，旧原文保留供导出；预览candidate冻结且不可修改', async () => {
  const seed = fixture();
  const unsupported = seed.user('旧深层', p => {
    p.controls = [{ ...p.controls[1], id: 'drawer', type: seed.layout.ControlType.DRAWER,
      children: [{ ...p.controls[0], id: 'child_joystick', type: seed.layout.ControlType.JOYSTICK }] }];
  });
  const text = JSON.stringify(unsupported);
  const f = fixture({ initial: { profiles: text.startsWith('[') ? text : '[' + text + ']', active_profile: unsupported.name } });
  await f.store.init({});
  assert.ok(f.store.getProfileNames().includes('旧深层'));
  assert.match(f.store.getProfileCompatibility('旧深层'), /UnsupportedFeature/);
  assert.equal(JSON.parse(f.store.exportToJson('旧深层')).controls[0].children[0].type, f.layout.ControlType.JOYSTICK);
  assert.equal(f.store.analyzeImport(text).ok, false);
  const review = f.store.analyzeImport(JSON.stringify(f.user('冻结坐标', p => { p.controls[0].xPct = .31; })));
  review.reviewedJson = JSON.stringify(f.user('替换原文', p => { p.controls[0].xPct = .91; }));
  const saved = await f.store.commitReviewedImport(review.reviewId);
  assert.equal(saved.name, '冻结坐标'); assert.equal(saved.controls[0].xPct, .31);
});
