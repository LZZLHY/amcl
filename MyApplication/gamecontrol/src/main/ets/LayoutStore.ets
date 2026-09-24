import { AppLogger } from 'commons';
/**
 * LayoutStore.ets — 布局持久化服务
 *
 * - Preferences 存储（主存储）
 * - JSON 导入/导出
 * - 多套方案管理
 */
import { ProcessPreferences, LaunchPreferenceStore, LaunchPreferenceSnapshot, LaunchPreferenceValue } from 'commons';
import { mergeLayoutPreferences, LayoutMergeResult } from './LayoutMerge';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  LayoutProfile, ControlItem, ControlType,
  getDefaultLayout, cloneLayout, migrateProfile, validateAndNormalizeLayout, generateControlId,
  DEFAULT_LOOK_SENSITIVITY, DEFAULT_INVERT_Y,
  DEFAULT_LOOK_SMOOTHING, DEFAULT_LOOK_ACCEL,
  makeHotbarSelector, computeAutoGuiScale, computeHotbarRectPx, HotbarRectPx,
  makeSystemButton, SystemAction, SYS_INPUT_ID, LAYOUT_PROFILE_VERSION
} from './ControlLayout';
import { getAllPresets } from './LayoutPresets';
import { isPojavLayoutJson, importPojavLayout } from './PojavImporter';
import {
  InputSurfaceContext,
  INPUT_SURFACE_FIELD_DENSITY,
  INPUT_SURFACE_FIELD_RECT,
  getInputSurfaceContextStore
} from './InputSurfaceContext';

class InputDisplayMetrics {
  widthPx: number = 0
  heightPx: number = 0
  density: number = 0
}

/** Current game Window first; default display is only a pre-window fallback. */
function currentInputDisplayMetrics(): InputDisplayMetrics {
  const metrics = new InputDisplayMetrics()
  const context: InputSurfaceContext = getInputSurfaceContextStore().snapshot()
  if (!context.provisional) {
    if (context.has(INPUT_SURFACE_FIELD_RECT)) {
      metrics.widthPx = context.widthPx
      metrics.heightPx = context.heightPx
    }
    if (context.has(INPUT_SURFACE_FIELD_DENSITY)) metrics.density = context.density
    return metrics
  }
  try {
    const fallback = display.getDefaultDisplaySync()
    metrics.widthPx = fallback.width
    metrics.heightPx = fallback.height
    metrics.density = fallback.densityPixels > 0 ? fallback.densityPixels : 1
  } catch (_) {}
  return metrics
}

/**
 * 控制层 native 参数 sink（三层架构 · D1=方案 a / 控制反转）。
 * gamecontrol 公共逻辑**不直接依赖 libentry.so**（否则 gamecontrol 抽成 HAR 会反向依赖
 * 持有 .so 的 entry HAP）。由 entry 在启动时通过 `setControlNativeSink(...)` 注入 testNapi 实现。
 * 未注入时 no-op —— 等价于以前「.so 未就绪/老 .so 缺这两个方法」时的 try/catch 降级。
 */
export interface ControlNativeSink {
  setLookSensitivity(v: number): void;
  setInvertY(v: boolean): void;
  // 方案 C（2026-07-11）：视角平滑 α + 加速强度。老实现（旧 entry）若未实现这两个方法，
  // 由 EntryControlNativeSink 提供；注入时整体替换，不存在部分实现问题。
  setLookSmoothing(v: number): void;
  setLookAccel(v: number): void;
}

let g_controlNativeSink: ControlNativeSink | null = null;

/** 由 entry（持 libentry.so 的 HAP）在启动时注入控制层 native 实现；传 null 卸载。 */
export function setControlNativeSink(sink: ControlNativeSink | null): void {
  g_controlNativeSink = sink;
}

const TAG = 'LayoutStore';
const PREF_NAME = 'control_layout'
const KEY_PROFILES = 'profiles'       // JSON string of LayoutProfile[]
const KEY_ACTIVE = 'active_profile'   // string: name of active profile

export interface LayoutEditorStoreSnapshot {
  profiles: LayoutProfile[]
  activeName: string
  activeChosenAutomatically: boolean
}

/** 子进程布局导入结果；deferred 不代表已保存，调用方必须保留原始 journal。 */
export interface GameLayoutImportResult {
  deferred: boolean;
  changed: boolean;
  conflicts: string[];
}

export class LayoutStore {
  private pref: LaunchPreferenceStore | null = null
  private profiles: LayoutProfile[] = []
  private activeName: string = '默认'
  private activeChosenAutomatically: boolean = false
  private _ready: boolean = false
  private _initPromise: Promise<void> | null = null
  private editorSnapshot: LayoutEditorStoreSnapshot | null = null
  /** 真实编辑器 lease 与普通 mutation 留下的取消快照分开，避免导入被永久误挡。 */
  private editorLeases: number = 0
  private editorOwnsSnapshot: boolean = false
  private mutationTail: Promise<void> = Promise.resolve()
  private pendingMutations: number = 0
  /** 回滚也失败意味着缓存/磁盘关系未知；本进程停止后续写入，保留 journal 等待冷启动恢复。 */
  private mutationPersistenceBlocked: boolean = false

  /** 首个编辑器在无在途写入时取得 lease；嵌套子组件共享同一取消基线。 */
  beginEditorSession(): boolean {
    if (!this._ready) return false
    if (this.editorLeases === 0 && this.pendingMutations > 0) return false
    if (this.editorLeases === 0 && !this.editorOwnsSnapshot) {
      this.editorSnapshot = null
      this.beginEditorTransaction()
      this.editorOwnsSnapshot = true
    }
    this.editorLeases++
    return true
  }

