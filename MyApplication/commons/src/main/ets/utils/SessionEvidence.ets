/**
 * SessionEvidence.ets — 会话证据清单与选择持久化（统一日志系统 U02）
 *
 * ActivityLedger 负责活动状态和账本目录；本模块负责“目录里究竟有哪些证据文件”。
 * 先兼容当前已经存在的六段账本文件，再为后续 render/jvm/gc/debug 归档提供统一入口。
 *
 * 约束：
 *   1. 只把真实存在且非空的文件列入可上传集合；
 *   2. 用户选择单独落盘，不由刷新清单时悄悄重置；
 *   3. 对外路径与本地路径分离，绝不把绝对路径写进公开清单；
 *   4. 未知文件也登记为 OTHER，不能再出现“磁盘上有文件但系统完全不知道”。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { zlib } from '@kit.BasicServicesKit';
import {
  EvidenceFileRecord, EvidenceFileState, EvidenceManifest, EvidenceRole,
  EvidenceSource, EvidenceUploadPolicy, EvidenceUploadSelection,
  defaultEvidenceSelection,
  isDefaultEvidenceFile, isSafeEvidencePath,
} from './EvidenceTypes';
import { ensureDirSync } from './FileUtils';
import { stringToUtf8 } from './Base64Util';
import { evidenceFileStamp, evidenceTextDigest, hashEvidenceRange, readEvidenceTextBounded, writeEvidenceTextAtomic } from './EvidenceIo';
import { readSessionCapture, CaptureSource, verifyCapturedSource, nativeSessionIo } from './SessionCapture';
import { readSessionBannerActivityId } from './GameLogPaths';

const EVIDENCE_MANIFEST_NAME: string = 'evidence-manifest.json';
const EVIDENCE_SELECTION_NAME: string = 'evidence-selection.json';
const MAX_SCAN_DEPTH: number = 5;
const MAX_GZIP_TEXT_BYTES: number = 16 * 1024 * 1024;
export const GZIP_EVIDENCE_TRUNCATION_MARKER: string = '[amcl] gzip 轮转分片超过阅读上限，后续内容未载入';

/** 一次范围读取的快照结果；用于分享前确认文件没有在读取期间跨过新的 revision。 */
export interface SessionEvidenceTextSnapshot {
  text: string;
  bytes: number;
  stable: boolean;
}

interface EvidenceClassification {
  role: EvidenceRole;
  source: EvidenceSource;
  uploadPolicy: EvidenceUploadPolicy;
}

interface LegacyEvidenceMapping {
  path: string;
  role: EvidenceRole;
  source: EvidenceSource;
}

function ledgerDir_(filesDir: string, activityId: number): string {
  return filesDir + '/logs/ledger/' + activityId;
}

function evidenceManifestPath_(filesDir: string, activityId: number): string {
  return ledgerDir_(filesDir, activityId) + '/' + EVIDENCE_MANIFEST_NAME;
}

function evidenceSelectionPath_(filesDir: string, activityId: number): string {
  return ledgerDir_(filesDir, activityId) + '/' + EVIDENCE_SELECTION_NAME;
}

function fileBytes_(path: string): number {
  try {
    const stat = fs.statSync(path);
    return stat.size > 0 ? stat.size : 0;
  } catch (e) {
    return 0;
  }
}

function fileFingerprint_(path: string): string {
  try {
    return evidenceFileStamp(path);
  } catch (e) {
    return 'missing';
  }
}

function isDirectory_(path: string): boolean {
  try { return fs.statSync(path).isDirectory(); } catch (e) { return false; }
}

function readText_(path: string): string {
  try {
    if (fileBytes_(path) <= 0) return '';
    return fs.readTextSync(path);
  } catch (e) {
    return '';
  }
}

/** 原子写清单/选择：先写同目录临时文件、校验完整字节，再 rename 替换旧文件。 */
function writeText_(path: string, value: string): boolean {
  try { writeEvidenceTextAtomic(path, value); return true; } catch (e) { return false; }
}

function utf8ByteLength_(value: string): number {
  return stringToUtf8(value).byteLength;
}

