/**
 * LauncherStartupRuntime — Ability 与首屏之间的一次性准备交接。
 *
 * Ability 仍先安装根目录保护与 native bridge；CA/下载恢复等业务准备留到开屏已经
 * 提交首帧以后执行。页面只等待同一 Promise，重建/重复回调不会重复恢复下载引擎。
 * 不保存 UI 节点或 UIContext；Ability 销毁只撤销未开始的闭包，不取消已开始的耐久工作。
 */
export class LauncherStartupRuntime {
  private static prepare_: (() => Promise<void>) | null = null;
  private static task_: Promise<void> | null = null;
  private static epoch_: number = 0;

  /** 每个新的 Ability 初始化轮次登记自己的准备函数，不修改进程恢复 owner。 */
  static install(prepare: () => Promise<void>): void {
    LauncherStartupRuntime.prepare_ = prepare;
    LauncherStartupRuntime.task_ = null;
    LauncherStartupRuntime.epoch_++;
  }

  /** 同一轮的所有页面共享真实完成结果；先固定 Promise，防止同步重入重复执行。 */
  static prepare(): Promise<void> {
    if (LauncherStartupRuntime.task_ !== null) return LauncherStartupRuntime.task_;
    const prepare = LauncherStartupRuntime.prepare_;
    const epoch: number = LauncherStartupRuntime.epoch_;
    LauncherStartupRuntime.task_ = Promise.resolve().then((): Promise<void> =>
      prepare === null ? Promise.resolve() : prepare()).then((): void => {
      if (epoch === LauncherStartupRuntime.epoch_) LauncherStartupRuntime.prepare_ = null;
    }).catch((error: Error): void => {
      // 失败仍保留本轮闭包，重试重新执行实际准备；旧轮失败不能清掉新 Ability 的任务。
      if (epoch === LauncherStartupRuntime.epoch_) LauncherStartupRuntime.task_ = null;
      throw error;
    });
    return LauncherStartupRuntime.task_;
  }

  /** 销毁时释放尚未开始的 Ability 闭包，已在运行的文件恢复继续按原所有权收口。 */
  static detach(): void {
    LauncherStartupRuntime.prepare_ = null;
    LauncherStartupRuntime.epoch_++;
  }
}
