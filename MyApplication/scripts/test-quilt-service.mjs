/** Quilt安装回归：真实服务、Maven构造与DownloadManager事务，替换官方HTTP/Native事件边界。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { loader, root, fileIo } from './mod-install-test-runtime.mjs';
import { createHostTestScope } from './lib/host-test-lifecycle.mjs';
import { assertExternalOutputPath } from './lib/workspace-paths.mjs';

const argument = process.argv.indexOf('--output-dir');
if (argument < 0 || !process.argv[argument + 1]) throw new Error('需要显式 --output-dir 外置输出');
const output = assertExternalOutputPath(process.argv[argument + 1]); fs.mkdirSync(output, { recursive: true });
const scope = createHostTestScope('quilt-', { parent: output, automatic: false });
const fixture = scope.directory;
const official = JSON.parse(fs.readFileSync(path.join(root, 'scripts/fixtures/mod-install/quilt-1.20.1-0.29.2.profile.json'), 'utf8'));
const log = { info() {}, warn() {}, error() {}, debug() {}, flush() {} };
const cases = [], pass = name => { cases.push(name); console.log('PASS: ' + name); };
const hash = body => crypto.createHash('sha1').update(body).digest('hex');
let count = 0;

/** 虚拟OHOS绝对路径映射到本轮独占E盘夹具；Native边界收到的路径仍经生产准入检查。 */
function harness(options = {}) {
  const physical = path.join(fixture, String(++count)); fs.mkdirSync(physical);
  const mapped = value => typeof value === 'string' && value.startsWith('/mc') ? path.join(physical, value.slice(1)) : value;
  const io = { ...fileIo,
    openSync: (p, flags) => fileIo.openSync(mapped(p), flags),
    readSync(fd, buffer, opt) { return fs.readSync(fd, new Uint8Array(buffer), 0, opt?.length ?? buffer.byteLength, opt?.offset ?? null); },
    mkdirSync: (p, recursive = false) => fs.mkdirSync(mapped(p), { recursive }),
    lstatSync: p => fs.lstatSync(mapped(p)), statSync: p => fs.statSync(mapped(p)),
    readTextSync: p => fs.readFileSync(mapped(p), 'utf8'), listFileSync: p => fs.readdirSync(mapped(p)),
    renameSync: (a, b) => fs.renameSync(mapped(a), mapped(b)),
    unlinkSync: p => fs.unlinkSync(mapped(p)), rmdirSync: p => fs.rmdirSync(mapped(p)),
  };
  const bindings = { '@kit.CoreFileKit': { fileIo: io }, '@kit.NetworkKit': { http: {} },
    commons: { AppLogger: log, LogTags: { MOD_MAVEN: 'MavenUtils' }, LOG_DOMAIN_MODLOADER: 0,
      BMCLAPI_BASE: 'https://bmclapi2.bangbang93.com', formatError: e => e.message,
      DiagnosticPolicy: { isDeveloperBuild: () => false }, CancelledError: class extends Error {},
      writeTextFile(p, text) { fs.writeFileSync(mapped(p), text); },
      fileExistsAndNonEmpty(p) { try { return fs.statSync(mapped(p)).size > 0; } catch { return false; } } },
    './ForgeService': { ForgeService: class {} }, './NeoForgeService': { NeoForgeService: class {} },
  };
  const load = loader(bindings);
  const DM = load('feature_core/src/main/ets/download/DownloadManager.ets');
  const Maven = load('feature_core/src/main/ets/modloader/MavenUtils.ets');
  const profile = structuredClone(options.profile ?? official);
  const bytesByPath = new Map(profile.libraries.map(lib => [Maven.mavenToRelativePath(lib.name), Buffer.from('controlled fixture ' + lib.name)]));
  const requests = [], records = [], tasks = new Map();
  let cancellations = 0;
  const engine = {
    async fetchText(url) {
      requests.push(url);
      if (url.endsWith('/profile/json')) return { ok: true, body: JSON.stringify(profile) };
      if (url.endsWith('/versions/game')) return { ok: true, body: JSON.stringify([{ version: '1.20.1', stable: true }]) };
      if (url.endsWith('/loader/1.20.1')) return { ok: true, body: JSON.stringify([{ loader: { version: '0.29.2' } }]) };
      const entry = [...bytesByPath].find(([relative]) => url.endsWith(relative + '.sha1'));
      if (entry) return { ok: true, body: options.badChecksum ? 'not a checksum' : hash(entry[1]) };
      throw new Error('Unexpected metadata URL ' + url);
    },
    createTask(spec) { const id = records.length + 1; const task = { id, spec, state: 'Waiting', executionEpoch: 1 };
      records.push(task); tasks.set(id, task); return id; },
    onProgress(id, callback) { tasks.get(id).progress = callback; return true; },
    onComplete(id, callback) { tasks.get(id).complete = callback; return true; },
    start(id) {
      const task = tasks.get(id); task.state = 'Loading';
      queueMicrotask(() => {
        task.progress?.({ taskId: id, executionEpoch: 1, overallProgress: 0, filesDone: 0,
          filesTotal: task.spec.files.length, bytesDone: 0, bytesTotal: 100, currentFiles: [], currentFile: '' });
        const aborted = task.state === 'Aborted';
        if (!aborted) for (const spec of task.spec.files) {
          const relative = spec.localPath.split('/libraries/')[1], body = bytesByPath.get(relative);
          assert.equal(spec.check.sha1, hash(body), '生产事务必须保留官方侧摘要');
          fs.mkdirSync(path.dirname(mapped(spec.localPath)), { recursive: true });
          fs.writeFileSync(mapped(spec.localPath), options.corruptBody ? Buffer.from('CORRUPT') : body);
        }
        const success = !aborted && !options.downloadFailure;
        task.state = aborted ? 'Aborted' : success ? 'Finished' : 'Failed';
        const failedFiles = success || aborted ? [] : task.spec.files.map(file => ({ localPath: file.localPath,
          basename: path.basename(file.localPath), lastError: { kind: 'ProtocolError', message: 'fixture unavailable' } }));
        task.complete({ taskId: id, executionEpoch: 1, success, aborted, durationMs: 1, failedFiles,
          finalProgress: { overallProgress: 1, speedBps: 0, currentFile: '', currentFiles: [],
            filesDone: success ? task.spec.files.length : 0, filesTotal: task.spec.files.length,
            bytesDone: success ? 100 : 0, bytesTotal: 100, etaSeconds: 0 } });
      }); return true;
    },
    queryTask(id) { const task = tasks.get(id); return task ? { taskId: id, state: task.state, executionEpoch: 1,
      terminal: ['Finished', 'Failed', 'Aborted'].includes(task.state), executionSettled: task.state !== 'Loading' } : null; },
    cancel(id) { cancellations++; const task = tasks.get(id); if (task) task.state = 'Aborted'; return true; },
    purgeTask(id) { tasks.delete(id); return true; }, unbindActivity() { return true; },
  };
  DM.setDownloadNativeEngine(engine); const dm = new DM.DownloadManager(); dm.caBundleInitialized_ = true; DM.DownloadManager._instance = dm;
  const Quilt = load('feature_core/src/main/ets/modloader/QuiltService.ets');
  const service = new Quilt.QuiltService();
  const destination = '/mc/versions/' + official.id + '/' + official.id + '.json';
  return { service, Quilt, load, io, mapped, requests, records, tasks, destination, get cancellations() { return cancellations; } };
}

