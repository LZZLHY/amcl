/**
 * JdkInstallTask.ets — JdkInstaller 适配器
 *
 * 把 JDK 下载接入 registry，让它和 MC / mod 任务在同一个 DownloadTasksSheet 里展示。
 *
 * 设计要点：
 *   - 通过 `JdkManager.createInstaller(version)` 拿到一个**独立**的 JdkInstaller
 *   - 多个 JdkInstallTask 实例各自持有独立 installer，下载状态 / 进度回调
 *     / cancel token / DM taskId 全部 per-instance —— 多 JDK 真正并发互不影响
 *   - 三阶段：downloading（DownloadManager 拉 zip）→ verifying（SHA-256）→ extracting
 *   - 解压期间 cancel：取消标志被设置，但 unzip 调用本身不可中断；
 *     extract 完成后 installer 检测 cancel → 删除已落地文件 → 报 ABORTED
 *
 * Phase 2 限制：JDK 不支持 pause/resume（解压无法暂停）。
 *
 * 2026-05-26 重构（B-1 修复）：原版本依赖 JdkManager 单实例的 setDownloadCallback
 * 单插槽，并发 JDK 下载会互相覆盖回调；现在改走 per-task installer，多版本
 * 真正并发安全。详见 docs/self-inspection/2026-05-26_AMCL_多任务下载并发缺陷诊断.md §B-1
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  UnifiedDownloadAdapter, UnifiedTaskView, UnifiedTaskState, TaskCategory,
} from 'feature_core';
import { JdkManager, JdkDownloadProgress } from './JdkManager';
import { JdkInstaller } from './JdkInstaller';
import { DownloadTaskRegistry } from 'feature_core';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_LAUNCH } from 'commons';

const TAG = 'JdkInstallTask';

/** JdkDownloadProgress.phase -> UnifiedTaskState */
function mapJdkPhase(p: string): string {
  switch (p) {
    case 'downloading': return UnifiedTaskState.DOWNLOADING;
    case 'extracting':  return UnifiedTaskState.EXTRACTING;
    case 'verifying':   return UnifiedTaskState.VERIFYING;
    default:             return UnifiedTaskState.PREPARING;
  }
}

/**
 * 三阶段 → 单根进度条的分段映射（2026-07-29 修复「进度跑到 100% 又回 0 重来一遍」）。
 *
 * 症状根因：download / verifying / extracting 三个阶段各自用 0~100 的**独立**百分比，
 * 而 UI（TaskCard / 聚合进度条）只有一根 `view.progress`。于是用户看到：
 *   下载 0→100 → SHA-256 校验把它打回 0 → 解压又把它打回 0→100，
 * 看起来就像「下载了两次」。实际日志只有一次下载（bytes=122293345/122293345, dur=12148ms）。
 *
 * 修法：把三阶段压进一条单调不减的 0~100 轴，各占一段权重：
 *   downloading 0~90（下载是耗时主体）
 *   verifying  90~95（SHA-256 全文件读一遍，~1s）
 *   extracting 95~100（解压）
 * 这样进度条永远只升不降，且各阶段仍有可见推进。
 */
const JDK_PHASE_BASE: number = 0;
function mapJdkPercentToOverall(phase: string, percent: number): number {
  const p = Math.max(0, Math.min(100, percent));
  switch (phase) {
    case 'downloading': return JDK_PHASE_BASE + p * 0.90;
    case 'verifying':   return 90 + p * 0.05;
    case 'extracting':  return 95 + p * 0.05;
    default:            return JDK_PHASE_BASE;
  }
}

export class JdkInstallTask implements UnifiedDownloadAdapter {
  readonly view: UnifiedTaskView = new UnifiedTaskView();
  private jdkVersion_: string;
  /**
   * per-task installer。null 表示构造时 createInstaller 失败（未知 / 未上线版本），
   * start() 会立即把 view 标 ERROR 并 reject。
   */
  private installer_: JdkInstaller | null;
  /** 构造期失败原因（installer 为 null 时填，避免 start 用模糊"安装失败"误导用户）*/
  private initError_: string;
  /** cancel 后置 true，让回调里的 view.state 别再被 progress 反复覆盖 */
  private cancelRequested_: boolean = false;
  /** 本次 start() 的起始时刻，用于在终态填 view.durationMs（UI 的"用时"）。 */
  private startedAtMs_: number = 0;
  /**
   * 活动账本 activityId（活动账本 · L2-b 修正）。
   *
   * **必须由调用方传入，不能用 `view.startedAtMs`。** 后者是 registry 在**出队**时
   * 才赋值的时间戳，而调用方（Index）是在 **enqueue 之前**就用 `Date.now()` 开好了
   * 账本 —— 两个时间戳不同，用 view 的那个会把 native 下载日志绑到一个没有 scope 的
   * id 上，结果账本里只有 manifest、一行下载日志都没有。
   * 这正是 2026-08-01 自审发现的缺陷 3。
   */
  private activityId_: number = 0;

