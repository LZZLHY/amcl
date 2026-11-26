/**
 * 整合包持久安装计划。网络任务与 ArkUI 页面分离后，所有重试/恢复都按同一份计划执行。
 * 文件位于 filesDir/modpack-work/<id>/session.json，实例只保存 pending 所有者和最终收据。
 * 原子保存失败必须向上传播，不能将缺少恢复记录的安装报告为完整成功。
 */
import { fileIo as fs, hash } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ensureDirSync, hasPendingModpackInstall, removeDirRecursive } from 'commons';
import { safeBaseName, safeRelPath } from 'feature_core';
import { ModpackPlan, ModpackProblem } from './ModpackManifest';
import { ModpackPackageCandidate } from './ModpackPackage';
import { ModpackOverrideJournalRef, ModpackJournalPorts,
  assertNoModpackJournalWriter, readModpackJournalSession,
  recoverModpackJournalSession, bindModpackJournalClose } from './ModpackOverrideJournal';

/**
 * 单次覆盖的写前记录。source 是覆盖层与相对路径，区分 overrides/client-overrides。
 * 在 rename 前持久化前后摘要；重启时目标只能匹配其中之一，否则保留用户修改并停止。
 */
export interface ModpackOverrideReceipt {
  path: string;
  source: string;
  previousSha1: string;
  sha1: string;
  committed: boolean;
}

/** 持久字段必须能纯 JSON 序列化，不保存页面、仓库或 UI 回调。 */
export interface ModpackInstallSession {
  /** 可选以兼容旧记录；true 冻结本安装的正文来源限制，重启恢复不能退回第三方镜像。 */
  officialFilesOnly?: boolean;
  schemaVersion: number;
  id: string;
  mcDir: string;
  versionName: string;
  /** 下载详情中选定的名称意图；最终预约目录名仍由 versionName 保存，旧记录允许缺省。 */
  requestedVersionName?: string;
  plan: ModpackPlan;
  warnings: string[];
  missing: ModpackProblem[];
  selectedOptional: string[];
  confirmed: boolean;
  baseReady: boolean;
  overridesApplied: boolean;
  complete: boolean;
  installedFiles: string[];
  overrideFiles: string[];
  /** 旧会话没有此字段时按保守内容检查迁移，不猜测旧文件的归属。 */
  overrideReceipts?: ModpackOverrideReceipt[];
  /** 历史 schema 2 基座的短日志引用；主线只兼容读取和显式归并，普通保存不可改写。 */
  overrideJournal?: ModpackOverrideJournalRef;
  projectId: string;
  sourceVersionId: string;
  archiveSha1: string;
  archiveSize: number;
  iconUrl: string;
  createdAt: number;
  /** 包装发现的稳定候选与用户选择；旧会话缺省时仍按原已解析计划恢复。 */
  packageCandidates?: ModpackPackageCandidate[];
  /** 初始选择入口独立保留；下钻或坏内包解析失败后仍能冷恢复并改选同包其他客户端。 */
  packageOrigins?: ModpackPackageCandidate[];
  selectedPackageId?: string;
  packageReady?: boolean;
  /** 相对于任务工作根的有效载荷根及外层归档摘要，避免重启后重新猜选来源。 */
  packageRoot?: string;
  packageArchiveSha1?: string;
}

/** 仅供恢复入口显示；完整计划只在用户选择任务后读取。 */
export interface ModpackRecoveryItem {
  id: string;
  title: string;
  mcDir: string;
  versionName: string;
  missingCount: number;
  confirmed: boolean;
}

/** 由实例提交收据决定确认文案，不能用清单是否确认推断实例已交付。 */
export type ModpackRecoveryKind = 'install' | 'repair';

interface ModpackRecoveryDismissal {
  schemaVersion: number;
  id: string;
  kind: ModpackRecoveryKind;
}

