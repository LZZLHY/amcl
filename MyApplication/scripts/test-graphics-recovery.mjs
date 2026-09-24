// 验证恢复纯规则及实际磁盘协议：首帧、显式选择、PID/锁/身份/设置变化和一次消费反例。
// 临时夹具及其清理边界统一使用外部宿主测试区，不修改系统 TEMP，也不回退到源码目录。
import { workspaceTempRoot } from './lib/workspace-paths.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
const registry = makePureEtsLoader()('launch/src/main/ets/GraphicsProfileRegistry.ets');
let shortWrite = false, zeroWrite = false, failRename = false;
const directoryHandles = new Set();
let directorySequence = 1000000;
const fileIo = {
  OpenMode: { CREATE: fs.constants.O_CREAT, WRITE_ONLY: fs.constants.O_WRONLY, TRUNC: fs.constants.O_TRUNC, READ_ONLY: fs.constants.O_RDONLY },
  accessSync: file => fs.existsSync(file),
  mkdirSync: (file, recursive) => fs.mkdirSync(file, { recursive }),
  statSync: file => fs.statSync(file),
  readTextSync: file => fs.readFileSync(file, 'utf8'),
  openSync: (file, flags) => {
    // Windows Node 不提供目录 fsync；只替代这项 OS 边界，文件写入仍在真实临时目录执行。
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) {
      const fd = ++directorySequence; directoryHandles.add(fd); return { fd };
    }
    return { fd: fs.openSync(file, flags) };
  },
  writeSync: (fd, bytes) => zeroWrite ? 0 : fs.writeSync(fd, shortWrite ? Buffer.from(bytes).subarray(0, 17) : Buffer.from(bytes)),
  fsyncSync: fd => { if (!directoryHandles.has(fd)) fs.fsyncSync(fd); },
  closeSync: file => { const fd = file.fd ?? file; if (!directoryHandles.delete(fd)) fs.closeSync(fd); },
  unlinkSync: file => fs.unlinkSync(file),
  renameSync: (from, to) => { if (failRename) throw Error('injected rename failure'); fs.renameSync(from, to); }
};
const ports = { launch: registry, '@kit.CoreFileKit': { fileIo },
  '@kit.ArkTS': { util: {} }, '@kit.BasicServicesKit': { zlib: {} },
  '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd: () => {
    const hash = createHash('sha256'); return { updateSync: value => hash.update(value.data), digestSync: () => ({ data: hash.digest() }) };
  } } } };
const commonLoad = makePureEtsLoader(ports);
const encoding = commonLoad('commons/src/main/ets/utils/Base64Util.ets');
const io = commonLoad('commons/src/main/ets/utils/EvidenceIo.ets');
// 使用真实 UTF-8 编码器与原子写入器；精确 buffer 的 TextEncoder 替身会漏掉本次真机反例。
const load = makePureEtsLoader({ ...ports, commons: { ...encoding, ...io } });
const policy = load('entry/src/main/ets/runtime/GraphicsRecoveryPolicy.ets');
const { GraphicsRecoveryStore: store } = load('entry/src/main/ets/runtime/GraphicsRecoveryStore.ets');
const id = '01234567-89ab-cdef-0123-456789abcdef';
const ticket = { id, parentPid: 21, activityId: 100, rootActivityId: 100, attempt: 0,
  createdAt: 1000, version: '26.2', mcDir: '/mc', gameDir: '/mc/versions/26.2', jdk: '25', xmx: 2048,
  preferenceStamp: 'auto:false:', retryProfile: '' };
const failure = { id, parentPid: 21, activityId: 100, childPid: 22, createdAt: 1200,
  profile: 'mobilegl', nextProfile: 'mobileglues', stage: 'admission', code: 'vulkan_capability_rejected', presentCount: 0, automatic: true };
const permits = (t = ticket, f = failure, overrides = {}) => policy.graphicsRecoveryPermitted(t, f,
  overrides.id ?? id, overrides.parent ?? 21, overrides.lock ?? 0, overrides.alive ?? 0,
  overrides.version ?? '26.2', overrides.root ?? '/mc', overrides.stamp ?? 'auto:false:', overrides.now ?? 1500);
