/**
 * PreparePhase.ets — Phase 6.3 第 1 阶段：拉取版本信息
 *
 * 职责：
 *   1. 调用 McDownloader.fetchVersionInfo(gameVersion) 拿 manifest + version.json
 *   2. 把原始 version.json 写入 state.tempJsonPath（供后续 MergePhase 读）
 *   3. 写入 state.versionInfo 让 ClientPhase / LibrariesPhase / AssetsPhase 复用
 *
 * 进度语义：
 *   - 阶段开始 onProgress(progress=0)
 *   - 阶段完成 onProgress(progress=1)
 *   - 中间无字节级进度（fetchVersionInfo 内部 ~50KB 文本，太小没必要）
 *
 * 取消：state.cancelled=true 时阶段开始 / 完成前抛 '已取消'。
 *       fetchVersionInfo 自身没有 cancel 接口（http.createHttp），
 *       所以中段无法立即停 —— 实测 manifest+version.json 一般 <1s，可接受。
 *
 * 创建日期：2026-05-06
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  IDownloadPhase, PhaseContext, PhaseProgress,
} from '../PhaseRunner';
import { DownloadFlowState } from './DownloadFlowState';
import { CancelledError } from 'commons';
import { McDownloader } from '../McDownloader';
import { writeTextFile } from 'commons';
import { VersionParser } from '../../version/VersionParser';
import { ensureMinecraftLoggingConfig } from '../../version/MinecraftLoggingConfig';

const TAG = 'PreparePhase';

export class PreparePhase implements IDownloadPhase {
  readonly name: string = 'prepare';
  readonly weight: number;
  private state_: DownloadFlowState;
  private downloader_: McDownloader;

  constructor(state: DownloadFlowState, downloader: McDownloader, weight: number = 2) {
    this.state_ = state;
    this.downloader_ = downloader;
    this.weight = weight;
  }

  async run(_ctx: PhaseContext, onProgress: (p: PhaseProgress) => void): Promise<void> {
    if (this.state_.cancelled) throw new CancelledError();

    onProgress({
      phase: this.name,
      progress: 0,
      speedBps: 0,
      message: '获取版本信息',
    });

    let info = await this.downloader_.fetchVersionInfo(this.state_.gameVersion);
    this.state_.versionInfo = info;

    // 确保父目录存在再写
    PreparePhase.ensureDir(this.state_.tempVersionDir);
    writeTextFile(this.state_.tempJsonPath, info.rawJson);
    const parsed = VersionParser.parse(this.state_.tempJsonPath);
    await ensureMinecraftLoggingConfig(this.state_.mcDir, parsed?.loggingClient);

    if (this.state_.cancelled) throw new CancelledError();

    onProgress({
      phase: this.name,
      progress: 1.0,
      speedBps: 0,
      message: '版本信息获取完成',
    });

    hilog.info(0x0000, TAG, 'PreparePhase done: %{public}s libs=%{public}d',
      this.state_.gameVersion, info.versionJson.libraries.length);
  }

  private static ensureDir(dir: string): void {
    try { fs.mkdirSync(dir, true); } catch (e) { /* exists */ }
  }

}