  /**
   * @param forceReinstall 「更新」入口传 true。见 JdkInstaller.forceReinstall 的注释：
   *   不传的话，因为过期的安装在新语义下仍算「已装」，更新会命中幂等门直接报完成。
   */
  constructor(jdkVersion: string, manager: JdkManager, activityId: number = 0,
              forceReinstall: boolean = false) {
    this.jdkVersion_ = jdkVersion;
    this.activityId_ = activityId;
    this.installer_ = manager.createInstaller(jdkVersion, forceReinstall);
    this.initError_ = (this.installer_ === null)
      ? 'JDK ' + jdkVersion + ' 未知或未发布'
      : '';

    this.view.id = 'jdk:' + jdkVersion;
    this.view.category = TaskCategory.JDK;
    this.view.title = (forceReinstall ? 'JDK ' + jdkVersion + ' 更新' : 'JDK ' + jdkVersion);
    this.view.subtitle = jdkVersion === '25'
      ? 'OpenJDK 25（实验性 · 26.1+）'
      : jdkVersion === '21'
        ? 'OpenJDK 21（实验性 · 1.20.5+）'
        : 'OpenJDK 17（推荐 · 1.20.4-）';
    this.view.state = UnifiedTaskState.PREPARING;
    this.view.canCancel = true;
    // JDK 不支持 pause；canViewDetail=true 让用户能看到三阶段进度
    this.view.canViewDetail = true;
  }

  start(): Promise<void> {
    // 构造时已失败：直接走错误终态，不触发任何下载
    let inst = this.installer_;
    if (inst === null) {
      this.view.state = UnifiedTaskState.ERROR;
      this.view.errorMessage = this.initError_;
      this.view.canCancel = false;
      this.view.canRetry = false;
      try { DownloadTaskRegistry.instance().notifyChange(); } catch (e) { /* ignore */ }
      return Promise.reject(new Error(this.initError_));
    }

    this.cancelRequested_ = false;
    this.view.state = UnifiedTaskState.PREPARING;
    this.view.errorMessage = '';
    this.view.errorKind = '';
    // ⚠️ 2026-08-04 修复「无法取消下载」：**每次开跑都必须把操作标志复位**。
    //   所有终态分支都会置 canCancel=false / canRetry=true，而这里过去只复位了
    //   state/progress/errorMessage。于是重试起来的那次下载 canCancel 仍是 false，
    //   TaskCard 的 `if (view.canCancel)` 不成立 → **取消按钮直接不渲染**，
    //   用户对着一个正在跑的 118 MB 下载完全无法中止。
    //   canRetry 同理要清掉：运行中不该出现可点的重试按钮。
    this.view.canCancel = true;
    this.view.canRetry = false;
    // 重试时进度回到 0（此时确实要重来），并重置计时基准。
    this.view.progress = 0;
    this.view.durationMs = 0;
    // ⚠️ 2026-07-29：JDK 任务过去从不给 view.durationMs 赋值，于是 TaskCard 的
    //   `'完成 · 用时 ' + formatDuration_(view.durationMs)` 永远拿到 0 → 用时空白。
    //   Registry 的 drainQueue_ 会设 startedAtMs，但那是"出队时刻"；这里自己记一份
    //   起点，终态时算差值，保证 MC/mod 之外的 JDK 任务也有耗时可看。
    this.startedAtMs_ = Date.now();
    AppLogger.info(TAG, `start(): JDK ${this.jdkVersion_} invoking downloadAndInstall`, LOG_DOMAIN_LAUNCH);

    // per-task installer，独立回调插槽 —— 多 JDK 并发互不影响（B-1 修复点）
    inst.setDownloadCallback((p: JdkDownloadProgress) => this.handleProgress_(p));
    // 活动账本：用构造时传入的 activityId（= Index 开账本用的那个值）。
    // 不能用 view.startedAtMs —— 见 activityId_ 字段注释。
    inst.activityId = this.activityId_;

    return inst.downloadAndInstall().then((ok: boolean) => {
      this.markDuration_();
      if (this.cancelRequested_) {
        this.view.state = UnifiedTaskState.ABORTED;
        this.view.canCancel = false;
        this.view.canRetry = true;
      } else if (ok) {
        this.view.state = UnifiedTaskState.DONE;
        this.view.progress = 100;
        this.view.canCancel = false;
      } else {
        // installer 在内部 catch 已经报 progress，但没抛异常
        if (this.view.state !== UnifiedTaskState.ERROR) {
          this.view.state = UnifiedTaskState.ERROR;
          if (this.view.errorMessage.length === 0) {
            this.view.errorMessage = '安装失败';
          }
        }
        this.view.canCancel = false;
        this.view.canRetry = true;
      }
      try { DownloadTaskRegistry.instance().notifyChange(); } catch (e) { /* ignore */ }
    }).catch((e: Error) => {
      this.markDuration_();
      this.view.state = UnifiedTaskState.ERROR;
      this.view.errorMessage = e.message;
      this.view.canCancel = false;
      this.view.canRetry = true;
      try { DownloadTaskRegistry.instance().notifyChange(); } catch (e2) { /* ignore */ }
      throw e;
    });
  }