const RECOVERY_DISMISSAL = 'dismissed.json';
/** 与当前 Registry 位于同一线程；挡住等待取消期间打开的第二个恢复入口。 */
const dismissingRecoveries: Set<string> = new Set<string>();

/** 清单尚未可用时也保存来源，下载/解压中途退出后可继续同一归档。 */
export interface ModpackSourceReceipt {
  /** 归档尚未解析时也保留正文来源约束；与内容身份分开记录，仍允许自家网关。 */
  officialFilesOnly?: boolean;
  schemaVersion: number;
  id: string;
  mcDir: string;
  title: string;
  /** 归档尚未解析时也保存名称，关闭详情或进程退出后继续原安装意图。 */
  requestedVersionName?: string;
  archivePath?: string;
  archiveUrl?: string;
  archiveMirrors?: string[];
  archiveSha1?: string;
  archiveSha512?: string;
  archiveSize?: number;
  projectId?: string;
  sourceVersionId?: string;
  iconUrl?: string;
}

/** 同步写入小型 JSON，关闭/刷盘完成后再原子替换；异常保留旧记录。 */
export function writeModpackJsonAtomic(path: string, value: Object): void {
  writeModpackTextAtomic(path, JSON.stringify(value));
}

/**
 * 在同目录写入并刷盘后原子替换。旧 WAL 的归并及放弃标记使用受监控的关闭器，
 * 关闭失败不得继续提交。普通会话可选择取得本次独占暂存的 inode 身份，
 * 供其下一次保存确认磁盘仍是上次已知的 schema 1 快照。
 */
function writeModpackTextAtomic(path: string, text: string, closeJournalFile?: (file: fs.File) => void,
  rememberIdentity: boolean = false): string {
  let temp = path + '.writing';
  let handle: fs.File | undefined = undefined;
  let identity = '';
  try {
    handle = fs.openSync(temp, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW);
    let bytes = new util.TextEncoder().encodeInto(text);
    let written = fs.writeSync(handle.fd, bytes.buffer);
    if (written !== bytes.byteLength) throw new Error('整合包恢复记录写入不完整');
    fs.fsyncSync(handle.fd);
    if (rememberIdentity) identity = sessionFileIdentity(path, fs.lstatSync(temp));
    const finished = handle;
    handle = undefined;
    if (closeJournalFile !== undefined) closeJournalFile(finished);
    else fs.closeSync(finished);
    fs.renameSync(temp, path);
    let directory = fs.openSync(path.substring(0, path.lastIndexOf('/')), fs.OpenMode.READ_ONLY);
    try { fs.fsyncSync(directory.fd); } finally {
      if (closeJournalFile !== undefined) closeJournalFile(directory);
      else fs.closeSync(directory);
    }
  } finally {
    if (handle !== undefined) {
      if (closeJournalFile !== undefined) closeJournalFile(handle);
      else fs.closeSync(handle);
    }
  }
  // rename 会改变部分文件系统的 ctime。确认 inode 仍是本次暂存后再记最终身份，
  // 避免把未知路径替换误记为本轮的已知快照；缺少纳秒属性时下次仍重新校验。
  if (rememberIdentity && identity.length > 0) {
    const published = sessionFileIdentity(path, fs.lstatSync(path));
    if (published.length > 0 && identity.slice(0, identity.lastIndexOf('|')) === published.slice(0, published.lastIndexOf('|')))
      return published;
  }
  return '';
}

/** 只按合法任务 ID 构造工作根，不接受来源清单中的任意绝对路径。 */
export function modpackWorkDir(filesDir: string, id: string): string {
  if (safeBaseName(id) !== id || id.length === 0) throw new Error('整合包安装身份不安全');
  return filesDir + '/modpack-work/' + id;
}

