/**
 * PathUtils.ets — 通用路径/字节/时间格式化工具（v5 新增）
 *
 * 抽出这个模块的目的：
 *   - DownloadFloatingBar / DownloadPanel / McDownloader 多处都要做 basename
 *     和字节/时间 format
 *   - 原 DownloadManager.ets 里的 formatBytes/formatSpeed 保留作为别名
 *     （向后兼容），这里补齐其他格式化工具
 */

/** 取路径的 basename（最后一个 / 或 \ 之后的部分）；空串返回空串 */
export function basename(p: string): string {
  if (!p) return '';
  const i = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
  return i >= 0 ? p.substring(i + 1) : p;
}

/**
 * 格式化字节数为人类可读字符串。
 *   1234    → "1.2 KB"
 *   1234567 → "1.2 MB"
 */
export function formatBytes(bytes: number): string {
  if (bytes < 0) return '-';
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}

/** 同 formatBytes 但带 "/s" 后缀 */
export function formatSpeed(bps: number): string {
  return formatBytes(bps) + '/s';
}

/**
 * 格式化剩余秒数为人类可读时长字符串。
 *   seconds < 0 → ""（UI 隐藏）
 *   seconds < 60 → "42 秒"
 *   seconds < 3600 → "1 分 23 秒"
 *   否则 → "1 小时 23 分"
 */
export function formatEta(seconds: number): string {
  if (seconds < 0) return '';
  if (seconds < 60) return `${seconds} 秒`;
  if (seconds < 3600) {
    let m = Math.floor(seconds / 60);
    let s = seconds % 60;
    return s === 0 ? `${m} 分` : `${m} 分 ${s} 秒`;
  }
  let h = Math.floor(seconds / 3600);
  let m = Math.floor((seconds % 3600) / 60);
  return m === 0 ? `${h} 小时` : `${h} 小时 ${m} 分`;
}

/**
 * 格式化任务耗时（毫秒）为 "0:35" / "1:23" / "1:02:15"
 * 给 DownloadPanel 的"已用"字段用。
 */
export function formatDurationMs(ms: number): string {
  if (ms < 0) return '';
  let totalSec = Math.floor(ms / 1000);
  let s = totalSec % 60;
  let m = Math.floor(totalSec / 60) % 60;
  let h = Math.floor(totalSec / 3600);
  let pad = (n: number) => n < 10 ? '0' + n : n.toString();
  if (h > 0) return `${h}:${pad(m)}:${pad(s)}`;
  return `${m}:${pad(s)}`;
}

/**
 * 把百分比（0~1 的 double）格式化为 "12%" / "0.5%"（小数点前有值时省略）。
 */
export function formatPercent(progress: number): string {
  if (!isFinite(progress) || progress <= 0) return '0%';
  const p = progress * 100;
  if (p >= 10) return Math.round(p) + '%';
  return p.toFixed(1) + '%';
}
