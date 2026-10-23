/**
 * 合法旧布局库的源形态仓库：原Preferences raw保持原位，独立备份不超过SDK单值16MiB；
 * 目录只保存身份/名字及有界payload引用，按方案读原文，不拼接全库规范化结果。
 * 原始条目引用同一冻结raw的真实数组范围，避免大量小方案产生同样数量的文件与fsync。
 * 本层只校验IO身份、摘要、范围和原子提交；布局语义/系统补齐/增长预算由gamecontrol负责。
 */
import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { LaunchPreferenceStore, LaunchPreferenceValue } from './PreferenceSnapshot'
import { writeEvidenceTextAtomic, evidenceTextDigest } from './EvidenceIo'
import { ensureDirSync } from './FileUtils'
import { LAYOUT_STORAGE_XML_BYTES, LAYOUT_STORAGE_LIBRARY_BYTES, LAYOUT_STORAGE_CHUNK_BYTES } from './LayoutStorageBudget'

const SOURCE_KEY: string = 'profiles_source_backend'
const PAGE_ITEMS: number = 32
const ROOT_BYTES: number = 16 * 1024
/** 每个合法profile至少含非空name和controls数组；此推导只限制新增目录，不限制旧raw的实际条目数。 */
const NEW_ENTRY_BOUND: number = Math.floor(LAYOUT_STORAGE_LIBRARY_BYTES / 26)

export interface OwnerLayoutSourceEntry {
  profileId: string
  profileRevision: number
  name: string
  isPreset: boolean
  targetDevice: string
  bytes: number
  digest: string
  payloadId: string
}
export interface OwnerLayoutSourceInput {
  profileId: string
  profileRevision: number
  name: string
  isPreset: boolean
  targetDevice: string
  sourceIndex: number
  raw: string
}
export interface OwnerLayoutSourceChange { profileId: string; raw: string | null }
/** owner V2幂等完成标记与目录pointer同flush，不能确认布局后漏记已消费身份。 */
export interface OwnerLayoutSourceCompletion { key: string; value: string }
interface SourceRange { start: number; end: number }
interface SourceEntry extends OwnerLayoutSourceEntry {
  sourceIndex: number
  start: number
  end: number
  payloadGeneration: string
}
interface SourcePage { entries: SourceEntry[]; nextDigest: string }
interface SourceRoot {
  schema: number
  generation: string
  sourceGeneration: string
  sourceDigest: string
  sourceBytes: number
  sourceCount: number
  activeOriginalDigest: string
  count: number
  pageCount: number
  firstDigest: string
  activeProfileId: string
  totalBytes: number
}

/** 只计数UTF-8字节，不为16MiB原文反复分配4倍容量的编码缓冲；代理对按完整Unicode标量计。 */
function bytes(value: string): number {
  let result: number=0
  for (let index: number=0;index<value.length;index++) {
    const code: number=value.charCodeAt(index)
    if (code<0x80) result++
    else if (code<0x800) result+=2
    else if (code>=0xD800 && code<=0xDBFF && index+1<value.length && value.charCodeAt(index+1)>=0xDC00 && value.charCodeAt(index+1)<=0xDFFF) {
      result+=4;index++
    } else result+=3
  }
  return result
}
function positive(value: number): boolean { return Number.isSafeInteger(value) && value > 0 }
function digest(value: string): boolean { return typeof value==='string' && new RegExp('^[0-9a-f]{64}$').test(value) }
function identity(value: string): boolean { return typeof value==='string' && new RegExp('^[a-zA-Z0-9_-]{1,64}$').test(value) }
function generation(value: string): boolean { return typeof value==='string' && new RegExp('^[0-9a-f]{32}$').test(value) }
function onlyKeys(value: Object, allowed: string[]): void {
  if (!value || typeof value!=='object' || Array.isArray(value) || Object.keys(value).some((key: string): boolean => !allowed.includes(key))) {
    throw new Error('Invalid source layout object fields')
  }
}
function copyEntry(entry: OwnerLayoutSourceEntry): OwnerLayoutSourceEntry {
  return {profileId:entry.profileId,profileRevision:entry.profileRevision,name:entry.name,isPreset:entry.isPreset,
    targetDevice:entry.targetDevice,bytes:entry.bytes,digest:entry.digest,payloadId:entry.payloadId}
}
/** payload容器必须是JSON对象；字段语义仍由gamecontrol核验，不能将null/数组写成活动方案。 */
function requireProfileObject(raw: string): void {
  const value: Object=JSON.parse(raw) as Object
  if (value===null || typeof value!=='object' || Array.isArray(value)) throw new Error('Invalid source layout profile object')
}

