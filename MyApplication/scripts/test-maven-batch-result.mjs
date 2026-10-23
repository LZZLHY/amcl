/**
 * Maven 批量结果宿主回放：实际加载 MavenUtils、MavenSpecBuilder、DownloadManager 与
 * SharedDownloadCoordinator，只替换 Native 传输事件边界。验证一项失败不会被 Promise
 * reject 扩成整批失败，以及取消、缺快照、未知路径和非法坐标不会被误报为成功。
 * 不访问公网、手机或游戏目录，不复制生产结果转换/选失败项算法。
 */
import assert from 'node:assert/strict';
import { loader } from './mod-install-test-runtime.mjs';

const cases = [];
const log = { info() {}, warn() {}, error() {}, debug() {}, flush() {} };
const libDir = '/trusted/maven-batch/libraries';
const forgeName = 'net.minecraftforge:forge:1.7.10-10.13.4.1614-1.7.10';

/** 构造真实合法坐标列表；首项失败夹具代表已经由安装器生产、但曾被错误重复请求的 Forge。 */
function libraries(count = 18) {
  return Array.from({ length: count }, (_, index) => ({
    name: index === 0 ? forgeName : `org.example:fixture-${index}:1.0`,
  }));
}

/**
 * Native 夹具仅发布可控进度/完成事件，实际注册、共享订阅、失败隔离和 Promise 行为
 * 均来自生产 DownloadManager。每组独占模块缓存、单例及 Native 注册表，不复用旧终态。
 * outcomes 是 successive Native task 的结果，避免第二轮重试继承首轮故障。
 */
function harness(outcomes = [{ success: true }], extra = {}) {
  const bindings = {
    commons: { AppLogger: log, LogTags: { MOD_MAVEN: 'MavenUtils' },
      LOG_DOMAIN_MODLOADER: 0, BMCLAPI_BASE: 'https://bmclapi2.bangbang93.com',
      formatError: error => error.message, DiagnosticPolicy: { isDeveloperBuild: () => false } },
    '@kit.NetworkKit': { http: {} },
    '@kit.CryptoArchitectureKit': { cryptoFramework: {} },
    ...extra,
  };
  const load = loader(bindings);
  const DM = load('feature_core/src/main/ets/download/DownloadManager.ets');
  const Maven = load('feature_core/src/main/ets/modloader/MavenUtils.ets');
  const Builder = load('feature_core/src/main/ets/modloader/MavenSpecBuilder.ets');
  // 复用同一模块实例执行仓内 Hypium 纯函数测试；不替换实际 Maven 构造和结果转换函数。
  bindings.feature_core = { ...Maven, ...Builder, ...DM };
  const records = [], tasks = new Map(), cancellations = [];
  const engine = {
    createTask(spec) {
      const id = records.length + 1;
      const outcome = outcomes[Math.min(records.length, outcomes.length - 1)];
      if (outcome.throwBeforeCreate) throw new Error('fixture native initialization failed');
      const task = { id, spec, outcome, state: 'Loading' };
      records.push(task); tasks.set(id, task); return id;
    },
    onProgress(id, callback) { tasks.get(id).progress = callback; return true; },
    onComplete(id, callback) { tasks.get(id).complete = callback; return true; },
    start(id) {
      const task = tasks.get(id);
      // 使用事件轮次模拟 NAPI 主线程完成回调；不能在注册事务未提交时提前伪造完成。
      queueMicrotask(() => {
        const failedIndex = task.outcome.failedIndex;
        const failedFiles = failedIndex === undefined ? [] : [{
          localPath: task.spec.files[failedIndex].localPath,
          basename: 'failed.jar', triedUrls: task.spec.files[failedIndex].urls,
          lastError: { kind: 'ProtocolError', message: 'fixture HTTP 404', httpStatus: 404, nativeCode: 22 },
        }];
        const aborted = task.outcome.aborted === true;
        const success = task.outcome.success === true;
        task.state = aborted ? 'Aborted' : success ? 'Finished' : 'Failed';
        const finalProgress = { overallProgress: 1, speedBps: 0, currentFile: '',
          // Native filesDone 统计所有已终结项，包含失败，复现手机18/18而17成功1失败。
          filesDone: task.spec.files.length, filesTotal: task.spec.files.length,
          bytesDone: 17, bytesTotal: 18, etaSeconds: 0, currentFiles: [] };
        const error = success ? undefined : { kind: 'ProtocolError', message: 'fixture HTTP 404',
          httpStatus: 404, nativeCode: 22, url: 'https://fixture.invalid/missing.jar', triedUrls: [] };
        task.complete({ taskId: id, executionEpoch: 1, success, aborted, durationMs: 5,
          failedFiles, error, finalProgress });
      });
      return true;
    },
    queryTask(id) { const task = tasks.get(id); return task ? { taskId: id, executionEpoch: 1, state: task.state } : null; },
    cancel(id) { cancellations.push(id); return true; },
    purgeTask(id) { tasks.delete(id); return true; },
    unbindActivity() { return true; },
  };
  DM.setDownloadNativeEngine(engine);
  const manager = new DM.DownloadManager();
  manager.caBundleInitialized_ = true;
  DM.DownloadManager._instance = manager;
  return { Maven, Builder, DM, manager, records, cancellations, load };
}

