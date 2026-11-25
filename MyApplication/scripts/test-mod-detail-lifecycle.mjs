/**
 * 四类资源详情的退出生命周期回归。
 *
 * 执行生产 openDetail、异步选版、父 Builder、标题关闭回调及真实 MainStep/HeroCard/StatsCard，
 * 只隔离网络、安装服务、图像与 ArkUI 原生绘制边界。退出期 Prop 同步和再次绘制由宿主显式
 * 投递，用于证明数据契约；这里没有运行 ArkUI 帧调度、原生退出动画或真实设备输入。
 *
 * 所有业务夹具只存在内存；--output 仅保存独占的小型收据，失败亦保留。没有临时文件、
 * 计时器或子进程需要退役，不清理共享父目录。源码前后摘要不一致时本轮结果必须失败。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { loadActionComponent, actionUiReceiver } from './lib/unified-actions-fixture.mjs';
import { productionPathPolicy } from './mod-install-test-runtime.mjs';
import { PROJECT_ROOT, assertExternalOutputPath, resolveWorkspacePath } from './lib/workspace-paths.mjs';

const outputAt = process.argv.indexOf('--output');
assert.ok(outputAt < 0 || process.argv[outputAt + 1], '--output 后必须提供仓库外证据目录');
const startedAt = new Date().toISOString();
// 独立调用可显式选目录；总门无参数调用时沿用现行路由/AMCL_RUN_DIR和公开CI系统临时根。
const outputRoot = outputAt >= 0 ? assertExternalOutputPath(process.argv[outputAt + 1])
  : resolveWorkspacePath('run', 'mod-detail-lifecycle');
const output = path.join(outputRoot,
  'run-' + startedAt.replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z') + '-' + process.pid);
fs.mkdirSync(output, { recursive: true });
const pageFile = 'entry/src/main/ets/pages/ModBrowsePage.ets';
const sheetFile = 'entry/src/main/ets/components/ModDetailSheet.ets';
const resourceControlFile = 'entry/src/main/ets/runtime/UnavailableResourceControl.ets';
const typesFile = 'mods/src/main/ets/ModTypes.ets';
const sources = [pageFile, sheetFile, resourceControlFile, typesFile, 'mods/src/main/ets/ModDependencyResolver.ets',
  'mods/src/main/ets/ModpackInstaller.ets', 'feature_core/src/main/ets/modloader/MavenUtils.ets',
  'scripts/lib/unified-actions-fixture.mjs', 'scripts/lib/load-pure-ets.mjs', 'scripts/lib/ets-compiler.mjs'];
const hash = value => createHash('sha256').update(value).digest('hex');
const hashes = () => Object.fromEntries(sources.map(file => [file,
  hash(fs.readFileSync(path.join(PROJECT_ROOT, file)))]));
const initialHashes = hashes(), groups = [], controls = [];
const pageSource = fs.readFileSync(path.join(PROJECT_ROOT, pageFile), 'utf8');

/** 共享解析器只定位真实成员/属性，测试不会据名称重新实现任何业务判断。 */
function pageAst(source = pageSource) {
  return compiler.createSourceFile(pageFile, source, compiler.ScriptTarget.Latest, true);
}

/** 取主详情 bindSheet 的真实生命周期表达式，避免在测试侧手写另一个关闭回调。 */
function sheetLifecycleExpression(name) {
  const ast = pageAst(), begin = pageSource.indexOf('.bindSheet($$this.showDetailSheet_');
  assert.ok(begin >= 0, '必须命中资源详情的真实 Sheet 绑定');
  const end = pageSource.indexOf('// ============== VersionPickerSheet', begin);
  let expression;
  function visit(node) {
    if (node.name?.getText(ast) === name && node.getStart(ast) > begin && node.end < end) {
      expression = node.initializer.getText(ast);
    }
    compiler.forEachChild(node, visit);
  }
  visit(ast);
  assert.ok(expression, '真实 Sheet 缺少生命周期：' + name);
  return new Function('return ' + expression);
}

/**
 * @State 名单取自真实页面声明；后续通过 Proxy 拒绝实际写入，而非仅搜索生命周期正文。
 * 这样 aboutToDisappear 直接或间接调用的帮助函数、以及卸载后迟到的 Promise 都受约束。
 */
function stateFieldNames() {
  const ast = pageAst();
  const owner = ast.statements.find(node => node.members && node.name?.getText(ast) === 'ModBrowsePage');
  return new Set(owner.members.filter(member => /@State\b/.test(member.getText(ast)))
    .map(member => member.name?.getText(ast)).filter(Boolean));
}

