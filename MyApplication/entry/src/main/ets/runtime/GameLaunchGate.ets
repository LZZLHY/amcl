/** One launch transaction per page, including asynchronous preparation and failure. */
export class GameLaunchGate {
  private task: Promise<void> | undefined = undefined

  run(operation: () => Promise<void>): Promise<void> {
    const current: Promise<void> | undefined = this.task
    if (current !== undefined) return current
    const task: Promise<void> = Promise.resolve().then((): Promise<void> => operation())
    this.task = task
    return task
  }
}
