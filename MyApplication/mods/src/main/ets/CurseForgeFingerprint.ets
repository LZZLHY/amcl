/**
 * CurseForge 文件指纹的公共异步入口。
 * 工作线程两遍分块读取并过滤 09/0A/0D/20 字节，再计算 seed=1 的 MurmurHash2；
 * 固定缓冲避免整文件与过滤副本同时驻留。原有输入上限和失败返回 0 的约定保留。
 */
import { AppLogger, LOG_DOMAIN_DOWNLOAD } from 'commons';
import { computeLocalModFingerprint } from './LocalModFileTasks';
import { LocalModScanControl } from './ModScanWork';

// 保持既有纯函数导出，算法一致性测试及其他消费者无需改名。
export { murmur2 } from './CurseForgeMurmur2';

/** 普通读取错误返回 0；扫描取消也返回 0，调用方仍须检查控制器后停止后继反查。 */
export async function computeCurseForgeFingerprint(path: string, control?: LocalModScanControl): Promise<number> {
  try {
    return await computeLocalModFingerprint(path, control);
  } catch (e) {
    if (!control?.isCancelled()) {
      AppLogger.warn('CurseForgeFingerprint', `fingerprint failed: ${path}`, e as Object, LOG_DOMAIN_DOWNLOAD);
    }
    return 0;
  }
}
