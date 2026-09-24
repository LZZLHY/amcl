export type LaunchPreferenceValue = string | number | boolean

export interface LaunchPreferenceSnapshot {
  name: string
  values: Record<string, LaunchPreferenceValue>
}

export interface LaunchPreferenceStore {
  getSync(key: string, fallback: LaunchPreferenceValue): LaunchPreferenceValue
  get(key: string, fallback: LaunchPreferenceValue): Promise<LaunchPreferenceValue>
  putSync(key: string, value: LaunchPreferenceValue): void
  put(key: string, value: LaunchPreferenceValue): Promise<void>
  deleteSync(key: string): void
  flush(): Promise<void>
}

/**
 * entry 注入的本局布局日志提交器。base 永远是启动快照，proposed 是累计布局状态；
 * Promise resolve 必须表示日志已持久提交，不能只是进入内存队列。账号和设置不使用此接口。
 */
export interface GameLayoutCommitSink {
  commit(base: LaunchPreferenceSnapshot, proposed: LaunchPreferenceSnapshot): Promise<void>
}

export function copyLaunchPreferenceSnapshot(snapshot: LaunchPreferenceSnapshot): LaunchPreferenceSnapshot {
  if (!snapshot || typeof snapshot.name !== 'string' || !snapshot.values || typeof snapshot.values !== 'object' || Array.isArray(snapshot.values)) {
    throw new Error('Invalid launch preferences snapshot')
  }
  const values: Record<string, LaunchPreferenceValue> = {}
  for (const key of Object.keys(snapshot.values)) {
    const value: LaunchPreferenceValue = snapshot.values[key]
    if (key === '__proto__' || key === 'constructor' || key === 'prototype' ||
      (typeof value !== 'string' && typeof value !== 'boolean' && typeof value !== 'number') ||
      (typeof value === 'number' && !Number.isFinite(value))) throw new Error('Invalid snapshot preference value')
    values[key] = value
  }
  return { name: snapshot.name, values: values }
}

export function createLaunchPreferenceStores(snapshots: LaunchPreferenceSnapshot[]): Map<string, LaunchPreferenceStore> {
  const next: Map<string, LaunchPreferenceStore> = new Map<string, LaunchPreferenceStore>()
  for (const item of snapshots) {
    if (!item || !['amcl_accounts', 'amcl_settings', 'control_layout'].includes(item.name) || next.has(item.name)) {
      throw new Error('Unknown or duplicate launch preferences store')
    }
    next.set(item.name, new ReadOnlyLaunchPreferences(item))
  }
  if (next.size !== 3) throw new Error('Incomplete game preferences snapshot')
  return next
}

/** Immutable session input. Persistence belongs to the launcher process. */
export class ReadOnlyLaunchPreferences implements LaunchPreferenceStore {
  private snapshot: LaunchPreferenceSnapshot
  constructor(snapshot: LaunchPreferenceSnapshot) { this.snapshot = copyLaunchPreferenceSnapshot(snapshot) }
  getSync(key: string, fallback: LaunchPreferenceValue): LaunchPreferenceValue {
    return Object.keys(this.snapshot.values).includes(key) ? this.snapshot.values[key] : fallback
  }
  async get(key: string, fallback: LaunchPreferenceValue): Promise<LaunchPreferenceValue> { return this.getSync(key, fallback) }
  putSync(_key: string, _value: LaunchPreferenceValue): void { throw new Error('Game launch preferences are read-only; edit launcher settings for the next launch') }
  async put(key: string, value: LaunchPreferenceValue): Promise<void> { this.putSync(key, value) }
  deleteSync(_key: string): void { throw new Error('Game launch preferences are read-only') }
  async flush(): Promise<void> {}
}

/**
 * 独立游戏进程仅可编辑 control_layout 的两个字符串键。这里没有 Preferences/XML 句柄。
 * put 先写本局 overlay，flush 委托 entry 持久提交；失败恢复上次成功版本，并传播异常。
 * 提交期间拒绝新的 put，防止失败回滚吞掉另一笔并发编辑；重复 flush 共用同一次提交。
 */
