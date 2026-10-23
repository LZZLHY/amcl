/**
 * 导出源的只读 I/O 边界。只访问固定游戏根、版本描述及用户选定的数据，不启动游戏、
 * 不修复文件、不创建源目录。枚举与摘要使用异步 FileIO；检查失败必须向上报告。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { resolveInstanceGameDir } from 'commons';
import { ExportRequest, ExportIssue, ExportVersionSource, ExportResolvedVersion, ExportInventoryFile,
  ExportDependency, ExportPath, safeBaseName, safeRelPath, ExportContentTree, ExportContentItem,
  createExportContentTree, addExportContentItem, finalizeExportContentTree, exportContentStandardDefault,
  ExportContentSelectionEvaluator, validateExportSelection } from 'feature_core';
import { ExportFileHashes, hashExportFile, hashExportDependencyFile } from './ExportArchiveIO';

/** 仅保存真实源字节事实；依赖期望及候选选择仍由每次检查独立判断。 */
interface ExportCheckDigestEntry { identity: string; digest: ExportFileHashes; }

/**
 * fd与路径比较沿用摘要读取的inode/size/时间戳语义。只有同时具备SDK的两个纳秒字段时
 * 才允许复用；旧系统的秒级字段只用于本次fresh读取前后核验，不能充当memo命中依据。
 * Stat不提供dev，不能通过虚构设备号或仅inode合并不同root/relative来源。
 */
function checkDigestIdentity(stat: fs.Stat): string {
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('检查摘要输入不是普通文件');
  return String(stat.ino) + ':' + stat.size + ':' + String(stat.mtimeNs ?? stat.mtime) + ':' + String(stat.ctimeNs ?? stat.ctime);
}

/** SDK纳秒字段是epoch bigint；缺失/零占位及无效inode都不能形成强身份。 */
function preciseCheckDigestIdentity(stat: fs.Stat): boolean {
  return typeof stat.ino === 'bigint' && stat.ino > 0n && typeof stat.mtimeNs === 'bigint' && stat.mtimeNs > 0n &&
    typeof stat.ctimeNs === 'bigint' && stat.ctimeNs > 0n;
}

/** 缺纳秒时只做本次打开/读取的保守身份比较，不因此升级为可复用身份。 */
function sameCheckDigestFile(left: fs.Stat, right: fs.Stat): boolean {
  checkDigestIdentity(left); checkDigestIdentity(right);
  if (left.ino !== right.ino || left.size !== right.size || left.mtime !== right.mtime || left.ctime !== right.ctime) return false;
  if (typeof left.mtimeNs === 'bigint' && typeof right.mtimeNs === 'bigint' && left.mtimeNs !== right.mtimeNs) return false;
  if (typeof left.ctimeNs === 'bigint' && typeof right.ctimeNs === 'bigint' && left.ctimeNs !== right.ctimeNs) return false;
  return true;
}

/**
 * 只由一次checkPlan栈内创建的摘要上下文，不写草稿/preview/record，不跨检查共享。
 * 命中也必须重做路径链、READ_ONLY|NOFOLLOW打开、fd/path身份和close；省略的仅是重复
 * 正文读取及SHA计算，不能把它当源目录已冻结、权限永远有效或候选永远合格的证明。
 * 执行/准备/冻结/快照调用不传此实例，继续独立fresh读取和原三重摘要复核。
 */
export class ExportCheckDigestContext {
  private readonly entries_: Map<string, ExportCheckDigestEntry> = new Map<string, ExportCheckDigestEntry>();
  private readonly purpose_: 'all' | 'sha1';

  /**
   * 用途在实例构造时固定，hash调用不接受切换参数，避免同一memo混入不同算法的结果。
   * 默认all保留既有API和双摘要调用；仅依赖预览的局部上下文显式选择sha1。
   */
  constructor(purpose: 'all' | 'sha1' = 'all') {
    if (purpose !== 'all' && purpose !== 'sha1') throw new Error('检查摘要用途无效');
    this.purpose_ = purpose;
  }

  /** fresh与命中后精度丢失的补读使用同一固定用途；不会把弱身份升级为可复用身份。 */
  private async fresh_(path: string, cancelled: () => boolean): Promise<ExportFileHashes> {
    return this.purpose_ === 'sha1' ? await hashExportDependencyFile(path, cancelled) : await hashExportFile(path, cancelled);
  }

