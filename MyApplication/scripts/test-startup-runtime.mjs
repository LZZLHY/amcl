#!/usr/bin/env node
/**
 * 执行真实 RuntimeDeployer ArkTS 类的启动异步部署，不复制部署、摘要或提交判据。
 * 仅以内存文件系统、延迟摘要和 native 端口替换设备环境；固定测试清单与字节用于
 * 注入跨块、短写、视图偏移及提交故障，不代替真实清单门禁或 native flock 验证。
 * 没有宿主临时文件或清理动作；只有显式 --output-dir 才将报告写到仓外目录。
 */
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { assertExternalOutputPath } from './lib/workspace-paths.mjs';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const arguments_ = process.argv.slice(2);
assert.ok(arguments_.length === 0 || (arguments_.length === 2 && arguments_[0] === '--output-dir'),
  '用法：node scripts/test-startup-runtime.mjs [--output-dir 仓外绝对目录]');
const outputDirectory = arguments_.length ? arguments_[1] : undefined;
if (outputDirectory) assert.ok(path.isAbsolute(outputDirectory), '--output-dir 必须是绝对路径');
const sourcePaths = ['launch/src/main/ets/RuntimeDeployer.ets', 'launch/src/main/ets/RuntimeSlotGenerations.ets'];
const sources = sourcePaths.map(relative => ({ path: relative,
  sha256: crypto.createHash('sha256').update(fs.readFileSync(path.join(repository, relative))).digest('hex') }));
const results = [];
const block = 256 * 1024;

/** 向下一事件循环投递，强制生产代码实际跨 await，而非只用已完成 Promise。 */
const nextTurn = () => new Promise(resolve => setImmediate(resolve));
/** 只为固定夹具计算独立参考身份，业务摘要由真实生产方法执行。 */
const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
/** 生成不重复的二进制内容，避免错误尾块或零填充刚好等于预期。 */
function fixtureBytes(length, seed) {
  const bytes = Buffer.alloc(length);
  for (let index = 0; index < length; index++) bytes[index] = (index * 29 + seed * 13) % 251;
  return bytes;
}

/**
 * 每个用例拥有全新的内存文件、句柄、stage owner 与注入开关，互不共享可写状态。
 * fs 操作遵循 SDK 默认 fd 游标；不实现目录事务，目录提交只交给下方 native 替身。
 */
