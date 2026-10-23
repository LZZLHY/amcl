/**
 * 运行真实扫描、文件工作函数和调度器的宿主回归。
 * TaskPool 的跨线程调度由可取消的异步宿主替身承接；不把本测试当作 ArkTS 编译或真机性能证明。
 * 测试数据必须显式外置：node scripts/test-local-mod-scan.mjs --work-dir <外部任务目录>。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { ts, root, mocks, fileIo } from './mod-install-test-runtime.mjs';

const outArg = process.argv.indexOf('--work-dir');
if (outArg < 0 || !process.argv[outArg + 1]) throw new Error('必须通过 --work-dir 指定仓库外测试数据目录');
const output = path.resolve(process.argv[outArg + 1]);
if (output === root || output.startsWith(root + path.sep)) throw new Error('测试数据必须位于仓库外');
fs.mkdirSync(output, { recursive: true });
const work = fs.mkdtempSync(path.join(output, 'local-mod-'));
let executingTask = null;
let readHook = null;
let shortRead = 0;
let peakBuffer = 0;
let openCount = 0;
const descriptors = new Set();
const kitIo = {
  ...fileIo,
  // HarmonyOS 的 mtime 是数值，Node Stats.mtime 是每次新建的 Date，需按真实接口形状适配。
  statSync(p) { const stat = fs.statSync(p); return { size: stat.size, mtime: stat.mtimeMs, isFile: () => stat.isFile() }; },
  openSync(p, mode) { const f = fileIo.openSync(p, mode); descriptors.add(f.fd); openCount++; return f; },
  closeSync(f) { const fd = typeof f === 'number' ? f : f.fd; fileIo.closeSync(f); descriptors.delete(fd); },
  readSync(fd, buffer, options) {
    peakBuffer = Math.max(peakBuffer, buffer.byteLength);
    if (readHook) readHook();
    const length = Math.min(options?.length ?? buffer.byteLength, shortRead || Infinity);
    return fs.readSync(fd, new Uint8Array(buffer), 0, length, options?.offset ?? null);
  },
};
/** 同步工作函数在下一次事件循环运行；取消状态由当前任务暴露给真实块检查逻辑。 */
class HostTask {
  constructor(fn, ...args) { this.fn = fn; this.args = args; this.cancelled = false; }
  static isCanceled() { return executingTask?.cancelled ?? false; }
}
const taskpool = {
  Task: HostTask, Priority: { LOW: 0 },
  cancel(task) { task.cancelled = true; },
  execute(task) {
    return new Promise((resolve, reject) => setImmediate(() => {
      executingTask = task;
      try {
        if (task.cancelled) throw new Error('LocalModScanCancelled');
        const value = task.fn(...task.args);
        if (task.cancelled) throw new Error('LocalModScanCancelled');
        resolve(value);
      } catch (e) { reject(e); } finally { executingTask = null; }
    }));
  },
};
const extras = {
  '@kit.CoreFileKit': { fileIo: kitIo },
  '@kit.ArkTS': { taskpool },
  '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd(algorithm) {
    assert.equal(algorithm, 'SHA1'); const hash = crypto.createHash('sha1');
    return { updateSync(blob) { hash.update(blob.data); }, digestSync() { return { data: new Uint8Array(hash.digest()) }; } };
  } } },
  './ModInstallTransaction': { modInstallationActive: () => false },
};
/** 仅移除宿主 TypeScript 不支持的函数装饰器；其余生产代码直接转译执行。 */
const cache = new Map();
function load(relative) {
  const filename = path.resolve(root, relative);
  if (cache.has(filename)) return cache.get(filename);
  const source = fs.readFileSync(filename, 'utf8').replace(/^@Concurrent\s*$/gm, '');
  const result = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true });
  const errors = (result.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error);
  assert.equal(errors.length, 0, filename + ': ' + errors.map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')).join('\n'));
  const mod = { exports: {} }; cache.set(filename, mod.exports);
  const requireLocal = name => {
    if (name === 'commons') return { ...mocks.commons, ...load('commons/src/main/ets/utils/InstancePaths.ets') };
    if (name in extras) return extras[name];
    if (name in mocks) return mocks[name];
    if (name.startsWith('.')) return load(path.resolve(path.dirname(filename), name + '.ets'));
    throw new Error('Unexpected import: ' + name);
  };
  vm.runInNewContext(result.outputText, { module: mod, exports: mod.exports, require: requireLocal, console, setTimeout, clearTimeout }, { filename });
  cache.set(filename, mod.exports); return mod.exports;
}

