/**
 * 直接执行生产 AppearanceLibrary/AppearancePng/AtomicFileWriter 的宿主回归。
 * 仅替换鸿蒙平台边界：FileIO 映射真实独占文件，SHA-256 使用 Node 真摘要，图像
 * 边界真实 inflate PNG 的 IDAT。此测试证明业务准入与事务，不冒充 ImageKit 真机验证。
 * 输出必须外置；--out 显式选择本轮 E 盘容器，不创建工程日志或安装额外依赖。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import compiler from './lib/ets-compiler.mjs';
import { PROJECT_ROOT, assertExternalOutputPath, resolveWorkspacePath } from './lib/workspace-paths.mjs';

const outArg = process.argv.indexOf('--out');
const output = assertExternalOutputPath(outArg >= 0 ? process.argv[outArg + 1] : resolveWorkspacePath('run', 'offline-skin-assets'));
fs.mkdirSync(output, { recursive: true });
const boundSources = ['account/src/main/ets/AppearanceLibrary.ets', 'account/src/main/ets/AppearancePng.ets',
  'commons/src/main/ets/utils/AtomicFileWriter.ets', 'scripts/test-appearance-library.mjs'];
const inputs = Object.fromEntries(boundSources.map(p => [p, crypto.createHash('sha256').update(fs.readFileSync(path.join(PROJECT_ROOT, p))).digest('hex')]));
const receiptName = 'receipt-' + new Date().toISOString().replaceAll(':', '-') + '-' + process.pid + '.json';
process.on('exit', code => fs.writeFileSync(path.join(output, receiptName), JSON.stringify({
  at: new Date().toISOString(), exitCode: code, sources: inputs,
  platformScope: 'host production logic with FileIO, SHA256 and bounded PNG inflate platform substitutes; no HAP/device claim',
}, null, 2)));

/** 独立夹具编码器生成真 PNG；算法与生产校验器分开实现，防止正反例共享同一个错误。 */
function crc(bytes) {
  const table = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  let value = 0xffffffff;
  for (const byte of bytes) value = table[(value ^ byte) & 0xff] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}
function chunk(type, bytes = Buffer.alloc(0)) {
  const body = Buffer.concat([Buffer.from(type, 'ascii'), bytes]);
  const header = Buffer.alloc(4), tail = Buffer.alloc(4);
  header.writeUInt32BE(bytes.length); tail.writeUInt32BE(crc(body));
  return Buffer.concat([header, body, tail]);
}
function png({ width = 64, height = 64, alpha = 173, extras = [], data, color = 6, depth = 8 } = {}) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header[8] = depth; header[9] = color;
  const channels = new Map([[0, 1], [2, 3], [3, 1], [4, 2], [6, 4]]).get(color) ?? 4;
  const rowBytes = Math.ceil(width * channels * depth / 8);
  const rows = Buffer.alloc((1 + rowBytes) * height, color === 3 ? 0 : alpha);
  for (let y = 0; y < height; y++) rows[y * (1 + rowBytes)] = 0;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header), ...extras,
    chunk('IDAT', data ?? zlib.deflateSync(rows)), chunk('IEND')]);
}

