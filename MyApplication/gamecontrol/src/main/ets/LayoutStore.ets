import { AppLogger } from 'commons';
/**
 * LayoutStore.ets — 布局持久化服务
 *
 * - Preferences 存储（主存储；profiles / active_profile，另有只追加的 profiles_quarantine）
 * - JSON 导入/导出与多套方案管理；加载逐方案校验，非法原文先隔离备份再改写，只有启动器进程写盘
 * - 保存/回滚只发布已确认定义；Native配置应用由游戏会话的运行对象订阅，不由仓库主动执行
 */
import { ProcessPreferences, LaunchPreferenceStore, LaunchPreferenceSnapshot, LaunchPreferenceValue,
  OwnerLayoutSourceRepository, OwnerLayoutSourceEntry, OwnerLayoutSourceInput, OwnerLayoutSourceChange,
  OwnerLayoutSourceCompletion, evidenceTextDigest } from 'commons';
import { mergeLayoutPreferences, LayoutMergeResult } from './LayoutMerge';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { display } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  LayoutProfile, ControlItem, ControlType,
  getDefaultLayout, cloneLayout, cloneLayoutWithFreshGroupIds, migrateProfile, validateAndNormalizeLayout, generateControlId,
  legacyLookCompatibleLayout,
  validateAndNormalizeLayoutWithReason, LayoutValidationResult,
  repairLayoutControlIds, ControlIdRepairResult, utf8ByteLength,
  makeHotbarSelector, computeAutoGuiScale, computeHotbarRectPx, HotbarRectPx,
  LAYOUT_PROFILE_VERSION
} from './ControlLayout';
import { getAllPresets } from './LayoutPresets';
import { buildLayoutCandidate, MAX_LAYOUT_PROFILE_BYTES } from './LayoutCandidate';
import { GameSessionLayoutRepository, getGameSessionLayoutRepository, SessionLayoutCatalogEntry,
  SessionLayoutChange, SessionLayoutTransport, SessionLayoutCommit } from './GameSessionLayoutRepository';
import { normalizeLayoutSource } from './LayoutSourceNormalization';
import { mergeGameSessionLayouts } from './GameLayoutSessionMerge';
import { validateLayoutLibraryBudget } from './LayoutBudget';
import { InputConfigurationDelivery, InputConfigurationListener, InputConfigurationStatus,
  InputConfigurationProgressReader, InputPolicyActivationSnapshot, InputPolicyStatusListener,
  InputPolicyStatusRegistration, InputPolicyStatusSubscription, cloneInputPolicySnapshot,
  InputConfigurationDefinitionListener } from './InputConfiguration';
import { externalLayoutFormat, analyzeExternalLayout } from './ExternalLayoutImporter';
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

const TAG = 'LayoutStore';
const PREF_NAME = 'control_layout'
const KEY_PROFILES = 'profiles'       // JSON string of LayoutProfile[]
const KEY_ACTIVE = 'active_profile'   // string: name of active profile
const KEY_QUARANTINE = 'profiles_quarantine' // 只追加的隔离记录；只有启动器进程写，游戏 overlay 不接受此键

// 隔离区上限：ArkData Preferences 单个 string 值不得超过 16MB（官方常量 MAX_VALUE_LENGTH），且整个文件在
// getPreferencesSync 时同步载入内存。取 8 条 / 4 MiB：足以放下两份 1 MiB（布局合并上限）原文的
// JSON 转义副本，又不让每次冷启动同步读入过大的 XML。超限时封锁覆盖写入，绝不淘汰旧条目。
const QUARANTINE_SCHEMA: number = 1
const QUARANTINE_MAX_ENTRIES: number = 8
const QUARANTINE_MAX_BYTES: number = 4 * 1024 * 1024
const MAX_UNRESOLVED_ACTIVE_LOGS: number = 32

/** 隔离单条：raw 是捕获时 `profiles` 键的完整原文（逐字节），其余字段只含下标、原因码、时间与原活动名。 */
interface LayoutQuarantineEntry {
  digest: string
  capturedAt: number
  reasons: string[]
  invalidIndexes: number[]
  activeAtCapture: string
  raw: string
}

/** `profiles_quarantine` 的完整文档：schema 固定为 1，entries 只追加，按 digest + 原文去重，从不淘汰。 */
interface LayoutQuarantineDocument {
  schema: number
  entries: LayoutQuarantineEntry[]
}

/**
 * 最近一次异常加载的摘要，供布局列表页显示非阻塞提示。计数在本进程内保留到下一次异常加载；
 * writeBlocked / writeBlockMessage 实时反映是否仍封锁覆盖 `profiles` 的写入（消息可直接展示给用户）。
 */
export interface LayoutLoadIssues {
  quarantinedProfiles: number
  documentQuarantined: boolean
  repairedProfiles: number
  renamedProfiles: number
  activeFallback: boolean
  writeBlocked: boolean
  writeBlockMessage: string
}

/** 单次 load 的逐方案处理账本：只在内存里组装、不写盘；是否持久化由 `_doInit` 决定。 */
class LayoutSalvageReport {
  users: LayoutProfile[] = []
  userIndexes: number[] = []
  quarantinedIndexes: number[] = []
  // 仅用于判断原活动方案是否被隔离（trim 后比较）；方案名属于用户文本，绝不写进日志。
  quarantinedNames: string[] = []
  repairedIndexes: number[] = []
  reasons: string[] = []
  renamed: number = 0
  entryCount: number = 0
  presetCopies: number = 0
  invalidPresetCopies: number = 0
  unknownPresetCopies: number = 0
  secondPassReverted: string[] = []
  documentReason: string = ''
}

/**
 * 隔离记录去重与日志关联用的 64 位稳定摘要（两路 FNV-1a 变体，16 位十六进制）。它会随隔离记录
 * 持久化，算法必须保持不变，所以不复用 LayoutMerge 里只服务冲突副本命名的同形函数；不作安全用途，
 * 去重时仍逐字比较原文，碰撞最多多存一条。
 */
function layoutTextDigest(value: string): string {
  let first: number = 2166136261
  let second: number = 2246822519
  for (let index: number = 0; index < value.length; index++) {
    const code: number = value.charCodeAt(index)
    first = Math.imul(first ^ code, 16777619) >>> 0
    second = Math.imul(second ^ code, 3266489917) >>> 0
  }
  return first.toString(16).padStart(8, '0') + second.toString(16).padStart(8, '0')
}

/** 空值视为空文档；结构不符返回 null，调用方据此拒绝追加 —— 绝不覆盖一份读不懂的旧隔离记录。 */
function parseQuarantineDocument(value: LaunchPreferenceValue): LayoutQuarantineDocument | null {
  if (typeof value !== 'string') return null
  if (value.length === 0) {
    const empty: LayoutQuarantineDocument = { schema: QUARANTINE_SCHEMA, entries: [] }
    return empty
  }
  try {
    const parsed: LayoutQuarantineDocument = JSON.parse(value) as LayoutQuarantineDocument
    if (!parsed || typeof parsed !== 'object' || parsed.schema !== QUARANTINE_SCHEMA
        || !Array.isArray(parsed.entries)) return null
    for (let i = 0; i < parsed.entries.length; i++) {
      const item: LayoutQuarantineEntry = parsed.entries[i]
      if (!item || typeof item.digest !== 'string' || typeof item.raw !== 'string') return null
    }
    return parsed
  } catch (e) {
    return null
  }
}

/** 只有 id 超长 / 重复是可保守修复的首个失败原因；其它规则一律隔离，不猜测用户意图。 */
function isRepairableIdReason(reason: string): boolean {
  return reason.endsWith('.id-length') || reason.endsWith('.id-duplicate')
}

/** 原因直方：去掉 `profile[i]:` 前缀与所有下标，只按规则名计数，日志里不出现方案名或原文。 */
function reasonHistogram(reasons: string[]): string {
  const counts: Map<string, number> = new Map<string, number>()
  for (let i = 0; i < reasons.length; i++) {
    const colon: number = reasons[i].indexOf(':')
    const rule: string = (colon >= 0 ? reasons[i].substring(colon + 1) : reasons[i])
      .replace(new RegExp('\\[\\d+\\]', 'g'), '')
    counts.set(rule, (counts.get(rule) ?? 0) + 1)
  }
  const parts: string[] = []
  counts.forEach((count: number, rule: string) => { parts.push(rule + ':' + count.toString()) })
  parts.sort()
  return parts.length > 0 ? parts.join(',') : 'none'
}

/** 从 base 尾部按完整码点截短后拼接后缀，保证结果仍满足校验器的 256 UTF-8 字节名字上限。 */
function fitNameWithSuffix(base: string, suffix: string): string {
  const limit: number = 256 - utf8ByteLength(suffix)
  let prefix: string = base
  while (prefix.length > 0 && utf8ByteLength(prefix) > limit) {
    const last: number = prefix.charCodeAt(prefix.length - 1)
    // 末尾是低代理时连同高代理一起去掉，不留下半个码点。
    const cut: number = (last >= 0xDC00 && last <= 0xDFFF && prefix.length >= 2) ? 2 : 1
    prefix = prefix.substring(0, prefix.length - cut)
  }
  return prefix + suffix
}

/**
 * 在 taken 之外生成不重名的方案名（"<base>" → "<base> 副本" → "<base> 副本 2" ...）。
 * 新建、导入与加载时的重名改名共用这一条规则；结果恒不超过 256 字节，避免下一次 save 整表失败。
 */
function uniqueNameAmong(base: string, taken: Set<string>): string {
  if (!taken.has(base)) return base
  let n: number = 1
  let candidate: string = fitNameWithSuffix(base, ' 副本')
  while (taken.has(candidate)) {
    n++
    candidate = fitNameWithSuffix(base, ' 副本 ' + n.toString())
  }
  return candidate
}

export interface LayoutEditorStoreSnapshot {
  profiles: LayoutProfile[]
  activeName: string
  activeChosenAutomatically: boolean
  /** 未加载载荷的目录身份随回滚一起恢复，不能把占位空 controls 误当成用户删除。 */
  unloadedProfileIds?: string[]
}

/** 子进程布局导入结果；deferred 不代表已保存，调用方必须保留原始 journal。 */
export interface GameLayoutImportResult {
  deferred: boolean;
  changed: boolean;
  conflicts: string[];
}

/** 历史大库启动只冻结source及目录，不构造整份规范化Preferences字符串。 */
export interface LayoutLaunchSource {
  catalog: SessionLayoutCatalogEntry[]
  activeProfileId: string
  sourceDigest: string
  sourceBytes: number
  sourceGrowthCredit: number
  readProfileRaw: (profileId: string) => string
}

