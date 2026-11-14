/**
 * 兼容手机试验包留下的 schema 2 覆盖日志。主线仍写原 schema 1 会话，
 * 只在用户发起恢复时验证精确旧基座及日志帧，再原子归并为 schema 1。
 * 浏览列表只读取基座摘要。完整读取和归并共用同一主执行环境的会话与句柄护栏。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { evidenceHex, evidenceTextDigest } from 'commons';
import { safeBaseName } from 'feature_core';
import { ModpackInstallSession } from './ModpackInstallSession';

export interface ModpackOverrideJournalRef { version: number; generation: string; name: string; indices: number[]; }
interface JournalHeader { version: number; sessionId: string; generation: string; baseSha256: string; baseBytes: number; }
interface CommitBody { seq: number; index: number; previous: string; }
interface CommitEnvelope { payload: string; sha256: string; }
interface PendingClose { file: fs.File; inode: string; }
interface JournalScope { directory: string; id: string; key: string; }

/** 兼容层沿用唯一的 schema 1 结构校验与耐久发布实现。 */
export interface ModpackJournalPorts {
  validate(value: ModpackInstallSession, id: string): ModpackInstallSession;
  writeText(path: string, text: string): void;
}

const BASE_LIMIT = 64 * 1024 * 1024;
const LINE_LIMIT = 4 * 1024;
const LOG_LIMIT = 132 * 1024;
const SHA256 = /^[a-f0-9]{64}$/;
const activeRecoveries: Set<string> = new Set<string>();
// close 抛错时保留句柄及原 inode。只有在原执行环境证明身份一致后才能重试关闭。
const pendingCloses: Map<string, PendingClose[]> = new Map<string, PendingClose[]>();

function directoryStat(path: string): fs.Stat {
  const stat = fs.lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('覆盖日志目录不是普通目录');
  return stat;
}

/** 同一物理工作目录的路径别名必须命中同一会话锁。拒绝链接和未知 inode。 */
function journalScope(directory: string, id: string): JournalScope {
  directoryStat(directory.substring(0, directory.lastIndexOf('/')));
  const inode = String(directoryStat(directory).ino);
  if (!/^[1-9][0-9]*$/.test(inode)) throw new Error('覆盖日志工作目录身份无效');
  return { directory: directory, id: id, key: inode + ':' + id };
}

export function assertNoModpackJournalWriter(directory: string, id: string): void {
  const key = journalScope(directory, id).key;
  if (activeRecoveries.has(key) || pendingCloses.has(key)) throw new Error('覆盖日志正在恢复或句柄关闭未确认');
}

/**
 * 在打开前绑定会话身份。即使随后路径发生变化，也必须尝试关闭已打开的原句柄。
 * 关闭失败由本会话保留，禁止普通保存或清理绕过不确定状态。
 */
export function bindModpackJournalClose(directory: string, id: string): (file: fs.File) => void {
  const key = journalScope(directory, id).key;
  return (file: fs.File): void => closeTrackedFile(key, file);
}

function closeTrackedFile(key: string, file: fs.File): void {
  let inode = '';
  try { inode = String(fs.statSync(file.fd).ino); }
  catch (_) { /* 没有身份也必须尝试关闭，失败后由进程退出恢复。 */ }
  try { fs.closeSync(file); }
  catch (error) {
    const files = pendingCloses.get(key) ?? [];
    if (!files.some((entry: PendingClose): boolean => entry.file === file)) files.push({ file: file, inode: inode });
    pendingCloses.set(key, files);
    throw new Error('覆盖日志句柄关闭未确认：' + (error as Error).message);
  }
}

function retryPendingCloses(key: string): void {
  const files = pendingCloses.get(key);
  if (files === undefined) return;
  while (files.length > 0) {
    const entry = files[0];
    if (entry.inode.length === 0 || String(fs.statSync(entry.file.fd).ino) !== entry.inode)
      throw new Error('覆盖日志未确认句柄身份已变化，请重启后恢复');
    fs.closeSync(entry.file);
    files.shift();
  }
  pendingCloses.delete(key);
}

function regularFile(path: string): fs.Stat {
  const stat = fs.lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('覆盖日志原件不是普通文件');
  return stat;
}

