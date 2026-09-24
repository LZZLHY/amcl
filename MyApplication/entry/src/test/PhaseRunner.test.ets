/*
 * PhaseRunner.test.ets — Phase 6 (PhaseRunner 抽象) 单元测试
 *
 * TDD 红阶段：本文件先于 PhaseRunner.ets 创建。
 *
 * 覆盖范围：
 *   - 顺序执行多个 phase
 *   - 单 phase 失败后续不再执行
 *   - 字节级权重累加正确
 *   - cancel / pause / resume 信号传递到当前 phase
 *   - 空数组安全处理
 *   - onProgress 回调权重映射正确
 *
 * 测试用 mock IDownloadPhase 实现，零 I/O。
 *
 * 实施计划：docs/guides/download-system-implementation-plan.md §Phase 6
 *
 * 创建日期：2026-05-05
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  PhaseRunner,
  IDownloadPhase,
  PhaseContext,
  PhaseProgress,
  RunnerState,
} from 'feature_core';

// ============================================================
//  Mock IDownloadPhase 实现
// ============================================================

class MockPhase implements IDownloadPhase {
  readonly name: string;
  readonly weight: number;
  private resolveRun: (() => void) | null = null;
  private rejectRun: ((err: Error) => void) | null = null;
  private finalProgress: number = 1.0;
  private shouldFail: boolean = false;
  private failError: string = '';
  paused: boolean = false;
  cancelled: boolean = false;
  cleanupOnCancel: boolean = false;
  invokedCount: number = 0;

  constructor(name: string, weight: number) {
    this.name = name;
    this.weight = weight;
  }

  /** 测试控制：让 run 立即成功结束 */
  finishImmediately(progress: number = 1.0): void {
    this.finalProgress = progress;
  }

  /** 测试控制：让 run 失败 */
  setShouldFail(error: string): void {
    this.shouldFail = true;
    this.failError = error;
  }

  /** 测试控制：从外部触发当前 run 的完成 */
  triggerComplete(): void {
    if (this.resolveRun) {
      this.resolveRun();
      this.resolveRun = null;
      this.rejectRun = null;
    }
  }

  triggerFail(err: string): void {
    if (this.rejectRun) {
      this.rejectRun(new Error(err));
      this.rejectRun = null;
      this.resolveRun = null;
    }
  }

  async run(ctx: PhaseContext, onProgress: (p: PhaseProgress) => void): Promise<void> {
    this.invokedCount++;
    if (this.shouldFail) {
      throw new Error(this.failError);
    }
    onProgress({
      phase: this.name,
      progress: this.finalProgress,
      speedBps: 1024,
      message: 'mock running',
    });
    // 立即完成
    return Promise.resolve();
  }

  async pause(): Promise<void> {
    this.paused = true;
  }

  async resume(): Promise<void> {
    this.paused = false;
  }

  async cancel(cleanup: boolean): Promise<void> {
    this.cancelled = true;
    this.cleanupOnCancel = cleanup;
  }
}

class HangingMockPhase implements IDownloadPhase {
  readonly name: string;
  readonly weight: number;
  private resolveRun: (() => void) | null = null;
  private rejectRun: ((err: Error) => void) | null = null;
  paused: boolean = false;
  cancelled: boolean = false;

  constructor(name: string, weight: number) {
    this.name = name;
    this.weight = weight;
  }

  triggerComplete(): void {
    if (this.resolveRun) {
      let r = this.resolveRun;
      this.resolveRun = null;
      this.rejectRun = null;
      r();
    }
  }

  async run(ctx: PhaseContext, onProgress: (p: PhaseProgress) => void): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      this.resolveRun = resolve;
      this.rejectRun = reject;
    });
  }

  async pause(): Promise<void> {
    this.paused = true;
  }

  async resume(): Promise<void> {
    this.paused = false;
  }

  async cancel(cleanup: boolean): Promise<void> {
    this.cancelled = true;
    if (this.rejectRun) {
      this.rejectRun(new Error('cancelled'));
      this.rejectRun = null;
      this.resolveRun = null;
    }
  }
}

function makeContext(): PhaseContext {
  return {
    taskId: 'test-1',
    versionName: '1.20.4',
    gameVersion: '1.20.4',
    loaderType: 'vanilla',
    mcDir: '/tmp/.minecraft',
    filesDir: '/tmp',
  };
}

