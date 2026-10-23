/**
 * 一次检查内的真实源摘要复用回归。生产SourceInspector与ArchiveIO完整运行，正文来自
 * 外置真实文件、SHA来自Node密码端口；只替换SDK FileIO形状/错误注入，不复制memo算法。
 * 每次fixture独立，inode/纳秒身份、打开标志、真实读量及句柄结算分别对账。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import { PROJECT_ROOT, resolveWorkspacePath } from './lib/workspace-paths.mjs';

const digest = (bytes, kind = 'sha1') => crypto.createHash(kind).update(bytes).digest('hex');
const active = () => false;

/** 每个来源真实落盘；SDK错误仅在指定端口发生，不在测试侧模拟检查结果。 */
function fixture({ native = false, purpose = 'all' } = {}) {
  const parent = resolveWorkspacePath('run', 'export-check-digest-tests'); fs.mkdirSync(parent, { recursive: true });
  const directory = fs.mkdtempSync(path.join(parent, 'amcl-check-digest-'));
  const modules = new Map(), handles = new Map();
  const state = { reads: new Map(), opens: [], lstats: [], algorithms: [], nativeAlgorithms: [], nativeSpecs: [], omitNs: false, statTransform: null,
    beforeLstat: null, beforeOpen: null, afterRead: null, afterClose: null, failOpen: 0, failStat: 0, failRead: 0, failClose: 0,
    // 独立job身份和可控release用于证明批次必须等待真实Native收据，不以Promise完成冒充drain。
    nextNativeId: 40, nativeJobs: new Map(), nativeReleased: [], nativeCancelled: [], nativeReleaseAllowed: true };
  const physical = virtual => {
    assert(virtual.startsWith('/'));
    const actual = path.resolve(directory, '.' + virtual);
    assert(actual === directory || actual.startsWith(directory + path.sep)); return actual;
  };
  function put(virtual, bytes) {
    const actual = physical(virtual); fs.mkdirSync(path.dirname(actual), { recursive: true }); fs.writeFileSync(actual, bytes);
  }
  function stat(value, nofollow = false) {
    const virtual = typeof value === 'number' ? handles.get(value) : value;
    const raw = typeof value === 'number' ? fs.fstatSync(value, { bigint: true })
      : nofollow ? fs.lstatSync(physical(value), { bigint: true }) : fs.statSync(physical(value), { bigint: true });
    const result = { ino: raw.ino, size: Number(raw.size), mtime: Number(raw.mtimeMs / 1000n), ctime: Number(raw.ctimeMs / 1000n),
      ...(state.omitNs ? {} : { mtimeNs: raw.mtimeNs, ctimeNs: raw.ctimeNs }),
      isFile: () => raw.isFile(), isDirectory: () => raw.isDirectory(), isSymbolicLink: () => raw.isSymbolicLink() };
    return state.statTransform ? state.statTransform(virtual, result, typeof value === 'number' ? 'fd' : nofollow ? 'lstat' : 'stat') : result;
  }
  const io = {
    OpenMode: { READ_ONLY: 0, NOFOLLOW: 131072 },
    async lstat(virtual) {
      state.lstats.push(virtual);
      if (state.beforeLstat) await state.beforeLstat(virtual);
      try { return stat(virtual, true); }
      catch (error) { if (error.code === 'ENOENT') error.code = 13900002; throw error; }
    },
    async stat(value) { if (state.failStat-- > 0) throw new Error('EIO stat boundary'); return stat(value); },
    async open(virtual, flags) {
      assert.equal(flags, io.OpenMode.READ_ONLY | io.OpenMode.NOFOLLOW, '每次摘要/命中都必须只读且NOFOLLOW');
      state.opens.push({ virtual, flags });
      if (state.beforeOpen) await state.beforeOpen(virtual);
      if (state.failOpen-- > 0) throw new Error('EACCES open boundary');
      if (fs.lstatSync(physical(virtual)).isSymbolicLink()) throw new Error('ELOOP NOFOLLOW boundary');
      const fd = fs.openSync(physical(virtual), 'r'); handles.set(fd, virtual); return { fd };
    },
    async read(fd, buffer, options = {}) {
      if (state.failRead-- > 0) throw new Error('EIO read boundary');
      const virtual = handles.get(fd), count = fs.readSync(fd, Buffer.from(buffer), 0, options.length ?? buffer.byteLength, null);
      state.reads.set(virtual, (state.reads.get(virtual) ?? 0) + count);
      if (state.afterRead) await state.afterRead(virtual, count); return count;
    },
    async close(file) {
      const fd = typeof file === 'number' ? file : file.fd, virtual = handles.get(fd);
      fs.closeSync(fd); handles.delete(fd);
      if (state.afterClose) await state.afterClose(virtual);
      // 注入的是真实close之后SDK报告失败，既证明失败不能缓存，也不制造测试句柄泄漏。
      if (state.failClose-- > 0) throw new Error('EIO close boundary');
    },
  };
  const cryptoFramework = { createMd(name) { state.algorithms.push(name); const hash = crypto.createHash(name.toLowerCase()); return {
    async update({ data }) { hash.update(data); }, async digest() { return { data: new Uint8Array(hash.digest()) }; },
  }; } };
  // 仅替换Native端口，真实ETS wrapper/ArchiveIO仍执行。借用同一fd按显式位置读，
  // SHA端口记录实际创建算法，能区分“结果留空”与“不曾计算未请求SHA256”。
  const nativeBridge = native ? {
    exportArchiveStart() { throw new Error('unexpected native archive write'); },
    exportArchiveVerifyStart() { throw new Error('unexpected native archive verify'); },
    exportFileHashStart(spec) {
      state.nativeSpecs.push({ ...spec });
      const bytes = Buffer.alloc(spec.size); let offset = 0;
      while (offset < bytes.length) {
        const count = fs.readSync(spec.fd, bytes, offset, bytes.length - offset, offset);
        if (count <= 0) throw new Error('native fixture truncated'); offset += count;
      }
      const virtual = handles.get(spec.fd); state.reads.set(virtual, (state.reads.get(virtual) ?? 0) + bytes.length);
      const hash = name => { state.nativeAlgorithms.push(name); return digest(bytes, name.toLowerCase()); };
      const jobId = ++state.nextNativeId; state.nativeJobs.set(jobId, { ...spec });
      return { jobId, completion: Promise.resolve({ jobId, operation: 'hash', files: 1, size: spec.size,
        sha1: spec.sha1 === false ? '' : hash('SHA1'), sha256: spec.sha256 === false ? '' : hash('SHA256') }) };
    },
    exportJobQuery(jobId) { return { exists: state.nativeJobs.has(jobId), released: state.nativeReleased.includes(jobId), jobId, filesDone: 1, bytesDone: 0,
      settled: true, errorCode: '', errorMessage: '' }; },
    exportJobCancel(jobId) { state.nativeCancelled.push(jobId); return state.nativeJobs.has(jobId); },
    exportJobRelease(jobId) {
      if (!state.nativeReleaseAllowed) return false;
      assert(state.nativeJobs.delete(jobId), '真实job只退役一次'); state.nativeReleased.push(jobId); return true;
    },
  } : {};
  function selected(relative, names) {
    const source = fs.readFileSync(path.join(PROJECT_ROOT, relative), 'utf8');
    const ast = compiler.createSourceFile(relative, source, compiler.ScriptTarget.Latest, true);
    return ast.statements.filter(node => names.includes(node.name?.text) || node.declarationList?.declarations.some(item => names.includes(item.name.text)))
      .map(node => node.getFullText(ast)).join('\n');
  }
  function load(relative, override) {
    if (modules.has(relative)) return modules.get(relative);
    const source = override ?? fs.readFileSync(path.join(PROJECT_ROOT, relative), 'utf8');
    const js = compiler.transpileModule(source, { compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 } }).outputText;
    const exports = {}; modules.set(relative, exports);
    const require = name => {
      if (name === '@kit.CoreFileKit') return { fileIo: io };
      if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework };
      if (name === '@kit.BasicServicesKit') return {};
      if (name === 'libentry.so') return { default: nativeBridge };
      if (name === 'commons') return { resolveInstanceGameDir() { throw new Error('unexpected instance resolver'); },
        stringToUtf8: value => new Uint8Array(Buffer.from(value)), AppLogger: { info() {}, warn() {} } };
      if (name === 'feature_core') return { ...load('feature_core/src/main/ets/export/ExportPath.ets'),
        ...load('feature_core/src/main/ets/export/ExportZipFormat.ets'),
        ...load('feature_core/src/main/ets/export/ExportContentSelection.ets'),
        ...load('selected-path-policy', selected('feature_core/src/main/ets/modloader/MavenUtils.ets',
          ['MAX_SAFE_SEGMENT_LENGTH', 'MAX_SAFE_RELATIVE_PATH_LENGTH', 'containsControlCharacter', 'safeBaseName', 'safeRelPath'])) };
      if (name.startsWith('.')) return load(path.relative(PROJECT_ROOT,
        path.resolve(PROJECT_ROOT, path.dirname(relative), name + '.ets')).replaceAll('\\', '/'));
      throw new Error('unexpected module: ' + name);
    };
    new Function('exports', 'require', js)(exports, require); return exports;
  }
  put('/mc/.fixture', 'root');
  const inspector = load('entry/src/main/ets/export/ExportSourceInspector.ets');
  const archive = load('entry/src/main/ets/export/ExportArchiveIO.ets');
  const context = new inspector.ExportCheckDigestContext(purpose);
  const dependency = (relative, bytes, overrides = {}) => ({ path: relative, url: 'https://fixture.invalid/' + relative,
    sha1: digest(bytes), size: Buffer.byteLength(bytes), kind: 'asset', generated: false, ...overrides });
  return { state, physical, put, inspector, archive, context, dependency,
    readBytes: virtual => state.reads.get(virtual) ?? 0,
    close() {
      assert.equal(handles.size, 0, '所有成功/失败/取消操作必须关闭自己的fd');
      assert.equal(state.nativeJobs.size, 0, 'Native任务必须全部取得真实release收据');
      const actual = fs.realpathSync(directory), base = fs.realpathSync(parent);
      assert.equal(path.dirname(actual), base); assert(path.basename(actual).startsWith('amcl-check-digest-'));
      fs.rmSync(actual, { recursive: true, force: true });
    } };
}