/** 断言批量输入条目数守恒；failedNames按坐标去重，失败计数仍覆盖每个重复输入。 */
function assertCounts(result, ok, failed, total) {
  assert.equal(result.ok, ok); assert.equal(result.failed, failed);
  assert.equal(result.ok + result.failed, total);
  assert.ok(result.failedNames.length <= result.failed);
}
function pass(name) { cases.push(name); console.log('PASS: ' + name); }

// 同时回放实际 createAndWait reject 与共享失败清单，然后执行实际 selectFailedLibs 再提交。
{
  const h = harness([{ failedIndex: 0 }, { success: true }]), libs = libraries();
  const result = await h.Maven.downloadMavenLibraries(libs, libDir);
  assertCounts(result, 17, 1, 18);
  assert.deepEqual(Array.from(result.failedNames), [forgeName]);
  assert.match(result.errors[0], /ProtocolError http=404/);
  const retry = h.Maven.selectFailedLibs(libs, result);
  assert.equal(retry.length, 1); assert.equal(retry[0].name, forgeName);
  assertCounts(await h.Maven.downloadMavenLibraries(retry, libDir), 1, 0, 1);
  assert.deepEqual(h.records.map(task => task.spec.files.length), [18, 1]);
  pass('真实Manager/shared reject保留17成功1失败，实际选择器仅重试1项');
}

{
  const h = harness([{ throwBeforeCreate: true }]), libs = libraries(2);
  assertCounts(await h.Maven.downloadMavenLibraries(libs, libDir), 0, 2, 2);
  // 相对根在共享准入前被拒，尚未产生任何终态回调；不能借其他用例的快照假报部分成功。
  assertCounts(await h.Maven.downloadMavenLibraries(libs, 'relative/libraries'), 0, 2, 2);
  assert.equal(h.records.length, 0);
  pass('初始化异常与没有终态快照全部保守失败');
}

{
  const h = harness([{ aborted: true, failedIndex: 0 }]), libs = libraries(2);
  assertCounts(await h.Maven.downloadMavenLibraries(libs, libDir), 0, 2, 2);
  // 纯转换器也不能把取消清单中缺席的输入当作成功。
  const view = new h.DM.DownloadTaskView(); view.aborted = true;
  const built = h.Builder.buildSpecsForLibs(libs, libDir);
  view.failedFiles = [{ localPath: built.specs[0].localPath }];
  assertCounts(h.Builder.parseDoneEventToBatchResult(view, libs, built.pathToName), 0, 2, 2);
  pass('Native取消与直接取消快照均不虚报部分成功');
}

{
  const h = harness(), libs = libraries(2), built = h.Builder.buildSpecsForLibs(libs, libDir);
  const view = new h.DM.DownloadTaskView(); view.finished = true; view.success = false;
  view.failedFiles = [{ localPath: '/unmapped/unknown.jar' }];
  assertCounts(h.Builder.parseDoneEventToBatchResult(view, libs, built.pathToName), 0, 2, 2);
  view.success = true;
  assertCounts(h.Builder.parseDoneEventToBatchResult(view, libs, built.pathToName), 0, 2, 2);
  view.success = false; view.failedFiles = [];
  assertCounts(h.Builder.parseDoneEventToBatchResult(view, libs, built.pathToName), 0, 2, 2);
  pass('未知失败路径和false却无可解释失败均fail closed');
}

