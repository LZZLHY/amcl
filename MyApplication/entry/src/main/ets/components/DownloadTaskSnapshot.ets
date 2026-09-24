/**
 * 下载面板的不可变汇总快照。任务对象继续复用 @Observed 引用供卡片局部刷新；
 * 分组数组和计数每次通知重新生成，避免只替换内容相同的数组时，ArkUI 不刷新汇总和筛选。
 */
import { UnifiedTaskView, UnifiedTaskState, isInProgressState, aggregateProgress } from 'feature_core';

export interface DownloadTaskSnapshot {
  all: UnifiedTaskView[];
  inProgress: UnifiedTaskView[];
  done: UnifiedTaskView[];
  failed: UnifiedTaskView[];
  activeCount: number;
  waitingCount: number;
  progress: number;
}

/** 同一批视图同时生成计数、筛选列表和进度；失败/取消单列，不冒充“已完成”。 */
export function makeDownloadTaskSnapshot(views: UnifiedTaskView[]): DownloadTaskSnapshot {
  const snapshot: DownloadTaskSnapshot = { all: views.slice(), inProgress: [], done: [], failed: [],
    activeCount: 0, waitingCount: 0, progress: aggregateProgress(views) };
  for (const view of views) {
    if (isInProgressState(view.state)) {
      snapshot.activeCount++;
      snapshot.inProgress.push(view);
    } else if (view.state === UnifiedTaskState.WAITING) {
      snapshot.waitingCount++;
      snapshot.inProgress.push(view);
    } else if (view.state === UnifiedTaskState.DONE) snapshot.done.push(view);
    else if (view.state === UnifiedTaskState.ERROR || view.state === UnifiedTaskState.ABORTED) snapshot.failed.push(view);
  }
  return snapshot;
}
