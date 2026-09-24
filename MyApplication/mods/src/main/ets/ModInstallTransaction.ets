/** Directory-scoped, recoverable activation of a complete mod set. */
import { fileIo as fs } from '@kit.CoreFileKit';
import { computeFileSha1, safeBaseName, safeRelPath } from 'feature_core';
import { removeDirRecursive, AppLogger, LOG_DOMAIN_DOWNLOAD } from 'commons';

const JOURNAL = '.amcl-mod-transaction.json';
const tails = new Map<string, Promise<void>>();
const counts = new Map<string, number>();
let sequence = 0;

export interface ModFileChange {
  stagedRelative: string;
  newName: string;
  oldNames: string[];
  sha1: string;
}
interface BackupEntry { name: string; saved: string; }
interface TransactionJournal {
  schema: number;
  stagingName: string;
  committed: boolean;
  restored?: boolean;
  changes: ModFileChange[];
  backups: BackupEntry[];
}

export function modFileExists(path: string): boolean {
  try { fs.lstatSync(path); return true; } catch (e) { return false; }
}

export function ensureModDirectory(path: string): void {
  if (!modFileExists(path)) {
    try { fs.mkdirSync(path, true); }
    catch (e) { if (!modFileExists(path)) throw e as Error; }
  }
  const stat = fs.lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('不是可写的普通模组目录：' + path);
}

export function normalizeModDirectory(path: string): string {
  if (!path.startsWith('/') || path.indexOf('\\') >= 0 || path.indexOf('\u0000') >= 0)
    throw new Error('模组目录必须是绝对路径');
  const parts: string[] = [];
  for (const part of path.split('/')) {
    if (part.length === 0 || part === '.') continue;
    if (part === '..') throw new Error('模组目录包含上级路径');
    parts.push(part);
  }
  if (parts.length < 2 || parts[parts.length - 1] !== 'mods') throw new Error('无效的模组目录');
  return '/' + parts.join('/');
}

export function modTransactionPending(dir: string): boolean {
  return (counts.get(dir) ?? 0) > 0 || modFileExists(dir + '/' + JOURNAL);
}

export function modInstallationActive(dir: string): boolean { return (counts.get(dir) ?? 0) > 0; }
export function hasModRecoveryJournal(dir: string): boolean { return modFileExists(dir + '/' + JOURNAL); }

export async function withModDirectoryLock<T>(dir: string, work: () => Promise<T>): Promise<T> {
  const key = normalizeModDirectory(dir);
  const previous = tails.get(key) ?? Promise.resolve();
  let release: () => void = (): void => {};
  const own = new Promise<void>((resolve: () => void): void => { release = resolve; });
  const tail = previous.then((): Promise<void> => own);
  tails.set(key, tail);
  counts.set(key, (counts.get(key) ?? 0) + 1);
  await previous;
  try { return await work(); }
  finally {
    release();
    const count = (counts.get(key) ?? 1) - 1;
    if (count === 0) counts.delete(key); else counts.set(key, count);
    if (tails.get(key) === tail) tails.delete(key);
  }
}

export function createModStaging(dir: string): string {
  const parent = dir.substring(0, dir.lastIndexOf('/'));
  const name = '.amcl-mod-install-' + Date.now() + '-' + (++sequence);
  const staging = parent + '/' + name;
  fs.mkdirSync(staging, true);
  return staging;
}

export function writeModFile(path: string, text: string): void {
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try { fs.writeSync(file.fd, text); fs.fsyncSync(file.fd); }
  finally { fs.closeSync(file); }
}

function writeJournal(dir: string, journal: TransactionJournal): void {
  const target = dir + '/' + JOURNAL;
  const temp = target + '.tmp';
  writeModFile(temp, JSON.stringify(journal));
  fs.renameSync(temp, target);
}

function stagingFrom(dir: string, journal: TransactionJournal): string {
  const name = journal.stagingName;
  if (journal.schema !== 1 || safeBaseName(name) !== name || !name.startsWith('.amcl-mod-install-'))
    throw new Error('模组恢复记录的暂存目录无效');
  return dir.substring(0, dir.lastIndexOf('/')) + '/' + name;
}

function validateJournal(journal: TransactionJournal): void {
  if (typeof journal.committed !== 'boolean' || (journal.restored !== undefined && typeof journal.restored !== 'boolean')
    || (journal.committed && journal.restored === true) || !Array.isArray(journal.changes) || !Array.isArray(journal.backups))
    throw new Error('模组恢复记录状态无效');
  const targets = new Set<string>();
  for (const change of journal.changes) {
    if (safeBaseName(change.newName) !== change.newName || targets.has(change.newName)
      || safeRelPath(change.stagedRelative) !== change.stagedRelative || !change.stagedRelative.startsWith('download/')
      || !new RegExp('^[a-f0-9]{40}$').test(change.sha1)) throw new Error('模组恢复文件记录无效');
    targets.add(change.newName);
    for (const old of change.oldNames) if (safeBaseName(old) !== old) throw new Error('模组恢复旧文件名无效');
  }
  for (const backup of journal.backups) {
    if (safeBaseName(backup.name) !== backup.name || safeRelPath(backup.saved) !== backup.saved || !backup.saved.startsWith('backup/'))
      throw new Error('模组恢复备份记录无效');
  }
}

