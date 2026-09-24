/**
 * DownloadTaskRegistry.ets — 全局下载任务注册中心（2026-05-22）
 *
 * 单例 + 监听器模式：所有下载入口（Index.beginDownload / ModBrowsePage.executeInstall
 * / SettingsTab JDK 按钮 / 自动 JDK bootstrap）改为 `registry.enqueue(adapter)`。
 *
 * 主要职责：
 *   - 持有 adapter 引用，避免 GC
 *   - 统一 `start / cancel / pause / resume / retry / purge` API
 *   - 提供 view 快照给 `DownloadTasksSheet` 渲染
 *   - 通过 `addListener` 让 UI 在 task 状态变化时刷新（@ObjectLink 已经处理单字段刷新；
 *     listener 主要负责"新增 / 移除"这种数组级变化）
 *
 * 注意：Registry 使用 FIFO 公平队列，并以 maxConcurrent 限制同时运行任务数。
 *
 * 相关文档：docs/guides/download-multi-task-design.md § 四.2 + § 五 Phase 2
 */

import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';
import {
  UnifiedDownloadAdapter, UnifiedTaskView, UnifiedTaskState,
  isInProgressState, isTerminalState, aggregateProgress, TaskCategory,
} from './UnifiedDownloadTask';

const TAG = 'DownloadTaskRegistry';

/** 监听器签名：任意 task 增/删/状态变化时被调用 */
export type RegistryListener = () => void;

class PendingStart {
  /** 首次执行/重试开启新活动，暂停恢复沿用同一活动。 */
  newAttempt: boolean;
  startState: string;
  action: () => Promise<void>;
  resolve: () => void;
  reject: (error: Error) => void;

  constructor(startState: string, action: () => Promise<void>,
              resolve: () => void, reject: (error: Error) => void, newAttempt: boolean = true) {
    this.newAttempt = newAttempt;
    this.startState = startState;
    this.action = action;
    this.resolve = resolve;
    this.reject = reject;
  }
}

export class DownloadTaskRegistry {
  private static _instance: DownloadTaskRegistry | null = null;

  /** id -> adapter 映射（id 是 adapter.view.id） */
  private adapters_: Map<string, UnifiedDownloadAdapter> = new Map();
  /** 维持插入顺序的 id 数组（Map.values() 顺序在 ArkTS 严格模式下不保证） */
  private orderedIds_: string[] = [];
  private listeners_: RegistryListener[] = [];
  /** Registry 层任务并发上限；native 内部线程并发仍由引擎自行控制。 */
  maxConcurrent: number = 3;
  private waitingIds_: string[] = [];
  private runningIds_: string[] = [];
  private pendingStarts_: Map<string, PendingStart> = new Map();
  /** 同一队列同时出队的任务也必须有不同的毫秒活动主键。 */
  private lastActivityAt_: number = 0;
  /** 依赖任务的 UI 身份归属。成员可独立展示，但执行、取消、重试仍由整组 owner 统一负责。 */
  private attachedOwners_: Map<string, string> = new Map();

  static instance(): DownloadTaskRegistry {
    if (!DownloadTaskRegistry._instance) {
      DownloadTaskRegistry._instance = new DownloadTaskRegistry();
    }
    return DownloadTaskRegistry._instance;
  }

  // ============================================================
  //  注册 / 启动
  // ============================================================

