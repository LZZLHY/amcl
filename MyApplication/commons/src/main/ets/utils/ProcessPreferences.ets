import { preferences } from '@kit.ArkData'
import { LaunchPreferenceSnapshot, LaunchPreferenceStore, LaunchPreferenceValue,
  GameLayoutCommitSink, GameLayoutLaunchPreferences,
  copyLaunchPreferenceSnapshot, createLaunchPreferenceStores } from './PreferenceSnapshot'

class OwnerPreferences implements LaunchPreferenceStore {
  private store: preferences.Preferences
  constructor(store: preferences.Preferences) { this.store = store }
  getSync(key: string, fallback: LaunchPreferenceValue): LaunchPreferenceValue { return this.store.getSync(key, fallback) as LaunchPreferenceValue }
  async get(key: string, fallback: LaunchPreferenceValue): Promise<LaunchPreferenceValue> { return await this.store.get(key, fallback) as LaunchPreferenceValue }
  putSync(key: string, value: LaunchPreferenceValue): void { this.store.putSync(key, value) }
  async put(key: string, value: LaunchPreferenceValue): Promise<void> { await this.store.put(key, value) }
  deleteSync(key: string): void { this.store.deleteSync(key) }
  async flush(): Promise<void> { await this.store.flush() }
}

/** Installed before any game HAR initializes; a missing snapshot never opens XML. */
export class ProcessPreferences {
  private static game: boolean = false
  private static stores: Map<string, LaunchPreferenceStore> = new Map<string, LaunchPreferenceStore>()
  private static layoutSnapshot: LaunchPreferenceSnapshot | undefined = undefined
  private static layoutOpened: boolean = false
  private static layoutSinkInstalled: boolean = false
  static isGameProcess(): boolean { return ProcessPreferences.game }
  static installGameSnapshots(snapshots: LaunchPreferenceSnapshot[]): void {
    if (ProcessPreferences.game) throw new Error('Game preferences already initialized')
    const next: Map<string, LaunchPreferenceStore> = createLaunchPreferenceStores(snapshots)
    const layout: LaunchPreferenceSnapshot | undefined = snapshots.find((item: LaunchPreferenceSnapshot): boolean => item.name === 'control_layout')
    if (layout === undefined) throw new Error('Game layout snapshot is missing')
    ProcessPreferences.layoutSnapshot = copyLaunchPreferenceSnapshot(layout)
    ProcessPreferences.stores = next
    ProcessPreferences.game = true
  }
  /**
   * 仅 entry 在 snapshot 安装后、任何 LayoutStore 打开前注入。禁止晚换 store，
   * 否则旧 LayoutStore 会继续持有只读对象而形成两套不一致的本局状态。
   */
  static installGameLayoutCommitSink(sink: GameLayoutCommitSink): void {
    const snapshot: LaunchPreferenceSnapshot | undefined = ProcessPreferences.layoutSnapshot
    if (!ProcessPreferences.game || snapshot === undefined || ProcessPreferences.layoutOpened || ProcessPreferences.layoutSinkInstalled) {
      throw new Error('Game layout commit sink must be installed once before opening layout preferences')
    }
    ProcessPreferences.stores.set('control_layout', new GameLayoutLaunchPreferences(snapshot, sink))
    ProcessPreferences.layoutSinkInstalled = true
  }
  /** 只允许回滚游戏布局暂存；不暴露账号/设置写权限，也不能替换已确认的布局内容。 */
  static discardGameLayoutChanges(): void {
    const store: LaunchPreferenceStore | undefined = ProcessPreferences.stores.get('control_layout')
    if (!ProcessPreferences.game || !(store instanceof GameLayoutLaunchPreferences)) {
      throw new Error('Only the installed game layout overlay may be discarded')
    }
    store.discardUncommitted()
  }
  static open(context: Context, name: string): LaunchPreferenceStore {
    if (ProcessPreferences.game) {
      const store: LaunchPreferenceStore | undefined = ProcessPreferences.stores.get(name)
      if (store === undefined) throw new Error('Game snapshot missing for ' + name)
      if (name === 'control_layout') ProcessPreferences.layoutOpened = true
      return store
    }
    return new OwnerPreferences(preferences.getPreferencesSync(context, { name: name }))
  }
  static async captureOwner(context: Context, name: string): Promise<LaunchPreferenceSnapshot> {
    if (ProcessPreferences.game) throw new Error('Game process cannot capture owner preferences')
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: name })
    await store.flush()
    const snapshot: LaunchPreferenceSnapshot = { name: name,
      values: store.getAllSync() as Record<string, LaunchPreferenceValue> }
    return copyLaunchPreferenceSnapshot(snapshot)
  }
}