  /** 缺失、存在性检查失败或取消也撤销旧字节事实；不把曾经存在当作当前可读证明。 */
  invalidate(root: string, relative: string): void { this.entries_.delete(root + '\u0000' + relative); }

  /** 选择可能检查多个真实alias；取消整个选择时撤销本局部上下文，不能只清归档目标键。 */
  invalidateAll(): void { this.entries_.clear(); }

  /**
   * root与relative均为本次真实读取来源。NUL在现有路径规则中被拒绝，可安全分隔两部分，
   * 不按目标路径、digest或inode猜等价性。任何异常会撤销旧memo；关闭成功和最终取消
   * 检查之后才重新登记字节事实，避免close/I/O失败仍留下可复用条目。
   * @throws 路径、打开、stat、hash、关闭、身份变化和取消错误均交给checkPlan负责人。
   */
  async hash(root: string, relative: string, cancelled: () => boolean): Promise<ExportFileHashes> {
    const key = root + '\u0000' + relative;
    const cached = this.entries_.get(key);
    this.entries_.delete(key);
    if (cancelled()) throw new Error('已请求取消');
    await assertExportPath(root, relative);
    const path = root + '/' + relative;
    const beforePath = await fs.lstat(path);
    const identity = checkDigestIdentity(beforePath);
    const precise = preciseCheckDigestIdentity(beforePath);
    if (cancelled()) throw new Error('已请求取消');
    const opened = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    let digest: ExportFileHashes | undefined = undefined;
    let reusable = false;
    try {
      const beforeFd = await fs.stat(opened.fd);
      if (!sameCheckDigestFile(beforePath, beforeFd)) throw new Error('检查摘要打开期间源文件发生变化：' + relative);
      const preciseFd = preciseCheckDigestIdentity(beforeFd);
      if (cancelled()) throw new Error('已请求取消');
      // 每次仍实际打开只读fd确认当前可读性；没有纳秒身份就调用原摘要owner，不能用
      // 秒级mtime/ctime冒充同秒等长改写的证据。缓存不保存“依赖校验通过”的布尔结果。
      const reused = precise && preciseFd && cached !== undefined && cached.identity === identity;
      digest = reused && cached !== undefined ? cached.digest : await this.fresh_(path, cancelled);
      if (cancelled()) throw new Error('已请求取消');
      await assertExportPath(root, relative);
      const afterFd = await fs.stat(opened.fd);
      const afterPath = await fs.lstat(path);
      if (!sameCheckDigestFile(beforePath, afterFd) || !sameCheckDigestFile(beforePath, afterPath) || digest.size !== afterPath.size) {
        throw new Error('检查摘要期间源文件发生变化：' + relative);
      }
      reusable = precise && preciseFd && preciseCheckDigestIdentity(afterFd) && preciseCheckDigestIdentity(afterPath);
      if (reused && !reusable) {
        // 命中判定之后，后置fd/path若失去纳秒强身份，旧digest已没有充分的本轮证明。
        // 不能只禁止“下一次复用”却仍把旧值返回。至多追加一次真实fresh摘要，并在同一
        // 校验fd仍打开时重新核验路径与fd；即使精度随后恢复，本次也不重新登记memo。
        // 全程无重试循环，fresh读取/close/取消失败继续抛给原检查owner。
        digest = await this.fresh_(path, cancelled);
        if (cancelled()) throw new Error('已请求取消');
        await assertExportPath(root, relative);
        const freshAfterFd = await fs.stat(opened.fd);
        const freshAfterPath = await fs.lstat(path);
        if (!sameCheckDigestFile(beforePath, freshAfterFd) || !sameCheckDigestFile(beforePath, freshAfterPath) ||
          digest.size !== freshAfterPath.size) throw new Error('检查摘要fresh复核期间源文件发生变化：' + relative);
        reusable = false;
      }
    } finally { await fs.close(opened); }
    if (cancelled()) throw new Error('已请求取消');
    if (digest === undefined) throw new Error('检查摘要没有取得完整字节事实');
    if (reusable) this.entries_.set(key, { identity, digest: { size: digest.size, sha1: digest.sha1, sha256: digest.sha256 } });
    // 调用方只能取得值副本，不能修改后来复用的SHA/长度事实。
    return { size: digest.size, sha1: digest.sha1, sha256: digest.sha256 };
  }
}

