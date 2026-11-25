/** 同一次首页启动的可选观察者。检查由原 Sheet 执行，派发仍由创建本次启动的首页负责。 */
export interface LaunchAttemptObserver {
  current(): boolean
  beginChecks(): void
  check(key: string, state: string, fix: string): void
  stop(stage: string, reason: string): void
  bind(activityId: number, isolated: boolean): void
  bindPrivateParams(params: Record<string,string | number>): void
  sent(reused?: boolean): void
}

/** 启动目标先由调用端确认，具体窗口、账户、能力准入和已安装检查由首页完成。 */
export type StartObservedGame = (versionId: string, observer: LaunchAttemptObserver) => Promise<void>