{
  const libs = [...libraries(2), { name: 'invalid-coordinate' }];
  const success = harness([{ success: true }]);
  const good = await success.Maven.downloadMavenLibraries(libs, libDir);
  assertCounts(good, 2, 1, 3); assert.match(good.errors[0], /invalid maven coordinate/);
  const partial = harness([{ failedIndex: 0 }]);
  const bad = await partial.Maven.downloadMavenLibraries(libs, libDir);
  assertCounts(bad, 1, 2, 3);
  assert.deepEqual(Array.from(bad.failedNames), [forgeName, 'invalid-coordinate']);
  assert.equal(partial.Maven.selectFailedLibs(libs, bad).length, 2);
  pass('resolve/reject共同合并非法坐标，不使ok与failed超出输入');
}

{
  const h = harness(), libs = [{ name: 'bad' }, { name: 'bad' }];
  const result = await h.Maven.downloadMavenLibraries(libs, libDir);
  assertCounts(result, 0, 2, 2); assert.deepEqual(Array.from(result.failedNames), ['bad']);
  assert.equal(h.records.length, 0);
  assertCounts(await h.Maven.downloadMavenLibraries([], libDir), 0, 0, 0);
  pass('全部非法、重复非法与空输入不建Native任务且计数准确');
}

{
  // 宿主只替换 Hypium 的断言出口，原有 MavenSpecBuilder.test.ets 整个套件实际执行。
  // 这样同步维护的 unknown/invalid/abort 断言与既有 URL、存储路径、校验规格一起验证。
  let count = 0;
  const hypium = {
    describe(name, body) { body(); },
    it(name, flags, body) {
      try { body(); ++count; } catch (error) { error.message = name + ': ' + error.message; throw error; }
    },
    expect(value) { return {
      assertEqual(expected) { assert.equal(value, expected); },
      assertTrue() { assert.equal(value, true); },
      assertFalse() { assert.equal(value, false); },
    }; },
  };
  const h = harness([{ success: true }], { '@ohos/hypium': hypium });
  h.load('entry/src/test/MavenSpecBuilder.test.ets').default();
  assert.ok(count > 0);
  pass('原有MavenSpecBuilder Hypium生产纯函数套件：' + count + '项');
}

{
  const h = harness([{ failedIndex: 0 }]);
  const libs = [{ name: 'org.example:first:1', storagePath: 'shared/fixture.jar',
    directUrl: 'https://private.invalid/repository/fixture.jar?revision=1', sha1: 'a'.repeat(40), size: 4 },
  { name: 'org.example:alias:1', storagePath: 'shared/fixture.jar',
    directUrl: 'https://private.invalid/repository/fixture.jar?revision=1', sha1: 'a'.repeat(40), size: 4 }];
  const result = await h.Maven.downloadMavenLibraries(libs, libDir);
  assertCounts(result, 0, 2, 2); assert.equal(h.records[0].spec.files.length, 1);
  assert.deepEqual(new Set(result.failedNames), new Set(libs.map(lib => lib.name)));
  assert.deepEqual(Array.from(h.records[0].spec.files[0].urls), [libs[0].directUrl]);
  assert.equal(h.records[0].spec.files[0].localPath, libDir + '/shared/fixture.jar');
  pass('同内容别名只传一次，失败按所有原输入结算，未知仓库原直链/query不被改写');
}
{
  const h = harness();
  const libs = [{ name: 'org.example:first:1', storagePath: 'shared/conflict.jar', sha1: 'a'.repeat(40), size: 4 },
    { name: 'org.example:second:1', storagePath: 'shared/conflict.jar', sha1: 'b'.repeat(40), size: 4 }];
  assertCounts(await h.Maven.downloadMavenLibraries(libs, libDir), 0, 2, 2);
  assert.equal(h.records.length, 0);
  assert.equal(h.Builder.artifactSidecarUrl('https://repo.invalid/a.jar?revision=1', '.sha1'),
    'https://repo.invalid/a.jar.sha1?revision=1');
  const known = h.Builder.buildMavenArtifactUrls('https://maven.neoforged.net/releases/net/neoforged/fixture/1/fixture-1.jar', true);
  assert.equal(known[0], 'https://maven.neoforged.net/releases/net/neoforged/fixture/1/fixture-1.jar');
  assert(known.some(url => url.includes('/maven/net/neoforged/fixture/')));
  assert(!known.some(url => url.includes('/maven/releases/')));
  pass('目标内容冲突在去重前阻断，sidecar query和已知仓库最长前缀完整保留');
}