  /**
   * 把 adapter 加入 FIFO 队列。最多同时运行 maxConcurrent 个任务；返回 Promise reflect 终态。
   */
  enqueue(adapter: UnifiedDownloadAdapter): Promise<void> {
    let id = adapter.view.id;
    if (id.length === 0) {
      return Promise.reject(new Error('adapter.view.id 不能为空'));
    }

    let existing = this.adapters_.get(id);
    if (existing) {
      if (!isTerminalState(existing.view.state)) {
        AppLogger.warn(TAG, `enqueue rejected: task id=${id} already active (state=${existing.view.state})`, null, LOG_DOMAIN_DOWNLOAD);
        return Promise.reject(new Error('任务 "' + adapter.view.title + '" 已在进行中'));
      }
      // ⚠️ 2026-08-04：这里原来是"一次 purge 不成功就直接 reject"。
      //   但 native 侧从 cancel/失败到真正 execution-settled 需要等 worker + curl 收敛，
      //   实测可达数秒；单次判定过于苛刻，用户点重新下载就收到「旧 native 资源尚未释放」，
      //   只能自己反复点。给一个有限等待窗口（~3s，每 300ms 一次），和
      //   JdkInstallTask.retry() 里已验证过的做法保持一致。
      if (!this.tryPurgeNativeOwner_(id, existing)) {
        let pendingAdapter: UnifiedDownloadAdapter = adapter;
        let staleAdapter: UnifiedDownloadAdapter = existing;
        return this.purgeThenEnqueue_(id, pendingAdapter, staleAdapter);
      }
      this.removeInternal_(id);
    }

    return this.commitEnqueue_(id, adapter);
  }

  /**
   * 等旧 native execution 收敛后再入队。窗口内每 300ms 复查一次，最多 ~3s。
   * 期间若该 id 已被别处清理（用户手动清理 / purgeFinished），直接走正常入队。
   */
  private async purgeThenEnqueue_(
    id: string,
    adapter: UnifiedDownloadAdapter,
    stale: UnifiedDownloadAdapter,
  ): Promise<void> {
    AppLogger.info(TAG,
      `enqueue: waiting for native purge of stale task id=${id}`, LOG_DOMAIN_DOWNLOAD);
    for (let i = 0; i < 10; i++) {
      await new Promise<void>((r: () => void): void => { setTimeout((): void => r(), 300); });
      if (this.adapters_.get(id) !== stale) break;          // 已被别处清理
      if (this.tryPurgeNativeOwner_(id, stale)) break;
    }
    if (this.adapters_.get(id) === stale) {
      if (!this.tryPurgeNativeOwner_(id, stale)) {
        throw new Error('任务 "' + adapter.view.title + '" 的旧下载资源仍在释放，请稍后再试');
      }
      this.removeInternal_(id);
    }
    return this.commitEnqueue_(id, adapter);
  }

  /** 真正落地入队（adapters_ 登记 + waiting/pending 配对 + drain）。 */
  private commitEnqueue_(id: string, adapter: UnifiedDownloadAdapter): Promise<void> {
    this.adapters_.set(id, adapter);
    this.orderedIds_.push(id);
    adapter.view.state = UnifiedTaskState.WAITING;
    adapter.view.progress = 0;
    adapter.view.queuePosition = 0;
    // 同 scheduleAction_：入队前清掉可能残留的同 id waiting 条目，
    // 保证 waitingIds_ 与 pendingStarts_ 严格一一对应（失步会导致任务永久卡 PREPARING）。
    let staleWaiting = this.waitingIds_.indexOf(id);
    if (staleWaiting >= 0) {
      this.waitingIds_.splice(staleWaiting, 1);
      AppLogger.warn(TAG,
        `enqueue: removed stale waiting entry for id=${id}`, null, LOG_DOMAIN_DOWNLOAD);
    }
    AppLogger.info(TAG, `enqueue: id=${id} category=${adapter.view.category} title=${adapter.view.title}`, LOG_DOMAIN_DOWNLOAD);

    return new Promise<void>((resolve: () => void, reject: (error: Error) => void) => {
      let pending = new PendingStart(UnifiedTaskState.PREPARING,
        (): Promise<void> => adapter.start(), resolve, reject);
      this.pendingStarts_.set(id, pending);
      this.waitingIds_.push(id);
      this.updateQueuePositions_();
      this.notify();
      this.drainQueue_();
    });
  }

  // ============================================================
  //  操作（按 id 派发到 adapter）
  // ============================================================

