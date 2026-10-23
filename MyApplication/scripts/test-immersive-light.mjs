/**
 * 沉浸光感整组配置与五处标题宿主回归。
 * 执行生产ETS的迁移、保存、策略、标题options和设置事件方法，仅隔离平台存储与UI声明。
 * 不执行像素绘制；实际DSL、SDK兼容转换和HAP由正常构建验证，真机视觉另验。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { PROJECT_ROOT, assertExternalOutputPath } from './lib/workspace-paths.mjs';
import { loadActionComponent } from './lib/unified-actions-fixture.mjs';

const index = process.argv.indexOf('--output');
if (index < 0) throw new Error('请通过 --output 指定外置证据目录');
const output = assertExternalOutputPath(process.argv[index + 1]);
fs.mkdirSync(output, { recursive: true });
const startedAt = new Date().toISOString(), passed = [];
const pass = name => { passed.push(name); console.log('PASS ' + name); };
const sourcePaths = ['commons/src/main/ets/common/DockLight.ets', 'commons/src/main/ets/common/ImmersiveLight.ets',
  'feature_system/src/main/ets/PreferenceManager.ets', 'entry/src/main/ets/components/ImmersiveLightRuntime.ets',
  'entry/src/main/ets/components/ImmersiveTitleScaffold.ets', 'entry/src/main/ets/components/ImmersiveLightSettings.ets',
  'entry/src/main/ets/pages/tabs/SettingsTab.ets', 'entry/src/main/ets/pages/Index.ets'];
const sourceHashes = () => Object.fromEntries(sourcePaths.map(file => [file,
  createHash('sha256').update(fs.readFileSync(path.join(PROJECT_ROOT, file))).digest('hex')]));
const initialHashes = sourceHashes();
const load = makePureEtsLoader();
// 图标查找继续执行生产目录，只有系统资源解析是宿主边界；新标题共享依赖不能用空枚举掩盖。
globalThis.$r = value => value;
const common = { ...load('commons/src/main/ets/common/DockLight.ets'), ...load('commons/src/main/ets/common/ImmersiveLight.ets'),
  ...load('commons/src/main/ets/common/IconCatalog.ets') };
const { DockLightMode: M, ImmersiveLightModule: Module, ImmersiveLightPreferences: Preferences,
  migrateImmersiveLightPreferences: migrate, copyImmersiveLightPreferences: copy,
  encodeImmersiveLightPreferences: encode, decodeImmersiveLightPreferences: decode,
  resolveImmersiveLightMode: resolve } = common;

// 缺失新键的五档迁移保持旧效果范围，未知新记录不得复活旧偏好或打开新模块。
for (const mode of Object.values(M)) {
  const result = migrate(mode);
  assert.equal(result.enabled, mode !== M.OFF);
  assert.equal(result.navigationMode, mode === M.OFF ? M.AUTO : mode);
  assert.equal(result.bottomBar, true); assert.equal(result.titleButtons, false);
}
for (const raw of ['', '{}', 'null', '{"version":2}', '{"version":1,"enabled":true,"navigationMode":"off","bottomBar":true,"titleButtons":true}']) {
  assert.equal(decode(raw).enabled, false);
}
const selected = new Preferences(); selected.titleButtons = true; selected.navigationMode = M.EXQUISITE;
assert.deepEqual(decode(encode(selected)), selected);
const disabled = copy(selected); disabled.enabled = false;
assert.equal(resolve(disabled, Module.BOTTOM_BAR, true, true), M.OFF);
assert.equal(resolve(disabled, Module.TITLE_BUTTONS, true, true), M.OFF);
assert.equal(disabled.titleButtons, true); assert.equal(disabled.navigationMode, M.EXQUISITE);
disabled.enabled = true;
assert.equal(resolve(disabled, Module.TITLE_BUTTONS, true, false), M.SMOOTH);
assert.equal(resolve(disabled, Module.TITLE_BUTTONS, false, false), M.OFF);
assert.equal(resolve(disabled, Module.BOTTOM_BAR, false, false), M.AUTO);
disabled.bottomBar = false;
assert.equal(resolve(disabled, Module.BOTTOM_BAR, true, true), M.OFF);
assert.equal(resolve(disabled, Module.TITLE_BUTTONS, true, true), M.EXQUISITE);
pass('五档迁移、损坏记录、安全缺省与总开关/模块/能力优先级');

// 缓存与磁盘分离，flush可延迟或失败；同目录不同manager必须共享确认屏障与队列。
const key = 'immersiveLightPreferences', stores = new Map();
let game = false;
function storage(directory = '/light-controls') {
  if (stores.has(directory)) return stores.get(directory);
  const cache = new Map([['dockLightMode', M.GENTLE]]), disk = new Map(cache), steps = [];
  const api = { getSync: (name, fallback) => cache.has(name) ? cache.get(name) : fallback,
    async put(name, value) { cache.set(name, value); }, putSync: (name, value) => cache.set(name, value),
    deleteSync: name => cache.delete(name),
    async flush() { const snapshot = new Map(cache), step = steps.shift(); if (step) await step(); disk.clear();
      for (const [name, value] of snapshot) disk.set(name, value); } };
  const result = { api, cache, disk, steps }; stores.set(directory, result); return result;
}
const commons = { ...common, ProcessPreferences: { open: context => storage(context.preferencesDir).api,
  isGameProcess: () => game }, formatError: String };
const PreferenceManager = makePureEtsLoader({ commons,
  '@kit.PerformanceAnalysisKit': { hilog: { warn() {} } } })('feature_system/src/main/ets/PreferenceManager.ets').PreferenceManager;
const context = { preferencesDir: '/light-controls' }, a = new PreferenceManager(context), b = new PreferenceManager(context);
const data = storage();
assert.equal(a.immersiveLightPreferences.navigationMode, M.GENTLE);
assert.equal(data.cache.has(key), false, '读取迁移不应提前标记新记录已保存');
let release;
data.steps.push(() => new Promise(resolve => { release = resolve; }));
const first = copy(selected), second = copy(selected); second.enabled = false;
const writing = a.saveImmersiveLightPreferences(first);
await Promise.resolve(); await Promise.resolve();
assert.equal(decode(data.cache.get(key)).titleButtons, true);
assert.equal(b.immersiveLightPreferences.titleButtons, false, '新manager不能读到在途配置');
assert.equal(data.disk.has(key), false);
const queued = b.saveImmersiveLightPreferences(second); second.titleButtons = false;
release(); await writing; await queued;
assert.equal(a.immersiveLightPreferences.enabled, false);
assert.equal(a.immersiveLightPreferences.titleButtons, true, '排队请求应在调用时复制，而非消费迟到修改');
assert.deepEqual(new PreferenceManager(context).immersiveLightPreferences, decode(data.disk.get(key)));
data.steps.push(async () => { throw new Error('flush rejected'); });
await assert.rejects(a.saveImmersiveLightPreferences(first), /flush rejected/);
assert.equal(b.immersiveLightPreferences.enabled, false);
const old = decode(data.disk.get(key));
data.steps.push(async () => { throw new Error('write outcome unknown'); }, async () => { throw new Error('rollback unknown'); });
await assert.rejects(a.saveImmersiveLightPreferences(first), /回滚尚未确认/);
assert.deepEqual(b.immersiveLightPreferences, old);
await b.saveImmersiveLightPreferences(first);
assert.equal(a.immersiveLightPreferences.enabled, true);
const absentContext = { preferencesDir: '/light-first-failure' }, absentStore = storage(absentContext.preferencesDir);
absentStore.steps.push(async () => { throw new Error('first flush failure'); });
await assert.rejects(new PreferenceManager(absentContext).saveImmersiveLightPreferences(first), /first flush failure/);
assert.equal(absentStore.cache.has(key), false); assert.equal(absentStore.disk.has(key), false);
data.cache.set(key, '{"version":2}');
assert.equal(a.immersiveLightPreferences.enabled, false, '损坏/未来新记录不再迁移旧键');
game = true; await assert.rejects(a.saveImmersiveLightPreferences(first), /当前进程/); game = false;
const bad = copy(first); bad.navigationMode = M.OFF;
assert.throws(() => a.saveImmersiveLightPreferences(bad), /无效/);
pass('跨manager在途读取、整组串行保存、首写/普通失败、未知回滚重试与不可变请求');

// 执行生产runtime，只替代固定设备能力；同一配置的进度刷新不重复探测或通知。
let supportReads = 0, published = 0;
const appValues = new Map();
globalThis.AppStorage = { get: name => appValues.get(name), has: name => appValues.has(name),
  setOrCreate(name, value) { published++; appValues.set(name, value); } };
const runtime = makePureEtsLoader({ commons: common, feature_system: { PreferenceManager },
  './DockLightMaterial': { readDockLightCapabilities: () => { supportReads++; return { floatingSupported: true, immersiveSupported: false, queryFailed: false }; },
    dockLightStatus: () => '系统适配效果' } })('entry/src/main/ets/components/ImmersiveLightRuntime.ets');
assert.equal(runtime.effectiveTitleLightMode(''), M.OFF);
runtime.publishImmersiveLightPreferences(first); runtime.publishImmersiveLightPreferences(first);
assert.equal(published, 1);
for (let iteration = 0; iteration < 50; iteration++) assert.equal(runtime.effectiveTitleLightMode(encode(first)), M.SMOOTH);
assert.equal(supportReads, 1);
assert.equal(runtime.effectiveBottomLightMode(disabled), M.OFF);
pass('运行时只发布确认配置、能力/解码复用及模块隔离');

/** 提取生产组件非DSL方法；属性装饰器和绘制Builder由真实SDK检查，不模拟成视觉证明。 */
function component(relative, name, dependencies, globals = {}) {
  return loadActionComponent(relative, name, { dependencies, globals });
}
const colors = { Transparent: 'transparent' }, theme = { textPrimary: '#111', textSecondary: '#666', bgCard: '#fff' };
for (const available of [false, true]) {
  let back = 0, close = 0, external = 0;
  const design = { IconStyleMode: { SMALL: 100 }, get hdsMaterial() { assert.ok(available); return {
    MaterialType: { NONE: 0, ADAPTIVE: 100 }, MaterialLevel: { ADAPTIVE: 10, EXQUISITE: 0, GENTLE: 1, SMOOTH: 2 } }; } };
  const Header = component('entry/src/main/ets/components/ImmersiveTitleScaffold.ets', 'ImmersiveTitleScaffold', {
    commons: common, './AppRoundIconButton': {}, './AppTitleAction': {},
    '@kit.BasicServicesKit': { deviceInfo: { apiAvailable: version => { assert.equal(version, '6.1.0'); return available; } } },
    '@kit.UIDesignKit': design, './ImmersiveLightRuntime': runtime,
    '@kit.ArkUI': { LengthMetrics: { vp: value => ({ value, unit: 'vp' }) } } }, { Color: colors, $r: value => value });
  const view = new Header(); view.theme = theme; view.surfaceColor = '#f1f3f5'; view.onBack = () => back++;
  view.getUIContext = () => ({ getHostContext: () => undefined }); view.aboutToAppear();
  view.onClose = () => close++; view.onExternal = () => external++; view.showExternal = true;
  view.rawConfig = encode(first);
  const options = view.nativeTitleOptions_();
  assert.equal(options.content.backIcon.icon, 'sys.symbol.chevron_left');
  options.content.backIcon.action(); options.content.menu.value[0].content.action();
  assert.equal(back, 1); assert.equal(external, 1);
  if (available) { assert.equal(options.style.systemMaterialEffect.materialType, 100); assert.equal(options.style.systemMaterialEffect.materialLevel, 2);
    assert.equal(options.style.originalStyle.backgroundStyle.backgroundColor, '#f1f3f5'); }
  else assert.equal(options.style, undefined);
  view.modal = true; view.menuItems_().find(item => item.content.componentId === view.closeId).content.action(); assert.equal(close, 1);
  view.modal = false; view.showExternal = false; assert.deepEqual(view.menuItems_(), []);
  view.rawConfig = encode({ ...first, enabled: false });
  const offOptions = view.nativeTitleOptions_();
  if (available) { assert.equal(offOptions.style.systemMaterialEffect.materialType, 0); assert.equal(offOptions.style.originalStyle.contentStyle.backIconStyle.backgroundColor, '#fff'); }
}
pass('生产标题options的返回/关闭/外跳、隐藏外跳、旧系统无新材质及关闭背景');

