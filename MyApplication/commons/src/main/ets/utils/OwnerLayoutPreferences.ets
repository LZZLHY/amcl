/**
 * owner布局Preferences适配器。超过8MiB时先把完整原文备份与新方案载荷落盘，再同flush原子切换索引指针。
 * XML的原profiles保留为恢复证据；指针存在后只以目录载荷为权威，游戏进程不实例化此适配器。
 * 失败不丢原文/上一索引；回滚仍经LayoutStore完整两键提交，指针只在已确认flush后成为新基线。
 */
import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { LaunchPreferenceStore, LaunchPreferenceValue } from './PreferenceSnapshot'
import { writeEvidenceTextAtomic, evidenceTextDigest } from './EvidenceIo'
import { ensureDirSync } from './FileUtils'
import { stringToUtf8 } from './Base64Util'
import { LAYOUT_STORAGE_MIGRATION_BYTES, LAYOUT_STORAGE_LIBRARY_BYTES } from './LayoutStorageBudget'

const BACKEND_KEY: string = 'profiles_backend'
const MIGRATION_BYTES: number = LAYOUT_STORAGE_MIGRATION_BYTES
const FILE_BYTES: number = LAYOUT_STORAGE_LIBRARY_BYTES
const PAGE_ITEMS: number = 32
interface LayoutFileIndex { schema: number; generation: string; count: number; pageCount: number; firstDigest: string; rawDigest: string; bytes: number }
interface LayoutFilePage { entries: LayoutPayloadRef[]; nextDigest: string }
interface LayoutPayloadRef { id: string; digest: string; bytes: number }

