// 临时夹具及其清理边界统一使用外部宿主测试区，不修改系统 TEMP，也不回退到源码目录。
import { workspaceTempRoot } from './lib/workspace-paths.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';

const root = path.resolve(import.meta.dirname, '..');
const temp = fs.mkdtempSync(path.join(workspaceTempRoot(), 'amcl-file-access-'));
const logger = { info() {}, warn() {} };
const nativeFs = {
  accessSync: fs.existsSync,
  statSync: fs.statSync,
  mkdirSync: (p) => fs.mkdirSync(p, { recursive: true }),
  renameSync: fs.renameSync,
  unlinkSync: fs.unlinkSync,
  closeSync: f => fs.closeSync(f.fd),
  OpenMode: { READ_ONLY: 0 },
};
function load(relative, name, bindings) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8').replace(/^import .*;\r?\n/gm, '');
  const js = stripTypeScriptTypes(source, { mode: 'transform' }).replace(/^export /gm, '');
  return runInNewContext(js + '\n' + name, bindings);
}
function storage(dir, sdk = 26, extraFs = {}) {
  const api = load('feature_system/src/main/ets/GameStorage.ets', 'GameStorage', {
    fs: { ...nativeFs, ...extraFs }, AppLogger: logger,
    deviceInfo: { sdkApiVersion: sdk, deviceType: 'phone' },
  });
  return { api, ctx: { filesDir: dir } };
}
let count = 0;
function pass(name) { count++; console.log('PASS ' + name); }
try {
  const migration = path.join(temp, 'no-migration');
  fs.mkdirSync(path.join(migration, '.minecraft', 'versions', 'existing'), { recursive: true });
  fs.mkdirSync(path.join(migration, 'minecraft', 'versions', 'unrelated'), { recursive: true });
  let mutations = 0;
  const forbiddenMutation = () => { mutations++; throw new Error('path resolution must not mutate data'); };
  const s = storage(migration, 26, { renameSync: forbiddenMutation, mkdirSync: forbiddenMutation });
  assert.equal(s.api.sandboxMcDir(s.ctx), migration + '/.minecraft');
  assert.equal(mutations, 0);
  assert(fs.existsSync(path.join(migration, '.minecraft', 'versions', 'existing')));
  assert(fs.existsSync(path.join(migration, 'minecraft', 'versions', 'unrelated')));
  const older = storage(migration, 20, { renameSync: forbiddenMutation, mkdirSync: forbiddenMutation });
  assert.equal(older.api.sandboxMcDir(older.ctx), migration + '/.minecraft');
  pass('all API versions preserve original root and never migrate during path resolution');

  let selection = [];
  let options;
  const dest = path.join(temp, 'mods');
  const source = path.join(temp, 'source.jar');
  fs.writeFileSync(source, 'new jar bytes');
  const api = load('entry/src/main/ets/components/GameArchiveIO.ets', 'GameArchiveIO', {
    fs: {
      ...nativeFs,
      open: async uri => {
        if (uri.includes('unreadable')) throw new Error('read denied');
        return { fd: fs.openSync(source, 'r') };
      },
      copyFile: async (fd, p) => { fs.writeFileSync(p, fs.readFileSync(fd)); },
      rename: async (a, b) => {
        if (b.endsWith('blocked.jar')) throw new Error('commit denied');
        fs.renameSync(a, b);
      },
    },
    picker: {
      DocumentSelectOptions: class {},
      DocumentViewPicker: class { async select(opt) { options = opt; return selection; } },
    },
    AppLogger: logger, LOG_DOMAIN_UI: 0, GameStorage: s.api,
  });
  selection = ['file://docs/a.jar', 'file://docs/%E4%B8%AD%E6%96%87%20b.jar'];
  let result = await api.importResourceFiles({}, dest, ['.jar']);
  assert.equal(options.maxSelectNumber, 500);
  assert.equal(result.names.length, 2);
  assert.equal(result.failures.length, 0);
  assert.equal(fs.readFileSync(path.join(dest, '中文 b.jar'), 'utf8'), 'new jar bytes');
  pass('multi-selection imports every URI including encoded name');
  fs.writeFileSync(path.join(dest, 'unreadable.jar'), 'old bytes');
  fs.writeFileSync(path.join(dest, 'blocked.jar'), 'old bytes');
  selection = ['file://docs/unreadable.jar', 'file://docs/blocked.jar', 'file://docs/wrong.txt', 'file://docs/%2E%2E%2Fescape.jar', 'file://docs/good.jar'];
  result = await api.importResourceFiles({}, dest, ['.jar']);
  assert.equal(result.names.length, 1);
  assert.equal(result.failures.length, 4);
  assert.equal(fs.readFileSync(path.join(dest, 'unreadable.jar'), 'utf8'), 'old bytes');
  assert.equal(fs.readFileSync(path.join(dest, 'blocked.jar'), 'utf8'), 'old bytes');
  assert.equal(fs.readdirSync(dest).some(n => n.startsWith('.amcl-import-')), false);
  pass('partial failure continues, old files survive and staging is cleaned');
  selection = [];
  result = await api.importResourceFiles({}, dest, ['.jar']);
  assert.equal(result.cancelled, true);
  assert.equal(result.failures.length, 0);
  pass('cancel is distinct from failure');
  selection = ['file://docs/one.zip'];
  result = await api.importResourceFile({}, dest, ['.zip']);
  assert.equal(options.maxSelectNumber, 1);
  assert.equal(result.ok, true);
  pass('single JDK/modpack install retains its single-task contract');
  selection = ['file://docs/notes.txt', 'file://docs/config.json'];
  result = await api.importAnyFiles({}, dest);
  assert.equal(result.names.length, 2);
  assert.equal(options.fileSuffixFilters, undefined);
  pass('file browser accepts multiple files without extension filtering');

  let archiveIndex = 0;
  const saves = path.join(temp, 'saves');
  const archives = load('entry/src/main/ets/components/GameArchiveIO.ets', 'GameArchiveIO', {
    fs: {
      ...nativeFs,
      openSync: () => ({ fd: fs.openSync(source, 'r') }),
      copyFileSync: (src, dst) => {
        if (String(src).endsWith('broken.bin')) throw new Error('copy interrupted');
        fs.writeFileSync(dst, fs.readFileSync(src));
      },
      listFileSync: fs.readdirSync,
      copyDir: async (src, dest) => fs.cpSync(src, path.join(dest, path.basename(src)), { recursive: true }),
    },
    picker: {
      DocumentSelectOptions: class {},
      DocumentViewPicker: class { async select(opt) { options = opt; return ['file://docs/a/world.zip', 'file://docs/b/broken.zip', 'file://docs/c/world.zip']; } },
    },
    zlib: {
      decompressFile: (zip, dest, callback) => {
        fs.writeFileSync(path.join(dest, 'level.dat'), 'world bytes');
        if (++archiveIndex === 2) fs.writeFileSync(path.join(dest, 'broken.bin'), 'bad');
        callback(null);
      },
    },
    removeDirRecursive: p => fs.rmSync(p, { recursive: true, force: true }),
    setTimeout, clearTimeout, AppLogger: logger, LOG_DOMAIN_UI: 0,
  });
  result = await archives.importSaveZips({ tempDir: temp }, saves);
  assert.equal(options.maxSelectNumber, 500);
  assert.equal(result.names.length, 2);
  assert.equal(result.failures.length, 1);
  assert.equal(fs.readFileSync(path.join(saves, 'world', 'level.dat'), 'utf8'), 'world bytes');
  assert.equal(fs.readFileSync(path.join(saves, 'world (1)', 'level.dat'), 'utf8'), 'world bytes');
  assert.equal(fs.existsSync(path.join(saves, 'broken')), false);
  pass('multiple saves keep unique names, continue after failure and clean incomplete world');
  console.log(`ALL PASS: ${count} behavior groups; platform APIs mocked, real temporary filesystem used`);
} finally {
  assert(path.resolve(temp).startsWith(path.resolve(workspaceTempRoot()) + path.sep + 'amcl-file-access-'));
  fs.rmSync(temp, { recursive: true, force: true });
}