/** 只有 ENOENT 表示不存在，权限撤销、设备错误和不可读目录不能退化为空结果。 */
export async function exportPathExists(path: string): Promise<boolean> {
  try { await fs.lstat(path); return true; }
  catch (error) { if ((error as BusinessError).code === 13900002) return false; throw error as Error; }
}

/** 沿根以内的每个分量检查链接；末端打开还使用 NOFOLLOW，避免导出应用私有区以外的内容。 */
export async function assertExportPath(root: string, relative: string = ''): Promise<void> {
  if (!root.startsWith('/') || root.indexOf('\u0000') >= 0 || root.split('/').some((s: string): boolean => s === '..' || s === '.')) {
    throw new Error('源游戏目录不是规范的绝对路径');
  }
  if (relative.length > 0 && safeRelPath(relative) !== relative) throw new Error('导出文件含不安全的相对路径');
  let current = '';
  for (const part of root.split('/').filter((s: string): boolean => s.length > 0)) {
    current += '/' + part;
    const stat = await fs.lstat(current);
    if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error('源游戏目录含链接或不是目录');
  }
  const parts = relative.length > 0 ? relative.split('/') : [];
  for (let index = 0; index < parts.length; index++) {
    current += '/' + parts[index];
    const stat = await fs.lstat(current);
    if (stat.isSymbolicLink() || (index < parts.length - 1 && !stat.isDirectory())) {
      throw new Error('导出范围含链接或特殊目录：' + relative);
    }
    if (!stat.isDirectory() && !stat.isFile()) throw new Error('导出不支持特殊文件：' + relative);
  }
}

/** 元数据有大小上限，防止把异常文件作为 JSON 一次读入界面进程。 */
export async function readExportText(root: string, relative: string): Promise<string> {
  await assertExportPath(root, relative);
  const stat = await fs.lstat(root + '/' + relative);
  if (!stat.isFile() || stat.size <= 0 || stat.size > 32 * 1024 * 1024) throw new Error('版本或资产清单大小无效：' + relative);
  return await fs.readText(root + '/' + relative);
}

/** 读取一般继承链而非调用 OHOS 启动解析器；保留原 JSON 正文用于冻结前再核对。 */
export async function readExportVersions(root: string, versionId: string): Promise<ExportVersionSource[]> {
  const sources: ExportVersionSource[] = [];
  let next = versionId;
  while (next.length > 0) {
    if (safeBaseName(next) !== next) throw new Error('版本身份不安全');
    if (sources.some((s: ExportVersionSource): boolean => s.id === next)) throw new Error('版本继承出现循环');
    if (sources.length >= 32) throw new Error('版本继承层数过深');
    const text = await readExportText(root, 'versions/' + next + '/' + next + '.json');
    const obj = JSON.parse(text) as Record<string, Object>;
    if (obj === null || Array.isArray(obj)) throw new Error('版本 JSON 不是对象');
    sources.push({ id: next, jsonText: text });
    const parent = obj['inheritsFrom'];
    if (parent !== undefined && typeof parent !== 'string') throw new Error('版本继承身份无效');
    next = typeof parent === 'string' ? parent : '';
  }
  return sources;
}

/** 这些是运行库、共享依赖、启动器身份和安装控制资料，不是可勾选的用户游戏内容。 */
export function isExportControlPath(relative: string, request: ExportRequest): boolean {
  if (ExportPath.excluded(relative)) return true;
  const lower = relative.toLowerCase();
  const parts = lower.split('/');
  const first = parts[0];
  if (parts.some((p: string): boolean => p.startsWith('.amcl') || p.startsWith('lwjgl-ohos') ||
    p.endsWith('.amcl.part') || p.endsWith('.download-meta') || p === 'stub-objc-bridge.jar' ||
    p === 'launcher_accounts.json' || p === 'accounts.json' || p === 'usercache.json' ||
    p === 'launcher_profiles.json' || p === 'launcher_msa_credentials.bin' || p === 'hmcl_accounts.json' || p === 'microsoft_accounts.json' ||
    p === 'pcl' || p === '.hmcl' || p === 'session.lock')) return true;
  if (['versions', 'libraries', 'assets', 'natives', 'download-temp', 'forge-proc-tmp', 'launcher_log.txt',
    'forge-installer.log', 'mc_output.log', 'hs_err_pid.log'].indexOf(first) >= 0) return true;
  // 仅排除已确认的根级安装控制资料：安装器失败可遗留解压目录与下载JAR，旧bootstrapper
  // 已退役。不要泛化匹配installer/forge或日志后缀，以免吞掉mods/config中的用户内容。
  // neoforge-installer.jar.log尚无直接生产证据，本轮不把它或所有.log扩为控制项。
  if (['forge-install-temp', 'neoforge-installer.jar', 'forge-install-bootstrapper.jar'].indexOf(first) >= 0) return true;
  if (first === request.versionId.toLowerCase() + '.json' || first === request.versionId.toLowerCase() + '.jar') return true;
  return false;
}

