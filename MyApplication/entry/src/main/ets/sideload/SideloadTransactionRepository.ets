/**
 * 自更新事务的唯一持久化边界。Repository不持业务状态；调用方只在commit成功后替换内存快照。
 * schema1先按原字节备份再升级，未知安装阶段保留原协议身份，绝不伪造新执行权证明。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { AtomicWriteError } from 'commons';
import { SideloadUpdateTransaction, SideloadTransactionPolicy } from 'update';
import { SideloadFiles } from './SideloadFiles';

export class SideloadTransactionRepository {
  private root: string;
  private path: string;
  private allowSameVersion: boolean;
  private lockPath: string;

  /** 路径只由应用filesDir构造，所有载荷继续受原事务策略的内部目录约束。 */
  constructor(root: string, allowSameVersion: boolean) {
    this.root = root; this.path = root + '/transaction.json'; this.allowSameVersion = allowSameVersion;
    this.lockPath = root + '/.sideload-transaction.lock';
  }

  /** 读取独立副本；过大或损坏输入保留原件并拒绝执行，恢复方不能将它当作没有安装风险。 */
  load(): SideloadUpdateTransaction | undefined {
    const lock = this.acquireLock();
    try { return this.loadUnlocked(); }
    finally { fs.closeSync(lock); }
  }

  /** 读取/原字节备份/schema升级处在同一journal EX，升级不能再另开FD重入锁。 */
  private loadUnlocked(): SideloadUpdateTransaction | undefined {
    if (!fs.accessSync(this.path)) return undefined;
    if (fs.statSync(this.path).size > 64 * 1024) throw new Error('更新事务记录过大，请保留现场并核实安装结果');
    const body = fs.readTextSync(this.path);
    const value = JSON.parse(body) as SideloadUpdateTransaction;
    if (!SideloadTransactionPolicy.validate(value, this.root, this.allowSameVersion)) throw new Error('更新事务记录无效，请保留现场并核实安装结果');
    if (value.schema === 2) return value;
    // 原字节只追加备份，旧失败正文不改写；备份失败时禁止用新schema覆盖唯一旧记录。
    const backup = this.root + '/transaction-schema1-' + value.id + '.json';
    if (!fs.accessSync(backup)) SideloadFiles.write(backup, body);
    value.ownerAttemptId = value.id; value.installProtocol = 1;
    return this.commitLocked(value, 0);
  }

  /**
   * expectedRevision在专用journal EX内读盘比较；先生成副本、可靠写盘，再把已提交对象交给Coordinator。
   * rename后的目录同步失败原样抛AtomicWriteError(durability-unknown)，不能继续副作用。
   */
  commit(value: SideloadUpdateTransaction, expectedRevision: number): SideloadUpdateTransaction {
    // 独立短期journal EX不使用安装锁；下载持有安装SH时也可以安全提交字节/阶段。
    const lock = this.acquireLock();
    try { return this.commitLocked(value, expectedRevision); }
    finally { fs.closeSync(lock); }
  }

  /** 固定文件且NOFOLLOW；不会和安装SH/EX共用inode，因此下载提交不自锁。 */
  private acquireLock(): fs.File {
    const lock = fs.openSync(this.lockPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.NOFOLLOW);
    try { lock.tryLock(true); return lock; }
    catch (_) { fs.closeSync(lock); throw new Error('更新记录正在提交，请稍后核实'); }
  }

  /** 仅在专用journal EX持有期间读revision和发布，跨进程不会出现两个CAS赢家。 */
  private commitLocked(value: SideloadUpdateTransaction, expectedRevision: number): SideloadUpdateTransaction {
    let diskRevision = 0;
    if (fs.accessSync(this.path)) {
      const disk = JSON.parse(fs.readTextSync(this.path)) as SideloadUpdateTransaction;
      diskRevision = disk.schema === 2 ? disk.revision ?? 0 : 0;
    }
    if (diskRevision !== expectedRevision) throw new Error('更新事务已由另一修订改变，请重新核实');
    const next = JSON.parse(JSON.stringify(value)) as SideloadUpdateTransaction;
    next.schema = 2; next.revision = expectedRevision + 1;
    if (!SideloadTransactionPolicy.validate(next, this.root, this.allowSameVersion)) throw new Error('更新事务提交身份无效');
    SideloadFiles.write(this.path, JSON.stringify(next));
    return next;
  }

  /** 只有已知typed错误才允许区分rename前/后；未知耐久性必须封住安装effect。 */
  static durabilityUnknown(error: Error): boolean {
    return error instanceof AtomicWriteError && error.kind === 'durability-unknown';
  }
}
