/**
 * 执行生产ExportNativeArchive适配器，Native仅以可控异步端口替换；不复制job算法或ZIP编码。
 * 专门证明completion/query/release乱序、取消与异常不会让ArkTS owner提前清理。
 * 核心字节和真正NAPI由独立Native测试及SDK产物验证，不用此替身冒充手机吞吐。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import compiler from './lib/ets-compiler.mjs';
import { PROJECT_ROOT } from './lib/workspace-paths.mjs';

/**
 * Native局部Get/Number/String helper的字段名不全会被全局文本门发现，所以另以真实
 * NativeExport声明的AST覆盖输入、句柄、结果和进度字段。只验证跨语言保留合同，
 * 不复制writer/hash/job逻辑；同一验证器移除保留项后必须能报缺，避免配置空真。
 */
test('all NativeExport protocol fields and six native entry names survive property obfuscation', () => {
  const declaration = fs.readFileSync(path.join(PROJECT_ROOT, 'entry/src/main/cpp/types/libentry/index.d.ts'), 'utf8');
  const source = compiler.createSourceFile('libentry.d.ts', declaration, compiler.ScriptTarget.Latest, true);
  const fields = new Set(); let interfaces = 0;
  for (const node of source.statements) if (compiler.isInterfaceDeclaration(node) && node.name.text.startsWith('NativeExport')) {
    interfaces++;
    for (const member of node.members) {
      assert(compiler.isPropertySignature(member) && compiler.isIdentifier(member.name));
      fields.add(member.name.text);
    }
  }
  assert(interfaces >= 6 && fields.has('completion') && fields.has('workerCount'));
  const methods = ['exportArchiveStart', 'exportArchiveVerifyStart', 'exportFileHashStart', 'exportJobQuery', 'exportJobCancel', 'exportJobRelease'];
  const required = new Set([...fields, ...methods, 'toLowerCase']);
  const rules = fs.readFileSync(path.join(PROJECT_ROOT, 'entry/obfuscation-rules.txt'), 'utf8');
  const missing = text => {
    const kept = new Set(); let properties = false;
    for (const raw of text.split(/\r?\n/)) {
      const value = raw.trim();
      if (value === '-keep-property-name') properties = true;
      else if (value.startsWith('-keep-')) properties = false;
      else if (properties && value && !value.startsWith('#') && !value.startsWith('-')) kept.add(value);
    }
    return [...required].filter(value => !kept.has(value));
  };
  assert.deepEqual(missing(rules), []);
  // 正反使用同一声明驱动验证：移除每个必需名字的全部保留行，逐项证明缺项可被识别。
  for (const name of required) {
    const withdrawn = rules.split(/\r?\n/).filter(line => line.trim() !== name).join('\n');
    assert(missing(withdrawn).includes(name), name);
  }
});

/** 只翻译真实源；require隔离模块边界，timer使用真实事件循环，避免把微任务当CPU并行。 */
function fixture(overrides = {}) {
  const state = { started: [], queries: 0, cancels: 0, releases: 0, warnings: [], releaseAllowed: true };
  let resolve, reject;
  const completion = new Promise((yes, no) => { resolve = yes; reject = no; });
  const result = operation => ({ jobId: 41, operation, files: 1, size: operation === 'hash' ? 3 : 200,
    payloadBytes: 3, archiveBytes: operation === 'hash' ? 0 : 200, sha1: 'a'.repeat(40), sha256: 'b'.repeat(64) });
  const start = operation => spec => { state.started.push({ operation, spec }); return { jobId: 41, completion }; };
  const native = {
    exportArchiveStart: start('write'), exportArchiveVerifyStart: start('verify'), exportFileHashStart: start('hash'),
    exportJobQuery() { state.queries++; return { exists: true, released: false, jobId: 41, operation: 'write',
      state: 'running', filesDone: 0, filesTotal: 1, bytesDone: 0, bytesTotal: 3, archiveBytes: 0, settled: false,
      errorCode: '', errorMessage: '' }; },
    exportJobCancel() { state.cancels++; return true; },
    exportJobRelease() { state.releases++; return state.releaseAllowed; }, ...overrides,
  };
  const source = fs.readFileSync(path.join(PROJECT_ROOT, 'entry/src/main/ets/export/ExportNativeArchive.ets'), 'utf8');
  const compiled = compiler.transpileModule(source, { compilerOptions: { module: compiler.ModuleKind.CommonJS,
    target: compiler.ScriptTarget.ES2020 } });
  const api = {};
  new Function('exports', 'require', compiled.outputText)(api, name => {
    if (name === 'libentry.so') return { default: native };
    if (name === 'commons') return { AppLogger: { warn: (...args) => state.warnings.push(args), info() {} } };
    if (name === 'feature_core') return {};
    throw Error('Unexpected dependency ' + name);
  });
  return { api, state, native, resolve, reject, result };
}
const context = { filesDir: '/app', workRelative: 'game-export/work/123-job' };
const files = [{ archivePath: 'a.txt', size: 3, sha256: 'b'.repeat(64), directory: false,
  source: 'gameDir', sourcePath: 'a.txt', sha1: '', content: '', required: false }];
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