function fixture(configuration = {}) {
  const files = new Map(), directories = new Set(['/']), handles = new Map(), stages = new Set();
  const events = [], logs = [], resources = new Map(), pendingDigestBuffers = new Set();
  let nextFd = 1, stageSequence = 0, markerReads = 0;
  const mode = { ...configuration };
  const counters = { reads: 0, writes: 0, rawViews: [], digestLengths: [], yields: 0 };
  const flags = { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: 64, TRUNC: 512 };
  const slotNames = ['lwjgl-ohos', 'lwjgl-ohos-322', 'lwjgl-ohos-2'];
  const slots = new Map();
  for (const [index, name] of slotNames.entries()) {
    const jars = [{ name: 'lwjgl.jar', size: index === 0 ? block * 2 + 37 : 12000 + index }];
    if (index === 0) jars.push({ name: 'extra.jar', size: 73 });
    for (const jar of jars) {
      const bytes = fixtureBytes(jar.size, index + jar.size);
      jar.sha256 = sha256(bytes); jar.resourcePath = name + '/' + jar.name;
      resources.set(jar.resourcePath, bytes);
    }
    const identity = sha256(Buffer.from(JSON.stringify(jars)));
    slots.set(name, { id: name, version: 'fixture', deploymentDirectory: name, jars,
      marker: 'amcl.lwjgl.startup-fixture\nmanifest=' + identity + '\n' });
  }

  /** 递归创建虚拟目录，仅增加 Set 条目，不触及主机路径。 */
  function mkdir(directory) {
    if (directories.has(directory)) return;
    mkdir(path.posix.dirname(directory)); directories.add(directory);
  }
  /** 模拟缺失路径的 IO 异常，保证生产 catch/finally 路径确实被运行。 */
  function requireFile(file) {
    if (!files.has(file)) throw new Error('ENOENT: ' + file);
    return files.get(file);
  }
  /** 核对 fd 仍被持有；关闭后重复读写不能静默得到默认内容。 */
  function handle(fd) {
    assert.ok(handles.has(fd), '操作已关闭或未知 fd：' + fd);
    return handles.get(fd);
  }
  /** 只移除 native 替身已证明属于当前 stage 的虚拟内容。 */
  function removePrefix(prefix) {
    for (const key of files.keys()) if (key === prefix || key.startsWith(prefix + '/')) files.delete(key);
    for (const key of directories) if (key === prefix || key.startsWith(prefix + '/')) directories.delete(key);
  }

  const io = {
    OpenMode: flags,
    /** 每次读取先检查摘要是否仍持有旧 buffer，捕获遗漏 await 的生命周期错误。 */
    async read(fd, buffer) {
      assert.equal(pendingDigestBuffers.has(buffer), false, '摘要完成前复用了读取 buffer');
      await nextTurn();
      const item = handle(fd), bytes = requireFile(item.path);
      if (mode.readFailure && item.position > 0) throw new Error('injected read failure');
      const count = Math.min(buffer.byteLength, bytes.length - item.position);
      new Uint8Array(buffer).set(bytes.subarray(item.position, item.position + count));
      item.position += count; counters.reads++;
      return count;
    },
    /** 用实际返回长度推进游标，允许反复短写，独立验证完整文件最终字节。 */
    async write(fd, buffer) {
      await nextTurn();
      const item = handle(fd), bytes = Buffer.from(buffer);
      if (mode.zeroWrite) return 0;
      const count = Math.min(bytes.length, mode.shortWrite ? 8191 : bytes.length);
      const previous = requireFile(item.path), next = Buffer.alloc(Math.max(previous.length, item.position + count));
      previous.copy(next); bytes.copy(next, item.position, 0, count);
      files.set(item.path, next); item.position += count; item.synced = false; counters.writes++;
      events.push(['write', item.path, count]);
      return count;
    },
    /** open/close 在真实异步边界管理句柄，临时文件打开即截断，便于检查 finally 收口。 */
    async open(file, openFlags) {
      await nextTurn();
      if (!files.has(file) && !(openFlags & flags.CREATE)) throw new Error('ENOENT: ' + file);
      assert.ok(directories.has(path.posix.dirname(file)), '父目录不存在：' + file);
      if (openFlags & flags.TRUNC) files.set(file, Buffer.alloc(0));
      const fd = nextFd++; handles.set(fd, { path: file, position: 0, writable: !!(openFlags & flags.WRITE_ONLY), synced: false });
      events.push(['open', file, fd]); return { fd };
    },
    async close(opened) {
      await nextTurn();
      const fd = typeof opened === 'number' ? opened : opened.fd;
      const item = handle(fd); handles.delete(fd); events.push(['close', item.path, item.synced]);
    },
    /** fsync 只确认已完整完成的写；rename 会独立断言此事实。 */
    async fsync(fd) { await nextTurn(); const item = handle(fd); item.synced = true; events.push(['fsync', item.path]); },
    async stat(file) {
      await nextTurn();
      if (!files.has(file) && !directories.has(file)) throw new Error('ENOENT: ' + file);
      return { size: files.get(file)?.length || 0, isFile: () => files.has(file), isDirectory: () => directories.has(file) };
    },
    async listFile(directory) {
      await nextTurn();
      if (!directories.has(directory)) throw new Error('ENOENT: ' + directory);
      return Array.from(files.keys()).filter(file => path.posix.dirname(file) === directory).map(file => path.posix.basename(file));
    },
    async readText(file) {
      await nextTurn();
      const value = requireFile(file).toString('utf8');
      if (mode.flipMarker && file.endsWith('/.installed') && ++markerReads === 2) return value + 'changed';
      return value;
    },
    async mkdir(directory) { await nextTurn(); mkdir(directory); },
    async access(file) { await nextTurn(); return files.has(file) || directories.has(file); },
    async unlink(file) { await nextTurn(); requireFile(file); files.delete(file); events.push(['unlink', file]); },
    /** 发布临时文件前必须已落盘并关闭；失败模式持续拒绝 marker 的两次 rename 尝试。 */
    async rename(from, to) {
      await nextTurn(); requireFile(from);
      assert.equal(Array.from(handles.values()).some(item => item.path === from), false, 'rename 前未关闭临时文件');
      const closed = events.findLast(event => event[0] === 'close' && event[1] === from);
      assert.equal(closed?.[2], true, 'rename 前没有 fsync 成功证据');
      if (mode.markerFailure && to.endsWith('/.installed')) throw new Error('injected marker rename failure');
      files.set(to, files.get(from)); files.delete(from); events.push(['rename', to]);
    },
  };
  const cryptoFramework = {
    /** 延迟读取传入视图，验证调用者既等待异步完成又不散列 backing buffer 的额外字节。 */
    createMd() {
      const digest = crypto.createHash('sha256');
      return {
        async update({ data }) {
          assert.equal(pendingDigestBuffers.has(data.buffer), false, '同一 buffer 并发更新摘要');
          pendingDigestBuffers.add(data.buffer);
          try {
            await nextTurn(); await nextTurn();
            if (mode.digestFailure) throw new Error('injected digest failure');
            counters.digestLengths.push(data.byteLength); digest.update(data);
          } finally { pendingDigestBuffers.delete(data.buffer); }
        },
        async digest() { await nextTurn(); return { data: new Uint8Array(digest.digest()) }; },
      };
    },
  };
  const logger = { info: (...values) => logs.push(['info', ...values]),
    warn: (...values) => logs.push(['warn', ...values]), error: (...values) => logs.push(['error', ...values]) };
  const selectSlot = (directory, feature = 0) => {
    const slot = slots.get(path.posix.basename(directory));
    assert.ok(slot, '未知夹具槽：' + directory);
    assert.equal(feature, slot.deploymentDirectory === 'lwjgl-ohos' ? 17 : 0, '不能改变本轮实际 JDK 选择');
    return slot;
  };
  const load = makePureEtsLoader({
    '@kit.CoreFileKit': { fileIo: io }, '@kit.CryptoArchitectureKit': { cryptoFramework },
    commons: { AppLogger: logger, stringToUtf8: value => new Uint8Array(Buffer.from(value)), SUPPORTED_JDK_VERSIONS: [] },
    feature_core: {}, './LwjglRuntimeSlots': { lwjglRuntimeSlot: selectSlot },
    './LwjglSlotIntegrity': {}, './GameCompatibility': {}, './JdkTreeValidation': {},
  });
  const { RuntimeDeployer } = load('launch/src/main/ets/RuntimeDeployer.ets');
  const generations = load('launch/src/main/ets/RuntimeSlotGenerations.ets');
  const mcDir = '/fixture/minecraft'; mkdir(mcDir);
  generations.setRuntimeSlotNativeOps({
    /** Native 替身只搬运目录，不代替生产类决定字节是否可以提交。 */
    createStage(destination) {
      const stage = path.posix.dirname(path.posix.dirname(destination)) + '/.stage-test-' + (++stageSequence) + '/' + path.posix.basename(destination);
      mkdir(stage); stages.add(stage); events.push(['createStage', stage]); return stage;
    },
    publish(stage, destination) {
      events.push(['publish', stage, destination]);
      if (!stage) { requireFile(destination + '/.installed'); return; }
      assert.ok(stages.has(stage), 'publish 必须持有本轮 stage owner');
      requireFile(stage + '/.installed');
      if (mode.publishFailure) throw new Error('injected publication failure');
      const from = path.posix.dirname(stage), to = path.posix.dirname(destination);
      const moving = Array.from(files.entries()).filter(([file]) => file.startsWith(from + '/'));
      removePrefix(to); mkdir(destination);
      for (const [file, bytes] of moving) { files.set(to + file.slice(from.length), bytes); files.delete(file); }
      events.push(['committed', destination]);
    },
    discardStage(stage) { assert.ok(stages.has(stage)); removePrefix(path.posix.dirname(stage)); stages.delete(stage); events.push(['discard', stage]); },
    collect(directory) { events.push(['collect', directory]); if (mode.gcFailure) throw new Error('injected GC failure'); return 0; },
    acquire() { throw new Error('本回归不创建 JVM 读租约'); }, release() { return false; }, retire() { return false; },
  });
  const context = { filesDir: '/fixture/files', resourceManager: {
    /** 每次返回带17字节前缀和额外后缀的视图，误写整个 backing buffer 必然校验失败。 */
    async getRawFileContent(resource) {
      await nextTurn();
      const original = resources.get(resource); assert.ok(original, '未知夹具资源：' + resource);
      const padded = new Uint8Array(original.length + 46); padded.fill(0xEE); padded.set(original, 17);
      const view = padded.subarray(17, 17 + original.length);
      if (mode.badResource && resource.startsWith(mode.badResource + '/')) view[view.length - 1] ^= 1;
      counters.rawViews.push([view.byteOffset, view.byteLength, view.buffer.byteLength]);
      return view;
    },
  } };
  const deployer = new RuntimeDeployer(context);
  // 三个非槽小阶段由其他既有回归覆盖；此处仅记录调用顺序，测试范围不伪称包含其 IO。
  for (const method of ['deployStubObjcBridge', 'deployFontconfigRuntime', 'deployJdk8FontConfig']) {
    deployer[method] = () => events.push(['phase', method]);
  }
  const directory = (slot = 'lwjgl-ohos') => generations.lwjglGenerationDirectory(mcDir, slot, slot === 'lwjgl-ohos' ? 17 : 0);
  /** 直接调用生产私有槽核心以观察抛错；公开入口的逐槽容错另设用例核验。 */
  const install = () => deployer.extractLwjglSlotForStartup_(mcDir, 'lwjgl-ohos', 17);
  /** 独立参考字节逐项比较最终产物，不能只依据生产返回的 ok 判断通过。 */
  function assertCommitted(slot = 'lwjgl-ohos') {
    const target = directory(slot), selected = selectSlot(slot, slot === 'lwjgl-ohos' ? 17 : 0);
    assert.equal(requireFile(target + '/.installed').toString('utf8'), selected.marker);
    for (const jar of selected.jars) assert.deepEqual(requireFile(target + '/' + jar.name), resources.get(jar.resourcePath));
    assert.equal(Array.from(files.keys()).some(file => file.includes('.tmp.')), false, '临时文件必须收口');
  }
  return { mode, files, handles, stages, events, logs, counters, directory, install, deployer, assertCommitted, mcDir };
}

