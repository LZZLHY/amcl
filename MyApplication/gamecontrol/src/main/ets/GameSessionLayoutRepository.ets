/**
 * 冻结布局会话的业务仓库。目录与方案载荷分离，目录列举不读全部控件；文件/摘要由 entry 适配器负责。
 * 只保存相对冻结基线的最新净修改，重复编辑同一实体替换旧结果，不积累无界操作历史。
 */
import { LayoutProfile, cloneLayout, utf8ByteLength } from './ControlLayout'
import { buildLayoutCandidate } from './LayoutCandidate'
import { MAX_LAYOUT_LIBRARY_BYTES, MAX_LAYOUT_XML_BYTES } from './LayoutBudget'

export interface SessionLayoutCatalogEntry {
  profileId: string
  profileRevision: number
  name: string
  isPreset: boolean
  targetDevice: 'phone' | 'tablet' | 'foldable' | 'any'
  bytes: number
  digest: string
  payloadId: string
}

export interface SessionLayoutChange {
  profileId: string
  baseDigest: string
  baseRevision: number
  proposed: LayoutProfile | null
}

export interface SessionLayoutCommit {
  changes: SessionLayoutChange[]
  activeProfileId: string
}

/** 入口只暴露白名单 payload ID；实现须验证冻结摘要、普通文件/边界、并等待原子持久化后返回。 */
export interface SessionLayoutTransport {
  readProfile(entry: SessionLayoutCatalogEntry): LayoutProfile
  commit(commit: SessionLayoutCommit): Promise<void>
}

export class GameSessionLayoutRepository {
  private catalog: SessionLayoutCatalogEntry[]
  private active: string
  private transport: SessionLayoutTransport
  private originals: Map<string, LayoutProfile> = new Map<string, LayoutProfile>()
  private catalogById: Map<string, SessionLayoutCatalogEntry> = new Map<string, SessionLayoutCatalogEntry>()
  private grandfatherSource: boolean
  private sourceGrowthCredit: number

  constructor(catalog: SessionLayoutCatalogEntry[], active: string, transport: SessionLayoutTransport, grandfatherSource: boolean = false,
    sourceGrowthCredit: number = 0) {
    const ids: Set<string> = new Set<string>()
    const names: Set<string> = new Set<string>()
    for (const entry of catalog) {
      if (ids.has(entry.profileId) || names.has(entry.name)) throw new Error('Invalid duplicate frozen layout identity')
      ids.add(entry.profileId); names.add(entry.name)
    }
    if (!ids.has(active)) throw new Error('TargetMissing:冻结活动方案不存在')
    this.catalog = catalog.map((entry: SessionLayoutCatalogEntry): SessionLayoutCatalogEntry => ({
      profileId: entry.profileId, profileRevision: entry.profileRevision, name: entry.name, isPreset: entry.isPreset,
      targetDevice: entry.targetDevice, bytes: entry.bytes, digest: entry.digest, payloadId: entry.payloadId }))
    for (const entry of this.catalog) this.catalogById.set(entry.profileId, entry)
    this.active = active
    this.transport = transport
    this.grandfatherSource = grandfatherSource
    if (!Number.isSafeInteger(sourceGrowthCredit) || sourceGrowthCredit < 0 || sourceGrowthCredit > MAX_LAYOUT_XML_BYTES) throw new Error('Invalid source semantic credit')
    this.sourceGrowthCredit = sourceGrowthCredit
  }

  /** 占位对象只承载目录字段，Store 使用 unloaded 集合保证它不会作为运行时方案或编辑结果。 */
  initialProfiles(): LayoutProfile[] {
    return this.catalog.map((entry: SessionLayoutCatalogEntry): LayoutProfile => ({ profileId: entry.profileId,
      profileRevision: entry.profileRevision, name: entry.name, isPreset: entry.isPreset,
      targetDevice: entry.targetDevice, globalScale: 1, controls: [] }))
  }

  activeName(): string { return this.catalog.find((entry: SessionLayoutCatalogEntry): boolean => entry.profileId === this.active)!.name }

  /** 已确认内容仍等于冻结实体时允许Store退休读取缓存；修改结果与新增实体必须保留到提交/回传。 */
  isFrozenDefinition(profile: LayoutProfile): boolean {
    const entry: SessionLayoutCatalogEntry | undefined = this.catalogById.get(profile.profileId ?? '')
    return entry !== undefined && entry.profileRevision === profile.profileRevision && entry.name === profile.name
  }

  /** 每次外部读取给独立副本；首次按冻结载荷读取，不能向后来 parent 的权威库查询。 */
  readProfile(id: string): LayoutProfile {
    const cached: LayoutProfile | undefined = this.originals.get(id)
    if (cached !== undefined) { this.originals.delete(id); this.originals.set(id, cached); return cloneLayout(cached) }
    const entry: SessionLayoutCatalogEntry | undefined = this.catalogById.get(id)
    if (entry === undefined) throw new Error('TargetMissing:冻结方案不存在')
    const profile: LayoutProfile = this.transport.readProfile(entry)
    if (profile.profileId !== entry.profileId || profile.profileRevision !== entry.profileRevision || profile.name !== entry.name) {
      throw new Error('StaleCandidate:冻结方案身份漂移')
    }
    // 两页+活动方案的读取缓存有界，连续浏览完整大库不会积累所有规范化定义。
    if (this.originals.size >= 65) this.originals.delete(this.originals.keys().next().value)
    this.originals.set(id, cloneLayout(profile))
    return cloneLayout(profile)
  }