/** 兼容fallback必须在发起任何job之前；部分Native桥不允许创建无取消/释放能力的任务。 */
test('missing or partial Native bridge leaves the original archive path untouched', async () => {
  for (const missing of ['exportArchiveStart', 'exportJobRelease', 'exportFileHashStart']) {
    const f = fixture({ [missing]: undefined });
    assert.equal(await f.api.tryNativeWriteArchive(context, files, () => false, () => {}), false);
    assert.equal(await f.api.tryNativeHashFile(3, 3, true, () => false), undefined);
    assert.equal(f.state.started.length, 0);
  }
});

test('archive job receives only frozen private fields and actual writer progress', async () => {
  const f = fixture(), progress = [];
  const pending = f.api.tryNativeWriteArchive(context, files, () => false, (...args) => progress.push(args));
  assert.deepEqual(f.state.started[0], { operation: 'write', spec: { filesDir: '/app', jobRelative: context.workRelative,
    snapshotRelative: 'snapshot', archiveRelative: 'export.zip', entries: [{ path: 'a.txt', size: 3, sha256: 'b'.repeat(64), directory: false }], workerCount: 2 } });
  f.resolve(f.result('write')); assert.equal(await pending, true);
  assert.deepEqual(progress.at(-1), [1, 3]); assert.equal(f.state.releases, 1); assert.equal(f.state.cancels, 0);
});

/** 可见complete早于release可用时，真实owner继续等待；不在测试里把release替换成恒true。 */
test('completion never releases the ArkTS owner before positive Native release', async () => {
  const f = fixture(); f.state.releaseAllowed = false;
  let returned = false;
  const pending = f.api.tryNativeWriteArchive(context, files, () => false, () => {}).then(value => { returned = true; return value; });
  f.resolve(f.result('write')); await pause(45);
  assert.equal(returned, false); assert(f.state.releases >= 2); assert.equal(f.state.cancels, 1);
  f.state.releaseAllowed = true; assert.equal(await pending, true); assert.equal(returned, true);
});

test('a rejected job still waits for release and preserves its original failure', async () => {
  const f = fixture(); f.state.releaseAllowed = false;
  let returned = false;
  const pending = f.api.tryNativeVerifyArchive(context, files, () => false).catch(error => { returned = true; return error; });
  f.reject(Error('corrupt independent CRC')); await pause(30); assert.equal(returned, false);
  f.state.releaseAllowed = true; assert.match((await pending).message, /corrupt independent CRC/);
});

test('user cancellation reaches this job once and still waits for real completion', async () => {
  const f = fixture(); let cancel = false, returned = false;
  const pending = f.api.tryNativeWriteArchive(context, files, () => cancel, () => {}).catch(error => { returned = true; return error; });
  cancel = true; await pause(145); assert.equal(f.state.cancels, 1); assert.equal(returned, false);
  f.resolve(f.result('write')); assert.match((await pending).message, /取消/); assert.equal(f.state.releases, 1);
});

test('query errors cancel but do not publish failure before the Native completion barrier', async () => {
  const f = fixture({ exportJobQuery() { throw Error('query boundary failure'); } });
  let returned = false;
  const pending = f.api.tryNativeWriteArchive(context, files, () => false, () => {}).catch(error => { returned = true; return error; });
  await pause(15); assert.equal(returned, false); assert.equal(f.state.cancels, 1); assert.equal(f.state.releases, 0);
  f.resolve(f.result('write')); assert.match((await pending).message, /query boundary failure/); assert.equal(f.state.releases, 1);
});

test('hash borrows only fd/actual size and honors SHA256-only purpose', async () => {
  const f = fixture(); const pending = f.api.tryNativeHashFile(7, 3, false, () => false);
  assert.deepEqual(f.state.started[0], { operation: 'hash', spec: { fd: 7, size: 3, sha1: false, sha256: true } });
  const result = f.result('hash'); result.sha1 = ''; f.resolve(result);
  assert.deepEqual(await pending, { size: 3, sha1: '', sha256: 'b'.repeat(64) });
});

