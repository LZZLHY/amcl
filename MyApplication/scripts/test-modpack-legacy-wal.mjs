/**
 * 主线冷恢复兼容回归。用真实生产 Session、Installer 和旧 WAL 解码器执行，
 * 宿主只替换 FileKit/CryptoKit 基础端口。真实手机原件只读，写入限本轮独占副本。
 */
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileIo, mocks, productionPathPolicy } from './mod-install-test-runtime.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { createHostTestScope } from './lib/host-test-lifecycle.mjs';
import { assertExternalOutputPath, resolveWorkspacePath } from './lib/workspace-paths.mjs';

function argument(name) {
  const index = process.argv.indexOf(name);
  if (index < 0) return undefined;
  const value = process.argv[index + 1];
  assert.ok(value && !value.startsWith('--'), 'missing argument ' + name);
  return value;
}

const parent = assertExternalOutputPath(process.env.AMCL_TEST_OUTPUT_DIR
  || resolveWorkspacePath('run', 'modpack-legacy-wal'));
fs.mkdirSync(parent, { recursive: true });
const report = fs.mkdtempSync(path.join(parent, 'run-'));
const scope = createHostTestScope('fixtures-', { parent: report, automatic: false });
const root = path.resolve(scope.directory);
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const actualHash = file => sha(fs.readFileSync(file));
const handles = new Map();
const cases = [];
let legacy;
let failClose;
let failRename = false;
let failParentFsync;
let opens = 0;
let sessionTextReads = 0;
let failure;

/** 所有生产文件操作限独占夹具，避免真实副本或其原外部安装路径参与宿主测试。 */
function owned(file) {
  const local = path.resolve(file);
  assert.ok(local.startsWith(root + path.sep), 'fixture path escaped: ' + local);
}

function statWithTimes(file) {
  owned(file);
  const stat = fs.lstatSync(file);
  const times = fs.lstatSync(file, { bigint: true });
  stat.mtimeNs = times.mtimeNs;
  stat.ctimeNs = times.ctimeNs;
  return stat;
}

const io = {
  ...fileIo,
  OpenMode: { ...fileIo.OpenMode, NOFOLLOW: fs.constants.O_NOFOLLOW ?? 0 },
  accessSync(file) { owned(file); return fileIo.accessSync(file); },
  lstatSync: statWithTimes,
  statSync(file) {
    if (typeof file === 'number') return fs.fstatSync(file);
    owned(file);
    return fs.statSync(file);
  },
  openSync(file, flags) {
    owned(file);
    const handle = fileIo.openSync(file, flags);
    opens++;
    handles.set(handle.fd, file);
    return handle;
  },
  closeSync(handle) {
    const name = handles.get(handle.fd);
    assert.ok(name);
    if (failClose && name.endsWith(failClose)) {
      failClose = undefined;
      throw new Error('fixture uncertain close');
    }
    fileIo.closeSync(handle);
    handles.delete(handle.fd);
  },
  readSync(fd, bytes, options) {
    assert.ok(handles.has(fd));
    assert.equal(options.offset, undefined, 'FileKit offset 相对当前指针');
    return fs.readSync(fd, new Uint8Array(bytes), 0, Math.min(options.length, 31993), null);
  },
  readTextSync(file) {
    owned(file);
    if (file.endsWith('/session.json')) sessionTextReads++;
    return fileIo.readTextSync(file);
  },
  listFileSync(file) { owned(file); return fs.readdirSync(file); },
  fsyncSync(fd) {
    const name = handles.get(fd);
    assert.ok(name);
    if (fs.fstatSync(fd).isDirectory()) {
      if (name === failParentFsync) {
        failParentFsync = undefined;
        throw new Error('fixture parent fsync');
      }
      // Windows 不支持对目录 fd 执行 fsync，普通文件仍调用真实 fsync。
      if (process.platform !== 'win32') fs.fsyncSync(fd);
    } else fs.fsyncSync(fd);
  },
  renameSync(before, after) {
    owned(before);
    owned(after);
    if (failRename && after.endsWith('/session.json')) {
      failRename = false;
      throw new Error('fixture before rename');
    }
    fs.renameSync(before, after);
  },
  unlinkSync(file) { owned(file); fs.unlinkSync(file); },
};

