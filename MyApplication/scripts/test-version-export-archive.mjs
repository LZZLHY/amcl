/**
 * 执行真实ArkTS归档writer/独立校验器；只替换文件Kit和摘要Kit的平台边界。
 * 夹具显式写外置目录，Python标准库zipfile再独立打开产物，避免只靠同源读写器互证。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import compiler from './lib/ets-compiler.mjs';
import { PROJECT_ROOT, resolveWorkspacePath } from './lib/workspace-paths.mjs';

/** 每次测试独占目录；可注入短读、短写、零写与取消，不改真实账号或游戏文件。 */
function fixture({ shortRead = Infinity, shortWrite = Infinity } = {}) {
  const parent = resolveWorkspacePath('run', 'export-archive-tests'); fs.mkdirSync(parent, { recursive: true });
  const directory = fs.mkdtempSync(path.join(parent, 'amcl-version-export-'));
  const modules = new Map(), opened = new Set(), fdPaths = new Map();
  const state = { reads: 0, writes: 0, maxRead: 0, maxWrite: 0, zeroWrite: false, failReadback: false, readbackOpenCode: 13900012, readbackError: false, outputPath: '', algorithms: [] };
  const stat = p => {
    const s = typeof p === 'number' ? fs.fstatSync(p) : fs.statSync(p);
    return { size: s.size, ino: s.ino, mtime: s.mtimeMs, ctime: s.ctimeMs,
      mtimeNs: BigInt(Math.round(s.mtimeMs * 1e6)), ctimeNs: BigInt(Math.round(s.ctimeMs * 1e6)),
      isFile: () => s.isFile(), isDirectory: () => s.isDirectory(), isSymbolicLink: () => s.isSymbolicLink() };
  };
  const fileIo = {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 64, NOFOLLOW: 131072 },
    async access(p) { return fs.existsSync(p); },
    async open(p, flags = 0) {
      if (state.failReadback && p === state.outputPath && (flags & 3) === 0) {
        const error = new Error('Provider readback open failed'); error.code = state.readbackOpenCode; throw error;
      }
      if ((flags & 131072) && fs.existsSync(p) && fs.lstatSync(p).isSymbolicLink()) throw new Error('ELOOP');
      const fd = fs.openSync(p, flags & 64 ? 'wx' : flags & 2 ? 'r+' : flags & 1 ? 'w' : 'r');
      opened.add(fd); fdPaths.set(fd, p); return { fd };
    },
    async close(value) { const fd = typeof value === 'number' ? value : value.fd; fs.closeSync(fd); opened.delete(fd); fdPaths.delete(fd); },
    async stat(p) { return stat(p); },
    async lstat(p) {
      const s = fs.lstatSync(p); return { ...stat(p), isSymbolicLink: () => s.isSymbolicLink() };
    },
    async read(fd, buffer, options = {}) {
      state.reads++; state.maxRead = Math.max(state.maxRead, buffer.byteLength);
      if (state.readbackError && fdPaths.get(fd) === state.outputPath) throw new Error('Provider read EIO');
      return fs.readSync(fd, Buffer.from(buffer), 0, Math.min(options.length ?? buffer.byteLength, shortRead), options.offset ?? null);
    },
    async write(fd, buffer) {
      state.writes++; state.maxWrite = Math.max(state.maxWrite, buffer.byteLength);
      if (state.zeroWrite) return 0;
      return fs.writeSync(fd, Buffer.from(buffer), 0, Math.min(buffer.byteLength, shortWrite));
    },
    async fsync(fd) { fs.fsyncSync(fd); },
  };
  const cryptoFramework = { createMd(algorithm) {
    state.algorithms.push(algorithm);
    const digest = crypto.createHash(algorithm.toLowerCase());
    return { async update({ data }) { digest.update(data); }, async digest() { return { data: new Uint8Array(digest.digest()) }; } };
  } };
  function load(relative) {
    if (modules.has(relative)) return modules.get(relative);
    const source = fs.readFileSync(path.join(PROJECT_ROOT, relative), 'utf8');
    const js = compiler.transpileModule(source, { compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 } }).outputText;
    const exports = {}; modules.set(relative, exports);
    const require = name => {
      if (name === '@kit.CoreFileKit') return { fileIo };
      if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework };
      if (name === 'commons') return { stringToUtf8: text => new Uint8Array(Buffer.from(text, 'utf8')), AppLogger: { warn() {} } };
      if (name === 'libentry.so') return { default: {} };
      if (name === 'feature_core') return load('feature_core/src/main/ets/export/ExportZipFormat.ets');
      if (name.startsWith('.')) return load(path.relative(PROJECT_ROOT, path.resolve(PROJECT_ROOT, path.dirname(relative), name + '.ets')).replaceAll('\\', '/'));
      throw new Error('Unmocked dependency: ' + name);
    };
    new Function('exports', 'require', js)(exports, require); return exports;
  }
  const io = load('entry/src/main/ets/export/ExportArchiveIO.ets');
  const format = load('feature_core/src/main/ets/export/ExportZipFormat.ets');
  const snapshot = path.join(directory, 'snapshot'); fs.mkdirSync(snapshot);
  function file(name, bytes) {
    const target = path.join(snapshot, name); fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, bytes);
    return { archivePath: name, directory: false, size: bytes.length, sha256: crypto.createHash('sha256').update(bytes).digest('hex') };
  }
  function dir(name) { fs.mkdirSync(path.join(snapshot, name), { recursive: true }); return { archivePath: name, directory: true, size: 0, sha256: '' }; }
  return { directory, snapshot, state, io, format, file, dir, opened,
    close() {
      assert.equal(opened.size, 0, 'every owner must close its descriptors');
      // Windows递归删除仅允许mkdtemp直接子目录，先实取路径以防误删共享父目录。
      const actual = fs.realpathSync(directory), base = fs.realpathSync(parent);
      assert.equal(path.dirname(actual), base); assert(path.basename(actual).startsWith('amcl-version-export-'));
      fs.rmSync(actual, { recursive: true, force: true });
    },
  };
}