/** ArkTS明确实现仓库端口；闭包仍绑定同一Store队列和source实例，不另持方案状态。 */
class OwnerSourceSessionTransport implements SessionLayoutTransport {
  private reader: (entry: SessionLayoutCatalogEntry) => LayoutProfile
  private writer: (commit: SessionLayoutCommit) => Promise<void>
  constructor(reader: (entry: SessionLayoutCatalogEntry) => LayoutProfile, writer: (commit: SessionLayoutCommit) => Promise<void>) {
    this.reader = reader; this.writer = writer
  }
  readProfile(entry: SessionLayoutCatalogEntry): LayoutProfile { return this.reader(entry) }
  async commit(commit: SessionLayoutCommit): Promise<void> { await this.writer(commit) }
}

/** 只读订阅固定到原provider registration；不含Native端口或应用命令。 */
interface PolicyStatusObserver {
  registration: InputPolicyStatusRegistration
  subscription: InputPolicyStatusSubscription
  listener: InputPolicyStatusListener
}

export class LayoutStore {
  /** 原会话Runtime登记的只读provider；仓库不从报告决定持久提交或Native应用。 */
  private policyStatusRegistration: InputPolicyStatusRegistration | undefined = undefined
  private policyStatusProvider: (() => InputPolicyActivationSnapshot) | undefined = undefined
  private policyStatusObservers: PolicyStatusObserver[] = []

  /** 登记原会话的纯值 provider，返回不透明身份；仓库仅传递报告，不从报告决定保存或应用。 */
  registerInputPolicyStatusProvider(provider: () => InputPolicyActivationSnapshot): InputPolicyStatusRegistration {
    // 观察资格属于登记时的运行体。替换 provider 时退休旧订阅，不能保留前端闭包直到
    // 下一局再误投，也不能把旧订阅静默改绑到新 registration。
    this.policyStatusObservers = []
    const registration: InputPolicyStatusRegistration = new InputPolicyStatusRegistration()
    this.policyStatusRegistration = registration; this.policyStatusProvider = provider
    return registration
  }

  /** 仅原provider能注销自己；后来会话已登记时旧stop不能把新报告撤掉。 */
  removeInputPolicyStatusProvider(registration: InputPolicyStatusRegistration): void {
    this.policyStatusObservers = this.policyStatusObservers.filter((entry: PolicyStatusObserver): boolean => entry.registration !== registration)
    if (registration !== this.policyStatusRegistration) return
    this.policyStatusRegistration = undefined; this.policyStatusProvider = undefined
  }

  /** 只读副本；没有会话provider时返回undefined，不能把域缺席说成全已生效。 */
  inputPolicyStatus(): InputPolicyActivationSnapshot | undefined {
    if (this.policyStatusProvider === undefined) return undefined
    return cloneInputPolicySnapshot(this.policyStatusProvider())
  }

  /** 订阅捕获原registration，不在provider替换后偷取global current或重新挂到新局。 */
  addInputPolicyStatusListener(listener: InputPolicyStatusListener): InputPolicyStatusSubscription | undefined {
    const registration: InputPolicyStatusRegistration | undefined = this.policyStatusRegistration
    if (registration === undefined) return undefined
    const subscription: InputPolicyStatusSubscription = new InputPolicyStatusSubscription()
    this.policyStatusObservers.push({ registration: registration, subscription: subscription, listener: listener })
    this.publishInputPolicyStatus(registration)
    return subscription
  }
  /** 按原 subscription 精确移除；其它前端/新 registration 的观察不会一同退休。 */
  removeInputPolicyStatusListener(subscription: InputPolicyStatusSubscription): void {
    this.policyStatusObservers = this.policyStatusObservers.filter((entry: PolicyStatusObserver): boolean => entry.subscription !== subscription)
  }

  /** 实际定义投递/维护进展或原 Runtime 通知后只转发值；观察抛错不改变保存/应用事实。 */
  publishInputPolicyStatus(registration: InputPolicyStatusRegistration): void {
    if (registration !== this.policyStatusRegistration || this.policyStatusProvider === undefined) return
    const snapshot: InputPolicyActivationSnapshot = cloneInputPolicySnapshot(this.policyStatusProvider())
    for (const entry of this.policyStatusObservers.slice()) {
      if (entry.registration !== registration || this.policyStatusObservers.indexOf(entry) < 0) continue
      try { entry.listener(cloneInputPolicySnapshot(snapshot)) }
      catch (_) { /* 只读观察失败不夺走进度；继续其它原订阅，前端回收仍负责精确退订。 */ continue }
    }
  }
  /** 已确认的活动配置代次；同一快照不重发，失败保存不污染订阅者。 */
  private inputConfigurationDelivery: InputConfigurationDelivery = new InputConfigurationDelivery()
  /** 订阅者取得独立深拷贝，不能修改存储或其它前端的配置。 */
  addInputConfigurationListener(listener: InputConfigurationListener, name: string = 'input-view', progress?: InputConfigurationProgressReader): void {
    if (this._ready) this.publishInputConfiguration()
    this.inputConfigurationDelivery.add(name, listener, progress)
  }

  removeInputConfigurationListener(listener: InputConfigurationListener): void {
    this.inputConfigurationDelivery.remove(listener)
  }
  /** 会话只观察已确认定义，先于任何应用consumer；没有保存草稿入口。 */
  addInputConfigurationDefinitionListener(listener: InputConfigurationDefinitionListener): void {
    if (this._ready) this.publishInputConfiguration()
    this.inputConfigurationDelivery.addDefinitionListener(listener)
  }
  removeInputConfigurationDefinitionListener(listener: InputConfigurationDefinitionListener): void {
    this.inputConfigurationDelivery.removeDefinitionListener(listener)
  }

  /** 持久化事务完成后发布已确认定义。会话及前端订阅者各自负责真实应用，仓库不直接写Native。 */
  private publishInputConfiguration(saved: boolean = false): void {
    // 捕获本次实际投递前的 provider。同步应用/观察可能 stop/start；旧续体只可通知
    // 原登记，publish 的身份校验会拒绝它，不能从 current 借后来会话的通知资格。
    const registration: InputPolicyStatusRegistration | undefined = this.policyStatusRegistration
    const profile: LayoutProfile = this.getActiveProfile()
    this.inputConfigurationDelivery.publish(profile, saved)
    if (registration !== undefined) this.publishInputPolicyStatus(registration)
  }

  /** 会话维护重试未确认订阅者；仓库只管理定义投递回执，不自行决定Native运行政策。 */
  reconcileInputConfiguration(): void {
    const registration: InputPolicyStatusRegistration | undefined = this.policyStatusRegistration
    this.inputConfigurationDelivery.reconcile()
    if (registration !== undefined) this.publishInputPolicyStatus(registration)
  }

  /** 运行端口发生真实替换时，仅作废具名订阅者回执；保存修订和其它影响域保持原事实。 */
  invalidateInputConfiguration(name: string): void { this.inputConfigurationDelivery.invalidate(name) }

  inputConfigurationStatus(): InputConfigurationStatus[] { return this.inputConfigurationDelivery.status() }
  private pref: LaunchPreferenceStore | null = null
  private profiles: LayoutProfile[] = []
  private activeName: string = '默认'
  private activeChosenAutomatically: boolean = false
  private _ready: boolean = false
  private _initPromise: Promise<void> | null = null
  private editorSnapshot: LayoutEditorStoreSnapshot | null = null
  /** 只读编辑取消无需写盘；保存失败且回滚未知时仍走原恢复路径。 */
  private editorSnapshotRevision: number = 0
  private mutationRevision: number = 0
  /** 真实编辑器 lease 与普通 mutation 留下的取消快照分开，避免导入被永久误挡。 */
  private editorLeases: number = 0
  private editorOwnsSnapshot: boolean = false
  private mutationTail: Promise<void> = Promise.resolve()
  private pendingMutations: number = 0
  /** 回滚也失败意味着缓存/磁盘关系未知；本进程停止后续写入，保留 journal 等待冷启动恢复。 */
  private mutationPersistenceBlocked: boolean = false
  // 以下加载修复状态全部取“无事发生”的默认值：不经 init 直接设置字段的宿主测试与首装路径都安全。
  // pendingQuarantine 非空 = 磁盘 profiles 仍是需要先备份的原文；落盘或去重命中后清空。
  private pendingQuarantine: LayoutQuarantineEntry | null = null
  /** 内存是加载修复后的结果而磁盘还是原文（隔离/修 id/改名/活动名修正）；成功 save 后清除。 */
  private loadRepairPending: boolean = false
  /** 隔离记录无法落盘时封锁一切覆盖 profiles 的写入；原因码决定展示给用户的说明。 */
  private layoutWriteBlocked: boolean = false
  private layoutWriteBlockReason: string = ''
  private layoutWriteBlockLogged: string = ''
  private loadIssues: LayoutLoadIssues | null = null
  private unresolvedActiveLogged: Set<string> = new Set<string>()
  /** 导入回执在当前 Store 中冻结转换结果，窗口变化不会重新解释已确认坐标。 */
  private importReviews: Map<string, LayoutProfile> = new Map<string, LayoutProfile>()
  private importCommits: Map<string, Promise<LayoutProfile | null>> = new Map<string, Promise<LayoutProfile | null>>()
  private importInFlight: Set<string> = new Set<string>()
  private sessionRepository: GameSessionLayoutRepository | null = null
  private unloadedProfileIds: Set<string> = new Set<string>()
  /** mutation中的candidate只供提交使用；公共读取持续返回上一笔已确认快照，flush成功后才切换。 */
  private pendingReadSnapshot: LayoutEditorStoreSnapshot | null = null
  private ownerSourceRepository: OwnerLayoutSourceRepository | null = null
  private sourceCompletion: OwnerLayoutSourceCompletion | undefined = undefined
  private ownerContext: common.UIAbilityContext | null = null
  private sourceGrowthCredit: number = 0
  private readCacheOrder: string[] = []

