/**
 * AiAnalysisService.ets — AI 分析的生命周期持有者（消息中心与诊断体验 · M5.7）
 *
 * 要根除的问题：`streamAiAnalysis` 的回调原本直接写 `McErrorSheet` 的 `@State`，
 * 流的生命周期实际挂在一个 UI 组件上。于是「用户关掉 Sheet 就白等半分钟」——
 * 组件销毁后没人接收增量，结果也没地方存。
 *
 * 解法是把「谁持有这个流」上移到 service：
 *
 *   start(sessionKey, ...)  幂等，同一 sessionKey 不重复发起
 *   attach(sessionKey, cb)  Sheet 打开时订阅实时增量
 *   detach(sessionKey)      Sheet 关闭**仅解绑，不取消流**
 *   流结束 → 落盘 filesDir/logs/ai/<sessionKey>.md
 *          → 落一条 AppMessage
 *          → 按前后台选灵动弹窗 / 系统通知
 *
 * 这样流的存活与任何 UI 组件都无关，Sheet 只是一个可随时接上/断开的观察者。
 *
 * 关联：docs/guides/message-center-and-diagnosis-ux.md §5.7
 * 创建日期：2026-07-30
 */

import { common } from '@kit.AbilityKit';
import { AppLogger, LOG_DOMAIN_UI } from 'commons';
import { streamAiAnalysis, AiStreamHandle, LOGSHARE_API_BASE, loadShareRecords, LogShareRecord } from './LogShareClient';
import { saveSessionAiText } from './McSessionSnapshot';
import { AiReportSource, saveAiReport } from './AiReportStore';
import { buildAiDoneMessage, buildAiFailedMessage } from './AppMessageStore';
import { postAppMessage } from './AppNotifier';

const TAG = 'AiAnalysisService';

/** 一次分析的运行态。 */
export enum AiTaskState {
  IDLE = 0,
  RUNNING = 1,
  DONE = 2,
  ERROR = 3,
}

/** Sheet 订阅的回调。 */
export interface AiTaskObserver {
  onDelta: (text: string) => void;
  onDone: (full: string) => void;
  onError: (msg: string) => void;
}

/** 单个 sessionKey 的分析任务。 */
class AiTask {
  statusText: string = '';
  retryAt: number = 0;
  logShareId: string = '';
  apiBaseUrl: string = '';
  sessionKey: number = 0;
  versionLabel: string = '';
  state: AiTaskState = AiTaskState.IDLE;
  text: string = '';
  error: string = '';
  handle: AiStreamHandle | null = null;
  observer: AiTaskObserver | null = null;
  /** 正文持久化完成才置 true；DONE 只说明网络回答结束。 */
  saved: boolean = false;
  saveError: string = '';
  snapshotDigest: string = '';
}

/** 任务表：sessionKey → AiTask。进程级，进程死了自然清空。 */
const tasks_: Map<number, AiTask> = new Map<number, AiTask>();

/**
 * 账本/平板使用只读变更订阅，不占用旧错误 Sheet 的 observer 槽位。
 * 订阅者收到会话号后自行读取快照；解绑一个页面不会解绑其他页面或取消流。
 */
const listeners_: Map<number, (sessionKey: number) => void> = new Map<number, (sessionKey: number) => void>();
let nextListenerId_: number = 0;

/** 供新 UI 使用的值快照；不暴露可取消的网络句柄。 */
export interface AiTaskSnapshot {
  statusText: string;
  retryAt: number;
  state: AiTaskState;
  text: string;
  error: string;
  shareId: string;
  apiBaseUrl: string;
  snapshotDigest: string;
  saved: boolean;
  saveError: string;
}

/** 注册页面级订阅。页面在销毁时必须用返回值解绑，避免持有页面实例。 */
export function subscribeAiTaskChanges(listener: (sessionKey: number) => void): number {
  const id: number = ++nextListenerId_;
  listeners_.set(id, listener);
  return id;
}

/** 只删除本次注册，不改变任务或旧 Sheet 观察者。 */
export function unsubscribeAiTaskChanges(id: number): void { listeners_.delete(id); }

/** 一个页面回调异常不能中断其他页面更新，更不能使 SSE 流失败。 */
function notifyAiChanged(sessionKey: number): void {
  for (const listener of Array.from(listeners_.values())) {
    try { listener(sessionKey); } catch (e) { /* 展示订阅异常不影响分析服务。 */ }
  }
}

/** 返回独立对象，让 @State 页面可以一次性发布一致的分析状态。 */
export function getAiTaskSnapshot(sessionKey: number): AiTaskSnapshot {
  const task: AiTask | undefined = tasks_.get(sessionKey);
  return { state: task?.state ?? AiTaskState.IDLE, text: task?.text ?? '', error: task?.error ?? '',
    statusText: task?.statusText ?? '', retryAt: task?.retryAt ?? 0,
    shareId: task?.logShareId ?? '', apiBaseUrl: task?.apiBaseUrl ?? '', snapshotDigest: task?.snapshotDigest ?? '',
    saved: task?.saved ?? false, saveError: task?.saveError ?? '' };
}

