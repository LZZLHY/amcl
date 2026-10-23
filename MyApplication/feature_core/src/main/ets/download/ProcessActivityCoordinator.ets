/**
 * 同一进程内的游戏与持续文件任务准入。手机兼容路线退出 JVM 必须结束整个进程，
 * 不能与尚未收口的下载、导出复制或目标读回重叠；真正隔离的 GameAbility 不取得这里
 * 的游戏预约，因此父启动器的文件任务仍可并行。
 * 所有方法在同一 ArkTS 事件循环同步执行，检查和占位之间没有 await。这不是跨进程
 * 锁，也不替代版本租约、Native execution-settled 或安装围栏。文件预约必须持到业务
 * finally 的真实结束，不能按 UI 终态或取消请求提前释放。
 */
export class SharedProcessGameLease {
  private committed_: boolean = false;
  private released_: boolean = false;
  private readonly release_: () => void;

  /** 协调器创建的原预约；闭包绑定身份，其他对象不能释放当前游戏的占位。 */
  constructor(release: () => void) { this.release_ = release; }

  /**
   * 紧邻实际 Native 启动调用且在最后的前端/授权核验后提交。Native 即使失败也可能已经
   * 创建 JVM 或污染 renderer；此后只由真实进程结束撤销占位，不能凭 rc 或页面销毁
   * 开放新文件任务，再被既有 _exit 一并终止。
   */
  commitNativeDispatch(): void {
    if (this.released_) throw new Error('游戏进程预约已失效，请重新发起启动');
    this.committed_ = true;
  }

  /** 只释放尚未进入 Native 的准备预约；幂等，已提交游戏一直保护到真实进程结束。 */
  releasePreparation(): void {
    if (this.released_ || this.committed_) return;
    this.released_ = true;
    this.release_();
  }
}

/** 仅用于同进程对象身份；没有可由 UI 冒认的字符串主键。 */
class ProcessFileReservation {}

export class ProcessActivityCoordinator {
  private static owner_: ProcessActivityCoordinator | undefined = undefined;
  private files_: Set<ProcessFileReservation> = new Set<ProcessFileReservation>();
  private sharedGame_: SharedProcessGameLease | undefined = undefined;

  /** 同进程 HAR 单例；独立游戏进程拥有自己的实例，不借父侧布尔值授予退出权限。 */
  static instance(): ProcessActivityCoordinator {
    if (ProcessActivityCoordinator.owner_ === undefined) ProcessActivityCoordinator.owner_ = new ProcessActivityCoordinator();
    return ProcessActivityCoordinator.owner_;
  }

  /**
   * 第一个异步步骤前预约，到执行/取消/验证真正结束才释放。同一业务允许嵌套预约，
   * 不同文件业务可以并行，它们只排斥共享游戏。释放闭包绑定原对象且幂等；不接受
   * 任务 id 冒认，也不从展示列表推断空闲。
   */
  acquireFileTask(reason: string): () => void {
    if (this.sharedGame_ !== undefined) {
      throw new Error('游戏正在本应用进程中准备或运行，请结束游戏并返回启动器后再开始' + reason);
    }
    const owner: ProcessFileReservation = new ProcessFileReservation();
    this.files_.add(owner);
    return (): void => { this.files_.delete(owner); };
  }

  /**
   * 只有真实共享进程路线调用。文件任务已预约时明确拒绝本次游戏，不取消原工作；
   * 没有文件工作时立即占位。准备失败或前端提前离开须在 finally 释放未提交预约。
   */
  acquireSharedGame(): SharedProcessGameLease {
    if (this.files_.size > 0) throw new Error('导出、下载或文件任务尚未结束，请完成或取消后再启动游戏');
    if (this.sharedGame_ !== undefined) throw new Error('当前游戏进程已被预约，请返回现有游戏或重启应用');
    const lease: SharedProcessGameLease = new SharedProcessGameLease((): void => {
      if (this.sharedGame_ === lease) this.sharedGame_ = undefined;
    });
    this.sharedGame_ = lease;
    return lease;
  }
}