export class OwnerLayoutPreferences implements LaunchPreferenceStore {
  private context: common.Context
  private preference: LaunchPreferenceStore
  private staged: string | undefined = undefined
  private generationSequence: number = 0
  private pointer: string
  constructor(context: common.Context, preference: LaunchPreferenceStore) {
    this.context = context; this.preference = preference
    this.pointer = preference.getSync(BACKEND_KEY, '') as string
    if (typeof this.pointer !== 'string') throw new Error('Invalid owner layout backend pointer')
  }
  private bytes(value: string): number { return stringToUtf8(value).byteLength }
  private directory(): string {
    const dir: string = this.context.filesDir + '/layout-library'
    for (const parent of [this.context.filesDir, dir]) {
      if (fs.accessSync(parent) && !fs.lstatSync(parent).isDirectory()) throw new Error('布局后端父目录是链接或非普通目录')
    }
    return dir
  }
  private validGeneration(value: string): boolean { return new RegExp('^[0-9a-f]{32}_[0-9]+$').test(value) }
  private read(path: string, expected: string, limit: number): string {
    const stat = fs.lstatSync(path)
    if (!stat.isFile() || stat.size <= 0 || stat.size > limit) throw new Error('布局后端载荷不是有界普通文件')
    const value: string = fs.readTextSync(path)
    if (this.bytes(value) !== stat.size || evidenceTextDigest(value) !== expected) throw new Error('布局后端摘要/短读校验失败，保留原文恢复')
    return value
  }
  private readProfiles(pointer: string): string {
    const index = JSON.parse(pointer) as LayoutFileIndex
    if (Object.keys(index).some((key: string): boolean => !['schema', 'generation', 'count', 'pageCount', 'firstDigest', 'rawDigest', 'bytes'].includes(key))
        || index.schema !== 1 || !this.validGeneration(index.generation) || !Number.isSafeInteger(index.count) || index.count < 1
        || !Number.isSafeInteger(index.pageCount) || index.pageCount < 1 || index.pageCount > 4096
        || !Number.isSafeInteger(index.bytes) || index.bytes < 1 || index.bytes > FILE_BYTES) throw new Error('Invalid layout file index')
    const dir: string = this.directory() + '/' + index.generation
    if (!fs.lstatSync(dir).isDirectory()) throw new Error('布局后端目录身份非法')
    let next: string = index.firstDigest
    const parts: string[] = []
    let total: number = 2
    for (let pageIndex: number = 0; pageIndex < index.pageCount; pageIndex++) {
      const page = JSON.parse(this.read(dir + '/page_' + pageIndex.toString() + '.json', next, 256 * 1024)) as LayoutFilePage
      if (!Array.isArray(page.entries) || page.entries.length < 1 || page.entries.length > PAGE_ITEMS) throw new Error('Invalid layout backend page')
      for (const entry of page.entries) {
        if (!new RegExp('^profile_[0-9]+$').test(entry.id) || !Number.isSafeInteger(entry.bytes) || entry.bytes < 1 || entry.bytes > FILE_BYTES) throw new Error('Invalid layout backend payload reference')
        const value: string = this.read(dir + '/' + entry.id + '.json', entry.digest, entry.bytes)
        total += this.bytes(value) + (parts.length > 0 ? 1 : 0)
        if (total > index.bytes) throw new Error('Layout backend byte overflow')
        parts.push(value)
      }
      next = page.nextDigest
    }
    const result: string = '[' + parts.join(',') + ']'
    if (next !== '' || parts.length !== index.count || total !== index.bytes || evidenceTextDigest(result) !== index.rawDigest) throw new Error('Layout backend incomplete or identity drift')
    return result
  }
  getSync(key: string, fallback: LaunchPreferenceValue): LaunchPreferenceValue {
    if (key !== 'profiles') return this.preference.getSync(key, fallback)
    if (this.staged !== undefined) return this.staged
    return this.pointer.length === 0 ? this.preference.getSync(key, fallback) : this.readProfiles(this.pointer)
  }
  async get(key: string, fallback: LaunchPreferenceValue): Promise<LaunchPreferenceValue> { return this.getSync(key, fallback) }
  putSync(key: string, value: LaunchPreferenceValue): void {
    if (key === BACKEND_KEY) throw new Error('布局后端指针只能由完整提交生成')
    if (key !== 'profiles') { this.preference.putSync(key, value); return }
    if (typeof value !== 'string' || this.bytes(value) > FILE_BYTES) throw new Error('BudgetExceeded:布局库超过有界文件预算')
    this.staged = value
  }
  async put(key: string, value: LaunchPreferenceValue): Promise<void> {
    if (key === 'profiles' || key === BACKEND_KEY) this.putSync(key, value)
    else await this.preference.put(key, value)
  }
  deleteSync(key: string): void {
    if (key === 'profiles' || key === BACKEND_KEY) throw new Error('布局库不能删除后端身份')
    this.preference.deleteSync(key)
  }
  /** 原文备份在首个迁移前独立落盘；既有索引指针与所有旧载荷保留，失败回滚不依赖清理成功。 */
  private writeProfiles(value: string): string {
    const entries = JSON.parse(value) as Object[]
    if (!Array.isArray(entries) || entries.length < 1) throw new Error('Invalid layout library payload')
    const canonical: string = JSON.stringify(entries)
    if (canonical !== value) throw new Error('布局目录提交需要规范化JSON；原文保持不动')
    this.generationSequence++
    const generation: string = util.generateRandomUUID().toLowerCase().replace(/-/g, '') + '_' + this.generationSequence.toString()
    const dir: string = this.directory() + '/' + generation
    if (!this.validGeneration(generation) || fs.accessSync(dir)) throw new Error('布局后端代次已存在，拒绝覆盖')
    ensureDirSync(dir)
    if (this.pointer.length === 0) {
      const raw: LaunchPreferenceValue = this.preference.getSync('profiles', '')
      if (typeof raw !== 'string') throw new Error('原布局偏好不是字符串')
      // 备份沿独立代次路径保存，不覆盖先前恢复材料。
      writeEvidenceTextAtomic(dir + '/legacy-original.json', raw)
    }
    const refs: LayoutPayloadRef[] = []
    for (let index: number = 0; index < entries.length; index++) {
      const text: string = JSON.stringify(entries[index])
      const id: string = 'profile_' + index.toString()
      writeEvidenceTextAtomic(dir + '/' + id + '.json', text)
      refs.push({ id: id, digest: evidenceTextDigest(text), bytes: this.bytes(text) })
    }
    const pageCount: number = Math.ceil(refs.length / PAGE_ITEMS)
    if (pageCount > 4096) throw new Error('布局库目录页数超过有界预算')
    let next: string = ''
    for (let index: number = pageCount - 1; index >= 0; index--) {
      const text: string = JSON.stringify({ entries: refs.slice(index * PAGE_ITEMS, (index + 1) * PAGE_ITEMS), nextDigest: next } as LayoutFilePage)
      if (this.bytes(text) > 256 * 1024) throw new Error('布局库目录页超过有界预算')
      writeEvidenceTextAtomic(dir + '/page_' + index.toString() + '.json', text)
      next = evidenceTextDigest(text)
    }
    const index: LayoutFileIndex = { schema: 1, generation: generation, count: refs.length, pageCount: pageCount,
      firstDigest: next, rawDigest: evidenceTextDigest(value), bytes: this.bytes(value) }
    const pointer: string = JSON.stringify(index)
    // 指针切换前完整回读与摘要对账，不能把仅“写调用成功”当迁移完成。
    if (this.readProfiles(pointer) !== value) throw new Error('布局后端迁移回读失败')
    return pointer
  }
  async flush(): Promise<void> {
    const value: string | undefined = this.staged
    const beforePointer: string = this.pointer
    let nextPointer: string = beforePointer
    try {
      if (value !== undefined) {
        if (beforePointer.length > 0 || this.bytes(value) > MIGRATION_BYTES) {
          nextPointer = this.writeProfiles(value)
          await this.preference.put(BACKEND_KEY, nextPointer)
        } else await this.preference.put('profiles', value)
      }
      await this.preference.flush()
      this.pointer = nextPointer
      this.staged = undefined
    } catch (error) {
      // 恢复内存偏好指针，LayoutStore随后恢复两键并flush；回滚失败由它封锁后续mutation。
      this.preference.putSync(BACKEND_KEY, beforePointer)
      this.staged = undefined
      throw error as Error
    }
  }
}
