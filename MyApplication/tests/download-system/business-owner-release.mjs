/**
 * 业务owner收尾回归。执行真实Resource/Modpack任务、Registry及更新Coordinator，
 * 仅替换Native释放、平台IO/来源入口与定时调度；公共awaitTaskReleased也读生产代码。
 * 完整Mod事务和JDK发布另由原有全链fixture补延迟门，本套件不复制其状态机。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { root, ts } from '../../scripts/mod-install-test-runtime.mjs';
import { fixture as sideloadFixture, settle } from '../../scripts/lib/sideload-coordinator-fixture.mjs';

const log = { info() {}, warn() {}, error() {}, debug() {}, flush() {} };
const microtasks = async () => { for (let turn = 0; turn < 20; turn++) await Promise.resolve(); };

/**
 * 转译完整生产模块，按原import的本地名显式接入端口，不删除import再依赖全局变量。
 * SDK转译器会给部分符号补回require；故VM必须提供真实模块形状，含fileIo as fs
 * 之类别名。这里只装配依赖，类/函数/判断与生产原件相同。
 * 与正常宿主loader相同只转译TS，SDK/HAP语法与真实Native另由后续门禁证明。
 */
function production(relative, bindings = {}, scheduling = {}) {
  const filename = path.join(root, relative), original = fs.readFileSync(filename, 'utf8');
  const source = ts.createSourceFile(filename, original, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const dependencies = new Map();
  for (const statement of source.statements) {
    if (!ts.isImportDeclaration(statement)) continue;
    const name = statement.moduleSpecifier.text, dependency = dependencies.get(name) ?? {};
    const clause = statement.importClause;
    if (clause?.name && Object.hasOwn(bindings, clause.name.text)) dependency.default = bindings[clause.name.text];
    const named = clause?.namedBindings;
    if (named && ts.isNamedImports(named)) for (const item of named.elements) {
      if (Object.hasOwn(bindings, item.name.text)) dependency[item.propertyName?.text ?? item.name.text] = bindings[item.name.text];
    }
    dependencies.set(name, dependency);
  }
  const output = ts.transpileModule(original, { fileName: filename,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true });
  assert.equal((output.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0, relative);
  const module = { exports: {} };
  const require = name => {
    if (dependencies.has(name)) return dependencies.get(name);
    throw new Error('Unexpected business-owner platform dependency ' + name + ' from ' + relative);
  };
  vm.runInNewContext(output.outputText, { module, exports: module.exports, require, console, setTimeout, clearTimeout,
    setInterval, clearInterval, Observed: value => value, ...bindings, ...scheduling }, { filename });
  return module.exports;
}

/** 虚拟时钟只推进已有timer；每次Native释放必须由用例显式改变，时间流逝不造成功。 */
function ownerPort() {
  let now = 0, sequence = 0, released = false, throws = 1, purges = 0;
  const timers = new Map();
  const scheduling = { setTimeout(fn, delay = 0) { const id = ++sequence; timers.set(id, { fn, at: now + delay }); return id; }, clearTimeout(id) { timers.delete(id); } };
  const api = production('feature_core/src/main/ets/download/DownloadManager.ets', { AppLogger: log }, scheduling);
  const manager = Object.create(api.DownloadManager.prototype);
  manager.purgeTask = () => { purges++; if (throws-- > 0) throw new Error('transient bridge failure'); return released; };
  const originalWait = manager.awaitTaskReleased.bind(manager);
  manager.awaitTaskReleased = async (id, retain) => { assert.equal(retain, true); return originalWait(id, retain); };
  return { api, manager, scheduling, get purges() { return purges; }, release() { released = true; },
    async advance(ms) {
      const until = now + ms;
      for (let budget = 0; budget < 4000; budget++) {
        await microtasks();
        const next = [...timers].filter(([, timer]) => timer.at <= until).sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) { now = until; await microtasks(); return; }
        const [id, timer] = next; timers.delete(id); now = timer.at; timer.fn();
      }
      throw new Error('owner fixture exceeded bounded timer budget');
    } };
}

function registryFor(port) {
  const unified = production('feature_core/src/main/ets/download/UnifiedDownloadTask.ets');
  const Registry = production('feature_core/src/main/ets/download/DownloadTaskRegistry.ets',
    { ...unified, ...production('feature_core/src/main/ets/download/ProcessActivityCoordinator.ets'),
      AppLogger: log, LOG_DOMAIN_DOWNLOAD: 0 }, port.scheduling).DownloadTaskRegistry;
  const registry = new Registry(); registry.maxConcurrent = 1;
  let leases = 0;
  registry.setFileLeaseProvider(() => { leases++; return 1; }, () => { leases--; });
  return { unified, registry, get leases() { return leases; } };
}

export async function runBusinessOwnerReleaseRegression() {
  const cases = [];
  for (const mode of ['success', 'error', 'cancel']) {
    const port = ownerPort(), context = registryFor(port), { unified, registry } = context;
    const manager = port.manager;
    class Installer {
      async installBatch(_request, progress) {
        progress({ taskId: 7, finished: true, progress: 1, bytesDone: 4, bytesTotal: 4,
          filesDone: 1, filesTotal: 1, currentFiles: [], speedBps: 0 });
        if (mode !== 'success') throw new Error(mode === 'cancel' ? '已取消' : 'download fixture failure');
        return { taskId: 7, finished: true, progress: 1, currentFiles: [] };
      }
    }
    const Task = production('mods/src/main/ets/ResourceInstallTask.ets', { ...unified,
      ModInstaller: Installer, DownloadManager: { instance: () => manager },
      DownloadTaskRegistry: { instance: () => registry }, AppLogger: log, LOG_DOMAIN_DOWNLOAD: 0,
      ResourceKind: { MOD: 'mod', SHADER: 'shader', RESOURCE_PACK: 'resource_pack', DATAPACK: 'datapack', MODPACK: 'modpack' },
      resourceKindToInstallDir: () => '/fixture/resources' }, port.scheduling).ResourceInstallTask;
    const task = new Task({ projectTitle: mode, request: { kind: 'shader', mcDir: '/fixture', versionId: 'v',
      versionIsolation: false, primary: { filename: 'a.zip', size: 4 }, dependencies: [] } });
    let settled = false;
    const pending = registry.enqueue(task).then(() => { settled = true; return null; }, error => { settled = true; return error; });
    try {
      await port.advance(31000);
      assert(port.purges > 120, '实际调用公共Manager等待并越过原30秒窗口');
      assert.equal(settled, false); assert.equal(context.leases, 1); assert(registry.runningIds_.includes(task.view.id));
      assert.equal(task.taskId_, 7, '桥异常/超时均不能丢原ID');
      port.release(); await port.advance(250); const result = await pending;
      assert.equal(context.leases, 0); assert.equal(registry.runningIds_.length, 0);
      assert.equal(task.taskId_, 0);
      if (mode === 'success') assert.equal(result, null); else assert.match(result.message, mode === 'cancel' ? /取消/ : /failure/);
    } finally { port.release(); await port.advance(1000); await pending; }
    cases.push('Resource ' + mode + ': real Registry/lease survives bridge error and 30s boundary');
  }

  // 真实prepare归档下载失败发生在execute预约之前；Task.catch仍必须持Registry到释放。
  {
    const port = ownerPort(), context = registryFor(port), { unified, registry } = context;
    port.manager.createAndWait = async (_spec, progress) => {
      progress({ taskId: 9, filesDone: 0, filesTotal: 1, bytesDone: 0, bytesTotal: 4, speedBps: 0, etaSeconds: -1 });
      throw new Error('archive transfer failed');
    };
    const installerBindings = { DownloadManager: { instance: () => port.manager }, ActivityLogger: class { warn() {} },
      LOG_DOMAIN_DOWNLOAD: 0, fs: { lstatSync() { throw new Error('ENOENT'); } }, ensureDirSync() {},
      modpackWorkDir: () => '/fixture/modpack', saveModpackSource() {}, newVersionInstallOwner: () => 'owner-fixture' };
    const Installer = production('mods/src/main/ets/ModpackInstaller.ets', installerBindings, port.scheduling).ModpackInstaller;
    const Task = production('mods/src/main/ets/ModpackInstallTask.ets', { ...unified, ModpackInstaller: Installer,
      AppLogger: log, LOG_DOMAIN_DOWNLOAD: 0, newVersionInstallOwner: () => 'owner-fixture',
      DownloadTaskRegistry: { instance: () => registry } }, port.scheduling).ModpackInstallTask;
    const task = new Task({ title: 'archive failure', mcDir: '/fixture/mc', filesDir: '/fixture', existingVersions: [],
      archiveUrl: 'https://fixture.invalid/archive.zip', requireConfirmation: false });
    let settled = false;
    const pending = registry.enqueue(task).then(() => { settled = true; return null; }, error => { settled = true; return error; });
    try {
      await port.advance(31000);
      assert.equal(settled, false); assert.equal(context.leases, 1); assert(registry.runningIds_.includes(task.view.id));
      assert.deepEqual(Array.from(task.installer_.dmIds_), [9]);
      port.release(); await port.advance(500); assert.match((await pending).message, /archive transfer failed/);
      assert.equal(context.leases, 0); assert.equal(task.installer_.dmIds_.length, 0);
    } finally { port.release(); await port.advance(1000); await pending; }
    cases.push('Modpack prepare failure retains real Task/Registry before execute exists');

    // 已解除activeBase_不代表baseTasks_已退出；桥异常也必须保留其引用。
    let baseReleased = false, baseCalls = 0, settledBase = false;
    const installer = new Installer();
    installer.baseTasks_.push({ purgeNativeOwner() { if (++baseCalls === 1) throw new Error('base bridge unavailable'); return baseReleased; } });
    const waiting = installer.settleNativeOwners().then(() => { settledBase = true; });
    await port.advance(31000); assert.equal(settledBase, false); assert.equal(installer.baseTasks_.length, 1);
    baseReleased = true; await port.advance(250); await waiting; assert.equal(installer.baseTasks_.length, 0);
    cases.push('Modpack retained base owner survives transient bridge exception and old timeout');
  }

  for (const mode of ['success', 'error', 'cancel', 'needs-new-lease']) {
    const f = await sideloadFixture(), port = ownerPort();
    const original = f.core.DownloadManager.instance(); let hashCalls = 0;
    const Files = f.load('entry/src/main/ets/sideload/SideloadFiles.ets').SideloadFiles, hash = Files.sha256;
    Files.sha256 = async (...args) => { hashCalls++; return hash(...args); };
    const manager = { ...original, purgeTask: port.manager.purgeTask,
      awaitTaskReleased: port.manager.awaitTaskReleased,
      async createAndWait(spec, progress) {
        await original.createAndWait(spec, progress);
        if (mode === 'cancel') { f.coordinator.cancel(); throw new Error('已取消'); }
        if (mode === 'error' || mode === 'needs-new-lease') {
          if (mode === 'needs-new-lease') throw new port.api.DownloadFailure('authorization requires renewal', {
            kind: 'Authorization', message: 'authorization requires renewal', nativeCode: 0,
            url: '', triedUrls: [], needsNewLease: true });
          throw new Error('ordinary source error');
        }
      } };
    f.core.DownloadManager = { instance: () => manager };
    const ui = f.render(); f.coordinator.setAbilityForeground(false);
    try {
      await settle(); await port.advance(31000);
      assert.equal(f.counters.download, 1); assert.equal(hashCalls, 0, '不得在Native释放前读取/校验原件');
      assert.equal(f.counters.sign, 0); assert.equal(f.coordinator.busy, true);
      assert.equal(f.core.DownloadTaskRegistry.instance().runningIds_.length, 1);
      assert.equal(f.coordinator.downloadTaskId, 1);
      port.release(); await port.advance(1000); await settle();
      assert.equal(f.coordinator.busy, false); assert.equal(f.coordinator.downloadTaskId, 0);
      assert.equal(f.core.DownloadTaskRegistry.instance().runningIds_.length, 0);
      if (mode === 'success') assert(hashCalls > 0); else assert.equal(hashCalls, 0);
    } finally { port.release(); await port.advance(1000); await settle(); ui.dispose(); }
    cases.push('Sideload ' + mode + ': actual Coordinator keeps Registry until per-source Native release');
  }
  return cases;
}