/** 名称输入是 openDetail 的同步依赖，同样抽取生产函数并使用真实路径策略。 */
function namingFunctions() {
  const file = 'mods/src/main/ets/ModpackInstaller.ets';
  const ast = compiler.createSourceFile(file, fs.readFileSync(path.join(PROJECT_ROOT, file), 'utf8'),
    compiler.ScriptTarget.Latest, true, compiler.ScriptKind.TS);
  const source = ast.statements.filter(node => compiler.isFunctionDeclaration(node)
    && ['sanitizeVersionName', 'validateModpackVersionName'].includes(node.name?.text))
    .map(node => node.getText(ast)).join('\n');
  const js = compiler.transpileModule(source, { compilerOptions: {
    module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2021 } }).outputText;
  const exported = {};
  new Function('exports', 'safeBaseName', js)(exported, productionPathPolicy().safeBaseName);
  return exported;
}

/**
 * 负控只向生产请求关闭方法追加原缺陷的同步清空动作，保留其它生产控制流。
 * 预期必须由同一退出期数据断言检出；不会用转译报错或人为抛错冒充回归有效。
 */
function restoreSynchronousProjectClear(source) {
  const ast = pageAst(source);
  const owner = ast.statements.find(node => node.members && node.name?.getText(ast) === 'ModBrowsePage');
  const close = owner.members.find(member => member.name?.getText(ast) === 'closeDetail');
  assert.ok(close?.body, '负控必须命中真实 closeDetail');
  return source.slice(0, close.body.end - 1) + '\nthis.detailProject_ = {} as RemoteProject;\n'
    + source.slice(close.body.end - 1);
}

/** 在受控边界等待真实 Promise，避免固定微任务次数或 sleep 猜测选版进度。 */
function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, no) => { resolve = ok; reject = no; });
  return { promise, resolve, reject };
}

const pureLoad = makePureEtsLoader({ commons: {}, './ModSourceRouter': {} });
const types = pureLoad(typesFile);
const resolver = pureLoad('mods/src/main/ets/ModDependencyResolver.ets');
const naming = namingFunctions(), stateFields = stateFieldNames();
const kinds = [types.ResourceKind.MOD, types.ResourceKind.SHADER,
  types.ResourceKind.RESOURCE_PACK, types.ResourceKind.MODPACK];
const willAppear = sheetLifecycleExpression('onWillAppear');
const willDisappear = sheetLifecycleExpression('onWillDisappear');
const didDisappear = sheetLifecycleExpression('onDisappear');

/**
 * 每案独占组件和边界。父 Builder 原样产生 Props/回调；原生 Prop 派发用 Object.assign
 * 显式作用于同一个仍保留的 Sheet，不在关闭时重建组件来掩盖退出期读取。
 */