/** 所有改写平台调用共享一份状态，允许精确注入 rename 前失败与发布后的目录同步失败。 */
function fixture() {
  const directory = fs.mkdtempSync(path.join(output, 'case-')).replaceAll('\\', '/');
  const application = directory + '/app'; fs.mkdirSync(application);
  const descriptorPaths = new Map(), directoryFds = new Map(), uriPaths = new Map(), modules = new Map();
  let nextDirFd = -100, inputId = 0;
  const state = { readLimit: Infinity, writeLimit: Infinity, fault: '', lastRename: '', sourceReleased: 0,
    pixelReleased: 0, decoded: 0, remoteRequests: [], onHashUpdate: null, beforeRename: null };
  const platform = fn => {
    try { return fn(); }
    catch (error) { if (error.code === 'ENOENT') error.code = 13900002; throw error; }
  };
  const io = {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: 64, NOFOLLOW: 131072 },
    lstatSync: p => platform(() => fs.lstatSync(p)),
    statSync(p) {
      assert.equal(typeof p === 'number' || !p.startsWith('file:'), true, 'API20不能直接stat URI');
      return platform(() => typeof p === 'number' ? directoryFds.has(p) ? fs.statSync(directoryFds.get(p)) : fs.fstatSync(p) : fs.statSync(p));
    },
    mkdirSync: p => fs.mkdirSync(p), rmdirSync: p => fs.rmdirSync(p), unlinkSync: p => platform(() => fs.unlinkSync(p)),
    openSync(p, mode = 0) {
      p = uriPaths.get(p) ?? p;
      if (fs.existsSync(p) && fs.lstatSync(p).isDirectory()) { const fd = nextDirFd--; directoryFds.set(fd, p); return { fd }; }
      if ((mode & io.OpenMode.NOFOLLOW) && fs.existsSync(p)) assert.equal(fs.lstatSync(p).isSymbolicLink(), false);
      const fd = platform(() => fs.openSync(p, mode & io.OpenMode.CREATE ? 'w' : 'r'));
      descriptorPaths.set(fd, p); return { fd };
    },
    closeSync(file) { const fd = typeof file === 'number' ? file : file.fd;
      if (directoryFds.has(fd)) directoryFds.delete(fd); else { fs.closeSync(fd); descriptorPaths.delete(fd); } },
    readSync(fd, buffer, options = {}) {
      return fs.readSync(fd, Buffer.from(buffer), 0, Math.min(options.length ?? buffer.byteLength, state.readLimit), options.offset ?? null);
    },
    writeSync(fd, bytes) {
      const data = Buffer.from(bytes); return fs.writeSync(fd, data, 0, Math.min(data.length, state.writeLimit));
    },
    fsyncSync(fd) {
      if (directoryFds.has(fd)) {
        if (state.fault === 'index-directory-sync' && state.lastRename.endsWith('/library.json')) throw new Error('injected post-publish EIO');
      } else {
        if (state.fault === 'png-file-sync' && descriptorPaths.get(fd)?.includes('.png.')) throw new Error('injected PNG EIO');
        try { fs.fsyncSync(fd); }
        catch (error) {
          // Windows Node不允许对只读文件句柄FlushFileBuffers；仅在平台替身内用同一
          // 独占夹具文件的r+句柄完成真实flush，不改变生产FileIO的READ_ONLY合同。
          if (process.platform !== 'win32' || error.code !== 'EPERM') throw error;
          const writable = fs.openSync(descriptorPaths.get(fd), 'r+');
          try { fs.fsyncSync(writable); } finally { fs.closeSync(writable); }
        }
      }
    },
    renameSync(a, b) {
      state.beforeRename?.(a, b);
      if (state.fault === 'index-before-rename' && b.endsWith('/library.json')) throw new Error('injected index ENOSPC');
      fs.renameSync(a, b); state.lastRename = b;
    },
  };
  const digest = {
    createMd(algorithm) {
      assert.equal(algorithm, 'SHA256'); const hash = crypto.createHash('sha256');
      return { async update({ data }) { await state.onHashUpdate?.(); hash.update(data); },
        async digest() { return { data: new Uint8Array(hash.digest()) }; } };
    },
  };
  const image = {
    PixelMapFormat: { RGBA_8888: 'RGBA_8888' },
    createImageSource(buffer) {
      const bytes = Buffer.from(buffer), width = bytes.readUInt32BE(16), height = bytes.readUInt32BE(20);
      let released = false, busy = false;
      const run = async action => {
        assert.equal(released, false); assert.equal(busy, false, 'ImageSource不能并发'); busy = true;
        try { await Promise.resolve(); return action(); } finally { busy = false; }
      };
      return {
        getImageInfo: async () => run(() => ({ mimeType: 'image/png', size: { width, height } })),
        // 故意总返回1：APNG必须由生产字节层拒绝，不能依靠解码器识别帧数。
        getFrameCount: async () => run(() => 1),
        createPixelMap: async options => run(() => {
          const chunks = [];
          for (let at = 8; at < bytes.length;) {
            const length = bytes.readUInt32BE(at), type = bytes.toString('ascii', at + 4, at + 8);
            if (type === 'IDAT') chunks.push(bytes.subarray(at + 8, at + 8 + length));
            at += length + 12;
          }
          const pixels = zlib.inflateSync(Buffer.concat(chunks), { maxOutputLength: 128 * 1024 });
          assert.equal(pixels.length, (1 + width * 4) * height); state.decoded++;
          let pixelReleased = false;
          return { width, height, pixels, format: options?.desiredPixelFormat ?? 'PLATFORM_DEFAULT',
            async release() { assert.equal(pixelReleased, false); pixelReleased = true; state.pixelReleased++; } };
        }),
        async release() { assert.equal(busy, false); assert.equal(released, false); released = true; state.sourceReleased++; },
      };
    },
  };
  const load = relative => {
    if (modules.has(relative)) return modules.get(relative);
    const source = fs.readFileSync(path.join(PROJECT_ROOT, relative), 'utf8');
    const result = compiler.transpileModule(source, { compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 }, reportDiagnostics: true });
    assert.equal((result.diagnostics ?? []).filter(d => d.category === compiler.DiagnosticCategory.Error).length, 0, '生产文件必须可转换');
    const exports = {}; modules.set(relative, exports);
    const require = name => {
      if (name === '@kit.CoreFileKit') return { fileIo: io };
      if (name === '@kit.ImageKit') return { image };
      if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework: digest };
      if (name === '@kit.ArkTS') return { util: { generateRandomUUID: () => crypto.randomUUID() } };
      if (name === 'commons') return { ...load('commons/src/main/ets/utils/Base64Util.ets'), ...load('commons/src/main/ets/utils/AtomicFileWriter.ets'),
        getRemotePixelMap: async url => { state.remoteRequests.push(url); return remotePixel; } };
      if (name.startsWith('.')) return load(path.relative(PROJECT_ROOT, path.resolve(PROJECT_ROOT, path.dirname(relative), name + '.ets')).replaceAll('\\', '/'));
      throw new Error('unbound platform import ' + name);
    };
    new Function('exports', 'require', result.outputText)(exports, require); return exports;
  };
  const remotePixel = { remote: true, async release() { assert.fail('库不能release远程共享裸引用'); } };
  const { AppearanceLibrary } = load('account/src/main/ets/AppearanceLibrary.ets');
  const library = new AppearanceLibrary();
  return { directory, application, state, library, remotePixel, AppearanceLibrary,
    pngModule: load('account/src/main/ets/AppearancePng.ets'),
    context: { filesDir: application },
    index: () => JSON.parse(fs.readFileSync(application + '/account-textures/library.json', 'utf8')),
    add(bytes, name = '皮肤.png') { const actual = directory + '/input-' + inputId++ + '.png'; fs.writeFileSync(actual, bytes);
      const uri = 'file://fixture/' + crypto.randomUUID() + '/' + encodeURIComponent(name); uriPaths.set(uri, actual); return { uri, actual }; },
    close() {
      assert.equal(descriptorPaths.size, 0, '文件fd必须全部关闭'); assert.equal(directoryFds.size, 0, '目录fd必须全部关闭');
      const resolved = fs.realpathSync(directory), parent = fs.realpathSync(output);
      assert.equal(path.dirname(resolved), parent); assert.match(path.basename(resolved), /^case-/);
      fs.rmSync(resolved, { recursive: true, force: true });
    },
  };
}

