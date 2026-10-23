/**
 * 页面任务身份投影规则。把“任务属于当前源”与“页面已经展示该任务”分开，
 * 使从其他版本进入的页面在任务结束时仍能收到对应终态，不留下假运行状态。
 * 本文件只比较身份，协调器仅提供类型；运行时没有 SDK、文件或页面依赖，宿主回归执行同一规则。
 */
import { ExportTaskView } from './GameExportCoordinator';

/**
 * 活动任务始终可见；终态仅属于当前源、历史指定 ID 或本页已展示 ID 时继续投影。
 * 已展示身份保证一个页面观察到完整生命周期；无关旧任务不占用新版本的配置页。
 */
export function shouldProjectExportTask(task: ExportTaskView, sourceRoot: string, sourceVersion: string,
  requestedTaskId: string, displayedTaskId: string): boolean {
  if (task.state === 'running' || task.state === 'cancelling') return true;
  return (sourceRoot.length > 0 && task.request.mcRoot === sourceRoot && task.request.versionId === sourceVersion)
    || task.id === requestedTaskId || task.id === displayedTaskId;
}