/** 补齐短读并前后核对打开句柄、文件路径和父目录身份，覆盖日志的大小必须先受限。 */
function readExact(scope: JournalScope, path: string, limit: number): Uint8Array {
  const directory = path.substring(0, path.lastIndexOf('/'));
  const parent = directoryStat(directory);
  const before = regularFile(path);
  if (before.size <= 0 || before.size > limit) throw new Error('覆盖日志原件字节预算无效');
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
  try {
    if (fs.statSync(file.fd).ino !== before.ino) throw new Error('覆盖日志原件打开时身份变化');
    const bytes = new Uint8Array(before.size);
    const part = new ArrayBuffer(Math.min(64 * 1024, before.size));
    let offset = 0;
    while (offset < bytes.byteLength) {
      const length = Math.min(part.byteLength, bytes.byteLength - offset);
      // FileKit 的 offset 相对当前文件指针。独占 FD 顺序读取只传 length。
      const count = fs.readSync(file.fd, part, { length: length });
      if (!Number.isSafeInteger(count) || count <= 0 || count > length) throw new Error('覆盖日志原件短读');
      bytes.set(new Uint8Array(part, 0, count), offset);
      offset += count;
    }
    const after = regularFile(path);
    if (after.ino !== before.ino || after.size !== before.size || directoryStat(directory).ino !== parent.ino
      || journalScope(scope.directory, scope.id).key !== scope.key) throw new Error('覆盖日志读取期间身份变化');
    return bytes;
  } finally { closeTrackedFile(scope.key, file); }
}

/** 兼容精确 UTF-8 字节契约。替换字符、BOM 或重编码不能伪装为原基座。 */
function decode(bytes: Uint8Array): string {
  const text = util.TextDecoder.create('utf-8', { fatal: true, ignoreBOM: true }).decodeToString(bytes);
  const encoded = new util.TextEncoder().encodeInto(text);
  if (encoded.byteLength !== bytes.byteLength) throw new Error('覆盖日志 UTF-8 原字节不一致');
  for (let index = 0; index < bytes.byteLength; index++) {
    if (bytes[index] !== encoded[index]) throw new Error('覆盖日志 UTF-8 原字节不一致');
  }
  return text;
}

function fields(value: Object, expected: string[]): void {
  if (value === null || typeof value !== 'object' || Array.isArray(value)
    || Object.keys(value).sort().join('|') !== expected.slice().sort().join('|')) throw new Error('覆盖日志字段无效');
}

function reference(value: ModpackInstallSession): ModpackOverrideJournalRef {
  const ref = value.overrideJournal;
  if (ref === undefined) throw new Error('覆盖日志引用缺失');
  fields(ref, ['version', 'generation', 'name', 'indices']);
  if (ref.version !== 1 || typeof ref.generation !== 'string' || safeBaseName(ref.generation) !== ref.generation
    || ref.generation.length === 0 || ref.name !== '.override-' + ref.generation
    || safeBaseName(ref.name) !== ref.name || !Array.isArray(ref.indices) || ref.indices.length < 1 || ref.indices.length > 32)
    throw new Error('覆盖日志引用不安全');
  const seen = new Set<number>();
  const targets = new Set<string>();
  for (const index of ref.indices) {
    const record = value.overrideReceipts?.[index];
    if (!Number.isSafeInteger(index) || index < 0 || seen.has(index) || record === undefined || record.committed
      || targets.has(record.path)) throw new Error('覆盖日志预备索引无效');
    seen.add(index);
    targets.add(record.path);
  }
  return ref;
}

/** 同步借用 schema 1 视图执行原有结构检查，返回前恢复原版本和引用。 */
function validateAsSchemaOne(value: ModpackInstallSession, id: string, ports: ModpackJournalPorts): void {
  const ref = value.overrideJournal;
  try {
    value.schemaVersion = 1;
    value.overrideJournal = undefined;
    ports.validate(value, id);
  } finally {
    value.schemaVersion = 2;
    value.overrideJournal = ref;
  }
}

/**
 * 按旧协议验证精确基座、规范 JSON、每帧摘要、链序和预备索引。
 * 只忽略最后一段没有换行的未提交字节，完整但损坏的记录必须拒绝。
 */
