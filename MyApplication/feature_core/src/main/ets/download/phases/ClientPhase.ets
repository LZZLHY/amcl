/**
 * ClientPhase.ets — Phase 6.3 第 2 阶段：下载 client.jar
 *
 * 职责：
 *   - 调用 McDownloader.downloadClientJar(versionJson, tempVersionDir)
 *   - 把 NAPI 引擎报的字节级进度桥接到 PhaseProgress（current/total/bytesDone/...）
 *
 * 进度语义：
 *   - 委托 McDownloader.setProgressCallback —— 回调里 stage 包含 'client.jar' 的事件
 *     映射成 PhaseProgress.progress = current/total（按字节计）
 *   - speedBps / etaSeconds / bytesDone / bytesTotal / fileName 透传给 UI
 *
 * 取消：state.cancelled=true 时调 downloader.cancel()（McDownloader 会向 NAPI 引擎发 cancel）。
 *       phase.cancel() 也会被 PhaseRunner 调，相同语义。
 *
 * 创建日期：2026-05-06
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  IDownloadPhase, PhaseContext, PhaseProgress,
} from '../PhaseRunner';
import { DownloadFlowState } from './DownloadFlowState';
import { CancelledError } from 'commons';
import { McDownloader, DownloadProgress } from '../McDownloader';

const TAG = 'ClientPhase';

export class ClientPhase implements IDownloadPhase {
  readonly name: string = 'client';
  readonly weight: number;
  private state_: DownloadFlowState;
  private downloader_: McDownloader;

  constructor(state: DownloadFlowState, downloader: McDownloader, weight: number = 15) {
    this.state_ = state;
    this.downloader_ = downloader;
    this.weight = weight;
  }

  async run(_ctx: PhaseContext, onProgress: (p: PhaseProgress) => void): Promise<void> {
    if (this.state_.cancelled) throw new CancelledError();
    let info = this.state_.versionInfo;
    if (info === null) throw new Error('ClientPhase: state.versionInfo 为空，需要先跑 PreparePhase');

    let phaseName = this.name;

    this.downloader_.setProgressCallback((p: DownloadProgress): void => {
      // 仅捕获 stage 含 'client.jar' 的事件（McDownloader.downloadClientJar 内部会 report 这个 stage）
      if (p.stage.indexOf('client.jar') < 0) return;
      let prog = (p.total > 0) ? (p.current / p.total) : 0;
      if (prog > 1) prog = 1;
      onProgress({
        phase: phaseName,
        progress: prog,
        speedBps: p.speedBps ?? 0,
        message: p.fileName,
        current: p.current,
        total: p.total,
        fileName: p.fileName,
        bytesDone: p.bytesDone,
        bytesTotal: p.bytesTotal,
        etaSeconds: p.etaSeconds,
      });
    });

    let result = await this.downloader_.downloadClientJar(info.versionJson, this.state_.tempVersionDir);
    if (this.state_.cancelled) throw new CancelledError();

    // 显式 100% 收尾 —— 即使 reportFromView 最后一帧 progress 不到 1，UI 也要看见完成
    onProgress({
      phase: phaseName,
      progress: 1.0,
      speedBps: 0,
      message: result,
    });
    hilog.info(0x0000, TAG, 'ClientPhase done: %{public}s', result);
  }

  async cancel(_cleanup: boolean): Promise<void> {
    this.downloader_.cancel();
  }
}