/** 读取一份已登记证据；maxBytes=0 表示读完整文件。 */
export function readSessionEvidenceText(file: EvidenceFileRecord,
  maxBytes: number = 0): string {
  if (!file.localPath || file.localPath.length === 0) return '';
  // gzip/zip 轮转分片必须走异步解压入口；同步 reader 不把二进制误当 UTF-8。
  if (file.path.endsWith('.gz')) return '';
  try {
    const total: number = fileBytes_(file.localPath);
    if (total <= 0) return '';
    if (maxBytes <= 0 || total <= maxBytes) return fs.readTextSync(file.localPath);
    const opened: fs.File = fs.openSync(file.localPath, fs.OpenMode.READ_ONLY);
    try {
      const start: number = total - maxBytes;
      const buffer = new ArrayBuffer(maxBytes);
      const got: number = fs.readSync(opened.fd, buffer, { offset: start, length: maxBytes });
      if (got <= 0) return '';
      const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      let text: string = decoder.decodeToString(new Uint8Array(buffer, 0, got));
      if (start > 0) {
        const newline: number = text.indexOf('\n');
        if (newline >= 0 && newline < 512) text = text.substring(newline + 1);
      }
      return text;
    } finally {
      fs.closeSync(opened);
    }
  } catch (e) {
    return '';
  }
}

/** 异步读取文本或 gzip 轮转分片；输出限制按解压后字节计，避免压缩炸弹耗尽内存。 */
export async function readSessionEvidenceTextAsync(file: EvidenceFileRecord,
  maxBytes: number = 0): Promise<string> {
  const result = await readEvidenceTextBounded(file.localPath, file.path.endsWith('.gz'),
    maxBytes > 0 ? maxBytes : MAX_GZIP_TEXT_BYTES);
  return result.text + (result.eof ? '' : '\n' + GZIP_EVIDENCE_TRUNCATION_MARKER + '\n');
}

/** 读取固定范围并检查前后指纹；写入中的文件仍返回已读快照，但标记 stable=false。 */
export function readSessionEvidenceSnapshot(file: EvidenceFileRecord,
  maxBytes: number = 0): SessionEvidenceTextSnapshot {
  const before: string = fileFingerprint_(file.localPath);
  const bytes: number = fileBytes_(file.localPath);
  const text: string = readSessionEvidenceText(file, maxBytes);
  const after: string = fileFingerprint_(file.localPath);
  return { text: text, bytes: bytes, stable: before !== 'missing' && before === after
    && text === readSessionEvidenceText(file, maxBytes) };
}

/** 异步快照入口：普通文本和 gzip 都在同一组前后指纹内读取，调用方不得忽略 stable=false。 */
export async function readSessionEvidenceSnapshotAsync(file: EvidenceFileRecord,
  maxBytes: number = 0): Promise<SessionEvidenceTextSnapshot> {
  const before: string = evidenceFileStamp(file.localPath);
  const opened = await fs.open(file.localPath, fs.OpenMode.READ_ONLY);
  try {
    const bytes: number = (await fs.stat(opened.fd)).size;
    const digest: string = await hashEvidenceRange(opened.fd, bytes);
    const text: string = await readSessionEvidenceTextAsync(file, maxBytes);
    const afterDigest: string = await hashEvidenceRange(opened.fd, bytes);
    const after: string = evidenceFileStamp(file.localPath);
    return { text: text, bytes: bytes, stable: before === after && digest === afterDigest };
  } finally { await fs.close(opened); }
}

function safeRemotePath_(path: string): string {
  if (isSafeEvidencePath(path)) return path;
  return '';
}

function newRecord_(fileId: string, path: string, localPath: string,
  role: EvidenceRole, source: EvidenceSource, bytes: number,
  state: EvidenceFileState = EvidenceFileState.COMPLETE): EvidenceFileRecord {
  const safePath: string = safeRemotePath_(path);
  const record: EvidenceFileRecord = {
    fileId: fileId,
    path: safePath,
    localPath: localPath,
    role: role,
    source: source,
    state: state,
    uploadPolicy: EvidenceUploadPolicy.OPTIONAL,
    defaultSelected: false,
    bytes: bytes,
    lines: 0,
    capturedAt: 0,
    completedAt: state === EvidenceFileState.COMPLETE ? Date.now() : 0,
    attribution: 'unknown',
    reason: safePath.length > 0 ? '' : '外发相对路径不安全',
    digest: '',
  };
  record.defaultSelected = isDefaultEvidenceFile(record);
  if (record.defaultSelected) record.uploadPolicy = EvidenceUploadPolicy.DEFAULT;
  return record;
}