/** 大于一个chunk，真实读取量可以区分完整hash、前缀和完全命中的路径。 */
const bytes = Buffer.alloc(131087, 'a'), relative = 'assets/objects/aa/object';
const virtual = '/mc/' + relative;

/** 同一真实文件的不同用途各自持有局部memo；SHA1-only必须在Native和Kit两路均不创建SHA256。 */
for (const native of [false, true]) test(`SHA1 dependency purpose stays separate from dual digest contexts (${native ? 'Native' : 'Kit'})`, async () => {
  const f = fixture({ native, purpose: 'sha1' });
  try {
    f.put(virtual, bytes); const dep = f.dependency(relative, bytes);
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    assert.equal(await f.inspector.inspectExportDependency('/mc', { ...dep, sha1: 'f'.repeat(40) }, active, f.context), false);
    const first = await f.context.hash('/mc', relative, active);
    assert.equal(first.sha256, ''); assert.equal(first.sha1, digest(bytes)); first.sha1 = '0'.repeat(40);
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    assert.equal(f.readBytes(virtual), bytes.length);
    assert.deepEqual(native ? f.state.nativeAlgorithms : f.state.algorithms, ['SHA1']);
    if (native) { assert.deepEqual(f.state.algorithms, []); assert.equal(f.state.nativeSpecs[0].sha256, false); }

    // 未传用途的旧API仍返回双摘要；它不能从另一个SHA1实例借到缺少SHA256的值。
    const dual = new f.inspector.ExportCheckDigestContext();
    assert.equal((await dual.hash('/mc', relative, active)).sha256, digest(bytes, 'sha256'));
    assert.equal(f.readBytes(virtual), bytes.length * 2);
    assert.equal((await f.context.hash('/mc', relative, active)).sha256, '');
    assert.equal(f.readBytes(virtual), bytes.length * 2);
    assert.deepEqual(native ? f.state.nativeAlgorithms : f.state.algorithms, ['SHA1', 'SHA1', 'SHA256']);

    // 无上下文执行依赖检查仍fresh，但也只消费SHA1；普通快照摘要继续独立双算法。
    assert(await f.inspector.inspectExportDependency('/mc', dep, active));
    assert.equal(f.readBytes(virtual), bytes.length * 3);
    assert.equal((await f.archive.hashExportFile(virtual, active)).sha256, digest(bytes, 'sha256'));
    assert.deepEqual(native ? f.state.nativeAlgorithms : f.state.algorithms, ['SHA1', 'SHA1', 'SHA256', 'SHA1', 'SHA1', 'SHA256']);
  } finally { f.close(); }
});

