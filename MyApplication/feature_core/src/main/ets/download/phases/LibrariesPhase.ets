/**
 * LibrariesPhase.ets — Phase 6.3 第 3 阶段：下载 libraries
 *
 * 职责：
 *   - 调用 McDownloader.downloadLibraries(versionJson) 委托 NAPI 引擎下完所有 libraries
 *   - 把 stage 含 'libraries' 的进度事件映射成 PhaseProgress
 *
 * 取消：等同 ClientPhase，cancel() 透传到 McDownloader。
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

const TAG = 'LibrariesPhase';

export class LibrariesPhase implements IDownloadPhase {
  readonly name: string = 'libraries';
  readonly weight: number;
  private state_: DownloadFlowState;
  private downloader_: McDownloader;

  constructor(state: DownloadFlowState, downloader: McDownloader, weight: number = 25) {
    this.state_ = state;
    this.downloader_ = downloader;
    this.weight = weight;
  }

  async run(_ctx: PhaseContext, onProgress: (p: PhaseProgress) => void): Promise<void> {
    if (this.state_.cancelled) throw new CancelledError();
    let info = this.state_.versionInfo;
    if (info === null) throw new Error('LibrariesPhase: state.versionInfo 为空');

    let phaseName = this.name;
    this.downloader_.setProgressCallback((p: DownloadProgress): void => {
      if (p.stage.indexOf('libraries') < 0) return;
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

    let result = await this.downloader_.downloadLibraries(info.versionJson);
    if (this.state_.cancelled) throw new CancelledError();

    onProgress({
      phase: phaseName,
      progress: 1.0,
      speedBps: 0,
      message: result,
    });
    hilog.info(0x0000, TAG, 'LibrariesPhase done: %{public}s', result);
  }

  async cancel(_cleanup: boolean): Promise<void> {
    this.downloader_.cancel();
  }
}
