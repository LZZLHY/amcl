/** 执行真实生成JAR校验器；FileIO只映射到E夹具，SDK解压边界用Node原生inflate实现独立解码。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { crc32, deflateRawSync, inflateRawSync } from 'node:zlib';
import compiler from './lib/ets-compiler.mjs';
import { PROJECT_ROOT, resolveWorkspacePath } from './lib/workspace-paths.mjs';

/** 独立构造经典ZIP，CRC使用Node原生zlib，不依赖生产writer或生产CRC算法。 */
function makeJar(entries) {
  const locals = [], centrals = []; let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name), bytes = Buffer.from(entry.bytes ?? ''), method = entry.method ?? 8;
    const payload = method === 8 ? deflateRawSync(bytes) : bytes; const flags = 2048 | (entry.descriptor ? 8 : 0) | (entry.flags ?? 0);
    const crc = entry.crc ?? crc32(bytes); const local = Buffer.alloc(30); const central = Buffer.alloc(46);
    local.writeUInt32LE(0x04034b50); local.writeUInt16LE(20, 4); local.writeUInt16LE(flags, 6); local.writeUInt16LE(method, 8);
    local.writeUInt32LE(entry.descriptor ? 0 : crc, 14); local.writeUInt32LE(entry.descriptor ? 0 : payload.length, 18);
    local.writeUInt32LE(entry.descriptor ? 0 : bytes.length, 22); local.writeUInt16LE(name.length, 26);
    central.writeUInt32LE(0x02014b50); central.writeUInt16LE(0x0314, 4); central.writeUInt16LE(20, 6);
    central.writeUInt16LE(flags, 8); central.writeUInt16LE(method, 10); central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(payload.length, 20); central.writeUInt32LE(bytes.length, 24); central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE(((entry.unixMode ?? (entry.name.endsWith('/') ? 0o40755 : 0o100644)) * 65536) >>> 0, 38);
    central.writeUInt32LE(offset, 42); locals.push(local, name, payload); centrals.push(central, name); offset += 30 + name.length + payload.length;
    if (entry.descriptor) { const descriptor = Buffer.alloc(16); descriptor.writeUInt32LE(0x08074b50); descriptor.writeUInt32LE(crc, 4);
      descriptor.writeUInt32LE(payload.length, 8); descriptor.writeUInt32LE(bytes.length, 12); locals.push(descriptor); offset += descriptor.length; }
  }
  const central = Buffer.concat(centrals), end = Buffer.alloc(22); end.writeUInt32LE(0x06054b50);
  end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10); end.writeUInt32LE(central.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, central, end]);
}

/** SDK替身不验证CRC，保证CRC损坏负例实际由生产校验器的逐文件读回发现。 */
function extractJar(bytes, output) {
  const count = bytes.readUInt16LE(bytes.length - 12); let cursor = bytes.readUInt32LE(bytes.length - 6);
  for (let index = 0; index < count; index++) {
    const method = bytes.readUInt16LE(cursor + 10), compressed = bytes.readUInt32LE(cursor + 20), offset = bytes.readUInt32LE(cursor + 42);
    const nameSize = bytes.readUInt16LE(cursor + 28), extra = bytes.readUInt16LE(cursor + 30), comment = bytes.readUInt16LE(cursor + 32);
    const name = bytes.subarray(cursor + 46, cursor + 46 + nameSize).toString('utf8'); const target = path.resolve(output, name);
    assert(target.startsWith(output + path.sep));
    if (name.endsWith('/')) fs.mkdirSync(target, { recursive: true });
    else { const start = offset + 30 + bytes.readUInt16LE(offset + 26) + bytes.readUInt16LE(offset + 28);
      const payload = bytes.subarray(start, start + compressed); fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, method === 8 ? inflateRawSync(payload) : payload); }
    cursor += 46 + nameSize + extra + comment;
  }
}