  /**
   * 注册同一事务的依赖任务，不把它放进 FIFO 或 runningIds_。
   * 父任务已占调度槽，子文件在其内部受限并发；再次入队子任务会造成单槽队列自锁。
   * 只允许现存独立 owner 创建唯一成员，避免其他任务接管成员的进度或 native 所有权。
   */
  attachTask(ownerId: string, adapter: UnifiedDownloadAdapter): void {
    if (!this.adapters_.has(ownerId) || this.attachedOwners_.has(ownerId))
      throw new Error('依赖任务缺少有效的安装任务');
    const id = adapter.view.id;
    if (id.length === 0 || id === ownerId || this.adapters_.has(id))
      throw new Error('依赖任务标识重复：' + id);
    this.adapters_.set(id, adapter);
    this.attachedOwners_.set(id, ownerId);
    this.orderedIds_.push(id);
    AppLogger.info(TAG, `attach: owner=${ownerId} id=${id} title=${adapter.view.title}`, LOG_DOMAIN_DOWNLOAD);
    this.notify();
  }

  /**
   * owner 新一轮解析前替换旧的依赖视图。调用方必须先释放上一轮全部 native owner；
   * 本方法只清 UI/操作关系，既不启动下载，也不删除暂存文件。
   */
  clearAttachedTasks(ownerId: string): void {
    const ids: string[] = [];
    this.attachedOwners_.forEach((owner: string, id: string): void => { if (owner === ownerId) ids.push(id); });
    for (const id of ids) this.removeInternal_(id);
    if (ids.length > 0) this.notify();
  }

  cancel(id: string, cleanupFiles: boolean = false): Promise<void> {
    const ownerId = this.attachedOwners_.get(id);
    if (ownerId !== undefined) return this.cancel(ownerId, cleanupFiles);
    let a = this.adapters_.get(id);
    if (!a) {
      AppLogger.warn(TAG, `cancel: id=${id} not found`, null, LOG_DOMAIN_DOWNLOAD);
      return Promise.resolve();
    }
    let waitingIndex = this.waitingIds_.indexOf(id);
    if (waitingIndex >= 0) {
      this.waitingIds_.splice(waitingIndex, 1);
      let pending = this.pendingStarts_.get(id);
      this.pendingStarts_.delete(id);
      a.view.state = UnifiedTaskState.ABORTED;
      a.view.queuePosition = 0;
      // 2026-08-04：取消**队列中**的任务过去只改 state，不复位操作标志、也从不通知
      // adapter。后果：卡片上「取消」按钮还在（canCancel 仍为 true）、重试按钮却没有
      // （canRetry 仍为 false），于是既不能重试也不能删除 —— 只能等进程重启。
      // 现在补齐两件事：给 adapter 一次释放资源的机会，并把标志改成"可重试、不可取消"。
      a.view.canCancel = false;
      a.view.canPause = false;
      a.view.canResume = false;
      a.view.canRetry = true;
      let adapter: UnifiedDownloadAdapter = a;
      try {
        adapter.cancel(cleanupFiles).catch((e: Error): void => {
          AppLogger.warn(TAG, `cancel(queued) adapter rejected id=${id}`, e, LOG_DOMAIN_DOWNLOAD);
        });
      } catch (e) {
        AppLogger.warn(TAG, `cancel(queued) adapter threw id=${id}`, e as Error, LOG_DOMAIN_DOWNLOAD);
      }
      if (pending) pending.reject(new Error('已取消'));
      this.updateQueuePositions_();
      this.notify();
      this.drainQueue_();
      return Promise.resolve();
    }
    return a.cancel(cleanupFiles).then(() => this.notify());
  }

  pause(id: string): Promise<void> {
    let a = this.adapters_.get(id);
    if (!a || !a.view.canPause || a.view.state === UnifiedTaskState.WAITING) return Promise.resolve();
    return a.pause().then(() => this.notify());
  }

  resume(id: string): Promise<void> {
    let a = this.adapters_.get(id);
    if (!a || !a.view.canResume) return Promise.resolve();
    let adapter: UnifiedDownloadAdapter = a;
    return this.scheduleAction_(id, UnifiedTaskState.PREPARING,
      (): Promise<void> => adapter.resume());
  }