const Tasks = load('mods/src/main/ets/LocalModFileTasks.ets');
const Scan = load('mods/src/main/ets/LocalModScanner.ets');
const Work = load('mods/src/main/ets/ModScanWork.ets');
const Fingerprint = load('mods/src/main/ets/CurseForgeFingerprint.ets');
const T = load('mods/src/main/ets/ModTypes.ets');
const Index = load('mods/src/main/ets/InstalledModIndex.ets');
const req = { mcDir: work, versionId: 'test', versionIsolation: false, kind: T.ResourceKind.MOD };
const dir = path.join(work, 'mods'); fs.mkdirSync(dir);
for (let i = 0; i < 1027; i++) fs.writeFileSync(path.join(dir, `mod-${i}.jar${i === 1026 ? '.disabled' : ''}`), String(i));
fs.mkdirSync(path.join(dir, 'not-a-file.jar'));
fs.writeFileSync(path.join(dir, 'notes.txt'), 'ignored');
const initial = await Tasks.enumerateLocalResourceFiles(dir, ['.jar', '.jar.disabled']);
assert.equal(initial.length, 1027);
assert.equal(initial.find(m => m.filename.endsWith('.disabled')).enabled, false);
assert.equal((await new Scan.LocalModScanner(null).scan({ ...req, localMods: initial })).mods.length, 1027);
const zipDir = path.join(work, 'datapacks'); fs.mkdirSync(zipDir);
fs.writeFileSync(path.join(zipDir, 'pack.zip'), 'zip'); fs.writeFileSync(path.join(zipDir, 'pack.jar'), 'jar');
assert.equal((await Tasks.enumerateLocalResourceFiles(zipDir, ['.zip'])).length, 1);
assert.equal((await Tasks.enumerateLocalResourceFiles(path.join(work, 'absent'), ['.jar'])).length, 0);

let requests = 0; let inFlight = 0; let peakRequests = 0;
const repository = { async lookupVersionBySha1() {
  requests++; inFlight++; peakRequests = Math.max(peakRequests, inFlight);
  await new Promise(resolve => setTimeout(resolve, 1)); inFlight--; return null;
} };
await Promise.all([new Scan.LocalModScanner(repository).scan({ ...req, localMods: initial }),
  new Scan.LocalModScanner(repository).scan({ ...req, localMods: initial })]);
assert.equal(requests, 128, '每轮64预算不能截断清单，也不能变成无限来源查询');
assert.ok(peakRequests <= 2, '多轮扫描共享来源链并发预算');
const managed = initial[0];
const sha = crypto.createHash('sha1').update(fs.readFileSync(managed.filePath)).digest('hex');
Index.recordInstalledMod(dir, { baseName: managed.filename, source: 'modrinth', projectId: 'p', versionId: 'v', expectedSha1: sha, expectedSize: managed.sizeBytes, at: 1 });
const opensBefore = openCount;
let result = await new Scan.LocalModScanner(null).scan({ ...req, localMods: [managed] });
assert.equal(result.mods[0].integrity, 'verified'); assert.equal(openCount, opensBefore, '已收编快检不能重新打开JAR哈希');
result = await new Scan.LocalModScanner(null).scan({ ...req, localMods: [managed], fullVerify: true });
assert.equal(result.mods[0].sha1, sha); assert.equal(result.mods[0].integrity, 'verified');