  /** 组件完成异步保存/取消后释放自己的 lease；未解决的真实编辑草稿仍禁止父侧覆盖。 */
  endEditorSession(): void { if (this.editorLeases > 0) this.editorLeases-- }

  isEditorActive(): boolean {
    return this.editorLeases > 0 || (this.editorOwnsSnapshot && this.editorSnapshot !== null)
  }

  /** 深复制运行内存，失败时同时恢复方案、选中项和设备自动选择状态。 */
  private captureState(): LayoutEditorStoreSnapshot {
    return { profiles: this.profiles.map((profile: LayoutProfile): LayoutProfile => cloneLayout(profile)),
      activeName: this.activeName, activeChosenAutomatically: this.activeChosenAutomatically }
  }

  private restoreState(snapshot: LayoutEditorStoreSnapshot): void {
    this.profiles = snapshot.profiles.map((profile: LayoutProfile): LayoutProfile => cloneLayout(profile))
    this.activeName = snapshot.activeName
    this.activeChosenAutomatically = snapshot.activeChosenAutomatically
    this.applyGlobalParams(this.getActiveProfile())
  }

  /**
   * 串行的是完整 mutation，而非仅 flush；防止两个保存把 profiles/active 混成不同批次。
   * 失败恢复操作前内存；子进程 overlay 自己回滚未确认提交，父侧尝试恢复原偏好缓存并重抛。
   */
  private runMutation<T>(operation: () => Promise<T>, rollbackPreferenceKey: string = ''): Promise<T> {
    this.pendingMutations++
    const task: Promise<T> = this.mutationTail.then<T>(async (): Promise<T> => {
      if (this.mutationPersistenceBlocked) throw new Error('布局保存回滚未完成，请重启启动器后重试')
      const before: LayoutEditorStoreSnapshot = this.captureState()
      const beforeEditor: LayoutEditorStoreSnapshot | null = this.editorSnapshot
      const beforeOwned: boolean = this.editorOwnsSnapshot
      const previousProfiles: string = this.pref ? await this.pref.get(KEY_PROFILES, '') as string : ''
      const previousActive: string = this.pref ? await this.pref.get(KEY_ACTIVE, '') as string : ''
      const previousMarker: LaunchPreferenceValue = this.pref && rollbackPreferenceKey.length > 0
        ? await this.pref.get(rollbackPreferenceKey, '') : ''
      try { return await operation() }
      catch (error) {
        this.restoreState(before)
        this.editorSnapshot = beforeEditor
        this.editorOwnsSnapshot = beforeOwned
        if (ProcessPreferences.isGameProcess()) {
          // 第二次 put 可能在 flush 之前失败；必须同时恢复 child 底层 overlay，
          // 不能只有 LayoutStore 内存回退、后续 flush 却重新提交那半笔失败的 profiles。
          try { ProcessPreferences.discardGameLayoutChanges() }
          catch (rollback) {
            this.mutationPersistenceBlocked = true
            AppLogger.error(TAG, '游戏布局暂存回滚失败，停止后续修改并保留已确认提交')
          }
        } else if (this.pref) {
          try {
            // 完成身份与布局两键必须一起回滚并 flush；先撤销标记，避免失败后的缓存
            // 被下一次导入误认为已提交。如果回滚任一步失败，下面立即封锁本进程写入。
            if (rollbackPreferenceKey.length > 0) this.pref.putSync(rollbackPreferenceKey, previousMarker)
            await this.pref.put(KEY_PROFILES, previousProfiles)
            await this.pref.put(KEY_ACTIVE, previousActive)
            await this.pref.flush()
          } catch (rollback) {
            this.mutationPersistenceBlocked = true
            AppLogger.error(TAG, '布局偏好回滚失败，停止后续修改，原提交记录保留等待冷启动重试')
          }
        }
        throw error as Error
      }
    })
    const settled: Promise<T> = task.finally((): void => { this.pendingMutations-- })
    this.mutationTail = settled.then<void, void>((): void => {}, (): void => {})
    return settled
  }