  retry(id: string): Promise<void> {
    const ownerId = this.attachedOwners_.get(id);
    if (ownerId !== undefined) return this.retry(ownerId);
    let a = this.adapters_.get(id);
    // 诊断（2026-07-29）：重试点了没反应且**零日志**，说明被这里的静默 return 吞掉了。
    // 把每次 retry 入口的关键状态打出来，定位到底是 adapter 丢了还是 canRetry 为 false。
    AppLogger.info(TAG,
      `retry() entry: id=${id} found=${a !== undefined} `
      + (a !== undefined
          ? `state=${a.view.state} canRetry=${a.view.canRetry} `
            + `pending=${this.pendingStarts_.has(id)} running=${this.runningIds_.indexOf(id) >= 0}`
          : ''),
      LOG_DOMAIN_DOWNLOAD);
    if (!a) {
      AppLogger.warn(TAG, `retry ignored: adapter not found id=${id}`, null, LOG_DOMAIN_DOWNLOAD);
      return Promise.resolve();
    }
    if (!a.view.canRetry) {
      AppLogger.warn(TAG,
        `retry ignored: canRetry=false id=${id} state=${a.view.state}`, null, LOG_DOMAIN_DOWNLOAD);
      return Promise.resolve();
    }
    let adapter: UnifiedDownloadAdapter = a;
    // 在出队重设 startedAtMs 之前保存上次尝试身份；暂停恢复不建立新的重试关系。
    adapter.view.parentActivityId = adapter.view.startedAtMs;
    adapter.view.activityRelation = 'retry';
    return this.scheduleAction_(id, UnifiedTaskState.PREPARING,
      (): Promise<void> => adapter.retry(), true).catch((e: Error) => {
      AppLogger.warn(TAG, `retry id=${id} threw`, e, LOG_DOMAIN_DOWNLOAD);
      this.notify();
    });
  }

  private scheduleAction_(id: string, startState: string, action: () => Promise<void>, newAttempt: boolean = false): Promise<void> {
    let a = this.adapters_.get(id);
    if (!a) return Promise.reject(new Error('任务不存在: ' + id));
    if (this.pendingStarts_.has(id) || this.runningIds_.indexOf(id) >= 0) {
      return Promise.reject(new Error('任务已在队列或运行中: ' + id));
    }
    // ⚠️ 2026-07-29 根因修复（重试永久卡住）：
    //   守卫过去只查 pendingStarts_ / runningIds_，**没查 waitingIds_**。
    //   一旦 waitingIds_ 里残留了 id 而它的 pending 条目已被清掉（两者失步），
    //   每次重试都会再 push 一个同 id，而 drainQueue_ 取到 pending=undefined 后
    //   静默丢弃 → 队列里永远堆着这个 id、任务永远起不来。
    //   真机日志实锤：`drainQueue_: running=[] limit=3 waiting=[jdk:21]` 反复出现，
    //   且 adapter.retry() 从未被调用。
    //   这里在重新入队前先把陈旧残留摘掉，保证 waitingIds_ 与 pendingStarts_ 严格配对。
    let staleWaiting = this.waitingIds_.indexOf(id);
    if (staleWaiting >= 0) {
      this.waitingIds_.splice(staleWaiting, 1);
      AppLogger.warn(TAG,
        `scheduleAction_: removed stale waiting entry for id=${id} before re-enqueue`,
        null, LOG_DOMAIN_DOWNLOAD);
    }
    a.view.state = UnifiedTaskState.WAITING;
    a.view.queuePosition = 0;
    return new Promise<void>((resolve: () => void, reject: (error: Error) => void) => {
      this.pendingStarts_.set(id, new PendingStart(startState, action, resolve, reject, newAttempt));
      this.waitingIds_.push(id);
      this.updateQueuePositions_();
      this.notify();
      this.drainQueue_();
    });
  }

