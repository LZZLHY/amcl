/** 真正FileIO mkdir目标已存在会报EEXIST；验证生产ensure复用边界与独占原子写命名空间。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

const ioPath = 'commons/src/main/ets/utils/EvidenceIo.ets';
const evidencePath = 'commons/src/main/ets/utils/SessionEvidence.ets';
const sdkError = (code, message = 'synthetic SDK error') => Object.assign(new Error(message), { code });

test('原refresh直接mkdir(true)对已有活动目录真实失败；修复helper在strict SDK边界成功保存Evidence', async () => {
  const old = evidenceRuntime({ transform: (absolute, source) => {
    if (!absolute.endsWith('SessionEvidence.ets')) return source;
    const call = 'await ensureEvidenceDirectoryAsync(ledgerDir_(filesDir, activityId));';
    assert.equal(source.split(call).length, 2);
    return source.replace(call, 'await fs.mkdir(ledgerDir_(filesDir, activityId), true);');
  } });
  const current = evidenceRuntime();
  try {
    for (const f of [old, current]) f.write('logs/ledger/1/launcher/launcher-host.log', 'local evidence');
    await assert.rejects(old.load(evidencePath).refreshSessionEvidenceAsync(old.directory, 1), error => error.code === 13900015);
    const manifest = await current.load(evidencePath).refreshSessionEvidenceAsync(current.directory, 1);
    assert.equal(manifest.activityId, 1); assert.ok(fs.existsSync(current.directory + '/logs/ledger/1/evidence-manifest.json'));
  } finally { old.close(); current.close(); }
});

test('真正async ensure创建缺失父级并复用实取EEXIST真目录，文件/符号链接占位不被覆盖', async () => {
  const f = evidenceRuntime();
  try {
    const io = f.load(ioPath); const target = f.directory + '/nested/ordinary';
    for (const key of ['mkdirSync', 'lstatSync', 'statSync', 'accessSync']) f.kitFs[key] = () => assert.fail('ensure不能调用' + key);
    await Promise.all([io.ensureEvidenceDirectoryAsync(target), io.ensureEvidenceDirectoryAsync(target)]);
    assert.equal((await fs.promises.lstat(target)).isDirectory(), true);
    const file = f.write('file-placeholder', 'KEEP ORIGINAL');
    await assert.rejects(io.ensureEvidenceDirectoryAsync(file), /不是普通目录/);
    assert.equal(fs.readFileSync(file, 'utf8'), 'KEEP ORIGINAL');
    const real = f.directory + '/real-directory'; await fs.promises.mkdir(real);
    const link = f.directory + '/linked-directory'; fs.symlinkSync(real, link, process.platform === 'win32' ? 'junction' : 'dir');
    await assert.rejects(io.ensureEvidenceDirectoryAsync(link), /不是普通目录/);
    assert.equal(fs.lstatSync(link).isSymbolicLink(), true); assert.equal(fs.statSync(real).isDirectory(), true);
  } finally { f.close(); }
});

test('仅numeric13900015可尝试复用；权限/设备/未知失败原样传播，EEXIST或成功后路径消失都失败', async () => {
  const f = evidenceRuntime();
  try {
    const io = f.load(ioPath); const mkdir = f.kitFs.mkdir; const lstat = f.kitFs.lstat;
    const target = f.directory + '/existing'; await fs.promises.mkdir(target);
    let lstats = 0; f.kitFs.lstat = async p => { lstats++; return lstat(p); };
    for (const code of [13900012, 13900017, 13900042]) {
      const failure = sdkError(code, 'File exists'); f.kitFs.mkdir = async () => { throw failure; };
      const before = lstats; await assert.rejects(io.ensureEvidenceDirectoryAsync(target), error => error === failure);
      assert.equal(lstats, before, '非EEXIST不能靠lstat把失败伪装成成功');
    }
    f.kitFs.mkdir = async p => { await fs.promises.rmdir(p); throw sdkError(13900015, 'File exists'); };
    await assert.rejects(io.ensureEvidenceDirectoryAsync(target), error => error.code === 13900002);
    assert.equal(fs.existsSync(target), false);
    const fresh = f.directory + '/created-then-removed';
    f.kitFs.mkdir = async (p, recursive) => { await mkdir(p, recursive); await fs.promises.rmdir(p); };
    await assert.rejects(io.ensureEvidenceDirectoryAsync(fresh), error => error.code === 13900002);
    assert.equal(fs.existsSync(fresh), false);
  } finally { f.close(); }
});

test('pending-dir碰撞必须换UUID，不复用或清理别人命名空间；连续碰撞有限失败且旧目标仍完整', async () => {
  let sequence = ['collision', 'fresh'];
  const f = evidenceRuntime({ imports: { '@kit.ArkTS': { util: { generateRandomUUID: () => sequence.shift() ?? 'collision' } } } });
  try {
    const io = f.load(ioPath); const target = f.write('atomic.json', 'OLD').replaceAll('\\', '/');
    const collision = target + '.collision.pending-dir'; await fs.promises.mkdir(collision); fs.writeFileSync(collision + '/foreign.txt', 'FOREIGN');
    await io.writeEvidenceTextAtomicAsync(target, 'NEW');
    assert.equal(fs.readFileSync(target, 'utf8'), 'NEW'); assert.equal(fs.readFileSync(collision + '/foreign.txt', 'utf8'), 'FOREIGN');
    sequence = []; let attempts = 0; const mkdir = f.kitFs.mkdir;
    f.kitFs.mkdir = async (...args) => { attempts++; return mkdir(...args); };
    await assert.rejects(io.writeEvidenceTextAtomicAsync(target, 'UNCOMMITTED'), error => error.kind === 'not-committed');
    assert.equal(attempts, 8); assert.equal(fs.readFileSync(target, 'utf8'), 'NEW');
    assert.equal(fs.readFileSync(collision + '/foreign.txt', 'utf8'), 'FOREIGN');
  } finally { f.close(); }
});
