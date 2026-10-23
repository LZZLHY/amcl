/**
 * 活动列表的纯展示数据源：把真实日期组投影为一层日期头/活动行，供 List 的
 * LazyForEach 按视口创建节点。只保存已读取的记录引用，不访问文件、改终态或持久化。
 */
import { DownloadHistoryRecord } from 'feature_core';
import { ActivityDayGroup, activityCategory } from './ActivityUiModel';

/** 每个行都有确定的记录；日期头只使用标签/计数，避免在 Builder 中依赖空记录断言。 */
export interface ActivityListRow {
  key: string;
  header: boolean;
  groupLabel: string;
  groupCount: number;
  groupIndex: number;
  indexInGroup: number;
  lastInGroup: boolean;
  record: DownloadHistoryRecord;
}

export class ActivityListDataSource implements IDataSource {
  private rows: ActivityListRow[] = [];
  /** 筛选也会改变日期计数/组尾；独立视图世代避免相同活动key复用陈旧普通对象字段。 */
  private viewGeneration_: number = 0;
  /** 监听者只在实际列表存活期间持有，注销后不再收到刷新。 */
  private listeners: Set<DataChangeListener> = new Set<DataChangeListener>();

  totalCount(): number { return this.rows.length; }
  getData(index: number): ActivityListRow {
    if (!Number.isInteger(index) || index < 0 || index >= this.rows.length) throw new RangeError('活动行索引越界');
    return this.rows[index];
  }
  registerDataChangeListener(listener: DataChangeListener): void { this.listeners.add(listener); }
  unregisterDataChangeListener(listener: DataChangeListener): void { this.listeners.delete(listener); }

  /**
   * 保留原分组顺序、首组五行入场动效和组尾语义。刷新世代进入 key，确保 V1 普通对象
   * 内层结局/保留更新能重建可见行；右侧详情仍以 activityId 复用，不改变导航身份。
   */
  replace(groups: ActivityDayGroup[], revision: number): void {
    const rows: ActivityListRow[] = [];
    const generation: number = ++this.viewGeneration_;
    groups.forEach((group: ActivityDayGroup, groupIndex: number): void => {
      if (group.records.length === 0) return;
      rows.push({ key: 'day-' + group.key + '-' + revision + '-' + generation, header: true, groupLabel: group.label,
        groupCount: group.records.length, groupIndex: groupIndex, indexInGroup: -1,
        lastInGroup: false, record: group.records[0] });
      group.records.forEach((record: DownloadHistoryRecord, index: number): void => {
        rows.push({ key: 'activity-' + record.startedAt + '-' + activityCategory(record) + '-' + revision + '-' + generation,
          header: false, groupLabel: group.label, groupCount: group.records.length, groupIndex: groupIndex,
          indexInGroup: index, lastInGroup: index === group.records.length - 1, record: record });
      });
    });
    this.rows = rows;
    for (const listener of this.listeners) listener.onDataReloaded();
  }
}
