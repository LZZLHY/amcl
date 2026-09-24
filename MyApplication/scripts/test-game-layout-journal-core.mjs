/** 执行真实 ArkTS 布局合并及会话偏好实现；系统 Preferences 只用于断言游戏侧零 XML 访问。 */
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const loadSnapshots = makePureEtsLoader();
const prefs = loadSnapshots('commons/src/main/ets/utils/PreferenceSnapshot.ets');
const load = makePureEtsLoader({ commons: prefs });
const merge = load('gamecontrol/src/main/ets/LayoutMerge.ets');
const controls = load('gamecontrol/src/main/ets/ControlLayout.ets');
const presets = load('gamecontrol/src/main/ets/LayoutPresets.ets');
const session = '00000001-0002-0003-0004-000000000005';
let cases = 0;
function check(name, action) { action(); cases++; console.log('PASS', name); }
async function checkAsync(name, action) { await action(); cases++; console.log('PASS', name); }
function profile(name, scale = 1) {
  const value = controls.getDefaultLayout();
  value.name = name; value.isPreset = false; value.globalScale = scale; value.controls = [];
  return value;
}
function snapshot(values = [], active = '') {
  return { name: 'control_layout', values: { profiles: JSON.stringify(values), active_profile: active } };
}
function users(value) { return JSON.parse(value.values.profiles).filter(p => !p.isPreset); }
function run(base, proposed, current = base) { return merge.mergeLayoutPreferences(base, proposed, current, session); }
function freeze(value) {
  if (value && typeof value === 'object') { Object.freeze(value); for (const item of Object.values(value)) freeze(item); }
  return value;
}

