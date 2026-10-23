/**
 * 本地资源扫描的宿主线程调度与取消范围。
 * 文件计算和来源反查分别使用共享的两个槽位；重复开页不会创建无界文件任务。
 * 控制器只在宿主线程使用，不跨线程传递闭包、组件或网络仓储。
 */
import { taskpool } from '@kit.ArkTS';

/** 一轮扫描的取消状态；取消后不可复用，应为下一轮创建新实例。 */
export class LocalModScanControl {
  private cancelled_: boolean = false;
  private tasks_: Set<taskpool.Task> = new Set<taskpool.Task>();

  /** 停止后续工作，并通知已提交的文件任务在块边界退出。重复调用安全。 */
  cancel(): void {
    if (this.cancelled_) return;
    this.cancelled_ = true;
    this.tasks_.forEach((task: taskpool.Task): void => {
      try { taskpool.cancel(task); } catch (_) { /* 已结束或尚未入队，无需重复取消。 */ }
    });
  }

  /** 调用方在网络等待后也须检查此状态，取消的结果不得写回界面或索引。 */
  isCancelled(): boolean { return this.cancelled_; }

  /** 调度内部登记任务；返回 false 表示该范围已取消，不应提交。 */
  track(task: taskpool.Task): boolean {
    if (this.cancelled_) return false;
    this.tasks_.add(task);
    return true;
  }

  /** 调度内部在 finally 解绑，避免控制器长期保留已结束的任务。 */
  untrack(task: taskpool.Task): void { this.tasks_.delete(task); }
}

/** 有界异步闸门。等待者只保留轻量回调，获得槽位后再检查取消。 */
class ScanWorkGate {
  private active_: number = 0;
  private waiting_: Array<() => void> = [];

  /** 等待可用槽位；移交时 active 不减，避免新请求越过已排队的工作。 */
  private async acquire(): Promise<void> {
    if (this.active_ < 2) { this.active_++; return; }
    await new Promise<void>((resolve: () => void): void => { this.waiting_.push(resolve); });
  }

  /** 只在对应执行的 finally 调用一次。 */
  private release(): void {
    const next = this.waiting_.shift();
    if (next !== undefined) next();
    else this.active_--;
  }

  /** 当前工作失败仍释放槽位；排队取消不会执行 work。 */
  async run<T>(work: () => Promise<T>, control?: LocalModScanControl): Promise<T> {
    await this.acquire();
    try {
      if (control?.isCancelled()) throw new Error('LocalModScanCancelled');
      return await work();
    } finally { this.release(); }
  }
}

// 两个闸门不能合并：来源链持有自己的槽位时还会等待一次文件计算。
const fileGate: ScanWorkGate = new ScanWorkGate();
const sourceGate: ScanWorkGate = new ScanWorkGate();

/** 全进程文件计算预算；TaskPool 自身的线程池上限不能替代业务预算。 */
export async function runModFileTask(task: taskpool.Task, control?: LocalModScanControl): Promise<Object> {
  return fileGate.run<Object>(async (): Promise<Object> => {
    if (control !== undefined && !control.track(task)) throw new Error('LocalModScanCancelled');
    try {
      return await taskpool.execute(task, taskpool.Priority.LOW);
    } catch (e) {
      // 保留 TaskPool 的取消/执行异常，扫描层决定是否退化成未知来源。
      throw e as Error;
    } finally { control?.untrack(task); }
  }, control);
}

/** 限制同时进行的来源查询链；网络请求已发出时等待其结束，不再启动后继查询。 */
export async function runModSourceWork(work: () => Promise<void>, control?: LocalModScanControl): Promise<void> {
  await sourceGate.run<void>(work, control);
}
