/**
 * DownloadManager 真实生产模块的会话回归。仅替换 Native/平台边界及定时调度，
 * 不复制 Manager 的状态机。可控时钟主动触发 query/回滚窗口，不靠真实 sleep 猜竞态。
 * 本 fixture 不证明 NAPI TSFN/设备行为；Native 桥需另由真实 NAPI 编译与设备门禁证明。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { pathToFileURL } from 'node:url';
import { root, ts } from '../../scripts/mod-install-test-runtime.mjs';
import { makePureEtsLoader } from '../../scripts/lib/load-pure-ets.mjs';

/** 每个用例独立 JS 模块/env、Manager 单例和定时器，不把前一个用例的 Promise 复活。 */
export function harness() {
  let now = 0, sequence = 0;
  const timers = new Map();
  const schedule = (fn, delay = 0) => { const id = ++sequence; timers.set(id, { fn, at: now + delay }); return id; };
  const clock = {
    async advance(ms) {
      const until = now + ms;
      for (let guard = 0; guard < 1000; guard++) {
        await Promise.resolve();
        const next = [...timers].filter(([, timer]) => timer.at <= until).sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) { now = until; await Promise.resolve(); return; }
        const [id, timer] = next; timers.delete(id); now = timer.at; timer.fn();
      }
      throw new Error('manager fixture exceeded bounded timer budget');
    },
  };
  const filename = path.join(root, 'feature_core/src/main/ets/download/DownloadManager.ets');
  const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true,
  });
  const errors = (output.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error);
  assert.equal(errors.length, 0, errors.map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')).join('\n'));
  const log = { info() {}, warn() {}, error() {}, flush() {} };
  const mod = { exports: {} };
  const processActivities = makePureEtsLoader()('feature_core/src/main/ets/download/ProcessActivityCoordinator.ets');
  vm.runInNewContext(output.outputText, {
    module: mod, exports: mod.exports, setTimeout: schedule, clearTimeout: id => timers.delete(id),
    require(name) {
      if (name === 'commons') return { AppLogger: log, formatError: e => e?.message ?? String(e) };
      if (name === '@kit.CoreFileKit') return { fileIo: {} };
      if (name === '@kit.AbilityKit') return {};
      // 此 fixture 不进入 shareFiles；共享协调器有单独的生产模块回归。
      if (name === './SharedDownloadCoordinator') return {};
      if (name === './ProcessActivityCoordinator') return processActivities;
      throw new Error('unexpected Manager fixture import ' + name);
    },
  }, { filename });
  const api = mod.exports;
  const records = new Map(), progress = new Map(), complete = new Map(), unbound = [], order = [];
  let nextId = 1;
  const engine = {
    records, progress, complete, unbound, order, failProgress: false, failComplete: false,
    failStart: false, queryFailures: 0, blockedPurges: 0, onStart: null, finishSettled: true,
    createTask(spec) {
      const taskId = nextId++;
      records.set(taskId, { taskId, executionEpoch: 0, name: spec.name, state: 'Waiting', progress: 0,
        filesDone: 0, filesTotal: spec.files.length, bytesDone: 0, bytesTotal: 4, terminal: false, executionSettled: false });
      order.push('create:' + taskId); return taskId;
    },
    bindActivity(id) { order.push('bind:' + id); },
    unbindActivity(id) { unbound.push(id); },
    onProgress(id, cb) { progress.set(id, cb); return !engine.failProgress; },
    onComplete(id, cb) { complete.set(id, cb); return !engine.failComplete; },
    queryTask(id) {
      if (engine.queryFailures > 0) { engine.queryFailures--; throw new Error('temporary query failure'); }
      return records.get(id) ?? null;
    },
    listActive() { return [...records.values()]; },
    start(id) {
      order.push('start:' + id);
      const record = records.get(id);
      if (engine.failStart || !record || record.state !== 'Waiting') return false;
      record.executionEpoch++; record.state = 'Loading'; record.executionSettled = false;
      engine.onStart?.(id); return true;
    },
    cancel(id) {
      const record = records.get(id); if (!record) return false;
      engine.finish(id, 'Aborted', undefined, record.executionEpoch > 0); return true;
    },
    purgeTask(id) {
      if (engine.blockedPurges > 0) { engine.blockedPurges--; return false; }
      const record = records.get(id);
      if (!record || !record.terminal || !record.executionSettled) return false;
      records.delete(id); return true;
    },
    resume(id) {
      const record = records.get(id); if (!record?.terminal) return false;
      record.state = 'Waiting'; record.terminal = false; delete record.error;
      return engine.start(id);
    },
    retryFailed(id) { return engine.resume(id); },
    finish(id, state = 'Finished', error, emit = true) {
      const record = records.get(id); assert.ok(record);
      Object.assign(record, { state, terminal: true, executionSettled: engine.finishSettled, filesDone: record.filesTotal,
        progress: state === 'Finished' ? 1 : 0.5, bytesDone: state === 'Finished' ? 4 : 2 });
      if (error) record.error = error;
      const event = { taskId: id, executionEpoch: record.executionEpoch, success: state === 'Finished',
        aborted: state === 'Aborted', durationMs: 3, error, failedFiles: [], finalProgress: {
          overallProgress: record.progress, speedBps: 0, currentFile: '', filesDone: record.filesDone,
          filesTotal: record.filesTotal, bytesDone: record.bytesDone, bytesTotal: record.bytesTotal,
          etaSeconds: 0, currentFiles: [],
        } };
      if (emit) complete.get(id)?.(event);
      return event;
    },
  };
  api.setDownloadNativeEngine(engine);
  const manager = api.DownloadManager.instance(); manager.caBundleInitialized_ = true;
  const spec = name => ({ name, activityId: 9, files: [{ localPath: '/trusted/' + name,
    allowedRoot: '/trusted', urls: ['https://example.invalid/' + name], check: { size: 4 } }] });
  return { api, manager, engine, clock, spec, activities: processActivities.ProcessActivityCoordinator.instance() };
}