function fixture(kind, { mutatePage, validTarget = false } = {}) {
  const ui = actionUiReceiver(), requests = [], calls = { installed: [], counterpart: 0 };
  const globals = { ...ui.globals, Flex: (...args) => ui.globals.Row(...args),
    Scroll: (...args) => ui.globals.Column(...args), FlexWrap: { Wrap: 'Wrap' },
    BarState: { Off: 'Off' }, Curve: { FastOutSlowIn: 'original-curve' } };
  // SDK printer 将声明容器后的修饰器打印成独立调用；仍用现有接收器接住这些绘制边界。
  for (const name of ['alignItems', 'justifyContent', 'scrollBar', 'translate', 'clip', 'onAreaChange']) {
    globals[name] = (...args) => ui.globals.Column(...args);
  }
  let titleOptions;
  const Sheet = loadActionComponent(sheetFile, 'ModDetailSheet', { render: true,
    methods: ['ANIM_DURATION_MS', 'build', 'modDetailTitle_', 'MainStep', 'HeroCard', 'StatsCard',
      'StatCell', 'formatCount', 'formatUpdated', 'ImmersiveTitleContent1_', 'selectedGroupVersions',
      'versionSupportsMc', 'gotoPicker', 'gotoFiles', 'backToPicker', 'backToMain'], globals,
    dependencies: { mods: types, commons: { AppIconName: { Mod: 'Mod' } },
      './RemoteImage': { RemoteImage: () => {} }, './ModCard': { kindIcon: () => '' },
      './ImmersiveTitleScaffold': { ImmersiveTitleScaffold: options => { titleOptions = options; } } } });
  const sheet = new Sheet();
  Object.assign(sheet, { project: types.makeEmptyRemoteProject(), currentStep: 'main',
    selectedMcGroup: '', slidePct: 0, viewportW: 375, allVersions: [], theme: {},
    SourceBadge() {}, LoaderChip() {}, McVersionBadge() {}, supportedVersionLabel: () => '',
    VersionSelectCard() {}, ModpackNameCard_() {}, DepsCard() {}, CtaBar() {},
    PickerStep() {}, GroupFilesStep() {}, getUIContext: () => ({ animateTo: (_options, change) => change() }) });
  const Page = loadActionComponent(pageFile, 'ModBrowsePage', { render: true, mutate: mutatePage,
    methods: ['openDetail', 'closeDetail', 'invalidateLocalScanCache', 'invalidateDetailWork_',
      'resetDetailState_', 'detailInteractionActive_', 'detailWillAppearCallback_',
      'detailWillDisappearCallback_', 'detailDidDisappearCallback_',
      'onDetailWillDisappear_', 'onDetailDidDisappear_', 'aboutToDisappear', 'dismissLocalDraft_', 'ModDetailSheetBuilder',
      'prefetchDetail', 'pickDetailVersion', 'loadChosenDetail', 'buildDeclaredDepRows',
      'detailInstallIssue', 'buildDepRows', 'confirmInstallFromSheet', 'switchDetailSource',
      'usesCustomResourceSave_', 'currentBrowseKind_', 'retireModpackRecoveryScan_'],
    globals: { TAG: 'ModBrowsePage', LOG_DOMAIN_DOWNLOAD: 1, clearTimeout() {} },
    dependencies: { mods: { ...types, ...resolver, ...naming,
      // 只隔离目标环境读取及依赖服务端口；兼容判断、ready和确认分支继续执行生产方法。
      resolveInstalledLoader: () => 'fabric', resolveInstalledMcVersion: () => '1.21.11',
      makeResolverFromRouter: () => ({ resolve: async () => ({ dependencies: [], conflicts: [],
        depthExceeded: false, hasCompatWarning: false }) }) },
      commons: { AppLogger: { warn() {} } },
      'entry/ProductQaResources': pureLoad(resourceControlFile),
      '../launcherskill/LauncherSkillBus': pureLoad('entry/src/main/ets/launcherskill/LauncherSkillBus.ets'),
      '../services/ModTranslationLoader': { offTranslationStoresUpdated() {} },
      '../services/ModFileSave': { supportsCustomResourceSave: kind => ['mod', 'resourcepack', 'shader'].includes(kind) },
      '../components/ModDetailSheet': { ModDetailSheet: options => { Object.assign(sheet, options); } } } });
  const target = new Page();
  Object.assign(target, { detailProject_: types.makeEmptyRemoteProject(), detailFetchEpoch_: 0,
    detailSessionCounter_: 0, detailSession_: 0, detailPresentedSession_: 0,
    detailClosing_: false, detailDisposed_: false,
    showDetailSheet_: false, localScanCache_: new Map(), localScanCacheEpoch_: 0,
    targetVersionId_: validTarget ? 'target' : '', targetMcDir_: validTarget ? '/mc' : '', targetLocation_: 'sandbox',
    kindIdx_: kind === types.ResourceKind.MODPACK ? 3 : kind === types.ResourceKind.SHADER ? 2 : kind === types.ResourceKind.RESOURCE_PACK ? 1 : 0,
    customSaveKindIndices_: [], theme: {}, downloadingProjectIds_: new Set(),
    hasValidCurrentVersion: () => validTarget, getOrScanInstalled: async () => [],
    toast() {}, debounceTimer_: 0, translationListener_: null,
    retreatAnimationEpoch_: 0, retreatPolicy_: { reset() {} },
    router_: { repoFor: () => ({ getVersions: () => {
      const request = deferred(); requests.push(request); return request.promise;
    } }) },
    resolveCounterpart: async () => { calls.counterpart++; return null; },
    installModpackFromSheet: (...args) => { calls.installed.push(args); },
    executeInstall: async (...args) => { calls.installed.push(args); } });
  const f = { page: undefined, sheet, ui, requests, calls, forbidStateWrites: false, stateWrites: [] };
  f.page = new Proxy(target, { set(object, name, value) {
    if (f.forbidStateWrites && stateFields.has(name)) {
      f.stateWrites.push(String(name));
      assert.fail('卸载后不得写 @State：' + String(name));
    }
    return Reflect.set(object, name, value);
  } });
  const prefetch = Page.prototype.prefetchDetail;
  f.page.prefetchDetail = function(...args) { return (this.prefetchJob = prefetch.apply(this, args)); };
  f.project = { ...types.makeEmptyRemoteProject(), id: 'project', title: 'Entity Culling', kind,
    source: types.ModSource.MODRINTH, iconUrl: '' };
  f.version = { id: 'v1', projectId: 'project', source: types.ModSource.MODRINTH, name: '版本一',
    versionNumber: '1', versionType: 'release', datePublished: '2026-10-01T00:00:00Z',
    gameVersions: ['1.21.11'], loaders: ['fabric'], dependencies: [], files: [{ url: 'https://example.invalid/mod.jar',
      mirrors: [], filename: 'mod.jar', size: 23, isPrimary: true }] };
  f.lifecycle = () => ({ appear: willAppear.call(f.page), will: willDisappear.call(f.page),
    did: didDisappear.call(f.page) });
  f.render = () => {
    ui.clear(); titleOptions = undefined;
    f.page.ModDetailSheetBuilder();
    sheet.build();
    assert.ok(titleOptions, '真实 build 必须产生标题回调');
    titleOptions.content();
    return titleOptions;
  };
  return f;
}