  /** 终态填耗时（UI 的"用时/耗时"读 view.durationMs）。只在起点有效时写。 */
  private markDuration_(): void {
    if (this.startedAtMs_ > 0) {
      this.view.durationMs = Math.max(0, Date.now() - this.startedAtMs_);
    }
  }

  cancel(_cleanupFiles: boolean): Promise<void> {
    this.cancelRequested_ = true;
    let inst = this.installer_;
    if (inst !== null) inst.requestCancel();
    hilog.info(0x0000, TAG, 'cancel requested for JDK %{public}s', this.jdkVersion_);
    // 用户感受：下载阶段几乎立刻中止；校验 / 解压阶段需要等本步完成
    return Promise.resolve();
  }

  pause(): Promise<void> {
    return Promise.resolve();
  }

  resume(): Promise<void> {
    return Promise.resolve();
  }

  async retry(): Promise<void> {
    // ⚠️ 2026-07-29 根因修复「取消后点重试永久卡住」：
    //   这里**不能**再校验 view.state 必须是 ERROR/ABORTED。
    //   DownloadTaskRegistry.drainQueue_ 在调用 pending.action()（即本方法）**之前**
    //   就已经把 view.state 改成了 pending.startState（= PREPARING）：
    //       adapter.view.state = pending.startState;   // 'preparing'
    //       actionPromise = pending.action();          // → 本方法
    //   于是这条守卫恒不满足 → 静默 return → 下载永不启动，任务卡在 PREPARING、
    //   进度条停在原处，用户怎么点都没反应。
    //   真机日志实锤：Registry 侧 `invoking action for id=jdk:21 startState=preparing`
    //   已打印，但本方法的入口日志从未出现。
    //   准入控制已由 Registry 完成（retry() 查 canRetry + scheduleAction_ 查重入），
    //   适配器这里不需要、也不应该二次校验状态。
    let inst = this.installer_;
    // 用 AppLogger 写进 amcl_launcher.log（hilog 只进系统日志，排查时容易漏看）。
    AppLogger.info(TAG,
      `retry() entry: JDK ${this.jdkVersion_} state=${this.view.state} `
      + `downloading=${inst !== null ? String(inst.isDownloading()) : 'no-inst'}`,
      LOG_DOMAIN_LAUNCH);
    if (inst !== null) {
      // ⚠️ 2026-07-29：原实现 purgeNativeOwners() 一次不成就直接 reject，用户看到
      //   "请稍后重试"或干脆停在 0%。但 native 取消后要等 worker/curl 收敛（可达数秒），
      //   一次性判定过于苛刻。这里给最多 ~3s 的有限重试窗口（每 300ms 一次）。
      let purged = false;
      for (let i = 0; i < 10; i++) {
        try { purged = inst.purgeNativeOwners(); } catch (e) { purged = false; }
        if (purged) break;
        await new Promise<void>((resolve): void => { setTimeout((): void => resolve(), 300); });
      }
      if (!purged) {
        AppLogger.warn(TAG,
          `retry aborted: native owners not purged for JDK ${this.jdkVersion_}`,
          null, LOG_DOMAIN_LAUNCH);
        throw new Error('旧 JDK 下载任务仍在收敛，请稍后再试');
      }
    }
    AppLogger.info(TAG, `retry(): purge ok, restarting JDK ${this.jdkVersion_}`, LOG_DOMAIN_LAUNCH);
    await this.start();
  }

  purgeNativeOwner(): boolean {
    let inst = this.installer_;
    return inst === null || inst.purgeNativeOwners();
  }

  dispose(): void {
    // 解绑回调，避免 installer 持有 adapter 引用阻止 GC
    let inst = this.installer_;
    if (inst !== null) {
      try { inst.setDownloadCallback(null); } catch (e) { /* ignore */ }
    }
  }

  // ============================================================
  //  JdkDownloadProgress -> UnifiedTaskView
  // ============================================================

  private handleProgress_(p: JdkDownloadProgress): void {
    // cancel 被请求后忽略后续 progress（防止状态闪烁）
    if (this.cancelRequested_) return;

    this.view.state = mapJdkPhase(p.phase);
    // 三阶段映射到单根单调进度条（见 mapJdkPercentToOverall）。再取 max 兜底，
    // 确保任何阶段切换/迟到回调都不会让进度倒退。
    const overall = mapJdkPercentToOverall(p.phase, p.percent);
    this.view.progress = Math.max(this.view.progress, Math.min(100, overall));
    this.view.speedBps = Math.max(0, p.speedKBs) * 1024;
    this.view.currentLabel = p.message;
    try { DownloadTaskRegistry.instance().notifyChange(); } catch (e) { /* ignore */ }
  }
}