assert.equal(permits(), true);
for (const change of [{ id: 'other' }, { parent: 23 }, { lock: 1 }, { lock: -1 }, { alive: 1 }, { alive: -1 },
  { version: '26.3' }, { root: '/different' }, { stamp: 'mobilegl:true:' }, { now: 301001 }, { now: 900 }]) {
  assert.equal(permits(ticket, failure, change), false, JSON.stringify(change));
}
for (const change of [{ attempt: 1 }, { retryProfile: 'mobileglues' }, { activityId: 0 }, { rootActivityId: 0 }]) {
  assert.equal(permits({ ...ticket, ...change }), false);
}
for (const change of [{ childPid: 21 }, { childPid: 0 }, { automatic: false }, { presentCount: 1 },
  { nextProfile: 'mobilegl' }, { nextProfile: 'minecraft-vulkan' }, { nextProfile: 'zink' }, { nextProfile: 'gl4es' },
  { nextProfile: 'unknown' }, { stage: 'artifacts' }, { stage: 'bootstrap' }, { code: 'random_failure' }]) {
  assert.equal(permits(ticket, { ...failure, ...change }), false, JSON.stringify(change));
}
assert.equal(policy.graphicsFailureRetryable('render', 'window-create-failed', 0), true);
assert.equal(policy.graphicsFailureRetryable('render', 'eglSwapBuffers', 0), false, 'quick play may exist before first swap');
assert.equal(policy.graphicsFailureRetryable('render', 'window-create-failed', 1), false);
const candidates = [{ id: 'mobilegl', source: 'DEFAULT', selected: true, admitted: true, profile: registry.graphicsProfileById('mobilegl') },
  { id: 'mobileglues', source: 'DEFAULT', selected: false, admitted: true, profile: registry.graphicsProfileById('mobileglues') }];
assert.equal(policy.graphicsRecoveryCandidate({ apiFamily: 'OPENGL', profile: 'mobilegl', candidateDetails: candidates }), 'mobileglues');
assert.equal(policy.graphicsRecoveryCandidate({ apiFamily: 'OPENGL', profile: 'mobilegl',
  candidateDetails: [{ ...candidates[0], source: 'PREFERENCE' }, candidates[1]] }), '');
// 游戏默认 Vulkan 的 native 准入失败可沿现有协议在新进程选择 GL；显式 Vulkan 不可。
const vulkanDefault = { id: 'minecraft-vulkan', source: 'GAME_DEFAULT', selected: true, admitted: true,
  profile: registry.graphicsProfileById('minecraft-vulkan') };
const glNext = { ...candidates[0], selected: false };
assert.equal(policy.graphicsRecoveryCandidate({ apiFamily: 'VULKAN', profile: 'minecraft-vulkan',
  candidateDetails: [vulkanDefault, glNext, candidates[1]] }), 'mobilegl');
for (const source of ['GAME_API', 'PREFERENCE', 'DEV']) {
  assert.equal(policy.graphicsRecoveryCandidate({ apiFamily: 'VULKAN', profile: 'minecraft-vulkan',
    candidateDetails: [{ ...vulkanDefault, source }, glNext, candidates[1]] }), '');
}
assert.equal(permits(ticket, { ...failure, profile: 'minecraft-vulkan', nextProfile: 'mobilegl' }), true);
assert.equal(permits(ticket, { ...failure, profile: 'minecraft-vulkan', nextProfile: 'mobilegl', presentCount: 1 }), false);
const root = fs.mkdtempSync(path.join(workspaceTempRoot(), 'amcl-graphics-recovery-'));
try {
  store.create(root, ticket); assert.deepEqual(store.ticket(root, id), ticket);
  assert.throws(() => store.create(root, ticket), /already exists/);
  assert.equal(store.failure(root, id), undefined);
  store.report(root, failure); assert.deepEqual(store.failure(root, id), failure);
  assert.equal(store.claim(root, id), true); assert.equal(store.claim(root, id), false);
  assert.equal(store.failure(root, id), undefined);
  assert.equal(store.ticket(root, '../escape'), undefined);
  const request = path.join(root, 'graphics-recovery', id + '.request.json');
  fs.writeFileSync(request, '{broken'); assert.equal(store.ticket(root, id), undefined);
  const padded = encoding.stringToUtf8('中文📦');
  assert.ok(padded.buffer.byteLength > padded.byteLength, '保留生产子视图反例');
  const another = { ...ticket, id: '11234567-89ab-cdef-0123-456789abcdef', version: '中文📦' };
  shortWrite = true;
  store.create(root, another); assert.deepEqual(store.ticket(root, another.id), another);
  shortWrite = false;
  for (const fault of ['zero', 'rename']) {
    zeroWrite = fault === 'zero'; failRename = fault === 'rename';
    const failed = { ...ticket, id: (fault === 'zero' ? '2' : '3') + ticket.id.slice(1) };
    assert.throws(() => store.create(root, failed), /保存失败/);
    assert.equal(store.ticket(root, failed.id), undefined);
    assert.equal(fs.readdirSync(path.dirname(request)).some(name => name.includes('.tmp-')), false);
  }
  zeroWrite = false; failRename = false;
  assert.equal(directoryHandles.size, 0);
} finally {
  const verified = fs.realpathSync(root);
  assert.equal(path.dirname(verified).toLowerCase(), fs.realpathSync(workspaceTempRoot()).toLowerCase());
  assert.ok(path.basename(verified).startsWith('amcl-graphics-recovery-'));
  fs.rmSync(verified, { recursive: true, force: true });
}
console.log('Graphics recovery: scoped request, cold PID/lock barriers, bounded retry and atomic consumption PASS');