function classify_(relativePath: string): EvidenceClassification {
  const p: string = relativePath.toLowerCase();
  let role: EvidenceRole = EvidenceRole.OTHER;
  let source: EvidenceSource = EvidenceSource.DERIVED;
  if (p === 'game/logs/latest.log' || new RegExp('^game/logs/[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]+\\.log\\.gz$').test(p)) {
    role = EvidenceRole.MINECRAFT_MAIN; source = EvidenceSource.MOJANG_LOG4J;
  } else if (p.indexOf('game/logs/debug.log') === 0 || new RegExp('^game/logs/debug-[0-9]+\\.log\\.gz$').test(p)) {
    role = EvidenceRole.MINECRAFT_DEBUG; source = EvidenceSource.MOJANG_LOG4J;
  } else if (p.indexOf('game/mc_output') === 0) {
    role = EvidenceRole.MINECRAFT_OUTPUT; source = EvidenceSource.MC_STDIO;
  } else if (p.indexOf('crash-reports/') === 0) {
    role = EvidenceRole.CRASH_REPORT; source = EvidenceSource.MOJANG_LOG4J;
  } else if (p.indexOf('jvm/hs_err') === 0) {
    role = EvidenceRole.JVM_FATAL; source = EvidenceSource.JVM;
  } else if (p.indexOf('jvm/gc-amcl') === 0) {
    role = EvidenceRole.JVM_GC; source = EvidenceSource.JVM;
  } else if (p.indexOf('jvm/') === 0) {
    role = EvidenceRole.JVM_STDERR; source = EvidenceSource.JVM;
  } else if (p.indexOf('render/frame-summary') === 0 || p.indexOf('render/crash-tail') === 0) {
    role = EvidenceRole.RENDERER_TRACE; source = EvidenceSource.AMCL_RENDERER;
  } else if (p.indexOf('render/') === 0) {
    role = p.indexOf('render/probes/') === 0 || p.endsWith('.json')
      ? EvidenceRole.RENDERER_PROBE : EvidenceRole.RENDERER;
    source = EvidenceSource.AMCL_RENDERER;
  } else if (p.indexOf('renderer/mobileglues') === 0) {
    role = EvidenceRole.MOBILEGLUES; source = EvidenceSource.MOBILEGLUES;
  } else if (p.indexOf('input/') === 0) {
    role = EvidenceRole.INPUT; source = EvidenceSource.AMCL_INPUT;
  } else if (p.indexOf('audio/') === 0) {
    role = EvidenceRole.AUDIO; source = EvidenceSource.AMCL_AUDIO;
  } else if (p.indexOf('network/') === 0) {
    role = EvidenceRole.NETWORK; source = EvidenceSource.AMCL_NETWORK;
  } else if (p.indexOf('installer/') === 0) {
    role = EvidenceRole.INSTALLER; source = EvidenceSource.LOADER_INSTALLER;
  } else if (p.indexOf('agent/') === 0) {
    role = EvidenceRole.AGENT; source = EvidenceSource.JAVA_AGENT;
  } else if (p.indexOf('system/crash-report-') === 0) {
    role = EvidenceRole.SYSTEM_CRASH; source = EvidenceSource.PLATFORM_DFX;
  } else if (p.indexOf('system/') === 0) {
    role = EvidenceRole.SYSTEM_TRACE; source = EvidenceSource.PLATFORM_DFX;
  } else if (p.indexOf('launcher/') === 0) {
    role = EvidenceRole.LAUNCHER; source = EvidenceSource.AMCL_LAUNCHER;
  }
  const policy: EvidenceUploadPolicy = EvidenceUploadPolicy.OPTIONAL;
  return { role: role, source: source, uploadPolicy: policy };
}

function legacyMapping_(name: string): LegacyEvidenceMapping {
  if (name === 'launcher.log' || name.indexOf('launcher.tail') === 0) {
    return { path: 'launcher/launcher-host.log', role: EvidenceRole.LAUNCHER,
      source: EvidenceSource.AMCL_LAUNCHER };
  }
  if (name === 'game.log') {
    return { path: 'game/mc_output.log', role: EvidenceRole.MINECRAFT_OUTPUT,
      source: EvidenceSource.MC_STDIO };
  }
  if (name === 'mc-latest.log') {
    return { path: 'game/logs/latest.log', role: EvidenceRole.MINECRAFT_MAIN,
      source: EvidenceSource.MOJANG_LOG4J };
  }
  if (name === 'jvm.log') {
    return { path: 'jvm/jvm-stderr.log', role: EvidenceRole.JVM_STDERR,
      source: EvidenceSource.JVM };
  }
  if (name === 'crash-report.txt') {
    return { path: 'crash-reports/crash-report.txt', role: EvidenceRole.CRASH_REPORT,
      source: EvidenceSource.MOJANG_LOG4J };
  }
  return { path: 'system/crash-tail.log', role: EvidenceRole.SYSTEM_TRACE,
    source: EvidenceSource.PLATFORM_DFX };
}