/** 用例失败仍记录报告并继续其他隔离用例；所有断言均针对生产执行的外部可见结果。 */
async function check(name, execute, configuration = {}) {
  const state = fixture(configuration);
  try {
    await execute(state);
    assert.equal(state.handles.size, 0, '用例结束没有释放全部文件句柄');
    assert.equal(state.stages.size, 0, '用例结束没有释放全部 stage owner');
    results.push({ name, status: 'PASS', reads: state.counters.reads, writes: state.counters.writes });
    console.log('PASS ' + name);
  } catch (error) {
    results.push({ name, status: 'FAIL', error: error.stack || String(error) });
    console.error('FAIL ' + name + ': ' + error.message);
  }
}

await check('跨256KiB多块、37字节尾块及非零byteOffset保持最终字节', async state => {
  await state.install(); state.assertCommitted();
  assert.ok(state.counters.reads >= 7 && state.counters.writes >= 5, '必须确实经过多次 IO');
  assert.ok(state.counters.digestLengths.includes(37), '必须摘要实际尾块而非整块旧数据');
  assert.ok(state.counters.rawViews.every(([offset, length, backing]) => offset === 17 && backing === length + 46));
});
await check('反复短写仍完整收口且落盘关闭后才rename', async state => {
  await state.install(); state.assertCommitted(); assert.ok(state.counters.writes > 60);
}, { shortWrite: true });
await check('零长度短写拒绝发布并清理stage', async state => {
  await assert.rejects(state.install(), /短写/);
  assert.equal(state.events.some(event => event[0] === 'publish'), false);
  assert.equal(state.files.has(state.directory() + '/.installed'), false);
}, { zeroWrite: true });
await check('包内同大小SHA错误不能生成已提交marker', async state => {
  await assert.rejects(state.install(), /包内 LWJGL 内容身份不匹配/);
  assert.equal(state.events.filter(event => event[0] === 'discard').length, 1);
  assert.equal(state.events.some(event => event[0] === 'publish'), false);
}, { badResource: 'lwjgl-ohos' });
await check('异步摘要拒绝向外传播且finally清理owner', async state => {
  await assert.rejects(state.install(), /injected digest failure/);
  assert.equal(state.events.filter(event => event[0] === 'discard').length, 1);
}, { digestFailure: true });
await check('文件第二块读取失败仍关闭fd并拒绝提交', async state => {
  await assert.rejects(state.install(), /injected read failure/);
  assert.equal(state.events.some(event => event[0] === 'publish'), false);
}, { readFailure: true });
await check('marker改名失败清理临时文件和stage', async state => {
  await assert.rejects(state.install(), /injected marker rename failure/);
  assert.equal(state.events.some(event => event[0] === 'publish'), false);
  assert.equal(Array.from(state.files.keys()).some(file => file.includes('.stage-')), false);
}, { markerFailure: true });
await check('目录发布失败必须discard而不运行GC', async state => {
  await assert.rejects(state.install(), /injected publication failure/);
  assert.equal(state.events.filter(event => event[0] === 'discard').length, 1);
  assert.equal(state.events.some(event => event[0] === 'collect'), false);
  assert.equal(state.files.has(state.directory() + '/.installed'), false);
}, { publishFailure: true });
await check('精确复用不创建stage不重读rawfile并重新激活同代', async state => {
  await state.install(); state.assertCommitted();
  const before = state.events.length, rawCount = state.counters.rawViews.length;
  await state.install(); state.assertCommitted();
  assert.equal(state.counters.rawViews.length, rawCount);
  const reuse = state.events.slice(before);
  assert.equal(reuse.some(event => event[0] === 'createStage' || event[0] === 'write'), false);
  assert.ok(reuse.some(event => event[0] === 'publish' && event[1] === ''));
  assert.ok(reuse.some(event => event[0] === 'collect'));
});
await check('GC异常不撤销已发布代且只记录延后回收', async state => {
  await state.install(); state.assertCommitted();
  assert.ok(state.logs.some(values => values[0] === 'warn' && values.join(' ').includes('Deferred old generation collection')));
  assert.equal(state.events.filter(event => event[0] === 'committed').length, 1);
}, { gcFailure: true });
await check('最终目录同大小损坏必须重新部署而不能精确复用', async state => {
  await state.install();
  const file = state.directory() + '/lwjgl.jar', bytes = Buffer.from(state.files.get(file));
  bytes[bytes.length - 1] ^= 1; state.files.set(file, bytes);
  await state.install(); state.assertCommitted();
  assert.equal(state.events.filter(event => event[0] === 'createStage').length, 2);
});
await check('校验前后marker变化拒绝stage提交', async state => {
  await assert.rejects(state.install(), /校验期间部署标记发生变化/);
  assert.equal(state.events.some(event => event[0] === 'publish'), false);
}, { flipMarker: true });
await check('公开入口await让步并保留失败槽与两个独立成功槽', async state => {
  await state.deployer.deployAllForStartup(state.mcDir, async () => { state.counters.yields++; await nextTurn(); });
  assert.equal(state.counters.yields, 6);
  assert.equal(state.files.has(state.directory() + '/.installed'), false);
  state.assertCommitted('lwjgl-ohos-322'); state.assertCommitted('lwjgl-ohos-2');
  assert.ok(state.logs.some(values => values[0] === 'error' && values.join(' ').includes('lwjgl-ohos')));
  assert.deepEqual(state.events.filter(event => event[0] === 'phase').map(event => event[1]),
    ['deployStubObjcBridge', 'deployFontconfigRuntime', 'deployJdk8FontConfig']);
}, { badResource: 'lwjgl-ohos' });

const report = { schema: 'amcl/startup-runtime-regression@1', recordedAt: new Date().toISOString(),
  status: results.every(result => result.status === 'PASS') ? 'PASS' : 'FAIL', sources, results,
  limitations: ['内存fs/摘要/native替身不证明真机I/O性能', '不替代native跨进程锁和GC测试', '非槽小阶段只核对调用顺序'] };
if (outputDirectory) {
  const checked = assertExternalOutputPath(outputDirectory); fs.mkdirSync(checked, { recursive: true });
  const destination = path.join(checked, 'startup-runtime-' + report.recordedAt.replace(/[:.]/g, '-') + '.json');
  fs.writeFileSync(destination, JSON.stringify(report, null, 2) + '\n', { flag: 'wx' });
  console.log('报告：' + destination);
}
console.log(`${report.status}: ${results.filter(result => result.status === 'PASS').length}/${results.length}`);
if (report.status !== 'PASS') process.exitCode = 1;