export class GameLayoutLaunchPreferences implements LaunchPreferenceStore {
  private base: LaunchPreferenceSnapshot
  private committed: LaunchPreferenceSnapshot
  private overlay: LaunchPreferenceSnapshot
  private sink: GameLayoutCommitSink
  private pending: Promise<void> | undefined = undefined
  private committing: boolean = false

  constructor(snapshot: LaunchPreferenceSnapshot, sink: GameLayoutCommitSink) {
    if (snapshot.name !== 'control_layout') throw new Error('Only game control layouts may have a commit sink')
    if (!sink || typeof sink.commit !== 'function') throw new Error('Game layout commit sink is missing')
    this.base = copyLaunchPreferenceSnapshot(snapshot)
    this.committed = copyLaunchPreferenceSnapshot(snapshot)
    this.overlay = copyLaunchPreferenceSnapshot(snapshot)
    this.sink = sink
  }

  getSync(key: string, fallback: LaunchPreferenceValue): LaunchPreferenceValue {
    return Object.keys(this.overlay.values).includes(key) ? this.overlay.values[key] : fallback
  }
  async get(key: string, fallback: LaunchPreferenceValue): Promise<LaunchPreferenceValue> {
    return this.getSync(key, fallback)
  }
  putSync(key: string, value: LaunchPreferenceValue): void {
    if (this.committing) throw new Error('A game layout commit is in progress')
    if ((key !== 'profiles' && key !== 'active_profile') || typeof value !== 'string') {
      throw new Error('Only profiles and active_profile strings may be changed in the game process')
    }
    // 这里先限制字符串分配上限；布局业务的 UTF-8 字节、数量和结构由 sink 的纯 merge 校验。
    if (value.length > 1024 * 1024 || (key === 'active_profile' && value.length > 256)) {
      throw new Error('Game layout preference exceeds the size limit')
    }
    this.overlay.values[key] = value
  }
  async put(key: string, value: LaunchPreferenceValue): Promise<void> { this.putSync(key, value) }
  deleteSync(_key: string): void {
    throw new Error('Game layout keys cannot be deleted; submit a complete layout snapshot')
  }
  /**
   * 撤销尚未 flush 的两键暂存，例如 profiles 已 put、active_profile 随后失败的半笔写入。
   * 只回到本局最后一次已持久提交的完整快照，不接收调用方数据，也不打开 owner XML。
   * 提交在途时不能撤销，否则会与成功确认/失败回滚争抢 overlay 的所有权。
   */
  discardUncommitted(): void {
    if (this.committing) throw new Error('Cannot discard a game layout commit in progress')
    this.overlay = copyLaunchPreferenceSnapshot(this.committed)
  }
  async flush(): Promise<void> {
    if (this.pending !== undefined) return this.pending
    if (this.committing) throw new Error('Reentrant game layout commit')
    const proposed: LaunchPreferenceSnapshot = copyLaunchPreferenceSnapshot(this.overlay)
    this.committing = true
    const operation: Promise<void> = this.commitSnapshot(proposed)
    this.pending = operation
    try { await operation } finally { this.pending = undefined; this.committing = false }
  }
  private async commitSnapshot(proposed: LaunchPreferenceSnapshot): Promise<void> {
    try {
      // 每次给 sink 独立副本，防止实现持有/修改传入对象污染不可变基线或本局 overlay。
      await this.sink.commit(copyLaunchPreferenceSnapshot(this.base), copyLaunchPreferenceSnapshot(proposed))
      this.committed = copyLaunchPreferenceSnapshot(proposed)
      this.overlay = copyLaunchPreferenceSnapshot(proposed)
    } catch (error) {
      this.overlay = copyLaunchPreferenceSnapshot(this.committed)
      throw error as Error
    }
  }
}
