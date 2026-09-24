/**
 * PhaseRunner.ets — Phase 6 (S3-2): IDownloadPhase 抽象 + 顺序调度器
 *
 * 目标：把 DownloadTask 硬编码的 6 阶段（prepare/client/libraries/assets/
 *      modloader/merge）抽象为可插拔的 IDownloadPhase 接口。
 *      未来扩展整合包 / 资源包 / mod 安装流程时只需新写 phase 类，不改 runner。
 *
 * 当前状态（Phase 6.5 已完成）：接口 + runner + 6 个 phase 类（PreparePhase /
 * ClientPhase / LibrariesPhase / AssetsPhase / ModloaderPhase / MergePhase）+
 * DownloadFlowState 共享状态全部就绪；DownloadTask.doStart 已迁移到 PhaseRunner.run。
 *
 * 测试：entry/src/test/PhaseRunner.test.ets
 * 实施计划：docs/guides/download-system-implementation-plan.md §Phase 6
 *
 * 创建日期：2026-05-05
 */

import { AppLogger } from 'commons';

const TAG = 'PhaseRunner';

// ============================================================
//  接口与类型
// ============================================================

/** 阶段执行上下文（DownloadTask 传入的固定参数） */
export interface PhaseContext {
  taskId: string;
  versionName: string;
  gameVersion: string;
  loaderType: string;
  mcDir: string;
  filesDir: string;
}

/** 阶段进度事件 */
export interface PhaseProgress {
  phase: string;       // 阶段名（'client' / 'libraries' / ...）
  progress: number;    // 阶段内进度 0~1
  speedBps: number;    // 当前速度
  message: string;     // 用户可读说明
  // v6 (Phase 6.3): 可选字节级进度字段，供 UI 字节级展示与权重重算使用。
  // download 类 phase（ClientPhase/LibrariesPhase/AssetsPhase）会填，其他可不填。
  current?: number;        // 阶段内当前已完成单位（字节 / 文件数）
  total?: number;          // 阶段内单位总数
  fileName?: string;       // 当前正在处理的文件名（UI "正在下载" 行）
  bytesDone?: number;      // NAPI 引擎报的累计字节
  bytesTotal?: number;     // NAPI 引擎报的总字节
  etaSeconds?: number;     // 剩余秒数；-1 未知
}

/** 单个阶段的契约 */
export interface IDownloadPhase {
  /** 阶段名（也是 DownloadPhase 枚举值，用于 PHASE_WEIGHTS_MC 字典） */
  readonly name: string;
  /** 字节级权重；runner 内部按总和归一化 */
  readonly weight: number;
  /** 跑这个阶段。onProgress 回调阶段内进度（0~1）。 */
  run(ctx: PhaseContext, onProgress: (p: PhaseProgress) => void): Promise<void>;
  /** 暂停（可选） */
  pause?(): Promise<void>;
  /** 恢复（可选） */
  resume?(): Promise<void>;
  /** 取消（可选）；cleanup=true 时同时清理磁盘残留 */
  cancel?(cleanup: boolean): Promise<void>;
}

/** Runner 状态机 */
export enum RunnerState {
  Idle = 'Idle',
  Running = 'Running',
  Paused = 'Paused',
  Done = 'Done',
  Failed = 'Failed',
  Cancelled = 'Cancelled',
}

// ============================================================
//  PhaseRunner — 顺序调度器
// ============================================================

/**
 * 顺序跑 phases 数组；累计权重计算总进度；信号传递给当前 phase。
 *
 * 不变量：
 *   - 同一 runner 只能 run 一次（再次 run 会抛异常）
 *   - cancel 在 Done / Failed / Cancelled 状态下是 no-op
 *   - pause / resume 仅在 Running / Paused 之间切换
 */
export class PhaseRunner {
  private phases_: IDownloadPhase[];
  private ctx_: PhaseContext;
  private state_: RunnerState = RunnerState.Idle;
  private currentIndex_: number = -1;
  private currentPhase_: IDownloadPhase | null = null;
  private cancelRequested_: boolean = false;
  private cancelCleanup_: boolean = false;

  constructor(phases: IDownloadPhase[], ctx: PhaseContext) {
    this.phases_ = phases;
    this.ctx_ = ctx;
  }

  /** 当前状态 */
  getState(): string {
    return this.state_;
  }

