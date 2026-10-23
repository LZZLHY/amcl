/**
 * 冻结完整布局目录的 V2 文件传输。启动 ticket 只携带 root 身份；目录分页，方案按256KiB块懒读取。
 * 游戏提交替换本局最新净修改集，父侧完成持久化与外部回执后才退休 pending；失败保留上一版本与原文。
 * 账号、签名及其它偏好不进入该目录。所有路径由 UUID 和内部数字 ID 生成，绝不接受传入路径。
 */
import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import testNapi from 'libentry.so'
import { LaunchPreferenceSnapshot, ProcessPreferences, ensureDirSync, writeEvidenceTextAtomic,
  evidenceTextDigest, evidenceFileDigestSync } from 'commons'
import { LayoutProfile, cloneLayout, validateAndNormalizeLayout, utf8ByteLength, getLayoutStore,
  SessionLayoutCatalogEntry, SessionLayoutChange, SessionLayoutCommit, SessionLayoutTransport,
  GameSessionLayoutRepository, installGameSessionLayoutRepository, MAX_LAYOUT_LIBRARY_BYTES,
  LAYOUT_TRANSFER_CHUNK_BYTES, LayoutLaunchSource, normalizeLayoutSource } from 'gamecontrol'

const CHUNK_BYTES: number = LAYOUT_TRANSFER_CHUNK_BYTES
const PAGE_ITEMS: number = 32
const ROOT_BYTES: number = 16 * 1024
/** 现XML16MiB之外的迁移库经owner目录后端恢复；V2按有界32MiB窗口分块，不向XML单值写超限数据。 */
const LIBRARY_BYTES: number = MAX_LAYOUT_LIBRARY_BYTES
const MAX_PAGES: number = 4096
/** 源仓目录按原SDK字节/合法元素最小结构推导，只约束有界读，不以固定4096页拒旧raw。 */
const SOURCE_MAX_PAGES: number = Math.ceil((32 * 1024 * 1024 / 26) / PAGE_ITEMS)

interface FrozenRoot {
  schema: number
  snapshotId: string
  activityId: number
  parentPid: number
  createdAt: number
  sourceLibraryRevision: string
  activeProfileId: string
  catalogPageCount: number
  catalogDigest: string
  profileCount: number
  totalBytes: number
  encoding?: string
  sourceRawBytes?: number
  sourceRawDigest?: string
  sourceGrowthCredit?: number
}
interface CatalogPage { entries: SessionLayoutCatalogEntry[]; nextDigest: string }
interface PayloadDescriptor { bytes: number; digest: string; chunkDigests: string[] }
interface ChangePage { changes: DiskChange[]; nextDigest: string }
interface DiskChange { profileId: string; baseDigest: string; baseRevision: number; payloadId: string }
interface GameLease { schema: number; snapshotId: string; activityId: number; parentPid: number; gamePid: number; rootDigest: string }
interface V2Pending extends GameLease {
  revision: number
  submittedAt: number
  pageCount: number
  changesDigest: string
  activeProfileId: string
}
export interface V2LayoutImportReport { imported: number; pending: number; deferred: boolean; conflicts: string[] }

