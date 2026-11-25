import { UnifiedTaskView } from 'feature_core';

type Data = Record<string, Object>;

// 新尝试在出队前还未分配活动号，须从重试关系判断它正借用父活动号。
export function isQueuedRetry(view: UnifiedTaskView): boolean {
  return view.state === 'waiting' && view.activityRelation === 'retry' && view.parentActivityId === view.startedAtMs;
}

// 重试在队列中仍临时保留父活动号，只有原尝试的视图才能为原回执提供实时进度。
export function matchesTaskActivity(view: UnifiedTaskView, activity: number): boolean {
  return view.startedAtMs === activity && !isQueuedRetry(view);
}

/** 只发布可序列化的业务结果；内部路径和账户凭据不进入智能体回包。 */
export function result(state: string, reason: string = ''): Data {
  return reason ? { 'state': state, 'reason': reason } : { 'state': state };
}
// 保留 mc: 等已公开键。含路径的内部键使用原操作或列表引用。
export function publicTaskId(id: string, reference: string): string {
  return id.includes('/') || id.includes('\\') ? 'task:' + reference : id;
}

export function textArg(args: Data, key: string): string {
  return typeof args[key] === 'string' ? args[key] as string : '';
}
