/**
 * 资源另存宿主回归。运行模组、光影与资源包的保存协调、下载规格、任务队列和 URI 复制代码；
 * 系统 Picker、FileIO、Native 传输及活动存储使用可暂停的测试端口，不触碰真实用户文件。
 */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const context = { cacheDir: '/sandbox/cache' };
const oldContents = Buffer.from('user-owned-original');
const hash = (bytes, algorithm = 'sha1') => createHash(algorithm).update(bytes).digest('hex');

/** 每类用独立文件名、摘要和目录 URI，避免单例状态或同名缓存掩盖分类错误。 */
function resourceSample(kind, index, category, filename) {
  const payload = Buffer.from('verified-' + filename);
  const project = { id: 'sample-' + kind, source: 'modrinth', kind, title: 'Sample ' + kind, iconUrl: '' };
  const file = { filename, url: 'https://cdn.modrinth.com/test/' + filename,
    mirrors: ['https://mirror.invalid/' + filename], size: payload.length, sha1: hash(payload), isPrimary: true };
  const loaders = kind === 'mod' ? ['fabric'] : kind === 'shader' ? ['iris'] : ['minecraft'];
  const version = { id: 'sample-release-' + kind, projectId: project.id, source: project.source, files: [file],
    versionNumber: '1.0.0', gameVersions: ['1.21.1'], loaders, dependencies: [] };
  return { index, category, project, file, version, payload, uri: 'file://docs/storage/Users/currentUser/Docs/' + filename };
}

const modSample = resourceSample('mod', 0, 'mod', 'mod.jar');
const packSample = resourceSample('resourcepack', 1, 'rpack', 'resources.zip');
const shaderSample = resourceSample('shader', 2, 'shader', 'shaders.zip');
const { project, file, version, payload, uri } = modSample;

/** 闸门只控制平台端口返回的时序，是否创建任务、何时复制由生产代码决定。 */
function deferred() {
  let resolve;
  const promise = new Promise((complete) => { resolve = complete; });
  return { promise, resolve };
}