  private drainQueue_(): void {
    let configured = Math.floor(this.maxConcurrent);
    let limit = Number.isFinite(configured) && configured > 0 ? configured : 1;
    // 诊断（2026-07-29）：retry 通过了 scheduleAction_（已入 waitingIds_）却从未调到
    // adapter.retry()，只可能是这里的并发闸门没放行。把闸门状态打出来。
    if (this.waitingIds_.length > 0) {
      AppLogger.info(TAG,
        `drainQueue_: running=[${this.runningIds_.join(',')}] limit=${limit} `
        + `waiting=[${this.waitingIds_.join(',')}]`,
        LOG_DOMAIN_DOWNLOAD);
    }
    while (this.runningIds_.length < limit && this.waitingIds_.length > 0) {
      let idValue = this.waitingIds_.shift();
      if (idValue === undefined) break;
      let id: string = idValue;
      let pendingValue = this.pendingStarts_.get(id);
      AppLogger.info(TAG,
        `drainQueue_ loop: id=${id} hasPending=${pendingValue !== undefined} `
        + `hasAdapter=${this.adapters_.get(id) !== undefined} pendingKeys=[${Array.from(this.pendingStarts_.keys()).join(',')}]`,
        LOG_DOMAIN_DOWNLOAD);
      if (pendingValue === undefined) {
        // ⚠️ 2026-07-29 修复「取消后点重试永久卡住」：
        //   这里原本静默 continue。真机日志实锤（drainQueue_: running=[] limit=3
        //   waiting=[jdk:21] 反复出现、adapter.retry() 从不被调用、view 永久 preparing）：
        //   waitingIds_ 里有 id，但 pendingStarts_ 里没有对应条目 —— 二者失步。
        //   一旦发生，这个 id 每轮都被 shift 掉又静默丢弃，任务卡在 PREPARING：
        //   isInProgressState 恒真 → remove() 拒绝清理 → 用户怎么点重试都没反应。
        //   现在把它落到 ERROR 终态并说明原因，让用户能重试/清理，而不是无声卡死。
        let orphanAdapter = this.adapters_.get(id);
        if (orphanAdapter !== undefined && !isTerminalState(orphanAdapter.view.state)) {
          orphanAdapter.view.state = UnifiedTaskState.ERROR;
          orphanAdapter.view.errorMessage = '任务调度状态失步，请重试';
          orphanAdapter.view.queuePosition = 0;
          orphanAdapter.view.canCancel = false;
          orphanAdapter.view.canRetry = true;
        }
        AppLogger.warn(TAG,
          `drainQueue_: waiting/pending desync for id=${id}; forced to ERROR so it stays retryable`,
          null, LOG_DOMAIN_DOWNLOAD);
        this.pendingStarts_.delete(id);
        this.notify();
        continue;
      }
      let adapterValue = this.adapters_.get(id);
      if (adapterValue === undefined) {
        pendingValue.reject(new Error('任务在启动前已移除: ' + id));
        this.pendingStarts_.delete(id);
        continue;
      }
      let pending: PendingStart = pendingValue;
      let adapter: UnifiedDownloadAdapter = adapterValue;
      this.pendingStarts_.delete(id);
      this.runningIds_.push(id);
      adapter.view.queuePosition = 0;
      if (pending.newAttempt || adapter.view.startedAtMs <= 0) {
        adapter.view.startedAtMs = Math.max(Date.now(), this.lastActivityAt_ + 1);
        this.lastActivityAt_ = adapter.view.startedAtMs;
      }
      adapter.view.state = pending.startState;
      // 2026-08-04：一个**即将开始跑**的任务不该还挂着"重试"按钮。
      // 原来没人复位它：adapter 在失败终态里把 canRetry 置 true，重试后又没人置回 false，
      // 于是运行中的卡片一直显示可点的重试按钮，点下去只会撞 scheduleAction_ 的重入守卫。
      adapter.view.canRetry = false;
      this.updateQueuePositions_();
      this.notify();
      let actionPromise: Promise<void>;
      AppLogger.info(TAG, `drainQueue_: invoking action for id=${id} startState=${pending.startState}`,
        LOG_DOMAIN_DOWNLOAD);
      try {
        actionPromise = pending.action();
      } catch (e) {
        let syncError = e as Error;
        let runningIndex = this.runningIds_.indexOf(id);
        if (runningIndex >= 0) this.runningIds_.splice(runningIndex, 1);
        // 同步抛出时下载流程从未运行，没有 native complete 回调会把 view 推到终态。
        // 必须在此显式落终态，否则 view 永久停留在 PREPARING：isInProgressState 恒真、
        // remove() 因非终态被拒，形成无法清理的僵尸任务。
        adapter.view.state = UnifiedTaskState.ERROR;
        adapter.view.errorMessage = syncError.message;
        adapter.view.queuePosition = 0;
        // 2026-08-04：与下面的异步 reject 分支保持一致 —— 必须给出可重试/可清理的出口，
        // 否则卡片上既没有重试按钮也删不掉（remove() 只放行终态，而 canRetry 仍是 false）。
        adapter.view.canCancel = false;
        adapter.view.canPause = false;
        adapter.view.canResume = false;
        adapter.view.canRetry = true;
        pending.reject(syncError);
        AppLogger.warn(TAG, `task id=${id} threw before returning Promise`, syncError, LOG_DOMAIN_DOWNLOAD);
        this.notify();
        continue;
      }
      actionPromise.then((): void => {
        pending.resolve();
      }).catch((e: Error): void => {
        AppLogger.warn(TAG, `task id=${id} rejected`, e, LOG_DOMAIN_DOWNLOAD);
        // ⚠️ 2026-08-04：异步 reject 必须和上面的同步 throw 分支**对称**地兜住终态。
        //
        //   原实现这里只打日志 + reject，不写任何 view 字段。绝大多数 adapter 会在自己的
        //   catch 里落 ERROR，但有若干 reject 点位于 adapter 的「写 view / notify」之外，
        //   比如：
        //     · DownloadTask 的「版本 X 已存在」（抛在 phase try 之外，一次 notify 都不发）
        //     · DownloadTask 的「旧下载任务仍在收敛，请稍后重试」
        //     · RepairTask / ForgeRepairTask / ResourceInstallTask / ModpackInstallTask 的
        //       「旧…任务仍在收敛」（retry 里直接 Promise.reject，从不碰 view）
        //   这些路径走完之后 view 永久停在 Registry 写的 PREPARING：
        //   isInProgressState 恒真 → remove() 拒绝清理；enqueue 同 id 又被
        //   「已在进行中」顶掉；canRetry 还是构造默认的 false，连按钮都没有。
        //   结果就是这个资源在杀进程之前**再也下载不了**。
        //
        //   这里做最后一道兜底：只要 adapter 没把自己收敛到终态，就替它落 ERROR 并
        //   保证「可重试 + 可清理」。已经是终态的（adapter 自己处理过）一律不覆盖。
        if (!isTerminalState(adapter.view.state)) {
          adapter.view.state = UnifiedTaskState.ERROR;
          if (adapter.view.errorMessage.length === 0) {
            adapter.view.errorMessage = e.message !== undefined ? e.message : String(e);
          }
          adapter.view.queuePosition = 0;
          adapter.view.canCancel = false;
          adapter.view.canPause = false;
          adapter.view.canResume = false;
          adapter.view.canRetry = true;
          AppLogger.warn(TAG,
            `task id=${id} rejected without a terminal state; forced to ERROR so it stays `
            + 'retryable and removable', null, LOG_DOMAIN_DOWNLOAD);
        }
        pending.reject(e);
      }).finally((): void => {
        let runningIndex = this.runningIds_.indexOf(id);
        if (runningIndex >= 0) this.runningIds_.splice(runningIndex, 1);
        this.notify();
        this.drainQueue_();
      });
    }
    this.updateQueuePositions_();
  }

