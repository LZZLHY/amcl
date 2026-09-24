/**
 * 活动账本 V2 的纯展示模型。
 * 只处理分类、筛选、日期分组和 AI 摘要，不访问文件或网络，也不改变活动终态。
 * 页面与平板详情共用这些规则，避免同一条活动在不同布局中出现不同标签。
 */
import { ActivityCategory, DownloadHistoryRecord } from 'feature_core';

/** 筛选值同时用于按钮标识；不把“没有 AI”解释为失败。 */
export enum ActivityFilter {
  ALL = 'all',
  GAME = 'game',
  DOWNLOAD = 'download',
  ABNORMAL = 'abnormal',
}

/** 一组本地日历日期内的活动；调用方提供的记录不会被排序或修改。 */
export interface ActivityDayGroup {
  key: string;
  label: string;
  records: DownloadHistoryRecord[];
}

/** 今日概览只统计活动结局，不统计 AI 请求结局。 */
export interface ActivityDayStats {
  total: number;
  completed: number;
  interrupted: number;
  failed: number;
}

/** 色轴按真实计数分配组宽；组内最多八条刻线，避免大账本创建数千个节点。 */
export interface ActivityStatusBand {
  status: string;
  count: number;
  ticks: number[];
}

export function activityStatusBands(stats: ActivityDayStats): ActivityStatusBand[] {
  const bands: ActivityStatusBand[] = [
    { status: 'success', count: stats.completed, ticks: [] },
    { status: 'interrupted', count: stats.interrupted, ticks: [] },
    { status: 'failed', count: stats.failed, ticks: [] },
    { status: 'other', count: Math.max(0, stats.total - stats.completed - stats.interrupted - stats.failed), ticks: [] },
  ];
  const visible: ActivityStatusBand[] = [];
  for (const band of bands) {
    if (band.count <= 0) continue;
    for (let index: number = 0; index < Math.min(8, band.count); index++) band.ticks.push(index);
    visible.push(band);
  }
  return visible;
}

/** 左侧时间轴使用本地时分；日期由外层日期分组呈现，不在每张卡片重复。 */
export function activityClock(timestamp: number): string {
  if (!Number.isFinite(timestamp) || timestamp <= 0) return '—';
  const date: Date = new Date(timestamp);
  const hour: number = date.getHours();
  const minute: number = date.getMinutes();
  return (hour < 10 ? '0' : '') + hour + ':' + (minute < 10 ? '0' : '') + minute;
}

/** 为尚未写入 category 的旧记录提供与历史页面相同的回退。 */
export function activityCategory(record: DownloadHistoryRecord): string {
  if (record.category && record.category.length > 0) return record.category;
  return record.loaderType.indexOf('mod-') === 0 ? ActivityCategory.MOD_INSTALL : ActivityCategory.DOWNLOAD;
}

/** 常见生成型版本 ID 在列表中使用可辨认短名；自定义名称保持原样，详情仍保留完整 ID。 */
export function activityDisplayTitle(record: DownloadHistoryRecord): string {
  const title: string = record.title || record.versionName;
  if (activityCategory(record) !== ActivityCategory.LAUNCH) return title;
  const fabric = title.match(new RegExp('^fabric-loader-[0-9.]+-(.+)$'));
  if (fabric !== null) return 'Minecraft ' + fabric[1] + ' · Fabric';
  const loader = title.match(new RegExp('^([0-9][0-9.a-z-]*)-(forge|neoforge)-[0-9.]+(?:-.*)?$', 'i'));
  if (loader !== null) return 'Minecraft ' + loader[1] + ' · ' + (loader[2].toLowerCase() === 'forge' ? 'Forge' : 'NeoForge');
  return title;
}

/** 下载、模组、整合包和 JDK 都归入用户理解的“下载”，原记录类别不变。 */
export function isDownloadActivity(record: DownloadHistoryRecord): boolean {
  const category: string = activityCategory(record);
  return category === ActivityCategory.DOWNLOAD || category === ActivityCategory.MOD_INSTALL
    || category === ActivityCategory.MODPACK || category === ActivityCategory.JDK;
}

/** 异常筛选包含失败、崩溃和中断；成功记录不会因 AI 推测而被重新分类。 */
export function isAbnormalActivity(record: DownloadHistoryRecord): boolean {
  return record.status === 'failed' || record.status === 'crashed' || record.status === 'aborted'
    || record.status === 'interrupted';
}

/** 文案区分游戏中断与下载取消，避免把正常取消描述成崩溃。 */
export function activityStatusLabel(record: DownloadHistoryRecord): string {
  if (record.status === 'success') return activityCategory(record) === ActivityCategory.LAUNCH ? '正常退出' : '已完成';
  if (record.status === 'failed') return '失败';
  if (record.status === 'crashed') return '异常退出';
  if (record.status === 'running') return '进行中';
  if (record.status === 'interrupted') return '已中断';
  if (record.status === 'aborted') return activityCategory(record) === ActivityCategory.LAUNCH ? '已中断' : '已取消';
  return record.status;
}

