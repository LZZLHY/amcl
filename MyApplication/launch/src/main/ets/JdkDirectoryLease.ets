/**
 * JDK 槽位协调：writer 锁串行化安装/导入/删除，use 锁只覆盖最终目录发布。
 * 锁文件位于稳定的 jdk/.locks 下，不能随版本目录 rename 或删除。
 * File.tryLock 对应 flock(LOCK_EX|LOCK_NB)，与 native JVM 的共享 use 锁互操作。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ensureDirSync, AppLogger, LOG_DOMAIN_LAUNCH } from 'commons';

interface JdkPlanIoError { code?: number | string; message?: string; }
interface JdkAppPlanFence { phase: string; transactionId: string; }

export class JdkDirectoryLease {
  private file: fs.File | null = null;
  private companion: fs.File | null = null;
  private planKey: string = '';
  private planDirectory: string = '';
  private static activePlan: JdkDirectoryLease | null = null;

  private constructor(file: fs.File) { this.file = file; }

  /** 高层计划全寿命持EX；活跃owner只能由成功取得真实文件锁的本进程对象建立。 */
  static appPlan(filesDir: string, planId: string): JdkDirectoryLease {
    if (!new RegExp('^[a-zA-Z0-9][a-zA-Z0-9._-]{0,95}$').test(planId) || planId.indexOf('..') >= 0 || JdkDirectoryLease.activePlan !== null) throw new Error('App/JDK计划owner无效或正在执行');
    ensureDirSync(filesDir + '/jdk/.locks');
    const file = fs.openSync(filesDir + '/jdk/.locks/app-plan.writer',fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.NOFOLLOW);
    try {
      file.tryLock(true);
      const lease = new JdkDirectoryLease(file); lease.planKey = planId; lease.planDirectory = filesDir;
      JdkDirectoryLease.activePlan = lease; return lease;
    } catch (error) { fs.closeSync(file); throw new Error('已有JDK写者或App兼容计划，请待其结束后重试'); }
  }

  /** 同一主版本只有一个写入任务；下载阶段仍允许游戏读取旧安装。 */
  static writer(filesDir: string, version: string, planId: string = ''): JdkDirectoryLease {
    const active = JdkDirectoryLease.activePlan;
    const ownsPlan = active !== null && active.file !== null && active.planDirectory === filesDir && active.planKey === planId;
    if (planId !== '' && !ownsPlan) throw new Error('没有本进程真实App计划排他owner，不能仅凭id写入JDK');
    let shared: fs.File | null = null; let sharedLocked = false;
    try {
      if (!ownsPlan) {
        ensureDirSync(filesDir + '/jdk/.locks');
        shared = fs.openSync(filesDir + '/jdk/.locks/app-plan.writer',fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.NOFOLLOW);
        shared.tryLock(false); sharedLocked = true;
      }
      // 普通写者从读计划之前到全部槽位I/O结束始终持SH，不能在signed阶段越过高层的最终盘点。
      let text = '';
      try { text = fs.readTextSync(filesDir + '/update-runtime-plan.json'); } catch (error) {
        const detail = error as JdkPlanIoError;
        if (detail.code !== 13900002 && detail.code !== 'ENOENT' && detail.message !== 'ENOENT') throw error as Error;
      }
      if (text.length > 0) {
        if (text.length > 1048576) throw new Error('App/JDK兼容计划超限，暂不允许改动运行时');
        const plan = JSON.parse(text) as JdkAppPlanFence;
        if (typeof plan.transactionId !== 'string' || ['preparing','prepared','signed','restoring','ready-to-install'].indexOf(plan.phase) < 0) throw new Error('App/JDK兼容计划损坏，暂不允许写入');
        if ((plan.phase === 'restoring' || plan.phase === 'ready-to-install') && !ownsPlan) throw new Error('App更新兼容切换尚未确认，请先恢复更新事务');
        if (ownsPlan && plan.transactionId !== planId) throw new Error('App计划owner与持久身份不匹配');
      }
      const lease = JdkDirectoryLease.acquire(filesDir,version,'writer');
      lease.companion = shared; shared = null; return lease;
    } catch (error) {
      if (shared !== null) { try { if (sharedLocked) shared.unlock(); } finally { fs.closeSync(shared); } }
      throw new Error('无法锁定JDK写入资格：' + (error as Error).message);
    }
  }

  /** 发布/删除前取得排他 use 锁；任何正在使用该 JDK 的 JVM 都会使它立即失败。 */
  static publication(filesDir: string, version: string): JdkDirectoryLease {
    return JdkDirectoryLease.acquire(filesDir, version, 'use');
  }

  /** 短只读状态检查也遵守 use.SH，避免双 rename 的瞬间把完整安装误报为缺失。 */
  static reader(filesDir: string, version: string): JdkDirectoryLease {
    return JdkDirectoryLease.acquire(filesDir, version, 'use', false);
  }

  /** 仅供同进程 native 存储端口复核锁 inode；fd 所有权仍在本对象，不能在 native 关闭。 */
  descriptor(): number {
    if (this.file === null) throw new Error('JDK 租约已经释放');
    return this.file.fd;
  }

  private static acquire(filesDir: string, version: string, kind: string, exclusive: boolean = true): JdkDirectoryLease {
    if (!new RegExp('^[0-9]{1,3}$').test(version)) throw new Error('JDK 槽位标识无效');
    const directory = filesDir + '/jdk/.locks';
    ensureDirSync(directory);
    const file = fs.openSync(directory + '/' + version + '.' + kind, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.NOFOLLOW);
    try {
      file.tryLock(exclusive);
      return new JdkDirectoryLease(file);
    } catch (e) {
      try { fs.closeSync(file) } catch (closeError) { /* 未取得锁，关闭异常不覆盖原错误。 */ }
      const error = e as BusinessError;
      if (error.code === 13900034) {
        throw new Error(kind === 'use' ? 'JDK ' + version + ' 正在使用，请关闭游戏或安装器后重试'
          : 'JDK ' + version + ' 已有安装、导入或删除任务');
      }
      throw new Error('无法锁定 JDK ' + version + '：' + error.message);
    }
  }

  /** 每个fd分别释放，次要关闭错误不掩盖原业务错误，也不阻断另一个fd归还。 */
  private static releaseFile(file: fs.File, label: string): void {
    try { file.unlock(); } catch (error) { AppLogger.warn('JdkDirectoryLease',label + ' unlock失败，继续关闭fd',error as Object,LOG_DOMAIN_LAUNCH); }
    try { fs.closeSync(file); } catch (error) { AppLogger.warn('JdkDirectoryLease',label + ' close失败',error as Object,LOG_DOMAIN_LAUNCH); }
  }

  /** 幂等释放：先归还槽writer，再归还全寿命SH；全局EX owner清除不能被id字符串继续借用。 */
  release(): void {
    const file = this.file; const companion = this.companion;
    this.file = null; this.companion = null;
    if (JdkDirectoryLease.activePlan === this) JdkDirectoryLease.activePlan = null;
    if (file !== null) JdkDirectoryLease.releaseFile(file,'slot/plan');
    if (companion !== null) JdkDirectoryLease.releaseFile(companion,'global writer SH');
  }
}