  /**
   * Store 的完整目录用于证明新增/删除/活动引用；未读方案没有内容修改，因此无须为保存读取全库。
   * 修改的单方案走同一最终 candidate 校验；冻结旧兼容方案只读保留，不能因新规则而删去。
   */
  async commit(profiles: LayoutProfile[], unloaded: Set<string>, activeName: string): Promise<void> {
    const current: Map<string, LayoutProfile> = new Map<string, LayoutProfile>()
    const names: Set<string> = new Set<string>()
    for (const profile of profiles) {
      if (profile.profileId === undefined || current.has(profile.profileId) || names.has(profile.name)) throw new Error('Invalid session layout identity')
      current.set(profile.profileId, profile); names.add(profile.name)
    }
    const selected: LayoutProfile | undefined = profiles.find((profile: LayoutProfile): boolean => profile.name === activeName)
    if (selected === undefined || selected.profileId === undefined) throw new Error('TargetMissing:活动方案不存在')
    const changes: SessionLayoutChange[] = []
    for (const entry of this.catalog) {
      const profile: LayoutProfile | undefined = current.get(entry.profileId)
      if (profile === undefined) {
        if (entry.isPreset) throw new Error('Cannot delete frozen preset')
        changes.push({ profileId: entry.profileId, baseDigest: entry.digest, baseRevision: entry.profileRevision, proposed: null })
        continue
      }
      current.delete(entry.profileId)
      if (unloaded.has(entry.profileId) && profile.name === entry.name && profile.profileRevision === entry.profileRevision) continue
      const original: LayoutProfile = this.readProfile(entry.profileId)
      let proposed: LayoutProfile = profile
      if (unloaded.has(entry.profileId)) { proposed = cloneLayout(original); proposed.name = profile.name; proposed.profileRevision = profile.profileRevision }
      if (JSON.stringify(original) === JSON.stringify(proposed)) continue
      if (entry.isPreset) throw new Error('Cannot edit frozen preset')
      const checked = buildLayoutCandidate(proposed)
      if (checked.profile === null) throw new Error(checked.reason)
      changes.push({ profileId: entry.profileId, baseDigest: entry.digest, baseRevision: entry.profileRevision, proposed: checked.profile })
    }
    for (const profile of current.values()) {
      if (profile.isPreset) throw new Error('Cannot add game preset')
      const checked = buildLayoutCandidate(profile)
      if (checked.profile === null) throw new Error(checked.reason)
      changes.push({ profileId: profile.profileId!, baseDigest: '', baseRevision: 0, proposed: checked.profile })
    }
    // catalog记录冻结载荷真实字节，未加载占位对象不能被当成零成本；净修改替换/删除按完整库计算。
    const baseBytes: number = this.catalog.reduce((sum: number, entry: SessionLayoutCatalogEntry): number => sum + entry.bytes, 0)
    let bytes: number = baseBytes
    let metadataDelta: number = 0
    for (const change of changes) {
      const old: SessionLayoutCatalogEntry | undefined = this.catalog.find((entry: SessionLayoutCatalogEntry): boolean => entry.profileId === change.profileId)
      bytes -= old?.bytes ?? 0
      if (change.proposed !== null) {
        bytes += utf8ByteLength(JSON.stringify(change.proposed))
        if (old !== undefined) metadataDelta += Math.max(0, (change.proposed.profileRevision ?? 1).toString().length - old.profileRevision.toString().length)
      }
    }
    if (this.grandfatherSource) {
      // source的raw bytes不等于规范化成本；只读本次涉及的base，系统/default/identity补齐不作为用户增长。
      let contentDelta: number = 0
      const userBytes = (profile: LayoutProfile): number => {
        const copy: LayoutProfile = cloneLayout(profile); copy.profileId = undefined; copy.profileRevision = undefined
        return utf8ByteLength(JSON.stringify(copy))
      }
      for (const change of changes) {
        if (this.catalog.some((entry: SessionLayoutCatalogEntry): boolean => entry.profileId === change.profileId)) contentDelta -= userBytes(this.readProfile(change.profileId))
        if (change.proposed !== null) contentDelta += userBytes(change.proposed)
      }
      if (contentDelta > this.sourceGrowthCredit) throw new Error('BudgetExceeded:源形态历史大库只允许不增加用户内容压力的修改，请先缩减或导出')
    } else if (bytes > MAX_LAYOUT_LIBRARY_BYTES || bytes > Math.max(MAX_LAYOUT_XML_BYTES, baseBytes + metadataDelta)) {
      throw new Error('BudgetExceeded:本局完整库预算不允许该内容增长，请缩减或导出')
    }
    await this.transport.commit({ changes: changes, activeProfileId: selected.profileId })
  }
}

let installedRepository: GameSessionLayoutRepository | null = null
/** 仅在经授权 consume 后、LayoutStore 初次初始化之前安装，不允许中途替换冻结会话。 */
export function installGameSessionLayoutRepository(repository: GameSessionLayoutRepository): void {
  if (installedRepository !== null) throw new Error('Game layout repository already installed')
  installedRepository = repository
}
export function getGameSessionLayoutRepository(): GameSessionLayoutRepository | null { return installedRepository }