function appendRecord_(out: EvidenceFileRecord[], activityId: number,
  localPath: string, relativePath: string, role: EvidenceRole,
  source: EvidenceSource, bytes: number, state: EvidenceFileState): void {
  if (bytes <= 0 || relativePath.length === 0) return;
  // 恢复展示去重回执是内部协调状态，不是启动器正文；目录扫描不能把它默认外发，
  // 也不能因它没有 capture-host 计数而把已经封账的游戏日志误标为 partial。
  if (relativePath === 'launcher/recovery-receipt.json') return;
  const fileId: string = 'activity-' + activityId + '/' + relativePath;
  const record: EvidenceFileRecord = newRecord_(fileId, relativePath, localPath, role, source, bytes, state);
  if (record.path.length === 0) return;
  // 轻量文件指纹用于检测同路径同大小的重写；内容摘要仍由导出器按需计算。
  record.digest = fileFingerprint_(localPath);
  for (const old of out) {
    if (old.localPath === localPath) return;
  }
  out.push(record);
}

function scanTree_(root: string, prefix: string, activityId: number,
  out: EvidenceFileRecord[], depth: number): void {
  if (depth > MAX_SCAN_DEPTH || !isDirectory_(root)) return;
  let names: string[] = [];
  try { names = fs.listFileSync(root); } catch (e) { return; }
  for (const name of names) {
    if (name === EVIDENCE_MANIFEST_NAME || name === EVIDENCE_SELECTION_NAME
      || name.indexOf('.tmp-') >= 0 || name.endsWith('.partial')) continue;
    const local: string = root + '/' + name;
    const remote: string = prefix.length > 0 ? prefix + '/' + name : name;
    if (isDirectory_(local)) {
      scanTree_(local, remote, activityId, out, depth + 1);
      continue;
    }
    const bytes: number = fileBytes_(local);
    const kind = classify_(remote);
    appendRecord_(out, activityId, local, remote, kind.role, kind.source, bytes,
      EvidenceFileState.COMPLETE);
  }
}