function fixture() {
  const parent = resolveWorkspacePath('run', 'generated-jar-tests'); fs.mkdirSync(parent, { recursive: true });
  const directory = fs.mkdtempSync(path.join(parent, 'amcl-generated-jar-')), opened = new Set(), cache = new Map();
  const state = { sdkCalls: 0, sdkRunning: false, corrupt: false, gate: null, started: null, maxRead: 0 };
  function physical(p) { assert(p.startsWith('/')); const actual = path.resolve(directory, '.' + p); assert(actual.startsWith(directory + path.sep) || actual === directory); return actual; }
  function stat(p, link = false) {
    try { const s = typeof p === 'number' ? fs.fstatSync(p) : link ? fs.lstatSync(physical(p)) : fs.statSync(physical(p)); return {
      size: s.size, ino: s.ino, mtime: s.mtimeMs, ctime: s.ctimeMs, isDirectory: () => s.isDirectory(), isFile: () => s.isFile(), isSymbolicLink: () => s.isSymbolicLink() }; }
    catch (error) { if (error.code === 'ENOENT') error.code = 13900002; throw error; }
  }
  const fileIo = {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: 64, NOFOLLOW: 131072 },
    async open(p, flags = 0) { const fd = fs.openSync(physical(p), flags & 64 ? 'w' : 'r'); opened.add(fd); return { fd }; },
    async close(value) { const fd = typeof value === 'number' ? value : value.fd; fs.closeSync(fd); opened.delete(fd); },
    async stat(p) { return stat(p); }, async lstat(p) { return stat(p, true); },
    async mkdir(p, recursive = false) { fs.mkdirSync(physical(p), { recursive }); }, async listFile(p) { return fs.readdirSync(physical(p)); },
    async unlink(p) { assert(!state.sdkRunning, 'cleanup must await SDK owner'); fs.unlinkSync(physical(p)); },
    async rmdir(p) { assert(!state.sdkRunning, 'cleanup must await SDK owner'); fs.rmdirSync(physical(p)); },
    async fsync(fd) { fs.fsyncSync(fd); },
    async read(fd, buffer, options = {}) { state.maxRead = Math.max(state.maxRead, buffer.byteLength);
      return fs.readSync(fd, Buffer.from(buffer), 0, Math.min(options.length ?? buffer.byteLength, 4093), options.offset ?? null); },
    async write(fd, buffer) { return fs.writeSync(fd, Buffer.from(buffer), 0, Math.min(buffer.byteLength, 1013)); },
  };
  const zlib = { async decompressFile(input, output) {
    state.sdkCalls++; state.sdkRunning = true;
    try {
      assert(input.endsWith('.zip')); if (state.started) state.started(); if (state.gate) await state.gate;
      extractJar(fs.readFileSync(physical(input)), physical(output));
      if (state.corrupt) { const target = path.join(physical(output), 'net/minecraft/client/Minecraft.class'); const bytes = fs.readFileSync(target); bytes[0] ^= 255; fs.writeFileSync(target, bytes); }
    } finally { state.sdkRunning = false; }
  } };
  function load(relative) {
    if (cache.has(relative)) return cache.get(relative);
    const exports = {}; cache.set(relative, exports); const source = fs.readFileSync(path.join(PROJECT_ROOT, relative), 'utf8');
    const js = compiler.transpileModule(source, { compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 } }).outputText;
    const require = name => {
      if (name === '@kit.CoreFileKit') return { fileIo };
      if (name === '@kit.BasicServicesKit') return { zlib };
      if (name === '@kit.ArkTS') return { util: { generateRandomUUID: crypto.randomUUID } };
      if (name === 'commons') return load('commons/src/main/ets/utils/Base64Util.ets');
      if (name === 'feature_core') return load('feature_core/src/main/ets/export/ExportZipFormat.ets');
      throw new Error('Unmocked module: ' + name);
    };
    new Function('exports', 'require', js)(exports, require); return exports;
  }
  fs.mkdirSync(physical('/source')); const { verifyExportJar, extractVerifiedExportJar } = load('entry/src/main/ets/export/ExportJarVerifier.ets');
  return { state, directory, physical,
    async verify(bytes, required = ['net/minecraft/client/Minecraft.class'], prefixes = ['assets/minecraft/'], cancelled = () => false) {
      fs.writeFileSync(physical('/source/generated.jar'), bytes); return verifyExportJar('/source/generated.jar', '/scratch', required, prefixes, cancelled);
    },
    async extract(bytes, target = '/unpacked/content') {
      fs.writeFileSync(physical('/source/generated.jar'), bytes);
      return extractVerifiedExportJar('/source/generated.jar', target, ['net/minecraft/client/Minecraft.class'], ['assets/minecraft/'], () => false);
    },
    close() { assert.equal(opened.size, 0); assert.equal(state.sdkRunning, false);
      if (fs.existsSync(physical('/scratch'))) assert.deepEqual(fs.readdirSync(physical('/scratch')), []);
      const actual = fs.realpathSync(directory), base = fs.realpathSync(parent); assert.equal(path.dirname(actual), base);
      assert(path.basename(actual).startsWith('amcl-generated-jar-')); fs.rmSync(actual, { recursive: true, force: true }); },
  };
}

const contents = [ { name: 'net/minecraft/client/Minecraft.class', bytes: Buffer.from([0xca, 0xfe, 0xba, 0xbe, 1, 2, 3]) },
  { name: 'assets/minecraft/lang/中文.json', bytes: '{"test":true}' }, { name: 'empty/', bytes: '', method: 0 } ];

for (const method of [0, 8]) for (const descriptor of [false, true]) test(`actual verifier accepts method=${method}, descriptor=${descriptor}, Unicode and empty directories`, async () => {
  const f = fixture(); try { await f.verify(makeJar(contents.map(entry => ({ ...entry, method, descriptor })))); assert.equal(f.state.sdkCalls, 1); assert(f.state.maxRead <= 65536); } finally { f.close(); }
});