/** 首层库存供向导明确勾选；存档单独逐世界选择，日志/截图/服务器文件不会混在默认内容中。 */
export interface ExportContentChoices { directories: string[]; files: string[]; worlds: string[]; }
export async function discoverExportContent(request: ExportRequest): Promise<ExportContentChoices> {
  await assertExportPath(request.gameDir);
  const result: ExportContentChoices = { directories: [], files: [], worlds: [] };
  for (const name of (await fs.listFile(request.gameDir)).sort()) {
    if (safeBaseName(name) !== name || isExportControlPath(name, request)) continue;
    await assertExportPath(request.gameDir, name);
    const stat = await fs.lstat(request.gameDir + '/' + name);
    if (name === 'saves' && stat.isDirectory()) {
      for (const world of (await fs.listFile(request.gameDir + '/saves')).sort()) {
        await assertExportPath(request.gameDir, 'saves/' + world);
        if ((await fs.lstat(request.gameDir + '/saves/' + world)).isDirectory()) result.worlds.push(world);
      }
    } else if (stat.isDirectory()) result.directories.push(name);
    else if (stat.isFile()) result.files.push(name);
  }
  return result;
}

/** 专门分组的细范围先从通用config/其它资料中扣出，防父目录选择遮盖其取消。 */
const CONTENT_PARTITIONS: string[] = ['config/jei/world', 'config/tacz/custom',
  'journeymap/config', 'journeymap/server', 'journeymap/data'];

/** 发现取消不降为某个空分类；只在正在进行的SDK调用返回后由同一owner检查并退出。 */
function contentActive(cancelled: () => boolean): void { if (cancelled()) throw new Error('已请求取消内容发现'); }

/** SDK异常正文可能包含绝对路径；分类原因只保留明确的安全分类和数值错误码。 */
function contentReadFailure(error: Error): string {
  const code = (error as BusinessError).code;
  return typeof code === 'number' ? '无法读取，错误码 ' + code : '读取失败，可能存在链接、特殊文件或目录变化';
}

/**
 * 轻量内容树发现，不计算正文hash。包和世界目录只查是否有普通可导出内容；完整目录
 * 仍由最终inventory在选中后重新读取。读取错误保留path身份，不能伪装成empty。
 * @throws 根目录不可读和取消终止整个发现；分支失败留下error单元供重试/明确排除。
 */
