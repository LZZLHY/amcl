#!/usr/bin/env node
/**
 * 分辨率政策与持久化回归。执行真实纯 ArkTS 和 PreferenceManager 的方法，平台仅替换
 * 为可控存储边界；覆盖继承/明确100%、旧参数、引号隔离以及 flush 失败的确认屏障。
 * 这不证明 ArkUI 布局、NativeWindow 或游戏实际图像，设备验收另行执行。
 */
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const pure = makePureEtsLoader();
const policy = pure('commons/src/main/ets/common/GameResolutionPolicy.ets');
const tokens = pure('commons/src/main/ets/utils/JvmArgumentTokens.ets');
const languages = pure('commons/src/main/ets/common/GameLanguages.ets');
const { normalizeResolutionPreference, resolveResolutionPercent, withResolutionPolicy, gameResolutionDimension } = policy;
assert.equal(normalizeResolutionPreference(undefined), 0);
for (const invalid of [NaN, Infinity, -1, 49, 101]) assert.equal(normalizeResolutionPreference(invalid), 0);
assert.equal(normalizeResolutionPreference(100), 100);
assert.equal(resolveResolutionPercent(100, ['-Damcl.render.scale=0.5']), 100);
assert.equal(resolveResolutionPercent(0, ['-Damcl.render.scale=0.5', '-Damcl.render.scale=0.75']), 75);
assert.equal(resolveResolutionPercent(0, ['-Damcl.render.scale=0.75', '-Damcl.render.scale=broken']), 100);
assert.equal(resolveResolutionPercent(0, ['-Damcl.render.scale=7.5e-1']), 75);
assert.equal(resolveResolutionPercent(0, tokens.splitJvmArguments('-Ddescription="-Damcl.render.scale=0.5"')), 100);
assert.deepEqual(tokens.splitJvmArguments('"-Damcl.render.scale=0.75" -Dpath="a b"'), ['-Damcl.render.scale=0.75', '-Dpath=a b']);
const oldArgs = ['-Da=1', '-Damcl.render.scale=0.5', '-Db=2', '-Damcl.render.scale=0.8'];
assert.deepEqual(withResolutionPolicy(oldArgs, 100), ['-Da=1', '-Db=2', '-Damcl.render.scale=1']);
assert.equal(oldArgs.length, 4);
assert.deepEqual([gameResolutionDimension(2688, 75), gameResolutionDimension(1216, 75)], [2016, 912]);
assert.equal(gameResolutionDimension(2801, 100), 2801);
assert.equal(gameResolutionDimension(2801, 75), 2100);
assert.equal(gameResolutionDimension(0, 75), 0);

/** 故障只注入真实持久边界；算法不在 fixture 中复写。 */
class Store {
  values = new Map();
  failures = 0;
  pendingFlush;
  getSync(key, fallback) { return this.values.has(key) ? this.values.get(key) : fallback; }
  putSync(key, value) { this.values.set(key, value); }
  async put(key, value) { this.putSync(key, value); }
  async get(key, fallback) { return this.getSync(key, fallback); }
  deleteSync(key) { this.values.delete(key); }
  async flush() {
    if (this.failures > 0) { this.failures--; throw new Error('injected flush failure'); }
    if (this.pendingFlush) await this.pendingFlush;
  }
}
const store = new Store();
let child = false;
const load = makePureEtsLoader({
  commons: { ...policy, ...languages, ProcessPreferences: { open: () => store, isGameProcess: () => child }, formatError: String },
  '@kit.PerformanceAnalysisKit': { hilog: { warn() {} } },
});
const { PreferenceManager } = load('feature_system/src/main/ets/PreferenceManager.ets');
const pref = new PreferenceManager({ preferencesDir: '/resolution-fixture' });
assert.equal(pref.resolutionScalePercent, 0);
await pref.saveResolutionScalePercent(75);
assert.equal(pref.resolveLaunch('instance').renderScalePercent, 75);
pref.setVersionOverride('instance', { xmx: 2048, jdkVersion: '17', customJvmArgs: '-Dkeep=value', gameLanguage: 'en_us' });
await pref.saveResolutionScalePercent(100, 'instance');
assert.equal(pref.resolveLaunch('instance').renderScalePercent, 100);
assert.equal(pref.getVersionOverride('instance').customJvmArgs, '-Dkeep=value');
assert.equal(pref.getVersionOverride('instance').xmx, 2048);
await pref.saveResolutionScalePercent(0, 'instance');
assert.equal(pref.resolveLaunch('instance').renderScalePercent, 75);
// 未确认的 put 不能污染下一次启动快照，成功 flush 后才发布新值。
let confirm;
store.pendingFlush = new Promise(resolve => { confirm = resolve; });
const saving = pref.saveResolutionScalePercent(50);
await Promise.resolve();
assert.equal(pref.resolutionScalePercent, 75);
store.pendingFlush = undefined;
confirm();
await saving;
assert.equal(pref.resolutionScalePercent, 50);
store.failures = 1;
await assert.rejects(pref.saveResolutionScalePercent(85), /injected flush failure/);
assert.equal(pref.resolutionScalePercent, 50);
assert.equal(store.getSync('resolutionScalePercent', -1), 50);
await Promise.all([pref.saveResolutionScalePercent(75), pref.saveResolutionScalePercent(100)]);
assert.equal(pref.resolutionScalePercent, 100);
// 共享实例JSON在分辨率flush期间仍可能被JDK/语言等既有入口更新。
// 这些入口读到确认屏障的旧比例，不能把本次在途的新比例写回旧值，也不能丢失JDK更改。
await pref.saveResolutionScalePercent(75, 'instance');
let finishInstance;
store.pendingFlush = new Promise(resolve => { finishInstance = resolve; });
const instanceSave = pref.saveResolutionScalePercent(50, 'instance');
await Promise.resolve();
const concurrentOverride = pref.getVersionOverride('instance');
assert.equal(concurrentOverride.renderScalePercent, 75);
concurrentOverride.jdkVersion = '21';
pref.setVersionOverride('instance', concurrentOverride);
store.pendingFlush = undefined;
finishInstance();
await instanceSave;
assert.equal(pref.getVersionOverride('instance').renderScalePercent, 50);
assert.equal(pref.getVersionOverride('instance').jdkVersion, '21');
await assert.rejects(pref.saveResolutionScalePercent(25), /比例无效/);
child = true;
await assert.rejects(pref.saveResolutionScalePercent(50), /启动器/);
assert.equal(store.getSync('resolutionScalePercent', -1), 100);
console.log('game-resolution-policy: policy, inheritance, confirmed persistence and failure cases passed');