for (const kind of ['crc', 'truncated', 'traversal', 'absolute', 'symlink', 'duplicate', 'method', 'encrypted', 'missing-class', 'empty-class', 'missing-prefix']) {
  test('actual verifier rejects ' + kind, async () => {
    const f = fixture();
    try {
      let entries = contents.map(entry => ({ ...entry }));
      if (kind === 'crc') entries[0].crc = 0;
      if (kind === 'traversal') entries.push({ name: '../escape', bytes: 'bad' });
      if (kind === 'absolute') entries.push({ name: '/outside', bytes: 'bad' });
      if (kind === 'symlink') entries.push({ name: 'link', bytes: '../outside', unixMode: 0o120777 });
      if (kind === 'duplicate') entries.push({ ...entries[0] });
      if (kind === 'method') entries[0].method = 12;
      if (kind === 'encrypted') entries[0].flags = 1;
      if (kind === 'missing-class') entries = entries.slice(1);
      if (kind === 'empty-class') entries[0].bytes = '';
      if (kind === 'missing-prefix') entries = entries.filter(entry => !entry.name.startsWith('assets/'));
      let bytes = makeJar(entries); if (kind === 'truncated') bytes = bytes.subarray(0, bytes.length - 5);
      await assert.rejects(f.verify(bytes), /JAR/);
      assert.equal(f.state.sdkCalls, kind === 'crc' ? 1 : 0, 'dangerous or incomplete structure must never reach SDK extraction');
    } finally { f.close(); }
  });
}

test('actual readback CRC catches changed SDK output even when archive metadata was valid', async () => {
  const f = fixture(); try { f.state.corrupt = true; await assert.rejects(f.verify(makeJar(contents)), /CRC/); } finally { f.close(); }
});

test('cancellation during noninterruptible SDK extraction waits for its owner before cleanup', async () => {
  const f = fixture(); let cancelled = false, release; const started = new Promise(resolve => { f.state.started = resolve; });
  f.state.gate = new Promise(resolve => { release = resolve; });
  try {
    let settled = false; const pending = f.verify(makeJar(contents), undefined, undefined, () => cancelled).finally(() => { settled = true; });
    await started; cancelled = true; await new Promise(resolve => setImmediate(resolve)); assert.equal(settled, false);
    assert.equal(f.state.sdkRunning, true); assert.equal(fs.readdirSync(f.physical('/scratch')).length, 1);
    release(); await assert.rejects(pending, /取消/);
  } finally { release(); f.close(); }
});

test('verified extraction retains its already-checked contents without decompressing twice', async () => {
  const f = fixture();
  try {
    await f.extract(makeJar(contents)); assert.equal(f.state.sdkCalls, 1);
    assert.deepEqual(fs.readFileSync(f.physical('/unpacked/content/net/minecraft/client/Minecraft.class')), contents[0].bytes);
    assert.equal(fs.readFileSync(f.physical('/unpacked/content/assets/minecraft/lang/中文.json'), 'utf8'), contents[1].bytes);
    assert.deepEqual(fs.readdirSync(f.physical('/unpacked')), ['content']);
  } finally { f.close(); }
});

test('verified extraction refuses to take over any existing target and preserves its bytes', async () => {
  const f = fixture();
  try {
    fs.mkdirSync(f.physical('/unpacked/content'), { recursive: true }); fs.writeFileSync(f.physical('/unpacked/content/keep'), 'KEEP');
    await assert.rejects(f.extract(makeJar(contents)), /已存在.*拒绝接管/); assert.equal(f.state.sdkCalls, 0);
    assert.equal(fs.readFileSync(f.physical('/unpacked/content/keep'), 'utf8'), 'KEEP');
  } finally { f.close(); }
});

/** 本机可选的真实官方样本仅由环境显式提供；独立克隆/CI不依赖维护者的E盘材料。 */
if (process.env.AMCL_EXPORT_JAR_SAMPLES) {
  const samples = JSON.parse(process.env.AMCL_EXPORT_JAR_SAMPLES);
  assert(Array.isArray(samples) && samples.every(name => typeof name === 'string' && path.isAbsolute(name)));
  const receipts = [];
  for (const sample of samples) test('optional published installer ZIP validation: ' + path.basename(sample), async () => {
    const f = fixture();
    try {
      const bytes = fs.readFileSync(sample); await f.verify(bytes, ['install_profile.json'], []);
      receipts.push({ path: sample, bytes: bytes.length, sha1: crypto.createHash('sha1').update(bytes).digest('hex'),
        sha256: crypto.createHash('sha256').update(bytes).digest('hex'), verified: true, sdkCalls: f.state.sdkCalls });
      const out = resolveWorkspacePath('run', 'generated-jar-samples'); fs.mkdirSync(out, { recursive: true });
      fs.writeFileSync(path.join(out, 'receipt.json'), JSON.stringify({ capturedAt: new Date().toISOString(), samples: receipts }, null, 2));
    } finally { f.close(); }
  });
}
