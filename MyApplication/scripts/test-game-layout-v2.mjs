/** 实跑snapshot→V2文件→child懒仓库→净修改→owner三方事务，边界替身仅文件、Preferences、PID/游戏锁。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fixture } from './lib/game-layout-fixture.mjs';
const ID = '12345678-1234-4234-8234-123456789abc';
const session = f => f.disk.directory + '/game-layout-v2/' + (f.v2Id ?? ID);
const read = (f, name) => JSON.parse(fs.readFileSync(session(f) + '/' + name, 'utf8'));

function seed(f, count, full = false) {
  const layout = f.owner.load('gamecontrol/src/main/ets/ControlLayout.ets');
  const profiles = [];
  for (let i = 0; i < count; i++) {
    const profile = layout.getDefaultLayout(); profile.name = '用户' + i; profile.isPreset = false;
    if (full) {
      const button = profile.controls.find(c => c.type === layout.ControlType.BUTTON && !c.systemAction);
      const system = profile.controls.filter(c => c.systemAction);
      profile.controls = [...system, ...Array.from({ length: 248 - system.length }, (_, j) => ({ ...structuredClone(button),
        id: 'u_' + j, label: '"'.repeat(256), hidden: false, locked: false, menuOnly: false,
        visibilityOverride: 'force_show', hideOnInput: ['mouse', 'keyboard', 'mouse_and_keyboard'],
        style: { bg: '#FFFFFF' + ' '.repeat(57), bgPressed: '#FFFFFF' + ' '.repeat(57), fg: '#FFFFFF' + ' '.repeat(57), opacity: .999999999, shape: 'rounded', cornerRadius: .199999999 },
      }))];
      profile.hotbarAutoAdded = true;
    }
    profiles.push(profile);
  }
  const raw = JSON.stringify(profiles);
  f.ownerData.set('control_layout', new Map([['profiles', raw], ['active_profile', '用户0']]));
  return raw;
}

test('V2完整>128方案/>1MiB库启动，ticket有界、非active载荷懒读，parent不参与游戏内管理', async () => {
  const f = fixture();
  try {
    const raw = seed(f, 200); assert.ok(Buffer.byteLength(raw) > 1024 * 1024);
    await f.launchV2(); const root = read(f, 'root.json');
    assert.equal(root.schema, 2); assert.equal(root.profileCount, 202); assert.ok(root.catalogPageCount > 1);
    assert.equal(f.child.xmlOpens(), 0); assert.ok(f.child.store.getProfileNames().includes('用户199'));
    const base = session(f) + '/base_201_0.chunk'; const content = fs.readFileSync(base, 'utf8'); fs.writeFileSync(base, content + ' ');
    assert.throws(() => f.child.store.getProfile('用户199'), /digest|size drift/);
    fs.writeFileSync(base, content);
    await f.child.store.setActiveProfile('用户199');
    const clone = await f.child.store.cloneAsUser('用户199'); assert.ok(clone);
    assert.equal(await f.child.store.renameProfile(clone.name, '游戏副本'), true);
    assert.equal(await f.child.store.deleteProfile('用户198'), true);
    assert.equal(f.child.xmlOpens(), 0);
    f.state.lock = 0; const result = await f.owner.journal.importPending(f.disk.context);
    assert.equal(result.imported, 1); assert.ok(f.owner.store.getProfileNames().includes('游戏副本'));
    assert.equal(f.owner.store.getProfileNames().includes('用户198'), false);
  } finally { f.disk.close(); }
});

test('V2单方案多块载荷保持完整，块篡改/缺失拒绝而不换成空表', async () => {
  const f = fixture();
  try {
    seed(f, 2, true); await f.launchV2();
    const root = read(f, 'root.json'); const page = read(f, 'catalog_0.json');
    const entry = page.entries.find(e => e.name === '用户1'); const descriptor = read(f, entry.payloadId + '.json');
    assert.ok(descriptor.bytes > 256 * 1024); assert.ok(descriptor.chunkDigests.length > 1);
    const file = session(f) + '/' + entry.payloadId + '_1.chunk'; const bytes = fs.readFileSync(file);
    fs.unlinkSync(file); assert.throws(() => f.child.store.getProfile('用户1'), /ENOENT/);
    fs.writeFileSync(file, bytes); await f.child.store.setActiveProfile('用户1');
    assert.equal(f.child.store.getActiveProfile().controls.length, 248); assert.equal(root.profileCount, 4);
  } finally { f.disk.close(); }
});

test('V2净修改重复编辑替换同一项，失败保留上一journal及全部引用', async () => {
  const f = fixture();
  try {
    seed(f, 2); await f.launchV2();
    for (let i = 0; i < 3; i++) { const p = f.child.store.getProfile('用户0'); p.lookSensitivity = .7 + i * .2; assert.equal(await f.child.store.saveProfile(p), true); }
    const record = read(f, 'pending.json'); const page = read(f, 'changes_' + record.revision + '_0.json');
    assert.equal(page.changes.length, 1); const original = fs.readFileSync(session(f) + '/pending.json', 'utf8');
    f.disk.control.failWrite = path => String(path).includes('/pending.json.') && String(path).endsWith('/content.pending');
    const p = f.child.store.getProfile('用户0'); p.lookSensitivity = 2;
    await assert.rejects(() => f.child.store.saveProfile(p), /保存失败|RollbackFailed/);
    assert.equal(fs.readFileSync(session(f) + '/pending.json', 'utf8'), original);
    assert.equal(f.child.store.getProfile('用户0').lookSensitivity, 1.1);
    f.disk.control.failWrite = undefined; f.state.lock = 0;
    assert.equal((await f.owner.journal.importPending(f.disk.context)).imported, 1);
    assert.equal(f.owner.store.getProfile('用户0').lookSensitivity, 1.1);
  } finally { f.disk.close(); }
});

test('V2父子同实体冲突保留两份，父侧独立active选择不被child覆盖', async () => {
  const f = fixture();
  try {
    seed(f, 3); await f.launchV2();
    const child = f.child.store.getProfile('用户0'); child.lookSensitivity = .8; assert.equal(await f.child.store.saveProfile(child), true);
    const parent = f.owner.store.getProfile('用户0'); parent.lookSensitivity = 1.8; assert.equal(await f.owner.store.saveProfile(parent), true);
    await f.owner.store.setActiveProfile('用户2'); f.state.lock = 0;
    const result = await f.owner.journal.importPending(f.disk.context); assert.equal(result.conflicts.length, 1);
    assert.equal(f.owner.store.getProfile('用户0').lookSensitivity, 1.8);
    const conflict = f.owner.store.getAllProfiles().find(p => p.name.includes('游戏冲突')); assert.equal(conflict.lookSensitivity, .8);
    assert.notEqual(conflict.profileId, parent.profileId); assert.equal(f.owner.store.getActiveProfile().name, '用户2');
  } finally { f.disk.close(); }
});

test('V2删除后同名重建不能被旧child覆盖；回执失败重试不复活owner后来删除', async () => {
  const f = fixture();
  try {
    seed(f, 2); await f.launchV2();
    const child = f.child.store.getProfile('用户0'); child.lookSensitivity = .8; assert.equal(await f.child.store.saveProfile(child), true);
    await f.owner.store.deleteProfile('用户0'); const recreated = await f.owner.store.createProfile('用户0');
    assert.notEqual(recreated.profileId, child.profileId); f.state.lock = 0;
    f.disk.control.failWrite = path => String(path).includes('/applied.json.') && String(path).endsWith('/content.pending');
    await assert.rejects(() => f.owner.journal.importPending(f.disk.context), /保存失败/);
    assert.equal(f.owner.store.getProfile('用户0').profileId, recreated.profileId);
    const conflict = f.owner.store.getAllProfiles().find(p => p.name.includes('游戏冲突')); assert.ok(conflict);
    await f.owner.store.deleteProfile(conflict.name); f.disk.control.failWrite = undefined;
    assert.equal((await f.owner.journal.importPending(f.disk.context)).imported, 1);
    assert.equal(f.owner.store.getProfileNames().some(name => name.includes('游戏冲突')), false);
  } finally { f.disk.close(); }
});

test('V2 ownerflush失败回滚，租约活跃延后，原文可重试且完整目录仍在', async () => {
  const f = fixture();
  try {
    await f.launchV2(); await f.child.store.createProfile('child'); f.state.lock = 0;
    assert.equal(f.owner.store.beginEditorSession(), true);
    assert.equal((await f.owner.journal.importPending(f.disk.context)).deferred, true);
    f.owner.store.endEditorSession(); f.owner.store.commitEditorTransaction();
    f.state.failOwnerFlushCount = 1; const original = fs.readFileSync(session(f) + '/pending.json', 'utf8');
    await assert.rejects(() => f.owner.journal.importPending(f.disk.context), /owner disk failure/);
    assert.equal(fs.readFileSync(session(f) + '/pending.json', 'utf8'), original);
    assert.equal(f.owner.store.getProfileNames().includes('child'), false);
    assert.equal((await f.owner.journal.importPending(f.disk.context)).imported, 1);
    assert.ok(fs.existsSync(session(f) + '/root.json'));
  } finally { f.disk.close(); }
});

test('R0/V2近16MiB旧库先备份迁目录，identity膨胀不突破XML，冷启动/缩减/游戏启动完整', async () => {
  const f = fixture();
  try {
    const unit = seed(f, 1, true);
    const count = Math.floor((16 * 1024 * 1024 - 4096) / (Buffer.byteLength(unit) + 16));
    const profiles = JSON.parse(seed(f, count, true));
    const target = 16 * 1024 * 1024 - 1024;
    let remaining = target - Buffer.byteLength(JSON.stringify(profiles));
    // 保持当前校验接受的64字符样式字段，填满真实UTF-8字节，来源仍低于旧SDK单值16MiB。
    for (const profile of profiles) for (const control of profile.controls) {
      if (!control.style || !control.style.bg?.endsWith(' '.repeat(57))) continue;
      for (const key of ['bg', 'bgPressed', 'fg']) {
        const amount = Math.min(57, Math.floor(remaining / 2));
        control.style[key] = '#FFFFFF' + '中'.repeat(amount) + ' '.repeat(57 - amount); remaining -= amount * 2;
      }
    }
    const raw = JSON.stringify(profiles); assert.ok(Buffer.byteLength(raw) <= target);
    f.ownerData.set('control_layout', new Map([['profiles', raw], ['active_profile', '用户0']]));
    const beforePeak = process.resourceUsage().maxRSS;
    await f.owner.store.init(f.disk.context);
    const owner = f.ownerData.get('control_layout'); const pointer = JSON.parse(owner.get('profiles_backend'));
    assert.equal(owner.get('profiles'), raw, '原XML只作恢复原文保留，不写入膨胀后的超限值');
    assert.equal(fs.readFileSync(f.disk.directory + '/layout-library/' + pointer.generation + '/legacy-original.json', 'utf8'), raw);
    const snapshot = await f.owner.store.captureLaunchPreferences();
    const normalizedBytes = Buffer.byteLength(snapshot.values.profiles);
    assert.ok(normalizedBytes > 16 * 1024 * 1024, '身份/系统规范化超过旧XML边界，用目录后端保存');
    assert.ok(normalizedBytes < 32 * 1024 * 1024);
    const restarted = f.restartOwner(); await restarted.store.init(f.disk.context);
    assert.equal(restarted.store.getProfileNames().length, count + 2);
    assert.equal((await restarted.store.captureLaunchPreferences()).values.profiles, snapshot.values.profiles);
    await f.launchV2(); assert.equal(f.child.xmlOpens(), 0); assert.equal(f.child.store.getProfileNames().length, count + 2);
    await f.child.store.deleteProfile('用户' + (count - 1)); f.state.lock = 0;
    assert.equal((await f.owner.journal.importPending(f.disk.context)).imported, 1);
    assert.equal(f.owner.store.getProfileNames().includes('用户' + (count - 1)), false);
    const peak = process.resourceUsage().maxRSS;
    console.log(JSON.stringify({ evidence: 'layout-budget-host', rawBytes: Buffer.byteLength(raw), normalizedBytes,
      profiles: count + 2, beforeMaxRssKiB: beforePeak, maxRssKiB: peak, heapUsedBytes: process.memoryUsage().heapUsed,
      limitation: 'Node宿主进程峰值，包括本文件前面的场景；不代表HarmonyOS SDK/设备峰值' }));
  } finally { f.disk.close(); }
});

test('R0预算32MiB整库负例拒绝；历史库非增长编辑与metadata推进仍允许', () => {
  const f = fixture();
  try {
    const budget = f.owner.load('gamecontrol/src/main/ets/LayoutBudget.ets');
    const profiles = JSON.parse(seed(f, 140, true));
    assert.ok(Buffer.byteLength(JSON.stringify(profiles)) > budget.MAX_LAYOUT_LIBRARY_BYTES);
    assert.throws(() => budget.validateLayoutLibraryBudget([], profiles), /BudgetExceeded/);
    const before = profiles.slice(0, 64), after = structuredClone(before);
    assert.ok(Buffer.byteLength(JSON.stringify(before)) > budget.MAX_LAYOUT_XML_BYTES);
    for (const profile of after) { profile.profileId = 'old_' + profile.name; profile.profileRevision = 10; }
    budget.validateLayoutLibraryBudget(before, after);
    after.push(structuredClone(after[0])); assert.throws(() => budget.validateLayoutLibraryBudget(before, after), /BudgetExceeded/);
  } finally { f.disk.close(); }
});

test('R3合法小raw但规范化>32MiB历史库source启动、完整懒目录及删减回传，不走全库硬门', async () => {
  const f = fixture();
  try {
    const profiles = Array.from({ length: 18000 }, (_, index) => ({ name: '旧源' + index, controls: [], globalScale: 1 }));
    const raw = JSON.stringify(profiles); assert.ok(Buffer.byteLength(raw) < 16 * 1024 * 1024);
    f.ownerData.set('control_layout', new Map([['profiles', raw], ['active_profile', '旧源0']]));
    await f.launchV2(); const root = read(f, 'root.json');
    assert.equal(root.encoding, 'legacy-source'); assert.equal(root.profileCount, 18002);
    assert.equal(root.sourceRawBytes, Buffer.byteLength(raw)); assert.equal(root.sourceGrowthCredit, 0);
    assert.equal(f.ownerData.get('control_layout').get('profiles'), raw);
    assert.ok(f.ownerData.get('control_layout').get('profiles_source_backend'));
    assert.equal(f.child.xmlOpens(), 0); assert.equal(f.child.store.getProfileNames().length, 18002);
    const before = f.child.store.getProfile('旧源17999'); assert.ok(before.controls.some(control => control.systemAction === 'edit'));
    assert.equal(await f.child.store.deleteProfile('旧源17999'), true); f.state.lock = 0;
    const report = await f.owner.journal.importPending(f.disk.context); assert.equal(report.imported, 1);
    assert.equal(f.owner.store.getProfileNames().includes('旧源17999'), false);
    const marker = f.ownerData.get('control_layout').get('game_layout_applied_' + f.v2Id); assert.match(marker, /^[0-9a-f]{64}$/);
    const restarted = f.restartOwner(); await restarted.store.init(f.disk.context);
    assert.equal(restarted.store.getProfileNames().length, 18001);
    assert.equal(restarted.store.getProfile('旧源0').profileId, f.owner.store.getProfile('旧源0').profileId);
    console.log(JSON.stringify({ evidence: 'grandfather-source-host', rawBytes: Buffer.byteLength(raw), sourceProfiles: 18000,
      frozenProfiles: root.profileCount, frozenRawPayloadBytes: root.totalBytes, estimatedCanonicalMinimumBytes: 18000 * 1967,
      maxRssKiB: process.resourceUsage().maxRSS, limitation: 'Node宿主旧源组合；SDK设备峰值仍需真机' }));
  } finally { f.disk.close(); }
});

test('R3父目录junction不能跳出V2/owner私有根，拒绝且目标目录无新增', async () => {
  for (const name of ['game-layout-v2', 'layout-library']) {
    const f = fixture();
    try {
      const outside = f.disk.context.tempDir + '/outside'; fs.mkdirSync(outside);
      fs.symlinkSync(outside, f.disk.directory + '/' + name, 'junction');
      if (name === 'game-layout-v2') await assert.rejects(() => f.owner.snapshot.prepare(f.disk.context, 100, '1.16.5', f.activity), /linked|ordinary/);
      else {
        const preference = f.owner.process.open(f.disk.context, 'control_layout');
        await preference.put('profiles', JSON.stringify([{ payload: 'x'.repeat(9 * 1024 * 1024) }]));
        await assert.rejects(() => preference.flush(), /链接|普通目录/);
      }
      assert.deepEqual(fs.readdirSync(outside), []);
    } finally { f.disk.close(); }
  }
});

test('V2长方案ID共享前缀仍产生不同冲突副本；内容冲突不改变双方未修改的active选择', async () => {
  const f = fixture();
  try {
    const profiles = JSON.parse(seed(f, 2));
    const prefix = 'same_source_prefix_012345678901234567890';
    profiles[0].profileId = prefix + '_A'; profiles[0].profileRevision = 1;
    profiles[1].profileId = prefix + '_B'; profiles[1].profileRevision = 1;
    f.ownerData.set('control_layout', new Map([['profiles', JSON.stringify(profiles)], ['active_profile', '用户0']]));
    await f.launchV2();
    for (const name of ['用户0', '用户1']) {
      const child = f.child.store.getProfile(name); child.lookSensitivity = .8;
      assert.equal(await f.child.store.saveProfile(child), true);
      const parent = f.owner.store.getProfile(name); parent.lookSensitivity = 1.8;
      assert.equal(await f.owner.store.saveProfile(parent), true);
    }
    // saveProfile会选中被编辑项；把最终独立选择恢复为冻结基线，才证明两侧都未改变选择。
    await f.child.store.setActiveProfile('用户0'); await f.owner.store.setActiveProfile('用户0');
    f.state.lock = 0;
    const report = await f.owner.journal.importPending(f.disk.context);
    const copies = f.owner.store.getAllProfiles().filter(p => p.name.includes('游戏冲突'));
    assert.equal(report.conflicts.length, 2); assert.equal(copies.length, 2);
    assert.equal(new Set(copies.map(p => p.profileId)).size, 2, '身份哈希必须覆盖完整source ID');
    assert.equal(f.owner.store.getActiveProfile().name, '用户0', '内容冲突不等于child修改选择');
  } finally { f.disk.close(); }
});

test('V2 child明确选择的非active方案已被parent删除，保留pending并给TargetMissing', async () => {
  const f = fixture();
  try {
    seed(f, 2); await f.launchV2();
    await f.child.store.setActiveProfile('用户1');
    const pending = fs.readFileSync(session(f) + '/pending.json', 'utf8');
    assert.equal(await f.owner.store.deleteProfile('用户1'), true);
    assert.equal(f.owner.store.getActiveProfile().name, '用户0');
    f.state.lock = 0;
    await assert.rejects(() => f.owner.journal.importPending(f.disk.context), /TargetMissing/);
    assert.equal(fs.readFileSync(session(f) + '/pending.json', 'utf8'), pending);
    assert.equal(f.owner.store.getActiveProfile().name, '用户0');
  } finally { f.disk.close(); }
});

test('V2 owner现读库的重复名称/非法current被拒，child原文可恢复且不标applied', async () => {
  for (const corruption of ['duplicate-name', 'invalid-geometry']) {
    const f = fixture();
    try {
      seed(f, 2); await f.launchV2(); await f.child.store.createProfile('child-safe');
      const pending = fs.readFileSync(session(f) + '/pending.json', 'utf8');
      const owner = f.ownerData.get('control_layout');
      const profiles = JSON.parse(owner.get('profiles'));
      const users = profiles.filter(p => p.isPreset !== true);
      if (corruption === 'duplicate-name') users[1].name = users[0].name;
      else users[0].globalScale = -1;
      owner.set('profiles', JSON.stringify(profiles)); f.state.lock = 0;
      await assert.rejects(() => f.owner.journal.importPending(f.disk.context), /Invalid owner/);
      assert.equal(fs.readFileSync(session(f) + '/pending.json', 'utf8'), pending);
      assert.equal(fs.existsSync(session(f) + '/applied.json'), false);
    } finally { f.disk.close(); }
  }
});