export async function runDownloadManagerSessionRegression() {
  const cases = [];
  {
    const { manager, engine, spec } = harness();
    let id = 0, settlements = 0;
    engine.onStart = taskId => engine.finish(taskId);
    const waiting = manager.createAndWait(spec('sync'), view => {
      if (!id) { id = view.taskId; engine.order.push('owner:' + id); }
    }).then(view => { settlements++; return view; });
    assert.equal((await waiting).success, true); assert.equal(settlements, 1);
    assert.ok(engine.order.indexOf('owner:' + id) < engine.order.indexOf('start:' + id));
    engine.finish(id); assert.equal(settlements, 1); assert.deepEqual(engine.unbound, [id]);
    cases.push('registered owner receives taskId before start; synchronous/duplicate terminal settles once');
  }
  {
    const { manager, engine, spec } = harness();
    const waiting = manager.createAndWait(spec('early-cancel'), view => manager.cancel(view.taskId));
    await assert.rejects(waiting, /已取消/);
    assert.equal(engine.order.some(step => step.startsWith('start:')), false);
    assert.deepEqual(engine.unbound, [1]);
    cases.push('cancel from pre-start owner frame consumes epoch 0 terminal without issuing HTTP');
  }
  {
    const { api, manager, engine, clock, spec } = harness();
    let settled = 0;
    const waiting = manager.createAndWait(spec('rebind')).then(view => { settled++; return view; });
    const oldCallback = engine.complete.get(1);
    api.setDownloadNativeEngine(null); api.setDownloadNativeEngine(engine);
    await clock.advance(0);
    const terminal = engine.finish(1, 'Finished', undefined, false);
    oldCallback(terminal); assert.equal(settled, 0, 'detached callback generation must be ignored');
    manager.refreshFromNative(); assert.equal((await waiting).success, true);
    manager.refreshFromNative(); assert.equal(settled, 1); assert.deepEqual(engine.unbound, [1]);
    cases.push('same env detach/rebind preserves original Promise; list terminal uses same effects and rejects stale callback');
  }
  {
    const { manager, engine, clock, spec } = harness();
    const waiting = manager.createAndWait(spec('query'));
    const error = { kind: 'ProtocolError', message: 'limited', nativeCode: 0, httpStatus: 429,
      url: 'https://example.invalid/query', triedUrls: ['https://example.invalid/query'], needsNewLease: false,
      requestStarted: true, successfulHeadersSeen: false, bytesWritten: 7, httpAttempts: 1, retryAfterMs: 120000 };
    const rejection = assert.rejects(waiting, failure => {
      assert.deepEqual(failure.detail, error); return true;
    });
    engine.finish(1, 'Failed', error, false); engine.queryFailures = 1;
    await clock.advance(1000); await rejection;
    assert.deepEqual(engine.unbound, [1]);
    cases.push('temporary query failure retries and missing complete retains typed error/Retry-After facts');
  }
  {
    const { manager, engine, spec } = harness();
    const waiting = manager.createAndWait(spec('missing'));
    const rejection = assert.rejects(waiting, /TaskMissing/);
    engine.records.delete(1); manager.refreshFromNative(); await rejection;
    assert.deepEqual(engine.unbound, [1]);
    cases.push('missing Native owner explicitly rejects pending Promise before stale view removal');
  }
  {
    const { manager, engine, spec } = harness();
    const waiting = manager.createAndWait(spec('purge'));
    engine.finish(1, 'Finished', undefined, false);
    assert.equal(manager.purgeTask(1), true); assert.equal((await waiting).success, true);
    assert.deepEqual(engine.unbound, [1]);
    cases.push('manual purge before TSFN consumes query terminal and settles pending Promise');
  }
  {
    const { manager, engine, spec } = harness();
    const waiting = manager.createAndWait(spec('purge-between-query-and-release'));
    const query = engine.queryTask.bind(engine), purge = engine.purgeTask.bind(engine);
    let first = true, purges = 0;
    engine.queryTask = id => {
      const snapshot = { ...query(id) };
      // 源端在本次query取得Loading快照后、可能的下一次purge之前完成，且complete
      // 尚未送达。被测Manager必须保留等待者，不能用原子释放代替内容终态证据。
      if (first) { first = false; engine.finish(id, 'Finished', undefined, false); }
      return snapshot;
    };
    engine.purgeTask = id => { purges++; return purge(id); };
    assert.equal(manager.purgeTask(1), false); assert.equal(purges, 0);
    assert.ok(manager.getTask(1)); assert.equal(manager.purgeTask(1), true);
    assert.equal((await waiting).success, true); assert.deepEqual(engine.unbound, [1]);
    cases.push('purge refuses active query snapshot even if Native completes before following call');
  }
  for (const failure of ['failProgress', 'failComplete', 'failStart']) {
    const { manager, engine, spec } = harness(); engine[failure] = true;
    await assert.rejects(manager.createAndWait(spec(failure)), /download create\/register\/start failed/);
    assert.equal(engine.records.size, 0); assert.equal(manager.sessions_.size, 0);
    assert.deepEqual(engine.unbound, [1]);
    cases.push(failure + ' rolls back actual record and removes waiter/activity association');
  }
  for (const terminal of [false, true]) {
    const { manager, engine, clock, spec } = harness();
    const first = manager.createAndWait(spec('refresh-origin'));
    let second;
    manager.addListener(view => {
      if (view.name === 'refresh-origin' && !second) {
        second = manager.createAndWait(spec('created-during-refresh')).catch(error => error);
      }
    });
    if (terminal) engine.finish(1, 'Finished', undefined, false);
    manager.refreshFromNative();
    assert(second); assert.ok(manager.getTask(2)); assert.equal(manager.getTask(2).finished, false);
    if (!terminal) engine.finish(1, 'Finished', undefined, false);
    engine.finish(2, 'Finished', undefined, false);
    await clock.advance(500);
    assert.equal((await first).success, true); assert.equal((await second).success, true);
    cases.push((terminal ? 'terminal' : 'progress') + ' refresh listener can create a real new task without stale snapshot removing its waiter');
  }
  {
    const { manager, engine, clock, spec } = harness();
    engine.failStart = true; engine.blockedPurges = 2;
    let settled = false;
    const waiting = manager.createAndWait(spec('rollback-wait')).catch(error => { settled = true; return error; });
    await Promise.resolve(); assert.equal(settled, false);
    await clock.advance(500); await waiting; assert.equal(engine.records.size, 0);
    cases.push('setup failure waits for bounded real purge barrier before rejecting');
  }
  {
    const { manager, engine, clock, spec } = harness();
    engine.failProgress = true; engine.blockedPurges = 1000; engine.queryFailures = 1000;
    let settled = false;
    const pending = manager.createAndWait(spec('invisible-setup-owner')).catch(error => { settled = true; throw error; });
    const rejection = assert.rejects(pending, /download create\/register\/start failed/);
    await clock.advance(31000); assert.equal(settled, false); assert.equal(engine.records.size, 1);
    engine.blockedPurges = 0; engine.queryFailures = 0;
    await clock.advance(250); await rejection; assert.equal(engine.records.size, 0);
    cases.push('registration failure before owner ID publication keeps caller pending beyond old rollback timeout');
  }
  {
    const { manager, engine, spec } = harness();
    const waiting = manager.createAndWait(spec('resume'));
    const rejected = assert.rejects(waiting, /first attempt/);
    engine.finish(1, 'Failed', { kind: 'Timeout', message: 'first attempt', httpStatus: 0,
      nativeCode: 28, url: '', triedUrls: [] }, false);
    assert.equal(manager.resume(1), true); await rejected;
    const old = { taskId: 1, executionEpoch: 1, overallProgress: 0.7 };
    engine.progress.get(1)(old); assert.equal(manager.getTask(1).executionEpoch, 2);
    engine.finish(1); assert.equal(manager.getTask(1).success, true); assert.deepEqual(engine.unbound, [1, 1]);
    cases.push('resume settles preceding epoch before restart; stale progress cannot affect new execution');
  }
  {
    const { manager, engine, clock, spec } = harness();
    const waiting = manager.createAndWait(spec('superseded'));
    const rejection = assert.rejects(waiting, /切换/);
    // 模拟绕过 facade 的新轮次，原 Promise 必须明确中断，不能借下一轮成功来冒充完成。
    const record = engine.records.get(1); record.executionEpoch = 2;
    manager.refreshFromNative(); await rejection;
    engine.finish(1, 'Finished', undefined, false);
    const current = manager.getTask(1);
    await clock.advance(500);
    assert.equal(current.success, true); assert.equal(current.executionEpoch, 2);
    assert.equal(engine.unbound.filter(id => id === 1).length, 1);
    cases.push('unexpected epoch rejects old waiter and keeps one query chain for lost complete of new execution');
  }
  {
    const { manager, engine, clock, spec } = harness();
    const waiting = manager.createAndWait(spec('authorized'));
    const error = { kind: 'AuthorizationRenewalRequired', message: 'renew lease', httpStatus: 0,
      nativeCode: 0, url: '', triedUrls: [], needsNewLease: true, requestStarted: true,
      successfulHeadersSeen: true, bytesWritten: 2, httpAttempts: 1, retryAfterMs: 0 };
    engine.blockedPurges = 2;
    let settled = false;
    const rejection = assert.rejects(waiting, failure => {
      settled = true; assert.deepEqual(failure.detail, error); return true;
    });
    engine.finish(1, 'Failed', error); await Promise.resolve(); assert.equal(settled, false);
    await clock.advance(200); await rejection; assert.equal(engine.records.size, 0);
    cases.push('typed authorization renewal rejects only after original Native owner has actually purged');
  }
  {
    const { manager, engine, clock, spec } = harness();
    let settled = false;
    const pending = manager.createAndWait(spec('slow-authorized-release')).catch(error => { settled = true; throw error; });
    const error = { kind: 'AuthorizationRenewalRequired', message: 'renew', httpStatus: 0, nativeCode: 0,
      url: '', triedUrls: [], needsNewLease: true, httpAttempts: 1, bytesWritten: 2 };
    const rejection = assert.rejects(pending, failure => { assert.deepEqual(failure.detail, error); return true; });
    engine.blockedPurges = 1000; engine.finish(1, 'Failed', error);
    await clock.advance(6000); assert.equal(settled, false); assert.equal(engine.records.size, 1);
    engine.blockedPurges = 0; await clock.advance(100); await rejection;
    cases.push('slow authorized release preserves typed renewal facts until the original owner truly ends');
  }
  for (const retainOwner of [false, true]) {
    const { manager, engine, clock, spec } = harness();
    const waiting = manager.createAndWait(spec('owner-release-' + retainOwner));
    engine.finish(1); await waiting; engine.blockedPurges = 1000;
    let released = false;
    const release = manager.awaitTaskReleased(1, retainOwner).then(() => { released = true; });
    if (!retainOwner) {
      const rejection = assert.rejects(release, /TaskReleaseTimeout/);
      await clock.advance(30000); await rejection;
      assert.ok(manager.getTask(1)); assert.equal(engine.records.size, 1);
    } else {
      await clock.advance(31000); assert.equal(released, false); assert.ok(manager.getTask(1));
      engine.blockedPurges = 0; await clock.advance(250); await release;
      assert.equal(engine.records.size, 0);
    }
    cases.push('shared release barrier ' + (retainOwner ? 'retains outer owner after warning until actual purge' : 'rejects at bound without deleting identity'));
  }
  {
    const { api } = harness();
    const original = { localPath: '/trusted//a.jar/', allowedRoot: '/trusted/', urls: ['u', 'u'],
      check: { sha1: 'A'.repeat(40), size: 4 } };
    const compiled = api.compileDownloadFiles([original, { ...original, localPath: '/trusted/a.jar',
      allowedRoot: '/trusted', urls: ['v', 'u'], check: { sha1: 'a'.repeat(40), size: 4 } }]);
    assert.equal(compiled.length, 1); assert.deepEqual(Array.from(compiled[0].urls), ['u', 'v']);
    compiled[0].check.size = 8; assert.equal(original.check.size, 4);
    assert.throws(() => api.compileDownloadFiles([original, { ...original, check: { size: 4 } }]), /冲突/);
    assert.equal(api.compileDownloadFiles([]).length, 0, 'empty planning results stay valid; Native decides executable task contract');
    const noDigest = { ...original, check: { size: 4 }, urls: ['u'] };
    assert.throws(() => api.compileDownloadFiles([noDigest, { ...noDigest, urls: ['v'] }]), /来源身份冲突/);
    assert.equal(api.compileDownloadFiles([noDigest, { ...noDigest }]).length, 1);
    assert.throws(() => api.compileDownloadFiles([{ ...original, localPath: '/trusted/../a.jar' }]), /\. 或 \.\./);
    const authorized = { ...original, bearerToken: 'secret', authorizedPolicy: {
      singleUse: true, maxHttpAttempts: 1, validForNewRequestMs: 1000, maxBytes: 4 } };
    assert.throws(() => api.compileDownloadFiles([authorized, authorized]), /授权/);
    assert.equal(api.compileDownloadFiles([authorized])[0].urls.length, 2,
      'authorized candidate cardinality must remain subject to strict Native validation');
    cases.push('production compiler preserves optional facts, ordered candidates and strict authorized target isolation');
  }
  return cases;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const cases = await runDownloadManagerSessionRegression();
  console.log(JSON.stringify({ cases, count: cases.length }, null, 2));
}