/** 首次打开先产生真实请求；只有返回了版本目录才允许通过生产导航进入 picker/files。 */
async function openFixture(f, { loaded = false, step = 'main' } = {}) {
  f.page.openDetail(f.project);
  assert.equal(f.page.showDetailSheet_, true);
  assert.ok(f.page.detailSession_ > 0, '每次真正打开必须拥有会话身份');
  f.lifecycle().appear();
  if (loaded) { f.requests[0].resolve([f.version]); await f.page.prefetchJob; }
  f.render();
  if (step !== 'main') {
    assert.equal(loaded, true, '未加载的picker/files不是本回归宣称可达的用户路径');
    f.sheet.gotoPicker(); assert.equal(f.sheet.currentStep, 'picker');
    if (step === 'files') { f.sheet.gotoFiles('1.21.11'); assert.equal(f.sheet.currentStep, 'files'); }
  }
  return f.render();
}

/** 请求关闭只退休任务和关门，项目/选版必须保留给退出动画；重绘执行真实正文。 */
function assertExitSnapshot(f, before) {
  assert.equal(f.page.detailProject_, before.project, '退出期必须保留项目快照');
  assert.equal(f.page.detailSelectedVersion_, before.selected, '退出期必须保留选版快照');
  assert.equal(f.page.detailAllVersions_, before.versions, '退出期必须保留目录快照');
  f.render();
}

/** 真正退出后以安全空模型释放UI引用，重复/过期回调不应再有写入。 */
function assertCleared(f) {
  assert.deepEqual(f.page.detailProject_, types.makeEmptyRemoteProject());
  assert.equal(f.page.detailSelectedVersion_, null);
  assert.equal(f.page.detailAllVersions_.length, 0);
  assert.equal(f.page.detailSession_, 0);
  assert.equal(f.page.detailClosing_, false);
  f.render();
}

async function check(name, run) {
  const detail = await run(); groups.push({ name, ...detail }); console.log('PASS ' + name);
}