/** 对象白名单和整数验证同时拒绝未知版本与多余授权字段，不能按形状猜协议。 */
function onlyKeys(value: Object, keys: string[]): void {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some((key: string): boolean => !keys.includes(key))) {
    throw new Error('Invalid V2 layout object fields')
  }
}
function positive(value: number): boolean { return Number.isSafeInteger(value) && value > 0 }
function uuid(value: string): boolean { return typeof value === 'string' && new RegExp('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').test(value) }
function digest(value: string): boolean { return typeof value === 'string' && new RegExp('^[0-9a-f]{64}$').test(value) }
function identity(value: string): boolean { return typeof value === 'string' && new RegExp('^[a-zA-Z0-9_-]{1,64}$').test(value) }
function directory(context: common.Context, id: string): string {
  if (!uuid(id)) throw new Error('Invalid V2 layout session identity')
  const root: string = context.filesDir + '/game-layout-v2'
  const dir: string = root + '/' + id
  // lstat逐级验证本域所有父目录，符号链接不是目录，不能通过合法UUID跳出应用私有根。
  for (const parent of [context.filesDir, root, dir]) {
    if (fs.accessSync(parent) && !fs.lstatSync(parent).isDirectory()) throw new Error('V2 layout directory is linked or not an ordinary directory')
  }
  return dir
}
/** lstat 排除链接；仅读取预先有界的普通文件，字节/摘要复核不把短读当成功。 */
function readText(path: string, limit: number): string {
  const stat = fs.lstatSync(path)
  if (!stat.isFile() || stat.size <= 0 || stat.size > limit) throw new Error('V2 layout file is not a bounded ordinary file')
  const text: string = fs.readTextSync(path)
  if (utf8ByteLength(text) !== stat.size || utf8ByteLength(text) > limit) throw new Error('V2 layout short read or size drift')
  return text
}
function readChecked(path: string, expected: string, limit: number): string {
  const text: string = readText(path, limit)
  if (!digest(expected) || evidenceTextDigest(text) !== expected) throw new Error('V2 layout chunk digest mismatch')
  return text
}
function writeText(path: string, value: string, limit: number): string {
  if (utf8ByteLength(value) > limit) throw new Error('BudgetExceeded:V2文件超过单块预算')
  writeEvidenceTextAtomic(path, value)
  const expected: string = evidenceTextDigest(value)
  if (evidenceFileDigestSync(path) !== expected) throw new Error('V2 layout persisted digest mismatch')
  return expected
}
/** 按Unicode完整字符分块，每块UTF-8不超过256KiB，不切开代理对或把字符数当字节。 */
function chunks(text: string): string[] {
  const result: string[] = []
  let start: number = 0
  let bytes: number = 0
  for (let index: number = 0; index < text.length; index++) {
    let length: number = 1
    const code: number = text.charCodeAt(index)
    if (code >= 0xD800 && code <= 0xDBFF && index + 1 < text.length) length = 2
    const amount: number = utf8ByteLength(text.substring(index, index + length))
    if (bytes + amount > CHUNK_BYTES) { result.push(text.substring(start, index)); start = index; bytes = 0 }
    bytes += amount
    index += length - 1
  }
  result.push(text.substring(start))
  return result
}