/** JSON.parse只验证有界原始数组；扫描字面范围时尊重字符串转义和对象/数组深度，不规范化任何profile。 */
function sourceRanges(raw: string): SourceRange[] {
  if (bytes(raw)>LAYOUT_STORAGE_XML_BYTES) throw new Error('BudgetExceeded:旧布局原文超过SDK单值边界')
  if (!Array.isArray(JSON.parse(raw))) throw new Error('Invalid legacy layout source array')
  const ranges: SourceRange[]=[]
  let index: number=raw.indexOf('[')+1
  while (index<raw.length) {
    while (index<raw.length && /\s/.test(raw.charAt(index))) index++
    if (raw.charAt(index)===']') break
    const start: number=index
    let depth: number=0, quoted: boolean=false, escaped: boolean=false
    for (;index<raw.length;index++) {
      const ch: string=raw.charAt(index)
      if (quoted) {
        if (escaped) escaped=false
        else if (ch==='\\') escaped=true
        else if (ch==='"') quoted=false
      } else if (ch==='"') quoted=true
      else if (ch==='{' || ch==='[') depth++
      else if (ch==='}' || ch===']') {
        if (depth===0) break
        depth--
      } else if (ch===',' && depth===0) break
    }
    let end: number=index
    while (end>start && /\s/.test(raw.charAt(end-1))) end--
    if (end<=start) throw new Error('Invalid legacy layout element range')
    ranges.push({start:start,end:end})
    if (raw.charAt(index)===',') index++
    else if (raw.charAt(index)===']') break
  }
  return ranges
}

export class OwnerLayoutSourceRepository {
  private context: common.Context
  private preference: LaunchPreferenceStore
  private root: SourceRoot
  private pointer: string
  private source: string
  private ranges: SourceRange[]
  private entries: SourceEntry[]
  /** V2逐方案冻结使用O(1)身份查找，不能对完整大目录每项重复线性find。 */
  private entriesById: Map<string,SourceEntry> = new Map<string,SourceEntry>()
  private constructor(context: common.Context, preference: LaunchPreferenceStore, root: SourceRoot,
    pointer: string, source: string, ranges: SourceRange[], entries: SourceEntry[]) {
    this.context=context;this.preference=preference;this.root=root;this.pointer=pointer
    this.source=source;this.ranges=ranges;this.entries=entries
    for (const entry of entries) this.entriesById.set(entry.profileId,entry)
  }

  /** 仅在持久source pointer存在时读取目录；不调用旧wrapper的profiles整库规范化读取。 */
  static open(context: common.Context, preference: LaunchPreferenceStore): OwnerLayoutSourceRepository | null {
    const pointer: LaunchPreferenceValue=preference.getSync(SOURCE_KEY,'')
    if (pointer==='') return null
    if (typeof pointer!=='string' || bytes(pointer)>ROOT_BYTES) throw new Error('Invalid source layout pointer')
    return OwnerLayoutSourceRepository.readRepository(context,preference,pointer)
  }

