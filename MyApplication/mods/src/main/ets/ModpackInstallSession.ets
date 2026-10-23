/**
 * 整合包持久安装计划。网络任务与 ArkUI 页面分离后，所有重试/恢复都按同一份计划执行。
 * 文件位于 filesDir/modpack-work/<id>/session.json，实例只保存 pending 所有者和最终收据。
 * 原子保存失败必须向上传播，不能将缺少恢复记录的安装报告为完整成功。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ensureDirSync, hasPendingModpackInstall } from 'commons';
import { safeBaseName, safeRelPath } from 'feature_core';
import { ModpackPlan, ModpackProblem } from './ModpackManifest';

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
  projectId: string;
  sourceVersionId: string;
  archiveSha1: string;
  archiveSize: number;
  iconUrl: string;
  createdAt: number;
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

/** 清单尚未可用时也保存来源，下载/解压中途退出后可继续同一归档。 */
export interface ModpackSourceReceipt {
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
  let temp = path + '.writing';
  let handle: fs.File | undefined = undefined;
  try {
    handle = fs.openSync(temp, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    let bytes = new util.TextEncoder().encodeInto(JSON.stringify(value));
    let written = fs.writeSync(handle.fd, bytes.buffer);
    if (written !== bytes.byteLength) throw new Error('整合包恢复记录写入不完整');
    fs.fsyncSync(handle.fd);
    fs.closeSync(handle);
    handle = undefined;
    fs.renameSync(temp, path);
    let directory = fs.openSync(path.substring(0, path.lastIndexOf('/')), fs.OpenMode.READ_ONLY);
    try { fs.fsyncSync(directory.fd); } finally { fs.closeSync(directory); }
  } finally {
    if (handle !== undefined) fs.closeSync(handle);
  }
}

/** 只按合法任务 ID 构造工作根，不接受来源清单中的任意绝对路径。 */
export function modpackWorkDir(filesDir: string, id: string): string {
  if (safeBaseName(id) !== id || id.length === 0) throw new Error('整合包安装身份不安全');
  return filesDir + '/modpack-work/' + id;
}

export function saveModpackSession(filesDir: string, session: ModpackInstallSession): void {
  let dir = modpackWorkDir(filesDir, session.id);
  ensureDirSync(dir);
  writeModpackJsonAtomic(dir + '/session.json', session);
}

export function saveModpackSource(filesDir: string, source: ModpackSourceReceipt): void {
  let dir = modpackWorkDir(filesDir, source.id);
  ensureDirSync(dir);
  writeModpackJsonAtomic(dir + '/source.json', source);
}

export function loadModpackSource(filesDir: string, id: string): ModpackSourceReceipt {
  let source = JSON.parse(fs.readTextSync(modpackWorkDir(filesDir, id) + '/source.json')) as ModpackSourceReceipt;
  if (source === null || source.schemaVersion !== 1 || source.id !== id || typeof source.mcDir !== 'string'
    || typeof source.title !== 'string') throw new Error('整合包来源恢复记录损坏');
  if (source.requestedVersionName !== undefined && (typeof source.requestedVersionName !== 'string'
    || source.requestedVersionName.length === 0 || safeBaseName(source.requestedVersionName) !== source.requestedVersionName)) {
    throw new Error('整合包来源名称意图损坏');
  }
  return source;
}

/** 恢复时重新检查路径和结构；版本名为空表示尚未预约实例目录。 */
export function loadModpackSession(filesDir: string, id: string): ModpackInstallSession {
  let value = JSON.parse(fs.readTextSync(modpackWorkDir(filesDir, id) + '/session.json')) as ModpackInstallSession;
  if (value === null || value.schemaVersion !== 1 || value.id !== id || typeof value.mcDir !== 'string'
    || value.mcDir.length === 0 || !Array.isArray(value.plan?.files) || !Array.isArray(value.missing)
    || !Array.isArray(value.selectedOptional) || !Array.isArray(value.overrideFiles)
    || !Array.isArray(value.installedFiles) || !Array.isArray(value.warnings)) throw new Error('整合包恢复计划损坏');
  if (value.versionName.length > 0 && safeBaseName(value.versionName) !== value.versionName) {
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
    if (safeRelPath(dir) !== dir) throw new Error('整合包恢复覆盖路径不安全');
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

/** 历史完成且无缺失的任务不进入恢复列表；损坏记录保留原文件而不执行任何清理。 */
export function listModpackRecovery(filesDir: string): ModpackRecoveryItem[] {
  let result: ModpackRecoveryItem[] = [];
  let entries: string[] = [];
  try { entries = fs.listFileSync(filesDir + '/modpack-work'); } catch (e) { return result; }
  for (let id of entries) {
    try {
      let session = loadModpackSession(filesDir, id);
      // 收据提交与移除 pending 之间可能进程退出；完成标志不能掩盖仍待收尾的实例。
      let pending = session.versionName.length > 0
        && hasPendingModpackInstall(session.mcDir + '/versions/' + session.versionName);
      if (session.complete && session.missing.length === 0 && !pending) continue;
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