/** 列出当前账本的全部真实证据文件，兼容旧六段文件名。 */
export function listSessionEvidence(filesDir: string, activityId: number, verifyReceipts: boolean = true): EvidenceFileRecord[] {
  const out: EvidenceFileRecord[] = [];
  if (!filesDir || activityId <= 0) return out;
  const dir: string = ledgerDir_(filesDir, activityId);
  if (!isDirectory_(dir)) return out;

  const legacyNames: string[] = [
    'launcher.log', 'launcher.tail.log', 'launcher.tail.1.log',
    'game.log', 'mc-latest.log', 'jvm.log', 'crash-report.txt', 'system-crash.log',
  ];
  for (const name of legacyNames) {
    const local: string = dir + '/' + name;
    const bytes: number = fileBytes_(local);
    if (bytes <= 0) continue;
    // U03 归档器会同时保留兼容根文件和官方相对路径文件；优先列新路径，
    // 避免活动页把同一份 latest/JVM/crash 显示两次。
    if (name === 'game.log' && fileBytes_(dir + '/game/mc_output.log') > 0) continue;
    if (name === 'mc-latest.log' && fileBytes_(dir + '/game/logs/latest.log') > 0) continue;
    if (name === 'jvm.log' && fileBytes_(dir + '/jvm/jvm-stderr.log') > 0) continue;
    if (name === 'crash-report.txt' && isDirectory_(dir + '/crash-reports')) continue;
    const mapping = legacyMapping_(name);
    let remote: string = mapping.path;
    if (name === 'launcher.log' && fileBytes_(dir + '/launcher/launcher-host.log') > 0) remote = 'launcher/launcher-legacy.log';
    if (name === 'launcher.tail.log') remote = 'launcher/launcher-tail.log';
    if (name === 'launcher.tail.1.log') remote = 'launcher/launcher-tail.1.log';
    appendRecord_(out, activityId, local, remote, mapping.role, mapping.source, bytes,
      EvidenceFileState.COMPLETE);
  }
  scanTree_(dir + '/game', 'game', activityId, out, 0);
  scanTree_(dir + '/crash-reports', 'crash-reports', activityId, out, 0);
  scanTree_(dir + '/launcher', 'launcher', activityId, out, 0);
  scanTree_(dir + '/jvm', 'jvm', activityId, out, 0);
  scanTree_(dir + '/render', 'render', activityId, out, 0);
  scanTree_(dir + '/renderer', 'renderer', activityId, out, 0);
  scanTree_(dir + '/system', 'system', activityId, out, 0);
  scanTree_(dir + '/input', 'input', activityId, out, 0);
  scanTree_(dir + '/audio', 'audio', activityId, out, 0);
  scanTree_(dir + '/network', 'network', activityId, out, 0);
  scanTree_(dir + '/installer', 'installer', activityId, out, 0);
  scanTree_(dir + '/agent', 'agent', activityId, out, 0);
  applyCaptureState_(dir, out, activityId);
  const capture = readSessionCapture(filesDir, activityId);
  if (capture !== undefined) {
    for (const item of capture.sources) {
      let file = out.find((record: EvidenceFileRecord): boolean => record.path === item.destination);
      if (file === undefined) {
        const kind = classify_(item.destination);
        file = newRecord_('activity-' + activityId + '/' + item.destination, item.destination,
          dir + '/' + item.destination, kind.role, kind.source, 0, EvidenceFileState.NOT_PRODUCED);
        out.push(file);
      }
      // 原件横幅与本局不匹配时，旧收据不能覆盖当前已证实的错误归属。
      if (file.attribution === 'previous-session') continue;
      file.state = item.state as EvidenceFileState;
      file.attribution = item.attribution ?? 'unknown';
      file.reason = item.reason;
      // 清单只能消费固定归档收据。文件存在/大小变化/revision 更新都不能替代完整性校验。
      if (item.captured.length > 0 && file.state !== EvidenceFileState.WRITING) {
        // UI 可先枚举轻量来源，再通过异步读取逐份校验；外发/封账默认仍严格同步核验。
        const issue: string = verifyReceipts ? verifyCapturedSource(item, file.localPath) : '';
        file.rawSha256 = item.capturedSha256;
        file.rawBytes = item.capturedBytes;
        file.captureMode = item.mode ?? 'snapshot';
        file.verification = !verifyReceipts ? 'pending' : issue.length === 0 ? 'verified' : 'unverified';
        if (issue.length > 0) { file.state = EvidenceFileState.PARTIAL; file.reason = issue; }
      }
      if (item.attribution === 'previous-session') {
        file.state = EvidenceFileState.NOT_APPLICABLE;
        file.uploadPolicy = EvidenceUploadPolicy.NEVER;
      }
      file.defaultSelected = isDefaultEvidenceFile(file);
      if (file.uploadPolicy !== EvidenceUploadPolicy.NEVER) file.uploadPolicy = file.defaultSelected
        ? EvidenceUploadPolicy.DEFAULT : EvidenceUploadPolicy.OPTIONAL;
    }
  }
  if (!out.some((file: EvidenceFileRecord): boolean => file.role === EvidenceRole.LAUNCHER)) {
    const status = captureStatus_(dir, false) ?? captureStatus_(dir, true);
    const missing = newRecord_('activity-' + activityId + '/launcher/launcher-host.log',
      'launcher/launcher-host.log', dir + '/launcher/launcher-host.log', EvidenceRole.LAUNCHER,
      EvidenceSource.AMCL_LAUNCHER, 0, status === undefined ? EvidenceFileState.UNAVAILABLE : EvidenceFileState.NOT_PRODUCED);
    missing.reason = status === undefined ? '启动器采集没有状态记录，无法确认完整性' : '本次活动没有产生启动器正文';
    missing.uploadPolicy = EvidenceUploadPolicy.NEVER;
    out.push(missing);
  }
  out.sort((a: EvidenceFileRecord, b: EvidenceFileRecord): number =>
    a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  return out;
}

interface NativeCaptureStatus {
  sealed: boolean;
  dropped: number;
  writeFailures: number;
  truncated: number;
}

function captureStatus_(dir: string, game: boolean): NativeCaptureStatus | undefined {
  try {
    return JSON.parse(fs.readTextSync(dir + (game ? '/capture-game.json' : '/capture-host.json'))) as NativeCaptureStatus;
  } catch (e) { return undefined; }
}

/** 真实采集计数决定完整性，存在一个文件不等于完整捕获了事件流。 */
function applyCaptureState_(dir: string, files: EvidenceFileRecord[], activityId: number): void {
  for (const file of files) {
    if (file.source === EvidenceSource.AMCL_LAUNCHER || file.role === EvidenceRole.RENDERER) {
      const status = captureStatus_(dir, file.path.indexOf('-game.log') >= 0);
      if (status !== undefined) {
        const lost: number = status.dropped + status.writeFailures + status.truncated;
        file.state = lost > 0 ? EvidenceFileState.PARTIAL
          : status.sealed ? EvidenceFileState.COMPLETE : EvidenceFileState.WRITING;
        file.attribution = 'exact';
        file.reason = lost > 0 ? '采集缺口：丢弃 ' + status.dropped + '，写入失败 '
          + status.writeFailures + '，截断 ' + status.truncated : '';
      } else {
        file.state = EvidenceFileState.PARTIAL;
        file.reason = '历史文件没有采集计数，不能证明完整';
      }
    } else {
      file.state = EvidenceFileState.AVAILABLE;
      file.reason = '已保存文件；归属及完整性由采集记录说明';
      // stdout 由归档器按横幅复制；清单每次读取原件横幅复核，兼容修复前已归档的文件。
      // 仅有旧时间横幅或完全没有横幅时仍为 unknown，不靠文件名升级历史归属。
      if (file.source === EvidenceSource.MC_STDIO) {
        const id: number = readSessionBannerActivityId(file.localPath);
        if (id === activityId) {
          file.attribution = 'exact';
          file.reason = '已核对游戏输出横幅中的活动 ID';
        } else if (id > 0) {
          file.attribution = 'previous-session';
          file.state = EvidenceFileState.NOT_APPLICABLE;
          file.reason = '游戏输出横幅属于其他活动';
          file.uploadPolicy = EvidenceUploadPolicy.NEVER;
        }
      }
      if (file.source === EvidenceSource.PLATFORM_DFX && file.path.startsWith('system/crash-report-event-')) {
        file.attribution = 'exact';
        file.reason = '已核对平台事件时间与进程归属';
      }
    }
    file.defaultSelected = isDefaultEvidenceFile(file);
    if (file.uploadPolicy !== EvidenceUploadPolicy.NEVER) {
      file.uploadPolicy = file.defaultSelected ? EvidenceUploadPolicy.DEFAULT : EvidenceUploadPolicy.OPTIONAL;
    }
  }
}

function serializeRecord_(file: EvidenceFileRecord): Record<string, Object> {
  return {
    'fileId': file.fileId, 'path': file.path, 'localPath': file.localPath,
    'role': file.role, 'source': file.source,
    'state': file.state, 'uploadPolicy': file.uploadPolicy,
    'defaultSelected': file.defaultSelected, 'bytes': file.bytes, 'lines': file.lines,
    'capturedAt': file.capturedAt, 'completedAt': file.completedAt,
    'attribution': file.attribution, 'reason': file.reason, 'digest': file.digest,
    'rawSha256': file.rawSha256 ?? '', 'rawBytes': file.rawBytes ?? 0,
    'captureMode': file.captureMode ?? 'legacy', 'verification': file.verification ?? 'unverified',
  };
}

function serializeManifest_(manifest: EvidenceManifest): string {
  const files: Record<string, Object>[] = [];
  for (const file of manifest.files) files.push(serializeRecord_(file));
  const obj: Record<string, Object> = {
    'schema': manifest.schema, 'activityId': manifest.activityId, 'revision': manifest.revision,
    'captureState': manifest.captureState, 'integrityState': manifest.integrityState,
    'droppedEvents': manifest.droppedEvents, 'missingReasons': manifest.missingReasons,
    'files': files,
  };
  return JSON.stringify(obj);
}

/** 刷新证据清单；revision 只有内容集合发生变化时才前进。 */
export function refreshSessionEvidence(filesDir: string, activityId: number,
  captureState: string = 'sealed', integrityState: string = 'complete',
  missingReasons: string[] = []): EvidenceManifest {
  const files: EvidenceFileRecord[] = listSessionEvidence(filesDir, activityId);
  let previous = readSessionEvidence(filesDir, activityId);
  let revision: number = previous === undefined ? 1 : previous.revision;
  let changed: boolean = previous === undefined || previous.files.length !== files.length;
  if (!changed && previous !== undefined) {
    for (let i = 0; i < files.length; i++) {
    if (files[i].path !== previous.files[i].path || files[i].bytes !== previous.files[i].bytes
        || files[i].state !== previous.files[i].state || files[i].attribution !== previous.files[i].attribution
        || files[i].digest !== previous.files[i].digest) {
        changed = true;
        break;
      }
    }
  }
  const reasons: string[] = missingReasons.filter((reason: string): boolean =>
    reason !== '日志进程未完成封账' && reason !== '没有可用证据文件'
      && reason.indexOf('日志采集有缺口') < 0 && !reason.startsWith('文件采集缺口：'));
  let dropped: number = 0;
  const io = nativeSessionIo(filesDir, activityId);
  if (io !== undefined && (!io.consoleReady || io.ioError !== 0)) reasons.push('游戏原始输出重定向或写入失败');
  if (io !== undefined && captureState !== 'running' && !io.ended) reasons.push('游戏原始输出未取得有序关闭证明');
  if (io === undefined && files.some((file: EvidenceFileRecord): boolean => file.role === EvidenceRole.MINECRAFT_OUTPUT)) {
    reasons.push('历史游戏输出没有连续采集与关闭收据，已保存内容可读取但完整性未证实');
  }
  const unverified = files.filter((file: EvidenceFileRecord): boolean => file.bytes > 0
    && (file.source === EvidenceSource.MC_STDIO || file.source === EvidenceSource.MOJANG_LOG4J || file.source === EvidenceSource.JVM)
    && file.verification !== 'verified');
  if (unverified.length > 0) reasons.push('部分游戏/JVM 文件缺少可核验的封账收据');
  for (const game of [false, true]) {
    const status = captureStatus_(ledgerDir_(filesDir, activityId), game);
    if (status === undefined) continue;
    dropped += status.dropped;
    if (status.dropped + status.writeFailures + status.truncated > 0) {
      reasons.push((game ? '游戏进程' : '启动器进程') + '日志采集有缺口');
    }
    if (captureState !== 'running' && !status.sealed) reasons.push('日志进程未完成封账');
  }
  for (const file of files) {
    if (file.state === EvidenceFileState.PARTIAL || file.state === EvidenceFileState.UNAVAILABLE) {
      reasons.push('文件采集缺口：' + file.path + ' · ' + file.reason);
    }
  }
  if (!files.some((file: EvidenceFileRecord): boolean => file.bytes > 0)) reasons.push('没有可用证据文件');
  if (reasons.length > 0) integrityState = 'partial';
  if (previous?.captureState !== captureState || previous?.integrityState !== integrityState
    || previous?.droppedEvents !== dropped) changed = true;
  if (changed && previous !== undefined) revision++;
  const manifest: EvidenceManifest = {
    schema: 2, activityId: activityId, revision: revision,
    captureState: captureState, integrityState: integrityState,
    droppedEvents: dropped, missingReasons: Array.from(new Set<string>(reasons)), files: files,
  };
  try {
    ensureDirSync(ledgerDir_(filesDir, activityId));
    if (!writeText_(evidenceManifestPath_(filesDir, activityId), serializeManifest_(manifest))) {
      manifest.integrityState = 'partial'; manifest.missingReasons.push('证据清单保存失败');
    }
  } catch (e) { /* 清单写失败不阻断原始日志 */ }
  return manifest;
}

function parseString_(obj: Record<string, Object>, key: string, fallback: string): string {
  const value = obj[key];
  return typeof value === 'string' ? value as string : fallback;
}

function parseNumber_(obj: Record<string, Object>, key: string, fallback: number): number {
  const value = obj[key];
  return typeof value === 'number' ? value as number : fallback;
}

function parseRecord_(value: Object): EvidenceFileRecord | undefined {
  if (typeof value !== 'object' || value === null) return undefined;
  const obj = value as Record<string, Object>;
  const path: string = parseString_(obj, 'path', '');
  const localPath: string = parseString_(obj, 'localPath', '');
  if (!isSafeEvidencePath(path) || localPath.length === 0) return undefined;
  const role: EvidenceRole = parseString_(obj, 'role', EvidenceRole.OTHER) as EvidenceRole;
  const source: EvidenceSource = parseString_(obj, 'source', EvidenceSource.DERIVED) as EvidenceSource;
  const state: EvidenceFileState = parseString_(obj, 'state', EvidenceFileState.PARTIAL) as EvidenceFileState;
  const policy: EvidenceUploadPolicy =
    parseString_(obj, 'uploadPolicy', EvidenceUploadPolicy.OPTIONAL) as EvidenceUploadPolicy;
  const file: EvidenceFileRecord = {
    fileId: parseString_(obj, 'fileId', path),
    path: path, localPath: localPath, role: role, source: source, state: state,
    uploadPolicy: policy, defaultSelected: obj['defaultSelected'] === true,
    bytes: parseNumber_(obj, 'bytes', 0), lines: parseNumber_(obj, 'lines', 0),
    capturedAt: parseNumber_(obj, 'capturedAt', 0), completedAt: parseNumber_(obj, 'completedAt', 0),
    attribution: parseString_(obj, 'attribution', 'unknown'),
    reason: parseString_(obj, 'reason', ''), digest: parseString_(obj, 'digest', ''),
    rawSha256: parseString_(obj, 'rawSha256', ''), rawBytes: parseNumber_(obj, 'rawBytes', 0),
    captureMode: parseString_(obj, 'captureMode', 'legacy'), verification: parseString_(obj, 'verification', 'unverified'),
  };
  return file;
}

/** 读取已保存清单；损坏时返回 undefined，调用方可以从目录重建。 */
export function readSessionEvidence(filesDir: string, activityId: number): EvidenceManifest | undefined {
  const text: string = readText_(evidenceManifestPath_(filesDir, activityId));
  if (text.length === 0) return undefined;
  try {
    const parsed = JSON.parse(text) as Record<string, Object>;
    const values = parsed['files'];
    const files: EvidenceFileRecord[] = [];
    if (Array.isArray(values)) {
      for (const value of values as Object[]) {
        const record = parseRecord_(value);
        if (record !== undefined) files.push(record);
      }
    }
    return {
      schema: parseNumber_(parsed, 'schema', 2),
      activityId: parseNumber_(parsed, 'activityId', activityId),
      revision: parseNumber_(parsed, 'revision', 1),
      captureState: parseString_(parsed, 'captureState', 'unknown'),
      integrityState: parseString_(parsed, 'integrityState', 'partial'),
      droppedEvents: parseNumber_(parsed, 'droppedEvents', 0),
      missingReasons: Array.isArray(parsed['missingReasons'])
        ? parsed['missingReasons'] as string[] : [],
      files: files,
    };
  } catch (e) {
    return undefined;
  }
}

function serializeSelection_(selection: EvidenceUploadSelection): string {
  const obj: Record<string, Object> = {
    'activityId': selection.activityId, 'revision': selection.revision,
    'selectedFileIds': selection.selectedFileIds,
    'createdAt': selection.createdAt, 'includePublicSummary': selection.includePublicSummary,
  };
  return JSON.stringify(obj);
}

/** 取得分享选择；首次读取返回 latest/crash/launcher 默认集合。 */
export function evidenceSelectionOf(filesDir: string, activityId: number,
  files?: EvidenceFileRecord[]): EvidenceUploadSelection {
  const actual: EvidenceFileRecord[] = files ?? listSessionEvidence(filesDir, activityId);
  const text: string = readText_(evidenceSelectionPath_(filesDir, activityId));
  if (text.length > 0) {
    try {
      const parsed = JSON.parse(text) as Record<string, Object>;
      const values = parsed['selectedFileIds'];
      const ids: string[] = Array.isArray(values) ? values as string[] : [];
      const selection: EvidenceUploadSelection = {
        activityId: parseNumber_(parsed, 'activityId', activityId),
        revision: readSessionEvidence(filesDir, activityId)?.revision ?? 1,
        selectedFileIds: ids,
        createdAt: parseNumber_(parsed, 'createdAt', Date.now()),
        includePublicSummary: parsed['includePublicSummary'] !== false,
      };
      selection.selectedFileIds = normalizeEvidenceSelectionForFiles_(actual, ids);
      return selection;
    } catch (e) { /* 损坏的选择回退默认集合 */ }
  }
  const selection: EvidenceUploadSelection = {
    activityId: activityId, revision: readSessionEvidence(filesDir, activityId)?.revision ?? 1,
    selectedFileIds: defaultEvidenceSelection(actual),
    createdAt: Date.now(), includePublicSummary: true,
  };
  return selection;
}

function normalizeEvidenceSelectionForFiles_(files: EvidenceFileRecord[],
  ids: string[]): string[] {
  const out: string[] = [];
  for (const file of files) {
    if (ids.indexOf(file.fileId) < 0 || file.uploadPolicy === EvidenceUploadPolicy.NEVER || file.bytes <= 0) continue;
    if (file.state === EvidenceFileState.MISSING || file.state === EvidenceFileState.NOT_PRODUCED
      || file.state === EvidenceFileState.NOT_APPLICABLE || file.state === EvidenceFileState.UNAVAILABLE
      || file.state === EvidenceFileState.CLEANED) continue;
    out.push(file.fileId);
  }
  return out;
}

/** 保存用户本次活动的分享选择，自动剔除不存在/不可上传文件。 */
export function setEvidenceSelection(filesDir: string, activityId: number,
  selectedFileIds: string[], includePublicSummary: boolean = true): EvidenceUploadSelection {
  const files: EvidenceFileRecord[] = listSessionEvidence(filesDir, activityId);
  const selection: EvidenceUploadSelection = {
    activityId: activityId,
    revision: readSessionEvidence(filesDir, activityId)?.revision ?? 1,
    selectedFileIds: normalizeEvidenceSelectionForFiles_(files, selectedFileIds),
    createdAt: Date.now(),
    includePublicSummary: includePublicSummary,
  };
  ensureDirSync(ledgerDir_(filesDir, activityId));
  writeEvidenceTextAtomic(evidenceSelectionPath_(filesDir, activityId), serializeSelection_(selection));
  return selection;
}

/** 恢复默认分享集合，仍然只保存本次选择，不改变采集策略。 */
export function resetEvidenceSelection(filesDir: string, activityId: number): EvidenceUploadSelection {
  const files: EvidenceFileRecord[] = listSessionEvidence(filesDir, activityId);
  return setEvidenceSelection(filesDir, activityId, defaultEvidenceSelection(files), true);
}