export async function discoverExportContentTree(request: ExportRequest,
  cancelled: () => boolean = (): boolean => false): Promise<ExportContentTree> {
  contentActive(cancelled); await assertExportPath(request.gameDir);
  const tree = createExportContentTree();
  const seen = new Set<string>();
  let visited = 0;
  const emit = (item: ExportContentItem): void => {
    if (!seen.has(item.path)) { seen.add(item.path); addExportContentItem(tree, item); }
  };
  const failed = (path: string, kind: 'directory' | 'file' | 'world', error: Error): void => {
    contentActive(cancelled);
    const reason = contentReadFailure(error);
    emit({ id: 'item:' + path, path, label: path.substring(path.lastIndexOf('/') + 1), kind,
      defaultSelected: exportContentStandardDefault(path), available: false, reason });
    tree.issues.push({ code: 'CONTENT_DISCOVERY_ERROR', severity: 'warning', message: reason, path });
  };
  const isPartition = (root: string, path: string): boolean => CONTENT_PARTITIONS.some((entry: string): boolean =>
    entry !== root && (path === entry || path.startsWith(entry + '/')));
  const hasContent = async (path: string, root: string, depth: number): Promise<boolean> => {
    contentActive(cancelled);
    if (++visited > 200000 || depth > 64) throw new Error('内容发现超出安全规模');
    if (isExportControlPath(path, request) || isPartition(root, path)) return false;
    await assertExportPath(request.gameDir, path);
    const stat = await fs.lstat(request.gameDir + '/' + path); contentActive(cancelled);
    if (stat.isFile()) return true;
    if (!stat.isDirectory()) throw new Error('内容不是普通文件或目录');
    for (const name of (await fs.listFile(request.gameDir + '/' + path)).sort()) {
      contentActive(cancelled);
      if (safeBaseName(name) !== name) throw new Error('内容名称不安全');
      if (await hasContent(path + '/' + name, root, depth + 1)) return true;
    }
    return false;
  };
  const unit = async (path: string, world: boolean = false, optional: boolean = false,
    expectedKind: 'directory' | 'file' | 'world' = 'directory'): Promise<ExportContentItem | undefined> => {
    contentActive(cancelled);
    if (isExportControlPath(path, request)) return undefined;
    let observed = false;
    let kind: 'directory' | 'file' | 'world' = world ? 'world' : expectedKind;
    try {
      if (!ExportPath.relative(path)) throw new Error('内容名称不能在电脑目标安全保存');
      // 先核所有祖先再lstat末端，不先穿过祖先链接探测存在性。已枚举来源的ENOENT是
      // 发现竞态，必须留下错误范围；仅固定可选partition从未观察到时的缺失可视为不存在。
      await assertExportPath(request.gameDir, path.substring(0, path.lastIndexOf('/')));
      const stat = await fs.lstat(request.gameDir + '/' + path); observed = true; contentActive(cancelled);
      kind = world ? 'world' : stat.isDirectory() ? 'directory' : 'file';
      if (stat.isSymbolicLink()) throw new Error('导出范围含链接或特殊目录：' + path);
      if (world && !stat.isDirectory()) throw new Error('世界不是完整目录');
      if (!stat.isFile() && !stat.isDirectory()) throw new Error('内容不是普通文件');
      if (stat.isDirectory() && !(await hasContent(path, path, 0))) return undefined;
      const item: ExportContentItem = { id: 'item:' + path, path,
        label: path.substring(path.lastIndexOf('/') + 1), kind,
        defaultSelected: exportContentStandardDefault(path), available: true, reason: '' };
      if (stat.isFile()) item.size = stat.size;
      return item;
    } catch (error) {
      contentActive(cancelled);
      if (optional && !observed && (error as BusinessError).code === 13900002) return undefined;
      failed(path, kind, error as Error); return undefined;
    }
  };
  const children = async (root: string, worlds: boolean = false): Promise<void> => {
    try {
      await assertExportPath(request.gameDir, root);
      const stat = await fs.lstat(request.gameDir + '/' + root);
      if (!stat.isDirectory()) throw new Error('内容分类不是目录');
      const found: ExportContentItem[] = [];
      for (const name of (await fs.listFile(request.gameDir + '/' + root)).sort()) {
        contentActive(cancelled);
        if (safeBaseName(name) !== name) { failed(root, 'directory', new Error('内容名称不安全')); continue; }
        const path = root + '/' + name;
        if (worlds) {
          try {
            await assertExportPath(request.gameDir, path);
            if (!(await fs.lstat(request.gameDir + '/' + path)).isDirectory()) continue;
            tree.worlds.push(name);
          } catch (error) { contentActive(cancelled); failed(path, 'world', error as Error); continue; }
        }
        const item = await unit(path, worlds); if (item !== undefined) found.push(item);
      }
      const foundPaths = new Set<string>(found.map((item: ExportContentItem): string => item.path));
      for (const item of found) {
        if (root === 'shaderpacks' && item.kind === 'file' && item.path.endsWith('.txt')) {
          const packPath = item.path.substring(0, item.path.length - '.txt'.length);
          if (foundPaths.has(packPath)) item.associatedPath = packPath;
          else item.defaultSelected = false; // 未绑定到包的附加文本只在full或用户明确选择时带入。
        }
        emit(item);
      }
    } catch (error) { contentActive(cancelled); failed(root, 'directory', error as Error); }
  };
  const roots = (await fs.listFile(request.gameDir)).sort(); contentActive(cancelled);
  for (const name of roots) {
    contentActive(cancelled);
    if (safeBaseName(name) !== name || isExportControlPath(name, request)) continue;
    try {
      await assertExportPath(request.gameDir, name);
      const stat = await fs.lstat(request.gameDir + '/' + name); contentActive(cancelled);
      if (stat.isDirectory()) tree.directories.push(name); else if (stat.isFile()) tree.files.push(name);
      if (['mods', 'coremods', 'lib', 'resourcepacks', 'texturepacks', 'shaderpacks', 'schematics',
        'replay_recordings', 'replay_videos', 'saves'].indexOf(name) >= 0) await children(name, name === 'saves');
      else { const item = await unit(name, false, false, stat.isFile() ? 'file' : 'directory'); if (item !== undefined) emit(item); }
    } catch (error) { contentActive(cancelled); failed(name, 'directory', error as Error); }
  }
  for (const path of CONTENT_PARTITIONS) { const item = await unit(path, false, true); if (item !== undefined) emit(item); }
  contentActive(cancelled);
  return finalizeExportContentTree(tree);
}