/** 只重试当前已完成回答的本地保存，不重新上传、不启动新 AI 请求。 */
export async function retrySaveAiReport(ctx: common.UIAbilityContext, sessionKey: number): Promise<void> {
  const task: AiTask | undefined = tasks_.get(sessionKey);
  if (task !== undefined && task.state === AiTaskState.DONE && !task.saved && task.text.length > 0) {
    await persistTaskReport_(ctx, task);
  }
}

/** 查某个会话的当前状态（Sheet 打开时用来决定显示什么）。 */
export function getAiTaskState(sessionKey: number): AiTaskState {
  let t = tasks_.get(sessionKey);
  return t === undefined ? AiTaskState.IDLE : t.state;
}

/** 查某个会话已累积的文本（Sheet 重新打开时立刻能看到进度）。 */
export function getAiTaskText(sessionKey: number): string {
  let t = tasks_.get(sessionKey);
  return t === undefined ? '' : t.text;
}

/** 查某个会话的错误信息。 */
export function getAiTaskError(sessionKey: number): string {
  let t = tasks_.get(sessionKey);
  return t === undefined ? '' : t.error;
}

/** 是否有正在跑的分析。 */
export function isAiRunning(sessionKey: number): boolean {
  return getAiTaskState(sessionKey) === AiTaskState.RUNNING;
}

/**
 * 发起分析。**幂等** —— 同一 sessionKey 正在跑或已完成时直接返回，不重复发起
 * （否则用户来回开关 Sheet 会打出好几条并发请求，还会重复计费/限流）。
 *
 * @param ctx          用于落盘与发通知
 * @param sessionKey   会话主键（= ActivityRecord.startedAt）
 * @param logShareId   LogShare 的日志 id（AI 走服务端按 id 取日志）
 * @param versionLabel 消息正文里显示的版本名
 */
export function startAiAnalysis(ctx: common.UIAbilityContext, sessionKey: number,
  logShareId: string, versionLabel: string, apiBaseUrl: string = LOGSHARE_API_BASE, snapshotDigest: string = ''): void {
  if (sessionKey <= 0 || logShareId.length === 0 || apiBaseUrl !== LOGSHARE_API_BASE) return;
  let existing = tasks_.get(sessionKey);
  // 重试冷却留在服务层，旧诊断页与新阅读 sheet 都不能绕过 Retry-After。
  if (existing !== undefined && existing.logShareId === logShareId && existing.retryAt > Date.now()) return;
  if (existing !== undefined
    && existing.logShareId === logShareId && existing.apiBaseUrl === apiBaseUrl
    && (existing.state === AiTaskState.RUNNING || existing.state === AiTaskState.DONE)) {
    return;
  }
  // 先解除旧任务身份，再取消旧请求，避免同步取消回调误发失败消息。
  if (existing !== undefined) tasks_.delete(sessionKey);
  if (existing !== undefined && existing.handle !== null) existing.handle.cancel();

  let task = new AiTask();
  task.sessionKey = sessionKey;
  task.logShareId = logShareId;
  task.apiBaseUrl = apiBaseUrl;
  task.versionLabel = versionLabel;
  task.state = AiTaskState.RUNNING;
  task.text = '';
  task.error = '';
  task.snapshotDigest = snapshotDigest;
  tasks_.set(sessionKey, task);
  notifyAiChanged(sessionKey);

  AppLogger.info(TAG, 'ai analysis started: key=' + sessionKey + ' id=' + logShareId,
    LOG_DOMAIN_UI);

  task.handle = streamAiAnalysis(logShareId, {
    onStatus: (status: string, position: number): void => {
      if (tasks_.get(sessionKey) !== task) return;
      // 轮次上限是服务端粗状态，不展示工具参数，也不提前伪造 done 或失败。
      task.statusText = status === 'queued' ? 'AI 排队中' + (position > 0 ? ' · 入队时约 ' + position + ' 项' : '')
        : status === 'limit' ? '已达到分析轮次上限，等待服务端结束…' : 'AI 正在分析…';
      notifyAiChanged(sessionKey);
    },
    onRetryAfter: (seconds: number): void => {
      if (tasks_.get(sessionKey) === task) task.retryAt = Date.now() + seconds * 1000;
    },
    onDelta: (t: string) => {
      // 被新分享替换或被撤回的流可能仍有迟到回调，不能污染当前会话结果。
      if (tasks_.get(sessionKey) !== task) return;
      task.text += t;
      task.statusText = 'AI 正在分析…';
      let ob = task.observer;
      if (ob !== null) { try { ob.onDelta(t); } catch (e) { /* 旧 UI 失效不能打断分析。 */ } }
      notifyAiChanged(sessionKey);
    },
    onDone: (full: string) => {
      if (tasks_.get(sessionKey) !== task) return;
      task.text = full.length > 0 ? full : task.text;
      task.state = AiTaskState.DONE;
      task.handle = null;
      let ob = task.observer;
      if (ob !== null) { try { ob.onDone(task.text); } catch (e) { /* 完成后仍必须保存报告。 */ } }
      notifyAiChanged(sessionKey);
      // 落盘 + 告知。**即使此刻没有任何 observer（Sheet 已关）也照样执行** ——
      // 这正是把生命周期上移的目的。
      finishTask_(ctx, task, true);
    },
    onError: (msg: string) => {
      if (tasks_.get(sessionKey) !== task) return;
      task.state = AiTaskState.ERROR;
      task.error = msg;
      task.handle = null;
      let ob = task.observer;
      if (ob !== null) { try { ob.onError(msg); } catch (e) { /* 错误仍由服务记录和通知。 */ } }
      notifyAiChanged(sessionKey);
      finishTask_(ctx, task, false);
    },
  }, apiBaseUrl);
}