check('uncontended edit applies without mutating input', () => {
  const base = freeze(snapshot([profile('A')], 'A'));
  const proposed = freeze(snapshot([profile('A', 1.2)], 'A'));
  const result = run(base, proposed);
  assert.equal(users(result.snapshot)[0].globalScale, 1.2);
  assert.equal(result.snapshot.values.active_profile, 'A');
  assert.equal(result.conflicts.length, 0);
});
check('parent edits other profile survive', () => {
  const result = run(snapshot([profile('A'), profile('B')], 'A'),
    snapshot([profile('A', 1.2), profile('B')], 'A'), snapshot([profile('A'), profile('B', 1.4)], 'A'));
  assert.deepEqual(users(result.snapshot).map(p => p.globalScale), [1.2, 1.4]);
});
check('same-name conflicting edits preserve parent and stable child copy; replay idempotent', () => {
  const base = snapshot([profile('A')], 'A');
  const proposed = snapshot([profile('A', 1.2)], 'A');
  const result = run(base, proposed, snapshot([profile('A', 1.4)], 'A'));
  const values = users(result.snapshot);
  assert.equal(values.length, 2); assert.equal(values[0].name, 'A'); assert.equal(values[0].globalScale, 1.4);
  assert.match(values[1].name, /游戏冲突/); assert.equal(values[1].globalScale, 1.2);
  assert.equal(result.snapshot.values.active_profile, values[1].name);
  const replay = run(base, proposed, result.snapshot);
  assert.deepEqual(replay.snapshot, result.snapshot); assert.equal(replay.changed, false);
});
check('parent independent active choice wins over child active change', () => {
  const base = snapshot([profile('A'), profile('B'), profile('C')], 'A');
  const result = run(base, snapshot([profile('A', 1.2), profile('B'), profile('C')], 'B'),
    snapshot([profile('A'), profile('B'), profile('C')], 'C'));
  assert.equal(result.snapshot.values.active_profile, 'C');
});
check('uncontended deletion and deletion conflict are distinct', () => {
  const base = snapshot([profile('A')], 'A');
  assert.equal(users(run(base, snapshot([])).snapshot).length, 0);
  const conflict = run(base, snapshot([]), snapshot([profile('A', 1.5)], 'A'));
  assert.equal(users(conflict.snapshot)[0].globalScale, 1.5); assert.equal(conflict.conflicts.length, 1);
});
check('deletion cannot remove independently selected parent profile', () => {
  const result = run(snapshot([profile('A'), profile('B')], 'B'), snapshot([profile('B')], 'B'),
    snapshot([profile('A'), profile('B')], 'A'));
  assert.ok(users(result.snapshot).some(p => p.name === 'A'));
  assert.equal(result.snapshot.values.active_profile, 'A');
});
check('parent deletion and child edit retain child as a copy, not resurrect original', () => {
  const result = run(snapshot([profile('A')], 'A'), snapshot([profile('A', 1.3)], 'A'), snapshot([]));
  assert.equal(users(result.snapshot).length, 1); assert.notEqual(users(result.snapshot)[0].name, 'A');
});
check('same additions coalesce; competing additions preserve both', () => {
  assert.equal(users(run(snapshot([]), snapshot([profile('A')]), snapshot([profile('A')])).snapshot).length, 1);
  assert.equal(users(run(snapshot([]), snapshot([profile('A')]), snapshot([profile('A', 1.4)])).snapshot).length, 2);
});
check('first-install empty XML values accept cumulative child save', () => {
  const base = { name: 'control_layout', values: { profiles: '', active_profile: '' } };
  const result = run(base, snapshot([...presets.getAllPresets(), profile('new')], 'new'));
  assert.equal(users(result.snapshot)[0].name, 'new'); assert.equal(result.snapshot.values.active_profile, 'new');
});
check('preset-derived device geometry is neither user conflict nor authority', () => {
  const base = snapshot(presets.getAllPresets(), '★ 平板');
  const childPresets = presets.getAllPresets(); childPresets[1].globalScale = 1.6;
  const result = run(base, snapshot(childPresets, '★ 平板'));
  assert.equal(result.conflicts.length, 0);
  assert.equal(JSON.parse(result.snapshot.values.profiles).find(p => p.name === '★ 平板').globalScale,
    presets.presetTablet().globalScale);
});
check('invalid preset identities, invalid data and duplicates reject entire merge', () => {
  const base = freeze(snapshot([profile('safe')]));
  const invalidPreset = profile('forged'); invalidPreset.isPreset = true;
  for (const bad of [[profile('safe'), invalidPreset], [profile('safe'), profile('safe')],
    [profile('★ 手机')], [profile('bad', 999)], [{ name: 'bad', controls: 'not-array' }], [null]]) {
    assert.throws(() => run(base, snapshot(bad)), Error);
  }
  assert.throws(() => run(base, { name: 'control_layout', values: { profiles: '{}', active_profile: '' } }));
  assert.throws(() => run(base, snapshot([profile('safe')], 'missing')));
  assert.throws(() => run(base, { name: 'amcl_accounts', values: {} }));
  assert.throws(() => merge.mergeLayoutPreferences(base, base, base, '../../bad'));
  assert.equal(JSON.parse(base.values.profiles)[0].name, 'safe');
});
check('device metadata is not silently dropped from malformed journal', () => {
  const bad = profile('A'); bad.deviceModel = 42;
  assert.throws(() => run(snapshot([]), snapshot([bad])));
});
check('invalid current data aborts rather than discarding parent layouts', () => {
  assert.throws(() => run(snapshot([profile('A')]), snapshot([profile('A', 1.2)]),
    { name: 'control_layout', values: { profiles: '[{"name":"bad"}]', active_profile: '' } }));
});
check('input and merged output limits reject without truncation', () => {
  assert.throws(() => run(snapshot([]), snapshot(Array.from({ length: 129 }, (_, i) => profile('A' + i)))));
  assert.throws(() => run(snapshot([]), { name: 'control_layout', values: { profiles: ' '.repeat(1048577), active_profile: '' } }));
  const base = snapshot([]);
  const proposed = freeze(snapshot(Array.from({ length: 65 }, (_, i) => profile('child-' + i))));
  const current = freeze(snapshot(Array.from({ length: 65 }, (_, i) => profile('parent-' + i))));
  assert.throws(() => run(base, proposed, current));
  assert.equal(users(current).length, 65);
});
check('UTF8 bounded deterministic conflict names preserve complete emoji', () => {
  const name = '🙂'.repeat(64);
  const result = run(snapshot([profile(name)]), snapshot([profile(name, 1.2)]), snapshot([profile(name, 1.4)]));
  const copy = users(result.snapshot)[1];
  assert.ok(controls.utf8ByteLength(copy.name) <= 256); assert.ok(!copy.name.includes('\ud83d（'));
  assert.deepEqual(run(snapshot([profile(name)]), snapshot([profile(name, 1.2)]), result.snapshot).snapshot, result.snapshot);
});
check('occupied conflict name never overwrites parent content', () => {
  const base = snapshot([profile('A')]); const proposed = snapshot([profile('A', 1.2)]);
  const initial = run(base, proposed, snapshot([profile('A', 1.4)]));
  const occupied = users(initial.snapshot)[1].name;
  const result = run(base, proposed, snapshot([profile('A', 1.4), profile(occupied, 1.7)]));
  assert.equal(users(result.snapshot).find(p => p.name === occupied).globalScale, 1.7);
  assert.equal(users(result.snapshot).length, 3);
  assert.deepEqual(run(base, proposed, result.snapshot).snapshot, result.snapshot);
});
check('handwritten gamepad map key order does not create conflict', () => {
  const first = profile('A'); first.gamepad = { buttonMap: { a: { kind: 'none' }, b: { kind: 'hotbarNext' } } };
  const second = profile('A'); second.gamepad = { buttonMap: { b: { kind: 'hotbarNext' }, a: { kind: 'none' } } };
  const result = run(snapshot([first]), snapshot([second])); assert.equal(result.conflicts.length, 0);
});
check('non-layout preferences cannot be mutated by proposed', () => {
  const base = snapshot([]); base.values.legacy = true;
  const proposed = structuredClone(base); proposed.values.legacy = false;
  assert.throws(() => run(base, proposed));
});

