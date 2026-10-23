/**
 * TaskPool 线程内的本地资源文件操作。只使用线程安全文件、摘要和任务池模块；
 * 不访问 AppStorage、UI、日志单例或安装事务状态。句柄在每条退出路径关闭。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { taskpool } from '@kit.ArkTS';
import { LocalMod } from './ModTypes';
import { CurseForgeMurmur2 } from './CurseForgeMurmur2';

/** 每个文件或数据块开始时响应宿主取消；抛错使 TaskPool 不发布部分结果。 */
function checkCancelled(): void {
  if (taskpool.Task.isCanceled()) throw new Error('LocalModScanCancelled');
}

/** 完整枚举匹配扩展名的普通文件，不受来源反查预算限制，坏单项不影响其他项。 */
export function enumerateResourceFilesSync(directory: string, extensions: string[]): LocalMod[] {
  checkCancelled();
  let entries: string[];
  try { entries = fs.listFileSync(directory); } catch (_) { return []; }
  const mods: LocalMod[] = [];
  for (const filename of entries) {
    checkCancelled();
    const lower = filename.toLowerCase();
    if (!extensions.some((ext: string): boolean => ext.length > 0 && lower.endsWith(ext.toLowerCase()))) continue;
    const filePath = directory + '/' + filename;
    try {
      const stat = fs.statSync(filePath);
      if (!stat.isFile()) continue;
      mods.push({ filePath, filename, enabled: !lower.endsWith('.disabled'), sizeBytes: stat.size, sha1: '' });
    } catch (_) { /* 文件并发删除或不可读时保留其余清单。 */ }
  }
  return mods;
}

/** SHA-1 使用固定 256 KiB 缓冲；每块检查取消，不改变项目共享摘要函数的接口。 */
export function computeModSha1Sync(path: string): string {
  let file: fs.File | null = null;
  try {
    checkCancelled();
    const md = cryptoFramework.createMd('SHA1');
    file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const buffer = new ArrayBuffer(256 * 1024);
    while (true) {
      checkCancelled();
      const size = fs.readSync(file.fd, buffer);
      if (size <= 0) break;
      md.updateSync({ data: new Uint8Array(buffer, 0, size) });
    }
    checkCancelled();
    const digest = md.digestSync();
    let hex = '';
    for (let i = 0; i < digest.data.length; i++) hex += digest.data[i].toString(16).padStart(2, '0');
    return hex;
  } catch (e) {
    // 工作线程不依赖日志单例；错误交回宿主，finally 仍先归还句柄。
    throw e as Error;
  } finally {
    if (file !== null) { try { fs.closeSync(file); } catch (_) { /* 关闭失败不覆盖原异常。 */ } }
  }
}

/**
 * CF 指纹用两遍读取保持原算法：第一遍计过滤后的总长度，第二遍逐字节推进同一状态。
 * 每遍重新打开文件并顺序读取，处理短读而不把 offset 当缓冲区偏移。
 * 内存固定 256 KiB；保留原 96 MiB 输入上限，空文件/过大文件返回 0。
 */
export function computeModFingerprintSync(path: string): number {
  try {
    checkCancelled();
    const stat = fs.statSync(path);
    if (stat.size <= 0 || stat.size > 96 * 1024 * 1024) return 0;
    const buffer = new ArrayBuffer(256 * 1024);
    let kept = 0;
    let firstBytes = 0;
    for (let pass = 0; pass < 2; pass++) {
      let file: fs.File | null = null;
      const state = new CurseForgeMurmur2(kept);
      let total = 0;
      try {
        checkCancelled();
        file = fs.openSync(path, fs.OpenMode.READ_ONLY);
        while (true) {
          checkCancelled();
          const size = fs.readSync(file.fd, buffer);
          if (size <= 0) break;
          total += size;
          if (total > stat.size) throw new Error('Fingerprint input changed');
          const bytes = new Uint8Array(buffer, 0, size);
          for (let i = 0; i < size; i++) {
            const byte = bytes[i];
            if (byte === 9 || byte === 10 || byte === 13 || byte === 32) continue;
            if (pass === 0) kept++;
            else state.append(byte);
          }
        }
        if (total !== stat.size) throw new Error('Fingerprint input changed');
        if (pass === 0) firstBytes = total;
        else {
          const after = fs.statSync(path);
          if (after.size !== firstBytes || after.mtime !== stat.mtime) throw new Error('Fingerprint input changed');
          checkCancelled();
          return state.finish();
        }
      } finally {
        if (file !== null) { try { fs.closeSync(file); } catch (_) { /* 保留原始取消或文件错误。 */ } }
      }
    }
    return 0;
  } catch (e) {
    // 保留读取、文件变化和取消的区别，公开异步包装负责普通错误的降级日志。
    throw e as Error;
  }
}