  isReady(): boolean { return this._ready }

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this._initPromise) return this._initPromise
    this._initPromise = this._doInit(context)
    return this._initPromise
  }

  // 2026-05-23 ArkTS 严格模式：下面三个方法里调用 preferences.getPreferences /
  // pref.get / pref.put / pref.flush 都会报 'Function may throw'。这里统一
  // 包 try-catch + hilog + rethrow 以满足检查，同时不改变异常传播行为
  // （外层 init() 返回 Promise，调用方于 await/.catch 反正能拿到）。
  // 详见 docs/guides/api-migration-2026-05.md 「ArkTS Function may throw」节。
  private async _doInit(context: common.UIAbilityContext): Promise<void> {
    try {
      this.pref = ProcessPreferences.open(context, PREF_NAME)
      await this.load()
      this._ready = true
    } catch (e) {
      AppLogger.error(TAG, `_doInit failed: ${(e as Error).message}`)
      throw e as Error
    }
  }

  async waitReady(): Promise<void> {
    if (this._initPromise) await this._initPromise
  }

  private async load(): Promise<void> {
    if (!this.pref) return
    let json: string
    let name: string
    try {
      json = await this.pref.get(KEY_PROFILES, '') as string
      // 注：默认值 ''（空串）是有意为之——load 后如果是空串，pickDefaultByDevice
      // 会按设备短边 dp 自动选预设；老用户存过 active_profile 时会读到原值。
      name = await this.pref.get(KEY_ACTIVE, '') as string
    } catch (e) {
      AppLogger.error(TAG, `load: pref.get failed: ${(e as Error).message}`)
      throw e as Error
    }

    if (json && json.length > 2) {
      try {
        const arr = JSON.parse(json) as LayoutProfile[]
        if (!Array.isArray(arr)) {
          this.profiles = []
        } else {
          // 持久化数据也视为不可信输入：任一方案非法就拒绝整批用户存档，不能只保留前半批。
          const normalized: LayoutProfile[] = []
          let allValid = true
          for (let i = 0; i < arr.length; i++) {
            const p = migrateProfile(arr[i])
            if (!p) { allValid = false; break }
            normalized.push(p)
          }
          this.profiles = allValid ? normalized : []
        }
      } catch (e) {
        this.profiles = []
      }
    } else {
      this.profiles = []
    }

    // 预设精简 2026-05-30：现在只保留 2 套系统预设（★ 手机 / ★ 平板）。
    //
    // 系统预设始终以代码为准：删掉存档里所有 isPreset=true 的旧副本（无论名字），
    // 再用 getAllPresets() 的最新版本补回。这样改了预设布局 / 位置后，重进 app 就生效，
    // 不会被存档里的旧预设盖掉。用户自己克隆 / 新建的方案（isPreset=false）一律保留不动。
    const presets = getAllPresets()
    this.profiles = this.profiles.filter(p => p.isPreset !== true)
    for (let i = 0; i < presets.length; i++) {
      this.profiles.push(presets[i])
    }
    // 让系统预设排在用户方案前面（可选，纯展示顺序）
    this.profiles.sort((a, b) => (a.isPreset === true ? 0 : 1) - (b.isPreset === true ? 0 : 1))

    // 兜底：仍然空的话至少给一份默认布局
    if (this.profiles.length === 0) {
      this.profiles = [getDefaultLayout()]
    }

    // F1（2026-07-11）：物品栏直点条默认开启；只有首次注入时才自动对齐。
    for (let i = 0; i < this.profiles.length; i++) {
      this.ensureHotbarSelector(this.profiles[i])
      this.ensureSystemControls(this.profiles[i])
    }
    // ensureHotbarSelector 也改变布局数据，因此 load 的最终结果必须再次通过同一个边界。
    const checkedProfiles: LayoutProfile[] = []
    let allProfilesValid = true
    for (let i = 0; i < this.profiles.length; i++) {
      const checked = validateAndNormalizeLayout(this.profiles[i])
      if (!checked) { allProfilesValid = false; break }
      checkedProfiles.push(checked)
    }
    this.profiles = allProfilesValid && checkedProfiles.length > 0 ? checkedProfiles : [getDefaultLayout()]

    // 选默认活跃方案：用户上次活跃的优先；否则按设备类型自动选预设
    if (name && this.profiles.find(p => p.name === name)) {
      this.activeName = name
      this.activeChosenAutomatically = false
    } else {
      this.activeName = this.pickDefaultByDevice()
      this.activeChosenAutomatically = true
    }

    // 把活跃方案的全局参数同步到 C 层（视角灵敏度 / Y 倒置）
    this.applyGlobalParams(this.getActiveProfile())
  }

  /**
   * F1（2026-07-11）：确保方案含物品栏直点条并按本设备精确对齐 MC hotbar（§4.5 配方）。
   * - 已有 → 保持用户位置与尺寸不变，仅记录已拥有过 selector。
   * - 缺失且未标记过 → 注入一个（默认开）+ 仅本次对齐 + 置 hotbarAutoAdded=true。
   * - 缺失但已标记（老方案曾注入 / 用户删过）→ 不再注入，尊重用户选择。
   */
  private ensureHotbarSelector(p: LayoutProfile): void {
    if (!p || !p.controls) return
    let sel: ControlItem | undefined = undefined
    for (let i = 0; i < p.controls.length; i++) {
      if (p.controls[i].type === ControlType.HOTBAR_SELECTOR) { sel = p.controls[i]; break }
    }
    if (sel) {
      // 物品栏直点条天生必须贴合 MC 真实 hotbar（位置随分辨率 + 自动档 guiScale 决定），因此默认是
      // "系统对齐控件"：每次 load 都按本机重新对齐。这修复了"默认布局/预设自带的 selector 停留在
      // makeHotbarSelector 的粗略默认位置(0.34,0.9,300,36)、点击格对不准真实 hotbar"的回归。
      // 仅当用户在编辑器手动拖动 / 缩放过（hotbarUserPlaced=true，例如用了手动档 guiScale）才尊重其
      // 位置、不再覆盖——兼顾"默认精确对齐"与"尊重用户手动摆放"，比旧版"每次强制覆盖"或"从不对齐"都更稳。
      p.hotbarAutoAdded = true
      if (sel.hotbarUserPlaced !== true) {
        this.alignHotbarToDevice(sel, p.globalScale > 0 ? p.globalScale : 1.0)
      }
      return
    }
    if (p.hotbarAutoAdded === true) return

    sel = makeHotbarSelector(0.34, 0.9, 300, 36)
    sel.id = generateControlId(p.controls)
    this.alignHotbarToDevice(sel, p.globalScale > 0 ? p.globalScale : 1.0)
    const previousFlag = p.hotbarAutoAdded
    p.controls.push(sel)
    p.hotbarAutoAdded = true
    // 满 256 个控件等边界下，注入会令整份布局非法；必须完整回滚，不能截掉任意旧控件。
    if (!validateAndNormalizeLayout(p)) {
      p.controls.pop()
      p.hotbarAutoAdded = previousFlag
    }
  }

  /** 用设备物理分辨率 + 自动档 guiScale 把物品栏条对齐到 MC 真实 hotbar（复刻编辑器 autoAlignHotbar）。 */
  private alignHotbarToDevice(item: ControlItem, g: number): void {
    try {
      const metrics: InputDisplayMetrics = currentInputDisplayMetrics()
      let wPx = metrics.widthPx
      let hPx = metrics.heightPx
      if (wPx <= 0 || hPx <= 0 || metrics.density <= 0) return
      if (hPx > wPx) { const t = wPx; wPx = hPx; hPx = t }   // 游戏恒横屏
      const dens: number = metrics.density
      const gs = computeAutoGuiScale(wPx, hPx)
      const r: HotbarRectPx = computeHotbarRectPx(wPx, hPx, gs)
      item.xPct = r.leftPx / wPx
      item.yPct = r.topPx / hPx
      item.itemScale = 1.0
      item.baseWidth = (r.widthPx / dens) / g
      item.baseHeight = (r.heightPx / dens) / g
    } catch (e) {
      // display 不可用：保留 makeHotbarSelector 的近似底部居中值
    }
  }

  /**
   * 保证方案含"输入 / 设置 / 显示"三颗系统功能按钮（不可删除）。仿 ensureHotbarSelector：
   *   1. 老存档里 id='ime_chat' 但无 systemAction 的按钮 → 升级为 input 系统按钮，并从"仅游戏"改为常驻可见；
   *   2. input/edit/visibility 三个动作缺哪个就注入哪个（默认右上角功能键区）。
   * 注入后整表复验，越界（如满 256）则回滚，绝不产生非法布局。
   */
  private ensureSystemControls(p: LayoutProfile): void {
    if (!p || !p.controls) return
    for (let i = 0; i < p.controls.length; i++) {
      const c = p.controls[i]
      if (c.systemAction === undefined && c.id === SYS_INPUT_ID) {
        c.systemAction = 'input'
        c.grabbedOnly = false
        c.menuOnly = false
      }
    }
    this.ensureOneSystemControl(p, 'input', 0.778, 0.106, 2)
    this.ensureOneSystemControl(p, 'edit', 0.914, 0.017, 5)
    this.ensureOneSystemControl(p, 'visibility', 0.778, 0.195, 6)
  }

  private ensureOneSystemControl(p: LayoutProfile, action: SystemAction,
                                 xPct: number, yPct: number, alignIndex: number): void {
    for (let i = 0; i < p.controls.length; i++) {
      if (p.controls[i].systemAction === action) return   // 已存在，尊重用户位置/尺寸
    }
    const btn = makeSystemButton(action, xPct, yPct, alignIndex)
    // 保留 id 被老存档的非系统控件占用时，换一个唯一 id，保证 systemAction 语义与唯一性。
    if (p.controls.some((c: ControlItem) => c.id === btn.id)) {
      btn.id = generateControlId(p.controls)
    }
    p.controls.push(btn)
    if (!validateAndNormalizeLayout(p)) {
      p.controls.pop()
    }
  }

  /**
   * 阶段 3.6：根据屏幕短边 dp 自动选默认方案。
   *   - 短边 < 600dp：phone（默认 ★ 手机）
   *   - 短边 ≥ 600dp：tablet（默认 ★ 平板）
   * 失败时（display API 不可用）兜底到第一个 profile。
   */
  private pickDefaultByDevice(): string {
    let target: 'phone' | 'tablet' | 'any' = 'phone'
    try {
      const metrics: InputDisplayMetrics = currentInputDisplayMetrics()
      if (metrics.widthPx <= 0 || metrics.heightPx <= 0 || metrics.density <= 0) {
        target = 'phone'
      } else {
        const widthDp: number = metrics.widthPx / metrics.density
        const heightDp: number = metrics.heightPx / metrics.density
        const shortDp = Math.min(widthDp, heightDp)
        if (shortDp >= 600) target = 'tablet'
        else target = 'phone'
      }
    } catch (e) {
      target = 'phone'
    }
    // 优先匹配 targetDevice 完全等于 target 的系统预设
    const matched = this.profiles.find(p => p.targetDevice === target && p.isPreset)
    if (matched) return matched.name
    // 其次任意系统预设
    const anyPreset = this.profiles.find(p => p.isPreset)
    if (anyPreset) return anyPreset.name
    return this.profiles[0].name
  }

  /**
   * 把 LayoutProfile 中跟 C 层有关的全局参数（lookSensitivity / invertY）
   * 同步到 native。GameControls 一侧的参数（joystickDeadZone）由 ArkTS 自己读 profile。
   *
   * 调用时机：load 完成后、setActiveProfile / saveProfile 之后。
   */
  applyGlobalParams(p: LayoutProfile): void {
    if (!g_controlNativeSink) return
    try {
      g_controlNativeSink.setLookSensitivity(p.lookSensitivity ?? DEFAULT_LOOK_SENSITIVITY)
      g_controlNativeSink.setInvertY(p.invertY ?? DEFAULT_INVERT_Y)
      // 方案 C：把视角平滑 α + 加速强度也同步到 C 层（三源统一经 applyLookDelta 生效）
      g_controlNativeSink.setLookSmoothing(p.lookSmoothing ?? DEFAULT_LOOK_SMOOTHING)
      g_controlNativeSink.setLookAccel(p.lookAccel ?? DEFAULT_LOOK_ACCEL)
    } catch (e) {
      // sink 抛异常时忽略（等价于以前 NAPI 未就绪的降级）
    }
  }

  private async save(): Promise<void> {
    if (!this.pref) throw new Error('布局存储尚未初始化')
    try {
      // save 是最后一道防线：即使内部调用方遗漏校验，也绝不把部分非法数据写入 Preferences。
      const normalized: LayoutProfile[] = []
      for (let i = 0; i < this.profiles.length; i++) {
        const checked = validateAndNormalizeLayout(this.profiles[i])
        if (!checked) throw new Error('invalid control layout')
        normalized.push(checked)
      }
      this.profiles = normalized
      const json = JSON.stringify(this.profiles)
      await this.pref.put(KEY_PROFILES, json)
      await this.pref.put(KEY_ACTIVE, this.activeName)
      await this.pref.flush()
    } catch (e) {
      AppLogger.error(TAG, `save: pref.put/flush failed: ${(e as Error).message}`)
      throw e as Error
    }
  }

  /**
   * 获取当前活跃的布局方案
   */
  getActiveProfile(): LayoutProfile {
    const p = this.profiles.find(p => p.name === this.activeName)
    if (p) return p
    if (this.profiles.length > 0) {
      this.activeName = this.profiles[0].name
      return this.profiles[0]
    }
    const def = getDefaultLayout()
    this.profiles.push(def)
    this.activeName = def.name
    return def
  }

  /** Recompute only device-derived defaults when a new authoritative Window generation arrives. */
  refreshDeviceDerivedLayout(): void {
    if (!this._ready) return
    for (let i: number = 0; i < this.profiles.length; i++) {
      const profile: LayoutProfile = this.profiles[i]
      for (let j: number = 0; j < profile.controls.length; j++) {
        const control: ControlItem = profile.controls[j]
        if (control.type === ControlType.HOTBAR_SELECTOR &&
            control.hotbarUserPlaced !== true) {
          this.alignHotbarToDevice(
            control, profile.globalScale > 0 ? profile.globalScale : 1.0)
        }
      }
    }
    if (this.activeChosenAutomatically) this.activeName = this.pickDefaultByDevice()
    this.applyGlobalParams(this.getActiveProfile())
  }

  /**
   * 获取所有方案名称
   */
  getProfileNames(): string[] {
    return this.profiles.map(p => p.name)
  }

  /** 阶段 2.2：获取所有方案对象（UI 需要查 isPreset 字段时用）。返回的是内部引用，调用方不应直接修改。 */
  getAllProfiles(): LayoutProfile[] {
    return this.profiles
  }

  /** 编辑器事务：捕获进入编辑器前的完整方案列表及活跃方案。 */
  beginEditorTransaction(): void {
    if (this.editorSnapshot) return
    this.editorSnapshot = {
      profiles: this.profiles.map((p: LayoutProfile) => cloneLayout(p)),
      activeName: this.activeName,
      activeChosenAutomatically: this.activeChosenAutomatically
    }
  }

  /** 保存成功后提交编辑器事务，避免后续取消恢复已保存内容。 */
  commitEditorTransaction(): void {
    this.editorSnapshot = null
    this.editorOwnsSnapshot = false
  }

  /** 取消编辑器时恢复方案列表、活跃方案，并同步 Preferences/native 参数。 */
  async restoreEditorTransaction(): Promise<boolean> {
    return this.runMutation<boolean>(async (): Promise<boolean> => {
      if (!this.editorSnapshot) return true
      const snapshot = this.editorSnapshot
      this.restoreState(snapshot)
      await this.save()
      this.editorSnapshot = null
      this.editorOwnsSnapshot = false
      return true
    }).catch((e: Error): boolean => {
      AppLogger.error(TAG, `restoreEditorTransaction failed: ${(e as Error).message}`)
      return false
    })
  }

  private captureEditorTransaction(): void {
    this.beginEditorTransaction()
  }

  /**
   * 切换活跃方案
   */
  async setActiveProfile(name: string): Promise<void> {
    return this.runMutation<void>(async (): Promise<void> => {
    this.captureEditorTransaction()
    this.activeName = name
    this.activeChosenAutomatically = false
    await this.save()
    this.applyGlobalParams(this.getActiveProfile())
    })
  }

  /**
   * 保存当前方案（更新到 profiles 数组并持久化）。
   * 阶段 2.2：拒绝直接保存到 isPreset 方案上——应当先 cloneAsUser 出一份副本。
   * 返回 true 表示保存成功；false 表示被拒绝（调用方应提示用户先克隆）。
   */
  async saveProfile(profile: LayoutProfile): Promise<boolean> {
    return this.runMutation<boolean>(async (): Promise<boolean> => {
    this.captureEditorTransaction()
    // 外部传入对象一律先规范化；失败时不修改内存、不落盘，避免部分接受。
    const checked = validateAndNormalizeLayout(profile)
    if (!checked) return false
    const idx = this.profiles.findIndex(p => p.name === checked.name)
    if (idx >= 0 && this.profiles[idx].isPreset) {
      // 不允许覆盖系统预设。这里直接 reject；UI 应当提示用户去克隆。
      return false
    }
    if (idx >= 0) {
      this.profiles[idx] = cloneLayout(checked)
    } else {
      this.profiles.push(cloneLayout(checked))
    }
    this.activeName = checked.name
    this.activeChosenAutomatically = false
    await this.save()
    this.applyGlobalParams(checked)
    return true
    })
  }

  /**
   * 阶段 2.2：把当前方案克隆为可编辑的用户方案。
   * 自动生成不冲突的新名字（"<原名> 副本" / "<原名> 副本 2" ...），
   * isPreset = false，并切换为活跃方案。
   */
  async cloneAsUser(srcName: string): Promise<LayoutProfile | null> {
    return this.runMutation<LayoutProfile | null>(async (): Promise<LayoutProfile | null> => {
    this.captureEditorTransaction()
    const src = this.profiles.find(p => p.name === srcName)
    if (!src) return null
    const copy = cloneLayout(src)
    copy.isPreset = false
    // 找一个不冲突的名字
    let candidate = src.name + ' 副本'
    let n = 2
    const existing = new Set<string>(this.profiles.map(p => p.name))
    while (existing.has(candidate)) {
      candidate = src.name + ' 副本 ' + n.toString()
      n++
    }
    copy.name = candidate
    this.profiles.push(copy)
    this.activeName = candidate
    this.activeChosenAutomatically = false
    await this.save()
    this.applyGlobalParams(copy)
    return copy
    })
  }

  /**
   * 新建方案（从经典手机预设克隆，去掉 isPreset 标记）
   */
  async createProfile(name: string): Promise<LayoutProfile> {
    return this.runMutation<LayoutProfile>(async (): Promise<LayoutProfile> => {
    this.captureEditorTransaction()
    const presets = getAllPresets()
    const tpl = presets.length > 0 ? cloneLayout(presets[0]) : getDefaultLayout()
    tpl.name = name
    tpl.isPreset = false
    this.ensureHotbarSelector(tpl)
    this.ensureSystemControls(tpl)
    this.profiles.push(tpl)
    this.activeName = name
    this.activeChosenAutomatically = false
    await this.save()
    this.applyGlobalParams(tpl)
    return tpl
    })
  }

  /**
   * 删除方案。阶段 2.2：拒绝删除系统预设；返回 true 表示删除成功。
   */
  async deleteProfile(name: string): Promise<boolean> {
    return this.runMutation<boolean>(async (): Promise<boolean> => {
    this.captureEditorTransaction()
    const target = this.profiles.find(p => p.name === name)
    if (target && target.isPreset) {
      return false
    }
    this.profiles = this.profiles.filter(p => p.name !== name)
    if (this.profiles.length === 0) {
      // 兜底：把所有预设补回来
      const presets = getAllPresets()
      for (let i = 0; i < presets.length; i++) {
        this.profiles.push(presets[i])
      }
    }
    if (this.activeName === name) {
      this.activeName = this.profiles[0].name
      this.activeChosenAutomatically = false
      this.applyGlobalParams(this.getActiveProfile())
    }
    await this.save()
    return true
    })
  }

  /**
   * 重命名方案。阶段 2.2：拒绝重命名系统预设。
   */
  async renameProfile(oldName: string, newName: string): Promise<boolean> {
    return this.runMutation<boolean>(async (): Promise<boolean> => {
    this.captureEditorTransaction()
    const trimmed = newName.trim()
    if (trimmed.length === 0 || trimmed.length > 40) return false   // 空名 / 过长拒绝
    const p = this.profiles.find(p => p.name === oldName)
    if (!p) return false
    if (p.isPreset) return false                                     // 默认两个系统预设不可改名
    if (trimmed === oldName) return true                             // 没变化，视为成功
    if (this.profiles.find(pp => pp.name === trimmed)) return false  // 重名（含预设名）拒绝
    p.name = trimmed
    if (this.activeName === oldName) {
      this.activeName = newName
    }
    await this.save()
    return true
    })
  }

  /**
   * 恢复默认（将指定方案重置为默认布局）。
   * 阶段 2.2：对系统预设 → 重新克隆出新预设；对用户方案 → 替换为 getDefaultLayout。
   */
  async resetProfile(name: string): Promise<LayoutProfile> {
    return this.runMutation<LayoutProfile>(async (): Promise<LayoutProfile> => {
    this.captureEditorTransaction()
    const presets = getAllPresets()
    const target = this.profiles.find(p => p.name === name)
    if (target && target.isPreset) {
      // 系统预设重置 = 重新调其对应 builder 拿一份新的（保持自身名字/身份）。
      const fresh = presets.find(p => p.name === name)
      if (fresh) {
        this.ensureHotbarSelector(fresh)
        this.ensureSystemControls(fresh)
        const idx = this.profiles.findIndex(p => p.name === name)
        if (idx >= 0) this.profiles[idx] = fresh
        await this.save()
        this.applyGlobalParams(fresh)
        return fresh
      }
    }
    // 用户方案重置 = 按当前设备类型重置为对应系统预设（手机→★手机、平板→★平板），保留原方案名。
    const deviceType = this.getCurrentDeviceType()
    let base = presets.find(p => p.targetDevice === deviceType)
    if (!base) base = presets.length > 0 ? presets[0] : getDefaultLayout()
    const reset = cloneLayout(base)
    reset.name = name
    reset.isPreset = false
    this.ensureHotbarSelector(reset)
    this.ensureSystemControls(reset)
    const idx = this.profiles.findIndex(p => p.name === name)
    if (idx >= 0) {
      this.profiles[idx] = reset
    }
    await this.save()
    this.applyGlobalParams(reset)
    return reset
    })
  }

  /**
   * 启动器导入已退出游戏的布局提交。当前值在同一 mutation 队列内现读、三方合并，
   * 不覆盖打开或取消失败的编辑器草稿；只有完整 put+flush 成功后才刷新本进程缓存。
   */
  importGamePreferences(base: LaunchPreferenceSnapshot, proposed: LaunchPreferenceSnapshot,
    sessionId: string, digest: string): Promise<GameLayoutImportResult> {
    if (!new RegExp('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').test(sessionId)
      || !new RegExp('^[0-9a-f]{64}$').test(digest)) {
      return Promise.reject<GameLayoutImportResult>(new Error('布局导入完成身份无效'))
    }
    const markerKey: string = 'game_layout_applied_' + sessionId
    return this.runMutation<GameLayoutImportResult>(async (): Promise<GameLayoutImportResult> => {
      if (ProcessPreferences.isGameProcess()) throw new Error('只有启动器可以导入游戏布局')
      if (this.isEditorActive()) return { deferred: true, changed: false, conflicts: [] }
      const pref = this.pref
      if (pref === null) throw new Error('布局存储尚未初始化')
      // 单独 receipt 在 owner flush 后才写，断电/写盘失败会留下完成状态的时间窗口。
      // 此标记与布局同属一次 Preferences flush，后续 parent 即使删掉 child 新增方案，
      // 重试也只补外部回执而不再合并；否则“回到 base”的主动编辑会被误当作从未修改。
      if (await pref.get(markerKey, '') === digest) {
        return { deferred: false, changed: false, conflicts: [] }
      }
      const currentValues: Record<string, LaunchPreferenceValue> = {
        'profiles': await pref.get(KEY_PROFILES, '') as string,
        'active_profile': await pref.get(KEY_ACTIVE, '') as string
      }
      const current: LaunchPreferenceSnapshot = { name: PREF_NAME, values: currentValues }
      const merged: LayoutMergeResult = mergeLayoutPreferences(base, proposed, current, sessionId)
      if (merged.changed) {
        await pref.put(KEY_PROFILES, merged.snapshot.values[KEY_PROFILES])
        await pref.put(KEY_ACTIVE, merged.snapshot.values[KEY_ACTIVE])
      }
      await pref.put(markerKey, digest)
      await pref.flush()
      await this.load()
      return { deferred: false, changed: merged.changed, conflicts: merged.conflicts }
    }, markerKey)
  }

  /** 启动快照与布局写入共用队列，不能在 profiles/active 两键尚未成对确认时抓取半批。 */
  captureLaunchPreferences(): Promise<LaunchPreferenceSnapshot> {
    return this.runMutation<LaunchPreferenceSnapshot>(async (): Promise<LaunchPreferenceSnapshot> => {
      const pref = this.pref
      if (pref === null) throw new Error('布局存储尚未初始化')
      const values: Record<string, LaunchPreferenceValue> = {
        'profiles': await pref.get(KEY_PROFILES, '') as string,
        'active_profile': await pref.get(KEY_ACTIVE, '') as string
      }
      return { name: PREF_NAME, values: values }
    })
  }

  // ==================== JSON 导出/导入 ====================

  /**
   * 导出指定方案为 JSON 字符串
   */
  exportToJson(name: string): string {
    const p = this.profiles.find(p => p.name === name)
    if (!p) return '{}'
    // 导出时盖上当前设备型号（信息记录用，不改内存里的方案）。
    const copy = cloneLayout(p)
    const model = this.currentDeviceModel()
    if (model.length > 0) copy.deviceModel = model
    return JSON.stringify(copy, null, 2)
  }

  /** 当前设备型号（deviceInfo.marketName 优先，回退 productModel）。失败返回空串。 */
  currentDeviceModel(): string {
    try {
      const m = deviceInfo.marketName
      if (m !== undefined && m !== null && m.length > 0) return m
      const pm = deviceInfo.productModel
      return (pm !== undefined && pm !== null) ? pm : ''
    } catch (e) {
      return ''
    }
  }

  /** 生成不与现有任何方案重名的名字（"<base>" → "<base> 副本" → "<base> 副本 2" ...）。 */
  private uniqueProfileName(base: string): string {
    if (!this.profiles.some(p => p.name === base)) return base
    let candidate = base + ' 副本'
    let n = 2
    while (this.profiles.some(p => p.name === candidate)) {
      candidate = base + ' 副本 ' + n.toString()
      n++
    }
    return candidate
  }

  /**
   * 导出到文件
   */
  async exportToFile(name: string, filePath: string): Promise<void> {
    const json = this.exportToJson(name)
    // 2026-05-23 ArkTS 严格模式：fileIo.openSync/writeSync/closeSync 会报
    // 'Function may throw'。包 try-catch + hilog + rethrow；finally 保证 fd 释放。
    let file: fileIo.File | null = null
    try {
      file = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC)
      fileIo.writeSync(file.fd, json)
    } catch (e) {
      AppLogger.error(TAG, `exportToFile failed: ${(e as Error).message}`)
      throw e as Error
    } finally {
      if (file) {
        try { fileIo.closeSync(file.fd) } catch (_) { /* ignore close error */ }
      }
    }
  }

  /**
   * 从 JSON 字符串导入方案。v1 / v2 / PojavLauncher 都接受，自动迁移到 v2。
   */
  async importFromJson(json: string): Promise<LayoutProfile | null> {
    try {
      const obj = JSON.parse(json) as object
      // 阶段 3.5：先识别是不是 PojavLauncher 格式
      if (isPojavLayoutJson(obj)) {
        const name = '从 PojavLauncher 导入 ' + new Date().toISOString().slice(0, 10)
        const imported = importPojavLayout(json, name)
        if (!imported) return null
        // 导入的布局不含物品栏条 / 系统功能按钮，先补齐再校验保存，避免导入后当场缺"输入/设置/显示"。
        this.ensureHotbarSelector(imported)
        this.ensureSystemControls(imported)
        const checked = validateAndNormalizeLayout(imported)
        if (!checked) return null
        // 导入一律作为用户方案 + 同名去重，绝不覆盖已有方案。
        checked.isPreset = false
        checked.name = this.uniqueProfileName(checked.name)
        if (!(await this.saveProfile(checked))) return null
        return checked
      }
      const p = migrateProfile(obj as LayoutProfile)
      if (!p) return null
      this.ensureHotbarSelector(p)
      this.ensureSystemControls(p)
      // 导入一律作为用户方案（即使源标了 isPreset）+ 同名去重，绝不覆盖用户已有的同名方案。
      p.isPreset = false
      p.name = this.uniqueProfileName(p.name)
      if (!(await this.saveProfile(p))) return null
      return p
    } catch (e) {
      return null
    }
  }

  /**
   * 从文件导入
   */
  async importFromFile(filePath: string): Promise<LayoutProfile | null> {
    try {
      const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY)
      const buf = new ArrayBuffer(256 * 1024)
      const len = fileIo.readSync(file.fd, buf)
      fileIo.closeSync(file.fd)
      const decoder = new util.TextDecoder('utf-8')
      const json = decoder.decodeToString(new Uint8Array(buf, 0, len))
      return await this.importFromJson(json)
    } catch (e) {
      return null
    }
  }

  // ==================== 导入前分析（设备类型 / 合法性 / 旧版检测） ====================

  /** 当前设备类型：短边 dp ≥ 600 → tablet，否则 phone。display 不可用兜底 phone。 */
  getCurrentDeviceType(): string {
    try {
      const metrics: InputDisplayMetrics = currentInputDisplayMetrics()
      if (metrics.widthPx <= 0 || metrics.heightPx <= 0 || metrics.density <= 0) {
        return 'phone'
      }
      const dens: number = metrics.density > 0 ? metrics.density : 1
      const shortDp: number = Math.min(metrics.widthPx, metrics.heightPx) / dens
      return shortDp >= 600 ? 'tablet' : 'phone'
    } catch (e) {
      return 'phone'
    }
  }

  /**
   * 不落盘地分析一段导入 JSON：识别格式(amcl/pojav/invalid)、合法性、目标设备、是否与当前设备不符、
   * 是否旧版本、控件数。UI 据此在导入前弹提示（设备不符 / 旧版迁移 / 非法拒绝）。
   */
  analyzeImport(json: string): ImportAnalysis {
    const current = this.getCurrentDeviceType()
    let obj: object | null = null
    try {
      obj = JSON.parse(json) as object
    } catch (e) {
      obj = null
    }
    if (obj === null) {
      return {
        ok: false, format: 'invalid', reason: '文件不是有效的 JSON', name: '',
        sourceDevice: 'unknown', currentDevice: current, deviceMismatch: false,
        sourceVersion: 0, legacy: false, controlCount: 0
      }
    }
    if (isPojavLayoutJson(obj)) {
      return {
        ok: true, format: 'pojav', reason: '', name: 'PojavLauncher 布局',
        sourceDevice: 'unknown', currentDevice: current, deviceMismatch: false,
        sourceVersion: 0, legacy: false, controlCount: 0
      }
    }
    const raw = obj as LayoutProfile
    const migrated = migrateProfile(raw)
    if (!migrated) {
      return {
        ok: false, format: 'amcl', reason: '布局数据不完整或非法，无法导入',
        name: raw.name !== undefined ? raw.name : '(未命名)',
        sourceDevice: 'unknown', currentDevice: current, deviceMismatch: false,
        sourceVersion: 0, legacy: false, controlCount: 0
      }
    }
    const srcDevice: string = migrated.targetDevice !== undefined ? migrated.targetDevice : 'any'
    const mismatch = (srcDevice === 'phone' || srcDevice === 'tablet') && srcDevice !== current
    const srcVer = raw.version !== undefined ? raw.version : 0
    return {
      ok: true, format: 'amcl', reason: '', name: migrated.name,
      sourceDevice: srcDevice, currentDevice: current, deviceMismatch: mismatch,
      sourceVersion: srcVer, legacy: srcVer !== LAYOUT_PROFILE_VERSION,
      controlCount: migrated.controls.length
    }
  }

  /** 读文件并分析（不落盘）。读失败返回 ok=false。 */
  async analyzeImportFile(filePath: string): Promise<ImportAnalysis> {
    try {
      const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY)
      const buf = new ArrayBuffer(256 * 1024)
      const len = fileIo.readSync(file.fd, buf)
      fileIo.closeSync(file.fd)
      const decoder = new util.TextDecoder('utf-8')
      const json = decoder.decodeToString(new Uint8Array(buf, 0, len))
      return this.analyzeImport(json)
    } catch (e) {
      return {
        ok: false, format: 'invalid', reason: '读取文件失败：' + (e as Error).message,
        name: '', sourceDevice: 'unknown', currentDevice: this.getCurrentDeviceType(),
        deviceMismatch: false, sourceVersion: 0, legacy: false, controlCount: 0
      }
    }
  }
}

/** 导入前分析结果（LayoutListPage 据此决定是否弹提示 / 拒绝）。 */
export interface ImportAnalysis {
  /** 是否可导入（格式合法、可迁移）。 */
  ok: boolean
  /** 'amcl' | 'pojav' | 'invalid'。 */
  format: string
  /** !ok 时的原因文案。 */
  reason: string
  /** 方案名（迁移后 / 或原始）。 */
  name: string
  /** 源方案目标设备：phone|tablet|foldable|any|unknown。 */
  sourceDevice: string
  /** 当前设备：phone|tablet。 */
  currentDevice: string
  /** 源设备为 phone/tablet 且与当前设备不同 → true（导入可能布局不合理）。 */
  deviceMismatch: boolean
  /** 源 version（0=未知）。 */
  sourceVersion: number
  /** 源版本 != 当前 schema 版本（需迁移的旧版）。 */
  legacy: boolean
  /** 迁移后控件数。 */
  controlCount: number
}

// 全局单例
let _instance: LayoutStore | null = null

export function getLayoutStore(): LayoutStore {
  if (!_instance) {
    _instance = new LayoutStore()
  }
  return _instance
}