/** 新用途不得借优化放宽弱身份：每次fresh与命中后弱化的补读仍只算所需算法。 */
test('SHA1-only context keeps weak identity fresh and never caches a late weakened hit', async () => {
  const f = fixture({ purpose: 'sha1' });
  try {
    f.put(virtual, bytes); f.state.omitNs = true;
    for (let index = 0; index < 2; index++) assert.equal((await f.context.hash('/mc', relative, active)).sha256, '');
    assert.equal(f.readBytes(virtual), bytes.length * 2);
    f.state.omitNs = false; await f.context.hash('/mc', relative, active);
    let fdVisits = 0, lost = false;
    f.state.statTransform = (target, stat, operation) => {
      if (target !== virtual) return stat;
      if (operation === 'fd' && ++fdVisits === 2) lost = true;
      if (!lost) return stat; const value = { ...stat }; delete value.mtimeNs; delete value.ctimeNs; return value;
    };
    assert.equal((await f.context.hash('/mc', relative, active)).sha256, ''); assert(lost);
    f.state.statTransform = null; await f.context.hash('/mc', relative, active);
    assert.equal(f.readBytes(virtual), bytes.length * 5);
    assert.deepEqual(f.state.algorithms, Array(5).fill('SHA1'));
  } finally { f.close(); }
});

/** 入口扩展不改变失败失效和owner关闭；每种失败后复查都必须重新读取真实字节。 */
for (const failure of ['read', 'close', 'cancel', 'identity']) test(`SHA1-only dependency preserves ${failure} failure and descriptor cleanup`, async () => {
  const f = fixture({ purpose: 'sha1' });
  try {
    f.put(virtual, bytes); let cancelled = false;
    if (failure === 'read') f.state.failRead = 1;
    if (failure === 'close') f.state.failClose = 1;
    if (failure === 'cancel') f.state.afterRead = () => { cancelled = true; };
    if (failure === 'identity') f.state.afterRead = () => { f.put(virtual, Buffer.alloc(bytes.length, 'x')); };
    await assert.rejects(f.context.hash('/mc', relative, () => cancelled), /EIO|取消|变化/);
    cancelled = false; f.state.afterRead = null; f.put(virtual, bytes);
    assert(await f.inspector.inspectExportDependency('/mc', f.dependency(relative, bytes), active, f.context));
    assert.equal(f.state.algorithms.includes('SHA256'), false);
  } finally { f.close(); }
});

test('same check reuses actual digest while every dependency compares its own SHA and size', async () => {
  const f = fixture();
  try {
    f.put(virtual, bytes); const valid = f.dependency(relative, bytes);
    assert(await f.inspector.inspectExportDependency('/mc', valid, active, f.context));
    const opens = f.state.opens.length, paths = f.state.lstats.length;
    assert.equal(await f.inspector.inspectExportDependency('/mc', { ...valid, sha1: 'f'.repeat(40) }, active, f.context), false);
    assert.equal(await f.inspector.inspectExportDependency('/mc', { ...valid, size: bytes.length + 1 }, active, f.context), false);
    assert(await f.inspector.inspectExportDependency('/mc', valid, active, f.context));
    assert.equal(f.readBytes(virtual), bytes.length, '不缓存true/false，重复期待只复用字节事实');
    assert.equal(f.state.opens.length, opens + 3); assert(f.state.lstats.length > paths + 3);
    assert(f.state.lstats.filter(value => value === '/mc/assets/objects').length >= 8, '命中仍完整核验路径链');
  } finally { f.close(); }
});