/** payloadId 只允许内部数字前缀；单方案可跨多个块，descriptor 自身也有界。 */
function payloadPath(dir: string, id: string): string {
  if (!new RegExp('^(base_[0-9]+|change_[0-9]+_[0-9]+)$').test(id)) throw new Error('Invalid V2 payload reference')
  return dir + '/' + id
}
function writePayload(dir: string, id: string, profile: LayoutProfile): PayloadDescriptor {
  return writeRawPayload(dir, id, JSON.stringify(profile))
}
function writeRawPayload(dir: string, id: string, value: string): PayloadDescriptor {
  if (utf8ByteLength(value) > LIBRARY_BYTES) throw new Error('BudgetExceeded:单方案超出现后端容量')
  const path: string = payloadPath(dir, id)
  const parts: string[] = chunks(value)
  const hashes: string[] = []
  for (let index: number = 0; index < parts.length; index++) hashes.push(writeText(path + '_' + index.toString() + '.chunk', parts[index], CHUNK_BYTES))
  const descriptor: PayloadDescriptor = { bytes: utf8ByteLength(value), digest: evidenceTextDigest(value), chunkDigests: hashes }
  writeText(path + '.json', JSON.stringify(descriptor), ROOT_BYTES)
  return descriptor
}
function readRawPayload(dir: string, id: string, expectedDigest: string = '', expectedBytes: number = 0): string {
  if (new RegExp('^packed_[0-9]+_[0-9]+$').test(id)) {
    const parts: string[] = id.split('_')
    const page = JSON.parse(readText(dir + '/source_pack_' + parts[1] + '.json', CHUNK_BYTES)) as Record<string, string[]>
    onlyKeys(page, ['rawProfiles'])
    const slot: number = Number(parts[2])
    if (!Array.isArray(page['rawProfiles']) || page['rawProfiles'].length > 1024 || !Number.isSafeInteger(slot) || slot < 0) throw new Error('Invalid packed source reference')
    const raw: string = page['rawProfiles'][slot]
    if (typeof raw !== 'string' || utf8ByteLength(raw) !== expectedBytes || evidenceTextDigest(raw) !== expectedDigest) throw new Error('V2 packed source digest mismatch')
    return raw
  }
  const path: string = payloadPath(dir, id)
  const descriptor = JSON.parse(readText(path + '.json', ROOT_BYTES)) as PayloadDescriptor
  onlyKeys(descriptor, ['bytes', 'digest', 'chunkDigests'])
  if (!positive(descriptor.bytes) || descriptor.bytes > LIBRARY_BYTES || !digest(descriptor.digest)
      || !Array.isArray(descriptor.chunkDigests) || descriptor.chunkDigests.length < 1
      || descriptor.chunkDigests.length > LIBRARY_BYTES / CHUNK_BYTES || (expectedDigest.length > 0 && descriptor.digest !== expectedDigest)
      || (expectedBytes > 0 && descriptor.bytes !== expectedBytes)) throw new Error('Invalid V2 layout payload descriptor')
  let text: string = ''
  for (let index: number = 0; index < descriptor.chunkDigests.length; index++) {
    text += readChecked(path + '_' + index.toString() + '.chunk', descriptor.chunkDigests[index], CHUNK_BYTES)
    if (utf8ByteLength(text) > descriptor.bytes) throw new Error('V2 layout payload byte overflow')
  }
  if (utf8ByteLength(text) !== descriptor.bytes || evidenceTextDigest(text) !== descriptor.digest) throw new Error('V2 layout payload digest mismatch')
  return text
}
function readPayload(dir: string, id: string, expectedDigest: string = '', expectedBytes: number = 0): LayoutProfile {
  const profile: LayoutProfile | null = validateAndNormalizeLayout(JSON.parse(readRawPayload(dir, id, expectedDigest, expectedBytes)) as LayoutProfile)
  if (profile === null) throw new Error('Invalid V2 layout semantic payload')
  return profile
}
function readRoot(context: common.Context, id: string): FrozenRoot {
  const root = JSON.parse(readText(directory(context, id) + '/root.json', ROOT_BYTES)) as FrozenRoot
  onlyKeys(root, ['schema', 'snapshotId', 'activityId', 'parentPid', 'createdAt', 'sourceLibraryRevision', 'activeProfileId',
    'catalogPageCount', 'catalogDigest', 'profileCount', 'totalBytes', 'encoding', 'sourceRawBytes', 'sourceRawDigest', 'sourceGrowthCredit'])
  const source: boolean = root.encoding === 'legacy-source'
  if (root.schema !== 2 || root.snapshotId !== id || !positive(root.activityId) || !positive(root.parentPid)
      || !positive(root.createdAt) || !digest(root.sourceLibraryRevision) || !identity(root.activeProfileId)
      || (root.encoding !== undefined && root.encoding !== 'canonical' && !source)
      || !positive(root.catalogPageCount) || root.catalogPageCount > (source ? SOURCE_MAX_PAGES : MAX_PAGES) || !digest(root.catalogDigest)
      || !positive(root.profileCount) || root.profileCount > (source ? SOURCE_MAX_PAGES : MAX_PAGES) * PAGE_ITEMS || !positive(root.totalBytes)
      || root.catalogPageCount !== Math.ceil(root.profileCount / PAGE_ITEMS)
      || (source ? !positive(root.sourceRawBytes!) || root.sourceRawBytes! > 16 * 1024 * 1024 || !digest(root.sourceRawDigest!)
          || !Number.isSafeInteger(root.sourceGrowthCredit) || root.sourceGrowthCredit! < 0 || root.sourceGrowthCredit! > 16 * 1024 * 1024
        : root.totalBytes > LIBRARY_BYTES)) throw new Error('Invalid V2 frozen root')
  return root
}
function readCatalog(context: common.Context, root: FrozenRoot): SessionLayoutCatalogEntry[] {
  const result: SessionLayoutCatalogEntry[] = []
  const ids: Set<string> = new Set<string>()
  const names: Set<string> = new Set<string>()
  const payloads: Set<string> = new Set<string>()
  let expected: string = root.catalogDigest
  for (let index: number = 0; index < root.catalogPageCount; index++) {
    const page = JSON.parse(readChecked(directory(context, root.snapshotId) + '/catalog_' + index.toString() + '.json', expected, CHUNK_BYTES)) as CatalogPage
    onlyKeys(page, ['entries', 'nextDigest'])
    if (!Array.isArray(page.entries) || page.entries.length < 1 || page.entries.length > PAGE_ITEMS) throw new Error('Invalid V2 catalog page')
    for (const entry of page.entries) {
      onlyKeys(entry, ['profileId', 'profileRevision', 'name', 'isPreset', 'targetDevice', 'bytes', 'digest', 'payloadId'])
      if (!identity(entry.profileId) || !positive(entry.profileRevision) || typeof entry.name !== 'string'
          || utf8ByteLength(entry.name) > 256 || typeof entry.isPreset !== 'boolean'
          || !['phone', 'tablet', 'foldable', 'any'].includes(entry.targetDevice) || !positive(entry.bytes)
          || entry.bytes > LIBRARY_BYTES || !digest(entry.digest)
          || !(new RegExp('^base_[0-9]+$').test(entry.payloadId) || root.encoding === 'legacy-source' && new RegExp('^packed_[0-9]+_[0-9]+$').test(entry.payloadId))) {
        throw new Error('Invalid V2 catalog entry')
      }
      if (ids.has(entry.profileId) || names.has(entry.name) || payloads.has(entry.payloadId)) throw new Error('V2 catalog duplicate identity/name/payload reference')
      const parts: string[] = entry.payloadId.split('_')
      const first: number = Number(parts[1])
      if (!Number.isSafeInteger(first) || first < 0 || first >= root.profileCount || parts[1] !== first.toString()
          || parts[0] === 'packed' && (!Number.isSafeInteger(Number(parts[2])) || Number(parts[2]) < 0
            || Number(parts[2]) >= 1024 || parts[2] !== Number(parts[2]).toString())) throw new Error('Invalid bounded frozen payload ID')
      ids.add(entry.profileId); names.add(entry.name); payloads.add(entry.payloadId)
      result.push(entry)
    }
    if (index + 1 < root.catalogPageCount ? !digest(page.nextDigest) : page.nextDigest !== '') throw new Error('Invalid V2 catalog digest chain termination')
    expected = page.nextDigest
  }
  if (expected !== '' || result.length !== root.profileCount || result.reduce((sum: number, entry: SessionLayoutCatalogEntry): number => sum + entry.bytes, 0) !== root.totalBytes) {
    throw new Error('V2 catalog incomplete or byte mismatch')
  }
  return result
}