test('真实PNG正对照、旧皮肤、透明像素和可选标准附属块通过，错误类型/尺寸/CRC/动画失败', () => {
  const f = fixture();
  try {
    const valid = png({ extras: [chunk('tEXt', Buffer.from('author\0fixture'))] });
    assert.deepEqual(f.pngModule.validateAppearancePng(valid, 'skin'), { width: 64, height: 64 });
    assert.deepEqual(f.pngModule.validateAppearancePng(png({ height: 32 }), 'cape'), { width: 64, height: 32 });
    assert.deepEqual(f.pngModule.validateAppearancePng(png({ height: 32 }), 'skin'), { width: 64, height: 32 });
    for (const bytes of [Buffer.from('not png'), png({ width: 128 }), png({ height: 48 }), valid.subarray(0, 40),
      Buffer.concat([valid, Buffer.from([0])]), png({ extras: [chunk('acTL', Buffer.alloc(8))] }),
      png({ extras: [chunk('fcTL', Buffer.alloc(26))] }), png({ extras: [chunk('fdAT', Buffer.alloc(4))] }),
      png({ extras: [chunk('ABCD')] }), Buffer.alloc(1024 * 1024 + 1)]) {
      assert.throws(() => f.pngModule.validateAppearancePng(bytes, 'skin'));
    }
    const wrongCrc = Buffer.from(valid); wrongCrc[30] ^= 1;
    assert.throws(() => f.pngModule.validateAppearancePng(wrongCrc, 'skin'), /校验/);
    assert.throws(() => f.pngModule.validateAppearancePng(png(), 'cape'), /披风尺寸/);
    // 标准允许的调色板、灰度和16位包装不能被字节准入无故拒绝；消费端完整解码另测。
    for (const config of [{ color: 0, depth: 1 }, { color: 2, depth: 16 },
      { color: 3, depth: 8, extras: [chunk('PLTE', Buffer.from([0, 0, 0, 255, 255, 255]))] }]) {
      assert.doesNotThrow(() => f.pngModule.validateAppearancePng(png(config), 'skin'));
    }
  } finally { f.close(); }
});

