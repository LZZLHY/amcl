/**
 * 执行真实 UpdateChecker、PromptPolicy 和首页方法，验证正式通道切换、清单快照与提示排队。
 * 替身仅提供 HTTP、bundleManager、ArkUI controller/Toast 与可见性边界；
 * 正式收据核对、入队和出队使用产品源码。
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
let currentCode = 1000681, fetchBoundary;
const requests = [], logMessages = [];
const logger = { info: (_tag, message) => logMessages.push(message), warn() {}, debug() {} };
// 平台日志/地址可替身，运行时声明的纯校验必须加载当前生产实现。
const commons = { ...load('commons/src/main/ets/common/RuntimeRequirementPolicy.ets'), AppLogger: logger, formatError: String, UPDATE_MANIFEST_URLS: officialUrls,
   DistributionPolicy: { allowSideloadUpdates: () => true, isStore: () => false } };
const models = load('update/src/main/ets/SideloadUpdateModels.ets');
const noteTypes = load('update/src/main/ets/ChangelogTypes.ets');
const resolver = load('update/src/main/ets/GitHubUpdateAssetResolver.ets', { '@kit.NetworkKit': {}, './AppUpdatePolicy':load('update/src/main/ets/AppUpdatePolicy.ets'), commons });
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
const { SideloadUpdatePromptPolicy: Policy } = load('entry/src/main/ets/sideload/SideloadUpdatePromptPolicy.ets');
const { UpdateChecker: Checker } = checkerModule;

const productionAsset = { tag: 'v1.0.5', name: 'amcl-v1.0.5-sideload-unsigned.hap',
  url: 'https://github.com/LZZLHY/amcl/releases/download/v1.0.5/amcl-v1.0.5-sideload-unsigned.hap',
  sha256: 'c'.repeat(64), sizeBytes: 100, versionCode: 1000682, versionName: '1.0.5', product: 'sideload',
  legacyUniversal: false, websiteUrl: 'https://amcl.lovedhy.cn/api/packages/files/' + 'c'.repeat(64) + '/amcl-v1.0.5-sideload-unsigned.hap',
  mirrors: [{ provider: 'miawa', projectId: 'amcl', ready: true, filePath: 'amcl/v1.0.5/amcl-v1.0.5-sideload-unsigned.hap' }] };
const productionManifest = { versionCode: productionAsset.versionCode, versionName: productionAsset.versionName, tag: productionAsset.tag,
  sizeBytes: productionAsset.sizeBytes, mandatory: false, schema: 1, date: '2026-10-05', changelogUrl: '', notesEntries: [],
  url: 'https://github.com/LZZLHY/amcl/releases/tag/v1.0.5',
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
  const scope = { UpdateChecker: Checker, SideloadUpdatePromptPolicy: Policy,
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
/** 每个场景重置平台和下载服务输入；真正的解析、缓存及提示判据均由生产实现执行。 */
async function test(name, run) {
  profile.product = 'default'; currentCode = 1000681; requests.length = 0;
  fetchBoundary = async () => JSON.stringify(productionManifest);
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

await test('candidate and queue own deep copies of the formal manifest and its delivery', async () => {
  const raw = Checker.parseManifest(JSON.stringify(productionManifest));
  const candidate = Policy.candidate(raw, true); assert.ok(candidate);
  raw.url = 'https://wrong.example/changed'; raw.delivery.assets[0].sha256 = 'd'.repeat(64);
  assert.equal(candidate.manifest.url, productionManifest.url); assert.equal(candidate.manifest.delivery.assets[0].sha256, productionAsset.sha256);
  const queued = Policy.queue(null, candidate); assert.ok(queued);
  candidate.manifest.notes = 'changed by caller';
  assert.equal(queued.manifest.notes, productionManifest.notes);
  const displayed = Policy.select(queued, false); assert.ok(displayed); displayed.manifest.notes = 'changed by renderer';
  assert.equal(queued.manifest.notes, productionManifest.notes);
});

await test('manual request survives queue replacement and automatic requests stay suppressed after game launch', async () => {
  const manual = Policy.candidate(productionManifest, true);
  const automatic = Policy.candidate(productionManifest, false);
  assert.equal(Policy.queue(manual, automatic).manual, true); assert.equal(Policy.select(manual, true).manual, true);
  assert.equal(Policy.select(automatic, true), null);
});

await test('same release cannot prompt again and invalid production metadata cannot open a dialog', async () => {
  currentCode = 1000682;
  const result = await Checker.checkForUpdate(undefined, 'default');
  assert.equal(result.hasUpdate, false);
  currentCode = 1000681; fetchBoundary = async () => JSON.stringify({ ...productionManifest,
    delivery: { schema: 1, ready: true, assets: [{ ...productionAsset, url: 'https://wrong.example/target.hap' }] } });
  const bad = page(); bad.instance.initUpdateCheck(); await settle();
  assert.equal(bad.dialogs.length, 0); assert.equal(bad.instance.pendingAppUpdate_, null);
  assert.equal(bad.instance.prefManager.lastUpdateCheckAt, 0);
});

console.log(JSON.stringify({ suite: 'sideload-prompt-source', passed, implementation: 'real UpdateChecker/PromptPolicy/Index methods',
  deviceOrVisualVerification: false }));
