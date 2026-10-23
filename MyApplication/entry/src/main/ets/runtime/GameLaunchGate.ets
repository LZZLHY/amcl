/**
 * 单局启动single-flight。普通成功/失败都保留原事务；仅原前端退休且尚未进入Native
 * 启动时允许新前端等原准备finally收口后接续。同局不会并行执行两个准备事务。
 * NativeAttempted只是调用边界墓碑，不替代Native的RuntimeOnce/JVM占用权威。
 */
export class GameLaunchGate {
  private task: Promise<void> | undefined = undefined
  private retiredTask: Promise<void> | undefined = undefined
  private nativeAttempted: boolean = false

  /** 只能在实际mcLaunch调用前设置；失败返回或异常也不得通过页面重建自动重试。 */
  markNativeAttempted(): void { this.nativeAttempted = true; this.retiredTask = undefined }

  /** 撤销原前端准备资格，不立即清pending，避免新旧准备并行写同一运行目录。 */
  retireBeforeNative(): void {
    if (!this.nativeAttempted) this.retiredTask = this.task
  }

  run(operation: () => Promise<void>, isCurrent: () => boolean = (): boolean => true): Promise<void> {
    const current: Promise<void> | undefined = this.task
    if (current !== undefined) {
      if (this.retiredTask !== current || this.nativeAttempted) return current
      const resume = (): Promise<void> => {
        // 原准备pending期间可以连续重建多个前端；过期等待者不占用下一次single-flight。
        if (!isCurrent()) return Promise.resolve()
        if (this.task === current && !this.nativeAttempted) {
          this.task = undefined
          this.retiredTask = undefined
        }
        return this.run(operation, isCurrent)
      }
      // 原调用者仍取得原结果；新前端无论旧准备怎样收口都按自己的原操作重新取得资格。
      return current.then(resume, resume)
    }
    const task: Promise<void> = Promise.resolve().then((): Promise<void> => {
      if (!isCurrent()) return Promise.resolve()
      return operation()
    })
    this.task = task
    return task
  }
}
