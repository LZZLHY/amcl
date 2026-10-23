/**
 * 执行真实 UpdateChecker、TestSession、PromptPolicy 及 Index 的原方法，回归异步来源和排队代次。
 * 替身仅提供 HTTP、bundleManager、ArkUI controller/Toast 与可见性边界；
 * 解析、正式收据核对、来源快照、入队/出队和参数生成均使用产品源码，不镜像实现判据。
 * 宿主不连接真实服务或设备，也不把 controller 参数断言称作 ArkUI 视觉验收。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import compiler from './lib/ets-compiler.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
/** SDK transpiler 只负责宿主装载；正式 ArkTS 类型和源集审核仍由正常四产品构建完成。 */
function load(file, dependencies = {}) {
  const code = compiler.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), {
    compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 },
  }).outputText;
  const exports = {};
  vm.runInNewContext(code, { exports, require: name => {
    if (!(name in dependencies)) throw new Error('Unmocked dependency: ' + name);
    return dependencies[name];
  }, console, Object, Number, JSON, RegExp, Array, Map, Date, Promise });
  return exports;
}

const officialUrls = ['https://production.example/update.json', 'https://production.example/fallback.json'];
const profile = { product: 'default', storeChannel: false };
let hooks = true, currentCode = 1000681, fetchBoundary;
const requests = [], logMessages = [];
const logger = { info: (_tag, message) => logMessages.push(message), warn() {}, debug() {} };
const commons = { AppLogger: logger, formatError: String, UPDATE_MANIFEST_URLS: officialUrls,
  DiagnosticPolicy: { hasTestHooks: () => hooks }, DistributionPolicy: { allowSideloadUpdates: () => true, isStore: () => false } };
const models = load('update/src/main/ets/SideloadUpdateModels.ets');
const noteTypes = load('update/src/main/ets/ChangelogTypes.ets');
const resolver = load('update/src/main/ets/GitHubUpdateAssetResolver.ets', { '@kit.NetworkKit': {}, './AppUpdatePolicy':load('update/src/main/ets/AppUpdatePolicy.ets') });
const checkerModule = load('update/src/main/ets/UpdateChecker.ets', {
  commons, './AppUpdatePolicy':load('update/src/main/ets/AppUpdatePolicy.ets'), './ChangelogTypes': noteTypes, './GitHubUpdateAssetResolver': resolver,
  '@kit.AbilityKit': { bundleManager: { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 },
    getBundleInfoForSelfSync: () => ({ versionCode: currentCode }) } },
  feature_core: { DownloadManager: { instance: () => ({ fetchText: async (url, mirrors, timeout, limit) => {
    requests.push({ url, mirrors, timeout, limit });
    assert.equal(limit, 8191, '真实检查仍保持 8 KiB 字节上限');
    return fetchBoundary(url);
  } }) } },
});
const sessionModule = load('entry/src/main/ets/sideload/SideloadUpdateTestSession.ets', {
  commons, 'entry/ProductBuildProfile': { ProductBuildProfile: profile }, update: { ...models, ...checkerModule },
});
const { SideloadUpdateTestSession: Session, SideloadUpdatePromptPolicy: Policy } = sessionModule;
const { UpdateChecker: Checker } = checkerModule;