test('API20 fd短读+原子短写仍逐字节保留PNG；重复同kind去重，跨kind共享并持久重载', async () => {
  const f = fixture();
  try {
    f.state.readLimit = 7; f.state.writeLimit = 3;
    await Promise.all([f.library.init(f.context), f.library.init(f.context)]);
    const original = png({ height: 32, alpha: 19 }), input = f.add(original, '我的透明皮肤.png');
    const a = await f.library.importFromUri(input.uri, 'skin');
    assert.equal(a.name, '我的透明皮肤'); assert.equal(a.sha256, crypto.createHash('sha256').update(original).digest('hex'));
    assert.deepEqual(fs.readFileSync(f.library.resolvePath(a)), original);
    assert.equal((await f.library.importFromUri(f.add(original).uri, 'skin')).id, a.id);
    const cape = await f.library.importFromUri(input.uri, 'cape'); assert.notEqual(cape.id, a.id);
    assert.equal(cape.relativePath, a.relativePath); assert.equal(f.index().assets.length, 2);
    const copies = f.library.list('skin'); copies[0].name = '外部修改'; copies.length = 0;
    assert.equal(f.library.list('skin')[0].name, '我的透明皮肤');
    fs.unlinkSync(input.actual);
    const restart = new f.AppearanceLibrary(); await restart.init(f.context);
    assert.equal(restart.list('skin')[0].id, a.id); assert.equal(restart.list('cape')[0].id, cape.id);
    await assert.rejects(restart.init({ filesDir: f.directory + '/other' }), /上下文/);
    assert.equal(f.state.sourceReleased, f.state.decoded); assert.equal(f.state.pixelReleased, f.state.decoded);
  } finally { f.close(); }
});

test('不能仅靠CRC放行坏IDAT；解码失败释放ImageSource，队列仍能导入下一张', async () => {
  const f = fixture();
  try {
    await f.library.init(f.context);
    await assert.rejects(f.library.importFromUri(f.add(png({ data: Buffer.from('invalid deflate') })).uri, 'skin'));
    assert.equal(f.state.sourceReleased, 1); assert.equal(f.state.pixelReleased, 0); assert.equal(f.library.list('skin').length, 0);
    await assert.rejects(f.library.importFromUri(f.add(png({ extras: [chunk('acTL', Buffer.alloc(8))] })).uri, 'skin'), /APNG/);
    assert.equal(f.state.sourceReleased, 1, 'APNG在调用平台解码之前拒绝');
    await f.library.importFromUri(f.add(png()).uri, 'skin'); assert.equal(f.library.list('skin').length, 1);
  } finally { f.close(); }
});

test('并发导入不会覆盖彼此，等待中的删除重新检查账号使用guard', async () => {
  const f = fixture();
  try {
    await f.library.init(f.context);
    const first = await f.library.importFromUri(f.add(png()).uri, 'skin');
    let used = false, release; const gate = new Promise(r => { release = r; });
    f.state.onHashUpdate = async () => { f.state.onHashUpdate = null; await gate; };
    const importing = f.library.importFromUri(f.add(png({ alpha: 42 })).uri, 'skin');
    const removing = f.library.remove(first.id);
    f.library.setUsageGuard(id => used && id === first.id); used = true; release();
    await importing; await assert.rejects(removing, /仍被账号使用/); assert.equal(f.library.list('skin').length, 2);
    const imports = await Promise.all([f.library.importFromUri(f.add(png({ alpha: 4 })).uri, 'skin'),
      f.library.importFromUri(f.add(png({ alpha: 5 })).uri, 'skin')]);
    assert.notEqual(imports[0].id, imports[1].id); assert.equal(f.index().assets.length, 4);
  } finally { f.close(); }
});

test('删除只回收无其他kind引用的原件，备份不会恢复已删除文件的悬空条目', async () => {
  const f = fixture();
  try {
    await f.library.init(f.context); const input = f.add(png({ height: 32 }));
    const a = await f.library.importFromUri(input.uri, 'skin'), b = await f.library.importFromUri(input.uri, 'cape');
    const local = f.library.resolvePath(a); await f.library.remove(a.id); assert.equal(fs.existsSync(local), true);
    await f.library.remove(b.id); assert.equal(fs.existsSync(local), false); assert.equal(f.index().assets.length, 0);
    fs.writeFileSync(f.application + '/account-textures/library.json', '{broken');
    const restart = new f.AppearanceLibrary(); await restart.init(f.context);
    assert.equal(restart.list('skin').length, 0); assert.equal(restart.list('cape').length, 0);
    await restart.remove('missing');
  } finally { f.close(); }
});