async function until(predicate, description) {
  for (let i = 0; i < 100; i++) {
    if (predicate()) return;
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.fail(description);
}

/**
 * ArkUI 布局由设备验证。宿主抽取实际页面方法，保留详情代次及销毁判据；
 * 只替换 UIContext 和视觉投影，避免把“仍是当前详情”作为固定 mock 直接通过。
 */
function makePageFactory() {
  const relative = 'entry/src/main/ets/pages/ModBrowsePage.ets';
  const source = readFileSync(new URL('../' + relative, import.meta.url), 'utf8');
  const names = ['hasValidCurrentVersion', 'usesCustomResourceSave_', 'currentBrowseKind_', 'onPickCustomResourceSave_',
    'detailInteractionActive_', 'invalidateDetailWork_', 'closeDetail', 'saveResourceFileFromSheet_',
    'detailInstallIssue', 'buildDeclaredDepRows', 'loadChosenDetail', 'confirmInstallFromSheet'];
  const methods = names.map((name) => {
    const position = new RegExp('^  private (?:async )?' + name + '\\(', 'm').exec(source);
    assert(position, '找不到生产页面方法 ' + name);
    const ast = compiler.createSourceFile('PageFixture.ts', 'class Page {\n' + source.slice(position.index),
      compiler.ScriptTarget.Latest, true);
    const method = ast.statements.find(compiler.isClassDeclaration).members[0];
    assert.equal(method.name.getText(ast), name);
    return method.getText(ast);
  });
  const js = compiler.transpileModule('class Page {\n' + methods.join('\n') + '\n}', {
    compilerOptions: { target: compiler.ScriptTarget.ES2020 },
  }).outputText;
  return new Function('pickAndStartModFileSave', 'supportsCustomResourceSave', 'pickPrimaryFile',
    'ResourceKind', 'ModSource', 'DependencyType', js + '\nreturn Page;');
}

const createPageClass = makePageFactory();

function fixture({ initial = Buffer.alloc(0), downloadError = false, failWrite = false, sample = modSample } = {}) {
  const { project, file, version, payload, uri } = sample;
  const events = [];
  const files = new Map();
  const folders = new Set();
  const opened = new Map();
  const pickerResult = deferred();
  const nativeResult = deferred();
  const nativeRelease = deferred();
  let serial = 0;
  let adapterCompletion;
  let selectedNames;
  let activeFileTasks = 0;
  let targetWrites = 0;

  function put(name, contents) {
    files.set(name, { bytes: Buffer.from(contents), inode: ++serial, mtime: 0 });
  }

  function get(name) {
    const node = files.get(name);
    if (node === undefined) throw Object.assign(new Error('fixture file not found'), { code: 13900002 });
    return node;
  }

  function stat(node) {
    return { size: node.bytes.length, ino: BigInt(node.inode), mtime: node.mtime, ctime: node.mtime,
      mtimeNs: BigInt(node.mtime), ctimeNs: BigInt(node.mtime), isFile: () => true };
  }

  const fs = {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 64, NOFOLLOW: 131072 },
    async open(name, flags) {
      events.push(['open', name, flags]);
      assert.equal(flags & 512, 0, '任何阶段都不能用 TRUNC 打开用户文件');
      const fd = ++serial;
      opened.set(fd, { name, node: get(name), position: 0 });
      return { fd };
    },
    async stat(name) {
      return stat(typeof name === 'number' ? opened.get(name).node : get(name));
    },
    async lstat(name) { return stat(get(name)); },
    async close(handle) {
      assert(opened.delete(handle.fd), '句柄须由同一任务关闭一次');
    },
    async read(fd, buffer, { length = buffer.byteLength, offset } = {}) {
      const handle = opened.get(fd);
      const start = offset ?? handle.position;
      const count = handle.node.bytes.copy(Buffer.from(buffer), 0, start,
        Math.min(handle.node.bytes.length, start + length));
      if (offset === undefined) handle.position += count;
      return count;
    },
    async write(fd, buffer) {
      const handle = opened.get(fd);
      assert.equal(handle.name, uri);
      if (failWrite && targetWrites > 0) throw new Error('fixture target write failed');
      const chunk = Buffer.from(buffer).subarray(0, 4);
      const bytes = Buffer.alloc(Math.max(handle.node.bytes.length, handle.position + chunk.length));
      handle.node.bytes.copy(bytes);
      chunk.copy(bytes, handle.position);
      handle.node.bytes = bytes;
      handle.node.mtime++;
      handle.position += chunk.length;
      targetWrites++;
      events.push(['target-write', chunk.length]);
      return chunk.length;
    },
    async fsync(fd) { assert(opened.has(fd)); },
    async mkdtemp(prefix) {
      assert.equal(prefix, context.cacheDir + '/amcl-mod-save-XXXXXX', '系统 mkdtemp 要求六个 X 的模板');
      const directory = prefix.slice(0, -6) + String(++serial).padStart(6, '0');
      folders.add(directory);
      return directory;
    },
    async unlink(name) {
      assert(files.delete(name));
    },
    async rmdir(directory) {
      assert(folders.delete(directory), '只能回收该任务独占的暂存目录');
      assert(!Array.from(opened.values()).some((entry) => entry.name.startsWith(directory + '/')));
      for (const name of files.keys()) {
        if (name.startsWith(directory + '/')) files.delete(name);
      }
      events.push(['cleanup', directory]);
    },
  };

  const picker = {
    DocumentPickerMode: { DEFAULT: 0 },
    DocumentSaveOptions: class {},
    DocumentViewPicker: class {
      constructor(selectedContext) { assert.equal(selectedContext, context); }
      async save(options) {
        selectedNames = options.newFileNames;
        events.push(['picker']);
        const result = await pickerResult.promise;
        if (result.includes(uri)) put(uri, initial);
        return result;
      }
    },
  };
  const manager = {
    async createAndWait(spec, progress) {
      assert.equal(spec.files.length, 1);
      const local = spec.files[0];
      assert(folders.has(local.allowedRoot));
      assert.equal(local.localPath, local.allowedRoot + '/' + file.filename);
      assert.deepEqual(local.urls, [file.url, ...file.mirrors]);
      assert.deepEqual(local.check, { sha1: file.sha1, size: file.size });
      events.push(['native-start', spec]);
      progress?.({ taskId: 41, bytesDone: 3, bytesTotal: payload.length,
        filesDone: 0, filesTotal: 1, speedBps: 100, etaSeconds: 1, status: 'downloading' });
      await nativeResult.promise;
      if (downloadError) {
        put(local.localPath + '.part', payload.subarray(0, 3));
        throw new Error('fixture native checksum mismatch');
      }
      put(local.localPath, payload);
      events.push(['native-verified']);
      return { taskId: 41, bytesDone: payload.length, bytesTotal: payload.length,
        filesDone: 1, filesTotal: 1, failedFiles: [] };
    },
    async awaitTaskReleased(id) {
      assert.equal(id, 41);
      events.push(['native-release-wait']);
      await nativeRelease.promise;
      events.push(['native-released']);
      return true;
    },
    cancel(id) { assert.equal(id, 41); },
  };
  const cryptoFramework = {
    createMd(algorithm) {
      const digest = createHash(algorithm.toLowerCase().replaceAll('-', ''));
      return {
        async update({ data }) { digest.update(data); },
        async digest() { return { data: digest.digest() }; },
      };
    },
  };
  const logger = { info() {}, warn() {}, error() {} };
  const commons = { AppLogger: logger, LOG_DOMAIN_DOWNLOAD: 0, LogTags: { MOD_MAVEN: 'MavenFixture' },
    stringToUtf8: (value) => new TextEncoder().encode(value) };
  const core = {
    DownloadManager: { instance: () => manager }, ActivityCategory: { RESOURCE_MANAGE: 'resource_manage' },
    exportZipInteger: (number) => { assert(Number.isSafeInteger(number) && number >= 0); },
    EXPORT_ZIP_CHUNK: 64 * 1024,
  };
  const mods = {};
  const ports = {
    '@kit.CoreFileKit': { picker, fileIo: fs },
    '@kit.ArkTS': { util: { generateRandomUUID: () => `fixture-${++serial}` } },
    '@kit.BasicServicesKit': {},
    '@kit.CryptoArchitectureKit': { cryptoFramework },
    '@kit.NetworkKit': {}, '@kit.PerformanceAnalysisKit': {},
    commons, feature_core: core, mods,
    './ProcessActivityCoordinator': { ProcessActivityCoordinator: { instance: () => ({
      acquireFileTask() { activeFileTasks++; return () => { activeFileTasks--; }; },
    }) } },
    './TaskActivityOwner': {
      getTaskActivityOwner: () => ({ async beginTask() {}, async finishTask() {} }),
      reserveTaskActivityId: () => 1,
    },
    '../download/DownloadManager': {}, '../download/SourceProber': {}, './MavenSpecBuilder': {},
    './ModInstallTransaction': {}, './ExportNativeArchive': { tryNativeHashFile: async () => undefined },
  };
  // 只替换 UI 装饰器。Registry 仍使用真实状态枚举和入队、退出逻辑。
  const load = makePureEtsLoader(ports, {
    'feature_core/src/main/ets/download/UnifiedDownloadTask.ets':
      'const Observed = (value: Object): Object => value;\n' +
      loadUnifiedDownloadTaskSource(),
  });
  Object.assign(core, load('feature_core/src/main/ets/download/UnifiedDownloadTask.ets'));
  Object.assign(core, load('feature_core/src/main/ets/modloader/MavenUtils.ets'));
  Object.assign(core, load('feature_core/src/main/ets/download/DownloadTaskRegistry.ets'));
  Object.assign(mods, load('mods/src/main/ets/ModTypes.ets'), load('mods/src/main/ets/ModInstaller.ets'));
  ports['../export/ExportArchiveIO'] = load('entry/src/main/ets/export/ExportArchiveIO.ets');
  const registry = core.DownloadTaskRegistry.instance();
  const enqueue = registry.enqueue.bind(registry);
  registry.enqueue = (adapter) => {
    events.push(['enqueue', adapter]);
    adapterCompletion = enqueue(adapter);
    return adapterCompletion;
  };
  const service = load('entry/src/main/ets/services/ModFileSave.ets');
  const Page = createPageClass(service.pickAndStartModFileSave, service.supportsCustomResourceSave, mods.pickPrimaryFile,
    mods.ResourceKind, mods.ModSource, mods.DependencyType);
  return {
    events, folders, opened, files, registry, pickerResult, nativeResult, nativeRelease, put,
    get selectedNames() { return selectedNames; },
    get completion() { return adapterCompletion; },
    get activeFileTasks() { return activeFileTasks; },
    start: (isCurrent = () => true) => service.pickAndStartModFileSave(context, project, version, file, isCurrent),
    createPage({ kind = sample.index, valid = false } = {}) {
      return Object.assign(new Page(), {
        kindIdx_: kind, targetVersionId_: valid ? 'existing-version' : '', targetValid_: valid,
        customSaveKindIndices_: [], showVersionPicker_: true, detailSavePickerPending_: false,
        detailDisposed_: false, detailClosing_: false, showDetailSheet_: true,
        detailSession_: 1, detailPresentedSession_: 1, detailFetchEpoch_: 1,
        detailProject_: project, detailError_: '', router_: {},
        getOrScanInstalled() { assert.fail('另存不读取已安装资源'); },
        executeInstall() { assert.fail('自定义另存不得启动实例安装'); },
        uiCtx: () => context, invalidateLocalScanCache() {},
        refreshResourceTargetProjection_: () => events.push(['target-mode-projected']),
        onOpenDownloadTask: (id) => events.push(['task-sheet', id]),
        toast: (message) => events.push(['toast', message]),
      });
    },
  };
}

