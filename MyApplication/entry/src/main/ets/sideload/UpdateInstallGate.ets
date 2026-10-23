/** 安装与游戏共用文件锁。Native 游戏持共享锁，更新持排他锁，覆盖多进程及异步启动窗口。 */
import { fileIo as fs } from '@kit.CoreFileKit';
import testNapi from 'libentry.so';
import { InstallExecutionError } from './SideloadInstallProtocol';

export class UpdateInstallGate {
  private file: fs.File | undefined = undefined;
  private foreground: boolean = true;
  private owner: string = '';

  setForeground(value: boolean): void { this.foreground = value; }
  /** 未派发安装只能在可见前台推进；前提检查必须在每个 await 后重新执行。 */
  assertForeground(): void {
    if (!this.foreground) throw new InstallExecutionError('foreground', '已暂停安装，返回 AMCL 后会继续');
  }
  /** 查询当前进程和现有独立游戏锁，未知状态也拒绝安装。 */
  assertNoGame(filesDir: string): void {
    if (testNapi.mcIsRunning() || testNapi.desktopGameProcessState(filesDir, 0) !== 0) {
      throw new Error('请先保存并退出所有游戏窗口');
    }
  }
  /** tryLock 是非阻塞排他 flock；锁文件固定在 filesDir，不能随事务目录删除。 */
  acquire(filesDir: string, owner: string = 'legacy', recovery: boolean = false): void {
    if (this.file !== undefined) {
      if (this.owner !== owner) throw new InstallExecutionError('outcome-unknown', '安装租约已有其他所有者');
      return;
    }
    if (!recovery) this.assertForeground();
    this.assertNoGame(filesDir);
    let file: fs.File | undefined = undefined;
    try {
      file = fs.openSync(filesDir + '/.sideload-install.lock', fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.NOFOLLOW);
      file.tryLock(true); this.file = file; this.owner = owner;
    } catch (_) {
      if (file !== undefined) { try { fs.closeSync(file); } catch (_) { /* 未认领的句柄失败不放宽准入。 */ } }
      throw new Error('游戏或其他文件操作正在进行，请稍后更新');
    }
  }
  release(owner: string = 'legacy'): void {
    if (this.file !== undefined && this.owner !== owner) return;
    const file = this.file;
    if (file !== undefined) {
      // 关闭失败时保留owner，后续受控收尾仍可重试，不能丢失一个尚未关闭的排他FD。
      try { fs.closeSync(file); this.file = undefined; this.owner = ''; }
      catch (error) { throw error as Error; }
    }
  }
}