// 使用独立的旧版整块参考算法，对跨块尾字节和过滤规则进行一致性验证。
function oldMurmur(input, seed = 1) {
  let h = (seed ^ input.length) >>> 0; let i = 0;
  for (; i + 4 <= input.length; i += 4) {
    let k = input.readUInt32LE(i); k = Math.imul(k, 0x5bd1e995) >>> 0; k ^= k >>> 24; k = Math.imul(k, 0x5bd1e995) >>> 0;
    h = (Math.imul(h, 0x5bd1e995) ^ k) >>> 0;
  }
  let tail = 0; for (let j = i; j < input.length; j++) tail |= input[j] << ((j - i) * 8);
  if (i < input.length) h = Math.imul(h ^ tail, 0x5bd1e995) >>> 0;
  h ^= h >>> 13; h = Math.imul(h, 0x5bd1e995) >>> 0; return (h ^ (h >>> 15)) >>> 0;
}
const binary = path.join(work, 'fingerprint.jar');
for (const length of [0, 1, 2, 3, 4, 5, 31, 256 * 1024 - 1, 256 * 1024 + 3, 1024 * 1024 + 7]) {
  const bytes = Buffer.alloc(length); for (let i = 0; i < length; i++) bytes[i] = (i * 17 + (i >>> 6)) & 255;
  fs.writeFileSync(binary, bytes);
  const filtered = Buffer.from(bytes.filter(b => ![9, 10, 13, 32].includes(b)));
  assert.equal(Fingerprint.murmur2(new Uint8Array(bytes), 1), oldMurmur(bytes));
  assert.equal(await Fingerprint.computeCurseForgeFingerprint(binary), length ? oldMurmur(filtered) : 0);
}
shortRead = 7;
const shortBytes = Buffer.from(' a\tb\nc\rd0123456789 '); fs.writeFileSync(binary, shortBytes);
assert.equal(await Fingerprint.computeCurseForgeFingerprint(binary), oldMurmur(Buffer.from(shortBytes.filter(b => ![9, 10, 13, 32].includes(b)))));
assert.equal(await Tasks.computeLocalModSha1(binary), crypto.createHash('sha1').update(shortBytes).digest('hex'));
shortRead = 0;
assert.ok(peakBuffer <= 256 * 1024, '任何生产文件读取工作缓冲不能超过256KiB');

const cancel = new Work.LocalModScanControl(); let readCalls = 0;
readHook = () => { if (++readCalls === 2) cancel.cancel(); };
await assert.rejects(Tasks.computeLocalModSha1(binary, cancel)); readHook = null;
assert.equal(descriptors.size, 0, '取消后句柄必须归还');
readHook = () => { throw new Error('injected read failure'); };
assert.equal(await Fingerprint.computeCurseForgeFingerprint(binary), 0); readHook = null;
assert.equal(descriptors.size, 0, '文件读取失败后句柄必须归还');

const cancelScan = new Work.LocalModScanControl();
const indexBefore = fs.readFileSync(path.join(dir, '.amcl-mods-index.json'), 'utf8'); let cancelRequests = 0;
const cancellingRepo = { async lookupVersionBySha1() { cancelRequests++; cancelScan.cancel(); return { id: 'new', projectId: 'new', name: 'new' }; } };
await assert.rejects(new Scan.LocalModScanner(cancellingRepo).scan({ ...req, localMods: initial.slice(1), control: cancelScan }));
assert.ok(cancelRequests <= 2, '取消后不能继续派发下一批来源请求');
assert.equal(fs.readFileSync(path.join(dir, '.amcl-mods-index.json'), 'utf8'), indexBefore, '取消扫描不能写入半轮索引');
const preCancelled = new Work.LocalModScanControl(); preCancelled.cancel();
await assert.rejects(Tasks.enumerateLocalResourceFiles(dir, ['.jar'], preCancelled));
assert.equal(descriptors.size, 0);
console.log('PASS: complete 1027 files/disabled/zip, 64 budget, global concurrency, managed fast/full checks, streaming CF oracle and short reads, 256KiB buffers, cancellation/index isolation and descriptor cleanup');
console.log('Test evidence retained: ' + work);