/** 本局适配器固定 root，所有 payload读取均指向同一已完成的冻结目录。 */
class V2SessionTransport implements SessionLayoutTransport {
  private context: common.Context
  private lease: GameLease
  private revision: number = 0
  /** 尝试代次先占用且永不复用，失败后不能覆盖上一已确认journal仍引用的文件。 */
  private attempt: number = 0
  private source: boolean
  constructor(context: common.Context, lease: GameLease, source: boolean = false) { this.context = context; this.lease = lease; this.source = source }
  readProfile(entry: SessionLayoutCatalogEntry): LayoutProfile {
    if (this.source) return normalizeLayoutSource(readRawPayload(directory(this.context, this.lease.snapshotId), entry.payloadId, entry.digest, entry.bytes),
      entry.profileId, entry.profileRevision, entry.name)
    return readPayload(directory(this.context, this.lease.snapshotId), entry.payloadId, entry.digest, entry.bytes)
  }
  async commit(commit: SessionLayoutCommit): Promise<void> {
    if (!ProcessPreferences.isGameProcess() || testNapi.desktopProcessId() !== this.lease.gamePid) throw new Error('V2 layout process identity mismatch')
    const dir: string = directory(this.context, this.lease.snapshotId)
    this.attempt++
    const revision: number = this.attempt
    const changes: DiskChange[] = []
    for (let index: number = 0; index < commit.changes.length; index++) {
      const change: SessionLayoutChange = commit.changes[index]
      const payloadId: string = change.proposed === null ? '' : 'change_' + revision.toString() + '_' + index.toString()
      if (change.proposed !== null) writePayload(dir, payloadId, change.proposed)
      changes.push({ profileId: change.profileId, baseDigest: change.baseDigest, baseRevision: change.baseRevision, payloadId: payloadId })
    }
    const count: number = Math.max(1, Math.ceil(changes.length / PAGE_ITEMS))
    if (count > (this.source ? SOURCE_MAX_PAGES : MAX_PAGES)) throw new Error('BudgetExceeded:V2修改集过大')
    let next: string = ''
    for (let index: number = count - 1; index >= 0; index--) {
      next = writeText(dir + '/changes_' + revision.toString() + '_' + index.toString() + '.json',
        JSON.stringify({ changes: changes.slice(index * PAGE_ITEMS, (index + 1) * PAGE_ITEMS), nextDigest: next } as ChangePage), CHUNK_BYTES)
    }
    const pending: V2Pending = { schema: 2, snapshotId: this.lease.snapshotId, activityId: this.lease.activityId,
      parentPid: this.lease.parentPid, gamePid: this.lease.gamePid, rootDigest: this.lease.rootDigest,
      revision: revision, submittedAt: Date.now(), pageCount: count, changesDigest: next, activeProfileId: commit.activeProfileId }
    // 只有完整净修改及其载荷 fsync/摘要成功后原子替换完成记录；失败保留上一笔已确认 pending。
    const previous: string | undefined = fs.accessSync(dir + '/pending.json') ? readText(dir + '/pending.json', ROOT_BYTES) : undefined
    try {
      writeText(dir + '/pending.json', JSON.stringify(pending), ROOT_BYTES)
    } catch (error) {
      // rename后目录fsync失败可能已经发布新pending；恢复前一完整记录，失败显式封锁而不继续覆盖载荷。
      try {
        if (previous !== undefined) writeText(dir + '/pending.json', previous, ROOT_BYTES)
        else if (fs.accessSync(dir + '/pending.json')) {
          fs.unlinkSync(dir + '/pending.json')
          const parent: fs.File = fs.openSync(dir, fs.OpenMode.READ_ONLY)
          try { fs.fsyncSync(parent.fd) } finally { fs.closeSync(parent) }
        }
      } catch (_) { throw new Error('RollbackFailed:布局完成记录恢复失败，已保留全部载荷，请重启并恢复') }
      throw error as Error
    }
    this.revision = revision
    // 新pending确认后，旧修改页及载荷已无当前引用；owner因游戏锁尚未消费，清理只碰本目录普通白名单文件。
    try {
      for (const name of fs.listFileSync(dir)) {
        const match: RegExpMatchArray | null = name.match(new RegExp('^(?:changes|change)_([0-9]+)_.*(?:\\.json|\\.chunk)$'))
        if (match !== null && Number(match[1]) < revision && fs.lstatSync(dir + '/' + name).isFile()) fs.unlinkSync(dir + '/' + name)
      }
    } catch (_) { /* 清理失败保留材料；下一笔成功重试，不改变本次已确认结果。 */ }
  }
}