test('rename前失败不发布新条目、不丢旧库；成功重试可复用同摘要PNG', async () => {
  const f = fixture();
  try {
    await f.library.init(f.context); const old = await f.library.importFromUri(f.add(png()).uri, 'skin');
    const next = f.add(png({ alpha: 9 })); f.state.fault = 'index-before-rename';
    await assert.rejects(f.library.importFromUri(next.uri, 'skin')); assert.equal(f.library.list('skin').length, 1);
    assert.equal(f.index().assets[0].id, old.id); f.state.fault = '';
    await f.library.importFromUri(next.uri, 'skin'); assert.equal(f.library.list('skin').length, 2);
  } finally { f.close(); }
});

test('PNG fsync失败不提交索引，所有文件和临时句柄都结束', async () => {
  const f = fixture();
  try {
    await f.library.init(f.context); f.state.fault = 'png-file-sync';
    await assert.rejects(f.library.importFromUri(f.add(png()).uri, 'skin'));
    assert.equal(f.index().assets.length, 0); assert.equal(f.library.list('skin').length, 0);
  } finally { f.close(); }
});

test('发布后持久化未知不继续用旧内存覆盖；恢复确认新索引后再追加下一张', async () => {
  const f = fixture();
  try {
    await f.library.init(f.context); await f.library.importFromUri(f.add(png()).uri, 'skin');
    f.state.fault = 'index-directory-sync'; f.state.lastRename = '';
    await assert.rejects(f.library.importFromUri(f.add(png({ alpha: 10 })).uri, 'skin'), /保存状态待确认/);
    assert.equal(f.index().assets.length, 2); assert.throws(() => f.library.list('skin'), /状态待确认/);
    f.state.fault = '';
    await f.library.importFromUri(f.add(png({ alpha: 11 })).uri, 'skin');
    assert.equal(f.library.list('skin').length, 3); assert.equal(f.index().assets.length, 3);
  } finally { f.close(); }
});

test('主索引损坏从上代恢复；双损坏与未知新版本均保持原证据并拒绝覆盖', async () => {
  const f = fixture();
  try {
    await f.library.init(f.context); const a = await f.library.importFromUri(f.add(png()).uri, 'skin');
    await f.library.importFromUri(f.add(png({ alpha: 3 })).uri, 'skin');
    const primary = f.application + '/account-textures/library.json', backup = f.application + '/account-textures/library.backup.json';
    fs.writeFileSync(primary, ''); const restored = new f.AppearanceLibrary(); await restored.init(f.context);
    assert.equal(restored.list('skin').length, 1); assert.equal(restored.list('skin')[0].id, a.id);
    fs.writeFileSync(primary, '{broken'); fs.writeFileSync(backup, '{also broken');
    await assert.rejects(new f.AppearanceLibrary().init(f.context)); assert.equal(fs.readFileSync(primary, 'utf8'), '{broken');
    fs.writeFileSync(primary, JSON.stringify({ version: 2, assets: [] })); fs.writeFileSync(backup, JSON.stringify({ version: 1, assets: [] }));
    await assert.rejects(new f.AppearanceLibrary().init(f.context), /版本/); assert.equal(JSON.parse(fs.readFileSync(primary, 'utf8')).version, 2);
  } finally { f.close(); }
});

test('本地安全路径与源文件消失边界；预览缓存不release共享裸引用，远程继续委托commons', async () => {
  const f = fixture();
  try {
    await f.library.init(f.context); const a = await f.library.importFromUri(f.add(png()).uri, 'skin');
    for (const relativePath of ['../secret.png', '/account-textures/a.png', 'account-textures/../secret',
      'account-textures/%2fsecret.png', 'file://docs/secret.png']) {
      assert.throws(() => f.library.resolvePath({ ...a, relativePath }), /引用无效/);
      assert.equal(await f.library.loadTexture('amcl-texture:' + relativePath), null);
    }
    const before = f.state.pixelReleased;
    const source = 'amcl-texture:' + a.relativePath;
    const [p, p2] = await Promise.all([f.library.loadTexture(source), f.library.loadTexture(source)]);
    assert(p); assert.equal(p, p2); assert.equal(await f.library.loadTexture(source), p);
    assert.equal(p.format, 'RGBA_8888', '软件皮肤与头像消费者必须得到明确RGBA字节，不依赖平台默认顺序');
    assert.equal(await f.library.loadTexture('https://example.invalid/a.png'), f.remotePixel);
    assert.deepEqual(f.state.remoteRequests, ['https://example.invalid/a.png']);
    await f.library.remove(a.id); assert.equal(f.state.pixelReleased, before, '已交付预览不得被库remove提前release');
    assert.equal(await f.library.loadTexture(source), null); assert.equal(p.width, 64);
  } finally { f.close(); }
});