/** 固定测试 DTO 与正式收据使用同一版本/tag，专门覆盖原先仅按版本误绑定全局 testAsset 的场景。 */
function fixture(letter) {
  const base = 'https://amcl.lovedhy.cn/uploads/self-update-tests/' + letter.repeat(32) + '/';
  const asset = { tag: 'v1.0.5', name: 'entry-default-unsigned.hap', url: base + 'target.hap',
    sha256: letter.repeat(64), sizeBytes: 100, versionCode: 1000682, versionName: '1.0.5',
    product: 'sideload', legacyUniversal: true, websiteUrl: base + 'target.hap', mirrors: [] };
  const manifest = { versionCode: asset.versionCode, versionName: asset.versionName, tag: asset.tag,
    url: asset.url, sizeBytes: asset.sizeBytes, notes: '1.0.5\n- 注意：受控测试', mandatory: false,
    schema: 1, date: '2026-10-05', changelogUrl: '', notesEntries: [],
    delivery: { schema: 1, ready: true, assets: [asset] } };
  return { asset, manifest, url: base + 'manifest.json' };
}
const testA = fixture('a'), testB = fixture('b');
const productionAsset = { tag: 'v1.0.5', name: 'amcl-v1.0.5-sideload-unsigned.hap',
  url: 'https://github.com/LZZLHY/amcl/releases/download/v1.0.5/amcl-v1.0.5-sideload-unsigned.hap',
  sha256: 'c'.repeat(64), sizeBytes: 100, versionCode: 1000682, versionName: '1.0.5', product: 'sideload',
  legacyUniversal: false, websiteUrl: 'https://amcl.lovedhy.cn/api/packages/files/' + 'c'.repeat(64) + '/amcl-v1.0.5-sideload-unsigned.hap',
  mirrors: [{ provider: 'miawa', projectId: 'amcl', ready: true, filePath: 'amcl/v1.0.5/amcl-v1.0.5-sideload-unsigned.hap' }] };
const productionManifest = { ...testA.manifest, url: 'https://github.com/LZZLHY/amcl/releases/tag/v1.0.5',
  notes: '1.0.5\n- 修复：正式来源', delivery: { schema: 1, ready: true, assets: [productionAsset] } };

/** AST 取得 Index 的真实方法正文；不把源码 regex 或在测试中另写的同名函数当作行为证据。 */
const indexSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
const parsedIndex = compiler.createSourceFile('Index.ets', indexSource, compiler.ScriptTarget.Latest, true);
const index = parsedIndex.statements.find(node => node.name?.getText(parsedIndex) === 'Index');
assert.ok(index?.members, 'SDK AST must expose Index methods');
// 偏好服务现由生产惰性 getter 持有；连同真实 getter 一起提取，不能另写同名返回值
// 绕过它。每个场景将原偏好夹具注入 prefManager_，等价于正常首页已完成初始化。
const methodNames = ['getPrefManager_', 'checkForUpdate', 'showUpdateDialog', 'drainUpdateDialogs_', 'applyUpdateResult', 'initUpdateCheck'];
const methodText = methodNames.map(name => {
  const method = index.members.find(member => member.name?.getText(parsedIndex) === name);
  assert.ok(method, 'Missing production Index method: ' + name);
  return method.getText(parsedIndex);
});
const harnessJs = compiler.transpileModule('class Harness {\n' + methodText.join('\n') + '\n}', {
  compilerOptions: { target: compiler.ScriptTarget.ES2020 },
}).outputText;

