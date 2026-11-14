/**
 * JDK 安装的单一存储端口。HAR 只安排业务顺序，实际 ZIP 写入、执行模式、目录同步和
 * 持久 journal 由应用进程的 POSIX 实现负责；下载和本地导入不再各自实现双 rename。
 */
import { JdkDirectoryLease } from './JdkDirectoryLease';
import { JdkInstallJournal } from './JdkInstallJournal';
import { fileIo as fs } from '@kit.CoreFileKit';
import { stringToUtf8 } from 'commons';

export interface JdkInstallNativeOps {
  operation(action: string, filesDir: string, major: string, path: string, writerFd: number, useFd: number): string;
  extract(archive: string, stage: string, archiveSha256: string, timeoutMs: number): Promise<boolean>;
  seal(root: string, major: string, archiveSha256: string): Promise<boolean>;
}
let installed: JdkInstallNativeOps | undefined = undefined;
interface StorageIoError { code?: number | string; message?: string; }
/** 每个应用进程装配自己的端口；不得借用另一个进程的 fd/闭包。 */
export function setJdkInstallNativeOps(port: JdkInstallNativeOps): void { installed = port; }
function native(): JdkInstallNativeOps {
  if (installed === undefined) throw new Error('JDK 安装存储尚未初始化');
  return installed;
}
export class JdkInstallStorage {
  /**
   * 独立于数字目录/Manager列表枚举稳定发布记录。两次rename之间目标可暂缺，仍须把
   * legacy/native journal当未决；未知命名和I/O失败不能被空物理槽集合掩盖。仅查询不恢复。
   */
  static pendingRecoveryMajors(filesDir: string): string[] {
    const directory = filesDir + '/jdk/.locks';
    try {
      if (!fs.lstatSync(directory).isDirectory()) throw new Error('JDK恢复记录目录不是独立真实目录');
    } catch (error) {
      const detail = error as StorageIoError;
      if (detail.code === 13900002 || detail.code === 'ENOENT' || detail.message === 'ENOENT') return [];
      throw error as Error;
    }
    const names = fs.listFileSync(directory); if (names.length > 8192) throw new Error('JDK恢复目录项超限');
    const majors: string[] = [];
    for (const name of names) {
      if (!name.endsWith('.journal') && !name.endsWith('.publish.json')) continue;
      const match = name.match(new RegExp('^([1-9][0-9]{0,2})\\.(publish\\.json|journal)$'));
      if (match === null) throw new Error('发现无法识别的JDK未决发布记录，已保留现场');
      if (majors.indexOf(match[1]) < 0) majors.push(match[1]);
    }
    return majors.sort((a: string,b: string): number => Number(a) - Number(b));
  }