/** 固定源位置；请求中的 gameDir/shared 标记不能被手改草稿带离标准实例目录。 */
export async function validateExportRequest(request: ExportRequest): Promise<void> {
  // 私有草稿也可能因截断或旧schema损坏，JSON强转不提供运行时形状保证。
  if (request === null || typeof request !== 'object' ||
    typeof request.mcRoot !== 'string' || typeof request.versionId !== 'string' || typeof request.gameDir !== 'string' ||
    typeof request.exportId !== 'string' || typeof request.displayName !== 'string' || typeof request.sharedGameDir !== 'boolean' ||
    ['full', 'modrinth', 'curseforge'].indexOf(request.format) < 0 || ['pcl', 'hmcl'].indexOf(request.launcher) < 0 ||
    request.platform === null || typeof request.platform !== 'object' ||
    ['windows', 'linux', 'osx'].indexOf(request.platform.os) < 0 || ['x64', 'arm64', 'x86'].indexOf(request.platform.arch) < 0 ||
    typeof request.platform.version !== 'string' || !Array.isArray(request.includeDirectories) || !Array.isArray(request.includeFiles) ||
    !Array.isArray(request.selectedWorlds) || request.includeDirectories.concat(request.includeFiles).concat(request.selectedWorlds)
      .some((value: string): boolean => typeof value !== 'string')) throw new Error('导出请求或草稿格式无效，请重新选择');
  const selectionIssues = validateExportSelection(request);
  if (selectionIssues.length > 0) throw new Error(selectionIssues[0].message);
  if (safeBaseName(request.versionId) !== request.versionId || request.versionId.length === 0) throw new Error('未选择有效版本');
  await assertExportPath(request.mcRoot);
  const isolated = request.mcRoot + '/versions/' + request.versionId;
  if (request.gameDir !== request.mcRoot && request.gameDir !== isolated) throw new Error('导出实例目录与版本不匹配');
  if (request.sharedGameDir !== (request.gameDir === request.mcRoot)) throw new Error('共享目录状态已变化，请重新打开导出');
  // 整合包的强制隔离不能被旧草稿撤销。
  if (resolveInstanceGameDir(request.mcRoot, request.versionId, request.gameDir === isolated) !== request.gameDir) {
    throw new Error('实例隔离策略已变化，请重新打开导出');
  }
  await assertExportPath(request.gameDir);
}

/**
 * 递归读取只包含勾选的树；空目录保留，所有实际字节建立摘要。目录增删由执行前/冻结后
 * 重建同一清单比较发现，不能仅核对已经存在的文件而漏掉新建或删除的子项。
 */
export async function inventoryExportContent(request: ExportRequest, cancelled: () => boolean): Promise<ExportInventoryFile[]> {
  const issues = validateExportSelection(request);
  if (issues.length > 0) throw new Error(issues[0].message);
  const result: ExportInventoryFile[] = [];
  const evaluator = new ExportContentSelectionEvaluator(request);
  const selected: Map<string, string> = new Map<string, string>();
  const selectedFiles = new Set<string>(request.includeFiles);
  for (const name of request.includeDirectories.concat(request.includeFiles)) {
    if ((request.selectionVersion !== 2 && safeBaseName(name) !== name) || name === 'saves' || isExportControlPath(name, request)) throw new Error('内容选择包含控制目录或无效名称');
    if (evaluator.isSelected(name)) selected.set(name, selectedFiles.has(name) ? 'file' : 'directory');
  }
  for (const world of request.selectedWorlds) {
    if (safeBaseName(world) !== world || world.length === 0) throw new Error('存档名称无效');
    if (evaluator.isSelected('saves/' + world)) selected.set('saves/' + world, 'directory');
  }
  const accepted = new Set<string>();
  for (const relative of Array.from(selected.keys()).sort()) {
    let parent = relative.substring(0, relative.lastIndexOf('/'));
    let covered = false;
    while (parent.length > 0) {
      if (accepted.has(parent)) { covered = true; break; }
      parent = parent.substring(0, parent.lastIndexOf('/'));
    }
    if (covered) continue;
    await inventoryTree(request, relative, result, cancelled, evaluator, selected.get(relative) || '');
    if (selected.get(relative) === 'directory') accepted.add(relative);
  }
  return result.sort((a: ExportInventoryFile, b: ExportInventoryFile): number => a.path.localeCompare(b.path));
}