  /** owner source借同一目录/净修改业务仓库，不引入第二份UI或另一个存储权威。 */
  private configureOwnerSource(source: OwnerLayoutSourceRepository): void {
    this.ownerSourceRepository = source
    const catalog: SessionLayoutCatalogEntry[] = source.getCatalog().map((entry: OwnerLayoutSourceEntry): SessionLayoutCatalogEntry => ({
      profileId: entry.profileId, profileRevision: entry.profileRevision, name: entry.name, isPreset: entry.isPreset,
      targetDevice: entry.targetDevice as 'phone' | 'tablet' | 'foldable' | 'any', bytes: entry.bytes, digest: entry.digest, payloadId: entry.payloadId }))
    const transport: SessionLayoutTransport = new OwnerSourceSessionTransport(
      (entry: SessionLayoutCatalogEntry): LayoutProfile => normalizeLayoutSource(source.readProfileRaw(entry.profileId), entry.profileId, entry.profileRevision, entry.name),
      async (commit: SessionLayoutCommit): Promise<void> => {
        const rows: Map<string, OwnerLayoutSourceEntry> = new Map<string, OwnerLayoutSourceEntry>()
        for (const entry of source.getCatalog()) rows.set(entry.profileId, entry)
        const changes: OwnerLayoutSourceChange[] = commit.changes.map((change: SessionLayoutChange): OwnerLayoutSourceChange => ({
          profileId: change.profileId, raw: change.proposed === null ? null : JSON.stringify(change.proposed) }))
        const current: OwnerLayoutSourceEntry[] = this.profiles.map((profile: LayoutProfile): OwnerLayoutSourceEntry => {
          const old: OwnerLayoutSourceEntry | undefined = rows.get(profile.profileId!)
          return { profileId: profile.profileId!, profileRevision: profile.profileRevision ?? 1, name: profile.name,
            isPreset: profile.isPreset === true, targetDevice: profile.targetDevice ?? 'any', bytes: old?.bytes ?? 1,
            digest: old?.digest ?? evidenceTextDigest(JSON.stringify(profile)), payloadId: old?.payloadId ?? '' }
        })
        await source.commit(current, changes, commit.activeProfileId, this.sourceCompletion)
        // owner提交完成后以当前已确认源目录重建基线；下一次不增加压力比较针对本次确认后的库。
        this.configureOwnerSource(source)
      })
    // 缩减后的source若已回到普通16MiB预算，重新给出剩余增长额度；超预算就只比较净内容不增长。
    // 逐个临时规范化且达到预算立即停止，不分配全库规范化数组/字符串。
    let canonicalBytes: number = 2
    for (const entry of catalog) {
      canonicalBytes += utf8ByteLength(JSON.stringify(normalizeLayoutSource(source.readProfileRaw(entry.profileId),
        entry.profileId, entry.profileRevision, entry.name))) + 1
      if (canonicalBytes > 16 * 1024 * 1024) break
    }
    this.sourceGrowthCredit = Math.max(0, 16 * 1024 * 1024 - canonicalBytes)
    this.sessionRepository = new GameSessionLayoutRepository(catalog, source.activeProfileId(), transport, true, this.sourceGrowthCredit)
    this.profiles = this.sessionRepository.initialProfiles()
    this.readCacheOrder = []
    this.unloadedProfileIds = new Set<string>(this.profiles.map((profile: LayoutProfile): string => profile.profileId!))
    this.activeName = this.sessionRepository.activeName()
    this.activeChosenAutomatically = false
    this.loadRepairPending = false
  }

  /** 每项只产生一个临时规范化对象核实语义，目录输入保留原raw范围，避免完整规范化数组膨胀。 */
  private async migrateLargeSource(raw: string, active: string, entries: LayoutProfile[], force: boolean = false): Promise<boolean> {
    if (this.ownerContext === null || this.pref === null || ProcessPreferences.isGameProcess()) return false
    // 已有目录后端的规范化库可大于XML原始界；它保持已核实普通路径，不能被保守估计误当SDK旧raw。
    if (utf8ByteLength(raw) > 16 * 1024 * 1024) return false
    // 为两个代码预设、唯一命名最大256-byte增长及目录身份字段保守预留，提前source迁移不拒写旧库。
    let estimate: number = 32 * 1024
    for (const entry of entries) {
      if (entry?.isPreset === true) continue
      const checked: LayoutProfile | null = validateAndNormalizeLayout(entry)
      if (checked !== null) {
        // 一个临时对象即释放，不先构造完整规范化数组再发现膨胀越界。
        const normalized: LayoutProfile = normalizeLayoutSource(JSON.stringify(entry), checked.profileId ?? 'p_00000000000000000000000000000000', checked.profileRevision ?? 1, checked.name)
        estimate += utf8ByteLength(JSON.stringify(normalized)) + 256 + 1
      }
      if (estimate > 32 * 1024 * 1024) break
    }
    if (!force && estimate <= 32 * 1024 * 1024) return false
    const inputs: OwnerLayoutSourceInput[] = []
    const invalidIndexes: number[] = []
    const names: Set<string> = new Set<string>()
    const ids: Set<string> = new Set<string>()
    for (const preset of getAllPresets()) {
      const id: string = 'preset_' + (preset.targetDevice ?? 'any')
      preset.profileId = id; preset.profileRevision = 1
      inputs.push({ profileId: id, profileRevision: 1, name: preset.name, isPreset: true,
        targetDevice: preset.targetDevice ?? 'any', sourceIndex: -1, raw: JSON.stringify(preset) })
      names.add(preset.name); ids.add(id)
    }
    for (let index: number = 0; index < entries.length; index++) {
      const entry: LayoutProfile = entries[index]
      if (entry?.isPreset === true) continue
      const checked: LayoutProfile | null = validateAndNormalizeLayout(entry)
      if (checked === null) { invalidIndexes.push(index); continue }
      let id: string = checked.profileId ?? ''
      if (id.length === 0 || ids.has(id)) {
        let allocated: boolean = false
        for (let attempt: number = 0; attempt < 16; attempt++) {
          const random: string = util.generateRandomUUID().toLowerCase()
          if (!new RegExp('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').test(random)) throw new Error('Invalid source profile UUID')
          id = 'p_' + random.replace(/-/g, '')
          if (!ids.has(id)) { allocated = true; break }
        }
        if (!allocated) throw new Error('Source profile identity allocation exhausted; original retained')
      }
      const name: string = uniqueNameAmong(checked.name, names)
      inputs.push({ profileId: id, profileRevision: checked.profileRevision ?? 1, name: name, isPreset: false,
        targetDevice: checked.targetDevice ?? 'any', sourceIndex: index, raw: JSON.stringify(entry) })
      ids.add(id); names.add(name)
    }
    const chosen: string = inputs.some((entry: OwnerLayoutSourceInput): boolean => entry.name === active) ? active
      : inputs.some((entry: OwnerLayoutSourceInput): boolean => entry.name === active.trim()) ? active.trim() : inputs[0].name
    this.configureOwnerSource(await OwnerLayoutSourceRepository.openOrMigrate(this.ownerContext, this.pref, raw, chosen, inputs))
    if (invalidIndexes.length > 0) {
      // source原文备份包含被排除的完整条目，提示不得把“目录可启动”宣称为全部旧条目已兼容。
      this.loadIssues = { quarantinedProfiles: invalidIndexes.length, documentQuarantined: false, repairedProfiles: 0,
        renamedProfiles: 0, activeFallback: chosen !== active, writeBlocked: false, writeBlockMessage: '' }
      AppLogger.warn(TAG, 'source迁移保留原库并排除非法目录项: count=' + invalidIndexes.length.toString()
        + ' sourceDigest=' + this.ownerSourceRepository!.sourceDigest())
    }
    return true
  }

  /** 方案身份只在真正新增时分配；旧版本首次加载一次性分配并与方案库一起持久化。 */
  private newProfileIdentity(): string {
    for (let attempt: number = 0; attempt < 16; attempt++) {
      const random: string = util.generateRandomUUID().toLowerCase()
      if (!new RegExp('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').test(random)) throw new Error('Invalid generated profile UUID')
      const id: string = 'p_' + random.replace(/-/g, '')
      if (!this.profiles.some((profile: LayoutProfile): boolean => profile.profileId === id)) return id
    }
    throw new Error('Profile identity allocation exhausted; existing entities preserved')
  }

  /** 导入操作身份属于预览租约，与持久方案实体分开分配，不共享计数或假装为方案ID。 */
  private newImportReviewIdentity(): string {
    for (let attempt: number = 0; attempt < 16; attempt++) {
      const random: string = util.generateRandomUUID().toLowerCase()
      if (!new RegExp('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').test(random)) throw new Error('Invalid generated review UUID')
      const id: string = 'r_' + random.replace(/-/g, '')
      if (!this.importReviews.has(id)) return id
    }
    throw new Error('Import review identity allocation exhausted')
  }