/** 从工作树读取真实视图源码，保持 test fixture 使用与服务一致的状态值。 */
function loadUnifiedDownloadTaskSource() {
  return readFileSync(new URL('../feature_core/src/main/ets/download/UnifiedDownloadTask.ets', import.meta.url), 'utf8');
}

function eventNames(f) { return f.events.map(([name]) => name); }

{
  const f = fixture();
  const page = f.createPage();
  assert(page.usesCustomResourceSave_(), '无有效实例默认自定义保存');
  const pending = page.saveResourceFileFromSheet_(project, version, file);
  await page.saveResourceFileFromSheet_(project, version, file);
  assert.deepEqual(f.selectedNames, [file.filename]);
  assert.deepEqual(eventNames(f), ['picker'], '系统保存未确认，不能入队、预开目标或拉正文');
  f.pickerResult.resolve([]);
  await pending;
  assert.deepEqual(eventNames(f), ['picker']);
  assert.equal(page.showDetailSheet_, true, '取消后详情保持原选择');
  assert.equal(page.detailSavePickerPending_, false);
}

{
  const f = fixture();
  const page = f.createPage({ valid: true });
  assert(!page.usesCustomResourceSave_(), '有有效实例默认安装');
  page.onPickCustomResourceSave_();
  assert(page.usesCustomResourceSave_(), '有效实例也允许手动选择另存');
  assert.equal(page.targetVersionId_, 'existing-version', '切换另存不改变原安装实例');
  assert(!f.createPage({ kind: 3 }).usesCustomResourceSave_(), '整合包不开放单文件另存');
  const pending = page.saveResourceFileFromSheet_(project, version, file);
  assert.deepEqual(eventNames(f), ['target-mode-projected', 'picker']);
  page.closeDetail();
  f.pickerResult.resolve([uri]);
  await pending;
  assert(!eventNames(f).includes('enqueue'));
  assert(!eventNames(f).includes('native-start'));
  assert(!eventNames(f).includes('task-sheet'));
  assert.equal(f.files.get(uri).bytes.length, 0);
}

