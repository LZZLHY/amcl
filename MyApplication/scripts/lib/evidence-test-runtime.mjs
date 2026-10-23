// 宿主适配仅替换 OHOS 系统边界；被测实现直接从生产 .ets 编译，禁止真实网络发送。
// 临时夹具及其清理边界统一使用外部宿主测试区，不修改系统 TEMP，也不回退到源码目录。
import { workspaceTempRoot } from './workspace-paths.mjs';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import ts from './ets-compiler.mjs';
const repo = path.resolve(import.meta.dirname, '../..');
export function evidenceRuntime(options = {}) {
  const directory = fs.mkdtempSync(path.join(workspaceTempRoot(), 'amcl-evidence-test-'));
  const cache = new Map();
  const control = { afterRead: undefined, failWrite: undefined, requests: [], files: [], main: '', cryptoUpdates: [],
    remoteTransform: undefined, id: 'sAbCdEf', urlId: 'sAbCdEf', networkError: false };
  const stat = (p, follow = true) => {
    const value = typeof p === 'number' ? fs.fstatSync(p, { bigint: true }) : follow ? fs.statSync(p, { bigint: true }) : fs.lstatSync(p, { bigint: true });
    return { size: Number(value.size), mtime: Number(value.mtimeMs / 1000n), ctime: Number(value.ctimeMs / 1000n),
      ino: value.ino, mtimeNs: value.mtimeNs, ctimeNs: value.ctimeNs, isFile: () => value.isFile(), isDirectory: () => value.isDirectory(), isSymbolicLink: () => value.isSymbolicLink() };
  };
  const kitFs = {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
    statSync: stat, stat: async p => stat(p), lstatSync: p => stat(p, false),
    openSync(p, mode = 0) {
      if (control.failWrite?.(p, mode)) throw new Error('synthetic disk failure');
      if (fs.existsSync(p) && fs.statSync(p).isDirectory()) return { fd: -100 };
      return { fd: fs.openSync(p, (mode & 512) ? 'w' : mode === 0 ? 'r' : (mode & 64) ? 'a' : 'r+') };
    },
    async open(p, mode) { return kitFs.openSync(p, mode); },
    closeSync(file) { const fd = typeof file === 'number' ? file : file.fd; if (fd >= 0) fs.closeSync(fd); },
    async close(file) { kitFs.closeSync(file); },
    fsyncSync(fd) { if (fd >= 0) fs.fsyncSync(fd); },
    writeSync(fd, content) { return fs.writeSync(fd, typeof content === 'string' ? content : Buffer.from(content)); },
    async write(fd, content) { return kitFs.writeSync(fd, content); },
    readSync(fd, buffer, options = {}) { return fs.readSync(fd, Buffer.from(buffer), 0, options.length ?? buffer.byteLength, options.offset ?? null); },
    async read(fd, buffer, options) { const got = kitFs.readSync(fd, buffer, options); await control.afterRead?.(fd, got); return got; },
    // SDK readText 由宿主真实异步文件IO承接，用于验证导航元数据不会退回同步全量读取。
    readText: p => fs.promises.readFile(p, 'utf8'),
    readTextSync: p => fs.readFileSync(p, 'utf8'), listFileSync: p => fs.readdirSync(p), listFile: async p => fs.readdirSync(p),
    mkdirSync: p => fs.mkdirSync(p, { recursive: true }), renameSync: fs.renameSync,
    unlinkSync: fs.unlinkSync, copyFileSync: fs.copyFileSync, accessSync: fs.existsSync,
    rmdirSync: p => fs.rmSync(p, { recursive: true }),
  };
  // 真正异步SDK边界由Node异步文件API承接；保留原fd模式和写盘故障注入，
  // 目录句柄在Windows宿主用既有哨兵表示（设备仍真实open/fsync目录）。
  const invokeFd = (method, ...args) => new Promise((resolve, reject) => fs[method](...args,
    (error, value) => error ? reject(error) : resolve(value)));
  const normalizeStat = value => ({ size: Number(value.size), mtime: Number(value.mtimeMs / 1000n),
    ctime: Number(value.ctimeMs / 1000n), ino: value.ino, mtimeNs: value.mtimeNs, ctimeNs: value.ctimeNs,
    isFile: () => value.isFile(), isDirectory: () => value.isDirectory(), isSymbolicLink: () => value.isSymbolicLink() });
  const sdkError = error => {
    const codes = { ENOENT: 13900002, EEXIST: 13900015, ENOTDIR: 13900018,
      EACCES: 13900012, EPERM: 13900001, ELOOP: 13900033 };
    if (Object.hasOwn(codes, error.code)) error.code = codes[error.code];
    return error;
  };
  kitFs.stat = async p => { try { return normalizeStat(typeof p === 'number'
    ? await invokeFd('fstat', p, { bigint: true }) : await fs.promises.stat(p, { bigint: true })); } catch (error) { throw sdkError(error); } };
  kitFs.lstat = async p => { try { return normalizeStat(await fs.promises.lstat(p, { bigint: true })); } catch (error) { throw sdkError(error); } };
  kitFs.readText = async p => { try { return await fs.promises.readFile(p, 'utf8'); } catch (error) { throw sdkError(error); } };
  kitFs.mkdir = async (p, recursive = false) => {
    // 真实FileIO的递归只创建缺失父级，不把已存在的最终目标当成功；Node递归mkdir原样会掩盖EEXIST。
    try {
      if (recursive) await fs.promises.mkdir(path.dirname(p), { recursive: true });
      await fs.promises.mkdir(p);
    } catch (error) { throw sdkError(error); }
  };
  kitFs.open = async (p, mode = 0) => {
    if (control.failWrite?.(p, mode)) throw new Error('synthetic disk failure');
    try { if ((await fs.promises.stat(p)).isDirectory()) return { fd: -100 }; } catch (_) {}
    const flags = (mode & 512) ? 'w' : mode === 0 ? 'r' : (mode & 64) ? 'a' : 'r+';
    try { return { fd: await invokeFd('open', p, flags) }; } catch (error) { throw sdkError(error); }
  };
  kitFs.close = async file => { const fd = typeof file === 'number' ? file : file.fd; if (fd >= 0) await invokeFd('close', fd); };
  kitFs.fsync = async fd => { if (fd >= 0) await invokeFd('fsync', fd); };
  kitFs.write = async (fd, data) => await invokeFd('write', fd, typeof data === 'string' ? data : Buffer.from(data));
  kitFs.read = async (fd, buffer, options = {}) => {
    const got = await invokeFd('read', fd, Buffer.from(buffer), 0, options.length ?? buffer.byteLength, options.offset ?? null);
    await control.afterRead?.(fd, got); return got;
  };
  kitFs.listFile = async p => { try { return await fs.promises.readdir(p); } catch (error) { throw sdkError(error); } };
  kitFs.rename = async (from, to) => {
    for (let attempt = 0; ; attempt++) {
      try { await fs.promises.rename(from, to); return; }
      catch (error) {
        // Windows索引器/短读句柄会暂时阻止POSIX式替换；只重试同一rename，绝不删目标。
        if (process.platform !== 'win32' || !['EPERM', 'EBUSY'].includes(error.code) || attempt >= 7) throw sdkError(error);
        await new Promise(resolve => setTimeout(resolve, 8));
      }
    }
  };
  kitFs.copyFile = async (from, to) => { try { await fs.promises.copyFile(from, to); } catch (error) { throw sdkError(error); } };
  kitFs.unlink = async p => { try { await fs.promises.unlink(p); } catch (error) { throw sdkError(error); } };
  kitFs.rmdir = async p => { try { await fs.promises.rmdir(p); } catch (error) { throw sdkError(error); } };
  kitFs.access = async p => { try { await fs.promises.access(p); return true; } catch (error) { if (error.code === 'ENOENT') return false; throw sdkError(error); } };
  const logger = { info() {}, warn() {}, error() {}, flush() {} };
  const fileUtils = { ensureDirSync: p => fs.mkdirSync(p, { recursive: true }), removeDirRecursive: p => fs.rmSync(p, { recursive: true, force: true }) };
  const context = { filesDir: directory, tempDir: path.join(directory, 'temp') };
  fs.mkdirSync(context.tempDir);
  function load(rel) {
    const absolute = path.resolve(repo, rel);
    if (cache.has(absolute)) return cache.get(absolute);
    if (absolute.endsWith('FileUtils.ets')) return fileUtils;
    if (absolute.endsWith('AppLogger.ets')) return { AppLogger: logger };
    if (absolute.endsWith('Constants.ets')) return { LOG_DOMAIN: 0 };
    if (absolute.endsWith('DiagnosticBundle.ets')) return { DiagnosticBundle: { buildEnvHeader: () => '' } };
    if (absolute.endsWith('CrashLogUploader.ets')) return { uploadCrashLog: async () => { throw new Error('author adapter excluded from host network'); } };
    let source = fs.readFileSync(absolute, 'utf8');
    if (options.transform) source = options.transform(absolute, source);
    if (absolute.endsWith('ActivityLedger.ets')) source += '\nexport { archiveFile, archiveSessionLogs, applyPlatformOutcome_ };';
    const compiled = ts.transpileModule(source, { fileName: absolute, compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText;
    const module = { exports: {} }; cache.set(absolute, module.exports);
    const dependency = name => {
      if (Object.hasOwn(options.imports ?? {}, name)) return options.imports[name];
      if (name === '@kit.CoreFileKit') return { fileIo: kitFs };
      if (name === '@kit.ArkTS') return { process: { pid: 101 }, util: { generateRandomUUID: () => crypto.randomUUID(),
        TextDecoder: { create: () => { const decoder = new TextDecoder(); return { decodeToString: (data, options) => decoder.decode(data, options) }; } } } };
      if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework: { createMd: algorithm => {
        const hash = crypto.createHash(algorithm.toLowerCase());
        // Node接受零长度update，而当前真机HCF Md.Update拒绝空DataBlob。两种API统一
        // 保留此平台边界，防止空publication/空文本在宿主被错误放行；digest本身仍允许空消息。
        const update = (data, synchronous) => {
          control.cryptoUpdates.push({ algorithm, bytes: data?.byteLength ?? -1, synchronous });
          if (!(data instanceof Uint8Array) || data.byteLength === 0) {
            const error = new Error('update failed'); error.code = 17630001; throw error;
          }
          hash.update(data);
        };
        return { updateSync: ({ data }) => update(data, true), async update({ data }) { update(data, false); },
          digestSync: () => ({ data: new Uint8Array(hash.digest()) }), async digest() { return { data: new Uint8Array(hash.digest()) }; } };
      } } };
      if (name === '@kit.NetworkKit') return { http: { RequestMethod: { POST: 'POST', GET: 'GET', DELETE: 'DELETE' }, createHttp: () => ({
        async request(url, options) {
          control.requests.push({ url, options });
          if (url.endsWith('/limits')) return { responseCode: 200, result: JSON.stringify({ maxLength: 20485760, maxLines: 200000, storageTime: 1296000 }) };
          if (options.method === 'DELETE') return { responseCode: 200, result: JSON.stringify({ success: true, deleted: [url.split('/').pop()], failed: [] }) };
          if (options.method === 'POST') {
            if (control.networkError) throw new Error('synthetic response lost');
            const body = options.header['Content-Encoding'] === 'gzip' ? zlib.gunzipSync(Buffer.from(options.extraData)).toString() : options.extraData;
            const payload = JSON.parse(body);
            control.files = payload.files || []; control.main = payload.content ?? control.files[0]?.content ?? '';
            return { responseCode: 201, result: JSON.stringify({ success: true, id: control.id, url: 'https://logshare.cn/' + control.urlId, token: 'synthetic-delete-token' }) };
          }
          if (url.includes('/v1/raw/')) {
            const name = url.split('/v1/raw/')[1].split('/').slice(1).map(decodeURIComponent).join('/');
            const original = name ? control.files.find(file => file.name === name)?.content : control.main;
            return original === undefined ? { responseCode: 404, result: 'missing' }
              : { responseCode: 200, result: control.remoteTransform?.(name, original) ?? original };
          }
          return { responseCode: 200, result: JSON.stringify({ id: control.id, files: control.files.map(({ name }) => ({ name })) }) };
        }, destroy() {},
      }) } };
      if (name === '@kit.ArkData') return { preferences: { getPreferences: async () => ({ get: async () => '', put: async () => {}, flush: async () => {} }) } };
      if (name === '@kit.AbilityKit') return { bundleManager: { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 }, getBundleInfoForSelfSync: () => ({ versionName: 'synthetic' }) } };
      if (name === '@kit.BasicServicesKit') return { ...options.basicServices, zlib: { createGZipSync: () => {
        let data, offset = 0, target, chunks = [];
        return { async gzopen(p, mode) { target = p; if (mode === 'rb') data = zlib.gunzipSync(fs.readFileSync(p)); },
          async gzfread(buffer, _size, amount) { const chunk = data.subarray(offset, offset + amount); new Uint8Array(buffer).set(chunk); offset += chunk.length; return chunk.length; },
          async gzeof() { return offset === data.length ? 1 : 0; }, async gzcloser() {},
          async gzwrite(buffer, count) { chunks.push(Buffer.from(buffer).subarray(0, count)); return count; },
          async gzclosew() { fs.writeFileSync(target, zlib.gzipSync(Buffer.concat(chunks))); return 0; },
        };
      } } };
      if (name === 'commons') return { AppLogger: logger, LOG_DOMAIN_UI: 0, ...fileUtils,
        ...Object.assign({}, ...['Base64Util', 'EvidenceTypes', 'EvidencePresentation', 'EvidenceIo', 'SessionEnvironment', 'SessionCapture', 'SessionEvidence', 'EvidenceExportSnapshot', 'LogExport', 'ActivityLedger', 'ActivityStorage', 'LogEvent', 'LogErrorSignal', 'LogNoiseFilter', 'GameLogPaths'].map(file => load('commons/src/main/ets/utils/' + file + '.ets'))),
        ...options.commons };
      if (name.startsWith('.')) return load(path.relative(repo, path.resolve(path.dirname(absolute), name + '.ets')));
      throw new Error('Unsupported test boundary: ' + name);
    };
    // Observed属于ArkUI观测引擎边界，宿主只保留原类构造器而不模拟UI刷新。
    // 因此纯任务模型的枚举、默认字段和状态/进度辅助函数仍完整来自生产模块，
    // 不必为了缺SDK装饰器而在各测试复制一份会遗漏新恢复策略的任务模型。
    new Function('require', 'module', 'exports', 'AppStorage', 'Observed', compiled)(
      dependency, module, module.exports, { get: () => context }, target => target);
    return module.exports;
  }
  return { directory, context, control, load, kitFs,
    write(relative, content) { const file = path.join(directory, relative); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, content); return file; },
    close() {
      if (path.dirname(path.resolve(directory)) !== path.resolve(workspaceTempRoot()) || !path.basename(directory).startsWith('amcl-evidence-test-')) throw new Error('Unsafe fixture cleanup path');
      fs.rmSync(directory, { recursive: true, force: true });
    },
  };
}