  /**
   * 调用方已逐条校验语义后提供身份映射；原条目必须匹配原raw真实数组元素，新代码预设用sourceIndex=-1。
   * 先持久源/目录并完整回读，再将source pointer与active_profile同flush切换权威；旧XML和旧代次保持可恢复。
   */
  static async openOrMigrate(context: common.Context, preference: LaunchPreferenceStore, raw: string,
    activeName: string, inputs: OwnerLayoutSourceInput[]): Promise<OwnerLayoutSourceRepository> {
    const existing: OwnerLayoutSourceRepository | null=OwnerLayoutSourceRepository.open(context,preference)
    if (existing!==null) return existing
    const ranges: SourceRange[]=sourceRanges(raw)
    const gen: string=util.generateRandomUUID().toLowerCase().replace(/-/g,'')
    const dir: string=OwnerLayoutSourceRepository.directory(context,gen,true)
    writeEvidenceTextAtomic(dir+'/source-original.json',raw)
    const originalActive: LaunchPreferenceValue=preference.getSync('active_profile','')
    const activeRaw: string=typeof originalActive==='string' ? originalActive : ''
    if (bytes(activeRaw)>LAYOUT_STORAGE_XML_BYTES) throw new Error('Invalid legacy active name size')
    writeEvidenceTextAtomic(dir+'/active-original.json',activeRaw)
    const entries: SourceEntry[]=[]
    const usedRanges: Set<number>=new Set<number>()
    for (let index: number=0;index<inputs.length;index++) {
      const input: OwnerLayoutSourceInput=inputs[index]
      let text: string=input.raw
      let start: number=0,end: number=0,payloadGen: string=gen,payloadId: string='payload_'+index.toString()
      if (input.sourceIndex>=0) {
        if (!Number.isSafeInteger(input.sourceIndex) || input.sourceIndex>=ranges.length || usedRanges.has(input.sourceIndex)) {
          throw new Error('Invalid duplicate source layout reference')
        }
        usedRanges.add(input.sourceIndex)
        const range: SourceRange=ranges[input.sourceIndex]
        text=raw.substring(range.start,range.end)
        if (JSON.stringify(JSON.parse(text))!==JSON.stringify(JSON.parse(input.raw))) throw new Error('Source layout identity drift')
        start=range.start;end=range.end;payloadGen=gen;payloadId='source_'+input.sourceIndex.toString()
      } else {
        if (input.sourceIndex!==-1 || bytes(text)>LAYOUT_STORAGE_CHUNK_BYTES) throw new Error('Invalid generated source profile')
        requireProfileObject(text)
        writeEvidenceTextAtomic(dir+'/'+payloadId+'.json',text)
      }
      entries.push({profileId:input.profileId,profileRevision:input.profileRevision,name:input.name,isPreset:input.isPreset,
        targetDevice:input.targetDevice,bytes:bytes(text),digest:evidenceTextDigest(text),payloadId:payloadId,
        sourceIndex:input.sourceIndex,start:start,end:end,payloadGeneration:payloadGen})
    }
    const active: SourceEntry | undefined=entries.find((entry: SourceEntry): boolean => entry.name===activeName)
    if (active===undefined) throw new Error('TargetMissing:source active profile not found')
    const root: SourceRoot={schema:1,generation:gen,sourceGeneration:gen,sourceDigest:evidenceTextDigest(raw),
      sourceBytes:bytes(raw),sourceCount:ranges.length,activeOriginalDigest:evidenceTextDigest(activeRaw),count:entries.length,
      pageCount:0,firstDigest:'',activeProfileId:active.profileId,totalBytes:0}
    const pointer: string=OwnerLayoutSourceRepository.writeCatalog(context,root,entries)
    const repository: OwnerLayoutSourceRepository=OwnerLayoutSourceRepository.readRepository(context,preference,pointer)
    await repository.publishPointer(pointer,active.name,'')
    return repository
  }

  getCatalog(): OwnerLayoutSourceEntry[] { return this.entries.map((entry: SourceEntry): OwnerLayoutSourceEntry => copyEntry(entry)) }
  activeProfileId(): string { return this.root.activeProfileId }
  sourceDigest(): string { return this.root.sourceDigest }
  sourceBytes(): number { return this.root.sourceBytes }
  /** 单条读取始终复核摘要和范围；source原文缓存固定，不读取父进程后来修改的profiles。 */
  readProfileRaw(profileId: string): string {
    const entry: SourceEntry | undefined=this.entriesById.get(profileId)
    if (entry===undefined) throw new Error('TargetMissing:source profile not found')
    return this.readEntry(entry)
  }