  private updateQueuePositions_(): void {
    for (let i = 0; i < this.waitingIds_.length; i++) {
      let a = this.adapters_.get(this.waitingIds_[i]);
      if (a) a.view.queuePosition = i + 1;
    }
  }

  /** 主动把已 finalize 的任务从清单移除（用户点"清理"） */
  remove(id: string): void {
    let a = this.adapters_.get(id);
    if (!a) return;
    if (!isTerminalState(a.view.state)) {
      AppLogger.warn(TAG, `remove rejected: id=${id} not in terminal state`, null, LOG_DOMAIN_DOWNLOAD);
      return;
    }
    if (!this.tryPurgeNativeOwner_(id, a)) return;
    this.removeInternal_(id);
    this.notify();
  }

  /** 一键清理所有终态任务；逐项确认 native owner 已 purge 后再 dispose adapter。 */
  purgeFinished(): number {
    let removed = 0;
    let terminalIds: string[] = [];
    for (let id of this.orderedIds_) {
      let a = this.adapters_.get(id);
      if (a && isTerminalState(a.view.state)) terminalIds.push(id);
    }
    for (let id of terminalIds) {
      let a = this.adapters_.get(id);
      if (!a || !this.tryPurgeNativeOwner_(id, a)) continue;
      this.removeInternal_(id);
      removed++;
    }
    if (removed > 0) this.notify();
    return removed;
  }