/** 文件读前后 lstat 加摘要复核；符号链接及特殊文件一律阻断，绝不跟随到其他资料。 */
async function inventoryTree(request: ExportRequest, relative: string, result: ExportInventoryFile[], cancelled: () => boolean,
  evaluator: ExportContentSelectionEvaluator, expectedKind: string = ''): Promise<void> {
  if (cancelled()) throw new Error('已请求取消');
  if (isExportControlPath(relative, request)) return;
  // 宽目录的真实枚举可能出现目标无法表达的名称。求值器的false不是用户排除证据，
  // 不能把不安全项当未勾选静默跳过；精确合法子集及显式排除的父范围不会走到此项。
  if (!ExportPath.relative(relative)) throw new Error('所选范围包含电脑目标不支持的不安全名称：' + relative);
  if (!evaluator.isSelected(relative)) return;
  if (result.length >= 200000) throw new Error('导出条目超过 200000，请减少内容范围');
  await assertExportPath(request.gameDir, relative);
  const before = await fs.lstat(request.gameDir + '/' + relative);
  if ((expectedKind === 'directory' && !before.isDirectory()) || (expectedKind === 'file' && !before.isFile())) throw new Error('所选资料类型已变化：' + relative);
  if (before.isDirectory()) {
    result.push({ path: relative, directory: true, size: 0, sha1: '', sha256: '' });
    for (const child of (await fs.listFile(request.gameDir + '/' + relative)).sort()) {
      await inventoryTree(request, relative + '/' + child, result, cancelled, evaluator);
    }
  } else {
    const digest = await hashExportFile(request.gameDir + '/' + relative, cancelled);
    const after = await fs.lstat(request.gameDir + '/' + relative);
    if (before.size !== after.size || before.mtime !== after.mtime || before.ino !== after.ino || digest.size !== after.size) {
      throw new Error('检查期间文件发生变化：' + relative);
    }
    result.push({ path: relative, directory: false, size: digest.size, sha1: digest.sha1, sha256: digest.sha256 });
  }
}

/** 核验可信元数据摘要，缺少摘要的旧库只可作为明确的未知来源项，不能静默算作完整。 */
export async function inspectExportDependency(root: string, dependency: ExportDependency,
  cancelled: () => boolean, checkContext?: ExportCheckDigestContext): Promise<boolean> {
  if (cancelled()) { checkContext?.invalidate(root, dependency.path); throw new Error('已请求取消'); }
  try {
    const exists = await exportPathExists(root + '/' + dependency.path);
    if (cancelled()) { checkContext?.invalidate(root, dependency.path); throw new Error('已请求取消'); }
    if (!exists) {
      checkContext?.invalidate(root, dependency.path); return false;
    }
  } catch (error) { checkContext?.invalidate(root, dependency.path); throw error as Error; }
  let digest: ExportFileHashes;
  if (checkContext !== undefined) digest = await checkContext.hash(root, dependency.path, cancelled);
  else {
    await assertExportPath(root, dependency.path);
    // 此检查只比对可信SHA1和长度；执行/冻结阶段仍由原快照owner独立计算双摘要。
    digest = await hashExportDependencyFile(root + '/' + dependency.path, cancelled);
  }
  if (dependency.size > 0 && digest.size !== dependency.size) return false;
  if (dependency.sha1.length > 0 && digest.sha1 !== dependency.sha1.toLowerCase()) return false;
  return digest.size > 0;
}