  /**
   * 跑所有 phases；任一抛异常 → reject + state=Failed。
   * onProgress 接收**全局**累计进度（按权重归一化的 0~1）。
   */
  async run(onProgress: (p: PhaseProgress) => void): Promise<void> {
    if (this.state_ !== RunnerState.Idle) {
      throw new Error('PhaseRunner.run can only be called once (state=' + this.state_ + ')');
    }
    this.state_ = RunnerState.Running;

    if (this.phases_.length === 0) {
      this.state_ = RunnerState.Done;
      return;
    }

    // 计算权重归一化分母
    let totalWeight = 0;
    for (let p of this.phases_) totalWeight += p.weight;
    if (totalWeight <= 0) totalWeight = this.phases_.length;  // 防御：全 0 权重时退化为均分

    let cumulativeWeightDone = 0;

    for (let i = 0; i < this.phases_.length; i++) {
      if (this.cancelRequested_) {
        this.state_ = RunnerState.Cancelled;
        throw new Error('cancelled');
      }

      let phase = this.phases_[i];
      this.currentIndex_ = i;
      this.currentPhase_ = phase;

      let phaseWeight = phase.weight / totalWeight;
      let baseProgress = cumulativeWeightDone / totalWeight;

      try {
        await phase.run(this.ctx_, (p: PhaseProgress): void => {
          // 把阶段内进度（0~1）映射到全局进度
          let global = baseProgress + (p.progress * phaseWeight);
          if (global > 1) global = 1;
          // v6 (Phase 6.3): 透传可选字节级字段
          let evt: PhaseProgress = {
            phase: p.phase,
            progress: global,
            speedBps: p.speedBps,
            message: p.message,
            current: p.current,
            total: p.total,
            fileName: p.fileName,
            bytesDone: p.bytesDone,
            bytesTotal: p.bytesTotal,
            etaSeconds: p.etaSeconds,
          };
          onProgress(evt);
        });
      } catch (e) {
        let err = e as Error;
        if (this.cancelRequested_) {
          this.state_ = RunnerState.Cancelled;
        } else {
          this.state_ = RunnerState.Failed;
          AppLogger.error(TAG, 'phase ' + phase.name + ' failed: ' + err.message);
        }
        throw err;
      }

      // 阶段完成；累计权重。
      // 不再额外触发一次 onProgress —— 调用方（DownloadTask）会在 phase 内部
      // 触发最终进度回调（如 progress=1.0 表示该 phase 完成）。重复触发会让
      // UI 看到同一进度被报告两次，并破坏权重断言（见 PhaseRunner.test.ets）。
      cumulativeWeightDone += phase.weight;
    }

    this.currentIndex_ = -1;
    this.currentPhase_ = null;
    this.state_ = RunnerState.Done;
  }

  /** 暂停当前 phase（透传到 phase.pause） */
  async pause(): Promise<void> {
    if (this.state_ !== RunnerState.Running) return;
    let phase = this.currentPhase_;
    if (phase !== null && phase.pause !== undefined) {
      await phase.pause();
    }
    this.state_ = RunnerState.Paused;
  }

  /** 恢复 */
  async resume(): Promise<void> {
    if (this.state_ !== RunnerState.Paused) return;
    let phase = this.currentPhase_;
    if (phase !== null && phase.resume !== undefined) {
      await phase.resume();
    }
    this.state_ = RunnerState.Running;
  }

  /**
   * 取消当前 phase（透传到 phase.cancel）；
   * Done / Failed / Cancelled 状态下是 no-op。
   * 同步设标志 + 异步发送 cancel 信号；run() 看到标志后会 reject。
   */
  cancel(cleanup: boolean): void {
    if (this.state_ === RunnerState.Done || this.state_ === RunnerState.Failed
        || this.state_ === RunnerState.Cancelled) {
      return;
    }
    this.cancelRequested_ = true;
    this.cancelCleanup_ = cleanup;
    let phase = this.currentPhase_;
    if (phase !== null && phase.cancel !== undefined) {
      // fire-and-forget：phase.cancel 的 Promise 由 phase 自己内部 await
      // 提取 phaseName 到闭包外，规避 ArkTS '可能 null' 静态检查
      let phaseName = phase.name;
      phase.cancel(cleanup).catch((e: Error): void => {
        AppLogger.warn(TAG, 'phase ' + phaseName + ' cancel threw: ' + e.message);
      });
    }
  }
}
