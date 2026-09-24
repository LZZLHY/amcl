// 宿主适配仅替换 OHOS 系统边界；被测实现直接从生产 .ets 编译，禁止真实网络发送。
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import ts from './ets-compiler.mjs';
const repo = path.resolve(import.meta.dirname, '../..');
export function evidenceRuntime(options = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'amcl-evidence-test-'));
  const cache = new Map();
  const control = { afterRead: undefined, failWrite: undefined, requests: [], files: [], main: '',
    remoteTransform: undefined, id: 'sAbCdEf', urlId: 'sAbCdEf', networkError: false };
  const stat = p => {
    const value = typeof p === 'number' ? fs.fstatSync(p, { bigint: true }) : fs.statSync(p, { bigint: true });
    return { size: Number(value.size), mtime: Number(value.mtimeMs / 1000n), ctime: Number(value.ctimeMs / 1000n),
      ino: value.ino, mtimeNs: value.mtimeNs, ctimeNs: value.ctimeNs, isFile: () => value.isFile(), isDirectory: () => value.isDirectory() };
  };
  const kitFs = {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
    statSync: stat, stat: async p => stat(p), lstatSync: stat,
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
    readTextSync: p => fs.readFileSync(p, 'utf8'), listFileSync: p => fs.readdirSync(p), listFile: async p => fs.readdirSync(p),
    mkdirSync: p => fs.mkdirSync(p, { recursive: true }), renameSync: fs.renameSync,
    unlinkSync: fs.unlinkSync, copyFileSync: fs.copyFileSync, accessSync: fs.existsSync,
    rmdirSync: p => fs.rmSync(p, { recursive: true }),
  };
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
        return { updateSync: ({ data }) => hash.update(data), async update({ data }) { hash.update(data); },
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
        ...Object.assign({}, ...['Base64Util', 'EvidenceTypes', 'EvidencePresentation', 'EvidenceIo', 'SessionEnvironment', 'SessionEvidence', 'EvidenceExportSnapshot', 'LogExport', 'ActivityLedger', 'ActivityStorage', 'LogEvent', 'LogErrorSignal', 'LogNoiseFilter', 'GameLogPaths'].map(file => load('commons/src/main/ets/utils/' + file + '.ets'))),
        ...options.commons };
      if (name.startsWith('.')) return load(path.relative(repo, path.resolve(path.dirname(absolute), name + '.ets')));
      throw new Error('Unsupported test boundary: ' + name);
    };
    new Function('require', 'module', 'exports', 'AppStorage', compiled)(dependency, module, module.exports, { get: () => context });
    return module.exports;
  }
  return { directory, context, control, load, kitFs,
    write(relative, content) { const file = path.join(directory, relative); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, content); return file; },
    close() {
      if (path.dirname(path.resolve(directory)) !== path.resolve(os.tmpdir()) || !path.basename(directory).startsWith('amcl-evidence-test-')) throw new Error('Unsafe fixture cleanup path');
      fs.rmSync(directory, { recursive: true, force: true });
    },
  };
}
