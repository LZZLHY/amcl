/**
 * FontconfigUtils.ets — 查找 libfontconfig.so 源文件
 *
 * 工程注意：原本 RuntimeDeployer 和 ForgeService 各维护一份完全相同的候选路径
 * 列表 + resolveFontconfigSource 逻辑（D12-4，self-inspection 报告）。
 * 2026-05-06 收敛到此模块。
 *
 * 行为：在固定的系统目录 + 衍生的 app libs 目录中搜索可用的 libfontconfig.so，
 *       要求文件大小 > FONTCONFIG_MIN_SIZE_BYTES（防止抓到 stub / 空占位文件）。
 *
 * 调用方策略：RuntimeDeployer 与 ForgelikeInstaller 都把它视为可选兼容库；找不到时
 * 记录日志并继续。Forge/NeoForge processors 运行在 `java.awt.headless=true`，不能把
 * JDK 或系统未携带 fontconfig 误判为安装前置失败。本工具仅负责返回 null 或有效路径。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'FontconfigUtils';

/** 合法 libfontconfig.so 的最小大小阈值（拦截 stub / 空占位） */
export const FONTCONFIG_MIN_SIZE_BYTES = 4096;

/**
 * 在系统目录 + app libs 目录中查找 libfontconfig.so，返回首个 size > 阈值的路径。
 *
 * @param filesDir app 的 filesDir（用于反推 app bundle libs 目录）
 * @returns 找到则返回完整路径，否则返回 null
 */
export function resolveFontconfigSource(filesDir: string): string | null {
  let candidates: string[] = [
    '/data/storage/el1/bundle/libs/arm64/libfontconfig.so',
    '/data/storage/el1/bundle/libs/arm64-v8a/libfontconfig.so',
    '/data/storage/el1/bundle/libs/libfontconfig.so',
    '/system/lib64/libfontconfig.so',
    '/system/lib/libfontconfig.so',
  ];

  // 某些历史或自定义 JDK 包可能携带 libfontconfig.so.1，因此把已安装 JDK 也列为
  // best-effort 候选；但发布中的 JDK 17/21/25 均不保证提供它，不能假设任一版本“一定有”。
  // 该库若存在可跨目标 JDK 复用。优先 .so.1，再尝试 .so。
  for (let ver of ['17', '21', '25']) {
    candidates.push(filesDir + '/jdk/' + ver + '/lib/libfontconfig.so.1');
    candidates.push(filesDir + '/jdk/' + ver + '/lib/libfontconfig.so');
  }

  // 从 filesDir 反推 app 目录加入更多候选
  let idx = filesDir.lastIndexOf('/');
  if (idx > 0) {
    let parent = filesDir.substring(0, idx);
    candidates.push(parent + '/libs/arm64/libfontconfig.so');
    candidates.push(parent + '/libs/arm64-v8a/libfontconfig.so');
    candidates.push(parent + '/lib/libfontconfig.so');
    candidates.push(parent + '/lib64/libfontconfig.so');
  }

  for (let path of candidates) {
    try {
      let st = fs.statSync(path);
      if (st.size > FONTCONFIG_MIN_SIZE_BYTES) {
        hilog.info(0x0000, TAG, 'Selected fontconfig source: %{public}s (%{public}d bytes)', path, st.size);
        return path;
      }
    } catch (e) { /* continue */ }
  }
  hilog.warn(0x0000, TAG, 'No usable fontconfig source found. tried=%{public}s', JSON.stringify(candidates));
  return null;
}