await checkAsync('journal store keeps launch base constant across cumulative commits', async () => {
  const base = snapshot([]); const calls = [];
  const store = new prefs.GameLayoutLaunchPreferences(base, { async commit(b, p) { calls.push(structuredClone({ b, p })); } });
  await store.put('profiles', JSON.stringify([profile('A')])); await store.put('active_profile', 'A'); await store.flush();
  await store.put('profiles', JSON.stringify([profile('A'), profile('B')])); await store.flush();
  assert.deepEqual(calls[0].b, base); assert.deepEqual(calls[1].b, base);
  assert.equal(JSON.parse(calls[1].p.values.profiles).length, 2); assert.equal(base.values.profiles, '[]');
});
await checkAsync('failed sink rolls back both overlay keys to last successful state', async () => {
  let fail = false;
  const store = new prefs.GameLayoutLaunchPreferences(snapshot([]), { async commit() { if (fail) throw Error('disk full'); } });
  await store.put('profiles', '["first"]'); await store.put('active_profile', 'first'); await store.flush();
  fail = true; await store.put('profiles', '["bad"]'); await store.put('active_profile', 'bad');
  await assert.rejects(store.flush(), /disk full/);
  assert.equal(store.getSync('profiles', ''), '["first"]'); assert.equal(store.getSync('active_profile', ''), 'first');
});
await checkAsync('flush waits persistence, blocks concurrent puts and coalesces duplicate flush', async () => {
  let release; let count = 0;
  const wait = new Promise(resolve => { release = resolve; });
  const store = new prefs.GameLayoutLaunchPreferences(snapshot([]), { async commit() { count++; await wait; } });
  const first = store.flush(); const second = store.flush();
  assert.throws(() => store.putSync('profiles', '[]'), /in progress/);
  // 撤销接口同样不得抢占在途提交；完成后则只恢复最后一次已确认内容。
  assert.throws(() => store.discardUncommitted(), /in progress/);
  assert.equal(count, 1); release(); await Promise.all([first, second]);
  store.putSync('profiles', '[]');
  store.discardUncommitted();
});
await checkAsync('synchronous sink reentry cannot edit overlay before pending promise publication', async () => {
  let store;
  store = new prefs.GameLayoutLaunchPreferences(snapshot([]), { async commit() {
    assert.throws(() => store.putSync('active_profile', 'reentrant'), /in progress/);
  } });
  await store.flush(); assert.equal(store.getSync('active_profile', ''), '');
});
await checkAsync('sink receives isolated copies and cannot mutate baseline or committed overlay', async () => {
  const base = snapshot([]);
  const store = new prefs.GameLayoutLaunchPreferences(base, { async commit(b, p) {
    b.values.profiles = 'tampered base'; p.values.profiles = 'tampered proposed';
  } });
  await store.put('profiles', JSON.stringify([profile('A')])); await store.flush();
  assert.equal(JSON.parse(store.getSync('profiles', ''))[0].name, 'A'); assert.equal(base.values.profiles, '[]');
});
await checkAsync('actual business validation rejects staged bad JSON and restores last committed layout', async () => {
  const base = snapshot([profile('A')], 'A');
  const store = new prefs.GameLayoutLaunchPreferences(base, { async commit(b, p) { run(b, p, b); } });
  await store.put('profiles', 'not-json'); await store.put('active_profile', 'bad');
  await assert.rejects(store.flush());
  assert.equal(store.getSync('profiles', ''), base.values.profiles); assert.equal(store.getSync('active_profile', ''), 'A');
  await store.put('profiles', JSON.stringify([profile('A', 1.2)])); await store.flush();
  assert.equal(JSON.parse(store.getSync('profiles', ''))[0].globalScale, 1.2);
});
await checkAsync('only the two string keys are writable; no delete or account upgrade', async () => {
  const store = new prefs.GameLayoutLaunchPreferences(snapshot([]), { async commit() {} });
  for (const pair of [['extra', 'x'], ['profiles', 2], ['active_profile', true]]) assert.throws(() => store.putSync(...pair));
  assert.throws(() => store.deleteSync('profiles')); assert.throws(() => store.putSync('profiles', 'x'.repeat(1048577)));
  assert.throws(() => new prefs.GameLayoutLaunchPreferences({ name: 'amcl_accounts', values: {} }, { async commit() {} }));
  const immutable = new prefs.ReadOnlyLaunchPreferences({ name: 'amcl_settings', values: { value: 2 } });
  assert.throws(() => immutable.putSync('value', 3)); assert.equal(immutable.getSync('value', 0), 2);
});
await checkAsync('production ProcessPreferences injection leaves account/settings read-only and never opens XML', async () => {
  let xml = 0;
  const make = () => makePureEtsLoader({ '@kit.ArkData': { preferences: { getPreferencesSync() { xml++; throw Error('unexpected XML'); } } } })
    ('commons/src/main/ets/utils/ProcessPreferences.ets').ProcessPreferences;
  const snapshots = [{ name: 'amcl_accounts', values: { secret: 'unchanged' } },
    { name: 'amcl_settings', values: { setting: true } }, snapshot([])];
  const process = make(); const sink = { async commit() {} };
  assert.throws(() => process.installGameLayoutCommitSink(sink));
  process.installGameSnapshots(snapshots); process.installGameLayoutCommitSink(sink);
  assert.throws(() => process.installGameLayoutCommitSink(sink));
  const layout = process.open({}, 'control_layout'); await layout.put('profiles', '[]'); await layout.flush();
  assert.throws(() => process.open({}, 'amcl_accounts').putSync('secret', 'overwrite'));
  assert.throws(() => process.open({}, 'amcl_settings').putSync('setting', false));
  assert.throws(() => process.open({}, 'missing')); await assert.rejects(process.captureOwner({}, 'control_layout'));
  const late = make(); late.installGameSnapshots(snapshots); late.open({}, 'control_layout');
  assert.throws(() => late.installGameLayoutCommitSink(sink)); assert.equal(xml, 0);
});
console.log(`PASS ${cases} game layout journal core scenarios`);