let failure;
try {
  {
    const h = harness(); const result = await h.service.install('1.20.1', '0.29.2', '/mc');
    assert.equal(result.success, true, result.error); assert.equal(result.versionId, official.id);
    const installed = JSON.parse(h.io.readTextSync(h.destination));
    assert.equal(installed.mainClass, official.mainClass); assert.equal(installed.inheritsFrom, '1.20.1');
    assert.equal(installed.libraries.length, 11); assert.ok(installed.libraries.every(lib => /^[a-f0-9]{40}$/.test(lib.sha1)));
    assert.equal(h.records.length, 1); assert.equal(h.records[0].spec.files.length, 11); assert.equal(h.tasks.size, 0);
    assert.equal((await h.service.getLoaderVersions('1.20.1'))[0].loader, 'quilt');
    assert.deepEqual(Array.from(await h.service.getSupportedGameVersions()), ['1.20.1']);
    const managerModule = h.load('feature_core/src/main/ets/modloader/ModLoaderManager.ets');
    const manager = new managerModule.ModLoaderManager();
    assert.equal(managerModule.isSupportedInstallerLoader('quilt'), true); assert.equal(managerModule.isSupportedInstallerLoader('optifine'), false);
    assert.ok(Array.from(manager.getSupportedLoaderTypes()).includes('quilt'));
    assert.equal(manager.detectModLoader(official.id, '/mc/versions').type, 'quilt');
    pass('official Quilt profile installs 11 verified Maven files through production Native transaction and publishes client JSON');
  }
  for (const [name, options] of [
    ['wrong profile identity', { profile: { ...official, inheritsFrom: '1.21.1' } }],
    ['server mainClass', { profile: { ...official, mainClass: 'org.quiltmc.loader.impl.launch.knot.KnotServer' } }],
    ['unsafe Maven path', { profile: { ...official, libraries: [...official.libraries, { name: '../escape:jar:1', url: 'https://example.invalid/' }] } }],
    ['bad checksum response', { badChecksum: true }],
    ['corrupt downloaded bytes despite success event', { corruptBody: true }],
    ['persistent dependency failure', { downloadFailure: true }],
  ]) {
    const h = harness(options); const result = await h.service.install('1.20.1', '0.29.2', '/mc');
    assert.equal(result.success, false, name); assert.equal(fs.existsSync(h.mapped(h.destination)), false, name);
  }
  pass('profile identity, server profile, unsafe coordinates, checksum and transfer faults cannot publish a Quilt version');
  {
    const h = harness(); const result = await h.service.install('../escape', '0.29.2', '/mc');
    assert.equal(result.success, false); assert.equal(h.requests.length, 0); assert.equal(h.records.length, 0);
    const cancelled = await h.service.install('1.20.1', '0.29.2', '/mc', progress => {
      if (progress.phase === 'generating_json') throw new Error('已取消');
    });
    assert.equal(cancelled.success, false); assert.equal(fs.existsSync(h.mapped(h.destination)), false); assert.equal(h.tasks.size, 0);
    pass('unsafe input fails before network and cancellation before commit leaves no published profile or Native owner');
  }
  {
    const h = harness(); let seenDownload = false;
    const result = await h.service.install('1.20.1', '0.29.2', '/mc', progress => {
      // 与真实ModloaderPhase一致：用户取消标志是持续状态，后续检查点仍必须抛错。
      if (progress.message.startsWith('下载 Quilt 依赖 (')) seenDownload = true;
      if (seenDownload) throw new Error('下载中已取消');
    });
    assert.equal(seenDownload, true); assert.equal(result.success, false);
    assert.equal(fs.existsSync(h.mapped(h.destination)), false); assert.equal(h.tasks.size, 0);
    pass('cancellation from production Maven progress blocks publication and leaves no Native owner');
  }
  {
    const h = harness(); fs.mkdirSync(path.dirname(h.mapped(h.destination)), { recursive: true }); fs.writeFileSync(h.mapped(h.destination), 'USER-KEEP');
    const result = await h.service.install('1.20.1', '0.29.2', '/mc');
    assert.equal(result.success, false); assert.equal(fs.readFileSync(h.mapped(h.destination), 'utf8'), 'USER-KEEP');
    pass('existing different Quilt profile is preserved');
  }
  {
    const h = harness(); fs.mkdirSync(h.mapped('/mc'), { recursive: true });
    const linked = path.join(fixture, 'link-target'); fs.mkdirSync(linked);
    fs.symlinkSync(linked, h.mapped('/mc/libraries'), process.platform === 'win32' ? 'junction' : 'dir');
    const result = await h.service.install('1.20.1', '0.29.2', '/mc');
    assert.equal(result.success, false); assert.equal(h.records.length, 0); assert.equal(fs.readdirSync(linked).length, 0);
    pass('linked library root is rejected before any file transfer');
  }
  {
    const h = harness();
    const Manager = h.load('feature_core/src/main/ets/modloader/ModLoaderManager.ets').ModLoaderManager;
    const manager = new Manager();
    const { ModloaderPhase } = h.load('feature_core/src/main/ets/download/phases/ModloaderPhase.ets');
    const state = { gameVersion: '1.20.1', loaderVersion: '0.29.2', loaderType: 'quilt',
      filesDir: '/mc/appfiles', tempVersionDir: '/mc/base', versionName: '用户实例',
      versionInfo: {}, cancelled: false, installSandboxDir: '' };
    const phases = [];
    await new ModloaderPhase(state, manager).run({}, progress => phases.push(progress.message));
    assert.ok(state.installSandboxDir.startsWith('/mc/appfiles/forge-install-sandbox/'));
    assert.ok(state.loaderJsonPath.startsWith(state.installSandboxDir + '/versions/quilt-loader-'));
    assert.equal(JSON.parse(h.io.readTextSync(state.loaderJsonPath)).mainClass, official.mainClass);
    assert.ok(phases[0].includes('Quilt')); assert.ok(phases.at(-1).includes('Quilt'));
    assert.equal(fs.existsSync(h.mapped(h.destination)), false, '加载器规范名目录不能落到真实mc根');
    assert.equal(h.tasks.size, 0);
    pass('production ModloaderPhase routes Quilt through an exclusive sandbox without vanilla jar copies or stray real versions');
  }
  fs.writeFileSync(path.join(output, 'quilt-result.json'), JSON.stringify({ cases, count: cases.length,
    officialFixtureSha256: crypto.createHash('sha256').update(fs.readFileSync(path.join(root, 'scripts/fixtures/mod-install/quilt-1.20.1-0.29.2.profile.json'))).digest('hex') }, null, 2));
} catch (error) { failure = error; throw error; }
finally { await scope.close({ success: !failure }); }