/**
 * 历史资源可能保存在AMCL命名目录、官方virtual目录或objects仓。候选仅改变读取来源，
 * 不改变归档目标；逐项按同一可信摘要/长度核对，首选缺失或损坏时才尝试后继。权限/IO
 * 错误仍向上传播，不能借回退把不可读来源当不存在。返回值由计划负责人固定到sourcePath。
 * @throws 来源越界、链接、不可读及取消错误由预览/执行负责人展示。
 */
export async function selectExportDependencySource(root: string, dependency: ExportDependency,
  cancelled: () => boolean, checkContext?: ExportCheckDigestContext): Promise<string | undefined> {
  if (cancelled()) { checkContext?.invalidateAll(); throw new Error('已请求取消'); }
  const candidates = dependency.sourceCandidates ?? [dependency.sourcePath ?? dependency.path];
  try {
    for (const path of candidates) {
      const source: ExportDependency = { path, url: dependency.url, sha1: dependency.sha1,
        size: dependency.size, kind: dependency.kind, generated: dependency.generated };
      if (await inspectExportDependency(root, source, cancelled, checkContext)) return path;
    }
    return undefined;
  } catch (error) {
    // 已检查的候选可能与dependency.path完全不同；取消撤销本次选择的全部旧事实，
    // 不能让显式继续使用同一个context的调用者借alias命中已取消操作的旧memo。
    // 已捕获的真实I/O首因不能被“查询是否取消”这一次回调异常覆盖。探测本身失败时
    // 同样撤销旧事实，但仍抛原异常；入口探测的独立异常由调用方/批次边界正常处理。
    let interrupted = true;
    try { interrupted = cancelled(); } catch (_) { /* 无法确认取消状态，保守撤销本轮memo。 */ }
    if (interrupted) checkContext?.invalidateAll();
    throw error as Error;
  }
}

/**
 * 只读依赖检查的有界批次。最多四个worker调用原单项选择器，每项候选仍按声明顺序
 * 核验完整路径、只读fd、前后身份及各自期望摘要；不缓存“依赖通过”或放宽强身份。
 * 结果按输入index发布，完成顺序不会改变调用方的错误顺序、候选身份或缺件顺序。
 *
 * 首次I/O错误或取消只停止本批新派发，并向已入场项传入本批取消信号。worker自己接住
 * 异常后退出，所以Promise.all只等待全部真实close/Native release，不会首错提前返回。
 * drain后才抛最先触发停止的原始错误，不能被其它项随后出现的取消错误覆盖；失败后撤销
 * 此局部context的事实，避免已完成项在其它在途项收口后留下迟到memo。
 */
export async function selectExportDependencySources(root: string, dependencies: ExportDependency[],
  cancelled: () => boolean, checkContext?: ExportCheckDigestContext): Promise<(string | undefined)[]> {
  const results: (string | undefined)[] = dependencies.map((): undefined => undefined);
  let next = 0;
  let stopped = false;
  let failed = false;
  let failure: Error = new Error('依赖检查未完成');
  const stop = (error: Object | null | undefined): void => {
    // SDK端口或调用方取消回调也可能拒绝null/undefined/原始值。对上层保证Error形状，
    // 避免页面读message再次抛错；已有Error保留原实例及code，后续取消不能覆盖首因。
    if (!failed) { failed = true; failure = error instanceof Error ? error : new Error('依赖检查返回了非Error异常'); }
    stopped = true;
  };
  const interrupted = (): boolean => stopped || cancelled();
  const worker = async (): Promise<void> => {
    while (!stopped) {
      try {
        if (cancelled()) { stop(new Error('已请求取消')); return; }
        const index = next++;
        if (index >= dependencies.length) return;
        results[index] = await selectExportDependencySource(root, dependencies[index], interrupted, checkContext);
        if (cancelled()) { stop(new Error('已请求取消')); return; }
      } catch (error) { stop(error as Object); return; }
    }
  };
  const workers: Promise<void>[] = [];
  for (let index = 0; index < Math.min(4, dependencies.length); index++) workers.push(worker());
  await Promise.all(workers);
  try { if (!failed && cancelled()) stop(new Error('已请求取消')); }
  catch (error) { stop(error as Object); }
  if (failed) { checkContext?.invalidateAll(); throw failure; }
  return results;
}

/** 对 UI 统一暴露可读问题，第三方异常正文不带入将被打包的说明。 */
export function exportIssue(code: string, message: string, path: string = '', warning: boolean = false): ExportIssue {
  return { code, message, path, severity: warning ? 'warning' : 'error' };
}