let failure;
try {
  await check('安全空项目与异常上游标题都可执行真实Hero/统计正文', async () => {
    assert.equal(types.displayTitleOf({}), '');
    assert.equal(types.displayTitleOf({ title: undefined, chineseName: null }), '');
    assert.equal(types.displayTitleOf({ title: 'Original', chineseName: '译名' }), '译名');
    const f = fixture(kinds[0]);
    // 先用生产 reset 初始化所有空态字段，然后执行真实父Builder与正文，不能只断言helper返回值。
    f.page.resetDetailState_(); f.render();
    return { emptyModel: true };
  });

  for (const kind of kinds) {
    for (const state of [{ loaded: false, step: 'main' }, { loaded: true, step: 'main' },
      { loaded: true, step: 'picker' }, { loaded: true, step: 'files' }]) {
      await check(kind + ' ' + (state.loaded ? '已加载' : '未加载') + '/' + state.step + ' X关闭保留退出快照', async () => {
        const f = fixture(kind), header = await openFixture(f, state), callbacks = f.lifecycle();
        const snapshot = { project: f.page.detailProject_, selected: f.page.detailSelectedVersion_,
          versions: f.page.detailAllVersions_ }, epoch = f.page.detailFetchEpoch_;
        header.onClose();
        assert.equal(f.page.showDetailSheet_, false);
        assert.ok(f.page.detailFetchEpoch_ > epoch, '请求关闭立即退休异步工作');
        assertExitSnapshot(f, snapshot);
        const pending = f.page.prefetchJob;
        if (!state.loaded) { f.requests[0].resolve([f.version]); await pending; }
        assertExitSnapshot(f, snapshot);
        await f.page.pickDetailVersion(f.version);
        f.page.confirmInstallFromSheet(); await f.page.switchDetailSource(types.ModSource.CURSEFORGE);
        assert.equal(f.calls.counterpart, 0, '关闭期旧回调不能开始切源');
        assert.equal(f.calls.installed.length, 0, '关闭期旧CTA不能提交安装');
        assertExitSnapshot(f, snapshot);
        callbacks.will(); assertExitSnapshot(f, snapshot);
        callbacks.did(); assertCleared(f);
        return { kind, ...state };
      });
    }
  }

  await check('系统关闭开始就失效目录请求，真正退出才清理且旧回调不清新会话', async () => {
    const f = fixture(kinds[0]); await openFixture(f);
    const old = f.lifecycle(), epoch = f.page.detailFetchEpoch_, session = f.page.detailSession_;
    const snapshot = { project: f.page.detailProject_, selected: f.page.detailSelectedVersion_,
      versions: f.page.detailAllVersions_ };
    f.forbidStateWrites = true; old.will(); f.forbidStateWrites = false;
    assert.ok(f.page.detailFetchEpoch_ > epoch); assertExitSnapshot(f, snapshot);
    f.requests[0].resolve([f.version]); await f.page.prefetchJob; assertExitSnapshot(f, snapshot);
    f.page.openDetail({ ...f.project, id: 'too-early' });
    assert.equal(f.page.detailSession_, session, '退出动画中不创建新会话');
    assert.equal(f.requests.length, 1);
    old.did(); assertCleared(f);
    f.page.openDetail({ ...f.project, id: 'new-project', title: 'New Project' });
    const next = f.page.detailSession_; assert.ok(next > session);
    f.requests[1].resolve([f.version]); await f.page.prefetchJob;
    old.will(); old.did();
    assert.equal(f.page.detailSession_, next); assert.equal(f.page.showDetailSheet_, true);
    assert.equal(f.page.detailProject_.id, 'new-project'); f.render();
    return { oldSession: session, newSession: next, staleCallbacksIgnored: true };
  });

  await check('同帧打开关闭尚未呈现时可再次打开，旧呈现和退场回调均不碰新会话', async () => {
    const f = fixture(kinds[0]); f.page.openDetail(f.project);
    const old = f.lifecycle(), oldJob = f.page.prefetchJob, oldSession = f.page.detailSession_;
    f.page.closeDetail();
    assert.equal(f.page.detailSession_, 0); assert.equal(f.page.detailClosing_, false);
    assert.equal(f.page.detailProject_, f.project, '未呈现时同样不清除可能排队读取的快照');
    f.page.openDetail({ ...f.project, id: 'same-frame-new' });
    const next = f.page.detailSession_; assert.ok(next > oldSession);
    f.lifecycle().appear(); old.appear(); old.will(); old.did();
    assert.equal(f.page.detailSession_, next); assert.equal(f.page.detailPresentedSession_, next);
    assert.equal(f.page.showDetailSheet_, true); assert.equal(f.page.detailProject_.id, 'same-frame-new');
    f.requests[0].resolve([f.version]); await oldJob;
    f.requests[1].resolve([f.version]); await f.page.prefetchJob; f.render();
    return { sameFrameReopen: true, oldCallbacksIgnored: true };
  });

  await check('已呈现详情切换来源保持同一会话，真实新目录替换旧项目', async () => {
    const f = fixture(kinds[0]);
    f.project.altSource = types.ModSource.CURSEFORGE;
    await openFixture(f, { loaded: true });
    const session = f.page.detailSession_;
    f.page.resolveCounterpart = async () => ({ ...f.project, source: types.ModSource.CURSEFORGE,
      id: 'other-source', title: 'Other Source' });
    const changing = f.page.switchDetailSource(types.ModSource.CURSEFORGE);
    // 切换等待目标来源的真实目录。先让生产代码发起请求，再由平台替身回包。
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(f.page.detailSession_, session); assert.equal(f.page.detailPresentedSession_, session);
    assert.equal(f.requests.length, 2); assert.equal(f.page.detailProject_.id, 'other-source');
    f.requests[1].resolve([f.version]); assert.equal(await changing, 'other-source'); await f.page.prefetchJob; f.render();
    return { sessionRetained: true };
  });

  await check('页面卸载只退休普通工作与服务，生命周期及迟到Promise不写State', async () => {
    const f = fixture(kinds[0]); await openFixture(f);
    const callbacks = f.lifecycle(), before = f.page.detailFetchEpoch_;
    const discarded=[];
    f.page.localArchiveOwner_=flag=>discarded.push(flag);
    f.page.localModpackArchive_='/owned/local.mrpack';
    f.forbidStateWrites = true;
    f.page.aboutToDisappear();
    assert.deepEqual(discarded,[true]);
    assert.equal(f.page.localModpackArchive_,'');
    assert.ok(f.page.detailFetchEpoch_ > before);
    assert.equal(f.page.detailDisposed_, true);
    callbacks.will(); callbacks.did();
    f.requests[0].reject(Error('卸载后的来源失败')); await f.page.prefetchJob.catch(() => {});
    await Promise.resolve();
    assert.deepEqual(f.stateWrites, []);
    return { stateWrites: 0 };
  });

  for (const kind of kinds) {
    await check(kind + '真实安装入口捕获请求后统一关闭，退场清理不改变已提交快照', async () => {
      const f = fixture(kind, { validTarget: true }); await openFixture(f, { loaded: true });
      const callbacks = f.lifecycle(), project = f.page.detailProject_, version = f.page.detailSelectedVersion_,
        primary = f.page.detailPrimaryFile_, name = f.page.detailModpackName_, deps = f.page.detailResolvedDeps_.slice();
      f.page.confirmInstallFromSheet();
      assert.equal(f.calls.installed.length, 1); assert.equal(f.page.showDetailSheet_, false);
      assertExitSnapshot(f, { project, selected: version, versions: f.page.detailAllVersions_ });
      callbacks.did(); assertCleared(f);
      // 正常页面提交保留四项业务参数，且没有 QA 任务观察回调。
      assert.deepEqual(f.calls.installed[0], [project, version, primary,
        kind === types.ResourceKind.MODPACK ? name : deps, undefined]);
      return { kind, installSubmittedOnce: true };
    });
  }

  await check('负控：恢复同步清空由同一退出期行为断言检出', async () => {
    const f = fixture(kinds[0], { mutatePage: restoreSynchronousProjectClear });
    const header = await openFixture(f, { loaded: true });
    const snapshot = { project: f.page.detailProject_, selected: f.page.detailSelectedVersion_,
      versions: f.page.detailAllVersions_ };
    header.onClose();
    assert.throws(() => assertExitSnapshot(f, snapshot), /退出期必须保留项目快照/);
    controls.push({ mutation: 'synchronous-project-clear', detectedBy: 'retained-exit-project' });
    return { negativeControlRejected: true };
  });
} catch (error) { failure = error; }

