/** 统一分享快照：冻结选择和文件范围，逐行脱敏；网络和 ZIP 使用同一份产物。 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { EvidenceFileRecord, EvidenceUploadSelection, EvidenceUploadPolicy, normalizeEvidenceSelection } from './EvidenceTypes';
import { listSessionEvidence, readSessionEvidence } from './SessionEvidence';
import { verifySessionCaptureRotations } from './SessionCapture';
import { ensureDirSync, removeDirRecursive } from './FileUtils';
import { sanitizeLogForExport, LogExportTarget, utf8ByteLength } from './LogExport';
import { acquireEvidenceLease, releaseEvidenceLease, hashEvidenceRange, evidenceTextDigest,
  EvidenceTextCursor, readEvidenceTextBounded, writeEvidenceTextAtomic } from './EvidenceIo';
import { readObservedSessionEnvironment, sessionEnvironmentSummary } from './SessionEnvironment';

export const EVIDENCE_REDACTION_VERSION: string = 'game-v3';
/** 结构变化独立版本化，旧快照不能冒充已经携带 AI 环境上下文的新格式。 */
export const EVIDENCE_EXPORT_FORMAT: string = 'session-diagnosis-v2';
export const EVIDENCE_DIAGNOSIS_NAME: string = '_amcl/diagnosis.txt';
export interface EvidenceShareFile { name: string; content: string; }
export interface FrozenEvidenceFile {
  name: string;
  path: string;
  role: string;
  bytes: number;
  sourceBytes: number;
  digest: string;
  lines: number;
  state: string;
  reason?: string;
  rawSha256?: string;
  captureMode?: string;
  verification?: string;
}
export interface EvidenceExportSnapshot {
  activityId: number;
  revision: number;
  createdAt: number;
  directory: string;
  digest: string;
  redactionVersion: string;
  files: FrozenEvidenceFile[];
}
interface OpenEvidenceSource {
  record: EvidenceFileRecord;
  file: fs.File;
  size: number;
  inode: string;
}
interface PublicSnapshotFile {
  name: string; role: string; bytes: number; sourceBytes: number; sha256: string; lines: number; state: string; reason: string;
  rawSha256: string; captureMode: string; verification: string;
}
interface PublicSnapshotManifest {
  schema: number; activityId: number; createdAt: number; digest: string; redactionVersion: string; files: PublicSnapshotFile[];
}
let snapshotSequence: number = 0;

/** 常见技术文件名保持可读；自定义名称不携带玩家、目录或服务器标识。 */
export function publicEvidenceName(path: string): string {
  if (path.startsWith('system/crash-report-')) return 'system/crash-report-evidence-'
    + evidenceTextDigest(path).substring(0, 16) + '.log';
  const known = new RegExp('^(game/logs/(latest\\.log|debug\\.log(?:\\..+)?|[0-9-]+\\.log\\.gz)|game/mc_output\\.log|launcher/launcher[-.a-z0-9]*\\.log|jvm/(jvm-stderr\\.log|hs_err_pid[0-9]+\\.log|gc-amcl\\.log[.0-9]*)|crash-reports/crash-[0-9_:.\\-]+-(client|server)\\.txt|render/(renderer(?:-game)?\\.log|frame-summary\\.log|crash-tail\\.log))$');
  if (known.test(path)) return path.endsWith('.gz') ? path + '.decompressed.log' : path;
  const category: string = path.split('/')[0];
  const allowed: string[] = ['game', 'launcher', 'jvm', 'crash-reports', 'render', 'renderer', 'system', 'input', 'audio', 'network', 'installer', 'agent'];
  return (allowed.indexOf(category) >= 0 ? category : 'other') + '/evidence-'
    + evidenceTextDigest(path).substring(0, 16) + '.log';
}