for (const sample of [modSample, shaderSample, packSample]) {
  const { index, category, file, version, payload, uri } = sample;
  const f = fixture({ sample });
  assert(f.createPage().usesCustomResourceSave_(), '当前分类无实例时默认另存');
  const page = f.createPage({ valid: index !== 0 });
  if (index !== 0) {
    assert(!page.usesCustomResourceSave_(), '当前分类有有效实例时默认安装');
    page.onPickCustomResourceSave_();
    assert(page.usesCustomResourceSave_(), '允许主动把当前分类改为另存');
    assert.equal(page.targetVersionId_, 'existing-version');
    page.kindIdx_ = index === 1 ? 2 : 1;
    assert(!page.usesCustomResourceSave_(), '一个分类的手选模式不会改变另一分类');
    page.kindIdx_ = index;
  }
  await page.loadChosenDetail({ ...version, dependencies: [
    { projectId: 'required-dependency', dependencyType: 'required' },
  ] }, 1);
  assert.equal(page.detailInstallReady_, true, '无实例仍能准备保存');
  assert.equal(page.detailPrimaryFile_, file);
  assert.deepEqual(page.detailDeps_.map((item) => item.displayName), ['required-dependency']);
  assert.equal(page.detailDependenciesResolved_, false, '详情保留依赖声明，另存不准备依赖');
  page.confirmInstallFromSheet();
  assert.deepEqual(f.selectedNames, [file.filename], '系统窗口预填所选资源的真实文件名和后缀');
  assert.deepEqual(eventNames(f), index === 0 ? ['picker'] : ['target-mode-projected', 'picker']);
  assert.equal(f.activeFileTasks, 0, '系统窗口确认前不占用下载任务租约');
  f.pickerResult.resolve([uri]);
  await until(() => eventNames(f).includes('task-sheet'), '真实 CTA 确认后应打开任务详情');
  const id = f.events.find(([event]) => event === 'task-sheet')[1];
  assert.equal(page.showDetailSheet_, false);
  await until(() => eventNames(f).includes('native-start'), '确认后应开始一次正文下载');
  assert.equal(eventNames(f).filter((event) => event === 'enqueue').length, 1);
  assert.equal(eventNames(f).filter((event) => event === 'native-start').length, 1);
  assert.equal(f.files.get(uri).bytes.length, 0);
  f.nativeResult.resolve();
  await until(() => eventNames(f).includes('native-release-wait'), '必须等 Native owner 收口');
  assert.equal(f.files.get(uri).bytes.length, 0, '后台正文成功前不能触碰目标字节');
  assert.equal(f.folders.size, 1);
  f.nativeRelease.resolve();
  await f.completion;
  const { view } = f.registry.getAdapter(id);
  assert.equal(view.state, 'done');
  assert.equal(view.category, category, '保存任务必须保留光影、资源包或模组的分类');
  assert.equal(view.activityCategory, 'resource_manage', '保存记录不能记成实例安装');
  assert.equal(view.filesDone, 1);
  assert.equal(view.currentLabel, '文件已保存并核对');
  assert.deepEqual(f.files.get(uri).bytes, payload);
  assert(eventNames(f).indexOf('native-released') < eventNames(f).indexOf('target-write'));
  assert.equal(f.folders.size, 0);
  assert.equal(f.opened.size, 0);
  assert.equal(f.activeFileTasks, 0);
}