  /** 小型来源元数据在 staging 内完整写入并同步；中文按 UTF-8 字节而非 JS 字符数核对。 */
  static writeMetadata(path: string, value: string): void {
    const bytes = stringToUtf8(value);
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      let offset = 0;
      while (offset < bytes.byteLength) {
        const chunk = bytes.slice(offset, Math.min(offset + 65536, bytes.byteLength));
        const written = fs.writeSync(file.fd, chunk.buffer as ArrayBuffer);
        if (written <= 0 || written > chunk.byteLength) throw new Error('JDK 元数据写入不完整');
        offset += written;
      }
      fs.fsyncSync(file.fd);
    } finally { fs.closeSync(file); }
  }
  static recoveryRequired(filesDir: string, major: string): boolean {
    return JdkInstallJournal.recoveryRequired(filesDir, major) ||
      native().operation('pending', filesDir, major, '', -1, -1) === 'yes';
  }
  /** 只有存在 journal 才进入排他恢复；正常启动、正在准备 staging 的旧运行时不受影响。 */
  static recoverIfRequired(filesDir: string, major: string): void {
    if (!JdkInstallStorage.recoveryRequired(filesDir, major)) return;
    const writer = JdkDirectoryLease.writer(filesDir, major);
    try { JdkInstallStorage.recoverWithWriter(filesDir, major, writer); } finally { writer.release(); }
  }
  /** 调用方已经持 writer 时不能再次获取独立 OFD 的同一排他锁；仍只在必要时取 use.EX。 */
  static recoverWithWriter(filesDir: string, major: string, writer: JdkDirectoryLease): void {
    const legacy = JdkInstallJournal.recoveryRequired(filesDir, major);
    const pending = native().operation('pending', filesDir, major, '', -1, -1) === 'yes';
    // 两种格式不可能由同一个合格写者同时创建。遇到混合现场保持原件，不能先恢复
    // 一份再让另一份按过时inode删除刚恢复的目录；旧格式仅恢复，新发布统一走Native。
    if (legacy && pending) throw new Error('JDK存在两种未完成事务，保留现场等待核实');
    if (legacy) { JdkInstallJournal.recoverWithWriter(filesDir, major); return; }
    if (!pending) return;
    const use = JdkDirectoryLease.publication(filesDir, major);
    try { native().operation('recover', filesDir, major, '', writer.descriptor(), use.descriptor()); }
    finally { use.release(); }
  }
  /** App计划已持全局EX，按记录发现暂缺数字槽；传真实plan owner取得writer，不绕过锁。 */
  static recoverAllWithOwner(filesDir: string, planId: string): void {
    const directory = filesDir + '/jdk/.locks';
    const names = fs.listFileSync(directory);
    if (names.length > 8192) throw new Error('JDK恢复目录项超限');
    const majors: string[] = [];
    for (const name of names) {
      const match = name.match(new RegExp('^([1-9][0-9]{0,2})\\.(publish\\.json|journal|stage)$'));
      if (match === null || majors.indexOf(match[1]) >= 0) continue;
      majors.push(match[1]);
      const writer = JdkDirectoryLease.writer(filesDir, match[1], planId);
      try {
        JdkInstallStorage.recoverWithWriter(filesDir, match[1], writer);
        native().operation('collect', filesDir, match[1], '', writer.descriptor(), -1);
      } finally { writer.release(); }
    }
  }
  /** 只有目录枚举发现稳定stage归属记录才调用；writer冲突即延后，不阻塞合法旧安装读者。 */
  static collectAbandonedStage(filesDir: string, major: string): void {
    const writer = JdkDirectoryLease.writer(filesDir, major);
    try {
      JdkInstallStorage.recoverWithWriter(filesDir, major, writer);
      native().operation('collect', filesDir, major, '', writer.descriptor(), -1);
    } finally { writer.release(); }
  }
  static createStage(filesDir: string, major: string, writer: JdkDirectoryLease): string {
    return native().operation('create', filesDir, major, '', writer.descriptor(), -1);
  }
  /** 底层 Promise 只有在执行者退出后才 settle，取消/超时不能提前清目录。 */
  static async extract(archive: string, stage: string, archiveSha256: string): Promise<void> {
    if (!await native().extract(archive, stage, archiveSha256, 300000)) throw new Error('JDK ZIP 解压未完成');
  }
  static async seal(root: string, major: string, archiveSha256: string): Promise<void> {
    if (!await native().seal(root, major, archiveSha256)) throw new Error('JDK 安装内容尚未封存');
  }
  static publish(filesDir: string, major: string, root: string, writer: JdkDirectoryLease, use: JdkDirectoryLease): void {
    native().operation('publish', filesDir, major, root, writer.descriptor(), use.descriptor());
  }
  /** 有未恢复记录时 native 保留 staging；不能由 ArkTS finally 删除唯一新/旧副本。 */
  static discard(filesDir: string, major: string, stage: string, writer: JdkDirectoryLease): void {
    if (stage.length > 0) native().operation('discard', filesDir, major, stage, writer.descriptor(), -1);
  }
  static delete(filesDir: string, major: string, writer: JdkDirectoryLease, use: JdkDirectoryLease): void {
    native().operation('delete', filesDir, major, '', writer.descriptor(), use.descriptor());
  }
  /** 字体配置由宿主独立内容地址管理，任何来源的 JDK 槽位都保持原始文件集合。 */
  static prepareFonts(filesDir: string): void { native().operation('fonts', filesDir, '', '', -1, -1); }
}
