/**
 * 已装资源元数据的进程内工作闸门。刷新或重进页面仍共用并发预算，旧请求完成前不额外扩容。
 * 已发出的仓储请求由原仓储收尾；被取消的等待项只归还槽位，不再执行其业务闭包。
 */
export class InstalledResourceWork {
  private active_: number = 0;
  private waiters_: Array<() => void> = [];
  private limit_: number;

  constructor(limit: number = 3) { this.limit_ = Math.max(1, limit); }

  /** 获取槽位后再次检查取消，finally 保证成功、失败或取消都能唤醒下一项。 */
  async run(action: () => Promise<void>, cancelled: () => boolean): Promise<void> {
    if (cancelled()) return;
    if (this.active_ < this.limit_) this.active_++;
    else await new Promise<void>((resolve: () => void) => { this.waiters_.push(resolve); });
    try {
      if (!cancelled()) await action();
    } finally {
      const next = this.waiters_.shift();
      if (next !== undefined) next();
      else this.active_--;
    }
  }
}

/** 所有 Sheet 实例共用，避免快速重进叠加多份局部队列。 */
export const installedResourceWork = new InstalledResourceWork(3);