export class GameLayoutTransportV2 {
  /** owner 持久库已在 mutation 队列捕获；先写载荷/目录，再原子发布 root，ticket最后发布。 */
  static prepare(context: common.Context, id: string, activityId: number, parentPid: number, snapshot: LaunchPreferenceSnapshot,
    source: LayoutLaunchSource | null = null): string {
    if (ProcessPreferences.isGameProcess() || parentPid !== testNapi.desktopProcessId() || !positive(activityId)) throw new Error('Cannot prepare V2 layout session')
    if (source !== null) return GameLayoutTransportV2.prepareSource(context, id, activityId, parentPid, source)
    const raw: string = snapshot.values['profiles'] as string
    if (typeof raw !== 'string' || utf8ByteLength(raw) > LIBRARY_BYTES) throw new Error('BudgetExceeded:库超过现后端硬边界')
    const profiles = JSON.parse(raw) as LayoutProfile[]
    if (!Array.isArray(profiles) || profiles.length < 1) throw new Error('Invalid frozen layout library')
    const dir: string = directory(context, id)
    ensureDirSync(dir)
    const entries: SessionLayoutCatalogEntry[] = []
    let total: number = 0
    for (let index: number = 0; index < profiles.length; index++) {
      const profile: LayoutProfile | null = validateAndNormalizeLayout(profiles[index])
      if (profile === null || profile.profileId === undefined || profile.profileRevision === undefined) throw new Error('Invalid frozen profile identity')
      const payloadId: string = 'base_' + index.toString()
      const descriptor: PayloadDescriptor = writePayload(dir, payloadId, profile)
      total += descriptor.bytes
      if (total > LIBRARY_BYTES) throw new Error('BudgetExceeded:规范化库超过现后端边界')
      entries.push({ profileId: profile.profileId, profileRevision: profile.profileRevision, name: profile.name,
        isPreset: profile.isPreset === true, targetDevice: profile.targetDevice ?? 'any', bytes: descriptor.bytes,
        digest: descriptor.digest, payloadId: payloadId })
    }
    const active: SessionLayoutCatalogEntry | undefined = entries.find((entry: SessionLayoutCatalogEntry): boolean => entry.name === snapshot.values['active_profile'])
    if (active === undefined) throw new Error('TargetMissing:冻结活动方案不存在')
    const count: number = Math.ceil(entries.length / PAGE_ITEMS)
    if (count > MAX_PAGES) throw new Error('BudgetExceeded:目录超过有界页数')
    let next: string = ''
    for (let index: number = count - 1; index >= 0; index--) {
      next = writeText(dir + '/catalog_' + index.toString() + '.json',
        JSON.stringify({ entries: entries.slice(index * PAGE_ITEMS, (index + 1) * PAGE_ITEMS), nextDigest: next } as CatalogPage), CHUNK_BYTES)
    }
    const root: FrozenRoot = { schema: 2, snapshotId: id, activityId: activityId, parentPid: parentPid,
      createdAt: Date.now(), sourceLibraryRevision: evidenceTextDigest(raw), activeProfileId: active.profileId,
      catalogPageCount: count, catalogDigest: next, profileCount: entries.length, totalBytes: total }
    return writeText(dir + '/root.json', JSON.stringify(root), ROOT_BYTES)
  }