/** 每个场景拥有独立的真实 Presenter；UI 替身只记录原方法构造出的 builder 参数。 */
function page(blocked = false) {
  const presenter = load('entry/src/main/ets/components/UpdatePromptPresenter.ets').UpdatePromptPresenter;
  const dialogs = [], toasts = [], externalUrls = [];
  class Controller {
    constructor(options) { this.options = options; dialogs.push(this); }
    open() { this.opened = true; }
    close() { this.closed = true; }
  }
  const scope = { UpdateChecker: Checker, SideloadUpdateTestSession: Session, SideloadUpdatePromptPolicy: Policy,
    DistributionPolicy: commons.DistributionPolicy,
    ProductBuildProfile: profile, UpdatePromptPresenter: presenter, AppStorage: { get: () => true },
    AppLogger: logger, CustomDialogController: Controller, UpdateDialog: options => options,
    APP_VERSION: '1.0.5', TAG: 'Index-source-test', LOG_DOMAIN_UI: 1, DialogAlignment: { Center: 0 }, formatBytes: String };
  vm.runInNewContext(harnessJs + '\nthis.Harness = Harness;', scope);
  const instance = new scope.Harness();
  const preferences = { appUpdateChannel:'stable',lastUpdateCheckAt:0,latestSeenVersionCode:0,updatePromptDeferredAt:0,
    appUpdateLastCheck(){return this.lastUpdateCheckAt;},appUpdateLatestSeen(){return this.latestSeenVersionCode;},appUpdateLatestName(){return '';},appUpdateDeferredAt(){return this.updatePromptDeferredAt;},
    rememberAppUpdate(_p,_c,code){this.latestSeenVersionCode=code;this.lastUpdateCheckAt=Date.now();},deferAppUpdate(){this.updatePromptDeferredAt=Date.now();} };
  Object.assign(instance, { updateDialogCtrl_: blocked ? {} : null, pendingAppUpdate_: null,
    pendingRuntimePrompt_: false, pendingRuntimePromptManual_: false, showPrivacy: false,
    // 原有来源/通道用例描述已经可交互的首页；新开屏排队用例会显式撤销此资格。
    startupFinished_: true, showMcErrorSheet: false, recoveringSessions_: false, recoveryPresentationDeferred_: false,
    gameLaunchedThisSession: false, autoUpdateCheckStarted: false, updatePresenterOwner: 'test-page', theme: {},
    // prefManager 仅保留给已有断言的夹具别名；实际生产方法只经真实 getter 访问缓存字段。
    updateDot: false, prefManager_: preferences, prefManager: preferences,
    getUIContext: () => ({ getPromptAction: () => ({ showToast: value => toasts.push(value) }) }),
    openExternalUrl: url => externalUrls.push(url), closeUpdateDialog_() {}, openChangelogPage_() {},
    showRuntimeUpdateDialog_() { throw new Error('Unexpected runtime prompt'); } });
  return { instance, dialogs, toasts, externalUrls };
}
function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}
async function settle() { for (let i = 0; i < 20; i++) await Promise.resolve(); }
let passed = 0;
/** 每项执行前清掉前一个测试会话；不复用上一项的虚构登录、安装或平台执行结果。 */
async function test(name, run) {
  Session.clear(); profile.product = 'default'; hooks = true; currentCode = 1000681; requests.length = 0;
  fetchBoundary = async url => JSON.stringify(url.includes('/self-update-tests/') ? (url === testB.url ? testB.manifest : testA.manifest) : productionManifest);
  await run(); passed++; console.log('PASS prompt source: ' + name);
}

await test('changing App channel discards late response before cache and prompt',async()=>{
  const response=deferred();fetchBoundary=()=>response.promise;
  const p=page(),checking=p.instance.checkForUpdate();p.instance.prefManager.appUpdateChannel='preview';
  response.resolve(JSON.stringify(productionManifest));await checking;
  assert.equal(p.instance.prefManager.latestSeenVersionCode,0);assert.equal(p.dialogs.length,0);
});
await test('queued candidate from old channel does not block runtime prompt',async()=>{
  const p=page(true);await p.instance.checkForUpdate();p.instance.prefManager.appUpdateChannel='preview';
  p.instance.updateDialogCtrl_=null;let shown=0;p.instance.pendingRuntimePrompt_=true;
  p.instance.showRuntimeUpdateDialog_=()=>shown++;p.instance.drainUpdateDialogs_();
  assert.equal(p.dialogs.length,0);assert.equal(shown,1);
});