/** 新安装目录尚不存在时也可查询。读取异常必须向上传递，避免把已放弃任务误判可继续。 */
export function readModpackRecoveryDismissal(filesDir: string, id: string): ModpackRecoveryKind | undefined {
  const path = modpackWorkDir(filesDir, id) + '/' + RECOVERY_DISMISSAL;
  if (!fs.accessSync(path)) return undefined;
  const stat = fs.lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('整合包放弃记录不是普通文件');
  const record = JSON.parse(fs.readTextSync(path)) as ModpackRecoveryDismissal;
  if (record === null || record.schemaVersion !== 1 || record.id !== id ||
    (record.kind !== 'install' && record.kind !== 'repair')) throw new Error('整合包放弃记录损坏');
  return record.kind;
}

/** 只有启动/恢复入口需要核对内存锁和持久记录，浏览页可按候选摘要展示。 */
export function assertModpackRecoveryAvailable(filesDir: string, id: string): void {
  if (dismissingRecoveries.has(modpackWorkDir(filesDir, id))) throw new Error('正在停止这项整合包安装');
  if (readModpackRecoveryDismissal(filesDir, id) !== undefined) throw new Error('这项整合包安装已放弃');
}

/** 调用方从发起取消前持有到持久记录与清理完成，所有失败路径都交还同一会话。 */
export function claimModpackRecoveryDismissal(filesDir: string, id: string): () => void {
  const work = modpackWorkDir(filesDir, id);
  if (dismissingRecoveries.has(work)) throw new Error('正在停止这项整合包安装');
  dismissingRecoveries.add(work);
  return (): void => { dismissingRecoveries.delete(work); };
}

/** 工作根由应用独占；禁止把链接当成任务目录，避免标记写入或清理越界。 */
function requireModpackDismissalWorkDir(filesDir: string, id: string): string {
  const work = modpackWorkDir(filesDir, id);
  for (const path of [filesDir + '/modpack-work', work]) {
    const stat = fs.lstatSync(path);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('整合包工作目录不是普通目录');
  }
  return work;
}

/** 停止动作完成后才写入；保留原来源/计划，以便必要时辨认未交付实例的原归属。 */
export function saveModpackRecoveryDismissal(filesDir: string, id: string, kind: ModpackRecoveryKind): void {
  const work = requireModpackDismissalWorkDir(filesDir, id);
  assertNoModpackJournalWriter(work, id);
  const previous = readModpackRecoveryDismissal(filesDir, id);
  if (previous === kind) return;
  if (previous !== undefined) throw new Error('整合包放弃记录的身份已改变');
  const temp = RECOVERY_DISMISSAL + '.writing';
  if (fs.listFileSync(work).indexOf(temp) >= 0) {
    const stat = fs.lstatSync(work + '/' + temp);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('整合包放弃记录暂存不是普通文件');
  }
  const record: ModpackRecoveryDismissal = { schemaVersion: 1, id: id, kind: kind };
  // 放弃标记也使用当前会话的 FD 关闭记录，不能让关闭失败越过后续清理屏障。
  journalPorts(work, id).writeText(work + '/' + RECOVERY_DISMISSAL, JSON.stringify(record));
}