export default function phaseRunnerTest() {

  // ============================================================
  //  顺序执行
  // ============================================================
  describe('PhaseRunner sequential execution', () => {

    it('空 phase 数组立即完成', 0, async () => {
      let runner = new PhaseRunner([], makeContext());
      await runner.run((p) => { /* */ });
      expect(runner.getState()).assertEqual(RunnerState.Done);
    });

    it('单 phase 顺利完成', 0, async () => {
      let p1 = new MockPhase('p1', 1.0);
      p1.finishImmediately(1.0);
      let runner = new PhaseRunner([p1], makeContext());
      await runner.run((p) => { /* */ });
      expect(p1.invokedCount).assertEqual(1);
      expect(runner.getState()).assertEqual(RunnerState.Done);
    });

    it('多 phase 按顺序执行', 0, async () => {
      let order: string[] = [];
      class TrackingPhase implements IDownloadPhase {
        readonly name: string;
        readonly weight: number = 0.5;
        constructor(name: string) { this.name = name; }
        async run(): Promise<void> { order.push(this.name); }
      }
      let phases: IDownloadPhase[] = [
        new TrackingPhase('a'),
        new TrackingPhase('b'),
        new TrackingPhase('c'),
      ];
      let runner = new PhaseRunner(phases, makeContext());
      await runner.run((p) => { /* */ });
      expect(order.length).assertEqual(3);
      expect(order[0]).assertEqual('a');
      expect(order[1]).assertEqual('b');
      expect(order[2]).assertEqual('c');
    });

    it('phase 失败后续不再执行', 0, async () => {
      let p1 = new MockPhase('p1', 1.0);
      let p2 = new MockPhase('p2', 1.0);
      p2.setShouldFail('oops');
      let p3 = new MockPhase('p3', 1.0);
      let runner = new PhaseRunner([p1, p2, p3], makeContext());

      let threw = false;
      try {
        await runner.run((p) => { /* */ });
      } catch (e) {
        threw = true;
        expect((e as Error).message.indexOf('oops') >= 0).assertTrue();
      }
      expect(threw).assertTrue();
      expect(p1.invokedCount).assertEqual(1);
      expect(p2.invokedCount).assertEqual(1);
      expect(p3.invokedCount).assertEqual(0);  // 不应执行
      expect(runner.getState()).assertEqual(RunnerState.Failed);
    });
  });

  // ============================================================
  //  权重累加
  // ============================================================
  describe('PhaseRunner weight aggregation', () => {

    it('两 phase 各 50% 权重时，第一 phase 100% 进度对应整体 50%', 0, async () => {
      let p1 = new MockPhase('p1', 0.5);
      let p2 = new MockPhase('p2', 0.5);
      let snapshots: number[] = [];
      let runner = new PhaseRunner([p1, p2], makeContext());
      // phases finishImmediately(1.0) → onProgress 一次 progress=1.0
      p1.finishImmediately(1.0);
      p2.finishImmediately(1.0);
      await runner.run((p) => {
        snapshots.push(p.progress);
      });
      // 第一帧 (p1 完成时)：整体 0.5
      // 第二帧 (p2 完成时)：整体 1.0
      expect(snapshots.length >= 2).assertTrue();
      expect(snapshots[0]).assertEqual(0.5);
      expect(snapshots[snapshots.length - 1]).assertEqual(1.0);
    });

    it('权重分配 25/25/50 时进度正确', 0, async () => {
      let p1 = new MockPhase('p1', 0.25);
      let p2 = new MockPhase('p2', 0.25);
      let p3 = new MockPhase('p3', 0.50);
      p1.finishImmediately(1.0);
      p2.finishImmediately(1.0);
      p3.finishImmediately(1.0);
      let snapshots: number[] = [];
      let runner = new PhaseRunner([p1, p2, p3], makeContext());
      await runner.run((p) => {
        snapshots.push(p.progress);
      });
      expect(snapshots[0]).assertEqual(0.25);
      expect(snapshots[1]).assertEqual(0.50);
      expect(snapshots[2]).assertEqual(1.00);
    });

    it('权重总和不等于 1 时归一化', 0, async () => {
      // 权重 1+1+2 = 4，应归一化为 0.25 / 0.25 / 0.5
      let p1 = new MockPhase('p1', 1);
      let p2 = new MockPhase('p2', 1);
      let p3 = new MockPhase('p3', 2);
      p1.finishImmediately(1.0);
      p2.finishImmediately(1.0);
      p3.finishImmediately(1.0);
      let snapshots: number[] = [];
      let runner = new PhaseRunner([p1, p2, p3], makeContext());
      await runner.run((p) => snapshots.push(p.progress));
      expect(snapshots[0]).assertEqual(0.25);
      expect(snapshots[2]).assertEqual(1.0);
    });
  });

  // ============================================================
  //  cancel 信号
  // ============================================================
  describe('PhaseRunner cancel propagation', () => {

    it('cancel 在执行中 → 当前 phase.cancel 被调用', 0, async () => {
      let p1 = new HangingMockPhase('p1', 1.0);
      let runner = new PhaseRunner([p1], makeContext());
      let runPromise = runner.run((p) => { /* */ });

      // 等微任务跑完，让 runner 进入 p1.run
      await new Promise<void>((r) => setTimeout(r, 10));

      runner.cancel(false);

      // 等 cancel 收敛
      try { await runPromise; } catch (e) { /* expected */ }
      expect(p1.cancelled).assertTrue();
      expect(runner.getState()).assertEqual(RunnerState.Cancelled);
    });

    it('cancel(cleanup=true) 透传到 phase.cancel', 0, async () => {
      let p1 = new HangingMockPhase('p1', 1.0);
      let runner = new PhaseRunner([p1], makeContext());
      let runPromise = runner.run((p) => { /* */ });
      await new Promise<void>((r) => setTimeout(r, 10));
      runner.cancel(true);
      try { await runPromise; } catch (e) { /* */ }
      expect(p1.cancelled).assertTrue();
      // cleanup 字段需通过自定义 mock 暴露 — 此测试仅验证 cancel 被调用
    });

    it('已 Done 的 runner 调用 cancel 是 no-op', 0, async () => {
      let p1 = new MockPhase('p1', 1.0);
      p1.finishImmediately(1.0);
      let runner = new PhaseRunner([p1], makeContext());
      await runner.run((p) => { /* */ });
      expect(runner.getState()).assertEqual(RunnerState.Done);
      runner.cancel(false);  // 应不抛异常
      expect(runner.getState()).assertEqual(RunnerState.Done);  // 状态不变
    });
  });

  // ============================================================
  //  pause / resume
  // ============================================================
  describe('PhaseRunner pause/resume', () => {

    it('pause 调用当前 phase.pause', 0, async () => {
      let p1 = new HangingMockPhase('p1', 1.0);
      let runner = new PhaseRunner([p1], makeContext());
      let runPromise = runner.run((p) => { /* */ });
      await new Promise<void>((r) => setTimeout(r, 10));

      await runner.pause();
      expect(p1.paused).assertTrue();
      expect(runner.getState()).assertEqual(RunnerState.Paused);

      // 收尾
      runner.cancel(false);
      try { await runPromise; } catch (e) { /* */ }
    });

    it('resume 调用当前 phase.resume', 0, async () => {
      let p1 = new HangingMockPhase('p1', 1.0);
      let runner = new PhaseRunner([p1], makeContext());
      let runPromise = runner.run((p) => { /* */ });
      await new Promise<void>((r) => setTimeout(r, 10));
      await runner.pause();
      expect(p1.paused).assertTrue();
      await runner.resume();
      expect(p1.paused).assertFalse();
      expect(runner.getState()).assertEqual(RunnerState.Running);
      runner.cancel(false);
      try { await runPromise; } catch (e) { /* */ }
    });
  });

  // ============================================================
  //  状态机
  // ============================================================
  describe('PhaseRunner state machine', () => {

    it('初始状态：Idle', 0, () => {
      let runner = new PhaseRunner([], makeContext());
      expect(runner.getState()).assertEqual(RunnerState.Idle);
    });

    it('完成后状态：Done', 0, async () => {
      let p1 = new MockPhase('p1', 1.0);
      p1.finishImmediately(1.0);
      let runner = new PhaseRunner([p1], makeContext());
      await runner.run((p) => { /* */ });
      expect(runner.getState()).assertEqual(RunnerState.Done);
    });

    it('失败后状态：Failed', 0, async () => {
      let p1 = new MockPhase('p1', 1.0);
      p1.setShouldFail('oops');
      let runner = new PhaseRunner([p1], makeContext());
      try { await runner.run((p) => { /* */ }); } catch (e) { /* */ }
      expect(runner.getState()).assertEqual(RunnerState.Failed);
    });

    it('已 Done 不能再 run（抛异常）', 0, async () => {
      let p1 = new MockPhase('p1', 1.0);
      p1.finishImmediately(1.0);
      let runner = new PhaseRunner([p1], makeContext());
      await runner.run((p) => { /* */ });
      let threw = false;
      try {
        await runner.run((p) => { /* */ });
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });
  });
}
