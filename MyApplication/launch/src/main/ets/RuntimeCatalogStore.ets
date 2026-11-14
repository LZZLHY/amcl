/**
 * 签名目录的耐久写边界。所有文本先编码为 UTF-8，以真实写入字节数推进；短写、零写、
 * 文件同步或目录同步失败均不报告提交成功。临时文件与正式文件同目录，拒绝跟随末级链接。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ensureDirSync } from 'commons';

/** 目录项的建立/替换也必须刷盘；只同步文件不能证明 rename 在断电后仍可见。 */
export function syncRuntimeCatalogDirectory(path: string): void {
  const directory = fs.openSync(path,fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
  try { fs.fsyncSync(directory.fd); } finally { fs.closeSync(directory); }
}

/** 调用者先验证签名和语义；本函数只提交已经有界的原文字节，不重新序列化 JWS。 */
export function writeRuntimeCatalogAtomic(filesDir: string, directory: string, path: string, raw: string): void {
  ensureDirSync(directory);
  // 初次创建 runtime-catalog/v2 时，逐层同步祖先；日常复用也走同一小型固定路径。
  syncRuntimeCatalogDirectory(filesDir);
  if (directory !== filesDir + '/runtime-catalog') syncRuntimeCatalogDirectory(filesDir + '/runtime-catalog');
  const bytes = new util.TextEncoder().encodeInto(raw);
  const file = fs.openSync(path + '.writing',fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW);
  try {
    let offset = 0;
    while (offset < bytes.byteLength) {
      const chunk = bytes.slice(offset,Math.min(offset + 65536,bytes.byteLength));
      const written = fs.writeSync(file.fd,chunk.buffer as ArrayBuffer);
      if (!Number.isSafeInteger(written) || written <= 0 || written > chunk.byteLength) throw new Error('JDK目录未完整写入');
      offset += written;
    }
    fs.fsyncSync(file.fd);
  } finally { fs.closeSync(file); }
  fs.renameSync(path + '.writing',path);
  syncRuntimeCatalogDirectory(directory);
}
