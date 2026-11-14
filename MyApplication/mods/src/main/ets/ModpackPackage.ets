/**
 * 发现整合包的真实安装入口。将标准目录、启动器内包及完整 PC 实例归一为稳定候选，
 * 不执行 EXE/JAR，不默认选取多实例之一。root 与来源链均相对于本任务工作根，
 * 可随选择持久保存；重试仍须由调用者核验来源摘要并保持工作根的独占所有权。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { ensureDirSync, removeDirRecursive } from 'commons';
import { safeBaseName, safeRelPath, decompressFile, computeFileSha1 } from 'feature_core';
import { ModpackArchiveEntry, ModpackArchiveSummary, preflightModpackArchive } from './ModpackArchive';

export { preflightModpackArchive, ModpackArchiveSummary } from './ModpackArchive';

export interface ModpackPackageSource { path: string; sha1: string; }
export interface ModpackPackageCandidate {
  /** 不透明稳定身份，不能当作文件名拼接路径。 */
  id: string;
  /** modrinth / curseforge / mcbbs / hmcl / multimc / instance / archive（待选择展开）。 */
  kind: string;
  /** 相对于 workRoot 的清单目录或完整实例 Minecraft 根。 */
  root: string;
  title: string;
  versionId?: string;
  /** 相对于 candidate.root 的实际游戏数据根；未指定时由实例适配层提供选择。 */
  gameDir?: string;
  /** 每层内包的工作根相对路径及精确摘要；外层 archive.zip 存在时也计入。 */
  archiveChain?: ModpackPackageSource[];
  /** 延迟展开候选的归档文件（work-relative）；root仍是其所在普通目录。 */
  archivePath?: string;
  /** 即将展开的归档层数；外层已解压目录不算，范围1..4。 */
  archiveDepth?: number;
}
interface PackageMetadata {
  name?: string;
  id?: string;
  game?: string;
  formatVersion?: number;
  manifestVersion?: number;
  manifestType?: string;
  minecraft?: Object;
  addons?: Object[];
  components?: Object[];
  mainClass?: string;
  inheritsFrom?: string;
  patches?: Object[];
  libraries?: Object[];
}
interface TreeFacts { entries: number; bytes: number; }
const MAX_ENTRIES = 200000;
const MAX_BYTES = 16 * 1024 * 1024 * 1024;
const MAX_PAYLOADS = 16;
const MAX_ARCHIVE_DEPTH = 4;
const MAX_DISCOVERY_DEPTH = 8;
const MAX_METADATA = 4 * 1024 * 1024;
/** 这些是实例数据而不是包装层。扫描安全事实仍覆盖全树，入口发现不深入模组/资源。 */
const DATA_DIRECTORIES: string[] = ['mods', 'libraries', 'assets', 'resourcepacks', 'shaderpacks',
  'saves', 'config', 'defaultconfigs', 'kubejs', 'scripts', 'overrides', 'client-overrides',
  'server-overrides', 'runtime', 'runtimes', 'java', 'jdk', '__MACOSX'];

/** 普通文件/目录检查均用 lstat，不跟随从归档或外部替换进来的链接。 */
function regularFile(path: string): boolean {
  try { const stat = fs.lstatSync(path); return stat.isFile() && !stat.isSymbolicLink(); } catch (_) { return false; }
}
function regularDirectory(path: string): boolean {
  try { const stat = fs.lstatSync(path); return stat.isDirectory() && !stat.isSymbolicLink(); } catch (_) { return false; }
}
function pathExists(path: string): boolean {
  try { fs.lstatSync(path); return true; } catch (_) { return false; }
}
/** 只读小型元数据；BOM 在此归一，坏 JSON 不会被当成另一个格式静默安装。 */
function metadata(path: string): PackageMetadata | undefined {
  const stat = fs.lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > MAX_METADATA) throw new Error('整合包清单不是有界普通文件');
  let text = fs.readTextSync(path);
  if (text.charCodeAt(0) === 0xfeff) text = text.substring(1);
  let value: PackageMetadata;
  // 只隔离 JSON 语法/形状错误；文件读取、链接、类型和大小错误仍向上传播，
  // 不允许一个可读性错误被误当作普通旁附元数据而继续使用不可靠的归档。
  try { value = JSON.parse(text) as PackageMetadata; } catch (_) { return undefined; }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return undefined;
  return value;
}
function manifestName(name: string): boolean {
  return ['modrinth.index.json', 'manifest.json', 'mcbbs.packmeta', 'modpack.json', 'mmc-pack.json'].indexOf(name) >= 0;
}