async function rollback(dir: string, staging: string, journal: TransactionJournal): Promise<void> {
  const failures: string[] = [];
  for (let i = journal.changes.length - 1; i >= 0; i--) {
    const change = journal.changes[i];
    const staged = staging + '/' + change.stagedRelative;
    const installed = dir + '/' + change.newName;
    // A missing staged file means it was promoted. Only remove the exact promoted bytes.
    if (!modFileExists(staged) && modFileExists(installed)) {
      try {
        if (await computeFileSha1(installed) !== change.sha1) throw new Error('文件在提交后被修改');
        fs.renameSync(installed, staged);
      } catch (e) { failures.push(change.newName + '：' + (e as Error).message); }
    }
  }
  for (let i = journal.backups.length - 1; i >= 0; i--) {
    const backup = journal.backups[i];
    const saved = staging + '/' + backup.saved;
    if (!modFileExists(saved)) continue;
    try {
      const old = dir + '/' + backup.name;
      if (modFileExists(old)) throw new Error('原位置有其他文件，已保留备份');
      fs.renameSync(saved, old);
    } catch (e) { failures.push(backup.name + '：' + (e as Error).message); }
  }
  if (failures.length > 0) throw new Error('模组恢复尚未完成，原文件备份保留在 ' + staging + '\n' + failures.join('\n'));
}

function cleanup(dir: string, staging: string): void {
  // This runs only after committed/restored is durable. Retain the terminal journal
  // until cleanup completes; a later recovery must not undo the already settled files.
  try {
    if (modFileExists(staging)) removeDirRecursive(staging);
    if (modFileExists(staging)) throw new Error('暂存目录仍有未清理文件');
    if (modFileExists(dir + '/' + JOURNAL)) fs.unlinkSync(dir + '/' + JOURNAL);
  } catch (e) {
    AppLogger.warn('ModInstallTransaction', '文件事务已完成，暂存清理将在下次访问时继续：' + (e as Error).message,
      null, LOG_DOMAIN_DOWNLOAD);
  }
}

/** Caller holds the directory lock. A prior interrupted commit must settle before another change. */
export async function recoverModTransaction(dir: string): Promise<void> {
  if (!modFileExists(dir + '/' + JOURNAL)) return;
  const journal = JSON.parse(fs.readTextSync(dir + '/' + JOURNAL)) as TransactionJournal;
  validateJournal(journal);
  const staging = stagingFrom(dir, journal);
  if (!journal.committed && journal.restored !== true) {
    await rollback(dir, staging, journal);
    journal.restored = true;
    writeJournal(dir, journal);
  }
  cleanup(dir, staging);
}

/** Downloads and manifest validation must already have succeeded. */
export async function commitModFiles(dir: string, staging: string, changes: ModFileChange[]): Promise<void> {
  if (modFileExists(dir + '/' + JOURNAL)) throw new Error('存在尚未恢复的模组安装');
  const name = staging.substring(staging.lastIndexOf('/') + 1);
  const journal: TransactionJournal = { schema: 1, stagingName: name, committed: false, changes: changes, backups: [] };
  if (stagingFrom(dir, journal) !== staging) throw new Error('模组暂存文件必须与目标位于同一父目录');
  const oldNames = new Set<string>();
  for (const change of changes) {
    const staged = staging + '/' + change.stagedRelative;
    const stat = fs.lstatSync(staged);
    if (!stat.isFile() || stat.isSymbolicLink() || await computeFileSha1(staged) !== change.sha1)
      throw new Error('模组提交前文件校验失败：' + change.newName);
    for (const old of change.oldNames) oldNames.add(old);
    if (modFileExists(dir + '/' + change.newName)) oldNames.add(change.newName);
  }
  ensureModDirectory(staging + '/backup');
  oldNames.forEach((old: string): void => {
    if (!modFileExists(dir + '/' + old)) return;
    const stat = fs.lstatSync(dir + '/' + old);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('拒绝替换非普通模组文件：' + old);
    journal.backups.push({ name: old, saved: 'backup/' + journal.backups.length + '-' + old });
  });
  validateJournal(journal);
  writeJournal(dir, journal);
  try {
    // No awaits between backup and activation: page events cannot observe a half-committed set.
    for (const backup of journal.backups) fs.renameSync(dir + '/' + backup.name, staging + '/' + backup.saved);
    for (const change of changes) fs.renameSync(staging + '/' + change.stagedRelative, dir + '/' + change.newName);
    journal.committed = true;
    writeJournal(dir, journal);
  } catch (e) {
    await rollback(dir, staging, journal);
    journal.committed = false;
    journal.restored = true;
    try {
      writeJournal(dir, journal);
      cleanup(dir, staging);
    } catch (cleanupError) {
      AppLogger.warn('ModInstallTransaction', '原文件已恢复，恢复记录将在下次访问时重试', cleanupError as Error, LOG_DOMAIN_DOWNLOAD);
    }
    throw e as Error;
  }
  cleanup(dir, staging);
}
