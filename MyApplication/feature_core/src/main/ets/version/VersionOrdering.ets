/**
 * VersionOrdering.ets — 版本列表显示顺序合并（三层架构第4步：Index 纯逻辑下沉到 feature_core）。
 *
 * 纯函数：把"用户自定义拖拽顺序"与"磁盘实际存在的版本"合并出最终显示顺序。
 * 无 @State / 无 IO / 无 UI 依赖，仅做集合 + 排序运算，便于独立复用与测试。
 */

/**
 * 合并自定义顺序与磁盘版本，产出显示顺序：
 *   1. 磁盘有、但不在保存顺序里的【新版本】→ 按 mtime 倒序（最新下载在最上面）置顶；
 *   2. 保存顺序里、且磁盘仍存在的版本 → 维持保存的相对顺序；
 *   3. 保存顺序里、但磁盘已删除的版本 → 忽略。
 *
 * @param present 磁盘实际存在的版本目录名
 * @param mtimes  版本目录名 → mtime（秒），用于新版本默认排序
 * @param saved   用户持久化的自定义顺序（PreferenceManager.versionOrder）
 */
export function mergeVersionOrder(
  present: string[], mtimes: Map<string, number>, saved: string[]): string[] {
  let result: string[] = [];
  // 1) 新版本（不在 saved 里）按 mtime 倒序
  let news: string[] = [];
  for (let v of present) {
    if (saved.indexOf(v) < 0) news.push(v);
  }
  news.sort((a: string, b: string) => (mtimes.get(b) ?? 0) - (mtimes.get(a) ?? 0));
  for (let v of news) result.push(v);
  // 2) saved 顺序里仍存在的版本
  for (let v of saved) {
    if (present.indexOf(v) >= 0) result.push(v);
  }
  return result;
}