class PackageDiscovery {
  private work_: string;
  private cancelled_: () => boolean;
  private candidates_: ModpackPackageCandidate[] = [];
  private ids_: Set<string> = new Set<string>();
  private archivePaths_: Set<string> = new Set<string>();
  private entries_: number = 0;
  private bytes_: number = 0;
  private payloads_: number = 0;
  private invalidMetadata_: string[] = [];
  constructor(workRoot: string, cancelled: () => boolean) {
    this.work_ = workRoot.endsWith('/') ? workRoot.substring(0, workRoot.length - 1) : workRoot;
    this.cancelled_ = cancelled;
  }
  private check_(): void { if (this.cancelled_()) throw new Error('整合包发现已取消'); }
  private absolute_(relative: string): string {
    if (safeRelPath(relative) !== relative) throw new Error('整合包候选路径不安全');
    let current = this.work_;
    if (!regularDirectory(current)) throw new Error('整合包工作根不是普通目录');
    const parts = relative.split('/');
    for (let index = 0; index < parts.length - 1; index++) {
      current += '/' + parts[index];
      if (!regularDirectory(current)) throw new Error('整合包候选父目录不是普通目录');
    }
    return this.work_ + '/' + relative;
  }
  private budget_(facts: TreeFacts): void {
    this.entries_ += facts.entries; this.bytes_ += facts.bytes;
    if (this.entries_ > MAX_ENTRIES || this.bytes_ > MAX_BYTES) throw new Error('整合包多层累计解压预算超限');
  }
  /** 全树只检查一次安全事实；有中央目录时还逐文件核对大小，拒绝解压遗漏或额外产物。 */
  private scanTree_(root: string, relative: string, facts: TreeFacts, seen: Map<string, number>, depth: number): void {
    this.check_();
    if (depth > 64 || !regularDirectory(root)) throw new Error('整合包产物目录或深度无效');
    for (const name of fs.listFileSync(root)) {
      this.check_();
      if (safeBaseName(name) !== name) throw new Error('整合包产物文件名不安全');
      const rel = relative.length === 0 ? name : relative + '/' + name;
      if (safeRelPath(rel) !== rel) throw new Error('整合包产物相对路径不安全');
      const path = root + '/' + name, stat = fs.lstatSync(path);
      if (stat.isSymbolicLink() || (!stat.isDirectory() && !stat.isFile())) throw new Error('整合包产物包含链接或特殊文件');
      facts.entries++;
      if (facts.entries > MAX_ENTRIES) throw new Error('整合包产物数量超限');
      if (stat.isDirectory()) this.scanTree_(path, rel, facts, seen, depth + 1);
      else { facts.bytes += stat.size; seen.set(rel, stat.size); }
      if (facts.bytes > MAX_BYTES) throw new Error('整合包产物大小超限');
    }
  }
  private verifyTree_(root: string, summary?: ModpackArchiveSummary): TreeFacts {
    const facts: TreeFacts = { entries: 0, bytes: 0 }, seen = new Map<string, number>();
    this.scanTree_(root, '', facts, seen, 0);
    if (summary !== undefined) {
      let files = 0;
      for (const entry of summary.files) {
        if (entry.directory) {
          if (!regularDirectory(root + '/' + entry.path)) throw new Error('解压目录缺失或类型不符：' + entry.path);
          continue;
        }
        files++;
        if (seen.get(entry.path) !== entry.size) throw new Error('解压产物缺失或大小不符：' + entry.path);
      }
      if (seen.size !== files || facts.bytes !== summary.uncompressedBytes || facts.entries !== summary.entries) throw new Error('解压产物与预检清单不一致');
    }
    return facts;
  }
  /** 清单语法错误只记录在当前入口；有其他有效候选时不得让旁附坏配置遮蔽它们。 */
  private metadata_(path: string): PackageMetadata | undefined {
    const value = metadata(path);
    if (value === undefined && this.invalidMetadata_.length < 8) this.invalidMetadata_.push(path.substring(this.work_.length + 1));
    return value;
  }
  private add_(kind: string, root: string, title: string, source: string,
    chain: ModpackPackageSource[], versionId?: string): void {
    // JSON 元组避免 '#'、':' 等合法文件名字符造成身份拼接碰撞；身份不用于路径。
    const id = JSON.stringify([source, kind, versionId ?? '']);
    if (this.ids_.has(id)) return;
    if (this.candidates_.length >= 64) throw new Error('整合包安装候选超过 64 项，请拆分归档');
    this.ids_.add(id);
    const item: ModpackPackageCandidate = { id, kind, root,
      title: title.length > 0 ? title : (versionId ?? kind), archiveChain: chain.slice() };
    if (versionId !== undefined) item.versionId = versionId;
    this.candidates_.push(item);
  }
  /** 双清单优先使用 MCBBS 的完整语义；普通 CF/MR 不因旁附启动器而改变候选。 */
  private direct_(relative: string, source: string, chain: ModpackPackageSource[]): boolean {
    const dir = this.absolute_(relative);
    let found = false;
    let mcbbs = false;
    if (regularFile(dir + '/mcbbs.packmeta')) {
      const value = this.metadata_(dir + '/mcbbs.packmeta');
      if (value !== undefined && Array.isArray(value.addons)) {
        this.add_('mcbbs', relative, value.name ?? '', source + '/mcbbs.packmeta', chain); found = true; mcbbs = true;
      }
    }
    if (!mcbbs && regularFile(dir + '/manifest.json')) {
      const value = this.metadata_(dir + '/manifest.json');
      // 旧 MCBBS 可借用 manifest.json 名称，其 addons 语义不能误送进 CF parser。
      if (value !== undefined && Array.isArray(value.addons)) {
        this.add_('mcbbs', relative, value.name ?? '', source + '/manifest.json', chain); found = true;
      } else if (value !== undefined && value.manifestType === 'minecraftModpack' && value.manifestVersion === 1 && value.minecraft !== undefined) {
        this.add_('curseforge', relative, value.name ?? '', source + '/manifest.json', chain); found = true;
      }
    }
    if (regularFile(dir + '/modrinth.index.json')) {
      const value = this.metadata_(dir + '/modrinth.index.json');
      if (value !== undefined && value.game === 'minecraft' && value.formatVersion === 1) {
        this.add_('modrinth', relative, value.name ?? '', source + '/modrinth.index.json', chain); found = true;
      }
    }
    if (regularFile(dir + '/modpack.json') && regularFile(dir + '/minecraft/pack.json')) {
      const value = this.metadata_(dir + '/modpack.json');
      const game = this.metadata_(dir + '/minecraft/pack.json');
      if (value !== undefined && game !== undefined) {
        this.add_('hmcl', relative, value.name ?? '', source + '/modpack.json', chain); found = true;
      }
    }
    if (regularFile(dir + '/mmc-pack.json') && regularFile(dir + '/instance.cfg')) {
      if (this.metadata_(dir + '/mmc-pack.json') !== undefined) {
        this.add_('multimc', relative, relative.substring(relative.lastIndexOf('/') + 1), source + '/mmc-pack.json', chain); found = true;
      }
    }
    if (regularDirectory(dir + '/versions')) {
      for (const name of fs.listFileSync(dir + '/versions').sort()) {
        this.check_();
        if (safeBaseName(name) !== name || !regularFile(dir + '/versions/' + name + '/' + name + '.json')) continue;
        const value = this.metadata_(dir + '/versions/' + name + '/' + name + '.json');
        if (value === undefined || (value.mainClass === undefined && value.inheritsFrom === undefined && !Array.isArray(value.patches))) continue;
        this.add_('instance', relative, name, source + '/versions/' + name + '/' + name + '.json', chain, name); found = true;
      }
    }
    return found;
  }
  /** 只凭中央目录识别可解释的内包，避免展开根目录附近任意资源 ZIP。 */
  private promising_(summary: ModpackArchiveSummary): boolean {
    return summary.files.some((entry: ModpackArchiveEntry): boolean => {
      const parts = entry.path.split('/'), name = parts[parts.length - 1];
      if (parts.slice(0, parts.length - 1).some((part: string): boolean => DATA_DIRECTORIES.indexOf(part.toLowerCase()) >= 0)) return false;
      if (parts.length <= MAX_DISCOVERY_DEPTH + 1 && manifestName(name)) return true;
      if (name.toLowerCase().endsWith('.mrpack') || name === 'modpack.zip') return true;
      return parts.length >= 3 && parts[parts.length - 3] === 'versions' && name === parts[parts.length - 2] + '.json';
    });
  }
  /**
   * 发现内包先只读预检和绑定压缩字节，不展开也不预扣它的假想展开量。
   * 多个10GiB内包因此仍可先供用户选择；真正选中后才计该分支的展开预算。
   */
  private async payload_(relative: string, source: string, chain: ModpackPackageSource[], depth: number): Promise<void> {
    if (this.archivePaths_.has(relative)) return;
    this.archivePaths_.add(relative); this.check_();
    if (depth > MAX_ARCHIVE_DEPTH || this.payloads_ >= MAX_PAYLOADS) throw new Error('整合包内包层数或数量超限');
    const path = this.absolute_(relative), summary = preflightModpackArchive(path, this.cancelled_);
    if (!this.promising_(summary)) return;
    const sha1 = await computeFileSha1(path); this.check_();
    if (!new RegExp('^[a-fA-F0-9]{40}$').test(sha1)) throw new Error('内包来源摘要无效');
    this.payloads_++;
    const next = chain.concat([{ path: relative, sha1 }]);
    if (next.length > 6) throw new Error('整合包来源链超过6层');
    this.add_('archive', relative.substring(0, relative.lastIndexOf('/')),
      relative.substring(relative.lastIndexOf('/') + 1), source, next);
    const item = this.candidates_[this.candidates_.length - 1];
    item.archivePath = relative; item.archiveDepth = depth;
  }
  /** 所有者已收敛后，只退役当前待展开层及其后继的可再生缓存，不碰来源所在父层。 */
  private retirePayloads_(depth: number, chain: ModpackPackageSource[]): void {
    for (let current = depth; current <= MAX_ARCHIVE_DEPTH; current++) {
      const relative = 'payloads/p' + current.toString();
      const target = this.absolute_(relative);
      for (const source of chain) if (source.path === relative || source.path.startsWith(relative + '/')) throw new Error('内包目标会覆盖来源归档');
      if (pathExists(target)) {
        if (!regularDirectory(target)) throw new Error('内包目标不是普通目录');
        removeDirRecursive(target);
        if (pathExists(target)) throw new Error('旧内包缓存仍被占用，无法安全展开');
      }
    }
  }
  private identitySource_(candidate: ModpackPackageCandidate): string {
    let tuple: string[];
    try { tuple = JSON.parse(candidate.id) as string[]; } catch (_) { throw new Error('内包候选身份无效'); }
    if (!Array.isArray(tuple) || tuple.length !== 3 || typeof tuple[0] !== 'string' || tuple[1] !== 'archive') throw new Error('内包候选身份不符');
    return tuple[0];
  }
  /** 所选来源链必须仍是当时的压缩字节；不能在暂停后把替换文件重新合法化。 */
  private async verifyChain_(chain: ModpackPackageSource[]): Promise<void> {
    if (chain.length === 0 || chain.length > 6) throw new Error('整合包来源链为空或超限');
    for (const source of chain) {
      this.check_();
      if (!new RegExp('^[a-fA-F0-9]{40}$').test(source.sha1)) throw new Error('整合包来源摘要无效');
      const path = this.absolute_(source.path);
      if (!regularFile(path) || (await computeFileSha1(path)).toLowerCase() !== source.sha1.toLowerCase()) throw new Error('所选整合包来源在等待选择期间发生变化');
    }
  }
  /** 只计已经存在的外层及选中来源链上的父层，未选内包没有被展开也不消耗展开预算。 */
  private chargeExisting_(chain: ModpackPackageSource[]): void {
    const outer = regularFile(this.work_ + '/archive.zip') ? preflightModpackArchive(this.work_ + '/archive.zip', this.cancelled_) : undefined;
    this.budget_(this.verifyTree_(this.work_ + '/extracted', outer));
    let depth = 0;
    for (let index = 0; index < chain.length - 1; index++) {
      const source = chain[index];
      if (source.path === 'archive.zip') continue;
      depth++;
      const summary = preflightModpackArchive(this.absolute_(source.path), this.cancelled_);
      this.budget_(this.verifyTree_(this.work_ + '/payloads/p' + depth.toString(), summary));
    }
  }
  /** 用户明确选择后才展开一个分支；唯一子包继续，多子候选重新返回选择层。 */
  async materialize(candidate: ModpackPackageCandidate): Promise<ModpackPackageCandidate[]> {
    this.check_();
    if (candidate.kind !== 'archive') return [candidate];
    const relative = candidate.archivePath ?? '', depth = candidate.archiveDepth ?? 0;
    const chain = candidate.archiveChain ?? [];
    if (safeRelPath(relative) !== relative || !Number.isSafeInteger(depth) || depth < 1 || depth > MAX_ARCHIVE_DEPTH
      || chain.length === 0 || chain[chain.length - 1].path !== relative) throw new Error('延迟展开候选路径或深度无效');
    const sourceCount = chain.filter((source: ModpackPackageSource): boolean => source.path !== 'archive.zip').length;
    if (sourceCount !== depth) throw new Error('内包深度与来源链不一致');
    const source = this.identitySource_(candidate);
    await this.verifyChain_(chain); this.check_();
    const path = this.absolute_(relative), summary = preflightModpackArchive(path, this.cancelled_);
    if (!this.promising_(summary)) throw new Error('所选归档不再包含可识别的整合包');
    ensureDirSync(this.work_ + '/payloads');
    this.retirePayloads_(depth, chain);
    this.chargeExisting_(chain);
    this.budget_({ entries: summary.entries, bytes: summary.uncompressedBytes });
    const sha1 = chain[chain.length - 1].sha1;
    const root = 'payloads/p' + depth.toString();
    const target = this.absolute_(root);
    if (pathExists(target) && !regularDirectory(target)) throw new Error('内包目标不是普通目录');
    // 目标只属于当前发现者，调用者必须先结束旧解压 owner；失败现场保留供恢复/诊断。
    if (pathExists(target)) removeDirRecursive(target);
    ensureDirSync(target);
    await decompressFile(path, target);
    // 平台没有取消句柄：先等其 Promise 收敛，再检查取消；不能提前释放/删除目标。
    this.check_();
    if ((await computeFileSha1(path)).toLowerCase() !== sha1.toLowerCase()) throw new Error('内包在展开期间发生变化');
    const actual = this.verifyTree_(target, summary);
    // 预留使用中央目录推导的含隐式父目录数量；实际扫描事实仍参与累计补差，
    // 即使以后验证策略允许额外空目录，也不能悄悄漏记它们的资源成本。
    this.budget_({ entries: Math.max(0, actual.entries - summary.entries),
      bytes: Math.max(0, actual.bytes - summary.uncompressedBytes) });
    this.check_();
    await this.walk_(root, source, chain, 0, depth);
    return this.finish_();
  }
  private async walk_(relative: string, source: string, chain: ModpackPackageSource[], level: number, archiveDepth: number): Promise<void> {
    this.check_();
    if (level > MAX_DISCOVERY_DEPTH) return;
    const path = this.absolute_(relative);
    const found = this.direct_(relative, source, chain);
    const names = fs.listFileSync(path).sort();
    const zipNames = names.filter((name: string): boolean => name.toLowerCase().endsWith('.zip') && regularFile(path + '/' + name));
    const launcher = names.some((name: string): boolean => regularFile(path + '/' + name)
      && (name.toLowerCase().endsWith('.exe') || new RegExp('(hmcl|pcl|launcher).*\\.jar$', 'i').test(name)));
    for (const name of names) {
      this.check_();
      const next = relative + '/' + name, entrySource = source + '/' + name;
      if (regularFile(path + '/' + name)) {
        const lower = name.toLowerCase();
        const known = lower === 'modpack.zip' || lower.endsWith('.mrpack');
        const singleWrappedZip = !found && launcher && zipNames.length === 1 && lower.endsWith('.zip');
        if (known || singleWrappedZip) await this.payload_(next, entrySource, chain, archiveDepth + 1);
      } else if (regularDirectory(path + '/' + name) && name !== 'versions'
        && DATA_DIRECTORIES.indexOf(name.toLowerCase()) < 0) {
        await this.walk_(next, entrySource, chain, level + 1, archiveDepth);
      }
    }
  }
  async run(): Promise<ModpackPackageCandidate[]> {
    this.check_();
    if (!regularDirectory(this.work_ + '/extracted')) throw new Error('整合包外层尚未安全解压');
    const chain: ModpackPackageSource[] = [];
    let summary: ModpackArchiveSummary | undefined = undefined;
    if (regularFile(this.work_ + '/archive.zip')) {
      summary = preflightModpackArchive(this.work_ + '/archive.zip', this.cancelled_);
      const digest = await computeFileSha1(this.work_ + '/archive.zip'); this.check_();
      if (!new RegExp('^[a-fA-F0-9]{40}$').test(digest)) throw new Error('外层归档摘要无效');
      chain.push({ path: 'archive.zip', sha1: digest });
    }
    const facts = this.verifyTree_(this.work_ + '/extracted', summary);
    // 外层只计一次实际树；内包声明量在解压前累计，验证实际树时不重复扣除同一份预算。
    this.budget_(facts);
    await this.walk_('extracted', 'outer', chain, 0, 0);
    return this.finish_();
  }
  private async finish_(): Promise<ModpackPackageCandidate[]> {
    if (this.candidates_.length === 0 && this.invalidMetadata_.length > 0) {
      throw new Error('未找到有效整合包候选，清单 JSON 无效：' + this.invalidMetadata_.join('、'));
    }
    if (this.candidates_.length === 1 && this.candidates_[0].kind === 'archive') {
      // 使用新的计数器，从真实已展开链重新计量，避免唯一连续内包重复计外层预算。
      return new PackageDiscovery(this.work_, this.cancelled_).materialize(this.candidates_[0]);
    }
    return this.candidates_;
  }
}

/**
 * 调用者需独占 workRoot 且已完成外层预检/解压。多候选完整返回给选择层；没有候选返回空数组。
 * 唯一归档自动展开保持单包行为；存在多个入口时，archive候选仅绑定摘要，等待明确选择。
 * 失败或取消保留精确材料，不在本层删除外层归档、用户实例或执行任何平台启动器。
 */
export async function discoverModpackPackages(workRoot: string, cancelled: () => boolean): Promise<ModpackPackageCandidate[]> {
  return new PackageDiscovery(workRoot, cancelled).run();
}

/**
 * 仅展开用户选定的归档候选；多个子候选完整返回给选择层。调用者须先结束旧平台owner，
 * 且保留archivePath/archiveDepth/archiveChain用于暂停恢复，不能只持久化显示标题。
 */
export async function materializeModpackPackage(workRoot: string, candidate: ModpackPackageCandidate,
  cancelled: () => boolean): Promise<ModpackPackageCandidate[]> {
  return new PackageDiscovery(workRoot, cancelled).materialize(candidate);
}