const commons = {
  ...mocks.commons,
  ensureDirSync(directory) { owned(directory); fs.mkdirSync(directory, { recursive: true }); },
  removeDirRecursive(directory) { owned(directory); fs.rmSync(directory, { recursive: true, force: true }); },
  fileExists(file) { owned(file); return fs.existsSync(file) && fs.statSync(file).isFile(); },
};
const dependencies = {
  ...mocks,
  '@kit.CoreFileKit': { fileIo: io },
  commons,
  feature_core: productionPathPolicy(),
};
const load = makePureEtsLoader(dependencies);
Object.assign(commons, load('commons/src/main/ets/utils/InstancePaths.ets'));
const { evidenceHex, evidenceTextDigest } = load('commons/src/main/ets/utils/EvidenceIo.ets');
Object.assign(commons, { evidenceHex, evidenceTextDigest });
const sessions = load('mods/src/main/ets/ModpackInstallSession.ets');
const { commitModpackRecoveryAbandonment, inspectModpackRecovery, ModpackInstaller } =
  load('mods/src/main/ets/ModpackInstaller.ets');

function fixture(label, committed = true) {
  const id = 'owner-' + label;
  const files = (scope.directory + '/' + label + '/files').replaceAll('\\', '/');
  const work = files + '/modpack-work/' + id;
  const generation = 'legacy-generation';
  const log = work + '/.override-' + generation + '/commit.jsonl';
  const directory = path.dirname(log);
  fs.mkdirSync(directory, { recursive: true });
  const session = {
    schemaVersion: 2, id, mcDir: (scope.directory + '/' + label + '/mc').replaceAll('\\', '/'), versionName: '',
    plan: { name: 'legacy', gameVersion: '1.20.1', loaderType: '', loaderVersion: '', files: [], problems: [],
      overrideDirs: ['overrides'] },
    warnings: [], missing: [], selectedOptional: [], confirmed: true, baseReady: false, overridesApplied: false,
    complete: false, installedFiles: [], overrideFiles: [],
    overrideReceipts: [{ path: 'config/a.cfg', source: 'overrides/config/a.cfg', previousSha1: '',
      sha1: 'a'.repeat(40), committed: false }],
    overrideJournal: { version: 1, generation, name: '.override-' + generation, indices: [0] },
    projectId: '', sourceVersionId: '', archiveSha1: 'a'.repeat(40), archiveSize: 0, iconUrl: '', createdAt: 1,
  };
  const raw = JSON.stringify(session);
  const header = JSON.stringify({ version: 1, sessionId: id, generation, baseSha256: sha(raw), baseBytes: Buffer.byteLength(raw) });
  const payload = JSON.stringify({ seq: 1, index: 0, previous: sha(header) });
  fs.writeFileSync(work + '/session.json', raw);
  fs.writeFileSync(work + '/source.json', JSON.stringify({ schemaVersion: 1, id, mcDir: session.mcDir, title: 'legacy' }));
  fs.writeFileSync(log, header + '\n' + (committed ? JSON.stringify({ payload, sha256: sha(payload) }) + '\n' : ''));
  return { id, files, work, log, raw, session };
}

function pass(name) {
  cases.push(name);
  console.log('PASS ' + name);
}