  /** 公共兼容状态可供列表提示；旧不支持结构保留身份、内容及导出，不当作另一种控件运行。 */
  getProfileCompatibility(name: string): string {
    const profile: LayoutProfile | null = this.getProfile(name)
    if (profile === null) return 'TargetMissing'
    const checked = buildLayoutCandidate(profile)
    return checked.reason
  }

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
    return { profiles: this.profiles.map((profile: LayoutProfile): LayoutProfile => this.copyStoredProfile(profile, this.unloadedProfileIds)),
      activeName: this.activeName, activeChosenAutomatically: this.activeChosenAutomatically,
      unloadedProfileIds: Array.from(this.unloadedProfileIds) }
  }

  private restoreState(snapshot: LayoutEditorStoreSnapshot): void {
    const unloaded: Set<string> = new Set<string>(snapshot.unloadedProfileIds ?? [])
    this.profiles = snapshot.profiles.map((profile: LayoutProfile): LayoutProfile => this.copyStoredProfile(profile, unloaded))
    this.activeName = snapshot.activeName
    this.activeChosenAutomatically = snapshot.activeChosenAutomatically
    this.unloadedProfileIds = new Set<string>(snapshot.unloadedProfileIds ?? [])
  }

  /** 未加载source项只复制目录字段，避免rollback把几十万个小raw方案扩成所有可选字段的对象。 */
  private copyStoredProfile(profile: LayoutProfile, unloaded: Set<string>): LayoutProfile {
    if (profile.profileId === undefined || !unloaded.has(profile.profileId)) return cloneLayout(profile)
    return { profileId: profile.profileId, profileRevision: profile.profileRevision, name: profile.name,
      isPreset: profile.isPreset, targetDevice: profile.targetDevice, globalScale: 1, controls: [] }
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
      // 失败回滚会把 profiles 写回操作前的磁盘原文；若本次 save 曾完成修复写回，待写标记必须一起恢复。
      const beforeRepairPending: boolean = this.loadRepairPending
      const previousProfiles: string = this.pref ? await this.pref.get(KEY_PROFILES, '') as string : ''
      const previousActive: string = this.pref ? await this.pref.get(KEY_ACTIVE, '') as string : ''
      const previousMarker: LaunchPreferenceValue = this.pref && rollbackPreferenceKey.length > 0
        ? await this.pref.get(rollbackPreferenceKey, '') : ''
      try {
        this.pendingReadSnapshot = before
        const result: T = await operation()
        this.mutationRevision++
        this.pendingReadSnapshot = null
        this.publishInputConfiguration(true)
        return result
      }
      catch (error) {
        this.restoreState(before)
        this.editorSnapshot = beforeEditor
        this.editorOwnsSnapshot = beforeOwned
        this.loadRepairPending = beforeRepairPending
        if (this.sessionRepository !== null) {
          // V2 adapter只有完整pending原子发布后才resolve；失败时上一笔净修改仍完整可用。
          // Store恢复独立目录/草稿即可，不能调用不存在的Preferences overlay回滚。
          if ((error as Error).message.startsWith('RollbackFailed:')) this.mutationPersistenceBlocked = true
        } else if (ProcessPreferences.isGameProcess()) {
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
      } finally { this.pendingReadSnapshot = null }
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
      this.ownerContext = context
      this.sessionRepository = getGameSessionLayoutRepository()
      if (this.sessionRepository !== null) {
        if (!ProcessPreferences.isGameProcess()) throw new Error('Only a game process may install frozen layout repository')
        this.profiles = this.sessionRepository.initialProfiles()
        this.unloadedProfileIds = new Set<string>(this.profiles.map((profile: LayoutProfile): string => profile.profileId!))
        this.activeName = this.sessionRepository.activeName()
        // 活动载荷优先验证；其它方案仅保留目录，首次列举不读取完整库或 parent XML。
        this.getActiveProfile()
        this._ready = true
        this.publishInputConfiguration()
        return
      }
      this.pref = ProcessPreferences.open(context, PREF_NAME)
      const source: OwnerLayoutSourceRepository | null = OwnerLayoutSourceRepository.open(context, this.pref)
      if (source !== null) this.configureOwnerSource(source)
      else await this.load()
    } catch (e) {
      AppLogger.error(TAG, '_doInit failed: ' + (e as Error).message)
      throw e as Error
    }
    // 修复写回失败不能让 init 失败：内存里已是 salvage 结果，写入封锁与“下次保存重试”都有明确出口。
    await this.persistLoadRepairOnce()
    this._ready = true
    this.publishInputConfiguration()
  }

  async waitReady(): Promise<void> {
    if (this._initPromise) await this._initPromise
  }

  /**
   * 启动器进程在 init 内经 mutation 队列执行一次迁移写：先把隔离记录写入并单独 flush，确认后才经
   * save 改写 profiles / active_profile。隔离失败只封锁后续覆盖写并记错误；第二步失败保留待写标记，
   * 由下一次 save、启动快照或游戏布局导入前重试。游戏进程从不进入这里（overlay 也不接受第三个键）。
   */
  private async persistLoadRepairOnce(): Promise<void> {
    if (ProcessPreferences.isGameProcess() || !this.loadRepairPending) return
    try {
      await this.runMutation<void>(async (): Promise<void> => {
        if (!(await this.persistPendingQuarantine())) return
        await this.save()
        AppLogger.info(TAG, '布局存档修复已写回')
      })
    } catch (e) {
      AppLogger.warn(TAG, '布局存档修复写回失败，内存保持修复结果，下次保存时重试', e as Error)
    }
  }

  /**
   * 纯内存的逐方案加载（不写盘）：保留全部合法方案，重名 / 占用预设名的用户方案改名保留，
   * 超长或重复的控件 id 保守修复，其余非法项隔离；旧预设副本只计数丢弃，永不连坐用户方案。
   * 结果写入 pendingQuarantine / loadRepairPending，是否以及何时持久化由调用方决定。
   */
  private async load(): Promise<void> {
    if (!this.pref) return
    let storedProfiles: LaunchPreferenceValue
    let storedActive: LaunchPreferenceValue
    try {
      storedProfiles = await this.pref.get(KEY_PROFILES, '')
      // 注：默认值 ''（空串）是有意为之——load 后如果是空串，pickDefaultByDevice
      // 会按设备短边 dp 自动选预设；老用户存过 active_profile 时会读到原值。
      storedActive = await this.pref.get(KEY_ACTIVE, '')
    } catch (e) {
      AppLogger.error(TAG, 'load: pref.get failed: ' + (e as Error).message)
      throw e as Error
    }
    const raw: string = typeof storedProfiles === 'string' ? storedProfiles : storedProfiles.toString()
    const activeRaw: string = typeof storedActive === 'string' ? storedActive : ''
    const report: LayoutSalvageReport = new LayoutSalvageReport()
    const entries: LayoutProfile[] = this.parseStoredProfiles(storedProfiles, report)
    if (await this.migrateLargeSource(raw, activeRaw, entries)) return

    // 系统预设始终以代码为准（预设精简 2026-05-30 起只有 ★ 手机 / ★ 平板）：存档里的 isPreset
    // 旧副本无论是否合法都丢弃，再用 getAllPresets() 的最新版本补回；预设名对用户方案保留。
    const presets: LayoutProfile[] = getAllPresets()
    for (const preset of presets) {
      preset.profileId = 'preset_' + (preset.targetDevice ?? 'any')
      const stored: LayoutProfile | undefined = entries.find((entry: LayoutProfile): boolean => entry !== null
        && entry.isPreset === true && entry.profileId === preset.profileId)
      preset.profileRevision = stored?.profileRevision ?? 1
    }
    const presetNames: Set<string> = new Set<string>()
    for (let i = 0; i < presets.length; i++) presetNames.add(presets[i].name)
    for (let i = 0; i < entries.length; i++) this.salvageEntry(entries[i], i, presetNames, report)
    this.assignUniqueNames(report, presetNames)

    // 预设排在用户方案前面（纯展示顺序）；二轮注入逐方案执行，失败只回退那一份。
    const finalProfiles: LayoutProfile[] = []
    for (let i = 0; i < presets.length; i++) {
      const preset: LayoutProfile | null = this.normalizeWithInjections(presets[i], 'preset[' + i.toString() + ']', report)
      if (preset !== null) finalProfiles.push(preset)
      else AppLogger.error(TAG, '系统预设未通过布局校验，已跳过: target=preset[' + i.toString() + ']')
    }
    for (let i = 0; i < report.users.length; i++) {
      const label: string = 'profile[' + report.userIndexes[i].toString() + ']'
      const user: LayoutProfile | null = this.normalizeWithInjections(report.users[i], label, report)
      if (user !== null) finalProfiles.push(user)
    }
    // 兜底：仍然空的话至少给一份默认布局
    if (finalProfiles.length === 0) {
      const fallback: LayoutProfile | null = this.normalizeWithInjections(getDefaultLayout(), 'default', report)
      finalProfiles.push(fallback !== null ? fallback : getDefaultLayout())
    }
    this.profiles = finalProfiles
    // 保守估计之外仍有最终去重/几何差异：合法SDK raw始终可退到source迁移，不在capture时硬拒启动。
    if (!ProcessPreferences.isGameProcess() && utf8ByteLength(JSON.stringify(finalProfiles)) > 32 * 1024 * 1024
        && await this.migrateLargeSource(raw, activeRaw, entries, true)) return
    const identities: Set<string> = new Set<string>()
    let identityMigration: boolean = raw.length === 0 || entries.some((entry: LayoutProfile): boolean => entry !== null
      && typeof entry === 'object' && (entry.profileId === undefined || entry.profileRevision === undefined))
    for (let index: number = 0; index < this.profiles.length; index++) {
      const profile: LayoutProfile = this.profiles[index]
      if (profile.profileId === undefined || identities.has(profile.profileId)) {
        profile.profileId = profile.isPreset === true ? 'preset_' + (profile.targetDevice ?? index.toString()) : this.newProfileIdentity()
        identityMigration = true
      }
      if (profile.profileRevision === undefined) { profile.profileRevision = 1; identityMigration = true }
      identities.add(profile.profileId)
    }
    const activeMode: string = this.resolveLoadedActive(activeRaw, report)
    this.recordLoadOutcome(raw, activeRaw, activeMode, report)
    // 空库/旧库身份迁移也要在下次启动快照之前成对落盘，不能每次进程加载重新分配实体。
    if (identityMigration && !ProcessPreferences.isGameProcess()) this.loadRepairPending = true

    // 到这里只完成定义加载；_doInit确认ready后统一发布，Native应用由本局运行订阅者负责。
  }

  /** 文档级解析：空串是首装；非字符串、JSON 语法错误或非数组整体记为文档级隔离，合法列表为空。 */
  private parseStoredProfiles(stored: LaunchPreferenceValue, report: LayoutSalvageReport): LayoutProfile[] {
    if (typeof stored !== 'string') {
      report.documentReason = 'not-string'
      return []
    }
    if (stored.length === 0) return []
    let parsed: LayoutProfile[] = []
    try {
      parsed = JSON.parse(stored) as LayoutProfile[]
    } catch (e) {
      report.documentReason = 'json-parse'
      return []
    }
    if (!Array.isArray(parsed)) {
      report.documentReason = 'not-array'
      return []
    }
    return parsed
  }

  /**
   * 处理一条存档元素。旧预设副本只计数（非法 / 未知名都会让磁盘需要改写）；用户方案先带原因校验，
   * 首个失败是 id 超长 / 重复时尝试保守修复并复验；仍非法则隔离并逐条记日志（下标、原因、字节数、
   * 摘要，不含原文与名字）。合法方案原样收下，重名处理统一交给 assignUniqueNames。
   */
  private salvageEntry(entry: LayoutProfile, index: number, presetNames: Set<string>,
    report: LayoutSalvageReport): void {
    report.entryCount++
    const isObject: boolean = entry !== null && entry !== undefined && typeof entry === 'object'
    if (isObject && entry.isPreset === true) {
      report.presetCopies++
      const copy: LayoutProfile | null = validateAndNormalizeLayout(entry)
      if (copy === null) report.invalidPresetCopies++
      else if (!presetNames.has(copy.name)) report.unknownPresetCopies++
      return
    }
    let result: LayoutValidationResult = validateAndNormalizeLayoutWithReason(entry)
    if (result.profile === null && isRepairableIdReason(result.reason)) {
      const repair: ControlIdRepairResult | null = repairLayoutControlIds(entry)
      if (repair !== null) {
        result = validateAndNormalizeLayoutWithReason(repair.profile)
        if (result.profile !== null) {
          report.repairedIndexes.push(index)
          report.reasons.push('profile[' + index.toString() + ']:repaired-control-id')
        }
      }
    }
    const profile: LayoutProfile | null = result.profile
    if (profile === null) {
      report.quarantinedIndexes.push(index)
      report.reasons.push('profile[' + index.toString() + ']:' + result.reason)
      if (isObject && typeof entry.name === 'string') report.quarantinedNames.push(entry.name.trim())
      const text: string = entry === undefined ? '' : JSON.stringify(entry)
      AppLogger.warn(TAG, '布局方案无法读取，已隔离: index=' + index.toString() + ' reason=' + result.reason
        + ' bytes=' + utf8ByteLength(text).toString() + ' digest=' + layoutTextDigest(text))
      return
    }
    report.users.push(profile)
    report.userIndexes.push(index)
  }

  /**
   * 名字去重放在全部方案校验之后：每个名字的首个合法出现者保留原名（占用预设名的除外），其余重名者
   * 再在“预设名 + 全部保留名 + 已分配名”之外取唯一名。这样后出现的用户原名不会被前面的改名抢占，
   * 输出也满足 LayoutMerge 的“名字唯一、用户方案不占预设名”规则。
   */
  private assignUniqueNames(report: LayoutSalvageReport, presetNames: Set<string>): void {
    const taken: Set<string> = new Set<string>()
    presetNames.forEach((name: string) => { taken.add(name) })
    const keeps: boolean[] = []
    for (let i = 0; i < report.users.length; i++) {
      const keep: boolean = !taken.has(report.users[i].name)
      keeps.push(keep)
      if (keep) taken.add(report.users[i].name)
    }
    for (let i = 0; i < report.users.length; i++) {
      if (keeps[i]) continue
      report.users[i].name = uniqueNameAmong(report.users[i].name, taken)
      taken.add(report.users[i].name)
      report.renamed++
    }
  }

  /**
   * 二轮（物品栏条对齐 / 系统按钮注入）在副本上逐方案执行并复验；失败只把这一份回退到首轮规范化
   * 结果（预设即代码里未对齐的新预设），不再像旧实现那样把整张表换成单个默认布局。返回 null 只可能
   * 是代码预设本身非法，由调用方记错误后跳过。
   */
  private normalizeWithInjections(firstPass: LayoutProfile, label: string,
    report: LayoutSalvageReport): LayoutProfile | null {
    const working: LayoutProfile = cloneLayout(firstPass)
    this.ensureHotbarSelector(working)
    const candidate = buildLayoutCandidate(working)
    if (candidate.profile !== null) return candidate.profile
    report.secondPassReverted.push(label + ':' + candidate.reason)
    AppLogger.warn(TAG, '布局兼容转换未完成，保留原方案供导出/恢复: target=' + label + ' reason=' + candidate.reason)
    return validateAndNormalizeLayout(firstPass)
  }

  /**
   * 活动方案解析：精确匹配 → trim 匹配（兼容旧版改名写下的未 trim 名，需回写一次）→ 设备预设。
   * 回退时区分“原活动方案被隔离”（原名保留在隔离记录的 activeAtCapture）与“名字本就不存在”；
   * 两种回退都让磁盘上的 active_profile 需要改写，否则独立进程的布局合并会拒绝整份快照。
   */
  private resolveLoadedActive(stored: string, report: LayoutSalvageReport): string {
    if (stored.length > 0 && this.profiles.some((p: LayoutProfile): boolean => p.name === stored)) {
      this.activeName = stored
      this.activeChosenAutomatically = false
      return 'exact'
    }
    const trimmed: string = stored.trim()
    if (trimmed.length > 0 && trimmed !== stored
        && this.profiles.some((p: LayoutProfile): boolean => p.name === trimmed)) {
      this.activeName = trimmed
      this.activeChosenAutomatically = false
      return 'trimmed'
    }
    this.activeName = this.pickDefaultByDevice()
    this.activeChosenAutomatically = true
    if (stored.length === 0) return 'default'
    if (report.documentReason.length > 0 || report.quarantinedNames.indexOf(trimmed) >= 0) return 'fallback-quarantined'
    return 'fallback-missing'
  }

  /**
   * 汇总本次加载：生成待落盘的隔离条目（文档级失败、隔离项或修过 id 时才需要，原文整串保存），
   * 计算磁盘是否需要改写，记一条汇总日志，并更新列表页提示。正常加载不产生任何日志或状态变化。
   */
  private recordLoadOutcome(raw: string, activeRaw: string, activeMode: string, report: LayoutSalvageReport): void {
    const activeRepaired: boolean = activeMode === 'trimmed' || activeMode === 'fallback-quarantined'
      || activeMode === 'fallback-missing'
    const needsBackup: boolean = report.documentReason.length > 0 || report.quarantinedIndexes.length > 0
      || report.repairedIndexes.length > 0
    const rewrite: boolean = needsBackup || activeRepaired || report.renamed > 0
      || report.invalidPresetCopies > 0 || report.unknownPresetCopies > 0
    this.pendingQuarantine = null
    if (needsBackup) {
      const reasons: string[] = report.reasons.slice()
      if (report.documentReason.length > 0) reasons.unshift('document:' + report.documentReason)
      const entry: LayoutQuarantineEntry = { digest: layoutTextDigest(raw), capturedAt: Date.now(), reasons: reasons,
        invalidIndexes: report.quarantinedIndexes.slice(), activeAtCapture: activeRaw, raw: raw }
      this.pendingQuarantine = entry
    }
    this.loadRepairPending = rewrite
    if (!rewrite && report.secondPassReverted.length === 0) return
    AppLogger.warn(TAG, '布局存档已逐方案处理: process=' + (ProcessPreferences.isGameProcess() ? 'game' : 'launcher')
      + ' entries=' + report.entryCount.toString() + ' kept=' + report.users.length.toString()
      + ' quarantined=' + report.quarantinedIndexes.length.toString()
      + ' repaired=' + report.repairedIndexes.length.toString() + ' renamed=' + report.renamed.toString()
      + ' presetCopies=' + report.presetCopies.toString()
      + ' invalidPresetCopies=' + report.invalidPresetCopies.toString()
      + ' unknownPresetCopies=' + report.unknownPresetCopies.toString()
      + ' secondPassReverted=' + report.secondPassReverted.length.toString()
      + ' document=' + (report.documentReason.length > 0 ? report.documentReason : 'ok')
      + ' rawBytes=' + utf8ByteLength(raw).toString() + ' digest=' + layoutTextDigest(raw)
      + ' active=' + activeMode + ' reasons=' + reasonHistogram(report.reasons))
    if (needsBackup || report.renamed > 0 || activeMode === 'fallback-quarantined') {
      const issues: LayoutLoadIssues = { quarantinedProfiles: report.quarantinedIndexes.length,
        documentQuarantined: report.documentReason.length > 0, repairedProfiles: report.repairedIndexes.length,
        renamedProfiles: report.renamed, activeFallback: activeMode === 'fallback-quarantined',
        writeBlocked: false, writeBlockMessage: '' }
      this.loadIssues = issues
    }
  }

  /**
   * 把待写的隔离条目追加进 `profiles_quarantine` 并单独 flush。true = 没有待写条目，或已确认落盘
   * （含 digest + 原文去重命中）；false = 必须封锁覆盖 profiles 的写入。只追加：旧条目逐字保留，
   * 超出条数 / 字节上限或读不懂现有记录时拒绝而不是淘汰；游戏进程永远不写这个键。
   */
  private async persistPendingQuarantine(): Promise<boolean> {
    const entry: LayoutQuarantineEntry | null = this.pendingQuarantine
    if (entry === null) return true
    const pref: LaunchPreferenceStore | null = this.pref
    if (pref === null) return this.blockLayoutWrites('quarantine-unavailable', entry, null)
    if (ProcessPreferences.isGameProcess()) return this.blockLayoutWrites('game-process', entry, null)
    let appended: boolean = false
    try {
      const document: LayoutQuarantineDocument | null = parseQuarantineDocument(await pref.get(KEY_QUARANTINE, ''))
      if (document === null) return this.blockLayoutWrites('quarantine-unreadable', entry, null)
      const present: boolean = document.entries.some((item: LayoutQuarantineEntry): boolean =>
        item.digest === entry.digest && item.raw === entry.raw)
      if (!present) {
        if (document.entries.length >= QUARANTINE_MAX_ENTRIES) return this.blockLayoutWrites('quarantine-full', entry, null)
        document.entries.push(entry)
        const serialized: string = JSON.stringify(document)
        if (utf8ByteLength(serialized) > QUARANTINE_MAX_BYTES) return this.blockLayoutWrites('quarantine-full', entry, null)
        await pref.put(KEY_QUARANTINE, serialized)
        appended = true
      }
      // 去重命中也要 flush：同进程上一次写入可能只进了 Preferences 缓存（flush 失败），不能把缓存当已落盘。
      await pref.flush()
    } catch (e) {
      return this.blockLayoutWrites('quarantine-write-failed', entry, e as Error)
    }
    this.pendingQuarantine = null
    this.clearLayoutWriteBlock()
    AppLogger.info(TAG, '布局隔离记录已落盘: digest=' + entry.digest + ' appended=' + (appended ? 'yes' : 'dedup')
      + ' rawBytes=' + utf8ByteLength(entry.raw).toString())
    return true
  }

  /** 进入写入封锁：同一原因只记一次错误（重试失败不刷屏）；返回 false 便于调用点直接 return。 */
  private blockLayoutWrites(reason: string, entry: LayoutQuarantineEntry, error: Error | null): boolean {
    this.layoutWriteBlocked = true
    this.layoutWriteBlockReason = reason
    if (this.layoutWriteBlockLogged !== reason) {
      this.layoutWriteBlockLogged = reason
      AppLogger.error(TAG, '布局隔离记录无法落盘，已封锁覆盖 profiles 的写入: reason=' + reason
        + ' digest=' + entry.digest + ' rawBytes=' + utf8ByteLength(entry.raw).toString(), error)
    }
    return false
  }

  private clearLayoutWriteBlock(): void {
    this.layoutWriteBlocked = false
    this.layoutWriteBlockReason = ''
    this.layoutWriteBlockLogged = ''
  }

  /** 封锁期间所有覆盖 profiles 的写入抛出的用户可见说明；原始存档保持不动。 */
  private layoutWriteBlockMessage(): string {
    if (this.layoutWriteBlockReason === 'quarantine-full') {
      return '无法读取的布局原文已达隔离备份上限，为防止覆盖原数据，暂不能保存布局修改'
    }
    if (this.layoutWriteBlockReason === 'game-process') {
      return '游戏内不能备份无法读取的布局原文，请回到启动器后再保存布局修改'
    }
    return '无法读取的布局原文尚未备份成功，为防止覆盖原数据，暂不能保存布局修改；请重启应用后重试'
  }

  /** 列表页提示用的加载异常摘要；每次返回新对象，调用方修改不影响存储。 */
  getLoadIssues(): LayoutLoadIssues {
    const base: LayoutLoadIssues | null = this.loadIssues
    const issues: LayoutLoadIssues = {
      quarantinedProfiles: base !== null ? base.quarantinedProfiles : 0,
      documentQuarantined: base !== null ? base.documentQuarantined : false,
      repairedProfiles: base !== null ? base.repairedProfiles : 0,
      renamedProfiles: base !== null ? base.renamedProfiles : 0,
      activeFallback: base !== null ? base.activeFallback : false,
      writeBlocked: this.layoutWriteBlocked,
      writeBlockMessage: this.layoutWriteBlocked ? this.layoutWriteBlockMessage() : ''
    }
    return issues
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
    if (p.controlGroups !== undefined) sel.controlGroupId = p.defaultControlGroupId
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
   * 保证方案含输入、设置、显示和鼠标系统功能按钮（不可删除）。仿 ensureHotbarSelector：
   *   1. 老存档里 id='ime_chat' 但无 systemAction 的按钮 → 升级为 input 系统按钮，并从"仅游戏"改为常驻可见；
   *   2. 输入/设置/显示缺项补齐；鼠标迁移默认滚轮或在缺项时注入，保留用户定位。
   * 注入后整表复验，越界（如满 256）则回滚，绝不产生非法布局。
   */
  private ensureSystemControls(p: LayoutProfile): void {
    const candidate = buildLayoutCandidate(p)
    if (candidate.profile === null) throw new Error(candidate.reason)
    p.controls = candidate.profile.controls
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

  private async save(): Promise<void> {
    if (this.sessionRepository !== null) {
      await this.sessionRepository.commit(this.profiles, this.unloadedProfileIds, this.activeName)
      return
    }
    // 最终candidate一次检查实际UTF-8与用户内容增长；必要加载迁移独立标明，不能套V1通道上限。
    const previous: LayoutProfile[] = this.pendingReadSnapshot?.profiles ?? this.profiles
    validateLayoutLibraryBudget(previous, this.profiles, this.loadRepairPending)
    if (!this.pref) throw new Error('布局存储尚未初始化')
    // 加载修复待写时，隔离记录必须先于任何覆盖 profiles 的写入单独 flush 成功（两次 flush，
    // 不依赖 Preferences flush 是否原子）；备份失败即拒绝本次写入，原始 profiles 保持不动。
    if (!(await this.persistPendingQuarantine())) throw new Error(this.layoutWriteBlockMessage())
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
      this.loadRepairPending = false
    } catch (e) {
      AppLogger.error(TAG, 'save: pref.put/flush failed: ' + (e as Error).message)
      throw e as Error
    }
  }

  /**
   * 获取当前活跃的布局方案。名字解析不到时仍返回一个合法方案（首个方案）并同步 activeName，
   * 但每个解析失败的名字记一次日志（只记字节数与摘要），让内存与磁盘分叉在持久日志里可见。
   */
  getActiveProfile(): LayoutProfile {
    if (this.pendingReadSnapshot !== null) {
      const previous: LayoutProfile | null = this.getProfile(this.pendingReadSnapshot.activeName)
      if (previous !== null) return previous
    }
    const p: LayoutProfile | null = this.getProfile(this.activeName)
    if (p !== null) return p
    if (this.profiles.length > 0) {
      this.noteUnresolvedActive(this.activeName)
      this.activeName = this.profiles[0].name
      return this.getProfile(this.profiles[0].name)!
    }
    const def = getDefaultLayout()
    this.profiles.push(def)
    this.activeName = def.name
    return cloneLayout(def)
  }

  /** 同一个无法解析的活动名只记一次；集合有上限，异常循环也不会无界增长内存或刷屏。 */
  private noteUnresolvedActive(name: string): void {
    if (this.unresolvedActiveLogged.has(name) || this.unresolvedActiveLogged.size >= MAX_UNRESOLVED_ACTIVE_LOGS) return
    this.unresolvedActiveLogged.add(name)
    AppLogger.warn(TAG, '活动布局名无法解析，已回退到首个方案: nameBytes=' + utf8ByteLength(name).toString()
      + ' digest=' + layoutTextDigest(name))
  }

  /** Recompute only device-derived defaults when a new authoritative Window generation arrives. */
  refreshDeviceDerivedLayout(): void {
    if (!this._ready) return
    // 冻结基线不能随游戏窗口变化被持久化改写；实际热栏几何由 runtime 纯投影负责。
    if (this.sessionRepository !== null) { this.publishInputConfiguration(); return }
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
    this.publishInputConfiguration()
  }

  /**
   * 获取所有方案名称
   */
  getProfileNames(): string[] {
    return (this.pendingReadSnapshot?.profiles ?? this.profiles).map(p => p.name)
  }

  /**
   * 只读取目录元数据，返回预设方案名称的独立数组，供列表缓存预设标识。
   * mutation 未确认时沿用公共读取的上一笔快照；空快照也不能回退到待提交目录。
   * 这里只访问 isPreset/name，不经 getProfile/getAllProfiles 触发冻结载荷懒加载、
   * 完整方案深拷贝或读缓存更新，也不写存储、通知订阅者或改变编辑事务。
   * 字符串按值加入新数组；调用方增删或替换返回项不会污染仓库中的目录。
   */
  getPresetProfileNames(): string[] {
    const names: string[] = []
    const profiles: LayoutProfile[] = this.pendingReadSnapshot?.profiles ?? this.profiles
    for (const profile of profiles) {
      if (profile.isPreset) names.push(profile.name)
    }
    return names
  }

  /** 公共读取分配完整深拷贝；调用方不能通过引用绕过串行提交和持久化。 */
  getAllProfiles(): LayoutProfile[] {
    return (this.pendingReadSnapshot?.profiles ?? this.profiles).map((profile: LayoutProfile): LayoutProfile => this.getProfile(profile.name)!)
  }

  /** 单方案读取按 catalog 身份懒加载，仅命中的载荷进入本局可编辑副本。 */
  getProfile(name: string): LayoutProfile | null {
    const profiles: LayoutProfile[] = this.pendingReadSnapshot?.profiles ?? this.profiles
    const unloaded: Set<string> = this.pendingReadSnapshot === null ? this.unloadedProfileIds
      : new Set<string>(this.pendingReadSnapshot.unloadedProfileIds ?? [])
    const index: number = profiles.findIndex((profile: LayoutProfile): boolean => profile.name === name)
    if (index < 0) return null
    const profile: LayoutProfile = profiles[index]
    if (this.sessionRepository !== null && profile.profileId !== undefined && unloaded.has(profile.profileId)) {
      const loaded: LayoutProfile = this.sessionRepository.readProfile(profile.profileId)
      // 目录改名后的未加载项仍读取旧冻结内容，再只应用已经确认的元数据变化。
      loaded.name = profile.name
      loaded.profileRevision = profile.profileRevision
      profiles[index] = loaded
      unloaded.delete(profile.profileId)
      if (this.pendingReadSnapshot !== null) this.pendingReadSnapshot.unloadedProfileIds = Array.from(unloaded)
    }
    const result: LayoutProfile = cloneLayout(profiles[index])
    if (this.sessionRepository !== null && this.pendingReadSnapshot === null && result.profileId !== undefined) {
      this.readCacheOrder = this.readCacheOrder.filter((id: string): boolean => id !== result.profileId)
      this.readCacheOrder.push(result.profileId)
      while (this.readCacheOrder.length > 65) {
        const oldId: string = this.readCacheOrder.shift()!
        const oldIndex: number = this.profiles.findIndex((item: LayoutProfile): boolean => item.profileId === oldId)
        if (oldIndex < 0) continue
        const old: LayoutProfile = this.profiles[oldIndex]
        // 活动和已修改实体仍持有真实定义；未改只读页回到目录占位，下一次按冻结载荷重新读取。
        if (old.name === this.activeName || !this.sessionRepository.isFrozenDefinition(old)) continue
        this.unloadedProfileIds.add(oldId)
        this.profiles[oldIndex] = this.copyStoredProfile(old, this.unloadedProfileIds)
      }
    }
    return result
  }

  /** 编辑器事务：捕获进入编辑器前的完整方案列表及活跃方案。 */
  beginEditorTransaction(): void {
    if (this.editorSnapshot) return
    this.editorSnapshot = this.captureState()
    this.editorSnapshotRevision = this.mutationRevision
  }

  /** 保存成功后提交编辑器事务，避免后续取消恢复已保存内容。 */
  commitEditorTransaction(): void {
    this.editorSnapshot = null
    this.editorOwnsSnapshot = false
  }

  /** 取消编辑器时恢复并保存完整方案列表；确认后发布定义，真实运行应用由会话订阅者执行。 */
  async restoreEditorTransaction(): Promise<boolean> {
    if (this.editorSnapshot !== null && this.pendingMutations === 0 && !this.mutationPersistenceBlocked &&
      this.editorSnapshotRevision === this.mutationRevision) {
      this.commitEditorTransaction()
      return true
    }
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
    const target: LayoutProfile | undefined = this.profiles.find((profile: LayoutProfile): boolean => profile.name === name)
    if (target === undefined) throw new Error('TargetMissing:方案已删除或改名')
    const issue: string = this.getProfileCompatibility(name)
    if (issue.length > 0) throw new Error(issue)
    this.captureEditorTransaction()
    this.activeName = name
    this.activeChosenAutomatically = false
    await this.save()
    })
  }

  /**
   * 保存当前方案（更新到 profiles 数组并持久化）。
   * 阶段 2.2：拒绝直接保存到 isPreset 方案上——应当先 cloneAsUser 出一份副本。
   * 返回 true 表示保存成功；false 表示被拒绝（调用方应提示用户先克隆）。
   */
  async saveProfile(profile: LayoutProfile): Promise<boolean> {
    // 在 enqueue 前复制 UI 草稿，等待持久化期间调用方的继续编辑不改变该请求。
    const draft: LayoutProfile = cloneLayout(profile)
    return this.runMutation<boolean>(async (): Promise<boolean> => {
    if (draft.profileId === undefined || draft.profileRevision === undefined) return false
    this.captureEditorTransaction()
    // 外部传入对象一律先规范化；失败时不修改内存、不落盘，避免部分接受。
    const normalized = validateAndNormalizeLayout(draft)
    if (!normalized) return false
    // 保存也走系统入口补齐，不允许一次导入或外部草稿把不可删除入口永久省略。
    // 所有改动仍在规范化副本上，完整校验失败就结束本次事务，既有方案保持。
    const checked = buildLayoutCandidate(normalized).profile
    if (!checked) return false
    const idx = checked.profileId === undefined ? this.profiles.findIndex(p => p.name === checked.name)
      : this.profiles.findIndex(p => p.profileId === checked.profileId)
    if (idx < 0) return false
    if (idx >= 0 && this.profiles[idx].isPreset) {
      // 不允许覆盖系统预设。这里直接 reject；UI 应当提示用户去克隆。
      return false
    }
    const current: LayoutProfile = this.profiles[idx]
    // 实体/版本必须同时匹配。改名、删除后重建以及并行编辑不能被旧草稿覆盖。
    if (current.name !== checked.name || current.profileRevision !== checked.profileRevision) return false
    checked.profileId = current.profileId
    checked.profileRevision = (current.profileRevision ?? 1) + 1
    this.profiles[idx] = cloneLayout(checked)
    this.activeName = checked.name
    this.activeChosenAutomatically = false
    await this.save()
    return true
    })
  }

  /**
   * 编辑完成的一次原子提交。进入预设只创建内存草稿；此处在原串行事务中验证原身份、
   * 重映射副本组图并一次写入最终内容。失败由runMutation恢复完整目录，不留下半成品。
   * 原saveProfile继续拒绝预设，避免扩大其它调用方的权限。
   */
  async saveEditedProfile(profile: LayoutProfile): Promise<LayoutProfile | null> {
    const draft: LayoutProfile=cloneLayout(profile)
    return this.runMutation<LayoutProfile | null>(async (): Promise<LayoutProfile | null> => {
      if (draft.profileId === undefined || draft.profileRevision === undefined) return null
      const index: number=this.profiles.findIndex((item: LayoutProfile): boolean => item.profileId===draft.profileId)
      if (index<0) return null
      const current: LayoutProfile=this.profiles[index]
      if (current.name!==draft.name || current.profileRevision!==draft.profileRevision) return null
      const checked: LayoutProfile | null=buildLayoutCandidate(draft).profile
      if (checked===null) return null
      this.captureEditorTransaction()
      let result: LayoutProfile=checked
      if (current.isPreset) {
        result=cloneLayoutWithFreshGroupIds(checked)
        result.name=this.uniqueProfileName(current.name+' 副本')
        result.profileId=this.newProfileIdentity()
        result.profileRevision=1
        result.isPreset=false
        const candidate: LayoutProfile | null=buildLayoutCandidate(result).profile
        if (candidate===null) return null
        result=candidate
        this.profiles.push(result)
      } else {
        result.isPreset=false
        result.profileRevision=(current.profileRevision ?? 1)+1
        this.profiles[index]=result
      }
      this.activeName=result.name
      this.activeChosenAutomatically=false
      await this.save()
      return cloneLayout(result)
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
    const src = this.getProfile(srcName)
    if (!src) return null
    const copy = cloneLayoutWithFreshGroupIds(src)
    this.ensureSystemControls(copy)
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
    copy.profileId = this.newProfileIdentity()
    copy.profileRevision = 1
    this.profiles.push(copy)
    this.activeName = candidate
    this.activeChosenAutomatically = false
    await this.save()
    return cloneLayout(copy)
    })
  }

  /**
   * 新建方案（从经典手机预设克隆，去掉 isPreset 标记）。name 只是期望名：已被占用（含预设名）时
   * 按 uniqueProfileName 追加“副本”后缀，重名会让选中、保存、删除都命中错误的方案，并使独立进程
   * 启动时的布局合并整笔拒绝。返回对象的 name 是实际创建的名字，调用方的提示与选中必须以它为准。
   */
  async createProfile(name: string): Promise<LayoutProfile> {
    return this.runMutation<LayoutProfile>(async (): Promise<LayoutProfile> => {
    this.captureEditorTransaction()
    const presets: LayoutProfile[] = this.sessionRepository === null ? getAllPresets()
      : this.profiles.filter((profile: LayoutProfile): boolean => profile.isPreset === true)
        .map((profile: LayoutProfile): LayoutProfile => this.getProfile(profile.name)!)
    const tpl = presets.length > 0 ? cloneLayout(presets[0]) : getDefaultLayout()
    const actualName: string = this.uniqueProfileName(name)
    tpl.name = actualName
    tpl.isPreset = false
    tpl.profileId = this.newProfileIdentity()
    tpl.profileRevision = 1
    this.ensureHotbarSelector(tpl)
    this.ensureSystemControls(tpl)
    this.profiles.push(tpl)
    this.activeName = actualName
    this.activeChosenAutomatically = false
    await this.save()
    return cloneLayout(tpl)
    })
  }

  /**
   * 删除方案。阶段 2.2：拒绝删除系统预设；返回 true 表示删除成功。
   */
  async deleteProfile(name: string): Promise<boolean> {
    return this.runMutation<boolean>(async (): Promise<boolean> => {
    this.captureEditorTransaction()
    const target = this.profiles.find(p => p.name === name)
    if (target === undefined) return false
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
    }
    await this.save()
    return true
    })
  }

  /**
   * 重命名方案。阶段 2.2：拒绝重命名系统预设。新名先 trim；活动名必须写成同一个 trim 后的值，
   * 否则磁盘上的 active_profile 指向不存在的方案，getter 会静默回退、独立进程启动准备会失败。
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
    p.profileRevision = (p.profileRevision ?? 1) + 1
    if (this.activeName === oldName) {
      this.activeName = trimmed
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
    const presets: LayoutProfile[] = this.sessionRepository === null ? getAllPresets()
      : this.profiles.filter((profile: LayoutProfile): boolean => profile.isPreset === true)
        .map((profile: LayoutProfile): LayoutProfile => this.sessionRepository!.readProfile(profile.profileId!))
    const target = this.profiles.find(p => p.name === name)
    if (target === undefined) throw new Error('TargetMissing:方案已删除或改名')
    if (target.isPreset === true && this.sessionRepository !== null) {
      // 本局预设只取冻结载荷，不调用后来代码builder或制造不可编辑preset的假修订。
      const frozen: LayoutProfile = this.sessionRepository.readProfile(target.profileId!)
      const index: number = this.profiles.findIndex((profile: LayoutProfile): boolean => profile.profileId === target.profileId)
      this.profiles[index] = frozen
      this.unloadedProfileIds.delete(target.profileId!)
      await this.save()
      return cloneLayout(frozen)
    }
    if (target && target.isPreset) {
      // 系统预设重置 = 重新调其对应 builder 拿一份新的（保持自身名字/身份）。
      const fresh = presets.find(p => p.name === name)
      if (fresh) {
        fresh.profileId = target.profileId
        fresh.profileRevision = (target.profileRevision ?? 1) + 1
        this.ensureHotbarSelector(fresh)
        this.ensureSystemControls(fresh)
        const idx = this.profiles.findIndex(p => p.name === name)
        if (idx >= 0) this.profiles[idx] = fresh
        await this.save()
        return cloneLayout(fresh)
      }
    }
    // 用户方案重置 = 按当前设备类型重置为对应系统预设（手机→★手机、平板→★平板），保留原方案名。
    const deviceType = this.getCurrentDeviceType()
    let base = presets.find(p => p.targetDevice === deviceType)
    if (!base) base = presets.length > 0 ? presets[0] : getDefaultLayout()
    const reset = cloneLayout(base)
    reset.name = name
    reset.isPreset = false
    reset.profileId = target.profileId
    reset.profileRevision = (target.profileRevision ?? 1) + 1
    this.ensureHotbarSelector(reset)
    this.ensureSystemControls(reset)
    const idx = this.profiles.findIndex(p => p.name === name)
    if (idx >= 0) {
      this.profiles[idx] = reset
    }
    await this.save()
    return cloneLayout(reset)
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
      // 加载修复尚未写回时 current 仍是原文（可能含隔离项），合并会整笔拒绝；先按“隔离优先”补写，
      // 封锁中则抛出用户可见原因。之后失败的回滚会连同待写标记一起恢复（见 runMutation）。
      if (this.loadRepairPending) await this.save()
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

  /** V2净修改在同一队列现读current，完成标记与布局同flush；外部回执失败重试不会复活后来删除的方案。 */
  importGameSessionChanges(catalog: SessionLayoutCatalogEntry[], changes: SessionLayoutChange[],
    baseActiveId: string, proposedActiveId: string, sessionId: string, digest: string,
    readBase: (entry: SessionLayoutCatalogEntry) => LayoutProfile): Promise<GameLayoutImportResult> {
    if (!new RegExp('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').test(sessionId)
        || !new RegExp('^[0-9a-f]{64}$').test(digest)) return Promise.reject<GameLayoutImportResult>(new Error('Invalid V2 merge identity'))
    const markerKey: string = 'game_layout_applied_' + sessionId
    return this.runMutation<GameLayoutImportResult>(async (): Promise<GameLayoutImportResult> => {
      if (ProcessPreferences.isGameProcess() || this.pref === null) throw new Error('Only initialized owner may import V2 layouts')
      if (this.isEditorActive()) return { deferred: true, changed: false, conflicts: [] }
      if (await this.pref.get(markerKey, '') === digest) return { deferred: false, changed: false, conflicts: [] }
      if (this.ownerSourceRepository !== null) {
        const merged = mergeGameSessionLayouts(catalog, changes, this.profiles, this.activeName,
          baseActiveId, proposedActiveId, sessionId, readBase, {
            unloaded: new Set<string>(this.unloadedProfileIds),
            readProfile: (id: string): LayoutProfile => {
              const metadata: LayoutProfile | undefined = this.profiles.find((profile: LayoutProfile): boolean => profile.profileId === id)
              if (metadata === undefined) throw new Error('TargetMissing:source current实体不存在')
              return normalizeLayoutSource(this.ownerSourceRepository!.readProfileRaw(id), id, metadata.profileRevision ?? 1, metadata.name)
            }
          })
        this.profiles = merged.profiles
        this.activeName = merged.activeName
        this.sourceCompletion = { key: markerKey, value: digest }
        try { await this.save() } finally { this.sourceCompletion = undefined }
        return { deferred: false, changed: merged.changed, conflicts: merged.conflicts }
      }
      if (this.loadRepairPending) await this.save()
      // owner的队内内存已与已确认Preferences同源；额外现读磁盘两键并验证，防止外部缓存更新被忽略。
      const raw: string = await this.pref.get(KEY_PROFILES, '') as string
      const active: string = await this.pref.get(KEY_ACTIVE, '') as string
      const current: LayoutProfile[] = JSON.parse(raw) as LayoutProfile[]
      const merged = mergeGameSessionLayouts(catalog, changes, current, active, baseActiveId, proposedActiveId, sessionId, readBase)
      validateLayoutLibraryBudget(current, merged.profiles)
      if (merged.changed) {
        await this.pref.put(KEY_PROFILES, JSON.stringify(merged.profiles))
        await this.pref.put(KEY_ACTIVE, merged.activeName)
      }
      await this.pref.put(markerKey, digest)
      await this.pref.flush()
      this.profiles = merged.profiles.map((profile: LayoutProfile): LayoutProfile => cloneLayout(profile))
      this.activeName = merged.activeName
      this.activeChosenAutomatically = false
      return { deferred: false, changed: merged.changed, conflicts: merged.conflicts }
    }, markerKey)
  }

  /**
   * 启动快照与布局写入共用队列，不能在 profiles/active 两键尚未成对确认时抓取半批。快照只读磁盘原值、
   * 只含这两个键；若加载修复尚未写回（磁盘仍是合并会拒绝的原文），先按隔离优先的顺序补写，失败则让
   * 启动准备带着用户可见原因失败，而不是把无法合并的原文交给游戏进程。
   */
  captureLaunchPreferences(): Promise<LaunchPreferenceSnapshot> {
    return this.runMutation<LaunchPreferenceSnapshot>(async (): Promise<LaunchPreferenceSnapshot> => {
      if (this.ownerSourceRepository !== null) throw new Error('Source布局库请使用captureLaunchLayoutSource，不能伪装成完整Preferences字符串')
      const pref = this.pref
      if (pref === null) throw new Error('布局存储尚未初始化')
      if (this.loadRepairPending && !ProcessPreferences.isGameProcess()) await this.save()
      const values: Record<string, LaunchPreferenceValue> = {
        'profiles': await pref.get(KEY_PROFILES, '') as string,
        'active_profile': await pref.get(KEY_ACTIVE, '') as string
      }
      return { name: PREF_NAME, values: values }
    })
  }

  /** 与mutation同队列获取已确认source目录，readProfileRaw绑定此已提交owner仓库，freeze随即固定其载荷。 */
  captureLaunchLayoutSource(): Promise<LayoutLaunchSource | null> {
    return this.runMutation<LayoutLaunchSource | null>(async (): Promise<LayoutLaunchSource | null> => {
      const source: OwnerLayoutSourceRepository | null = this.ownerSourceRepository
      if (source === null) return null
      const catalog: SessionLayoutCatalogEntry[] = source.getCatalog().map((entry: OwnerLayoutSourceEntry): SessionLayoutCatalogEntry => ({
        profileId: entry.profileId, profileRevision: entry.profileRevision, name: entry.name, isPreset: entry.isPreset,
        targetDevice: entry.targetDevice as 'phone' | 'tablet' | 'foldable' | 'any', bytes: entry.bytes, digest: entry.digest, payloadId: entry.payloadId }))
      return { catalog: catalog, activeProfileId: source.activeProfileId(), sourceDigest: source.sourceDigest(), sourceBytes: source.sourceBytes(), sourceGrowthCredit: this.sourceGrowthCredit,
        readProfileRaw: (profileId: string): string => source.readProfileRaw(profileId) }
    })
  }

  // ==================== JSON 导出/导入 ====================

  /**
   * 导出指定方案为 JSON 字符串
   */
  exportToJson(name: string, legacyCompatible: boolean = false): string {
    const p = this.getProfile(name)
    if (!p) return '{}'
    // 导出时盖上当前设备型号（信息记录用，不改内存里的方案）。
    // 普通导出保留v4全部来源政策；用户明确选择旧版兼容时才作v3值投影。
    // 投影采用当前确认的全部控件和编辑结果，不修改长期库，也不覆盖原v4恢复材料。
    const copy: LayoutProfile | null = legacyCompatible ? legacyLookCompatibleLayout(p) : cloneLayout(p)
    if (copy === null) throw new Error('Invalid layout cannot be exported for an older reader')
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

  /** 生成不与现有任何方案（含系统预设）重名的名字（"<base>" → "<base> 副本" → "<base> 副本 2" ...）。 */
  private uniqueProfileName(base: string): string {
    const taken: Set<string> = new Set<string>()
    for (let i = 0; i < this.profiles.length; i++) taken.add(this.profiles[i].name)
    return uniqueNameAmong(base, taken)
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
  async importFromJson(json: string, acceptCompatibilityWarnings: boolean = false): Promise<LayoutProfile | null> {
    const review: ImportAnalysis = this.analyzeImport(json)
    if (!review.ok || ((review.warnings ?? []).length > 0 && !acceptCompatibilityWarnings)) return null
    return this.commitReviewedImport(review.reviewId ?? '')
  }

  /**
   * 新增导入与编辑更新是不同命令。名称和身份仅在完整 mutation 队首分配，两个独立同名导入均保留。
   * 单次预览 ID 重送复用同一 Promise/回执，不能因 UI 回调重复而多建副本；内容来自私有冻结 candidate。
   */
  commitReviewedImport(reviewId: string): Promise<LayoutProfile | null> {
    const pending: Promise<LayoutProfile | null> | undefined = this.importCommits.get(reviewId)
    if (pending !== undefined) return pending
    const frozen: LayoutProfile | undefined = this.importReviews.get(reviewId)
    if (frozen === undefined) return Promise.reject<LayoutProfile | null>(new Error('StaleCandidate:导入预览已失效，请重新预览'))
    this.importInFlight.add(reviewId)
    const operation: Promise<LayoutProfile | null> = this.runMutation<LayoutProfile | null>(async (): Promise<LayoutProfile | null> => {
      const candidate = buildLayoutCandidate(frozen)
      if (candidate.profile === null) throw new Error(candidate.reason)
      const profile: LayoutProfile = candidate.profile
      profile.name = this.uniqueProfileName(profile.name)
      profile.profileId = this.newProfileIdentity()
      profile.profileRevision = 1
      profile.isPreset = false
      this.captureEditorTransaction()
      this.profiles.push(profile)
      this.activeName = profile.name
      this.activeChosenAutomatically = false
      await this.save()
      return cloneLayout(profile)
    })
    this.importCommits.set(reviewId, operation)
    operation.then((): void => { this.importInFlight.delete(reviewId) },
      (): void => { this.importInFlight.delete(reviewId); this.importCommits.delete(reviewId) })
    return operation
  }

  /**
   * 从文件导入
   */
  async importFromFile(filePath: string, acceptCompatibilityWarnings: boolean = false): Promise<LayoutProfile | null> {
    try {
      return await this.importFromJson(this.readImportText(filePath),acceptCompatibilityWarnings)
    } catch (e) {
      return null
    }
  }

  // ==================== 导入前分析（设备类型 / 合法性 / 旧版检测） ====================

  /** 预览和保存共用有限读取。读取失败也关闭fd，超过限额不截断成另一份看似有效的JSON。 */
  private readImportText(filePath: string): string {
    let file: fileIo.File | null = null
    try {
      file = fileIo.openSync(filePath,fileIo.OpenMode.READ_ONLY)
      const buf = new ArrayBuffer(256*1024+1)
      const len: number = fileIo.readSync(file.fd,buf)
      if (len>256*1024) throw new Error('布局文件超过256KiB')
      const decoder = util.TextDecoder.create('utf-8')
      return decoder.decodeToString(new Uint8Array(buf,0,len))
    } catch (error) { throw error as Error }
    finally { if (file !== null) { try { fileIo.closeSync(file.fd) } catch (_) { /* 内容读取失败仍优先保留原错误。 */ } } }
  }

  /** 外部坐标按当前横向显示视口转换；无显示能力时使用明确的兼容参考尺寸。 */
  private importViewport(): number[] {
    try {
      const info = display.getDefaultDisplaySync()
      if (info.densityPixels>0) return [Math.max(info.width,info.height)/info.densityPixels,
        Math.min(info.width,info.height)/info.densityPixels]
    } catch (_) { /* 无显示环境的纯数据导入使用既有720×360参考画幅。 */ }
    return [720,360]
  }

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
    if (utf8ByteLength(json) > MAX_LAYOUT_PROFILE_BYTES) {
      return { ok: false, format: 'invalid', reason: 'BudgetExceeded:布局原文件超过256KiB', name: '',
        sourceDevice: 'unknown', currentDevice: current, deviceMismatch: false, sourceVersion: 0, legacy: false, controlCount: 0 }
    }
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
    const format: string = externalLayoutFormat(obj)
    if (format.length > 0) {
      const viewport: number[] = this.importViewport()
      const review = analyzeExternalLayout(json,format+' 布局',viewport[0],viewport[1])
      const analysis: ImportAnalysis = {
        ok: review.profile!==null, format: format, reason: review.reason, name: format+' 布局',
        sourceDevice: 'unknown', currentDevice: current, deviceMismatch: false,
        sourceVersion: 0, legacy: false, controlCount: review.profile?.controls.length ?? 0,
        warnings: review.warnings, skippedControls: review.skipped
      }
      return this.freezeImportCandidate(analysis, review.profile, json, viewport)
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
    const analysis: ImportAnalysis = {
      ok: true, format: 'amcl', reason: '', name: migrated.name,
      sourceDevice: srcDevice, currentDevice: current, deviceMismatch: mismatch,
      // v3与显式政策v4均为当前合法格式；只对真正旧格式提示迁移，不称v4“旧版”。
      sourceVersion: srcVer, legacy: srcVer < LAYOUT_PROFILE_VERSION,
      controlCount: migrated.controls.length
    }
    return this.freezeImportCandidate(analysis, migrated, json, this.importViewport())
  }

  /** 预览即完成迁移、系统补齐和最终预算；回执同时记录原文摘要、版本与转换视口。 */
  private freezeImportCandidate(analysis: ImportAnalysis, source: LayoutProfile | null,
    original: string, viewport: number[]): ImportAnalysis {
    if (source === null) return analysis
    const working: LayoutProfile = cloneLayout(source)
    working.profileId = undefined
    working.profileRevision = undefined
    working.isPreset = false
    this.ensureHotbarSelector(working)
    const candidate = buildLayoutCandidate(working)
    if (candidate.profile === null) { analysis.ok = false; analysis.reason = candidate.reason; return analysis }
    // 当前32个有效操作保留幂等回执；已完成旧操作随新独立预览过期，只能Stale不能重新新增。
    // 在途提交不可淘汰，避免排队的同一次请求失去其原回执。
    if (this.importReviews.size >= 32) {
      for (const id of this.importReviews.keys()) {
        if (!this.importInFlight.has(id)) { this.importReviews.delete(id); this.importCommits.delete(id); break }
      }
    }
    if (this.importReviews.size >= 32) { analysis.ok = false; analysis.reason = 'StaleCandidate:待处理预览过多'; return analysis }
    const id: string = this.newImportReviewIdentity()
    this.importReviews.set(id, cloneLayout(candidate.profile))
    analysis.reviewId = id
    analysis.reviewedJson = original
    analysis.sourceDigest = layoutTextDigest(original)
    analysis.converterVersion = 1
    analysis.viewportWidth = viewport[0]
    analysis.viewportHeight = viewport[1]
    analysis.controlCount = candidate.profile.controls.length
    return analysis
  }

  /** 读文件并分析（不落盘）。读失败返回 ok=false。 */
  async analyzeImportFile(filePath: string): Promise<ImportAnalysis> {
    try {
      const json: string = this.readImportText(filePath)
      const analysis: ImportAnalysis = this.analyzeImport(json)
      if (analysis.ok) analysis.reviewedJson=json
      return analysis
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
  /** 单次操作的冻结候选身份；确认传此 ID，不能重新解析文件或按新窗口重新转换。 */
  reviewId?: string
  sourceDigest?: string
  converterVersion?: number
  viewportWidth?: number
  viewportHeight?: number
  /** 只保存本次已读内容，确认后用它导入，避免预览和提交之间路径指向另一份文件。 */
  reviewedJson?: string
  warnings?: string[]
  skippedControls?: number
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
  /** 真正旧版需迁移；当前v3和显式来源v4均为false，不把新格式当旧版。 */
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