/** 第五参数只改变摘要用途；旧四参双摘要、明确SHA1-only均必须等真实release后返回。 */
test('hash keeps legacy dual purpose and explicitly supports SHA1-only without SHA256', async () => {
  for (const needSha256 of [true, false]) {
    const f = fixture();
    const pending = needSha256 ? f.api.tryNativeHashFile(7, 3, true, () => false)
      : f.api.tryNativeHashFile(7, 3, true, () => false, false);
    assert.deepEqual(f.state.started[0].spec, { fd: 7, size: 3, sha1: true, sha256: needSha256 });
    const result = f.result('hash'); if (!needSha256) result.sha256 = '';
    f.resolve(result); assert.deepEqual(await pending, { size: 3, sha1: result.sha1, sha256: result.sha256 });
    assert.equal(f.state.releases, 1);
  }
});

/** 双false没有合法摘要事实，必须在创建job前拒绝；三种合法用途分别严格检查结果形状。 */
test('hash rejects no-algorithm requests and malformed or unrequested digest fields', async () => {
  const empty = fixture();
  await assert.rejects(empty.api.tryNativeHashFile(7, 3, false, () => false, false), /至少需要/);
  assert.equal(empty.state.started.length, 0);
  for (const [sha1, sha256, field, value] of [
    [true, false, 'sha1', ''], [true, false, 'sha256', 'b'.repeat(64)],
    [false, true, 'sha1', 'a'.repeat(40)], [false, true, 'sha256', ''],
    [true, true, 'sha1', 'not-sha1'], [true, true, 'sha256', 'not-sha256'],
  ]) {
    const f = fixture(); const pending = f.api.tryNativeHashFile(7, 3, sha1, () => false, sha256);
    const result = f.result('hash'); if (!sha1) result.sha1 = ''; if (!sha256) result.sha256 = '';
    result[field] = value; f.resolve(result);
    await assert.rejects(pending, /摘要结果无效/); assert.equal(f.state.releases, 1);
  }
});

test('mismatching native result cannot be published after successful release', async () => {
  const f = fixture(); const pending = f.api.tryNativeWriteArchive(context, files, () => false, () => {}).catch(error => error);
  const result = f.result('write'); result.payloadBytes = 4; f.resolve(result);
  assert.match((await pending).message, /计划不一致/); assert.equal(f.state.releases, 1);
});

/** deferred消费后SDK若未兑现Promise，进度故障信号必须终止等待，但仍守住真实释放屏障。 */
test('consumed deferred delivery failure ends a pending completion only after positive release', async () => {
  const f = fixture(); f.state.releaseAllowed = false;
  f.native.exportJobQuery = () => ({ exists: true, jobId: 41, settled: true,
    filesDone: 1, bytesDone: 3, errorCode: 'DeliveryFailed', errorMessage: 'SDK consumed deferred' });
  let returned = false;
  const pending = f.api.tryNativeHashFile(7, 3, true, () => false).catch(error => { returned = true; return error; });
  // 负控旧源码会永久等待completion；限时用独立错误撤下夹具，保证失败可观测且不挂住CI。
  const rescue = setTimeout(() => f.reject(Error('regression guard: completion stayed pending')), 500);
  try {
    await pause(35); assert.equal(returned, false); assert(f.state.releases >= 2);
    f.state.releaseAllowed = true;
    assert.match((await pending).message, /SDK consumed deferred/);
  } finally {
    clearTimeout(rescue);
    // 中途断言失败也撤下未完成的替身，不能让原生产timer把负控进程永久留住。
    if (!returned) {
      f.state.releaseAllowed = true;
      f.reject(Error('regression guard: withdraw incomplete fixture'));
      await pending;
    }
  }
});

/** resolve可先运行微任务再返回错误；最终退役前必须再次观察状态，不能发布字节成功。 */
test('SDK delivery error discovered after resolved completion prevents successful export', async () => {
  const f = fixture();
  const pending = f.api.tryNativeWriteArchive(context, files, () => false, () => {}).catch(error => error);
  f.native.exportJobQuery = () => ({ exists: true, jobId: 41, settled: true,
    filesDone: 1, bytesDone: 3, errorCode: 'DeliveryFailed', errorMessage: 'resolve consumed then failed' });
  f.resolve(f.result('write'));
  assert.match((await pending).message, /resolve consumed then failed/);
  assert.equal(f.state.releases, 1);
});

/** SDK的null/undefined兜底拒绝仍须等释放，并输出页面可安全读取message的Error。 */
test('non-Error SDK rejections are normalized after the positive release barrier', async () => {
  for (const rejection of [null, undefined, 'rejected text', 7]) {
    const f = fixture(); f.state.releaseAllowed = false;
    let returned = false;
    const pending = f.api.tryNativeVerifyArchive(context, files, () => false).catch(error => { returned = true; return error; });
    f.reject(rejection); await pause(25); assert.equal(returned, false);
    f.state.releaseAllowed = true;
    const error = await pending;
    assert(error instanceof Error); assert.match(error.message, /非Error异常/);
  }
});
