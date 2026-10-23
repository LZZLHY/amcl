/** 直接执行生产租约与导入入口，验证写者互斥、读写分离及失败不触碰旧安装。 */
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
const handles = new Set(), locks = new Map();
let failure = 0, hashCalls = 0;
class File {
  constructor(path) { this.path = path; handles.add(this); }
  tryLock(exclusive = true) {
    const owners = locks.get(this.path) ?? [];
    if (failure || owners.some(x => exclusive || x.exclusive)) {
      const error = new Error('controlled file lock error'); error.code = failure || 13900034; throw error;
    }
    owners.push({ file: this, exclusive }); locks.set(this.path, owners);
  }
  unlock() { locks.set(this.path, (locks.get(this.path) ?? []).filter(x => x.file !== this)); }
}
const io = {
  OpenMode: { CREATE: 1, READ_WRITE: 2 },
  openSync: path => new File(path),
  closeSync: file => { file.unlock(); handles.delete(file); },
};
const load = makePureEtsLoader({
  '@kit.CoreFileKit': { fileIo: io }, '@kit.BasicServicesKit': {},
  commons: { ensureDirSync() {}, removeDirRecursive() {}, AppLogger: { warn() {}, error() {}, info() {} } },
  feature_core: { VersionFileVerifier: { async sha256File() { ++hashCalls; return 'x'; } } },
});
const Lease = load('launch/src/main/ets/JdkDirectoryLease.ets').JdkDirectoryLease;
const Importer = load('launch/src/main/ets/JdkImporter.ets').JdkImporter;
const writer = Lease.writer('/sandbox', '17');
assert.throws(() => Lease.writer('/sandbox', '17'), /已有/);
const different = Lease.writer('/sandbox', '21');
const reader = io.openSync('/sandbox/jdk/.locks/17.use'); reader.tryLock(false);
assert.throws(() => Lease.publication('/sandbox', '17'), /正在使用/);
const imported = await Importer.importFromZip({ filesDir: '/sandbox' }, '17', '/input.zip');
assert.equal(imported.ok, false); assert.equal(hashCalls, 0, '冲突导入不能开始读取/替换候选包');
io.closeSync(reader);
const publication = Lease.publication('/sandbox', '17');
const blockedReader = io.openSync('/sandbox/jdk/.locks/17.use');
assert.throws(() => blockedReader.tryLock(false)); io.closeSync(blockedReader);
publication.release(); publication.release();
writer.release(); different.release();
assert.throws(() => Lease.writer('/sandbox', '../17'), /标识无效/);
failure = 13900013;
assert.throws(() => Lease.writer('/sandbox', '17'), /无法锁定/);
assert.equal(handles.size, 0, '失败/幂等释放都不能泄漏文件句柄');
console.log('PASS production JDK leases: writer exclusion, reader/publication exclusion, separate slots, early import refusal and descriptor cleanup');