  private tryPurgeNativeOwner_(id: string, adapter: UnifiedDownloadAdapter): boolean {
    if (adapter.purgeNativeOwner === undefined) return true;
    try {
      // 直接经 adapter 调用，保留类方法的 this receiver；提取成局部函数会让依赖
      // this.taskId_/installer_ 的实现失去上下文。
      if (adapter.purgeNativeOwner()) return true;
      AppLogger.warn(TAG, `native purge rejected; retaining adapter id=${id}`, null, LOG_DOMAIN_DOWNLOAD);
    } catch (e) {
      AppLogger.warn(TAG, `native purge threw; retaining adapter id=${id}`, e as Object, LOG_DOMAIN_DOWNLOAD);
    }
    return false;
  }

  private removeInternal_(id: string): void {
    // 清理整组 owner 时同步注销它的成员，避免留下无法操作、持有旧适配器的卡片。
    this.clearAttachedTasks(id);
    this.attachedOwners_.delete(id);
    let waitingIndex = this.waitingIds_.indexOf(id);
    if (waitingIndex >= 0) this.waitingIds_.splice(waitingIndex, 1);
    let pending = this.pendingStarts_.get(id);
    if (pending) pending.reject(new Error('任务已清理: ' + id));
    this.pendingStarts_.delete(id);
    let runningIndex = this.runningIds_.indexOf(id);
    if (runningIndex >= 0) this.runningIds_.splice(runningIndex, 1);

    let a = this.adapters_.get(id);
    if (a) {
      try { a.dispose(); } catch (e) {
        AppLogger.warn(TAG, `adapter dispose threw: id=${id}`, e as Object, LOG_DOMAIN_DOWNLOAD);
      }
    }
    this.adapters_.delete(id);
    let idx = this.orderedIds_.indexOf(id);
    if (idx >= 0) this.orderedIds_.splice(idx, 1);
    this.updateQueuePositions_();
    this.drainQueue_();
  }

  // ============================================================
  //  查询
  // ============================================================

  /** 拿全部 view 快照（按 enqueue 顺序）。返回新数组，调用方可放心 ForEach */
  listAll(): UnifiedTaskView[] {
    let arr: UnifiedTaskView[] = [];
    for (let id of this.orderedIds_) {
      let a = this.adapters_.get(id);
      if (a) arr.push(a.view);
    }
    return arr;
  }

  /** 按分类筛 */
  listByCategory(category: TaskCategory): UnifiedTaskView[] {
    let arr: UnifiedTaskView[] = [];
    for (let id of this.orderedIds_) {
      let a = this.adapters_.get(id);
      if (a && a.view.category === category) arr.push(a.view);
    }
    return arr;
  }

  /** 单个 view 查询（用于 detail 子视图） */
  get(id: string): UnifiedTaskView | null {
    let a = this.adapters_.get(id);
    return a ? a.view : null;
  }

  /** 单个 adapter 查询（用于在 sheet 内调原始 task 的扩展操作，如 MC 任务的 retryFailedOnly） */
  getAdapter(id: string): UnifiedDownloadAdapter | null {
    let a = this.adapters_.get(id);
    return a ? a : null;
  }

  /** 活跃任务数（PREPARING/DOWNLOADING/EXTRACTING/VERIFYING/PAUSED） */
  activeCount(): number {
    let n = 0;
    for (let id of this.orderedIds_) {
      let a = this.adapters_.get(id);
      if (a && isInProgressState(a.view.state)) n++;
    }
    return n;
  }