const Settings = component('entry/src/main/ets/components/ImmersiveLightSettings.ets', 'ImmersiveLightSettings', { commons: common });
const settings = new Settings(); settings.preferences = first; settings.hasPresets = true;
const requests = []; settings.onChange = next => requests.push(next);
settings.requestEnabled_(false); assert.equal(first.enabled, true); assert.equal(requests.at(-1).titleButtons, true);
settings.preferences = requests.at(-1); settings.requestTitleButtons_(false); assert.equal(requests.length, 1);
settings.requestEnabled_(true); settings.preferences = requests.at(-1);
settings.requestBottomBar_(false); assert.equal(settings.preferences.bottomBar, true);
settings.saving = true; settings.requestNavigationMode_(M.AUTO); assert.equal(requests.length, 3);
const Tab = component('entry/src/main/ets/pages/tabs/SettingsTab.ets', 'SettingsTab', { commons: { ...common,
  ThemeMode: { LIGHT: 0, DARK: 1, SYSTEM: 2 }, JDK_AUTO: 'auto' },
  // 本组只执行设置分区与返回订阅；其余业务入口显式隔离，误走它们会因缺少能力直接失败。
  '../../components/TouchLearningStore': {}, '@kit.ArkUI': {}, '@kit.AbilityKit': {},
  '@kit.PerformanceAnalysisKit': {}, 'entry/ProductInputProfile': {} },
  { Color: colors, Scroller: class { scrollTo() {} } });
const tab = new Tab(); let backHandler;
tab.onSectionBackReady = handler => { backHandler = handler; }; tab.visible = true;
tab.aboutToAppear(); tab.selectSection_('immersive'); tab.syncSectionBack_();
assert.equal(typeof backHandler, 'function'); const stale = backHandler;
assert.equal(backHandler(), true); assert.equal(tab.activeSection, 'overview');
tab.activeSection = 'immersive'; tab.visible = false; tab.syncSectionBack_();
assert.equal(backHandler, undefined); assert.equal(stale(), false);
tab.canRunGame = false; tab.settingsQuery = '光感';
assert.ok(tab.visibleSections_().some(section => section.id === 'immersive'));
tab.visible = true; tab.syncSectionBack_(); tab.aboutToDisappear(); assert.equal(backHandler, undefined);
pass('设置事件不可变、总关闭保留模块、保存禁重、商店搜索与可见二级返回');

assert.deepEqual(sourceHashes(), initialHashes, '回归期间生产源码发生变化');
fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify({ status: 'passed', startedAt, finishedAt: new Date().toISOString(),
  scope: 'host behavior only; SDK and visual verification separate', groups: passed, sourceHashes: initialHashes }, null, 2) + '\n');