test('target aliases share only their actual source digest and candidate fallback is reevaluated', async () => {
  const f = fixture();
  try {
    const first = 'assets/virtual/legacy/name', second = relative;
    f.put('/mc/' + first, Buffer.alloc(bytes.length, 'b')); f.put(virtual, bytes);
    const base = f.dependency('assets/target-one', bytes, { sourceCandidates: [first, second] });
    assert.equal(await f.inspector.selectExportDependencySource('/mc', base, active, f.context), second);
    assert.equal(await f.inspector.selectExportDependencySource('/mc', { ...base, path: 'resources/target-two' }, active, f.context), second);
    assert.equal(f.readBytes(virtual), bytes.length);
    f.put('/mc/' + first, bytes);
    assert.equal(await f.inspector.selectExportDependencySource('/mc', base, active, f.context), first,
      '不能缓存上一次选中的fallback路径');
    assert.equal(f.readBytes('/mc/' + first), bytes.length * 2);
  } finally { f.close(); }
});

test('missing and failed candidates never become negative cache entries', async () => {
  const f = fixture();
  try {
    const dep = f.dependency(relative, bytes);
    assert.equal(await f.inspector.inspectExportDependency('/mc', dep, active, f.context), false);
    f.put(virtual, bytes); assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    fs.unlinkSync(f.physical(virtual));
    assert.equal(await f.inspector.inspectExportDependency('/mc', dep, active, f.context), false);
    f.put(virtual, bytes); assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    assert.equal(f.readBytes(virtual), bytes.length * 2);
  } finally { f.close(); }
});

for (const field of ['mtimeNs', 'ctimeNs']) test(`same-length same-second change invalidates digest through ${field}`, async () => {
  const f = fixture();
  try {
    f.put(virtual, bytes);
    let generation = 1n;
    // SDK秒字段故意完全相同，只推进其中一个真实SDK纳秒字段；正文仍从真实文件读取。
    f.state.statTransform = (_path, stat) => ({ ...stat, mtime: 1000, ctime: 1000,
      mtimeNs: field === 'mtimeNs' ? generation : 1000000000000n,
      ctimeNs: field === 'ctimeNs' ? generation : 1000000000000n });
    const dep = f.dependency(relative, bytes); assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    const changed = Buffer.alloc(bytes.length, 'c'); f.put(virtual, changed); generation++;
    assert.equal(await f.inspector.inspectExportDependency('/mc', dep, active, f.context), false);
    assert(await f.inspector.inspectExportDependency('/mc', f.dependency(relative, changed), active, f.context));
    assert.equal(f.readBytes(virtual), bytes.length * 2);
  } finally { f.close(); }
});

test('inode replacement invalidates same-length path even if all timestamps are equal', async () => {
  const f = fixture();
  try {
    f.put(virtual, bytes); f.state.statTransform = (_path, stat) => ({ ...stat, mtime: 1000, ctime: 1000, mtimeNs: 1n, ctimeNs: 2n });
    const dep = f.dependency(relative, bytes); assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    const before = fs.statSync(f.physical(virtual), { bigint: true }).ino, changed = Buffer.alloc(bytes.length, 'd');
    f.put('/replacement', changed); fs.renameSync(f.physical('/replacement'), f.physical(virtual));
    assert.notEqual(fs.statSync(f.physical(virtual), { bigint: true }).ino, before);
    assert.equal(await f.inspector.inspectExportDependency('/mc', dep, active, f.context), false);
    assert.equal(f.readBytes(virtual), bytes.length * 2);
  } finally { f.close(); }
});

for (const missing of ['both', 'mtimeNs', 'ctimeNs']) test(`SDK Stat missing ${missing} never reuses stable or same-second equal-length bytes`, async () => {
  const f = fixture();
  try {
    f.state.omitNs = missing === 'both'; f.state.statTransform = (_path, stat) => {
      const value = { ...stat, mtime: 1000, ctime: 1000 }; if (missing !== 'both') delete value[missing]; return value;
    };
    f.put(virtual, bytes); const dep = f.dependency(relative, bytes);
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    f.put(virtual, Buffer.alloc(bytes.length, 'e'));
    assert.equal(await f.inspector.inspectExportDependency('/mc', dep, active, f.context), false);
    assert.equal(f.readBytes(virtual), bytes.length * 3);
  } finally { f.close(); }
});

for (const [field, value] of [['ino', 0n], ['ino', -1n], ['ino', undefined], ['ino', 42],
  ['mtimeNs', 0n], ['mtimeNs', -1n], ['ctimeNs', 0n], ['ctimeNs', -1n]]) {
  test(`invalid strong identity ${field}=${String(value)} falls back to fresh hashing`, async () => {
    const f = fixture();
    try {
      f.put(virtual, bytes); f.state.statTransform = (_path, stat) => ({ ...stat, [field]: value });
      const dep = f.dependency(relative, bytes);
      assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
      assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
      assert.equal(f.readBytes(virtual), bytes.length * 2);
    } finally { f.close(); }
  });
}

test('cached leaf becoming an ordinary directory is rejected before any digest reuse', async () => {
  const f = fixture();
  try {
    f.put(virtual, bytes); const dep = f.dependency(relative, bytes);
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    fs.unlinkSync(f.physical(virtual)); fs.mkdirSync(f.physical(virtual));
    await assert.rejects(f.inspector.inspectExportDependency('/mc', dep, active, f.context), /普通文件/);
    assert.equal(f.readBytes(virtual), bytes.length);
  } finally { f.close(); }
});