/** 关键词搜索仅匹配可见活动资料，不读取日志正文或自动发起 AI。 */
export function matchesActivity(record: DownloadHistoryRecord, keyword: string, filter: ActivityFilter): boolean {
  if (filter === ActivityFilter.GAME && activityCategory(record) !== ActivityCategory.LAUNCH) return false;
  if (filter === ActivityFilter.DOWNLOAD && !isDownloadActivity(record)) return false;
  if (filter === ActivityFilter.ABNORMAL && !isAbnormalActivity(record)) return false;
  const query: string = keyword.trim().toLowerCase();
  if (query.length === 0) return true;
  const haystack: string = ((record.title ?? '') + ' ' + record.versionName + ' ' + (record.subtitle ?? '')
    + ' ' + record.gameVersion + ' ' + record.loaderType + ' ' + (record.errorMessage ?? '')).toLowerCase();
  return haystack.indexOf(query) >= 0;
}

/** 日期使用本地日历而非 UTC，跨午夜时仍对应用户看到的“今天”。 */
function localDayKey(timestamp: number): string {
  const date: Date = new Date(timestamp);
  return date.getFullYear() + '-' + (date.getMonth() + 1) + '-' + date.getDate();
}

/** 按时间降序稳定分组；同一日期只建一组，不依赖调用方排序。 */
export function groupActivities(records: DownloadHistoryRecord[], now: number): ActivityDayGroup[] {
  const sorted: DownloadHistoryRecord[] = records.slice().sort((left: DownloadHistoryRecord, right: DownloadHistoryRecord): number => right.startedAt - left.startedAt);
  const today: string = localDayKey(now);
  const yesterdayDate: Date = new Date(now);
  yesterdayDate.setDate(yesterdayDate.getDate() - 1);
  const yesterday: string = localDayKey(yesterdayDate.getTime());
  const groups: ActivityDayGroup[] = [];
  for (const record of sorted) {
    const key: string = localDayKey(record.startedAt);
    let group: ActivityDayGroup | undefined = groups.find((candidate: ActivityDayGroup): boolean => candidate.key === key);
    if (group === undefined) {
      const created: ActivityDayGroup = { key: key, label: key === today ? '今天' : key === yesterday ? '昨天' : key, records: [] };
      groups.push(created);
      group = created;
    }
    group.records.push(record);
  }
  return groups;
}

/** 概览不受搜索条件影响；未知/运行态计入总数，但不会误计为已完成。 */
export function activityTodayStats(records: DownloadHistoryRecord[], now: number): ActivityDayStats {
  const stats: ActivityDayStats = { total: 0, completed: 0, interrupted: 0, failed: 0 };
  const today: string = localDayKey(now);
  for (const record of records) {
    if (localDayKey(record.startedAt) !== today) continue;
    stats.total++;
    if (record.status === 'success') stats.completed++;
    else if (record.status === 'failed' || record.status === 'crashed') stats.failed++;
    else if (record.status === 'aborted' || record.status === 'interrupted') stats.interrupted++;
  }
  return stats;
}

/**
 * 从公开 Markdown 回答提取有限长度摘要，不再调用模型，也不渲染 HTML 或链接。
 * 不把 fenced code 当作用户应执行的建议；截断时避免拆开 Unicode 代理对。
 */
export function aiPreviewText(markdown: string, maxLength: number = 140): string {
  const limit: number = Math.max(16, Math.min(maxLength, 500));
  // 摘要只处理有界前缀，超长或恶意 Markdown 不应在每个流增量上拖慢列表线程。
  const plain: string = markdown.substring(0, 8192)
    .replace(new RegExp('```[\\s\\S]*?(?:```|$)', 'g'), ' ')
    .replace(new RegExp('!\\[[^\\]]*\\]\\([^)]*\\)', 'g'), '')
    .replace(new RegExp('\\[([^\\]]+)\\]\\([^)]*\\)', 'g'), '$1')
    .replace(new RegExp('(^|\\n)\\s{0,3}(?:#{1,6}\\s+|>\\s*|[-*+]\\s+)', 'g'), ' ')
    .replace(new RegExp('[`*_~]', 'g'), '')
    .replace(new RegExp('<[^>]*>', 'g'), '')
    .replace(new RegExp('\\s+', 'g'), ' ').trim();
  if (plain.length <= limit) return plain;
  let end: number = limit;
  const last: number = plain.charCodeAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return plain.substring(0, end) + '…';
}