  /** 净修改只替换对应条目，未读旧方案继续引用原raw；所有metadata/active与pointer同属本次确认提交。 */
  async commit(catalogCurrent: OwnerLayoutSourceEntry[], changes: OwnerLayoutSourceChange[], activeId: string,
    completion?: OwnerLayoutSourceCompletion): Promise<void> {
    if (this.preference.getSync(SOURCE_KEY,'')!==this.pointer) throw new Error('StaleCandidate:source layout authority changed')
    if (completion!==undefined && (!/^game_layout_applied_[a-zA-Z0-9_-]{1,128}$/.test(completion.key) ||
      typeof completion.value!=='string' || bytes(completion.value)>ROOT_BYTES)) throw new Error('Invalid source layout completion marker')
    const frozenCompletion: OwnerLayoutSourceCompletion | undefined=completion===undefined ? undefined :
      {key:completion.key,value:completion.value}
    const old: Map<string,SourceEntry>=new Map<string,SourceEntry>()
    for (const entry of this.entries) old.set(entry.profileId,entry)
    const changeMap: Map<string,OwnerLayoutSourceChange>=new Map<string,OwnerLayoutSourceChange>()
    for (const change of changes) {
      if (changeMap.has(change.profileId)) throw new Error('Invalid duplicate source layout change')
      changeMap.set(change.profileId,change)
    }
    const gen: string=util.generateRandomUUID().toLowerCase().replace(/-/g,'')
    const dir: string=OwnerLayoutSourceRepository.directory(this.context,gen,true)
    const next: SourceEntry[]=[]
    for (let index: number=0;index<catalogCurrent.length;index++) {
      const metadata: OwnerLayoutSourceEntry=catalogCurrent[index]
      const prior: SourceEntry | undefined=old.get(metadata.profileId)
      const change: OwnerLayoutSourceChange | undefined=changeMap.get(metadata.profileId)
      if (change!==undefined && change.raw===null) throw new Error('Invalid deleted source profile remains in catalog')
      if (change?.raw!==undefined && change.raw!==null) {
        const text: string=change.raw
        if (bytes(text)>LAYOUT_STORAGE_LIBRARY_BYTES || !text) throw new Error('BudgetExceeded:source profile payload')
        requireProfileObject(text)
        const payloadId: string='payload_'+index.toString()
        writeEvidenceTextAtomic(dir+'/'+payloadId+'.json',text)
        if (OwnerLayoutSourceRepository.read(this.context,gen,payloadId+'.json',evidenceTextDigest(text),LAYOUT_STORAGE_LIBRARY_BYTES)!==text) {
          throw new Error('Source layout new payload persisted readback mismatch')
        }
        next.push({profileId:metadata.profileId,profileRevision:metadata.profileRevision,name:metadata.name,isPreset:metadata.isPreset,
          targetDevice:metadata.targetDevice,bytes:bytes(text),digest:evidenceTextDigest(text),payloadId:payloadId,
          sourceIndex:-1,start:0,end:0,payloadGeneration:gen})
      } else {
        if (prior===undefined || metadata.profileRevision!==prior.profileRevision) throw new Error('StaleCandidate:source profile change missing')
        next.push({profileId:metadata.profileId,profileRevision:metadata.profileRevision,name:metadata.name,isPreset:metadata.isPreset,
          targetDevice:metadata.targetDevice,bytes:prior.bytes,digest:prior.digest,payloadId:prior.payloadId,
          sourceIndex:prior.sourceIndex,start:prior.start,end:prior.end,payloadGeneration:prior.payloadGeneration})
      }
    }
    const ids: Set<string>=new Set<string>(next.map((entry: SourceEntry): string => entry.profileId))
    for (const change of changes) if (change.raw!==null && !ids.has(change.profileId)) throw new Error('Invalid source change outside current catalog')
    const selected: SourceEntry | undefined=next.find((entry: SourceEntry): boolean => entry.profileId===activeId)
    if (selected===undefined) throw new Error('TargetMissing:source active profile not found')
    const root: SourceRoot={schema:1,generation:gen,sourceGeneration:this.root.sourceGeneration,sourceDigest:this.root.sourceDigest,
      sourceBytes:this.root.sourceBytes,sourceCount:this.root.sourceCount,activeOriginalDigest:this.root.activeOriginalDigest,
      count:next.length,pageCount:0,firstDigest:'',activeProfileId:activeId,totalBytes:0}
    const pointer: string=OwnerLayoutSourceRepository.writeCatalog(this.context,root,next)
    const verified: OwnerLayoutSourceRepository=OwnerLayoutSourceRepository.readRepository(this.context,this.preference,pointer)
    await this.publishPointer(pointer,selected.name,this.pointer,frozenCompletion)
    this.root=verified.root;this.pointer=pointer;this.entries=verified.entries;this.entriesById=verified.entriesById
  }

  private readEntry(entry: SourceEntry): string {
    let value: string
    if (entry.sourceIndex>=0) {
      const range: SourceRange | undefined=this.ranges[entry.sourceIndex]
      if (range===undefined || range.start!==entry.start || range.end!==entry.end || entry.payloadGeneration!==this.root.sourceGeneration ||
        entry.payloadId!=='source_'+entry.sourceIndex.toString()) throw new Error('Invalid source layout range identity')
      value=this.source.substring(entry.start,entry.end)
    } else value=OwnerLayoutSourceRepository.read(this.context,entry.payloadGeneration,entry.payloadId+'.json',entry.digest,entry.bytes)
    if (bytes(value)!==entry.bytes || evidenceTextDigest(value)!==entry.digest) throw new Error('Source layout payload digest mismatch')
    return value
  }