test('different roots cannot share a digest merely because inode size and nanoseconds match', async () => {
  const f = fixture();
  try {
    const changed = Buffer.alloc(bytes.length, 'f'); f.put(virtual, bytes); f.put('/other/' + relative, changed);
    f.state.statTransform = (_path, stat) => ({ ...stat, ino: 42n, mtime: 1000, ctime: 1000, mtimeNs: 1n, ctimeNs: 2n });
    assert(await f.inspector.inspectExportDependency('/mc', f.dependency(relative, bytes), active, f.context));
    assert(await f.inspector.inspectExportDependency('/other', f.dependency(relative, changed), active, f.context));
    assert.equal(f.readBytes(virtual), bytes.length); assert.equal(f.readBytes('/other/' + relative), bytes.length);
  } finally { f.close(); }
});

for (const kind of ['leaf', 'ancestor']) test(`cached source still rejects a real ${kind} junction replacement`, async () => {
  const f = fixture();
  try {
    f.put(virtual, bytes); const dep = f.dependency(relative, bytes);
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    f.put('/outside/object', bytes);
    if (kind === 'leaf') {
      fs.unlinkSync(f.physical(virtual)); fs.symlinkSync(f.physical('/outside'), f.physical(virtual), 'junction');
    } else {
      fs.renameSync(f.physical('/mc/assets/objects'), f.physical('/kept-objects'));
      fs.symlinkSync(f.physical('/outside'), f.physical('/mc/assets/objects'), 'junction');
      f.put('/outside/aa/object', bytes);
    }
    await assert.rejects(f.inspector.inspectExportDependency('/mc', dep, active, f.context), /链接/);
    assert.equal(f.readBytes(virtual), bytes.length); assert.equal(fs.readFileSync(f.physical('/outside/object')).length, bytes.length);
  } finally { f.close(); }
});

test('NOFOLLOW and fd/path identity reject replacements between validation and open', async () => {
  const f = fixture();
  try {
    f.put(virtual, bytes); const dep = f.dependency(relative, bytes);
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    let swapped = false;
    f.state.beforeOpen = target => {
      if (target === virtual && !swapped) { swapped = true; f.put('/replacement', bytes); fs.renameSync(f.physical('/replacement'), f.physical(virtual)); }
    };
    await assert.rejects(f.inspector.inspectExportDependency('/mc', dep, active, f.context), /打开期间.*变化/);
    f.state.beforeOpen = null;
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    assert.equal(f.readBytes(virtual), bytes.length * 2);
  } finally { f.close(); }
});

test('leaf junction installed after path validation is still rejected by NOFOLLOW open', async () => {
  const f = fixture();
  try {
    f.put(virtual, bytes); f.put('/outside/object', bytes); const dep = f.dependency(relative, bytes);
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    let swapped = false;
    f.state.beforeOpen = target => {
      if (target === virtual && !swapped) {
        swapped = true; fs.unlinkSync(f.physical(virtual)); fs.symlinkSync(f.physical('/outside'), f.physical(virtual), 'junction');
      }
    };
    await assert.rejects(f.inspector.inspectExportDependency('/mc', dep, active, f.context), /ELOOP NOFOLLOW/);
    assert.equal(f.readBytes(virtual), bytes.length);
  } finally { f.close(); }
});

for (const operation of ['Open', 'Stat', 'Close']) test(`cache hit propagates ${operation} failure and evicts the old entry`, async () => {
  const f = fixture();
  try {
    f.put(virtual, bytes); const dep = f.dependency(relative, bytes);
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    f.state['fail' + operation] = 1;
    await assert.rejects(f.inspector.inspectExportDependency('/mc', dep, active, f.context), /boundary/);
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    assert.equal(f.readBytes(virtual), bytes.length * 2);
  } finally { f.close(); }
});

test('fresh hash read failure and in-flight cancellation do not write reusable entries', async () => {
  const f = fixture();
  try {
    f.put(virtual, bytes); const dep = f.dependency(relative, bytes); f.state.failRead = 1;
    await assert.rejects(f.inspector.inspectExportDependency('/mc', dep, active, f.context), /EIO read/);
    let cancelled = false;
    f.state.afterRead = () => { cancelled = true; };
    await assert.rejects(f.inspector.inspectExportDependency('/mc', dep, () => cancelled, f.context), /取消/);
    f.state.afterRead = null; cancelled = false;
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    assert.equal(f.readBytes(virtual), bytes.length + 65536);
  } finally { f.close(); }
});

test('cancellation after cache-hit close discards memo and all handles settle before rejection', async () => {
  const f = fixture();
  try {
    f.put(virtual, bytes); const dep = f.dependency(relative, bytes);
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    let cancelled = false; f.state.afterClose = () => { cancelled = true; };
    await assert.rejects(f.inspector.inspectExportDependency('/mc', dep, () => cancelled, f.context), /取消/);
    cancelled = false; f.state.afterClose = null;
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    assert.equal(f.readBytes(virtual), bytes.length * 2);
  } finally { f.close(); }
});

