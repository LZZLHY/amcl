/**
 * 执行真实Index版本选择/就绪投影/launchMC与LaunchCoordinator，核对同进程切换的显示输入。
 * Builder只验证官方单参数对象字面量契约，不把宿主AST/转译当成设备ArkUI渲染资格。
 * 可选参数为原仓、候选覆盖树、独占报告路径；默认用于本仓现有宿主门禁。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createHostTestScope } from './lib/host-test-lifecycle.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
const project = path.resolve(process.argv[2] || path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
const overlay = path.resolve(process.argv[3] || project);
const report = process.argv[4];
const { default: compiler } = await import(pathToFileURL(path.join(project, 'scripts/lib/ets-compiler.mjs')).href);
const inputs = new Map();
function source(relative) {
  const candidate = path.join(overlay, relative);
  const actual = fs.existsSync(candidate) ? candidate : path.join(project, relative);
  const bytes = fs.readFileSync(actual);
  // Git在Windows检出为CRLF；解析与精确撤回使用统一LF，身份摘要始终绑定原始字节。
  const text = bytes.toString('utf8').replaceAll('\r\n', '\n');
  inputs.set(relative, crypto.createHash('sha256').update(bytes).digest('hex'));
  return text;
}
function component(text, name) {
  const ast = compiler.createSourceFile(name + '.ets', text, compiler.ScriptTarget.Latest, true);
  const value = ast.statements.find(node => node.name?.getText(ast) === name);
  assert(value?.members, name); return { ast, value };
}
function methods(subject, names) {
  return names.map(name => {
    const member = subject.value.members.find(value => name === 'constructor'
      ? compiler.isConstructorDeclaration(value) : value.name?.getText(subject.ast) === name);
    assert(member?.body, 'actual method missing: ' + name); return member.getText(subject.ast);
  });
}
function buildClass(body, dependencies, name = 'Subject') {
  const result = compiler.transpileModule('class ' + name + ' {\n' + body.join('\n') + '\n}\nexports.Subject=' + name + ';', {
    compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 }, reportDiagnostics: true,
  });
  assert.equal((result.diagnostics || []).filter(value => value.category === compiler.DiagnosticCategory.Error).length, 0);
  const exported = {};
  new Function('exports', ...Object.keys(dependencies), result.outputText)(exported, ...Object.values(dependencies));
  return exported.Subject;
}
const indexText = source('entry/src/main/ets/pages/Index.ets');
const homeText = source('entry/src/main/ets/pages/tabs/HomeTab.ets');
const index = component(indexText, 'Index');
const home = component(homeText, 'HomeTab');
const coordinator = component(source('launch/src/main/ets/LaunchCoordinator.ets'), 'LaunchCoordinator');
const logger = { info() {}, warn() {} };
const isJdkSlotVersion = value => ['8', '17', '21', '25'].includes(value);
const Coordinator = buildClass(methods(coordinator, ['constructor', 'resolvePlan', 'resolveJdk', 'isSpecificJdk']), {
  fs: { mkdirSync() {} }, resolveInstanceGameDir: (root, version, isolated) => isolated ? root + '/versions/' + version : root,
  AppLogger: logger, TAG: 'test', LOG_DOMAIN_LAUNCH: 1, isJdkSlotVersion, JDK_AUTO: 'auto',
}, 'LaunchCoordinator');
const events = [];
function visit(node) {
  if (compiler.isPropertyAssignment(node) && node.name?.getText(index.ast) === 'onSelectVersion' &&
      compiler.isArrowFunction(node.initializer)) events.push(node.initializer.getText(index.ast));
  compiler.forEachChild(node, visit);
}
visit(index.value);
assert.equal(events.length, 2, 'home and version-manager must share the actual selection callback');
const names = ['getJdkManager_', 'getLaunchCoordinator_', 'getPrefManager_', 'savePreferences', 'saveLauncherChange_',
  'updateJdkReadyState', 'selectManagedVersion_', 'launchMC'];
const callbacks = events.map((body, n) => `invokeSelection${n}(version: string): Promise<boolean> { const callback=${body}; return callback(version); }`);
function pageClass(text) {
  return buildClass([...methods(component(text, 'Index'), names), ...callbacks], {
    AppLogger: logger, TAG: 'test', LOG_DOMAIN_LAUNCH: 1, JDK_AUTO: 'auto', isJdkSlotVersion,
    LaunchCoordinator: Coordinator, GameRunAdmission: { capture: () => '' },
  });
}
const Page = pageClass(indexText);
const Home = buildClass(methods(home, ['statusDetailText', 'canLaunch']), {});
function fixture(PageType = Page) {
  const overrides = new Map(['8', '17', '21', '25'].map(major => ['qa-' + major, { jdkVersion: major, xmx: 512 }]));
  const installed = new Set(['8', '17', '21', '25']);
  const repairs = new Set(), imported = new Set();
  const records = { saves: [], mods: 0, store: 0, route: [], requiredPrompts: [] };
  const manager = { listVersions: () => [...installed].map(version => ({ version, installed: !repairs.has(version), repairRequired: repairs.has(version), userImported: imported.has(version) })),
    inspect: major => ({repairRequired:repairs.has(major),state:imported.has(major)?'user-import':'current'}),
    isInstalled: major => installed.has(major) && !repairs.has(major), jdkRangeFor: () => ({ minMajor: 8, maxMajor: 25 }),
    resolveLaunchJdk: (_version, hint) => hint || '21' };
  const prefs = { getVersionOverride: version => overrides.get(version),
    resolveLaunch: version => overrides.get(version), saveLauncherFields: async values => { records.saves.push({...values}); Object.assign(prefs,values); } };
  const page = new PageType();
  Object.assign(page, { prefManager_: prefs, jdkManager_: manager, launchCoordinator_: null,
    mcVersion: 'qa-17', selectedJdkVersion: 'auto', effectiveJdkVersion: '17', jdkReady: true,
    versionIsolation: true, startupFinished_: true, versionScanPending_: false, storeHasSession_: false,
    context: { filesDir: '/app' }, mcRoot: () => '/mc', scanInstalledModsCount() { records.mods++; },
    forceStoreSourceRecheck_() { records.store++; }, showRuntimeUpdateDialog_(manual) { records.requiredPrompts.push(manual); }, safeToast_() { assert.fail('unexpected startup rejection'); } });
  return { page, installed, overrides, records, repairs, imported };
}
const results = [];
for (let callback = 0; callback < events.length; callback++) {
  const f = fixture();
  // 同一实例重复穿过四代，不用每次构造新页面掩盖旧值残留。
  for (const major of ['8', '21', '25', '17', '8']) {
    const version = 'qa-' + major;
    await f.page[`invokeSelection${callback}`](version);
    assert.equal(f.page.mcVersion, version);
    assert.equal(f.page.effectiveJdkVersion, major);
    assert.equal(f.page.jdkReady, true);
    assert.equal(f.page.selectedJdkVersion, 'auto');
    assert.equal(f.records.saves.at(-1).mcVersion, version);
    assert.equal(f.overrides.get(version).jdkVersion, major);
    f.page.launchMC();
    assert.equal(f.page.preLaunchJdkVersion, major);
    assert.equal(f.page.preLaunchGameDir, '/mc/versions/' + version);
    assert.equal(f.page.showPreLaunchSheet, true);
    const h = new Home();
    Object.assign(h, { storeManager: false, availableVersions: ['qa-8'], jdkReady: f.page.jdkReady,
      mcDownloading: false, isRunning: false, effectiveJdkVersion: f.page.effectiveJdkVersion, heroLoaderText: () => 'Forge' });
    assert.match(h.statusDetailText(), new RegExp('JDK ' + major + ' '));
    assert.equal(h.canLaunch(), true);
    results.push({ callback, version, displayJdk: f.page.effectiveJdkVersion, launchJdk: f.page.preLaunchJdkVersion });
  }
  assert.equal(f.records.mods, 5); assert.equal(f.records.store, 5);
  f.installed.delete('25'); await f.page[`invokeSelection${callback}`]('qa-25');
  assert.equal(f.page.effectiveJdkVersion, '25'); assert.equal(f.page.jdkReady, false);
  f.page.launchMC(); assert.equal(f.page.preLaunchJdkVersion, '25', 'missing chosen JDK must remain chosen for inline install');
}
// 启动前必要修复只针对本局实际槽位：不能以另一个槽位不兼容为由阻断当前游戏。
const incompatible=fixture();incompatible.repairs.add('17');incompatible.page.launchMC();
assert.deepEqual(incompatible.records.requiredPrompts,[true]);assert.notEqual(incompatible.page.showPreLaunchSheet,true);
const unrelated=fixture();unrelated.repairs.add('8');unrelated.page.launchMC();
assert.equal(unrelated.page.showPreLaunchSheet,true);assert.deepEqual(unrelated.records.requiredPrompts,[]);
const importedRepair=fixture();importedRepair.repairs.add('17');importedRepair.imported.add('17');importedRepair.page.launchMC();
assert.equal(importedRepair.page.showPreLaunchSheet,true,'本地导入继续走实际运行时资格检查，不自动认领为官方更新');
assert.deepEqual(importedRepair.records.requiredPrompts,[]);
// 精确撤回这一修复，在相同真实方法里重现旧显示；launchMC仍正确，证明不是启动根因闭环。
const withoutRefresh = indexText.replace('      this.updateJdkReadyState();\n      this.scanInstalledModsCount();\n      this.forceStoreSourceRecheck_();',
  '    this.scanInstalledModsCount()\n    this.forceStoreSourceRecheck_()');
assert.ok(withoutRefresh !== indexText, 'counterfactual must remove the actual selection refresh call');
const old = fixture(pageClass(withoutRefresh)); await old.page.invokeSelection0('qa-8');
assert.equal(old.page.effectiveJdkVersion, '17'); old.page.launchMC(); assert.equal(old.page.preLaunchJdkVersion, '8');

// @Builder引用更新条件必须来自真实AST：只有一个直接对象字面量参数，内部读其字段。
const chip = home.value.members.find(member => member.name?.getText(home.ast) === 'HeroChip');
assert.equal(chip.parameters.length, 1);
assert.match(chip.getText(home.ast), /Text\(state\.label\)/);
assert.match(chip.getText(home.ast), /name: state\.icon/);
const calls = [];
function chipCalls(node) {
  if (compiler.isCallExpression(node) && node.expression.getText(home.ast) === 'this.HeroChip') calls.push(node);
  compiler.forEachChild(node, chipCalls);
}
chipCalls(home.value);
assert.equal(calls.length, 3);
for (const call of calls) {
  assert.equal(call.arguments.length, 1);
  assert(compiler.isObjectLiteralExpression(call.arguments[0]));
  assert.deepEqual(call.arguments[0].properties.map(property => property.name.getText(home.ast)), ['icon', 'label']);
}
assert.match(calls[0].arguments[0].getText(home.ast), /this\.effectiveJdkVersion/);

// 在同一游戏根放入共享与独立世界/模组，经过真实偏好提交、首页扫描、存档刷新及启动目录选择。
// 系统偏好用宿主文件承接 flush；每次重新打开都从文件读取，不能靠内存里的旧开关通过。
const isolationScope = createHostTestScope('version-isolation-');
const mcRoot = path.join(isolationScope.directory, '.minecraft').replaceAll('\\', '/');
const original = 'survival', versionDir = mcRoot + '/versions/' + original;
const preferenceFile = path.join(isolationScope.directory, 'amcl_settings.json');
const files = new Map();
function seed(relative, bytes) {
  const target = mcRoot + '/' + relative;
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, bytes);
  files.set(target, fs.readFileSync(target));
}
for (const id of ['other', original]) {
  seed('versions/' + id + '/' + id + '.jar', Buffer.alloc(1024 * 1024 + 1));
  seed('versions/' + id + '/' + id + '.json', JSON.stringify({ id, mainClass: 'net.minecraft.client.main.Main' }));
}
seed('versions/survival/saves/Original world/level.dat', 'original world');
seed('versions/survival/mods/active.jar', 'original mod');
seed('versions/survival/mods/paused.jar.disabled', 'original disabled mod');
seed('saves/Shared world/level.dat', 'shared world');
seed('mods/shared.jar', 'shared mod');
const kitFiles = { listFile: fs.promises.readdir, stat: fs.promises.stat, readText: p => fs.promises.readFile(p, 'utf8'),
  async lstat(p) { try { return await fs.promises.lstat(p); } catch (e) { if (e.code === 'ENOENT') e.code = 13900002; throw e; } },
  listFileSync: fs.readdirSync, statSync: fs.statSync, lstatSync: fs.lstatSync, mkdirSync: p => fs.mkdirSync(p, { recursive: true }) };
const common = { AppLogger: logger, JDK_AUTO: 'auto', isJdkSlotVersion, ProcessPreferences: {
  isGameProcess: () => false,
  open() {
    const data = fs.existsSync(preferenceFile) ? JSON.parse(fs.readFileSync(preferenceFile, 'utf8')) : {};
    return { getSync: (key, fallback) => data[key] ?? fallback, putSync(key, value) { data[key] = value; },
      deleteSync(key) { delete data[key]; }, flush: () => fs.promises.writeFile(preferenceFile, JSON.stringify(data)) };
  },
} };
const moduleSources = {};
const pure = makePureEtsLoader({ commons: common, '@kit.CoreFileKit': { fileIo: kitFiles },
  '@kit.PerformanceAnalysisKit': { hilog: logger }, '@kit.ArkTS': { taskpool: { Task: { isCanceled: () => false } } },
  '@kit.CryptoArchitectureKit': {}, '../modloader/MavenUtils': {}, feature_core: {} }, moduleSources);
function businessModule(relative) {
  moduleSources[relative] = source(relative);
  return pure(relative);
}
Object.assign(common, businessModule('commons/src/main/ets/utils/InstancePaths.ets'), businessModule('commons/src/main/ets/utils/FileUtils.ets'));
const { PreferenceManager } = businessModule('feature_system/src/main/ets/PreferenceManager.ets');
const { readLocalVersionInventory } = businessModule('feature_core/src/main/ets/version/LocalVersionInventory.ets');
const { LaunchCoordinator } = businessModule('launch/src/main/ets/LaunchCoordinator.ets');
const { ResourceKind, resourceKindToInstallDir } = businessModule('mods/src/main/ets/ModTypes.ets');
const { enumerateResourceFilesSync } = businessModule('mods/src/main/ets/LocalModFileWorker.ets');
const IsolationPage = buildClass(methods(index, ['saveLauncherChange_', 'changeManagedIsolation_', 'selectManagedVersion_',
  'scanVersions', 'scanInstalledModsCount', 'onVersionFilesChanged_']), { ...common, readLocalVersionInventory, invalidateInstalledLoaderCache() {},
  DiagnosticPolicy: { isDeveloperBuild: () => false }, DistributionPolicy: { isStore: () => false }, TAG: 'test', LOG_DOMAIN_LAUNCH: 0 });
const saves = component(source('entry/src/main/ets/components/SavesManagerSheet.ets'), 'SavesManagerSheet');
const Saves = buildClass(methods(saves, ['savesDir', 'refresh', 'onScopeChanged', 'dismissEntry_']), { ...common, fs: kitFiles, hilog: logger, TAG: 'test' });
const panel = Object.assign(new Saves(), { mcDir: mcRoot, versionId: original, active: true });
let prefs = new PreferenceManager({ preferencesDir: isolationScope.directory });
const launcher = Object.assign(new IsolationPage(), { mcVersion: 'other', availableVersions: ['other',original], versionIsolation: prefs.versionIsolation,
  mcRoot: () => mcRoot, getPrefManager_: () => prefs, startupAlive_: true, versionScanEpoch_: 0,
  updateJdkReadyState() {}, forceStoreSourceRecheck_() {}, refreshStoreManager_() {}, safeToast_: assert.fail });
await prefs.saveLauncherFields({ versionOrder: JSON.stringify(['other', original]) });
assert.equal(await launcher.selectManagedVersion_(original), true);
const launch = new LaunchCoordinator({ resolveLaunchJdk: () => '21' });
const roundTrip = [];
for (const [step, isolated] of [true, false, true].entries()) {
  if (step > 0) assert.equal(await launcher.changeManagedIsolation_(isolated), true);
  const expectedMods = isolated ? ['active.jar', 'paused.jar.disabled'] : ['shared.jar'];
  assert.equal(launcher.versionIsolation, isolated);
  assert.equal(launcher.installedModsCount, expectedMods.length, '开关确认后首页模组数应立即反映实际目录');
  prefs = new PreferenceManager({ preferencesDir: isolationScope.directory });
  assert.equal(prefs.versionIsolation, isolated);
  assert.equal(prefs.mcVersion, original);
  await launcher.scanVersions();
  assert.deepEqual(launcher.availableVersions, ['other', original]);
  assert.equal(launcher.mcVersion, original);
  const plan = launch.resolvePlan({ mcDir: mcRoot, mcVersion: prefs.mcVersion, versionIsolation: prefs.versionIsolation,
    overrideJdkVersion: 'auto', userPreferredJdk: 'auto', effectiveXmx: 1024 });
  assert.equal(plan.gameDir, isolated ? versionDir : mcRoot);
  panel.versionIsolation = prefs.versionIsolation;
  panel.onScopeChanged();
  assert.deepEqual(panel.rows.map(world => [world.name, world.valid]), [[isolated ? 'Original world' : 'Shared world', true]]);
  const modsDir = resourceKindToInstallDir(ResourceKind.MOD, mcRoot, prefs.mcVersion, prefs.versionIsolation);
  const mods = enumerateResourceFilesSync(modsDir, ['.jar', '.jar.disabled']);
  assert.deepEqual(mods.map(mod => mod.filename).sort(), expectedMods);
  assert.deepEqual(mods.filter(mod => mod.enabled).map(mod => mod.filename), [expectedMods[0]]);
  for (const [file, bytes] of files) assert.deepEqual(fs.readFileSync(file), bytes, file);
  roundTrip.push({ isolated, version: launcher.mcVersion, world: panel.rows[0].name, mods: expectedMods });
}
await isolationScope.close();
const summary = { state: 'PASS', scope: 'actual selection/resolution methods and Builder AST contract; no HAP, device rendering or dispatch claim',
  switchedRuns: results, isolationRoundTrip: roundTrip, missingSelectedJdkPreserved: true, oldDisplayCounterfactualReproduced: true,
  launchPlanDoesNotUseStaleDisplay: true, requiredManagedRuntimeBlockedBeforePrelaunch: true, compatibleOtherSlotNotBlocked: true, importedNotAutoClaimed: true, builderReferenceCalls: calls.length, inputs: Object.fromEntries(inputs) };
if (report) fs.writeFileSync(report, JSON.stringify(summary, null, 2) + '\n', { encoding: 'utf8', flag: 'wx' });
console.log(JSON.stringify({ state: summary.state, switchedRuns: results.length, builderReferenceCalls: calls.length, isolationRoundTrip: roundTrip }));