  /** 源方案按批有界冻结raw；只在一次读取时规范化单方案，避免合法旧库膨胀成全库大字符串。 */
  private static prepareSource(context: common.Context, id: string, activityId: number, parentPid: number, source: LayoutLaunchSource): string {
    if (!positive(source.sourceBytes) || source.sourceBytes > 16 * 1024 * 1024 || !digest(source.sourceDigest)) throw new Error('Invalid grandfather source proof')
    const dir: string = directory(context, id); ensureDirSync(dir)
    const entries: SessionLayoutCatalogEntry[] = []
    let pack: string[] = []; let packBytes: number = 18; let packIndex: number = 0; let total: number = 0
    const flushPack = (): void => {
      if (pack.length === 0) return
      writeText(dir + '/source_pack_' + packIndex.toString() + '.json', JSON.stringify({ rawProfiles: pack }), CHUNK_BYTES)
      pack = []; packBytes = 18; packIndex++
    }
    for (let index: number = 0; index < source.catalog.length; index++) {
      const entry: SessionLayoutCatalogEntry = source.catalog[index]
      const raw: string = source.readProfileRaw(entry.profileId)
      if (utf8ByteLength(raw) !== entry.bytes || evidenceTextDigest(raw) !== entry.digest
          || validateAndNormalizeLayout(JSON.parse(raw) as LayoutProfile) === null) throw new Error('StaleCandidate:历史源载荷或语义漂移')
      const cost: number = utf8ByteLength(JSON.stringify(raw)) + 1
      let payloadId: string = ''
      if (cost + 18 > CHUNK_BYTES) {
        flushPack(); payloadId = 'base_' + index.toString(); writeRawPayload(dir, payloadId, raw)
      } else {
        if (pack.length >= 1024 || packBytes + cost > CHUNK_BYTES) flushPack()
        payloadId = 'packed_' + packIndex.toString() + '_' + pack.length.toString()
        pack.push(raw); packBytes += cost
      }
      total += entry.bytes
      entries.push({ profileId: entry.profileId, profileRevision: entry.profileRevision, name: entry.name,
        isPreset: entry.isPreset, targetDevice: entry.targetDevice, bytes: entry.bytes, digest: entry.digest, payloadId: payloadId })
    }
    flushPack()
    const count: number = Math.ceil(entries.length / PAGE_ITEMS)
    if (count < 1 || count > SOURCE_MAX_PAGES) throw new Error('Invalid source-derived catalog count')
    let next: string = ''
    for (let index: number = count - 1; index >= 0; index--) next = writeText(dir + '/catalog_' + index.toString() + '.json',
      JSON.stringify({ entries: entries.slice(index * PAGE_ITEMS, (index + 1) * PAGE_ITEMS), nextDigest: next } as CatalogPage), CHUNK_BYTES)
    const root: FrozenRoot = { schema: 2, snapshotId: id, activityId: activityId, parentPid: parentPid, createdAt: Date.now(),
      sourceLibraryRevision: evidenceTextDigest(source.sourceDigest + ':' + next + ':' + source.activeProfileId),
      activeProfileId: source.activeProfileId, catalogPageCount: count, catalogDigest: next, profileCount: entries.length,
      totalBytes: total, encoding: 'legacy-source', sourceRawBytes: source.sourceBytes, sourceRawDigest: source.sourceDigest,
      sourceGrowthCredit: source.sourceGrowthCredit }
    return writeText(dir + '/root.json', JSON.stringify(root), ROOT_BYTES)
  }