/** 用户从已装实例再次选择补齐，才允许撤销该会话的补齐关闭记录。 */
export function clearModpackRepairDismissal(filesDir: string, id: string): void {
  const work = requireModpackDismissalWorkDir(filesDir, id);
  assertNoModpackJournalWriter(work, id);
  if (readModpackRecoveryDismissal(filesDir, id) !== 'repair') throw new Error('当前记录不允许重新补齐');
  const close = bindModpackJournalClose(work, id);
  fs.unlinkSync(work + '/' + RECOVERY_DISMISSAL);
  const directory = fs.openSync(work, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
  try { fs.fsyncSync(directory.fd); } finally { close(directory); }
}

/** 是否留下覆盖日志原件或 schema2 引用。完整读取失败时不能按仅有来源的旧会话继续提交。 */
export function hasModpackOverrideJournalEvidence(filesDir: string, id: string): boolean {
  if (!fs.accessSync(modpackWorkDir(filesDir, id))) return false;
  const work = requireModpackDismissalWorkDir(filesDir, id);
  const names = fs.listFileSync(work);
  if (names.some((name: string): boolean => name.startsWith('.override-'))) return true;
  if (names.indexOf('session.json') < 0) return false;
  const raw = fs.readTextSync(work + '/session.json');
  try {
    const value = JSON.parse(raw) as ModpackInstallSession;
    return value !== null && (value.schemaVersion === 2 || value.overrideJournal !== undefined);
  } catch (_) { return false; }
}

/** 旧版选择器把输入放在工作目录之外。只对正在收尾的旧来源核实字节及其他使用者，普通安装不扫描。 */
export async function releaseLegacyModpackImport(filesDir: string, id: string, knownPath?: string): Promise<boolean> {
  const root = filesDir + '/modpack-import';
  try {
    let archive = knownPath;
    if (archive === undefined) {
      if (!fs.accessSync(modpackWorkDir(filesDir, id) + '/source.json')) return true;
      archive = loadModpackSource(filesDir, id).archivePath ?? '';
    }
    if (!archive.startsWith(root + '/')) return true;
    const parts = archive.substring(root.length + 1).split('/');
    if (parts.length !== 2 || !/^\d+-\d+-\d+$/.test(parts[0]) || !parts[1] ||
      safeBaseName(parts[1]) !== parts[1] || !/\.(zip|mrpack)$/i.test(parts[1])) return false;
    if (!fs.accessSync(archive)) return true;
    const folder = root + '/' + parts[0];
    const work = requireModpackDismissalWorkDir(filesDir, id);
    const staged = work + '/archive.zip';
    const original = fs.lstatSync(archive);
    const parent = fs.lstatSync(folder);
    const base = fs.lstatSync(root);
    if (!base.isDirectory() || !parent.isDirectory() || !original.isFile() || !fs.lstatSync(staged).isFile()) return false;
    const match = await hash.hash(staged, 'sha256');
    if (!match || match !== await hash.hash(archive, 'sha256')) return false;
    for (const other of fs.listFileSync(filesDir + '/modpack-work')) {
      if (other === id) continue;
      const sibling = modpackWorkDir(filesDir, other);
      if (!fs.accessSync(sibling + '/source.json') || readModpackRecoveryDismissal(filesDir, other) !== undefined) continue;
      if (loadModpackSource(filesDir, other).archivePath === archive) return true;
    }
    const current = fs.lstatSync(archive);
    if (fs.lstatSync(root).ino !== base.ino || fs.lstatSync(folder).ino !== parent.ino ||
      current.ino !== original.ino || current.size !== original.size ||
      (current.ctimeNs ?? current.ctime) !== (original.ctimeNs ?? original.ctime)) return false;
    fs.unlinkSync(archive);
    if (fs.lstatSync(folder).ino === parent.ino && fs.listFileSync(folder).length === 0) fs.rmdirSync(folder);
    return true;
  } catch (_) { return false; }
}

/** 仅处理已写入放弃记录的私有暂存。旧来源不明也应清理能确认归属的任务缓存。 */
export async function cleanupDismissedModpackWork(filesDir: string, id: string): Promise<boolean> {
  try {
    const work = requireModpackDismissalWorkDir(filesDir, id);
    if (readModpackRecoveryDismissal(filesDir, id) === undefined) return false;
    const inputReleased = await releaseLegacyModpackImport(filesDir, id);
    const keep: string[] = [RECOVERY_DISMISSAL, 'session.json', 'source.json'];
    // 保留所有覆盖日志目录。冷恢复需要原字节，且无法把孤立代次当作可清理的网络缓存。
    const retain = (name: string): boolean => keep.indexOf(name) >= 0 || name.startsWith('.override-');
    for (const name of fs.listFileSync(work)) {
      if (retain(name)) continue;
      if (safeBaseName(name) !== name || name.length === 0) return false;
      const path = work + '/' + name;
      const stat = fs.lstatSync(path);
      if (stat.isDirectory() && !stat.isSymbolicLink()) removeDirRecursive(path);
      else fs.unlinkSync(path);
    }
    // 既有目录清理工具容忍单文件删除失败，必须实际重读确认清理结果。
    return fs.listFileSync(work).every(retain) && inputReleased;
  } catch (_) { return false; }
}

export function saveModpackSession(filesDir: string, session: ModpackInstallSession): void {
  let dir = modpackWorkDir(filesDir, session.id);
  ensureDirSync(dir);
  assertNoModpackJournalWriter(dir, session.id);
  if (session.schemaVersion !== 1 || session.overrideJournal !== undefined
    || diskUsesJournal(dir, verifiedSchemaOne.get(session))) throw new Error('覆盖日志会话须先重新读取并恢复，不能直接保存');
  const identity = writeModpackTextAtomic(dir + '/session.json', JSON.stringify(session), undefined, true);
  if (identity.length > 0) verifiedSchemaOne.set(session, identity);
  else verifiedSchemaOne.delete(session);
}

export function saveModpackSource(filesDir: string, source: ModpackSourceReceipt): void {
  let dir = modpackWorkDir(filesDir, source.id);
  ensureDirSync(dir);
  assertNoModpackJournalWriter(dir, source.id);
  if (diskUsesJournal(dir)) throw new Error('覆盖日志会话活跃，不能改写来源');
  writeModpackJsonAtomic(dir + '/source.json', source);
}

/** 仅本轮活跃会话能复用它刚刚持久化的 schema 1 身份；回收会话时不积累历史缓存。 */
const verifiedSchemaOne: WeakMap<ModpackInstallSession, string> = new WeakMap<ModpackInstallSession, string>();

/** inode、大小和纳秒时间全匹配才可跳过解析；未知平台回退到完整 schema 检查。 */
function sessionFileIdentity(path: string, stat: fs.Stat): string {
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('整合包恢复计划不是普通文件');
  const inode = String(stat.ino);
  if (!/^[1-9][0-9]*$/.test(inode)) return '';
  try {
    const modified = stat.mtimeNs;
    const changed = stat.ctimeNs;
    if (modified === undefined || changed === undefined) return '';
    return path + '|' + inode + '|' + stat.size + '|' + String(modified) + '|' + String(changed);
  } catch (_) { return ''; }
}

/** 未知磁盘身份须重新判断；损坏或孤立日志不能被普通保存覆盖成新会话。 */
function diskUsesJournal(directory: string, knownIdentity?: string): boolean {
  const path = directory + '/session.json';
  if (!fs.accessSync(path)) return fs.listFileSync(directory).some((name: string): boolean =>
    name === 'session.json' || name.startsWith('.override-'));
  const identity = sessionFileIdentity(path, fs.lstatSync(path));
  if (identity.length > 0 && knownIdentity === identity) return false;
  const previous = JSON.parse(fs.readTextSync(path)) as ModpackInstallSession;
  return previous?.schemaVersion !== 1 || previous.overrideJournal !== undefined;
}

/** 具名class落实method-signature接口，避免ArkTS把返回的函数literal判成无类型对象。 */
class SessionJournalPorts implements ModpackJournalPorts {
  private close: (file: fs.File) => void;

  constructor(directory: string, id: string) { this.close = bindModpackJournalClose(directory, id); }
  validate(value: ModpackInstallSession, id: string): ModpackInstallSession { return validateModpackSession(value, id); }

  writeText(path: string, text: string): void {
    writeModpackTextAtomic(path, text, this.close);
  }
}

function journalPorts(directory: string, id: string): ModpackJournalPorts {
  return new SessionJournalPorts(directory, id);
}

/** 写消费者显式重放旧 WAL，耐久归并为 schema 1 后才交给主线原有安装器。 */
export function recoverModpackSessionForWrite(filesDir: string, id: string): ModpackInstallSession {
  const directory = requireModpackDismissalWorkDir(filesDir, id);
  return recoverModpackJournalSession(directory, id, journalPorts(directory, id));
}

export function loadModpackSource(filesDir: string, id: string): ModpackSourceReceipt {
  let source = JSON.parse(fs.readTextSync(modpackWorkDir(filesDir, id) + '/source.json')) as ModpackSourceReceipt;
  if (source === null || source.schemaVersion !== 1 || source.id !== id || typeof source.mcDir !== 'string'
    || typeof source.title !== 'string') throw new Error('整合包来源恢复记录损坏');
  if (source.officialFilesOnly !== undefined && typeof source.officialFilesOnly !== 'boolean')
    throw new Error('整合包来源策略损坏');
  if (source.requestedVersionName !== undefined && (typeof source.requestedVersionName !== 'string'
    || source.requestedVersionName.length === 0 || safeBaseName(source.requestedVersionName) !== source.requestedVersionName)) {
    throw new Error('整合包来源名称意图损坏');
  }
  return source;
}

/** 恢复时重新检查路径和结构；版本名为空表示尚未预约实例目录。 */
export function loadModpackSession(filesDir: string, id: string): ModpackInstallSession {
  const directory = requireModpackDismissalWorkDir(filesDir, id);
  const path = directory + '/session.json';
  const stat = fs.lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('整合包恢复计划不是普通文件');
  const raw = fs.readTextSync(path);
  const value = JSON.parse(raw) as ModpackInstallSession;
  if (value?.schemaVersion === 2) return readModpackJournalSession(directory, raw, id, journalPorts(directory, id));
  return validateModpackSession(value, id);
}

/** schema1原有完整验证仅保留这一份；schema2精确基座与重放结果均重新走此门。 */
function validateModpackSession(value: ModpackInstallSession, id: string): ModpackInstallSession {
  if (value === null || value.schemaVersion !== 1 || value.overrideJournal !== undefined || value.id !== id || typeof value.mcDir !== 'string'
    || value.mcDir.length === 0 || !Array.isArray(value.plan?.files) || !Array.isArray(value.missing)
    || !Array.isArray(value.selectedOptional) || !Array.isArray(value.overrideFiles)
    || !Array.isArray(value.installedFiles) || !Array.isArray(value.warnings)) throw new Error('整合包恢复计划损坏');
  if (value.officialFilesOnly !== undefined && typeof value.officialFilesOnly !== 'boolean')
    throw new Error('整合包恢复来源策略损坏');
  if (typeof value.versionName !== 'string' || (value.versionName.length > 0 && safeBaseName(value.versionName) !== value.versionName)) {
    throw new Error('整合包恢复版本名不安全');
  }
  if (value.requestedVersionName !== undefined
    && (typeof value.requestedVersionName !== 'string' || value.requestedVersionName.length === 0
      || safeBaseName(value.requestedVersionName) !== value.requestedVersionName)) {
    throw new Error('整合包恢复名称意图不安全');
  }
  for (let file of value.plan.files) {
    // 尚未解析成功的 CF 条目允许 path 空；其他路径必须保持 canonical 相对路径。
    if (file.path.length > 0 && safeRelPath(file.path) !== file.path) throw new Error('整合包恢复文件路径不安全');
  }
  for (let dir of value.plan.overrideDirs) {
    // 点号仅在覆盖目录协议中表示已绑定有效载荷根，不改变通用文件相对路径规则。
    if (dir !== '.' && safeRelPath(dir) !== dir) throw new Error('整合包恢复覆盖路径不安全');
  }
  if (value.packageRoot !== undefined && safeRelPath(value.packageRoot) !== value.packageRoot)
    throw new Error('整合包恢复载荷根不安全');
  if (value.packageArchiveSha1 !== undefined && !/^[a-f0-9]{40}$/.test(value.packageArchiveSha1))
    throw new Error('整合包恢复来源摘要无效');
  if (value.packageCandidates !== undefined) {
    if (!Array.isArray(value.packageCandidates) || value.packageCandidates.length > 64)
      throw new Error('整合包恢复候选列表无效');
    const identities = new Set<string>();
    for (const candidate of value.packageCandidates) {
      if (typeof candidate.id !== 'string' || candidate.id.length === 0 || identities.has(candidate.id)
        || typeof candidate.root !== 'string' || safeRelPath(candidate.root) !== candidate.root
        || ['modrinth', 'curseforge', 'mcbbs', 'hmcl', 'multimc', 'instance', 'archive'].indexOf(candidate.kind) < 0
        || (candidate.gameDir !== undefined && candidate.gameDir !== '.' && safeRelPath(candidate.gameDir) !== candidate.gameDir))
        throw new Error('整合包恢复候选身份或路径无效');
      identities.add(candidate.id);
      if (candidate.kind === 'archive' && (candidate.archivePath === undefined
        || safeRelPath(candidate.archivePath) !== candidate.archivePath
        || !Number.isInteger(candidate.archiveDepth ?? 0) || (candidate.archiveDepth ?? 0) < 1 || (candidate.archiveDepth ?? 0) > 4))
        throw new Error('整合包恢复内包候选位置或深度无效');
      if (candidate.archiveChain !== undefined) {
        if (!Array.isArray(candidate.archiveChain) || candidate.archiveChain.length > 6)
          throw new Error('整合包恢复来源链无效');
        for (const link of candidate.archiveChain) {
          if (typeof link.path !== 'string' || safeRelPath(link.path) !== link.path || !/^[a-f0-9]{40}$/.test(link.sha1))
            throw new Error('整合包恢复来源链路径或摘要无效');
        }
      }
    }
    if (value.selectedPackageId !== undefined && value.selectedPackageId.length > 0
      && !identities.has(value.selectedPackageId)) throw new Error('整合包恢复选择不属于原始候选');
    if (value.packageReady === true) {
      const selected = value.packageCandidates.find((candidate: ModpackPackageCandidate): boolean => candidate.id === value.selectedPackageId);
      if (selected === undefined || value.packageRoot !== selected.root || value.plan.source !== selected.kind)
        throw new Error('整合包恢复计划与已选有效载荷不一致');
      if ((selected.kind === 'instance' || selected.kind === 'multimc') && selected.gameDir !== undefined
        && value.plan.overrideDirs.indexOf(selected.gameDir) < 0)
        throw new Error('整合包恢复游戏数据根与选择不一致');
    }
  }
  if (value.packageOrigins !== undefined) {
    if (!Array.isArray(value.packageOrigins) || value.packageOrigins.length === 0 || value.packageOrigins.length > 64)
      throw new Error('整合包原始候选列表无效');
    for (const candidate of value.packageOrigins) {
      if (typeof candidate.id !== 'string' || candidate.id.length === 0 || safeRelPath(candidate.root) !== candidate.root
        || ['modrinth', 'curseforge', 'mcbbs', 'hmcl', 'multimc', 'instance', 'archive'].indexOf(candidate.kind) < 0)
        throw new Error('整合包原始候选身份无效');
      if (candidate.archivePath !== undefined && safeRelPath(candidate.archivePath) !== candidate.archivePath)
        throw new Error('整合包原始内包路径无效');
      for (const link of candidate.archiveChain ?? []) {
        if (safeRelPath(link.path) !== link.path || !/^[a-f0-9]{40}$/.test(link.sha1))
          throw new Error('整合包原始来源链无效');
      }
    }
  }
  for (let rel of value.installedFiles.concat(value.overrideFiles)) {
    if (safeRelPath(rel) !== rel) throw new Error('整合包恢复收据路径不安全');
  }
  if (value.overrideReceipts !== undefined) {
    if (!Array.isArray(value.overrideReceipts)) throw new Error('覆盖恢复记录损坏');
    for (let record of value.overrideReceipts) {
      if (safeRelPath(record.path) !== record.path || safeRelPath(record.source) !== record.source
        || !new RegExp('^[a-f0-9]{40}$').test(record.sha1)
        || (record.previousSha1 !== '' && !new RegExp('^[a-f0-9]{40}$').test(record.previousSha1))
        || typeof record.committed !== 'boolean') throw new Error('覆盖恢复摘要不安全');
    }
  }
  return value;
}

/** 浏览器只从原子基座取展示字段。schema 2 的 WAL 只补覆盖路径和收据，不改变这些字段。
 * 工作线程不打开由主线程管理的 journal 句柄，否则关闭不确定性无法约束原 writer。
 * 候选身份仍由实际恢复入口在写入前完整校验，列表读取不消费或修改原会话。
 */
export function loadRecoveryPreview(filesDir: string, id: string): ModpackInstallSession {
  const path = requireModpackDismissalWorkDir(filesDir, id) + '/session.json';
  const stat = fs.lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('整合包恢复摘要不是普通文件');
  const value = JSON.parse(fs.readTextSync(path)) as ModpackInstallSession;
  if ((value?.schemaVersion !== 1 && value?.schemaVersion !== 2) || value.id !== id
    || typeof value.mcDir !== 'string' || value.mcDir.length === 0
    || typeof value.versionName !== 'string' || (value.versionName.length > 0 && safeBaseName(value.versionName) !== value.versionName)
    || typeof value.plan?.name !== 'string' || !Array.isArray(value.missing)
    || typeof value.confirmed !== 'boolean' || typeof value.complete !== 'boolean') {
    throw new Error('整合包恢复摘要无效');
  }
  return value;
}

/** 完整列表调用仍复用原校验，保证现有业务调用不会悄悄降级为预览。 */
export function listModpackRecovery(filesDir: string): ModpackRecoveryItem[] {
  return collectModpackRecovery(filesDir, loadModpackSession);
}

/** 仅供浏览器工作线程读取候选；取消发生在会话边界，不返回半份列表。 */
export function listModpackRecoveryPreview(filesDir: string, shouldStop: () => boolean): ModpackRecoveryItem[] {
  return collectModpackRecovery(filesDir, loadRecoveryPreview, shouldStop);
}

/** 共用完成态、实例 pending 和仅有来源记录的判据。损坏记录保留原件。 */
function collectModpackRecovery(filesDir: string, readSession: (filesDir: string, id: string) => ModpackInstallSession,
  shouldStop?: () => boolean): ModpackRecoveryItem[] {
  let result: ModpackRecoveryItem[] = [];
  let entries: string[] = [];
  try { entries = fs.listFileSync(filesDir + '/modpack-work'); } catch (e) { return result; }
  for (let id of entries) {
    if (shouldStop?.()) return [];
    // 先读放弃状态，避免未装完的源记录通过回退分支重新进入恢复列表。
    try { if (readModpackRecoveryDismissal(filesDir, id) !== undefined) continue; }
    catch (_) { continue; }
    try {
      let session = readSession(filesDir, id);
      // 收据提交与移除 pending 之间可能进程退出；完成标志不能掩盖仍待收尾的实例。
      if (session.complete && session.missing.length === 0
        && (session.versionName.length === 0 || !hasPendingModpackInstall(session.mcDir + '/versions/' + session.versionName))) continue;
      result.push({ id: id, title: session.plan.name, mcDir: session.mcDir,
        versionName: session.versionName, missingCount: session.missing.length, confirmed: session.confirmed });
    } catch (e) {
      // 下载/解压阶段还没有 session，只要来源记录完整，就可恢复归档准备过程。
      try {
        let source = loadModpackSource(filesDir, id);
        result.push({ id: id, title: source.title, mcDir: source.mcDir, versionName: '', missingCount: 0, confirmed: false });
      } catch (sourceError) { /* 不自动删除无法识别的历史证据。 */ }
    }
  }
  return result;
}
