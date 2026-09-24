/**
 * DownloadFlowState.ets — Phase 6.3 跨 phase 共享可变状态容器
 *
 * 由 DownloadTask 构造，依次传给 PreparePhase / ClientPhase / ... / MergePhase。
 * Phase 之间通过读写本对象的字段交换数据：
 *   - PreparePhase 写 versionInfo + tempJsonPath
 *   - ClientPhase 读 versionInfo + tempVersionDir，下载到 tempVersionDir/<gv>.jar
 *   - LibrariesPhase / AssetsPhase 只读 versionInfo
 *   - ModloaderPhase 写 loaderJsonPath + installSandboxDir
 *   - MergePhase 读 tempJsonPath + loaderJsonPath + installSandboxDir
 *
 * 输入字段（构造时传入，运行时不变）放在前面；
 * 跨 phase 共享数据（运行时由 phase 写入）放在后面。
 *
 * 设计要点：
 *   - 不持有 McDownloader / ModLoaderManager 引用 —— 这些由对应 phase 的构造器单独传入。
 *     原因：DownloadFlowState 是纯数据容器，不应耦合下载/安装实现。
 *   - cancelled 标志由 DownloadTask 在 cancel() 时翻黑；phase 内部通过引用本对象读到。
 *
 * 实施计划：docs/guides/download-system-implementation-plan.md §Phase 6.3
 *
 * 创建日期：2026-05-06
 */

import { ModLoaderType } from '../../modloader/ModLoaderTypes';
import { FetchVersionInfoResult } from '../McDownloader';

export class DownloadFlowState {
  // 输入（构造后只读，TypeScript 没有真正的 readonly 但约定不改）
  readonly gameVersion: string;
  readonly loaderType: ModLoaderType | null;
  readonly loaderVersion: string;
  readonly versionName: string;
  readonly mcDir: string;
  readonly filesDir: string;
  readonly tempDir: string;          // mcDir + '/download-temp'
  readonly tempVersionDir: string;   // tempDir + '/versions/' + gameVersion
  readonly targetDir: string;        // mcDir + '/versions/' + versionName

  // 跨 phase 写入的数据
  versionInfo: FetchVersionInfoResult | null = null;
  tempJsonPath: string = '';                  // tempVersionDir + '/' + gameVersion + '.json'
  loaderJsonPath: string | null = null;       // 由 ModloaderPhase 填，MergePhase 读
  installSandboxDir: string = '';             // Forge 沙箱根；为空表示无沙箱（vanilla / Fabric）

  // 取消标志（DownloadTask 翻黑，phase 在合适检查点抛 '已取消'）
  cancelled: boolean = false;

  constructor(
    gameVersion: string,
    loaderType: ModLoaderType | null,
    loaderVersion: string,
    versionName: string,
    mcDir: string,
    filesDir: string,
  ) {
    this.gameVersion = gameVersion;
    this.loaderType = loaderType;
    this.loaderVersion = loaderVersion;
    this.versionName = versionName;
    this.mcDir = mcDir;
    this.filesDir = filesDir;
    this.tempDir = mcDir + '/download-temp';
    this.tempVersionDir = this.tempDir + '/versions/' + gameVersion;
    this.targetDir = mcDir + '/versions/' + versionName;
    this.tempJsonPath = this.tempVersionDir + '/' + gameVersion + '.json';
  }
}