test('cancellation during a missing-path lstat is not reported as an ordinary absent dependency', async () => {
  const f = fixture();
  try {
    let cancelled = false;
    f.state.beforeLstat = target => { if (target === virtual) cancelled = true; };
    await assert.rejects(f.inspector.inspectExportDependency('/mc', f.dependency(relative, bytes), () => cancelled, f.context), /取消/);
    await assert.rejects(f.inspector.selectExportDependencySource('/mc', f.dependency(relative, bytes, { sourceCandidates: [] }), () => cancelled, f.context), /取消/);
    assert.equal(f.state.opens.length, 0);
  } finally { f.close(); }
});

test('new check context and execution without context always hash fresh bytes', async () => {
  const f = fixture();
  try {
    f.put(virtual, bytes); const dep = f.dependency(relative, bytes);
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, new f.inspector.ExportCheckDigestContext()));
    assert(await f.inspector.inspectExportDependency('/mc', dep, active));
    const actual = await f.archive.hashExportFile(virtual, active);
    assert.equal(actual.sha256, digest(bytes, 'sha256')); assert.equal(f.readBytes(virtual), bytes.length * 4);
  } finally { f.close(); }
});

test('callers cannot mutate memo facts through a returned digest object', async () => {
  const f = fixture();
  try {
    f.put(virtual, bytes); const first = await f.context.hash('/mc', relative, active);
    first.sha1 = '0'.repeat(40); first.size = 0;
    assert(await f.inspector.inspectExportDependency('/mc', f.dependency(relative, bytes), active, f.context));
    assert.equal(f.readBytes(virtual), bytes.length);
  } finally { f.close(); }
});

/** B审发现的后置精度丢失反例：不能只禁下次memo，却仍向本次返回旧digest。 */
for (const lossAt of ['afterFd', 'afterPath']) test(`cache hit losing nanoseconds at ${lossAt} performs one fresh hash and leaves no memo`, async () => {
  const f = fixture();
  try {
    f.put(virtual, bytes); const dep = f.dependency(relative, bytes);
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    const opensBefore = f.state.opens.length; let fdVisits = 0, afterFdPassed = false, lost = false;
    f.state.statTransform = (target, stat, operation) => {
      if (target !== virtual) return stat;
      if (operation === 'fd' && ++fdVisits === 2) {
        if (lossAt === 'afterFd') lost = true; else afterFdPassed = true;
      }
      if (lossAt === 'afterPath' && afterFdPassed && operation === 'lstat') lost = true;
      if (!lost) return stat;
      const value = { ...stat }; delete value.mtimeNs; delete value.ctimeNs; return value;
    };
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    assert(lost); assert.equal(f.readBytes(virtual), bytes.length * 2);
    assert.equal(f.state.opens.length, opensBefore + 2, '只追加一次fresh摘要，不能进入重试循环');
    // 原文件保持不变，恢复强戳后本可匹配原memo；仍fresh证明弱身份这次没有重新登记。
    f.state.statTransform = null;
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    assert.equal(f.readBytes(virtual), bytes.length * 3);
  } finally { f.close(); }
});

test('late weakened identity returns fresh changed bytes rather than a previously matching digest', async () => {
  const f = fixture();
  try {
    f.put(virtual, bytes); const dep = f.dependency(relative, bytes), changed = Buffer.alloc(bytes.length, 'x');
    // 秒字段刻意固定，首次memo仍具有真实纳秒字段。后置精度丢失时实际同长度改写正文。
    f.state.statTransform = (_target, stat) => ({ ...stat, mtime: 1000, ctime: 1000 });
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    let fdVisits = 0, lost = false;
    f.state.statTransform = (target, stat, operation) => {
      const value = { ...stat, mtime: 1000, ctime: 1000 };
      if (target !== virtual) return value;
      if (operation === 'fd' && ++fdVisits === 2) { lost = true; f.put(virtual, changed); }
      if (lost) { delete value.mtimeNs; delete value.ctimeNs; } return value;
    };
    assert.equal(await f.inspector.inspectExportDependency('/mc', dep, active, f.context), false,
      '旧期望必须与本次fresh字节比较，不能把先前通过的摘要重新返回');
    assert.equal(f.readBytes(virtual), bytes.length * 2);
  } finally { f.close(); }
});

test('late weakened identity propagates its fresh read failure and does not restore old memo', async () => {
  const f = fixture();
  try {
    f.put(virtual, bytes); const dep = f.dependency(relative, bytes);
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    let fdVisits = 0, lost = false;
    f.state.statTransform = (target, stat, operation) => {
      if (target !== virtual) return stat;
      if (operation === 'fd' && ++fdVisits === 2) lost = true;
      if (!lost) return stat;
      const value = { ...stat }; delete value.mtimeNs; delete value.ctimeNs; return value;
    };
    f.state.failRead = 1;
    await assert.rejects(f.inspector.inspectExportDependency('/mc', dep, active, f.context), /EIO read/);
    f.state.statTransform = null;
    assert(await f.inspector.inspectExportDependency('/mc', dep, active, f.context));
    assert.equal(f.readBytes(virtual), bytes.length * 2);
  } finally { f.close(); }
});