await test('real startup and recovery gates queue an actual checked candidate until home is interactive', async () => {
  const p = page(); p.instance.startupFinished_ = false;
  await p.instance.checkForUpdate();
  assert.ok(p.instance.pendingAppUpdate_, '真实检查结果必须入队，不能在开屏期间丢弃');
  assert.equal(p.dialogs.length, 0, '开屏期间不能构造或打开更新controller');
  p.instance.drainUpdateDialogs_(); assert.equal(p.dialogs.length, 0);
  p.instance.startupFinished_ = true; p.instance.recoveringSessions_ = true;
  p.instance.drainUpdateDialogs_(); assert.equal(p.dialogs.length, 0, '恢复await期间仍不展示更新');
  p.instance.recoveringSessions_ = false; p.instance.recoveryPresentationDeferred_ = true;
  p.instance.drainUpdateDialogs_(); assert.equal(p.dialogs.length, 0, '恢复展示尚待消费时继续排队');
  p.instance.recoveryPresentationDeferred_ = false; p.instance.drainUpdateDialogs_();
  assert.equal(p.dialogs.length, 1); assert.equal(p.dialogs[0].opened, true);
  assert.equal(p.dialogs[0].options.builder.sourceLabel, 'GitHub 发布');
  assert.equal(p.instance.pendingAppUpdate_, null, '真实出队应消费已展示候选');
});

await test('clear during real Index await discards result before preferences and presentation', async () => {
  Session.configure(testA.url, testA.asset, false);
  const response = deferred(); fetchBoundary = () => response.promise;
  const p = page(); const checking = p.instance.checkForUpdate();
  assert.equal(requests[0].url, testA.url);
  Session.clear(); response.resolve(JSON.stringify(testA.manifest)); await checking;
  assert.equal(p.instance.prefManager.latestSeenVersionCode, 0); assert.equal(p.instance.prefManager.lastUpdateCheckAt, 0);
  assert.equal(p.instance.pendingAppUpdate_, null); assert.equal(p.dialogs.length, 0); assert.equal(p.externalUrls.length, 0);
});

await test('same fixture reconfigure invalidates old await generation and fresh request still works', async () => {
  Session.configure(testA.url, testA.asset, false); const old = Session.captureSource();
  const response = deferred(); fetchBoundary = () => response.promise;
  const p = page(); const checking = p.instance.checkForUpdate();
  Session.configure(testA.url, testA.asset, false); assert.equal(Session.isCurrent(old), false);
  assert.equal(Policy.candidate(testA.manifest, old, true), null);
  response.resolve(JSON.stringify(testA.manifest)); await checking; assert.equal(p.dialogs.length, 0);
  fetchBoundary = async () => JSON.stringify(testA.manifest); await p.instance.checkForUpdate();
  assert.equal(p.dialogs.length, 1); assert.equal(p.dialogs[0].options.builder.sourceLabel, '临时测试源');
  assert.equal(p.dialogs[0].options.builder.selfUpdateParams.testAsset.sha256, testA.asset.sha256);
});

await test('already presented builder keeps its copied test parameters after global clear and reconfigure', async () => {
  Session.configure(testA.url, testA.asset, false); const p = page(); await p.instance.checkForUpdate();
  const shown = p.dialogs[0].options.builder; Session.clear(); Session.configure(testB.url, testB.asset, true);
  // 来源候选的有效期只约束新提示；已经展示的业务面持有自己的参数，不能突然变成正式安装。
  assert.equal(shown.sourceLabel, '临时测试源'); assert.equal(shown.selfUpdateParams.testAsset.url, testA.asset.url);
  assert.equal(shown.selfUpdateParams.sameVersionTest, false); assert.equal(shown.selfUpdateParams.manifest.url, testA.asset.url);
});

await test('deferred stale fixture is dropped by actual Index drain and does not block runtime prompt', async () => {
  Session.configure(testA.url, testA.asset, false); const p = page(true); await p.instance.checkForUpdate();
  assert.equal(p.instance.pendingAppUpdate_.source.testSource, true); assert.equal(p.dialogs.length, 0);
  Session.clear(); p.instance.updateDialogCtrl_ = null;
  let runtimeShown = 0; p.instance.pendingRuntimePrompt_ = true;
  p.instance.showRuntimeUpdateDialog_ = () => { runtimeShown++; };
  p.instance.drainUpdateDialogs_(); assert.equal(p.instance.pendingAppUpdate_, null);
  assert.equal(p.dialogs.length, 0); assert.equal(runtimeShown, 1); assert.equal(p.externalUrls.length, 0);
});