/** 不仅验证容器能列目录：Python逐条解压并核对内容SHA，覆盖中文/emoji/空文件/空目录。 */
test('production ZIP64 writer handles short I/O and Python independently reads every entry', async () => {
  const f = fixture({ shortRead: 4093, shortWrite: 1013 });
  try {
    const files = [f.dir('空目录'), f.file('模组/🙂.jar.disabled', crypto.randomBytes(180000)), f.file('options.txt', Buffer.from('中文\n')), f.file('empty', Buffer.alloc(0))];
    const archive = path.join(f.directory, 'pack.zip'); const progress = [];
    await f.io.writeExportArchive(f.snapshot, archive, files, () => false, (count, bytes) => progress.push([count, bytes]));
    await f.io.verifyExportArchive(archive, files, () => false);
    assert.deepEqual(progress.at(-1), [4, 180007]); assert(f.state.maxRead <= 65536); assert(f.state.maxWrite <= 65536);
    const result = spawnSync(process.env.PYTHON ?? 'python', ['-B', '-c',
      'import sys,json,zipfile,hashlib; z=zipfile.ZipFile(sys.argv[1]); print(json.dumps([{ "path": i.filename,"directory":i.is_dir(),"size":i.file_size,"sha256":hashlib.sha256(z.read(i)).hexdigest()} for i in z.infolist()],ensure_ascii=False))', archive], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    const observed = JSON.parse(result.stdout);
    assert.deepEqual(observed.map(item => [item.path, item.directory, item.size, item.directory ? '' : item.sha256]),
      files.map(item => [item.archivePath + (item.directory ? '/' : ''), item.directory, item.size, item.sha256]));
  } finally { f.close(); }
});

/** 真实fileIo错误码不等同POSIX errno：只允许授权/功能限制，未知及目标故障必须阻断确认。 */
for (const code of [13900001, 13900012, 13900031, 13900002, 13900005, 13900013, 13900038, undefined]) {
  test(`URI readback open classifies fileIo error ${code}`, async () => {
    const f = fixture();
    try {
      const source = path.join(f.snapshot, 'source'); const destination = path.join(f.directory, 'target');
      fs.writeFileSync(source, 'written bytes'); fs.writeFileSync(destination, '');
      f.state.outputPath = destination; f.state.failReadback = true; f.state.readbackOpenCode = code;
      if ([13900001, 13900012, 13900031].includes(code)) {
        const receipt = await f.io.copyExportArchiveToUri(source, destination, () => false, () => {});
        assert.equal(receipt.readbackVerified, false); assert.equal(receipt.size, 13);
      } else {
        await assert.rejects(f.io.copyExportArchiveToUri(source, destination, () => false, () => {}), error => error.code === code);
      }
      assert.equal(fs.readFileSync(destination, 'utf8'), 'written bytes');
    } finally { f.close(); }
  });
}

test('hash helper returns actual SHA1 and SHA256, including empty files', async () => {
  const f = fixture({ shortRead: 317 });
  try {
    for (const bytes of [Buffer.alloc(0), crypto.randomBytes(140001)]) {
      f.file('hash.bin', bytes);
      assert.deepEqual(await f.io.hashExportFile(path.join(f.snapshot, 'hash.bin'), () => false), {
        size: bytes.length, sha1: crypto.createHash('sha1').update(bytes).digest('hex'), sha256: crypto.createHash('sha256').update(bytes).digest('hex') });
    }
  } finally { f.close(); }
});

/** 依赖入口沿生产Kit读取与关闭核心，只创建SHA1；空文件与多chunk短读仍返回真实长度。 */
test('dependency hash purpose uses only SHA1 in Kit fallback and preserves generic dual hashing', async () => {
  const f = fixture({ shortRead: 317 });
  try {
    for (const bytes of [Buffer.alloc(0), crypto.randomBytes(140001)]) {
      f.file('dependency.bin', bytes); const source = path.join(f.snapshot, 'dependency.bin');
      f.state.algorithms.length = 0;
      assert.deepEqual(await f.io.hashExportDependencyFile(source, () => false), {
        size: bytes.length, sha1: crypto.createHash('sha1').update(bytes).digest('hex'), sha256: '' });
      assert.deepEqual(f.state.algorithms, ['SHA1']);
      f.state.algorithms.length = 0;
      assert.deepEqual(await f.io.hashExportFile(source, () => false), {
        size: bytes.length, sha1: crypto.createHash('sha1').update(bytes).digest('hex'),
        sha256: crypto.createHash('sha256').update(bytes).digest('hex') });
      assert.deepEqual(f.state.algorithms, ['SHA1', 'SHA256']); assert.equal(f.opened.size, 0);
    }
  } finally { f.close(); }
});

test('verifier rejects byte corruption, wrong planned hash, central path changes and trailing payload', async () => {
  const f = fixture();
  try {
    const files = [f.file('data.bin', Buffer.from('known payload'))]; const archive = path.join(f.directory, 'pack.zip');
    await f.io.writeExportArchive(f.snapshot, archive, files, () => false, () => {}); const original = fs.readFileSync(archive);
    for (const mutate of [b => { b[50 + 8] ^= 1; }, b => { b[b.indexOf(Buffer.from('PK\x01\x02', 'binary')) + 46] ^= 1; }]) {
      const bytes = Buffer.from(original); mutate(bytes); fs.writeFileSync(archive, bytes);
      await assert.rejects(f.io.verifyExportArchive(archive, files, () => false), /归档/);
    }
    fs.writeFileSync(archive, original);
    await assert.rejects(f.io.verifyExportArchive(archive, [{ ...files[0], sha256: '0'.repeat(64) }], () => false), /归档/);
    fs.appendFileSync(archive, 'unexpected'); await assert.rejects(f.io.verifyExportArchive(archive, files, () => false), /归档/);
  } finally { f.close(); }
});

test('writer rejects invalid plans and mutated snapshots before declaring success', async () => {
  const f = fixture();
  try {
    const item = f.file('data.bin', Buffer.from('snapshot')); const output = name => path.join(f.directory, name + '.zip');
    for (const archivePath of ['../secret', '/absolute', 'C:/secret', 'a\\b', 'a//b']) {
      await assert.rejects(f.io.writeExportArchive(f.snapshot, output('invalid'), [{ ...item, archivePath }], () => false, () => {}));
      assert(!fs.existsSync(output('invalid')));
    }
    await assert.rejects(f.io.writeExportArchive(f.snapshot, output('collision'), [item, { ...item, archivePath: 'DATA.BIN' }], () => false, () => {}), /冲突/);
    fs.writeFileSync(path.join(f.snapshot, 'data.bin'), 'different');
    await assert.rejects(f.io.writeExportArchive(f.snapshot, output('changed'), [item], () => false, () => {}), /快照/);
  } finally { f.close(); }
});

test('cancellation and zero writes settle the running I/O and release every file', async () => {
  const f = fixture();
  try {
    const files = [f.file('big.bin', crypto.randomBytes(220000))]; const archive = path.join(f.directory, 'cancel.zip');
    await assert.rejects(f.io.writeExportArchive(f.snapshot, archive, files, () => f.state.writes > 2, () => {}), /取消/);
    assert.equal(f.opened.size, 0);
    f.state.zeroWrite = true;
    await assert.rejects(f.io.writeExportArchive(f.snapshot, path.join(f.directory, 'zero.zip'), files, () => false, () => {}), /写入/);
  } finally { f.close(); }
});

test('URI copy refuses nonempty destinations, handles short writes, and verifies actual readback', async () => {
  const f = fixture({ shortWrite: 71 });
  try {
    const source = path.join(f.snapshot, 'source'); const destination = path.join(f.directory, 'target');
    const bytes = crypto.randomBytes(130003); fs.writeFileSync(source, bytes); fs.writeFileSync(destination, 'KEEP');
    await assert.rejects(f.io.copyExportArchiveToUri(source, destination, () => false, () => {}), /已有内容/);
    assert.equal(fs.readFileSync(destination, 'utf8'), 'KEEP'); fs.writeFileSync(destination, '');
    const receipt = await f.io.copyExportArchiveToUri(source, destination, () => false, () => {});
    assert.deepEqual(receipt, { size: bytes.length, sha256: crypto.createHash('sha256').update(bytes).digest('hex'), readbackVerified: true });
    assert.deepEqual(fs.readFileSync(destination), bytes);
    assert.deepEqual(f.state.algorithms, ['SHA256', 'SHA256'], '目标复制与读回均只需要SHA256，不能创建无用SHA1');
  } finally { f.close(); }
});

test('URI copy reports partial output on cancel and leaves source unchanged', async () => {
  const f = fixture();
  try {
    const source = path.join(f.snapshot, 'source'); const destination = path.join(f.directory, 'target');
    const bytes = crypto.randomBytes(220000); fs.writeFileSync(source, bytes); fs.writeFileSync(destination, '');
    let copied = 0;
    await assert.rejects(f.io.copyExportArchiveToUri(source, destination, () => copied > 0, value => { copied = value; }), /取消.*未完成文件/);
    assert(fs.statSync(destination).size > 0 && fs.statSync(destination).size < bytes.length); assert.deepEqual(fs.readFileSync(source), bytes);
  } finally { f.close(); }
});

test('URI capability failure is distinct from an I/O failure after readback opened', async () => {
  const f = fixture();
  try {
    const source = path.join(f.snapshot, 'source'); const destination = path.join(f.directory, 'target');
    fs.writeFileSync(source, 'content'); fs.writeFileSync(destination, ''); f.state.outputPath = destination;
    f.state.failReadback = true;
    const unverified = await f.io.copyExportArchiveToUri(source, destination, () => false, () => {});
    assert.equal(unverified.readbackVerified, false); assert.equal(unverified.size, 7);
    fs.writeFileSync(destination, ''); f.state.failReadback = false; f.state.readbackError = true;
    await assert.rejects(f.io.copyExportArchiveToUri(source, destination, () => false, () => {}), /EIO/);
  } finally { f.close(); }
});

test('ZIP64 encodes sizes and offsets above 4GiB without 32bit truncation and rejects unsafe numbers', () => {
  const f = fixture();
  try {
    const name = new Uint8Array(Buffer.from('large.bin')); const size = 0x100000005; const offset = 0x200000007;
    const central = Buffer.from(f.format.exportZipCentralHeader(name, size, 123, offset, false)); const extra = 46 + name.length;
    assert.equal(central.readBigUInt64LE(extra + 4), BigInt(size)); assert.equal(central.readBigUInt64LE(extra + 12), BigInt(size));
    assert.equal(central.readBigUInt64LE(extra + 20), BigInt(offset));
    const end = Buffer.from(f.format.exportZipEnd(65536, 0x100000001, offset));
    assert.equal(end.readBigUInt64LE(24), 65536n); assert.equal(end.readBigUInt64LE(64), BigInt(offset + 0x100000001));
    assert.throws(() => f.format.exportZipEnd(1, 0, Number.MAX_SAFE_INTEGER + 1), /安全整数/);
  } finally { f.close(); }
});

test('Python accepts more than 65535 ZIP64 entries built with production header functions', () => {
  const f = fixture();
  try {
    const local = [], central = []; let offset = 0;
    for (let index = 0; index < 65536; index++) {
      const name = new Uint8Array(Buffer.from('empty-' + index + '/'));
      const header = f.format.exportZipLocalHeader(name, 0); const descriptor = f.format.exportZipDescriptor(0, 0);
      local.push(header, descriptor); central.push(f.format.exportZipCentralHeader(name, 0, 0, offset, true)); offset += header.length + descriptor.length;
    }
    const centralBytes = Buffer.concat(central); const archive = path.join(f.directory, 'many.zip');
    fs.writeFileSync(archive, Buffer.concat([...local, centralBytes, f.format.exportZipEnd(65536, centralBytes.length, offset)]));
    const result = spawnSync(process.env.PYTHON ?? 'python', ['-B', '-c', 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); assert len(z.infolist())==65536; assert all(i.is_dir() for i in z.infolist()); assert z.testzip() is None; print("65536 entries independently verified")', archive], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
  } finally { f.close(); }
});