{
  const f = fixture({ initial: oldContents });
  const pending = f.start();
  f.pickerResult.resolve([uri]);
  const id = await pending;
  await f.completion.catch(() => {});
  assert.equal(f.registry.getAdapter(id).view.state, 'error');
  assert(!eventNames(f).includes('native-start'));
  assert.deepEqual(f.files.get(uri).bytes, oldContents);
  assert.equal(f.opened.size, 0);
}

{
  const f = fixture();
  const pending = f.start();
  f.pickerResult.resolve([uri]);
  const id = await pending;
  await until(() => eventNames(f).includes('native-start'), '目标变更应发生在预检以后');
  f.put(uri, oldContents);
  f.nativeResult.resolve();
  f.nativeRelease.resolve();
  await f.completion.catch(() => {});
  assert.equal(f.registry.getAdapter(id).view.state, 'error');
  assert.deepEqual(f.files.get(uri).bytes, oldContents, '下载期间产生的同名用户文件必须保留');
  assert.equal(f.folders.size, 0);
  assert.equal(f.opened.size, 0);
}

{
  const f = fixture({ downloadError: true });
  const pending = f.start();
  f.pickerResult.resolve([uri]);
  const id = await pending;
  f.nativeResult.resolve();
  f.nativeRelease.resolve();
  await f.completion.catch(() => {});
  assert.equal(f.registry.getAdapter(id).view.state, 'error');
  assert(!eventNames(f).includes('target-write'));
  assert.equal(f.folders.size, 0);
  assert.equal(f.opened.size, 0);
}

{
  const f = fixture({ failWrite: true });
  const pending = f.start();
  f.pickerResult.resolve([uri]);
  const id = await pending;
  f.nativeResult.resolve();
  f.nativeRelease.resolve();
  await f.completion.catch(() => {});
  assert.equal(f.registry.getAdapter(id).view.state, 'error');
  assert(eventNames(f).includes('target-write'), '写入故障必须在真实短写后触发');
  assert.equal(f.folders.size, 0);
  assert.equal(f.opened.size, 0);
}

console.log('PASS: mod/shader/resource pack save flows and categories; picker timing, cancelled/stale selections, verified bytes, and cleanup');
