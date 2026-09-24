#!/usr/bin/env node
/**
 * 在独立临时目录执行真实 ArkTS 部署与校验：仅替换 OHOS IO/crypto 环境，不复制业务判据。
 * 正例使用仓内最终 JAR 字节；反例覆盖跨槽隔离、同大小损坏、缺标记、短写和发布失败。
 * 不启动 JVM、不访问设备、不更改 rawfile/prebuilt。
 */
// 临时夹具及其清理边界统一使用外部宿主测试区，不修改系统 TEMP，也不回退到源码目录。
import { workspaceTempRoot } from './lib/workspace-paths.mjs';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temporaryRoot = fs.mkdtempSync(path.join(workspaceTempRoot(), 'amcl-lwjgl-slots-'));
const mcDir = temporaryRoot.replaceAll('\\', '/') + '/minecraft';
const accesses = [];
const mutations = [];
const opened = new Set();
const errors = [];
let failedWritePath = '';
let failedRenamePath = '';
let failedReadPath = '';
let markerReadCount = 0;
let flipMarker = false;
let shortWrite = false;
const handlePaths = new Map();

const fileIo = {
  OpenMode: { READ_ONLY: fs.constants.O_RDONLY, WRITE_ONLY: fs.constants.O_WRONLY,
    CREATE: fs.constants.O_CREAT, TRUNC: fs.constants.O_TRUNC },
  statSync(value) { accesses.push(String(value)); return typeof value === 'number' ? fs.fstatSync(value) : fs.statSync(value); },
  mkdirSync(directory) { mutations.push('mkdir:' + directory); fs.mkdirSync(directory, { recursive: true }); },
  accessSync(file) { accesses.push(file); return fs.existsSync(file); },
  listFileSync(directory) { accesses.push(directory); return fs.readdirSync(directory); },
  unlinkSync(file) { mutations.push('unlink:' + file); fs.unlinkSync(file); },
  renameSync(source, destination) {
    mutations.push('rename:' + destination);
    if (failedRenamePath && destination.endsWith(failedRenamePath)) throw new Error('injected rename failure');
    fs.renameSync(source, destination);
  },
  readTextSync(file) {
    accesses.push(file);
    if (flipMarker && file.endsWith('/.installed') && ++markerReadCount === 2) return 'changed';
    return fs.readFileSync(file, 'utf8');
  },
  openSync(file, flags) {
    accesses.push(file);
    if ((flags & (fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_TRUNC)) !== 0) mutations.push('open-write:' + file);
    if (failedReadPath && file.endsWith(failedReadPath) && flags === fs.constants.O_RDONLY) throw new Error('injected read failure');
    const fd = fs.openSync(file, flags);
    opened.add(fd); handlePaths.set(fd, file);
    return { fd };
  },
  closeSync(file) { const fd = typeof file === 'number' ? file : file.fd; fs.closeSync(fd); opened.delete(fd); handlePaths.delete(fd); },
  fsyncSync(fd) { mutations.push('fsync:' + handlePaths.get(fd)); fs.fsyncSync(fd); },
  readSync(fd, buffer) { return fs.readSync(fd, new Uint8Array(buffer)); },
  writeSync(fd, buffer) {
    mutations.push('write:' + handlePaths.get(fd));
    if (failedWritePath && handlePaths.get(fd).includes(failedWritePath)) throw new Error('injected write failure');
    const bytes = typeof buffer === 'string' ? Buffer.from(buffer) : Buffer.from(buffer);
    return fs.writeSync(fd, shortWrite && bytes.length > 17 ? bytes.subarray(0, 17) : bytes);
  },
};
const cryptoFramework = {
  createMd() {
    const digest = crypto.createHash('sha256');
    return { updateSync({ data }) { digest.update(data); }, digestSync() { return { data: digest.digest() }; } };
  },
};
const logger = { info() {}, warn() {}, error(...args) { errors.push(args); } };
const load = makePureEtsLoader({
  '@kit.CoreFileKit': { fileIo },
  '@kit.CryptoArchitectureKit': { cryptoFramework },
  commons: { AppLogger: logger, stringToUtf8: (value) => new Uint8Array(Buffer.from(value)), SUPPORTED_JDK_VERSIONS: [] },
  feature_core: {},
  './GameCompatibility': {},
});
const { lwjglRuntimeSlot } = load('launch/src/main/ets/LwjglRuntimeSlots.ets');
const { verifyLwjglRuntimeSlot, verifyLwjglRuntimeSlotSync, lwjglBytesSha256 } = load('launch/src/main/ets/LwjglSlotIntegrity.ets');
const { RuntimeDeployer } = load('launch/src/main/ets/RuntimeDeployer.ets');
const { lwjglGenerationDirectory, setRuntimeSlotNativeOps } = load('launch/src/main/ets/RuntimeSlotGenerations.ets');
const slotDir = name => lwjglGenerationDirectory(mcDir, name);
let stageSequence = 0;
let failPublication = false;
const stages = new Set();
// ArkTS 集成用例只替换 native 端口；跨进程 flock/rename/GC 的真实实现由
// test-runtime-slot-store.py 在 POSIX 上另行运行，不能以此替身证明 native 正确性。
setRuntimeSlotNativeOps({
  createStage(destination) {
    const stage = path.dirname(path.dirname(destination)) + '/.stage-test-' + (++stageSequence) + '/' + path.basename(destination);
    fs.mkdirSync(stage, { recursive: true }); stages.add(stage); return stage;
  },
  publish(stage, destination) {
    if (failPublication) throw new Error('injected publication failure');
    if (!stage) return;
    assert.ok(stages.has(stage));
    assert.ok(destination.startsWith(mcDir + '/.amcl-runtime/'));
    if (fs.existsSync(path.dirname(destination))) fs.rmSync(path.dirname(destination), { recursive: true });
    fs.renameSync(path.dirname(stage), path.dirname(destination));
  },
  discardStage(stage) {
    assert.ok(stages.has(stage));
    if (fs.existsSync(path.dirname(stage))) fs.rmSync(path.dirname(stage), { recursive: true });
    stages.delete(stage);
  },
  retire() { return false; }, acquire() { throw new Error('此用例不启动 JVM'); }, release() { return false; },
});
let badResource = '';
const context = { filesDir: temporaryRoot.replaceAll('\\', '/') + '/files', resourceManager: {
  getRawFileContentSync(resource) {
    const source = fs.readFileSync(path.join(root, 'entry/src/main/resources/rawfile', resource));
    // 特意提供带前后额外字节的 view，防止部署把 backing buffer 而非有效区间写入目标。
    const padded = Buffer.concat([Buffer.from([1, 2, 3]), source, Buffer.from([4, 5])]);
    const view = new Uint8Array(padded.buffer, padded.byteOffset + 3, source.length);
    if (resource === badResource) view[view.length - 1] ^= 1;
    return view;
  },
} };
const deployer = new RuntimeDeployer(context);
const slots = [
  ['lwjgl-ohos', 'extractLwjglJars'],
  ['lwjgl-ohos-322', 'extractLwjgl322Jars'],
  ['lwjgl-ohos-2', 'extractLwjgl2Jars'],
];
let cases = 0;
/** 断言只改变正交的测试输入；失败显示生产返回的 detail，便于定位错误阶段。 */
function check(result, expected, label) {
  assert.equal(result.ok, expected, label + ': ' + result.detail);
  cases++;
}
try {
  assert.throws(() => lwjglRuntimeSlot('/test/lwjgl-ohos-2-extra'), /未知 LWJGL/);
  const copy = lwjglRuntimeSlot('lwjgl-ohos-322');
  copy.jars[0].sha256 = 'changed'; copy.jars.push({ name: 'foreign.jar', size: 1, sha256: 'changed' });
  assert.notEqual(lwjglRuntimeSlot('lwjgl-ohos-322').jars[0].sha256, 'changed');
  assert.equal(lwjglRuntimeSlot('lwjgl-ohos-322').jars.length, 7);
  assert.equal(lwjglBytesSha256(new Uint8Array([1, 2, 3])), crypto.createHash('sha256').update(Buffer.from([1, 2, 3])).digest('hex'));

  for (const [slotName, method] of slots) {
    const directory = slotDir(slotName);
    // 已存在的旧平铺槽只作为迁移遗留，发布新代不能覆盖或回收其内容。
    fs.mkdirSync(mcDir + '/' + slotName, { recursive: true });
    fs.writeFileSync(mcDir + '/' + slotName + '/legacy-sentinel', 'unchanged');
    const slot = lwjglRuntimeSlot(directory);
    deployer[method](mcDir);
    check(await verifyLwjglRuntimeSlot(directory), true, slotName + ' 正常部署');
    assert.equal(fs.readFileSync(directory + '/.installed', 'utf8'), slot.marker);
    assert.equal(opened.size, 0, '部署/读取必须释放句柄');
    assert.equal(fs.readFileSync(mcDir + '/' + slotName + '/legacy-sentinel', 'utf8'), 'unchanged');

    // 重进首页时执行同一个生产部署入口；验证成功不得撤 marker、写 tmp 或改动 JAR。
    mutations.length = 0;
    deployer[method](mcDir);
    assert.deepEqual(mutations, [], slotName + ' 精确复用必须零写入');
    check(await verifyLwjglRuntimeSlot(directory), true, slotName + ' 精确复用');

    fs.writeFileSync(directory + '/.installed', 'installed');
    check(await verifyLwjglRuntimeSlot(directory), false, slotName + ' 旧 marker');
    mutations.length = 0;
    deployer[method](mcDir);
    assert.ok(mutations.length > 0, slotName + ' 旧 marker 不得误复用');
    check(await verifyLwjglRuntimeSlot(directory), true, slotName + ' 旧 marker 重新部署');
    fs.writeFileSync(directory + '/foreign.jar', 'PK bad');
    check(await verifyLwjglRuntimeSlot(directory), false, slotName + ' 额外 JAR');
    fs.unlinkSync(directory + '/foreign.jar');
    fs.writeFileSync(directory + '/ignored.tmp', 'incomplete');
    check(await verifyLwjglRuntimeSlot(directory), true, slotName + ' 非 classpath 临时文件');

    const jar = directory + '/lwjgl.jar';
    const valid = fs.readFileSync(jar);
    const changed = Buffer.from(valid); changed[changed.length - 1] ^= 1;
    fs.writeFileSync(jar, changed);
    const corrupt = await verifyLwjglRuntimeSlot(directory);
    check(corrupt, false, slotName + ' 同大小损坏');
    assert.match(corrupt.detail, /SHA-256/);
    mutations.length = 0;
    deployer[method](mcDir);
    assert.ok(mutations.length > 0, slotName + ' 同大小损坏不得误复用');
    check(await verifyLwjglRuntimeSlot(directory), true, slotName + ' 同大小损坏重新部署');
    fs.writeFileSync(jar, valid.subarray(0, valid.length - 1));
    check(await verifyLwjglRuntimeSlot(directory), false, slotName + ' 截断');
    fs.unlinkSync(jar);
    check(await verifyLwjglRuntimeSlot(directory), false, slotName + ' 缺失');
    fs.writeFileSync(jar, valid);
    failedReadPath = '/lwjgl.jar';
    check(await verifyLwjglRuntimeSlot(directory), false, slotName + ' 读取失败');
    failedReadPath = '';
    assert.equal(opened.size, 0);
    fs.unlinkSync(directory + '/.installed');
    check(await verifyLwjglRuntimeSlot(directory), false, slotName + ' 部署中断');
    check(verifyLwjglRuntimeSlotSync(directory, false), true, slotName + ' 仅部署内部可不要求 marker');
    fs.writeFileSync(directory + '/.installed', slot.marker);
  }

  // 模拟未选择的 modern 已损坏：两个兼容槽不仅通过，而且没有读取 modern 路径。
  fs.writeFileSync(slotDir('lwjgl-ohos') + '/lwjgl.jar', 'broken');
  accesses.length = 0;
  for (const name of ['lwjgl-ohos-322', 'lwjgl-ohos-2']) check(await verifyLwjglRuntimeSlot(slotDir(name)), true, '不受 modern 损坏影响');
  assert.equal(accesses.some((file) => file.includes('/lwjgl-ohos/')), false);
  check(await verifyLwjglRuntimeSlot(slotDir('lwjgl-ohos')), false, '选择 modern 则必须失败');

  flipMarker = true; markerReadCount = 0;
  check(await verifyLwjglRuntimeSlot(slotDir('lwjgl-ohos-2')), false, '读取期间 marker 变化');
  flipMarker = false;

  // 失败注入运行真实部署器。发布标记只在完整文件核验后产生，且所有句柄收口。
  fs.unlinkSync(slotDir('lwjgl-ohos-2') + '/.installed');
  badResource = 'lwjgl2/lwjgl.jar';
  assert.throws(() => deployer.extractLwjgl2Jars(mcDir), /内容身份/);
  assert.equal(fs.existsSync(slotDir('lwjgl-ohos-2') + '/.installed'), false);
  badResource = '';
  failedWritePath = 'lwjgl-ohos-2/lwjgl.jar.tmp.';
  assert.throws(() => deployer.extractLwjgl2Jars(mcDir), /injected write/);
  assert.equal(opened.size, 0);
  assert.equal(fs.existsSync(slotDir('lwjgl-ohos-2') + '/.installed'), false);
  failedWritePath = '';
  failedRenamePath = '/.installed';
  assert.throws(() => deployer.extractLwjgl2Jars(mcDir), /injected rename/);
  assert.equal(fs.existsSync(slotDir('lwjgl-ohos-2') + '/.installed'), false);
  assert.equal(opened.size, 0);
  failedRenamePath = '';
  shortWrite = true;
  failPublication = true;
  assert.throws(() => deployer.extractLwjgl2Jars(mcDir), /injected publication/);
  assert.equal(fs.existsSync(slotDir('lwjgl-ohos-2') + '/.installed'), false);
  assert.equal(stages.size, 0, '目录发布失败也清理自有 staging');
  failPublication = false;
  deployer.extractLwjgl2Jars(mcDir);
  shortWrite = false;
  check(await verifyLwjglRuntimeSlot(slotDir('lwjgl-ohos-2')), true, '短写循环完整收口');
  assert.equal(fs.readdirSync(slotDir('lwjgl-ohos-2')).some((name) => name.includes('.tmp.')), false);

  // 首页统一部署保持三个槽独立；被损坏的资源明确日志失败，不能获得 marker。
  fs.mkdirSync(context.filesDir, { recursive: true });
  badResource = 'lwjgl/lwjgl.jar';
  deployer.deployAll(mcDir);
  badResource = '';
  check(await verifyLwjglRuntimeSlot(slotDir('lwjgl-ohos')), false, '发布失败保留原损坏代，不伪装成功');
  assert.ok(errors.some((entry) => entry.join(' ').includes('lwjgl-ohos')));
  check(await verifyLwjglRuntimeSlot(slotDir('lwjgl-ohos-322')), true, '另一槽部署失败不跳过 322');
  check(await verifyLwjglRuntimeSlot(slotDir('lwjgl-ohos-2')), true, '另一槽部署失败不跳过 2');
  assert.equal(opened.size, 0);
  assert.equal(stages.size, 0);
  console.log('[lwjgl-runtime-slots] PASS: ' + cases + ' 个生产校验判据 + 部署故障/短写/句柄/内容视图注入');
} finally {
  // 测试只删除自身 mkdtemp 创建的目录，先核验真实路径仍是专属测试根。
  for (const fd of opened) fs.closeSync(fd);
  const resolved = fs.realpathSync(temporaryRoot);
  assert.ok(path.basename(resolved).startsWith('amcl-lwjgl-slots-'));
  assert.equal(path.dirname(resolved), fs.realpathSync(workspaceTempRoot()));
  fs.rmSync(resolved, { recursive: true, force: true });
}