// 自动回收是生产的下一事件轮行为；等这一轮结束再退出，不留下后台定时查询或逻辑owner。
{
  const h = harness(), libs = libraries(2);
  const cancelled = await h.Maven.downloadMavenLibraries(libs, libDir, () => { throw new Error('已取消'); });
  assertCounts(cancelled, 0, 2, 2); assert.equal(h.records.length, 0, '首帧取消不能启动正文');
  assert(cancelled.errors.every(message => message.includes('已取消')));
  pass('Maven编排首帧抛取消会撤逻辑订阅，零Native正文且保持输入守恒');
}
{
  const h = harness(), libs = libraries(2);
  const first = h.Maven.downloadMavenLibraries(libs, libDir);
  const second = h.Maven.downloadMavenLibraries(libs, libDir, () => { throw new Error('已取消'); });
  const [good, cancelled] = await Promise.all([first, second]);
  assertCounts(good, 2, 0, 2); assertCounts(cancelled, 0, 2, 2);
  assert.equal(h.records.length, 1); assert.equal(h.cancellations.length, 0);
  pass('Maven取消仅撤本消费者，另一共享安装成功且不误cancel物理owner');
}
{
  let mutations = 0, requests = 0;
  const deniedIo = { OpenMode: { READ_ONLY: 0 }, openSync() { mutations++; throw new Error('unexpected file IO'); },
    unlinkSync() { mutations++; }, mkdirSync() { mutations++; }, statSync() { mutations++; throw new Error('unexpected stat'); } };
  const h = harness([{ success: true }], { '@kit.CoreFileKit': { fileIo: deniedIo },
    '@kit.NetworkKit': { http: { createHttp() { requests++; throw new Error('unexpected HTTP'); } } } });
  h.manager.caBundleInitialized_ = false;
  const single = await h.Maven.downloadMavenLibrary('org.example:fixture:1', undefined, libDir,
    'a'.repeat(40), 4, 'relocated/fixture.jar', 'https://private.invalid/fixture.jar?rev=1');
  assert.equal(single.success, false); assert.match(single.error, /CA bundle/);
  assertCounts(await h.Maven.downloadMavenLibraries(libraries(2), libDir), 0, 2, 2);
  assert.equal(h.records.length, 0); assert.equal(mutations, 0); assert.equal(requests, 0);
  pass('CA初始化失败明确归报且零HTTP/零目标IO，不启动旧TRUNC旁路');
}
{
  const zip = Buffer.alloc(22); zip.writeUInt32LE(0x06054b50); let h, writes = 0, reads = 0;
  const io = { OpenMode: { READ_ONLY: 0 }, openSync(_file, mode) {
    assert.equal(mode, 0); assert.equal(h.manager.getTask(1), null, '只读JAR核验必须发生在真实owner释放后');
    reads++; return { fd: 42 };
  }, closeSync() {}, statSync: () => ({ size: zip.length }),
  readSync(_fd, buffer, options) { const value = zip.subarray(options?.offset ?? 0, (options?.offset ?? 0) + (options?.length ?? buffer.byteLength));
    new Uint8Array(buffer).set(value); return value.length; },
  unlinkSync() { writes++; throw new Error('must not unlink'); }, mkdirSync() { writes++; throw new Error('must not mkdir'); } };
  h = harness([{ success: true }], { '@kit.CoreFileKit': { fileIo: io } });
  const result = await h.Maven.downloadMavenLibrary('org.example:fixture:1', undefined, libDir,
    'a'.repeat(40), 22, 'relocated/fixture.jar', 'https://private.invalid/fixture.jar?rev=1');
  assert.equal(result.success, true); assert.equal(writes, 0); assert(reads > 0);
  const spec = h.records[0].spec.files[0]; assert.equal(spec.localPath, libDir + '/relocated/fixture.jar');
  assert.equal(spec.check.size, 22); assert.equal(spec.check.sha1, 'a'.repeat(40));
  assert.deepEqual(Array.from(spec.urls), ['https://private.invalid/fixture.jar?rev=1']);
  pass('旧单库API仅委托Native并等待release，再执行原只读JAR门，不提前删除目标');
}
await new Promise(resolve => setTimeout(resolve, 10));
console.log('Maven batch result regression passed: ' + cases.length + ' groups');