  /** 由已授权 GameAbility consume 调用一次；root保持冻结，PID绑定写独立租约，不改原始基线。 */
  static installGame(context: common.Context, id: string, activityId: number, parentPid: number, gamePid: number, expectedRootDigest: string): void {
    const root: FrozenRoot = readRoot(context, id)
    if (!ProcessPreferences.isGameProcess() || gamePid !== testNapi.desktopProcessId() || gamePid === parentPid
        || !positive(gamePid) || root.parentPid !== parentPid || root.activityId !== activityId) throw new Error('V2 layout consume identity mismatch')
    const dir: string = directory(context, id)
    if (!digest(expectedRootDigest) || evidenceFileDigestSync(dir + '/root.json') !== expectedRootDigest) throw new Error('V2 layout root differs from authorized ticket')
    if (fs.accessSync(dir + '/lease.json')) throw new Error('V2 layout session already consumed')
    const lease: GameLease = { schema: 2, snapshotId: id, activityId: activityId, parentPid: parentPid, gamePid: gamePid,
      rootDigest: evidenceFileDigestSync(dir + '/root.json') }
    const catalog: SessionLayoutCatalogEntry[] = readCatalog(context, root)
    const source: boolean = root.encoding === 'legacy-source'
    const repository = new GameSessionLayoutRepository(catalog, root.activeProfileId, new V2SessionTransport(context, lease, source), source, root.sourceGrowthCredit ?? 0)
    // 活动方案读取失败不发布租约或安装一个半有效仓库；其它 payload 在真正选择时再读取。
    repository.readProfile(root.activeProfileId)
    writeText(dir + '/lease.json', JSON.stringify(lease), ROOT_BYTES)
    installGameSessionLayoutRepository(repository)
  }