/** 流结束的收尾：落盘 + 投递消息。 */
function finishTask_(ctx: common.UIAbilityContext, task: AiTask, ok: boolean): void {
  if (ok && task.text.length > 0) {
    persistTaskReport_(ctx, task);
  }
  let msg = ok
    ? buildAiDoneMessage(task.sessionKey, task.versionLabel)
    : buildAiFailedMessage(task.sessionKey, task.versionLabel, task.error);
  postAppMessage(ctx, msg).catch((e: Error) => {
    AppLogger.warn(TAG, 'postAppMessage failed', e, LOG_DOMAIN_UI);
  });
}

/**
 * 保存与来源核验脱离 UI 生命周期，但仍受任务身份保护。
 * 先解析同实例的本地分享记录，不发送网络；原子保存后发布 saved，再兼容旧 aiPath。
 */
async function persistTaskReport_(ctx: common.UIAbilityContext, task: AiTask): Promise<void> {
  try {
    const shares = await loadShareRecords(ctx);
    if (tasks_.get(task.sessionKey) !== task) return;
    const share = shares.find((item: LogShareRecord): boolean => item.id === task.logShareId && item.apiBaseUrl === task.apiBaseUrl
      && item.activityId === task.sessionKey && item.accepted !== false);
    const source: AiReportSource = { shareId: task.logShareId, apiBaseUrl: task.apiBaseUrl,
      snapshotDigest: task.snapshotDigest || share?.snapshotDigest || '' };
    saveAiReport(ctx.filesDir, task.sessionKey, task.text, source);
    task.saved = true;
    task.saveError = '';
    notifyAiChanged(task.sessionKey);
    // 旧错误 Sheet 和消息中心仍通过 aiPath 重入；新账本不依赖这次兼容写入的成功。
    await saveSessionAiText(ctx, task.sessionKey, task.text);
    AppLogger.info(TAG, 'ai report saved: key=' + task.sessionKey, LOG_DOMAIN_UI);
  } catch (e) {
    if (tasks_.get(task.sessionKey) !== task) return;
    task.saveError = '分析已完成，但本地保存失败：' + (e as Error).message;
    notifyAiChanged(task.sessionKey);
    AppLogger.warn(TAG, 'save ai report failed', e, LOG_DOMAIN_UI);
  }
}

/**
 * Sheet 打开时订阅实时增量。
 *
 * 订阅时会先把**已累积的文本**通过 onDelta 回放一次，这样中途接上的 Sheet 也能立刻
 * 看到完整进度，而不是从此刻的增量开始拼半截内容。
 */
export function attachAiObserver(sessionKey: number, ob: AiTaskObserver): void {
  let t = tasks_.get(sessionKey);
  if (t === undefined) return;
  t.observer = ob;
  if (t.text.length > 0) ob.onDelta(t.text);
  if (t.state === AiTaskState.DONE) ob.onDone(t.text);
  else if (t.state === AiTaskState.ERROR) ob.onError(t.error);
}

/** Sheet 关闭：只解绑，**不取消流**。 */
export function detachAiObserver(sessionKey: number): void {
  let t = tasks_.get(sessionKey);
  if (t === undefined) return;
  t.observer = null;
}

/**
 * 真正取消分析（用户明确要求，如撤回了分享 —— 服务端按 id 取日志，日志删了流也无意义）。
 */
export function cancelAiAnalysis(sessionKey: number): void {
  let t = tasks_.get(sessionKey);
  if (t === undefined) return;
  tasks_.delete(sessionKey);
  if (t.handle !== null) {
    try { t.handle.cancel(); } catch (e) { /* 已结束 */ }
    t.handle = null;
  }
  notifyAiChanged(sessionKey);
  AppLogger.info(TAG, 'ai analysis cancelled: key=' + sessionKey, LOG_DOMAIN_UI);
}