  private async publishPointer(pointer: string,activeName: string,beforePointer: string,
    completion?: OwnerLayoutSourceCompletion): Promise<void> {
    if (this.preference.getSync(SOURCE_KEY,'')!==beforePointer) throw new Error('StaleCandidate:source layout pointer changed before commit')
    const beforeActive: LaunchPreferenceValue=this.preference.getSync('active_profile','')
    const beforeCompletion: LaunchPreferenceValue=completion===undefined ? '' : this.preference.getSync(completion.key,'')
    try {
      await this.preference.put(SOURCE_KEY,pointer);await this.preference.put('active_profile',activeName)
      if (completion!==undefined) await this.preference.put(completion.key,completion.value)
      await this.preference.flush()
      this.pointer=pointer
    } catch (error) {
      try {
        this.preference.putSync(SOURCE_KEY,beforePointer);this.preference.putSync('active_profile',beforeActive)
        if (completion!==undefined) this.preference.putSync(completion.key,beforeCompletion)
        await this.preference.flush()
      } catch (_) { throw new Error('RollbackFailed:source layout pointer/active restore failed; original files preserved') }
      throw error as Error
    }
  }

  private static directory(context: common.Context,gen: string,create: boolean=false): string {
    if (!generation(gen)) throw new Error('Invalid source layout generation')
    const root: string=context.filesDir+'/layout-source'
    const dir: string=root+'/'+gen
    for (const path of [context.filesDir,root,dir]) if (fs.accessSync(path) && !fs.lstatSync(path).isDirectory()) {
      throw new Error('Source layout directory is linked or not ordinary')
    }
    if (create) { if (fs.accessSync(dir)) throw new Error('Source layout generation already exists');ensureDirSync(dir) }
    return dir
  }
  private static read(context: common.Context,gen: string,name: string,expected: string,limit: number): string {
    if (!/^(source-original|active-original|page_[0-9]+|payload_[0-9]+)\.json$/.test(name) || !digest(expected)) throw new Error('Invalid source layout payload reference')
    const path: string=OwnerLayoutSourceRepository.directory(context,gen)+'/'+name
    const stat=fs.lstatSync(path)
    if (!stat.isFile() || stat.size<0 || stat.size>limit) throw new Error('Source layout payload is not bounded ordinary file')
    const text: string=fs.readTextSync(path)
    if (bytes(text)!==stat.size || evidenceTextDigest(text)!==expected) throw new Error('Source layout file digest mismatch')
    return text
  }

  private static writeCatalog(context: common.Context,root: SourceRoot,entries: SourceEntry[]): string {
    if (entries.length<1 || entries.length>root.sourceCount+NEW_ENTRY_BOUND) throw new Error('BudgetExceeded:source catalog bound')
    root.count=entries.length;root.pageCount=Math.ceil(entries.length/PAGE_ITEMS)
    let next: string=''
    for (let page: number=root.pageCount-1;page>=0;page--) {
      const text: string=JSON.stringify({entries:entries.slice(page*PAGE_ITEMS,(page+1)*PAGE_ITEMS),nextDigest:next} as SourcePage)
      if (bytes(text)>LAYOUT_STORAGE_CHUNK_BYTES) throw new Error('BudgetExceeded:source catalog page')
      writeEvidenceTextAtomic(OwnerLayoutSourceRepository.directory(context,root.generation)+'/page_'+page.toString()+'.json',text)
      next=evidenceTextDigest(text)
    }
    root.firstDigest=next;root.totalBytes=entries.reduce((sum: number,entry: SourceEntry): number => sum+entry.bytes,0)
    if (!positive(root.totalBytes)) throw new Error('Invalid source layout byte total')
    const pointer: string=JSON.stringify(root)
    if (bytes(pointer)>ROOT_BYTES) throw new Error('BudgetExceeded:source layout root')
    return pointer
  }