const finalHashes = hashes(), sourceStable = JSON.stringify(initialHashes) === JSON.stringify(finalHashes);
if (!sourceStable && !failure) failure = new Error('测试期间源码变化，本轮结果不能绑定新候选');
const receipt = { schemaVersion: 1, kind: 'source-bound-mod-detail-lifecycle-tests', startedAt,
  finishedAt: new Date().toISOString(), sourceRoot: PROJECT_ROOT, state: failure ? 'FAIL' : 'PASS',
  groups, controls, sourceStable, sourceHashes: initialHashes, finalSourceHashes: finalHashes,
  harnessSha256: hash(fs.readFileSync(new URL(import.meta.url))), temporaryFilesCreated: 0,
  failure: failure ? String(failure.stack ?? failure) : undefined,
  limitations: ['Prop refresh and repaint are explicitly delivered by the host; no ArkUI frame scheduling, native exit animation, device gestures or network delivery were executed',
    'MainStep, HeroCard and StatsCard are real; image/native title rendering, secondary cards, picker/files list bodies and installation service are isolated boundaries'] };
fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2));
if (failure) { console.error(failure.stack ?? failure); process.exitCode = 1; }
console.log(JSON.stringify({ state: receipt.state, groups: groups.length, sourceStable,
  receipt: path.join(output, 'receipt.json') }));