async function redactFrozenFile(source: string, compressed: boolean, target: string): Promise<number> {
  const cursor = new EvidenceTextCursor();
  let output: fs.File | undefined = undefined;
  let pending: string = '';
  let lines: number = 0;
  try {
    await cursor.open(source, compressed);
    ensureDirSync(target.substring(0, target.lastIndexOf('/')));
    output = await fs.open(target, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    let eof: boolean = false;
    while (!eof) {
      const page = await cursor.read();
      eof = page.eof; pending += page.text;
      const end: number = eof ? pending.length : pending.lastIndexOf('\n') + 1;
      if (end > 0) {
        const logical: string = pending.substring(0, end);
        const redacted: string = sanitizeLogForExport(logical, LogExportTarget.LOGSHARE, Number.MAX_SAFE_INTEGER);
        const written: number = await fs.write(output.fd, redacted);
        if (written !== utf8ByteLength(redacted)) throw new Error('脱敏快照短写');
        lines += logical.split('\n').length - 1;
        if (eof && !logical.endsWith('\n')) lines++;
        pending = pending.substring(end);
      }
      // 正常文件大小不限；极端的单行不能无限占用 JS 堆，失败必须对用户可见。
      if (pending.length > 8 * 1024 * 1024) throw new Error('单行日志超过 8 MiB，无法安全预览和脱敏');
    }
    fs.fsyncSync(output.fd);
    return lines;
  } finally {
    await cursor.close();
    if (output !== undefined) await fs.close(output);
  }
}

/** await 前复制选择并同时打开所有源文件；新增日志仅在下次快照中出现。 */
export async function createEvidenceExportSnapshot(filesDir: string, tempDir: string,
  selection: EvidenceUploadSelection, publicSummary: string): Promise<EvidenceExportSnapshot> {
  const selected: string[] = selection.selectedFileIds.slice();
  const includeSummary: boolean = selection.includePublicSummary;
  const snapshot: EvidenceExportSnapshot = { activityId: selection.activityId, revision: selection.revision,
    createdAt: Date.now(), directory: '', digest: '', redactionVersion: EVIDENCE_REDACTION_VERSION, files: [] };
  snapshot.directory = tempDir + '/amcl-share-' + selection.activityId + '-' + snapshot.createdAt + '-' + (++snapshotSequence);
  const opened: OpenEvidenceSource[] = [];
  acquireEvidenceLease(filesDir, selection.activityId);
  try {
    await verifySessionCaptureRotations(filesDir, selection.activityId);
    const available: EvidenceFileRecord[] = listSessionEvidence(filesDir, selection.activityId);
    if (normalizeEvidenceSelection(available, selected).length !== new Set<string>(selected).size) {
      throw new Error('所选证据已消失或不属于本次启动，请刷新文件清单');
    }
    for (const id of selected) {
      const record = available.find((file: EvidenceFileRecord): boolean => file.fileId === id);
      if (record === undefined || record.uploadPolicy === EvidenceUploadPolicy.NEVER) throw new Error('所选证据已消失或不可分享，请刷新文件清单');
      if (opened.some((item: OpenEvidenceSource): boolean => item.record.fileId === id)) continue;
      const file = fs.openSync(record.localPath, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(file.fd);
      if (!stat.isFile()) { fs.closeSync(file); throw new Error('证据不是普通文件'); }
      opened.push({ record: record, file: file, size: stat.size, inode: String(stat.ino) });
    }
    if (opened.length === 0) throw new Error('请至少选择一份证据文件');
    ensureDirSync(snapshot.directory);
    for (let index = 0; index < opened.length; index++) {
      const item = opened[index];
      const frozenPath: string = snapshot.directory + '/.source-' + index;
      const output = await fs.open(frozenPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      let digest: string = '';
      try { digest = await hashEvidenceRange(item.file.fd, item.size, output.fd); fs.fsyncSync(output.fd); }
      finally { await fs.close(output); }
      // 比较实际内容可识别同秒等长重写；原路径消失/替换一律失败。
      if (digest !== await hashEvidenceRange(item.file.fd, item.size)
        || String(fs.statSync(item.record.localPath).ino) !== item.inode) throw new Error('所选证据正在被改写，请稍后重试');
      const name: string = publicEvidenceName(item.record.path);
      if (snapshot.files.some((file: FrozenEvidenceFile): boolean => file.name === name)) throw new Error('公开文件名冲突');
      const path: string = snapshot.directory + '/' + name;
      const lines: number = await redactFrozenFile(frozenPath, item.record.path.endsWith('.gz'), path);
      fs.unlinkSync(frozenPath);
      const handle = await fs.open(path, fs.OpenMode.READ_ONLY);
      const bytes: number = fs.statSync(handle.fd).size;
      let redactedDigest: string = '';
      try { redactedDigest = await hashEvidenceRange(handle.fd, bytes); } finally { await fs.close(handle); }
      snapshot.files.push({ name: name, path: path, role: item.record.role, bytes: bytes,
        sourceBytes: item.size, digest: redactedDigest, lines: lines, state: item.record.state,
        rawSha256: item.record.rawSha256, captureMode: item.record.captureMode, verification: item.record.verification,
        reason: sanitizeLogForExport(item.record.reason, LogExportTarget.LOGSHARE, 1024) });
    }
    if (includeSummary && publicSummary.length > 0) {
      const content: string = sanitizeLogForExport(publicSummary, LogExportTarget.LOGSHARE, Number.MAX_SAFE_INTEGER);
      const name: string = '_amcl/session-info.txt';
      ensureDirSync(snapshot.directory + '/_amcl');
      writeEvidenceTextAtomic(snapshot.directory + '/' + name, content);
      snapshot.files.push({ name: name, path: snapshot.directory + '/' + name, role: 'public-summary',
        bytes: utf8ByteLength(content), sourceBytes: utf8ByteLength(content), digest: evidenceTextDigest(content),
        lines: content.split('\n').length, state: 'complete' });
    }
    const environment = readObservedSessionEnvironment(filesDir, selection.activityId);
    if (includeSummary) {
      appendDerivedFile_(snapshot, '_amcl/environment.json',
        sanitizeLogForExport(JSON.stringify(environment, null, 2), LogExportTarget.LOGSHARE, Number.MAX_SAFE_INTEGER));
    }
    // GET AI 保证接收到主正文与 ID；有界概览提供环境，完整日志以同 ID 独立附件保留。
    // 关闭会话摘要时不把环境暗中放回主正文，仍明确说明输入覆盖范围。
    const evidence = readSessionEvidence(filesDir, selection.activityId);
    const incomplete = available.filter((file: EvidenceFileRecord): boolean =>
      file.state === 'partial' || file.state === 'unavailable' || file.state === 'missing');
    let overview: string = 'AMCL_DIAGNOSIS_V2\nlauncher=AMCL\nactivityId=' + selection.activityId
      + '\nThis is diagnostic context, not the complete game log. Full selected files are attached to this same log ID.\n'
      + '游戏结局与日志完整性是独立事实；缺少文件不代表没有异常。\n'
      + 'captureIntegrity=' + (evidence?.integrityState ?? 'unknown')
      + '\nselectedFiles=' + snapshot.files.length + '\nuploadCoverage=selected-files\n';
    if (includeSummary) overview += sessionEnvironmentSummary(environment) + '\n'
      + sanitizeLogForExport(publicSummary, LogExportTarget.LOGSHARE, 1536) + '\n';
    else overview += 'environment=omitted by user; do not infer unrecorded platform or hardware\n';
    overview += 'Read _amcl/evidence-manifest.json for file names, source status and omitted/partial ranges.\n';
    for (const file of incomplete.slice(0, 8)) overview += 'captureGap=' + file.path + ': ' + file.reason.substring(0, 100) + '\n';
    for (const file of snapshot.files.slice(0, 12)) overview += 'file=' + file.name + ' (' + file.bytes + ' bytes, ' + file.state + ')\n';
    appendDerivedFile_(snapshot, EVIDENCE_DIAGNOSIS_NAME, sanitizeLogForExport(overview, LogExportTarget.LOGSHARE, 11000));
    sealEvidenceExportSnapshot(snapshot);
    return snapshot;
  } catch (e) {
    try { removeDirRecursive(snapshot.directory); } catch (ignored) { /* 尚未创建 */ }
    throw new Error((e as Error).message);
  } finally {
    for (const item of opened) { try { fs.closeSync(item.file); } catch (ignored) { /* 保留主错误 */ } }
    releaseEvidenceLease(filesDir, selection.activityId);
  }
}

/** 派生文本也进入预览、摘要和字节预算，不在网络发送时追加页面不可见的内容。 */
function appendDerivedFile_(snapshot: EvidenceExportSnapshot, name: string, content: string): void {
  ensureDirSync(snapshot.directory + '/_amcl');
  const path: string = snapshot.directory + '/' + name;
  writeEvidenceTextAtomic(path, content);
  snapshot.files.push({ name: name, path: path, role: 'public-summary', bytes: utf8ByteLength(content),
    sourceBytes: utf8ByteLength(content), digest: evidenceTextDigest(content), lines: content.split('\n').length,
    state: 'complete', captureMode: 'derived', verification: 'snapshot-verified' });
}

/** 公共清单是保留文件边界、摘要与节选状态的唯一派生产物。 */
export function sealEvidenceExportSnapshot(snapshot: EvidenceExportSnapshot): void {
  const identity: string[] = snapshot.files.map((file: FrozenEvidenceFile): string => file.name + ':' + file.digest);
  snapshot.digest = evidenceTextDigest(EVIDENCE_EXPORT_FORMAT + '\n' + EVIDENCE_REDACTION_VERSION + '\n' + identity.join('\n'));
  const manifest: PublicSnapshotManifest = { schema: 1, activityId: snapshot.activityId, createdAt: snapshot.createdAt,
    digest: snapshot.digest, redactionVersion: snapshot.redactionVersion,
    files: snapshot.files.map((file: FrozenEvidenceFile): PublicSnapshotFile => {
      return { name: file.name, role: file.role, bytes: file.bytes, sourceBytes: file.sourceBytes,
        sha256: file.digest, lines: file.lines, state: file.state, reason: file.reason ?? '',
        rawSha256: file.rawSha256 ?? '', captureMode: file.captureMode ?? 'legacy', verification: file.verification ?? 'unverified' };
    }) };
  const manifestName: string = '_amcl/evidence-manifest.json';
  const manifestText: string = JSON.stringify(manifest, null, 2);
  ensureDirSync(snapshot.directory + '/_amcl');
  writeEvidenceTextAtomic(snapshot.directory + '/' + manifestName, manifestText);
  snapshot.files.push({ name: manifestName, path: snapshot.directory + '/' + manifestName, role: 'public-summary',
    bytes: utf8ByteLength(manifestText), sourceBytes: utf8ByteLength(manifestText), digest: evidenceTextDigest(manifestText),
    lines: manifestText.split('\n').length, state: 'complete' });
}

/** 网络适配器只消费已冻结、已脱敏正文；预算按真实 UTF-8 字节计算。 */
export async function snapshotShareFiles(snapshot: EvidenceExportSnapshot,
  maxBytes: number, maxLines: number): Promise<EvidenceShareFile[]> {
  let bytes: number = 0;
  let lines: number = 0;
  for (const file of snapshot.files) { bytes += file.bytes; lines += file.lines; }
  if (bytes > maxBytes || lines > maxLines) throw new Error('所选日志超过服务限额，请减少所选文件或导出完整 ZIP');
  const files: EvidenceShareFile[] = [];
  for (const file of snapshot.files) {
    const content = await readEvidenceTextBounded(file.path, false, Math.max(file.bytes, 1));
    if (!content.eof || evidenceTextDigest(content.text) !== file.digest) throw new Error('冻结快照校验失败');
    files.push({ name: file.name, content: content.text });
  }
  return files;
}
export function disposeEvidenceExportSnapshot(snapshot: EvidenceExportSnapshot): void {
  removeDirRecursive(snapshot.directory);
}