  /** 等待任务数（FIFO 队列中尚未获得并发槽位的任务） */
  waitingCount(): number {
    let n = 0;
    for (let id of this.orderedIds_) {
      let a = this.adapters_.get(id);
      if (a && a.view.state === UnifiedTaskState.WAITING) n++;
    }
    return n;
  }

  /** 终态任务数（DONE/ERROR/ABORTED） */
  finishedCount(): number {
    let n = 0;
    for (let id of this.orderedIds_) {
      let a = this.adapters_.get(id);
      if (a && isTerminalState(a.view.state)) n++;
    }
    return n;
  }

  totalCount(): number {
    return this.orderedIds_.length;
  }

  /** FAB 用：聚合进度（活跃任务的字节加权平均） */
  aggregateProgress(): number {
    return aggregateProgress(this.listAll());
  }

  /** FAB 用：是否应当显示 */
  shouldShowFab(): boolean {
    if (this.totalCount() === 0) return false;
    // 至少有一个非终态 / 或刚进入终态的任务（终态保留几秒让用户看到结果）
    for (let id of this.orderedIds_) {
      let a = this.adapters_.get(id);
      if (a) return true;
    }
    return false;
  }

  // ============================================================
  //  Listener
  // ============================================================

  addListener(l: RegistryListener): void {
    this.listeners_.push(l);
  }

  removeListener(l: RegistryListener): void {
    let idx = this.listeners_.indexOf(l);
    if (idx >= 0) this.listeners_.splice(idx, 1);
  }

  // ============================================================
  //  通知节流（v6.5.1 2026-05-22 性能修复）
  // ============================================================
  //
  //  原始问题：libcurl 进度回调 5~30 Hz，每 tick 同步触发 listener →
  //  Index 整页 build()、Sheet 整页 build()，主线程过载导致界面卡死/闪退。
  //
  //  策略：
  //   - notifyChange()         → 节流（默认 120ms 一次）。给 progress tick 用。
  //   - notifyChangeImmediate() → 立刻同步触发。给 add/remove/state-transition 用。
  //
  //  细粒度字段（progress / bytesDone / speed）由 @Observed UnifiedTaskView +
  //  @ObjectLink TaskCard 处理，**不**经过 listener 通道。listener 只负责
  //  数组级变化（增删）和粗粒度刷新（FAB / stats bar）。

  /** 节流间隔，毫秒。120ms ≈ 8Hz，远超人眼感知阈值且能彻底避免渲染洪水 */
  private static readonly NOTIFY_THROTTLE_MS = 120;
  /** 待派发的节流 timer id；0 = 当前没有 pending */
  private notifyTimer_: number = 0;

  /**
   * 节流版 notify：高频回调（progress tick）应当用这个。同一 throttle 窗口
   * 内的多次调用合并为一次 listener 触发。
   *
   * adapter 调用方：所有 adapter 在 progress / 阶段变化回调里调本方法。
   */
  notifyChange(): void {
    if (this.notifyTimer_ !== 0) return;  // 已有 pending notify
    this.notifyTimer_ = setTimeout(() => {
      this.notifyTimer_ = 0;
      this.fireListeners_();
    }, DownloadTaskRegistry.NOTIFY_THROTTLE_MS);
  }

  /**
   * 立刻派发：用于 add/remove/state-transition 等"必须立刻可见"的事件。
   * 会把 pending 的节流 notify 一并合并掉。
   */
  notifyChangeImmediate(): void {
    if (this.notifyTimer_ !== 0) {
      clearTimeout(this.notifyTimer_);
      this.notifyTimer_ = 0;
    }
    this.fireListeners_();
  }

  private fireListeners_(): void {
    for (let l of this.listeners_) {
      try { l(); } catch (e) {
        let err = e as Error;
        AppLogger.error(TAG, 'listener threw', err, LOG_DOMAIN_DOWNLOAD);
      }
    }
  }

  /** 内部使用：immediate 触发（保留旧名兼容 enqueue/cancel/remove 等已有调用） */
  private notify(): void {
    this.notifyChangeImmediate();
  }
}

/** 便捷访问器 */
export function getDownloadTaskRegistry(): DownloadTaskRegistry {
  return DownloadTaskRegistry.instance();
}
