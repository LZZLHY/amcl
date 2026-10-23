/**
 * JDK 槽位协调：writer 锁串行化安装/导入/删除，use 锁只覆盖最终目录发布。
 * 锁文件位于稳定的 jdk/.locks 下，不能随版本目录 rename 或删除。
 * File.tryLock 对应 flock(LOCK_EX|LOCK_NB)，与 native JVM 的共享 use 锁互操作。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ensureDirSync, AppLogger, LOG_DOMAIN_LAUNCH } from 'commons';

export class JdkDirectoryLease {
  private file: fs.File | null = null;

  private constructor(file: fs.File) { this.file = file; }

  /** 同一主版本只有一个写入任务；下载阶段仍允许游戏读取旧安装。 */
  static writer(filesDir: string, version: string): JdkDirectoryLease {
    return JdkDirectoryLease.acquire(filesDir, version, 'writer');
  }

  /** 发布/删除前取得排他 use 锁；任何正在使用该 JDK 的 JVM 都会使它立即失败。 */
  static publication(filesDir: string, version: string): JdkDirectoryLease {
    return JdkDirectoryLease.acquire(filesDir, version, 'use');
  }

  private static acquire(filesDir: string, version: string, kind: string): JdkDirectoryLease {
    if (!new RegExp('^[0-9]{1,3}$').test(version)) throw new Error('JDK 槽位标识无效');
    const directory = filesDir + '/jdk/.locks';
    ensureDirSync(directory);
    const file = fs.openSync(directory + '/' + version + '.' + kind, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
    try {
      file.tryLock(true);
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

  /** 幂等释放；先撤销 JS 所有权，保证 finally 重入不会再次关闭同一 fd。 */
  release(): void {
    const file = this.file;
    this.file = null;
    if (file === null) return;
    try { file.unlock() } catch (e) {
      AppLogger.warn('JdkDirectoryLease', 'unlock failed; closing owned fd', e as Object, LOG_DOMAIN_LAUNCH);
    }
    try { fs.closeSync(file) } catch (e) {
      AppLogger.warn('JdkDirectoryLease', 'close lease fd failed', e as Object, LOG_DOMAIN_LAUNCH);
    }
  }
}