await test('deferred reconfigured candidate keeps only latest test generation and fixed asset', async () => {
  Session.configure(testA.url, testA.asset, false); const p = page(true); await p.instance.checkForUpdate();
  const oldGeneration = p.instance.pendingAppUpdate_.source.generation;
  Session.configure(testB.url, testB.asset, false); await p.instance.checkForUpdate();
  assert.ok(p.instance.pendingAppUpdate_.source.generation > oldGeneration);
  p.instance.updateDialogCtrl_ = null; p.instance.drainUpdateDialogs_();
  assert.equal(p.dialogs.length, 1); assert.equal(p.dialogs[0].options.builder.sourceLabel, '临时测试源');
  assert.equal(p.dialogs[0].options.builder.selfUpdateParams.testAsset.url, testB.asset.url);
});

await test('production await across a new matching-version test session never receives testAsset', async () => {
  const response = deferred(); fetchBoundary = () => response.promise;
  // 正式检查先读官网当前推荐头；仍须保留请求前捕获的正式来源身份，不能受后来
  // 激活的诊断会话影响。来源快照的 legacy URL 列表继续由 Session 原样核实。
  const p = page(); const checking = p.instance.checkForUpdate(); assert.equal(requests[0].url, 'https://amcl.lovedhy.cn/api/packages/manifest?product=sideload&channel=stable');
  Session.configure(testA.url, testA.asset, true); response.resolve(JSON.stringify(productionManifest)); await checking;
  assert.equal(p.dialogs.length, 1); const shown = p.dialogs[0].options.builder;
  assert.equal(shown.sourceLabel, 'GitHub 发布'); assert.equal(shown.selfUpdateParams.testAsset, undefined);
  assert.equal(shown.selfUpdateParams.sameVersionTest, undefined);
  assert.equal(shown.selfUpdateParams.manifest.delivery.assets[0].url, productionAsset.url);
});

await test('automatic production and deferred production keep formal origin while test session is active', async () => {
  Session.configure(testA.url, testA.asset, false); const p = page(true); p.instance.initUpdateCheck(); await settle();
  assert.equal(requests[0].url, 'https://amcl.lovedhy.cn/api/packages/manifest?product=sideload&channel=stable'); assert.equal(p.instance.pendingAppUpdate_.source.testSource, false);
  p.instance.updateDialogCtrl_ = null; p.instance.drainUpdateDialogs_();
  assert.equal(p.dialogs[0].options.builder.sourceLabel, 'GitHub 发布');
  assert.equal(p.dialogs[0].options.builder.selfUpdateParams.testAsset, undefined);
});

await test('mutated or reordered formal URL snapshot cannot become a formal candidate after real fetch', async () => {
  for (const change of [source => { source.urls[0] = testA.url; }, source => { source.urls.reverse(); }, source => { source.urls.push(testA.url); }]) {
    const source = Session.productionSource(); change(source); assert.equal(Session.isCurrent(source), false);
    const result = await Checker.checkForUpdate(source.urls, 'default'); Session.validateResult(result, source);
    assert.equal(result.ok, false); assert.equal(result.hasUpdate, false); assert.equal(result.manifest, null);
    assert.equal(Policy.candidate(testA.manifest, source, true), null);
  }
});

await test('candidate and queue deep copies protect manifest, delivery and source against caller alias changes', async () => {
  const raw = Checker.parseManifest(JSON.stringify(productionManifest)), source = Session.productionSource();
  const candidate = Policy.candidate(raw, source, true); assert.ok(candidate);
  raw.url = 'https://wrong.example/changed'; raw.delivery.assets[0].sha256 = 'd'.repeat(64); source.urls[0] = testA.url;
  assert.equal(candidate.manifest.url, productionManifest.url); assert.equal(candidate.manifest.delivery.assets[0].sha256, productionAsset.sha256);
  assert.equal(candidate.source.urls[0], officialUrls[0]);
  const queued = Policy.queue(null, candidate); assert.ok(queued);
  candidate.manifest.notes = 'changed by caller'; candidate.source.urls[0] = testB.url;
  assert.equal(queued.manifest.notes, productionManifest.notes); assert.equal(queued.source.urls[0], officialUrls[0]);
  const displayed = Policy.select(queued, false); assert.ok(displayed); displayed.manifest.notes = 'changed by renderer';
  assert.equal(queued.manifest.notes, productionManifest.notes);
});