function project(scope: JournalScope, raw: string, ports: ModpackJournalPorts): ModpackInstallSession {
  const base = readExact(scope, scope.directory + '/session.json', BASE_LIMIT);
  if (decode(base) !== raw) throw new Error('覆盖日志基座观察已变化');
  const value = JSON.parse(raw) as ModpackInstallSession;
  if (value?.schemaVersion !== 2 || value.id !== scope.id) throw new Error('覆盖日志基座身份无效');
  const ref = reference(value);
  validateAsSchemaOne(value, scope.id, ports);

  const bytes = readExact(scope, scope.directory + '/' + ref.name + '/commit.jsonl', LOG_LIMIT);
  const lines: string[] = [];
  let start = 0;
  for (let index = 0; index < bytes.byteLength; index++) {
    if (bytes[index] !== 10) continue;
    if (index - start > LINE_LIMIT || index === start) throw new Error('覆盖日志完整行无效');
    lines.push(decode(bytes.slice(start, index)));
    start = index + 1;
  }
  if (bytes.byteLength - start > LINE_LIMIT || lines.length < 1 || lines.length > ref.indices.length + 1)
    throw new Error('覆盖日志行预算无效');
  const header = JSON.parse(lines[0]) as JournalHeader;
  fields(header, ['version', 'sessionId', 'generation', 'baseSha256', 'baseBytes']);
  // 原协议摘要是 UTF-8 的 SHA-256。直接对已核验的字节求摘要，省去大基座的逐字符编码。
  const digest = cryptoFramework.createMd('SHA256');
  digest.updateSync({ data: base });
  if (header.version !== 1 || header.sessionId !== scope.id || header.generation !== ref.generation
    || header.baseSha256 !== evidenceHex(digest.digestSync().data) || header.baseBytes !== base.byteLength
    || JSON.stringify({ version: header.version, sessionId: header.sessionId, generation: header.generation,
      baseSha256: header.baseSha256, baseBytes: header.baseBytes }) !== lines[0]) throw new Error('覆盖日志与精确基座身份不符');

  let previous = evidenceTextDigest(lines[0]);
  const applied = new Set<string>(value.overrideFiles);
  for (let index = 1; index < lines.length; index++) {
    const envelope = JSON.parse(lines[index]) as CommitEnvelope;
    fields(envelope, ['payload', 'sha256']);
    if (typeof envelope.payload !== 'string' || !SHA256.test(envelope.sha256)
      || evidenceTextDigest(envelope.payload) !== envelope.sha256
      || JSON.stringify({ payload: envelope.payload, sha256: envelope.sha256 }) !== lines[index])
      throw new Error('覆盖日志完整帧摘要无效');
    const body = JSON.parse(envelope.payload) as CommitBody;
    fields(body, ['seq', 'index', 'previous']);
    if (body.seq !== index || body.index !== ref.indices[index - 1] || body.previous !== previous
      || JSON.stringify({ seq: body.seq, index: body.index, previous: body.previous }) !== envelope.payload)
      throw new Error('覆盖日志顺序或提交索引无效');
    const record = value.overrideReceipts![body.index];
    record.committed = true;
    if (!applied.has(record.path)) {
      value.overrideFiles.push(record.path);
      applied.add(record.path);
    }
    previous = envelope.sha256;
  }
  validateAsSchemaOne(value, scope.id, ports);
  return value;
}

/** 完整观察仍带有 schema 2 身份，调用方无法把只读投影冒充可写的 schema 1 会话。 */
export function readModpackJournalSession(directory: string, raw: string, id: string, ports: ModpackJournalPorts): ModpackInstallSession {
  return project(journalScope(directory, id), raw, ports);
}

/**
 * 显式恢复独占同一会话，归并后主线继续使用原 schema 1 写入流程。
 * 发布失败时保留基座或已经发布的完整 schema 1，旧日志原件不退役，冷启动可再次判断。
 */
export function recoverModpackJournalSession(directory: string, id: string, ports: ModpackJournalPorts): ModpackInstallSession {
  const scope = journalScope(directory, id);
  if (activeRecoveries.has(scope.key)) throw new Error('覆盖日志已经在恢复');
  retryPendingCloses(scope.key);
  activeRecoveries.add(scope.key);
  try {
    const path = directory + '/session.json';
    regularFile(path);
    const raw = fs.readTextSync(path);
    const value = JSON.parse(raw) as ModpackInstallSession;
    if (value?.schemaVersion === 1) return ports.validate(value, id);
    const restored = project(scope, raw, ports);
    restored.schemaVersion = 1;
    restored.overrideJournal = undefined;
    ports.writeText(path, JSON.stringify(restored));
    return restored;
  } finally { activeRecoveries.delete(scope.key); }
}