  private static readRepository(context: common.Context,preference: LaunchPreferenceStore,pointer: string): OwnerLayoutSourceRepository {
    const root=JSON.parse(pointer) as SourceRoot
    onlyKeys(root,['schema','generation','sourceGeneration','sourceDigest','sourceBytes','sourceCount','activeOriginalDigest','count','pageCount','firstDigest','activeProfileId','totalBytes'])
    if (root.schema!==1 || !generation(root.generation) || !generation(root.sourceGeneration) || !digest(root.sourceDigest) ||
      !positive(root.sourceBytes) || root.sourceBytes>LAYOUT_STORAGE_XML_BYTES || !Number.isSafeInteger(root.sourceCount) || root.sourceCount<0 ||
      !digest(root.activeOriginalDigest) || !positive(root.count) || root.count>root.sourceCount+NEW_ENTRY_BOUND ||
      !positive(root.pageCount) || root.pageCount!==Math.ceil(root.count/PAGE_ITEMS) || !digest(root.firstDigest) ||
      !identity(root.activeProfileId) || !positive(root.totalBytes)) throw new Error('Invalid source layout root')
    const source: string=OwnerLayoutSourceRepository.read(context,root.sourceGeneration,'source-original.json',root.sourceDigest,LAYOUT_STORAGE_XML_BYTES)
    if (bytes(source)!==root.sourceBytes) throw new Error('Source layout source byte drift')
    const ranges: SourceRange[]=sourceRanges(source)
    if (ranges.length!==root.sourceCount) throw new Error('Source layout source count drift')
    OwnerLayoutSourceRepository.read(context,root.sourceGeneration,'active-original.json',root.activeOriginalDigest,LAYOUT_STORAGE_XML_BYTES)
    const entries: SourceEntry[]=[],ids: Set<string>=new Set<string>(),names: Set<string>=new Set<string>(),refs: Set<string>=new Set<string>()
    let next: string=root.firstDigest
    for (let page: number=0;page<root.pageCount;page++) {
      const text: string=OwnerLayoutSourceRepository.read(context,root.generation,'page_'+page.toString()+'.json',next,LAYOUT_STORAGE_CHUNK_BYTES)
      const data=JSON.parse(text) as SourcePage
      onlyKeys(data,['entries','nextDigest'])
      if (!Array.isArray(data.entries) || data.entries.length<1 || data.entries.length>PAGE_ITEMS) throw new Error('Invalid source layout page')
      for (const entry of data.entries) {
        onlyKeys(entry,['profileId','profileRevision','name','isPreset','targetDevice','bytes','digest','payloadId','sourceIndex','start','end','payloadGeneration'])
        if (!identity(entry.profileId) || !positive(entry.profileRevision) || typeof entry.name!=='string' || entry.name.length===0 || bytes(entry.name)>256 ||
          typeof entry.isPreset!=='boolean' || !['phone','tablet','foldable','any'].includes(entry.targetDevice) || !positive(entry.bytes) ||
          entry.bytes>LAYOUT_STORAGE_LIBRARY_BYTES || !digest(entry.digest) || !generation(entry.payloadGeneration) ||
          !Number.isSafeInteger(entry.sourceIndex) || entry.sourceIndex < -1 || !Number.isSafeInteger(entry.start) || !Number.isSafeInteger(entry.end) ||
          (entry.sourceIndex>=0 ? !/^source_[0-9]+$/.test(entry.payloadId) : !/^payload_[0-9]+$/.test(entry.payloadId))) throw new Error('Invalid source layout catalog entry')
        const ref: string=entry.payloadGeneration+':'+entry.payloadId
        if (ids.has(entry.profileId) || names.has(entry.name) || refs.has(ref)) throw new Error('Duplicate source layout identity/name/reference')
        ids.add(entry.profileId);names.add(entry.name);refs.add(ref);entries.push(entry)
      }
      if (page+1<root.pageCount ? !digest(data.nextDigest) : data.nextDigest!=='') throw new Error('Source catalog digest termination mismatch')
      next=data.nextDigest
    }
    if (entries.length!==root.count || !ids.has(root.activeProfileId) || entries.reduce((sum: number,entry: SourceEntry): number => sum+entry.bytes,0)!==root.totalBytes) {
      throw new Error('Source layout catalog incomplete')
    }
    const result=new OwnerLayoutSourceRepository(context,preference,root,pointer,source,ranges,entries)
    // 验证所有引用元数据与source范围；独立payload内容仍按方案读取，目录冷启不合成全库字符串。
    for (const entry of entries) {
      if (entry.sourceIndex>=0) result.readEntry(entry)
      else {
        const path: string=OwnerLayoutSourceRepository.directory(context,entry.payloadGeneration)+'/'+entry.payloadId+'.json'
        const stat=fs.lstatSync(path)
        if (!stat.isFile() || stat.size!==entry.bytes) throw new Error('Source layout payload identity missing')
      }
    }
    return result
  }
}