await test('session copies original asset and returned parameters; tampered snapshot and product gate fail closed', async () => {
  const original = structuredClone(testA.asset); original.mirrors = [{ provider: 'miawa', projectId: 'amcl', ready: true, filePath: 'fixture' }];
  Session.configure(testA.url, original, false); const source = Session.captureSource();
  original.sha256 = 'f'.repeat(64); original.mirrors[0].projectId = 'changed';
  assert.equal(Session.isCurrent(source), true); assert.equal(source.asset.sha256, testA.asset.sha256);
  const params = Session.parameters(Checker.parseManifest(JSON.stringify(testA.manifest)), source);
  params.testAsset.sha256 = 'f'.repeat(64); params.testAsset.mirrors[0].projectId = 'changed';
  assert.equal(Session.isCurrent(source), true); source.asset.mirrors[0].projectId = 'changed';
  assert.equal(Session.isCurrent(source), false);
  const fresh = Session.captureSource(); profile.product = 'store'; assert.equal(Session.isCurrent(fresh), false);
  assert.throws(() => Session.parameters(testA.manifest, fresh), /失效/);
});

await test('manual intent stays within the same source and stale input cannot overwrite valid queued production', async () => {
  const source = Session.productionSource(); const manual = Policy.candidate(productionManifest, source, true);
  const automatic = Policy.candidate(productionManifest, source, false);
  assert.equal(Policy.queue(manual, automatic).manual, true); assert.equal(Policy.select(manual, true).manual, true);
  assert.equal(Policy.select(automatic, true), null);
  Session.configure(testA.url, testA.asset, false); const testAutomatic = Policy.candidate(testA.manifest, Session.captureSource(), false);
  assert.equal(Policy.queue(manual, testAutomatic).manual, false);
  Session.clear(); const preserved = Policy.queue(manual, testAutomatic);
  assert.equal(preserved.source.testSource, false); assert.equal(preserved.manifest.url, productionManifest.url);
  assert.throws(() => Session.parameters(testA.manifest, testAutomatic.source), /失效/);
});

await test('same-version override remains scoped to test and formal bad metadata still cannot prompt', async () => {
  currentCode = 1000682; Session.configure(testA.url, testA.asset, true); const testSource = Session.captureSource();
  const testResult = await Checker.checkForUpdate(testSource.urls, 'default'); assert.equal(testResult.hasUpdate, false);
  Session.validateResult(testResult, testSource); assert.equal(testResult.hasUpdate, true);
  const productionSource = Session.productionSource(); const productionResult = await Checker.checkForUpdate(productionSource.urls, 'default');
  Session.validateResult(productionResult, productionSource); assert.equal(productionResult.hasUpdate, false);
  assert.equal(Session.parameters(productionResult.manifest, productionSource).testAsset, undefined);
  currentCode = 1000681; fetchBoundary = async () => JSON.stringify({ ...productionManifest,
    delivery: { schema: 1, ready: true, assets: [{ ...productionAsset, url: testA.asset.url }] } });
  const bad = page(); bad.instance.initUpdateCheck(); await settle();
  assert.equal(bad.dialogs.length, 0); assert.equal(bad.instance.pendingAppUpdate_, null);
  assert.equal(bad.instance.prefManager.lastUpdateCheckAt, 0);
});

Session.clear();
console.log(JSON.stringify({ suite: 'sideload-prompt-source', passed, implementation: 'real UpdateChecker/TestSession/PromptPolicy/Index methods',
  deviceOrVisualVerification: false }));
