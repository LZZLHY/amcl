/**
 * 当前数字槽位的最小持久发布事务。与尚未整合的Native候选无依赖；只处理本模块写出的
 * 精确目标/staging/backup身份，未知记录保留现场。调用者在全过程持writer，恢复/发布另持use.EX。
 * PREPARED先持久化再rename；恢复优先保留已经完整发布的新目录，否则恢复原目录。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { ensureDirSync, removeDirRecursive } from 'commons';
import { JdkDirectoryLease } from './JdkDirectoryLease';
import { validateRuntimeTree } from './JdkTreeValidation';

interface JdkPublishRecord {
  schemaVersion: number; major: string; stage: string; backup: string; previous: string; next: string;
}

/** 元数据在目录内随内容发布；这里只比较受控元数据，不把目录名/mtime当所有权凭证。 */
function identity(path: string): string {
  const directory = fs.lstatSync(path);
  if (!directory.isDirectory()) throw new Error('JDK事务目标不是独立真实目录');
  let tag = ''; let receipt = '';
  try { tag = fs.readTextSync(path + '/.amcl_release_tag'); } catch (_) { /* 旧安装可无戳。 */ }
  try { receipt = fs.readTextSync(path + '/.amcl-runtime-receipt.json'); } catch (_) { /* 旧安装可无收据。 */ }
  if (tag.length + receipt.length > 65536) throw new Error('JDK 来源元数据超限');
  return JSON.stringify([directory.ino.toString(),tag,receipt]);
}
function sameInode(path: string, recorded: string): boolean {
  const fields = JSON.parse(recorded) as string[];
  const directory = fs.lstatSync(path);
  return directory.isDirectory() && Array.isArray(fields) && fields.length === 3 && directory.ino.toString() === fields[0];
}
interface JournalIoError { code?: number | string; message?: string; }
function exists(path: string): boolean {
  try { fs.lstatSync(path); return true; } catch (error) {
    const detail = error as JournalIoError;
    if (detail.code === 13900002 || detail.code === 'ENOENT' || detail.message === 'ENOENT') return false;
    throw error as Error;
  }
}
/** 父目录同步失败必须停止；不能把仅file fsync称作目录切换已经耐久。 */
function syncDirectory(path: string): void {
  if (!fs.lstatSync(path).isDirectory()) throw new Error('JDK同步父目录不是独立真实目录');
  const file = fs.openSync(path,fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
  try { fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
}
interface SyncBudget { entries: number; bytes: number; }
/** 发布前同步候选全部普通文件与目录；拒绝链接和特殊节点，不让事后rename掩盖未落盘内容。 */
async function syncTree(path: string, budget: SyncBudget, depth: number = 0): Promise<void> {
  if (++budget.entries > 20000 || depth > 32) throw new Error('JDK发布同步超过目录预算');
  // 小批让出事件循环，避免成千文件的同步刷盘把安装界面连续阻塞成冻屏。writer仍跨await持有。
  if (budget.entries % 32 === 0) await new Promise<void>((resolve): void => { setTimeout((): void => resolve(),0); });
  const stat = fs.lstatSync(path);
  if (stat.isDirectory()) {
    for (const name of fs.listFileSync(path)) await syncTree(path + '/' + name,budget,depth + 1);
    syncDirectory(path);
  } else if (stat.isFile()) {
    budget.bytes += stat.size;
    if (budget.bytes > 2147483647) throw new Error('JDK发布同步超过体积预算');
    const file = fs.openSync(path,fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    try { fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
  } else throw new Error('JDK候选包含链接或特殊节点');
}
function root(filesDir: string): string { return filesDir + '/jdk'; }
function recordPath(filesDir: string, major: string): string { return root(filesDir) + '/.locks/' + major + '.publish.json'; }

export class JdkInstallJournal {
  /** 高层EX已取得后也恢复先前普通写者遗留的记录；不遗漏两次rename中间暂缺的数字槽。 */
  static recoverAllWithOwner(filesDir: string, planId: string): void {
    const directory = root(filesDir) + '/.locks'; if (!exists(directory)) return;
    if (!fs.lstatSync(directory).isDirectory()) throw new Error('JDK锁目录不是独立真实目录');
    const names = fs.listFileSync(directory); if (names.length > 8192) throw new Error('JDK恢复目录项超限');
    for (const name of names) {
      const match = name.match(new RegExp('^([1-9][0-9]{0,2})\\.publish\\.json$')); if (match === null) continue;
      const writer = JdkDirectoryLease.writer(filesDir,match[1],planId);
      try { JdkInstallJournal.recoverWithWriter(filesDir,match[1]); } finally { writer.release(); }
    }
  }

  /** 查询不改变文件；I/O异常保持失败关闭，不能把不可读记录当作没有事务。 */
  static recoveryRequired(filesDir: string, major: string): boolean { return exists(recordPath(filesDir,major)); }

  /** 同步原子提交短记录。文件写全、fsync、rename、父目录fsync按顺序完成。 */
  private static save(filesDir: string, record: JdkPublishRecord): void {
    const locks = root(filesDir) + '/.locks'; ensureDirSync(locks);
    syncDirectory(filesDir); syncDirectory(root(filesDir));
    const path = recordPath(filesDir,record.major); const temp = path + '.writing';
    const file = fs.openSync(temp,fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW);
    try {
      // JSON已转成ASCII，避免中文字符数与write字节数不同造成截断。
      const value = JSON.stringify(record).replace(new RegExp('[^\\x00-\\x7f]','g'),(c: string): string =>
        '\\u' + c.charCodeAt(0).toString(16).padStart(4,'0'));
      if (value.length > 1048576) throw new Error('JDK事务记录超限');
      if (fs.writeSync(file.fd,value) !== value.length) throw new Error('JDK 事务记录未完整写入');
      fs.fsyncSync(file.fd);
    } finally { fs.closeSync(file); }
    fs.renameSync(temp,path); syncDirectory(locks);
  }

  /** 只认本事务固定路径与inode身份；损坏/未知现场不自动删除，也不猜哪个backup最新。 */
  static recoverWithWriter(filesDir: string, major: string): void {
    if (!new RegExp('^[1-9][0-9]{0,2}$').test(major)) throw new Error('JDK恢复槽位非法');
    const path = recordPath(filesDir,major); if (!exists(path)) return;
    const stat = fs.lstatSync(path);
    if (!stat.isFile() || stat.size <= 0 || stat.size > 1048576) throw new Error('JDK 恢复记录损坏，已保留现场');
    const record = JSON.parse(fs.readTextSync(path)) as JdkPublishRecord;
    const base = root(filesDir); const target = base + '/' + major;
    if (record.schemaVersion !== 1 || record.major !== major ||
      !new RegExp('^[1-9][0-9]{0,2}\\.backup-[0-9-]+$').test(record.backup) ||
      !record.backup.startsWith(major + '.backup-') ||
      !new RegExp('^\\.staging-[a-zA-Z0-9-]+$').test(record.stage) ||
      typeof record.previous !== 'string' || typeof record.next !== 'string' || record.next.length === 0) {
      throw new Error('JDK 恢复记录身份无效，已保留现场');
    }
    const lease = JdkDirectoryLease.publication(filesDir,major);
    try {
      const backup = base + '/' + record.backup; const stage = base + '/' + record.stage;
      if (exists(target) && identity(target) === record.next) {
        if (validateRuntimeTree(target,major) !== '') throw new Error('已发布JDK内容异常，保留恢复现场');
      } else if (record.previous.length > 0) {
        if (exists(target)) {
          if (identity(target) !== record.previous || exists(backup)) throw new Error('JDK恢复遇到未知目标组合');
        } else {
          if (!exists(backup) || identity(backup) !== record.previous) throw new Error('JDK恢复找不到原安装身份');
          fs.renameSync(backup,target); syncDirectory(base);
        }
      } else if (exists(target) || exists(backup)) throw new Error('首次JDK安装恢复遇到未知目标');
      syncDirectory(base);
      if (exists(backup)) {
        if (!sameInode(backup,record.previous)) throw new Error('JDK备份inode改变，保留现场');
        removeDirRecursive(backup); syncDirectory(base);
      }
      if (exists(stage)) {
        if (!sameInode(stage,record.next)) throw new Error('JDK暂存inode改变，保留现场');
        removeDirRecursive(stage); syncDirectory(base);
      }
      fs.unlinkSync(path); syncDirectory(base + '/.locks');
    } finally { lease.release(); }
  }

  /** writer由业务持有；此方法内部取得use.EX，任何使用中的JVM都使发布立即失败。 */
  static async publish(filesDir: string, major: string, stage: string, mayPublish: () => boolean = (): boolean => true): Promise<void> {
    const base = root(filesDir); const target = base + '/' + major;
    if (stage.substring(0,base.length + 1) !== base + '/' ||
      !new RegExp('^\\.staging-[a-zA-Z0-9-]+$').test(stage.substring(base.length + 1))) throw new Error('JDK暂存路径不受控');
    JdkInstallJournal.recoverWithWriter(filesDir,major);
    await syncTree(stage,{entries:0,bytes:0});
    if (!mayPublish()) throw new Error('JDK发布前已取消或构建撤回，旧安装保持不变');
    const lease = JdkDirectoryLease.publication(filesDir,major);
    const backupName = major + '.backup-' + Date.now().toString() + '-' + Math.floor(Math.random()*1000000000).toString();
    const record: JdkPublishRecord = { schemaVersion:1,major:major,stage:stage.substring(base.length + 1),backup:backupName,
      previous:exists(target) ? identity(target) : '',next:identity(stage) };
    try {
      JdkInstallJournal.save(filesDir,record);
      if (record.previous.length > 0) { fs.renameSync(target,base + '/' + backupName); syncDirectory(base); }
      fs.renameSync(stage,target); syncDirectory(base);
    } finally { lease.release(); }
    // 统一走重入恢复完成清理；中途失败留下记录，由下次启动/任务接续恢复。
    JdkInstallJournal.recoverWithWriter(filesDir,major);
  }

  /** finally不能删除尚被journal引用的唯一新副本；持久恢复完成后才有清理资格。 */
  static mayDiscard(filesDir: string, major: string): boolean { return !exists(recordPath(filesDir,major)); }
}