/** dependency.path是目标，不能拿它代替sourceCandidates的实际来源键执行取消撤销。 */
for (const when of ['entry', 'candidate-await']) test(`source selection cancellation at ${when} evicts all alias source facts`, async () => {
  const f = fixture();
  try {
    const alias = 'assets/virtual/legacy/name', aliasPath = '/mc/' + alias;
    f.put(virtual, bytes); f.put(aliasPath, bytes);
    for (const source of [relative, alias]) assert(await f.inspector.inspectExportDependency('/mc', f.dependency(source, bytes), active, f.context));
    const dep = f.dependency('resources/target-that-is-not-a-source', bytes, { sourceCandidates: [alias, relative] });
    let cancelled = when === 'entry';
    if (when === 'candidate-await') f.state.beforeLstat = target => { if (target === aliasPath) cancelled = true; };
    await assert.rejects(f.inspector.selectExportDependencySource('/mc', dep, () => cancelled, f.context), /取消/);
    cancelled = false; f.state.beforeLstat = null;
    for (const source of [relative, alias]) assert(await f.inspector.inspectExportDependency('/mc', f.dependency(source, bytes), active, f.context));
    assert.equal(f.readBytes(virtual), bytes.length * 2); assert.equal(f.readBytes(aliasPath), bytes.length * 2);
  } finally { f.close(); }
});

/** 有界批次只改变调度，不替代真实来源选择、文件打开或摘要期望比较。 */
const tick = () => new Promise(resolve => setImmediate(resolve));
async function until(predicate) {
  for (let count = 0; count < 1000; count++) { if (predicate()) return; await tick(); }
  throw new Error('bounded dependency fixture did not reach its explicit gate');
}
function batchFiles(f, count = 9) {
  return Array.from({ length: count }, (_, index) => {
    const relative = 'libraries/batch/item-' + index + '.jar', bytes = Buffer.from('batch-' + index);
    f.put('/mc/' + relative, bytes); return f.dependency(relative, bytes);
  });
}

test('dependency batch reaches four in flight, never five, and publishes input order after reversed completion', async () => {
  const f = fixture({ purpose: 'sha1' }); const releases = new Map(); let inflight = 0, peak = 0;
  try {
    const deps = batchFiles(f); const entered = [];
    f.state.beforeLstat = async target => {
      const index = deps.findIndex(dep => target === '/mc/' + dep.path);
      // 每项只有第一次存在性检查被门控制；实际路径链和hash仍执行生产实现。
      if (index < 0 || entered.includes(index)) return;
      entered.push(index); peak = Math.max(peak, ++inflight);
      await new Promise(resolve => releases.set(index, () => { inflight--; resolve(); }));
    };
    const pending = f.inspector.selectExportDependencySources('/mc', deps, active, f.context);
    await until(() => releases.size === 4); assert.deepEqual(entered, [0, 1, 2, 3]); assert.equal(peak, 4);
    for (let next = 3; next >= 0; next--) releases.get(next)();
    await until(() => releases.size >= 8); assert.equal(peak, 4);
    for (let next = 7; next >= 4; next--) releases.get(next)();
    await until(() => releases.size === 9); releases.get(8)();
    assert.deepEqual(await pending, deps.map(dep => dep.path)); assert.equal(inflight, 0); assert.equal(peak, 4);
  } finally { for (const release of releases.values()) release(); f.close(); }
});

test('dependency batch cancellation stops new admission and drains all four Native releases and SDK fds', async () => {
  const f = fixture({ native: true, purpose: 'sha1' }); let cancelled = false, returned = false;
  try {
    const deps = batchFiles(f); f.state.nativeReleaseAllowed = false;
    const pending = f.inspector.selectExportDependencySources('/mc', deps, () => cancelled, f.context);
    const rejection = assert.rejects(pending, /取消/).then(() => { returned = true; });
    await until(() => f.state.nativeJobs.size === 4); cancelled = true;
    await tick(); await tick(); assert.equal(returned, false); assert.equal(f.state.nativeSpecs.length, 4);
    f.state.nativeReleaseAllowed = true; await rejection;
    assert.equal(f.state.nativeJobs.size, 0); assert.equal(f.state.nativeReleased.length, 4);
    assert(f.state.opens.every(item => deps.slice(0, 4).some(dep => item.virtual === '/mc/' + dep.path)));
  } finally { f.state.nativeReleaseAllowed = true; f.close(); }
});

test('dependency batch retains the first IO failure while draining other Native jobs before rejection', async () => {
  const f = fixture({ native: true, purpose: 'sha1' }); let failFirst, returned = false;
  try {
    const deps = batchFiles(f); const first = '/mc/' + deps[0].path; let entered = false;
    f.state.nativeReleaseAllowed = false;
    f.state.beforeLstat = async target => {
      if (target === first && !entered) { entered = true; await new Promise((_resolve, reject) => { failFirst = reject; }); }
    };
    const pending = f.inspector.selectExportDependencySources('/mc', deps, active, f.context);
    const originalError = new Error('EACCES primary-source');
    const rejection = assert.rejects(pending, error => error === originalError).then(() => { returned = true; });
    await until(() => f.state.nativeJobs.size === 3 && failFirst); failFirst(originalError);
    await tick(); await tick(); assert.equal(returned, false); assert.equal(f.state.nativeSpecs.length, 3);
    f.state.nativeReleaseAllowed = true; await rejection;
    assert.equal(f.state.nativeJobs.size, 0); assert.equal(f.state.nativeReleased.length, 3);
    assert(!f.state.opens.some(item => deps.slice(4).some(dep => item.virtual === '/mc/' + dep.path)));
  } finally { f.state.nativeReleaseAllowed = true; f.close(); }
});

