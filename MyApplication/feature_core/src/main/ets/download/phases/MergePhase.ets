/**
 * MergePhase.ets — Phase 6.3 第 6 阶段：合并 JSON + 迁入沙箱 libraries
 *
 * 职责：
 *   1. VersionJsonMerger.merge(tempJsonPath, loaderJsonPath, versionName, targetDir, mcJarPath)
 *      生成最终 mcDir/versions/<versionName>/<versionName>.json + 复制 jar
 *   2. 若 state.installSandboxDir 非空（Forge 路径）：把 sandbox/libraries 迁入 mcDir/libraries
 *      - 快速路径：mcDir/libraries 不存在 → 整目录 fs.renameSync（实测 0 ms）
 *      - 增量路径：递归 per-file rename（实测 5 ms / 200 文件）
 *
 * 进度：本阶段是 IO 密集型短任务，仅在开始/结束发 onProgress。
 *
 * 取消：合并是同步 IO，无中段取消点；安全的 cancel 检查放在阶段开始与迁入循环外。
 *
 * 创建日期：2026-05-06
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import {
  IDownloadPhase, PhaseContext, PhaseProgress,
} from '../PhaseRunner';
import { DownloadFlowState } from './DownloadFlowState';
import { AppLogger, CancelledError } from 'commons';
import { VersionJsonMerger } from '../../version/VersionJsonMerger';
import { safeBaseName } from '../../modloader/MavenUtils';
import { downloadComputeFileSha1, downloadPublishNoReplace } from '../DownloadManager';

const TAG = 'MergePhase';

class LibraryMigrationStats {
  migrated: number = 0;
  skipped: number = 0;
  failed: number = 0;
}

export class MergePhase implements IDownloadPhase {
  readonly name: string = 'merge';
  readonly weight: number;
  private state_: DownloadFlowState;

  constructor(state: DownloadFlowState, weight: number = 3) {
    this.state_ = state;
    this.weight = weight;
  }

  async run(_ctx: PhaseContext, onProgress: (p: PhaseProgress) => void): Promise<void> {
    if (this.state_.cancelled) throw new CancelledError();

    let phaseName = this.name;
    onProgress({
      phase: phaseName,
      progress: 0,
      speedBps: 0,
      message: '合并版本 JSON',
    });

    let mcJarPath = this.state_.tempVersionDir + '/' + this.state_.gameVersion + '.jar';
    VersionJsonMerger.merge(
      this.state_.tempJsonPath,
      this.state_.loaderJsonPath,
      this.state_.versionName,
      this.state_.targetDir,
      mcJarPath,
    );

    // Forge 沙箱路径才需要迁 libraries
    if (this.state_.installSandboxDir.length > 0) {
      MergePhase.migrateSandboxLibraries(this.state_.installSandboxDir, this.state_.mcDir);
    }

    if (this.state_.cancelled) throw new CancelledError();

    onProgress({
      phase: phaseName,
      progress: 1.0,
      speedBps: 0,
      message: '版本合并完成',
    });
    AppLogger.info(TAG, 'MergePhase done: ' + this.state_.targetDir);
  }

  /**
   * 沙箱 libraries 迁入策略（基于 SandboxProbe 真机验证）：
   *   - 若 mcDir/libraries 不存在 → 整目录 rename（T8 实测 0 ms）
   *   - 否则递归遍历沙箱 libraries，per-file rename（T5 实测 5 ms / 200 文件）
   * 已存在的文件：校验为同尺寸普通文件后跳过，并保留沙箱源文件供调用方审计/重试；
   * 目标类型或尺寸不一致、复制/发布/删源任一步失败都抛错。
   */
  static migrateSandboxLibraries(sandboxMcDir: string, realMcDir: string): void {
    let sandboxLibs = sandboxMcDir + '/libraries';
    let sandboxStat: fs.Stat;
    try {
      sandboxStat = fs.statSync(sandboxLibs);
    } catch (e) {
      AppLogger.info(TAG, 'No sandbox libraries to migrate (dir absent)');
      return;
    }
    let isDir = false;
    try { isDir = sandboxStat.isDirectory(); } catch (e) { /* */ }
    if (!isDir) return;

    let realLibs = realMcDir + '/libraries';
    let realLibsExists = false;
    try { realLibsExists = fs.statSync(realLibs).isDirectory(); } catch (e) { /* */ }

    // 整目录 rename 之前也必须扫描，避免把 installer 制造的链接/特殊文件带入真实库目录。
    MergePhase.validateMigrationTree_(sandboxLibs, 0);

    // 快速路径：realLibs 不存在 → 整目录 rename。只有 rename 系统调用本身失败
    // 才允许进入 per-file fallback；发布后的 fsync/校验失败不能伪装成“尚未迁移”。
    if (!realLibsExists) {
      let renamed = false;
      try {
        fs.renameSync(sandboxLibs, realLibs);
        renamed = true;
      } catch (e) {
        AppLogger.warn(TAG, 'Single-rename failed, fallback to per-file: ' + (e as Error).message);
      }
      if (renamed) {
        let published = fs.lstatSync(realLibs);
        if (published.isSymbolicLink() || !published.isDirectory()) {
          throw new Error('libraries 整目录 rename 后目标校验失败');
        }
        let parent = fs.openSync(realMcDir, fs.OpenMode.READ_ONLY);
        try { fs.fsyncSync(parent.fd); } finally { fs.closeSync(parent); }
        AppLogger.info(TAG, 'Migrated sandbox libraries via single-rename: ' + sandboxLibs + ' -> ' + realLibs);
        return;
      }
    }

    // 增量路径：per-file rename
    let stats = new LibraryMigrationStats();
    MergePhase.migrateLibrariesRecursive(sandboxLibs, realLibs, stats);
    AppLogger.info(TAG, 'Library migration: migrated=' + stats.migrated
      + ' skipped=' + stats.skipped + ' failed=' + stats.failed);
  }

  private static validateMigrationTree_(dir: string, depth: number): void {
    if (depth > 32) throw new Error('library 目录层级超限');
    let root = fs.lstatSync(dir);
    if (root.isSymbolicLink() || !root.isDirectory()) throw new Error('library 迁移源不是普通目录');
    let entries = fs.listFileSync(dir);
    for (let name of entries) {
      if (safeBaseName(name) !== name) throw new Error('library 迁移源包含非法文件名');
      let path = dir + '/' + name;
      let st = fs.lstatSync(path);
      if (st.isSymbolicLink()) throw new Error('拒绝迁移符号链接: ' + path);
      if (st.isDirectory()) MergePhase.validateMigrationTree_(path, depth + 1);
      else if (!st.isFile()) throw new Error('拒绝迁移非普通文件: ' + path);
    }
  }

  private static migrateLibrariesRecursive(srcDir: string, dstDir: string, stats: LibraryMigrationStats): void {
    let entries = fs.listFileSync(srcDir);
    try { fs.mkdirSync(dstDir, true); } catch (e) { /* exists */ }
    let dstRoot = fs.lstatSync(dstDir);
    if (dstRoot.isSymbolicLink() || !dstRoot.isDirectory()) throw new Error('library 迁移目标不是普通目录');
    for (let name of entries) {
      if (safeBaseName(name) !== name) throw new Error('library 迁移源包含非法文件名');
      let srcPath = srcDir + '/' + name;
      let dstPath = dstDir + '/' + name;
      let srcStat = fs.lstatSync(srcPath);
      if (srcStat.isSymbolicLink()) throw new Error('拒绝迁移符号链接: ' + srcPath);
      if (srcStat.isDirectory()) {
        try { fs.mkdirSync(dstPath, true); } catch (e) { /* exists */ }
        MergePhase.migrateLibrariesRecursive(srcPath, dstPath, stats);
        try { fs.rmdirSync(srcPath); } catch (e) { /* 不为空则忽略 */ }
      } else if (srcStat.isFile()) {
        let dstExists = false;
        try {
          let dstStat = fs.lstatSync(dstPath);
          if (dstStat.isSymbolicLink() || !dstStat.isFile()) {
            throw new Error('library 迁移目标存在非普通文件: ' + dstPath);
          }
          dstExists = true;
        } catch (e) {
          let message = (e as Error).message;
          if (message.indexOf('library 迁移目标存在非普通文件') >= 0) throw e as Error;
        }
        if (dstExists) {
          let existing = fs.lstatSync(dstPath);
          if (existing.isSymbolicLink() || !existing.isFile() || existing.size !== srcStat.size ||
              downloadComputeFileSha1(dstPath) !== downloadComputeFileSha1(srcPath)) {
            stats.failed += 1;
            throw new Error('library 迁移目标与源文件内容不一致: ' + dstPath);
          }
          // 内容完全相同才允许跳过；保留源供沙箱 finally 清理，不影响已验证目标。
          stats.skipped += 1;
          AppLogger.info(TAG, 'Library target content verified; source retained: ' + srcPath);
        } else {
          // R-03 同源修复（per-file 粒度）：只有 renameSync 系统调用本身失败（如跨设备）
          // 才允许 copy fallback。rename 已成功后的校验失败必须直接抛出——此时源已被移走，
          // 再走 copyFileAtomic_ 只会因源缺失产生误导性错误，且目标其实已发布。
          let renamed = false;
          try {
            fs.renameSync(srcPath, dstPath);
            renamed = true;
          } catch (e) {
            MergePhase.copyFileAtomic_(srcPath, dstPath, srcStat.size);
          }
          if (renamed) {
            let moved = fs.lstatSync(dstPath);
            if (moved.isSymbolicLink() || !moved.isFile() || moved.size !== srcStat.size) {
              stats.failed += 1;
              throw new Error('library rename 后目标校验失败: ' + dstPath);
            }
          }
          stats.migrated += 1;
        }
      } else {
        throw new Error('拒绝迁移非普通文件: ' + srcPath);
      }
    }
  }

  private static copyFileAtomic_(srcPath: string, dstPath: string, expectedSize: number): void {
    let tempPath = dstPath + '.amcl-copy-' + Date.now().toString() + '-'
      + Math.floor(Math.random() * 1000000).toString();
    try {
      // 临时文件必须与目标同目录，确保最终 rename 不再跨设备。
      fs.copyFileSync(srcPath, tempPath);
      let copied = fs.lstatSync(tempPath);
      if (copied.isSymbolicLink() || !copied.isFile() || copied.size !== expectedSize ||
          downloadComputeFileSha1(tempPath) !== downloadComputeFileSha1(srcPath)) {
        throw new Error('library fallback 复制后内容校验失败');
      }
      let tempFile = fs.openSync(tempPath, fs.OpenMode.READ_ONLY);
      try { fs.fsyncSync(tempFile.fd); } finally { fs.closeSync(tempFile); }
      // native helper 在同一父目录执行 no-replace publish + parent fsync，消除
      // lstat→rename 的覆盖窗口；失败时源和 temp 均保留到 catch 清理。
      if (!downloadPublishNoReplace(tempPath, dstPath)) {
        throw new Error('library fallback no-replace 发布失败: ' + dstPath);
      }
      let published = fs.lstatSync(dstPath);
      if (published.isSymbolicLink() || !published.isFile() || published.size !== expectedSize ||
          downloadComputeFileSha1(dstPath) !== downloadComputeFileSha1(srcPath)) {
        throw new Error('library fallback 发布后内容校验失败');
      }
      // 只有目标发布并复核成功后才删除源；删除失败同样向上抛错。
      fs.unlinkSync(srcPath);
    } catch (e) {
      try { fs.unlinkSync(tempPath); } catch (cleanupError) { /* */ }
      AppLogger.error(TAG, 'Library copy fallback failed: ' + srcPath + ' -> ' + dstPath
        + ', ' + (e as Error).message);
      throw e as Error;
    }
  }
}