try {
  const observed = fixture('observe');
  const before = opens;
  assert.equal(sessions.loadRecoveryPreview(observed.files, observed.id).schemaVersion, 2);
  assert.equal(inspectModpackRecovery(observed.files, observed.id), 'install');
  assert.equal(opens, before, '列表和确认摘要不得打开旧 WAL FD');
  assert.equal(sessions.loadModpackSession(observed.files, observed.id).overrideReceipts[0].committed, true);
  assert.equal(fs.readFileSync(observed.work + '/session.json', 'utf8'), observed.raw);
  const forged = { ...observed.session, schemaVersion: 1, overrideJournal: undefined };
  assert.throws(() => sessions.saveModpackSession(observed.files, forged), /不能直接保存/);
  assert.equal(fs.readFileSync(observed.work + '/session.json', 'utf8'), observed.raw);
  pass('preview never opens WAL; full observation replays without mutation and ordinary save is blocked');

  const retry = fixture('rename');
  const oldLog = actualHash(retry.log);
  failRename = true;
  assert.throws(() => sessions.recoverModpackSessionForWrite(retry.files, retry.id), /fixture before rename/);
  assert.equal(fs.readFileSync(retry.work + '/session.json', 'utf8'), retry.raw);
  const resumed = sessions.recoverModpackSessionForWrite(retry.files, retry.id);
  assert.equal(resumed.schemaVersion, 1);
  assert.equal(resumed.overrideReceipts[0].committed, true);
  assert.deepEqual(resumed.overrideFiles, ['config/a.cfg']);
  assert.equal(actualHash(retry.log), oldLog);
  const roundTrips = sessionTextReads;
  sessions.saveModpackSession(retry.files, resumed);
  const afterFirst = sessionTextReads;
  sessions.saveModpackSession(retry.files, resumed);
  assert.equal(sessionTextReads, afterFirst, '已知的原子 schema 1 写入不重复全量解析');
  assert.equal(afterFirst, roundTrips + 1);
  pass('atomic merge retries after pre-publish failure and retains WAL; schema1 hot saves avoid reparse');

  const uncertainPublish = fixture('parent-sync');
  const publishLog = actualHash(uncertainPublish.log);
  failParentFsync = uncertainPublish.work;
  assert.throws(() => sessions.recoverModpackSessionForWrite(uncertainPublish.files, uncertainPublish.id), /fixture parent fsync/);
  assert.equal(sessions.recoverModpackSessionForWrite(uncertainPublish.files, uncertainPublish.id).schemaVersion, 1);
  assert.equal(actualHash(uncertainPublish.log), publishLog);
  pass('post-rename failure retains original WAL and rechecks the visible complete schema1');

  const closed = fixture('close');
  failClose = '/commit.jsonl';
  assert.throws(() => sessions.loadModpackSession(closed.files, closed.id), /关闭未确认/);
  assert.equal(handles.size, 1);
  assert.throws(() => commitModpackRecoveryAbandonment(closed.files, closed.id, 'install'), /关闭未确认/);
  assert.equal(sessions.readModpackRecoveryDismissal(closed.files, closed.id), undefined);
  assert.equal(sessions.recoverModpackSessionForWrite(closed.files, closed.id).schemaVersion, 1);
  assert.equal(handles.size, 0);
  pass('unknown close blocks dismissal; same inode retry reclaims the original FD');

  const bad = fixture('bad-frame');
  fs.appendFileSync(bad.log, '{}\n');
  assert.equal(inspectModpackRecovery(bad.files, bad.id), 'install');
  assert.throws(() => commitModpackRecoveryAbandonment(bad.files, bad.id, 'install'), /覆盖日志/);
  assert.throws(() => sessions.recoverModpackSessionForWrite(bad.files, bad.id), /覆盖日志/);
  assert.equal(fs.readFileSync(bad.work + '/session.json', 'utf8'), bad.raw);
  assert.equal(sessions.readModpackRecoveryDismissal(bad.files, bad.id), undefined);
  pass('valid source does not let a complete invalid frame bypass full recovery or dismissal checks');

  const abandoned = fixture('dismiss', false);
  const abandonLog = actualHash(abandoned.log);
  fs.appendFileSync(abandoned.log, '{"payload":"torn');
  const tornLog = actualHash(abandoned.log);
  assert.notEqual(abandonLog, tornLog);
  fs.writeFileSync(abandoned.work + '/cache.part', 'owned cache');
  commitModpackRecoveryAbandonment(abandoned.files, abandoned.id, 'install');
  assert.equal(await sessions.cleanupDismissedModpackWork(abandoned.files, abandoned.id), true);
  assert.equal(fs.existsSync(abandoned.work + '/cache.part'), false);
  assert.equal(fs.readFileSync(abandoned.work + '/session.json', 'utf8'), abandoned.raw);
  assert.equal(actualHash(abandoned.log), tornLog);
  pass('dismissal ignores only torn tail and preserves base/source and WAL while reclaiming owned cache');

  const orphaned = fixture('orphan', false);
  const orphanLog = actualHash(orphaned.log);
  fs.unlinkSync(orphaned.work + '/session.json');
  assert.throws(() => commitModpackRecoveryAbandonment(orphaned.files, orphaned.id, 'install'), /缺少基座/);
  const installer = new ModpackInstaller();
  await assert.rejects(installer.discard({ filesDir: orphaned.files, sessionId: orphaned.id }), /缺少基座/);
  assert.equal(actualHash(orphaned.log), orphanLog);
  pass('orphan WAL cannot be dismissed or cold-discarded without its base');

  const legacyFiles = argument('--legacy-fixture');
  if (legacyFiles !== undefined) {
    assert.ok(path.isAbsolute(legacyFiles));
    const id = argument('--legacy-owner') ?? '1793459934757-2-724575236';
    assert.match(id, /^[A-Za-z0-9_-]+$/);
    const original = path.join(legacyFiles, 'modpack-work', id);
    const manifest = JSON.parse(fs.readFileSync(argument('--legacy-manifest')
      ?? path.resolve(legacyFiles, '..', '..', 'legacy-snapshot.json'), 'utf8').replace(/^\uFEFF/, ''));
    assert.equal(manifest.owner, id);
    const base = JSON.parse(fs.readFileSync(path.join(original, 'session.json'), 'utf8'));
    assert.equal(base.schemaVersion, 2);
    const ref = base.overrideJournal.name;
    assert.match(ref, /^\.override-[a-zA-Z0-9-]+$/);
    const files = (scope.directory + '/real-old-device/files').replaceAll('\\', '/');
    const copy = path.join(files, 'modpack-work', id);
    fs.mkdirSync(path.join(copy, ref), { recursive: true });
    const hashes = {};
    for (const relative of ['session.json', 'source.json', ref + '/commit.jsonl']) {
      const input = path.join(original, relative);
      assert.equal(fs.lstatSync(input).isSymbolicLink(), false);
      const expected = manifest.files.find(entry => entry.devicePath.endsWith('/' + relative));
      assert.ok(expected);
      hashes[relative] = actualHash(input);
      assert.equal(hashes[relative], expected.sha256);
      fs.copyFileSync(input, path.join(copy, relative), fs.constants.COPYFILE_EXCL);
      assert.equal(actualHash(path.join(copy, relative)), expected.sha256);
    }
    const count = base.overrideReceipts.filter(record => record.committed).length;
    const before = opens;
    assert.equal(sessions.loadRecoveryPreview(files, id).schemaVersion, 2);
    assert.equal(opens, before);
    const projected = sessions.loadModpackSession(files, id);
    assert.equal(projected.overrideReceipts.filter(record => record.committed).length, count + 32);
    const recovered = sessions.recoverModpackSessionForWrite(files, id);
    assert.equal(recovered.schemaVersion, 1);
    assert.equal(recovered.overrideReceipts.filter(record => record.committed).length, count + 32);
    assert.equal(recovered.mcDir, base.mcDir);
    assert.equal(recovered.versionName, base.versionName);
    assert.deepEqual(recovered.overrideFiles, projected.overrideFiles);
    for (const relative of Object.keys(hashes)) assert.equal(actualHash(path.join(original, relative)), hashes[relative]);
    for (const relative of ['source.json', ref + '/commit.jsonl'])
      assert.equal(actualHash(path.join(copy, relative)), hashes[relative]);
    legacy = { owner: id, sourceHashes: hashes, schemaBefore: 2, schemaAfter: 1,
      replayedFrames: 32, committedBefore: count, committedAfter: count + 32, originalBytesUnchanged: true,
      sourceAndWalRetainedInCopy: true };
    pass('exact current-phone bytes replay 32 frames and safely merge in an isolated copy');
  }
  assert.equal(handles.size, 0);
} catch (error) {
  failure = error;
  throw error;
} finally {
  fs.writeFileSync(path.join(report, 'summary.json'), JSON.stringify({ at: new Date().toISOString(),
    state: failure ? 'FAIL' : 'PASS', cases, ...(legacy ? { legacy } : {}), ...(failure ? { error: String(failure) } : {}) }, null, 2) + '\n');
  await scope.close({ success: !failure });
  console.log('RESULT ' + path.join(report, 'summary.json'));
}