/** 非Error也必须先drain，且上层始终能安全读取message；已有真实Error仍原实例返回。 */
for (const failure of [undefined, null, 'SDK string rejection']) test(`dependency batch normalizes ${String(failure)} only after Native drain`, async () => {
  const f = fixture({ native: true, purpose: 'sha1' }); let rejectFirst, returned = false;
  try {
    const deps = batchFiles(f); let entered = false; f.state.nativeReleaseAllowed = false;
    // open端口位于存在性业务错误码判断之后，确保原始非Error真正到达新批次边界。
    f.state.beforeOpen = async target => {
      if (target === '/mc/' + deps[0].path && !entered) { entered = true; await new Promise((_resolve, reject) => { rejectFirst = reject; }); }
    };
    const pending = f.inspector.selectExportDependencySources('/mc', deps, active, f.context);
    const rejected = assert.rejects(pending, error => error instanceof Error && /非Error/.test(error.message)).then(() => { returned = true; });
    await until(() => f.state.nativeJobs.size === 3 && rejectFirst); rejectFirst(failure);
    await tick(); await tick(); assert.equal(returned, false); assert.equal(f.state.nativeSpecs.length, 3);
    f.state.nativeReleaseAllowed = true; await rejected; assert.equal(f.state.nativeReleased.length, 3);
  } finally { f.state.nativeReleaseAllowed = true; f.close(); }
});

test('dependency batch normalizes a throwing cancellation callback after draining its admitted Native owners', async () => {
  const f = fixture({ native: true, purpose: 'sha1' }); let throwCancel = false, returned = false;
  try {
    const deps = batchFiles(f); f.state.nativeReleaseAllowed = false;
    const pending = f.inspector.selectExportDependencySources('/mc', deps, () => { if (throwCancel) throw undefined; return false; }, f.context);
    const rejected = assert.rejects(pending, error => error instanceof Error && /非Error/.test(error.message)).then(() => { returned = true; });
    await until(() => f.state.nativeJobs.size === 4); throwCancel = true;
    await tick(); assert.equal(returned, false); f.state.nativeReleaseAllowed = true; await rejected;
    assert.equal(f.state.nativeReleased.length, 4); assert.equal(f.state.nativeSpecs.length, 4);
  } finally { f.state.nativeReleaseAllowed = true; f.close(); }
});

test('dependency batch preserves primary IO Error identity and code when its later cancellation probe also throws', async () => {
  const f = fixture({ native: true, purpose: 'sha1' }); let rejectFirst, throwProbe = false, returned = false;
  try {
    const deps = batchFiles(f); let entered = false; f.state.nativeReleaseAllowed = false;
    const original = Object.assign(new Error('primary FileIO failed'), { code: 13900012 });
    f.state.beforeOpen = async target => {
      if (target === '/mc/' + deps[0].path && !entered) { entered = true; await new Promise((_resolve, reject) => { rejectFirst = reject; }); }
    };
    const pending = f.inspector.selectExportDependencySources('/mc', deps, () => { if (throwProbe) throw new Error('later cancellation probe'); return false; }, f.context);
    const rejected = assert.rejects(pending, error => error === original && error.code === 13900012).then(() => { returned = true; });
    await until(() => f.state.nativeJobs.size === 3 && rejectFirst); throwProbe = true; rejectFirst(original);
    await tick(); await tick(); assert.equal(returned, false); assert.equal(f.state.nativeSpecs.length, 3);
    f.state.nativeReleaseAllowed = true; await rejected; assert.equal(f.state.nativeReleased.length, 3);
  } finally { f.state.nativeReleaseAllowed = true; f.close(); }
});

test('dependency batch independently checks same-path conflicting expectations and ordered alias fallback', async () => {
  const f = fixture({ purpose: 'sha1' });
  try {
    f.put(virtual, bytes); f.put('/mc/assets/virtual/bad/name', Buffer.alloc(bytes.length, 'x'));
    const good = f.dependency(relative, bytes);
    const wrong = { ...good, sha1: 'f'.repeat(40) };
    const alias = { ...good, path: 'resources/name', sourceCandidates: ['assets/virtual/bad/name', relative] };
    const results = await f.inspector.selectExportDependencySources('/mc', [good, wrong, alias], active, f.context);
    assert.deepEqual(results, [relative, undefined, relative]);
    assert.equal(f.readBytes('/mc/assets/virtual/bad/name'), bytes.length);
  } finally { f.close(); }
});

test('dependency batch still rejects inode replacement during SDK open and drains the other admitted reads', async () => {
  const f = fixture({ purpose: 'sha1' });
  try {
    const deps = batchFiles(f); let replaced = false;
    f.state.beforeOpen = target => {
      if (target !== '/mc/' + deps[0].path || replaced) return;
      replaced = true; fs.renameSync(f.physical(target), f.physical(target + '.old'));
      f.put(target, 'batch-0');
    };
    await assert.rejects(f.inspector.selectExportDependencySources('/mc', deps, active, f.context), /变化/);
    assert(replaced); assert(!f.state.opens.some(item => deps.slice(4).some(dep => item.virtual === '/mc/' + dep.path)));
  } finally { f.close(); }
});

test('empty and already-cancelled dependency batches create no file or Native owner', async () => {
  const f = fixture({ native: true });
  try {
    assert.deepEqual(await f.inspector.selectExportDependencySources('/mc', [], active, f.context), []);
    const deps = batchFiles(f);
    await assert.rejects(f.inspector.selectExportDependencySources('/mc', deps, () => true, f.context), /取消/);
    assert.equal(f.state.lstats.length, 0); assert.equal(f.state.opens.length, 0); assert.equal(f.state.nativeSpecs.length, 0);
  } finally { f.close(); }
});