  /** 游戏锁/编辑租约允许时现读 owner，已确认标记与布局同属 owner提交，外部回执只能后写。 */
  static async importPending(context: common.UIAbilityContext): Promise<V2LayoutImportReport> {
    const report: V2LayoutImportReport = { imported: 0, pending: 0, deferred: false, conflicts: [] }
    if (ProcessPreferences.isGameProcess()) throw new Error('Game process cannot import V2 layouts')
    if (testNapi.desktopGameProcessState(context.filesDir, 0) !== 0) { report.deferred = true; return report }
    const baseDir: string = context.filesDir + '/game-layout-v2'
    for (const parent of [context.filesDir, baseDir]) {
      if (fs.accessSync(parent) && !fs.lstatSync(parent).isDirectory()) throw new Error('V2 layout parent directory is linked or not ordinary')
    }
    let ids: string[] = []
    try { ids = fs.listFileSync(baseDir).filter((name: string): boolean => uuid(name)) }
    catch (error) { if ((error as BusinessError).code === 13900002) return report; throw error as Error }
    const store = getLayoutStore()
    await store.init(context)
    for (const id of ids.sort()) {
      const dir: string = directory(context, id)
      if (!fs.lstatSync(dir).isDirectory()) throw new Error('Invalid V2 session directory')
      if (!fs.accessSync(dir + '/pending.json')) continue
      report.pending++
      if (store.isEditorActive() || testNapi.desktopGameProcessState(context.filesDir, 0) !== 0) { report.deferred = true; continue }
      const root: FrozenRoot = readRoot(context, id)
      const rootDigest: string = evidenceFileDigestSync(dir + '/root.json')
      const pendingText: string = readText(dir + '/pending.json', ROOT_BYTES)
      const pending = JSON.parse(pendingText) as V2Pending
      onlyKeys(pending, ['schema', 'snapshotId', 'activityId', 'parentPid', 'gamePid', 'rootDigest', 'revision', 'submittedAt', 'pageCount', 'changesDigest', 'activeProfileId'])
      const lease = JSON.parse(readText(dir + '/lease.json', ROOT_BYTES)) as GameLease
      onlyKeys(lease, ['schema', 'snapshotId', 'activityId', 'parentPid', 'gamePid', 'rootDigest'])
      if (pending.schema !== 2 || lease.schema !== 2 || pending.snapshotId !== id || lease.snapshotId !== id
          || pending.activityId !== root.activityId || lease.activityId !== root.activityId
          || pending.parentPid !== root.parentPid || lease.parentPid !== root.parentPid
          || !positive(pending.gamePid) || pending.gamePid === pending.parentPid || pending.gamePid !== lease.gamePid
          || pending.rootDigest !== rootDigest || lease.rootDigest !== rootDigest || !positive(pending.revision)
          || !positive(pending.submittedAt) || pending.submittedAt < root.createdAt || pending.submittedAt > Date.now()
          || !positive(pending.pageCount) || pending.pageCount > (root.encoding === 'legacy-source' ? SOURCE_MAX_PAGES : MAX_PAGES) || !digest(pending.changesDigest)
          || !identity(pending.activeProfileId)) throw new Error('V2 layout journal identity mismatch; original retained')
      const catalog: SessionLayoutCatalogEntry[] = readCatalog(context, root)
      const changes: SessionLayoutChange[] = []
      const changedIds: Set<string> = new Set<string>()
      let expected: string = pending.changesDigest
      for (let index: number = 0; index < pending.pageCount; index++) {
        const page = JSON.parse(readChecked(dir + '/changes_' + pending.revision.toString() + '_' + index.toString() + '.json', expected, CHUNK_BYTES)) as ChangePage
        onlyKeys(page, ['changes', 'nextDigest'])
        if (!Array.isArray(page.changes) || page.changes.length > PAGE_ITEMS) throw new Error('Invalid V2 change page')
        for (const change of page.changes) {
          onlyKeys(change, ['profileId', 'baseDigest', 'baseRevision', 'payloadId'])
          const old: SessionLayoutCatalogEntry | undefined = catalog.find((entry: SessionLayoutCatalogEntry): boolean => entry.profileId === change.profileId)
          if (!identity(change.profileId) || changedIds.has(change.profileId) || (old === undefined
            ? change.baseDigest !== '' || change.baseRevision !== 0 || change.payloadId === ''
            : change.baseDigest !== old.digest || change.baseRevision !== old.profileRevision)) throw new Error('Invalid V2 change base identity')
          changedIds.add(change.profileId)
          if (change.payloadId !== '' && !change.payloadId.startsWith('change_' + pending.revision.toString() + '_')) throw new Error('Invalid V2 change revision reference')
          const proposed: LayoutProfile | null = change.payloadId === '' ? null : readPayload(dir, change.payloadId)
          if (proposed !== null && proposed.profileId !== change.profileId) throw new Error('V2 proposed profile identity mismatch')
          changes.push({ profileId: change.profileId, baseDigest: change.baseDigest, baseRevision: change.baseRevision, proposed: proposed })
        }
        if (index + 1 < pending.pageCount ? !digest(page.nextDigest) : page.nextDigest !== '') throw new Error('Invalid V2 change digest chain termination')
        expected = page.nextDigest
      }
      if (expected !== '') throw new Error('V2 change set incomplete')
      const journalDigest: string = evidenceTextDigest(pendingText)
      const result = await store.importGameSessionChanges(catalog, changes, root.activeProfileId,
        pending.activeProfileId, id, journalDigest,
        (entry: SessionLayoutCatalogEntry): LayoutProfile => root.encoding === 'legacy-source'
          ? normalizeLayoutSource(readRawPayload(dir, entry.payloadId, entry.digest, entry.bytes), entry.profileId, entry.profileRevision, entry.name)
          : readPayload(dir, entry.payloadId, entry.digest, entry.bytes))
      if (result.deferred) { report.deferred = true; continue }
      // 原文及冻结材料保留到 owner与回执确认；不以 child PID消失单独决定删除。
      writeText(dir + '/applied.json', JSON.stringify({ schema: 2, snapshotId: id, activityId: pending.activityId,
        gamePid: pending.gamePid, rootDigest: rootDigest, digest: journalDigest }), ROOT_BYTES)
      fs.unlinkSync(dir + '/pending.json')
      report.pending--; report.imported++; report.conflicts.push(...result.conflicts)
    }
    return report
  }
}
